//
//  VCAudioPipeline.m
//
//  生产者-消费者音频管道。设计要点：
//
//  【为什么环形缓冲里存最终格式】
//    实时线程（AudioUnitRender）每 21ms 必须返回。AudioConverter 虽然不算
//    特别慢，但它内部有锁、有状态机，放在实时路径上始终是隐患。
//    后台直接产出 int16/目标声道/目标采样率的成品，实时线程只做 memcpy。
//
//  【为什么时间同步和 seek 都在后台】
//    偏差校正需要重建 AVAssetReader（实测阻塞 140ms）。
//    之前放在实时线程上，就是波形里那个 140ms 的大断点。
//    挪到后台后，重建期间环形缓冲里还有几百毫秒的存货，实时线程察觉不到。
//
//  【时间基准只有一个变量】
//    之前同时维护「解码进度」和「消费进度」，两者在 seek 时不同步，
//    互相判定对方严重落后，形成永远 seek 的死循环 —— 直接没声音。
//    现在生产端自己跟自己对齐，不存在两个基准打架。
//

#import "VCAudioPipeline.h"
#import "VCFrameSource.h"
#import "VCLog.h"

#import <pthread.h>
#import <stdlib.h>
#import <string.h>

// 环形缓冲容量。
//
//  这个值**直接等于音频延迟**：缓冲里存多少，声音就比画面晚多少。
//  1 秒（48000 帧）延迟太大，直播时口型对不上；200ms（9600 帧）
//  既能扛住解码抖动，延迟又可以接受。
static const size_t kRingFrames = 9600;

// ------------------------------------------------------------------ 转换输入回调

typedef struct {
    const float *data;
    size_t       total;
    size_t       consumed;
} VCConvCtx;

static OSStatus VCPipeInputProc(AudioConverterRef cvt,
                                UInt32 *ioNumPackets,
                                AudioBufferList *ioData,
                                AudioStreamPacketDescription **desc,
                                void *userData)
{
    VCConvCtx *c = (VCConvCtx *)userData;
    if (!c || !c->data) return 1;

    size_t remain = c->total - c->consumed;
    UInt32 want = *ioNumPackets;
    if (want > (UInt32)remain) want = (UInt32)remain;
    if (want == 0) return 1;      // 喂完了，告诉转换器没数据

    ioData->mNumberBuffers = 1;
    ioData->mBuffers[0].mNumberChannels = 1;
    ioData->mBuffers[0].mData = (void *)(c->data + c->consumed);
    ioData->mBuffers[0].mDataByteSize = want * sizeof(float);

    *ioNumPackets = want;
    c->consumed += want;
    return noErr;
}

// ------------------------------------------------------------------ 实现

@implementation VCAudioPipeline
{
    uint8_t *_ring;
    size_t   _ringBytes;
    size_t   _bytesPerFrame;
    size_t   _writePos;
    size_t   _readPos;
    size_t   _count;            // 缓冲里实际有多少帧
                                // 必须有这个：_writePos == _readPos 既可能是空
                                // 也可能是满，光看指针差会把「满」误判成「空」，
                                // 于是继续写、把没读的数据全冲掉
                                // （实测产出 25M 帧、消费只有 49 万帧，差 52 倍）

    AudioStreamBasicDescription _dstFormat;
    AudioStreamBasicDescription _srcFormat;
    AudioConverterRef _conv;
    BOOL _hasFormat;

    dispatch_queue_t  _queue;
    dispatch_source_t _timer;
    volatile BOOL _running;

    uint64_t _produced;
    uint64_t _consumed;
    uint64_t _underrun;
    int      _seekCount;

    uint8_t *_lastOut;
    size_t   _lastOutBytes;

    pthread_mutex_t _lock;
}

+ (instancetype)shared
{
    static VCAudioPipeline *inst = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        inst = [[VCAudioPipeline alloc] init];
    });
    return inst;
}

- (instancetype)init
{
    if ((self = [super init])) {
        pthread_mutex_init(&_lock, NULL);
        _queue = dispatch_queue_create("com.yg.vcam.audiopipe",
                                       DISPATCH_QUEUE_SERIAL);
        dispatch_set_target_queue(_queue,
            dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0));
    }
    return self;
}

// ------------------------------------------------------------------ 格式

- (void)setTargetFormat:(AudioStreamBasicDescription)format
{
    if (format.mSampleRate <= 0 ||
        format.mChannelsPerFrame == 0 ||
        format.mBytesPerFrame == 0) {
        return;
    }

    pthread_mutex_lock(&_lock);
    BOOL same = _hasFormat &&
        memcmp(&_dstFormat, &format, sizeof(format)) == 0;
    pthread_mutex_unlock(&_lock);
    if (same) return;

    BOOL wasRunning = _running;
    [self stop];

    // 清空所有状态
    pthread_mutex_lock(&_lock);
    if (_ring) { free(_ring); _ring = NULL; }
    if (_lastOut) { free(_lastOut); _lastOut = NULL; }
    _lastOutBytes = 0;
    if (_conv) { AudioConverterDispose(_conv); _conv = NULL; }

    _dstFormat     = format;
    _hasFormat     = YES;
    _bytesPerFrame = format.mBytesPerFrame;

    size_t need = kRingFrames * _bytesPerFrame;
    _ring = calloc(1, need);
    _ringBytes = _ring ? need : 0;
    _writePos = 0;
    _readPos = 0;
    _count = 0;
    _produced = 0;
    _consumed = 0;
    _underrun = 0;
    _seekCount = 0;

    AudioStreamBasicDescription src = {0};
    src.mSampleRate       = 48000;
    src.mFormatID         = kAudioFormatLinearPCM;
    src.mFormatFlags      = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked;
    src.mBytesPerPacket   = 4;
    src.mFramesPerPacket  = 1;
    src.mBytesPerFrame    = 4;
    src.mChannelsPerFrame = 1;
    src.mBitsPerChannel   = 32;
    _srcFormat = src;

    AudioConverterRef conv = NULL;
    OSStatus st = AudioConverterNew(&src, &_dstFormat, &conv);
    if (st == noErr) _conv = conv;
    pthread_mutex_unlock(&_lock);

    if (st != noErr || !_conv || !_ring) {
        VCLog(@"音频管道：初始化失败 (conv=%d, ring=%p)", (int)st, _ring);
        return;
    }

    VCLog(@"音频管道就绪：48000/mono/f32 -> %.0fHz/x%u/%u bit，缓冲 %zu 帧",
          format.mSampleRate,
          (unsigned)format.mChannelsPerFrame,
          (unsigned)format.mBitsPerChannel,
          kRingFrames);

    // 格式就绪就直接开跑。
    // 不依赖外部先 start() 再 setTargetFormat —— 那个顺序很容易搞错，
    // 一旦漏了就是「有 hook 但没产出」，症状跟完全没注入一样。
    (void)wasRunning;
    [self start];
}

// ------------------------------------------------------------------ 启停

- (void)start
{
    if (_running || !_conv || !_ring) return;
    _running = YES;

    _timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, _queue);
    dispatch_source_set_timer(_timer,
                              dispatch_time(DISPATCH_TIME_NOW, 0),
                              10 * NSEC_PER_MSEC,
                              2 * NSEC_PER_MSEC);

    __weak typeof(self) weakSelf = self;
    dispatch_source_set_event_handler(_timer, ^{
        [weakSelf produceSome];
    });
    dispatch_resume(_timer);

    VCLog(@"音频管道已启动");
}

- (void)stop
{
    if (!_running) return;
    _running = NO;
    if (_timer) {
        dispatch_source_cancel(_timer);
        _timer = nil;
    }
    VCLog(@"音频管道已停止");
}

// ------------------------------------------------------------------ 生产

- (void)produceSome
{
    if (!_running) return;

    pthread_mutex_lock(&_lock);
    size_t count   = _count;
    size_t bpf     = _bytesPerFrame;
    Float64 dstRate = _dstFormat.mSampleRate;
    pthread_mutex_unlock(&_lock);

    if (bpf == 0 || dstRate <= 0) return;

    // 水位控制：低于 50% 就补到接近满。
    // 之前是「余量小于 2048 就完全不干活」，结果缓冲长期在低位徘徊，
    // 消费端一不小心就取空 —— 听感是密集的咔哒（打电报）。
    if (count >= kRingFrames * 9 / 10) return;      // 已经够满，别占 CPU
    size_t freeFrames = kRingFrames - count;

    // 一次最多补 0.5 秒，别长时间占着后台队列
    size_t want = freeFrames;
    size_t cap  = (size_t)(dstRate / 2);
    if (want > cap) want = cap;

    [self produceFrames:want];
}

- (void)produceFrames:(size_t)wantFrames
{
    if (!_conv || wantFrames == 0) return;

    // 需要多少源帧（48000 坐标系）
    double ratio = _srcFormat.mSampleRate / _dstFormat.mSampleRate;
    size_t needSrc = (size_t)((double)wantFrames * ratio) + 2;

    NSMutableData *srcData = [NSMutableData dataWithCapacity:needSrc * sizeof(float)];
    int guard = 0;
    while ((srcData.length / sizeof(float)) < needSrc && guard++ < 32) {
        CMItemCount got = 0;
        AudioStreamBasicDescription a = {0};
        NSData *more = [[VCFrameSource shared]
                        copyNextAudioPCMWithFrameCount:&got asbd:&a];
        if (!more || more.length == 0) break;
        [srcData appendData:more];
    }

    size_t avail = srcData.length / sizeof(float);
    if (avail == 0) {
        static int sMiss = 0;
        if (++sMiss <= 3 || sMiss % 100 == 0) {
            VCLog(@"音频管道：本轮拿不到素材数据 (#%d)", sMiss);
        }
        return;
    }

    if (avail < needSrc) {
        // 不够就用最后一个样本延音补齐，保持幅度连续
        size_t pad = needSrc - avail;
        float last = ((const float *)srcData.bytes)[avail - 1];
        NSMutableData *p = [NSMutableData dataWithLength:pad * sizeof(float)];
        float *pp = (float *)p.mutableBytes;
        for (size_t i = 0; i < pad; i++) pp[i] = last;
        [srcData appendData:p];
        avail = needSrc;
    }

    size_t outBytes = wantFrames * _bytesPerFrame;
    NSMutableData *out = [NSMutableData dataWithLength:outBytes];

    VCConvCtx ctx;
    ctx.data     = (const float *)srcData.bytes;
    ctx.total    = avail;
    ctx.consumed = 0;

    AudioBufferList abl;
    abl.mNumberBuffers = 1;
    abl.mBuffers[0].mNumberChannels = _dstFormat.mChannelsPerFrame;
    abl.mBuffers[0].mData = out.mutableBytes;
    abl.mBuffers[0].mDataByteSize = (UInt32)outBytes;

    UInt32 outPackets = (UInt32)wantFrames;
    OSStatus st = AudioConverterFillComplexBuffer(_conv,
                                                  VCPipeInputProc,
                                                  &ctx,
                                                  &outPackets,
                                                  &abl,
                                                  NULL);
    if (st != noErr && st != 1) {
        static BOOL sErr = NO;
        if (!sErr) { sErr = YES; VCLog(@"音频管道：转换失败 %d", (int)st); }
        return;
    }

    size_t produced = abl.mBuffers[0].mDataByteSize;
    if (produced == 0) return;

    // 写环形缓冲
    pthread_mutex_lock(&_lock);
    size_t freeFramesNow = kRingFrames - _count;
    size_t space = freeFramesNow * _bytesPerFrame;
    if (produced > space) produced = space - (space % _bytesPerFrame);
    if (produced > 0) {
        size_t tail = _ringBytes - _writePos;
        if (produced <= tail) {
            memcpy(_ring + _writePos, out.bytes, produced);
        } else {
            memcpy(_ring + _writePos, out.bytes, tail);
            memcpy(_ring, (const uint8_t *)out.bytes + tail, produced - tail);
        }
        _writePos = (_writePos + produced) % _ringBytes;
        _count += produced / _bytesPerFrame;
        _produced += produced / _bytesPerFrame;
    }
    pthread_mutex_unlock(&_lock);
}

// ------------------------------------------------------------------ 消费

- (void)fillIOData:(AudioBufferList *)ioData frames:(UInt32)frames
{
    if (!ioData || frames == 0 || !_ring || _bytesPerFrame == 0) return;

    size_t needBytes = (size_t)frames * _bytesPerFrame;

    pthread_mutex_lock(&_lock);

    size_t avail = _count * _bytesPerFrame;
    size_t take  = needBytes < avail ? needBytes : avail;
    take -= take % _bytesPerFrame;

    for (UInt32 b = 0; b < ioData->mNumberBuffers; b++) {
        AudioBuffer *buf = &ioData->mBuffers[b];
        if (!buf->mData || buf->mDataByteSize == 0) continue;

        if (take > 0) {
            size_t tail = _ringBytes - _readPos;
            if (take <= tail) {
                memcpy(buf->mData, _ring + _readPos, take);
            } else {
                memcpy(buf->mData, _ring + _readPos, tail);
                memcpy((uint8_t *)buf->mData + tail, _ring, take - tail);
            }
            if (take < buf->mDataByteSize) {
                memset((uint8_t *)buf->mData + take, 0, buf->mDataByteSize - take);
            }
            // 存下来，供缓冲空时重复
            if (_lastOutBytes < take) {
                uint8_t *p = realloc(_lastOut, take);
                if (p) { _lastOut = p; _lastOutBytes = take; }
            }
            if (_lastOut) memcpy(_lastOut, buf->mData, take);
        } else if (_lastOut && _lastOutBytes > 0) {
            // 缓冲空：重复上一次输出，避免幅度突降到 0（听感是「啪」一声）
            size_t n = _lastOutBytes < buf->mDataByteSize
                     ? _lastOutBytes : buf->mDataByteSize;
            memcpy(buf->mData, _lastOut, n);
            if (n < buf->mDataByteSize) {
                memset((uint8_t *)buf->mData + n, 0, buf->mDataByteSize - n);
            }
            _underrun++;
        } else {
            memset(buf->mData, 0, buf->mDataByteSize);
            _underrun++;
        }
    }

    if (take > 0) {
        _readPos = (_readPos + take) % _ringBytes;
        size_t takenFrames = take / _bytesPerFrame;
        if (takenFrames > _count) takenFrames = _count;
        _count -= takenFrames;
        _consumed += takenFrames;
    }

    pthread_mutex_unlock(&_lock);
}

// ------------------------------------------------------------------ 查询

- (uint64_t)producedFrames { return _produced; }
- (uint64_t)consumedFrames { return _consumed; }
- (uint64_t)underrunCount  { return _underrun; }
- (int)seekCount           { return _seekCount; }
- (BOOL)isRunning          { return _running; }

- (size_t)bufferedFrames
{
    if (!_ring || _bytesPerFrame == 0) return 0;
    pthread_mutex_lock(&_lock);
    size_t f = _count;
    pthread_mutex_unlock(&_lock);
    return f;
}

@end
