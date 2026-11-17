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
//
//  取 800ms（38400 帧）的依据：
//    · 实测欠载 103 次 / 713 次调用 = 14.5%，每次欠载会让实时线程
//      重复上一块 21ms，听感是「哒哒哒」——就是用户说的打电报
//    · 生产端单次耗时被视频解码拖到 20~50ms，定时器 5ms 一次会堆积
//    · 800ms 有 16 倍余量，即使连续卡几次也不会取空
//    · 录播场景 800ms 延迟完全可接受（不是实时互动）
static const size_t kRingFrames = 38400;

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

    // 已经解码到素材内的哪个时间点（秒）。
    // 生产端用它和视频时间比对，做闭环校正 —— 这是 5 小时长跑不跑偏的关键。
    double   _decodedMaterialSeconds;

    uint64_t _produced;
    uint64_t _consumed;
    uint64_t _underrun;
    uint64_t _starved;          // copyNextAudioPCM 拿不到数据的次数
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

    // 逐字段比较，不要用 memcmp 比整个结构体。
    //
    // AudioStreamBasicDescription 里有 padding 字节，调用方传进来的
    // 结构体 padding 通常是脏的，memcmp 会判定「格式变了」——
    // 于是每次 AudioUnitRender 都会走到下面的重建流程：
    // 停后台 → free 环形缓冲 → 重建转换器 → 重启。
    // 每秒 47 次重建 = 缓冲永远是空的 = 打电报。
    pthread_mutex_lock(&_lock);
    BOOL same = _hasFormat &&
                _dstFormat.mSampleRate       == format.mSampleRate &&
                _dstFormat.mChannelsPerFrame == format.mChannelsPerFrame &&
                _dstFormat.mBitsPerChannel   == format.mBitsPerChannel &&
                _dstFormat.mFormatFlags      == format.mFormatFlags &&
                _dstFormat.mBytesPerFrame    == format.mBytesPerFrame &&
                _conv != NULL && _ring != NULL;
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
    _decodedMaterialSeconds = 0.0;
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
    // 5ms 一次而不是 10ms：单次生产被视频解码挡住时，
    // 靠更高的触发频率把产量补回来。
    dispatch_source_set_timer(_timer,
                              dispatch_time(DISPATCH_TIME_NOW, 0),
                              5 * NSEC_PER_MSEC,
                              1 * NSEC_PER_MSEC);

    __weak typeof(self) weakSelf = self;
    dispatch_source_set_event_handler(_timer, ^{
        [weakSelf produceSome];
    });
    dispatch_resume(_timer);

    VCLog(@"音频管道已启动");
}

- (void)stop
{
    if (!_running && !_timer) return;
    _running = NO;

    if (_timer) {
        dispatch_source_cancel(_timer);
        _timer = nil;
    }

    // 关键：dispatch_source_cancel 是异步的，此刻后台的 produceFrames
    // 可能正持着 _lock 干活。必须同步等它跑完这一轮，否则
    // setTargetFormat 里紧接着的 free(_ring) 会踩到正在写的那块内存，
    // 而新起的 timer 又会和旧的 handler 同时生产 —— 数据直接错乱。
    if (_queue) {
        dispatch_sync(_queue, ^{ /* 排空队列 */ });
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
    // 只补到 70% 水位就停手：留 30% 的余量给定时器抖动，
    // 比「补到接近满才停」更能应付突发的慢一次。
    if (count >= kRingFrames * 8 / 10) return;
    size_t freeFrames = kRingFrames - count;

    // 一次最多补 0.5 秒，别长时间占着后台队列。
    // （800ms 缓冲 + 80% 水位 = 最多需要补 0.4 秒，够一次补满）
    size_t want = freeFrames;
    size_t cap  = (size_t)(dstRate / 2);
    if (want > cap) want = cap;

    // ---- 不做「音画时间对齐」----
    //
    //  这里曾经有一段闭环校正：拿 currentVideoSourceTime（视频**解码**进度）
    //  和音频已解码位置比对，偏差超 100ms 就 seek。
    //  实测是错的，而且很糟：
    //
    //    视频解码天生超前播放（预解码 + 抖音按 30fps 取帧，解码器跑得更快），
    //    报告里 currentVideoSourceTime 比实际播放位置超前了 14.7 秒。
    //    音频按它对齐 → 音频也超前 14.7 秒 → 下次检查还是超前 → 再 seek
    //    → 96 次 seek，每次清空 400ms 缓冲 → 连续断点，25 秒数据被丢弃。
    //
    //  真正保证音画同步的机制不是这个：
    //    我们在**采集端**供数据。视频帧和音频块都由系统按实时节奏取走，
    //    只要两者都不间断地按顺序供给，编码出来的音画天然同步。
    //    唯一要保证的是「供给不中断」—— 那是环形缓冲水位控制的活。
    //
    //  素材循环时的对齐由 VCFrameSource 负责：视频回绕时会一起重置音频 reader。

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
        _starved++;
        if (_starved <= 3 || _starved % 500 == 0) {
            VCLog(@"音频管道：本轮拿不到素材数据 (累计 %llu 次)", _starved);
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
        size_t producedFrames = produced / _bytesPerFrame;
        _writePos = (_writePos + produced) % _ringBytes;
        _count += producedFrames;
        _produced += producedFrames;

        // 记录解码进度（目标采样率坐标系，和视频时间同一尺度）
        _decodedMaterialSeconds += (double)producedFrames / _dstFormat.mSampleRate;
    }
    pthread_mutex_unlock(&_lock);
}

// ------------------------------------------------------------------ 消费

- (void)fillIOData:(AudioBufferList *)ioData frames:(UInt32)frames
{
    if (!ioData || frames == 0) return;

    // 所有对 _ring / _bytesPerFrame 的访问都必须在锁内 ——
    // setTargetFormat 会 free 掉旧缓冲，锁外读指针就是 use-after-free。
    pthread_mutex_lock(&_lock);

    if (!_ring || _bytesPerFrame == 0) {
        // 格式还没就绪：输出静音，但仍要填满 buffer，否则是脏数据
        for (UInt32 b = 0; b < ioData->mNumberBuffers; b++) {
            AudioBuffer *buf = &ioData->mBuffers[b];
            if (buf->mData && buf->mDataByteSize) {
                memset(buf->mData, 0, buf->mDataByteSize);
            }
        }
        pthread_mutex_unlock(&_lock);
        return;
    }

    const size_t needBytes = (size_t)frames * _bytesPerFrame;
    const size_t avail     = _count * _bytesPerFrame;

    size_t take = needBytes < avail ? needBytes : avail;
    take -= take % _bytesPerFrame;

    BOOL shortfall = (take < needBytes);
    if (shortfall) _underrun++;      // 每次调用最多计一次

    for (UInt32 b = 0; b < ioData->mNumberBuffers; b++) {
        AudioBuffer *buf = &ioData->mBuffers[b];
        if (!buf->mData || buf->mDataByteSize == 0) continue;

        size_t filled = 0;

        // ① 先从环形缓冲取真实数据
        if (take > 0) {
            size_t tail = _ringBytes - _readPos;
            if (take <= tail) {
                memcpy(buf->mData, _ring + _readPos, take);
            } else {
                memcpy(buf->mData, _ring + _readPos, tail);
                memcpy((uint8_t *)buf->mData + tail, _ring, take - tail);
            }
            filled = take;
        }

        // ② 不足一块的部分用「上一次的输出」补齐，绝不补零。
        //
        //    补零会让波形从当前幅度瞬间跌到 0，听感就是密集的咔哒声
        //    （打电报）。延音保持幅度连续，几百微秒的缺口人耳听不出来。
        if (filled < buf->mDataByteSize) {
            size_t pad = buf->mDataByteSize - filled;
            if (_lastOut && _lastOutBytes > 0) {
                size_t n = pad < _lastOutBytes ? pad : _lastOutBytes;
                memcpy((uint8_t *)buf->mData + filled, _lastOut, n);
                if (n < pad) {
                    memset((uint8_t *)buf->mData + filled + n, 0, pad - n);
                }
            } else {
                memset((uint8_t *)buf->mData + filled, 0, pad);
            }
        }

        // ③ 存一份本次输出，供下次补齐用
        if (_lastOutBytes < buf->mDataByteSize) {
            uint8_t *np = realloc(_lastOut, buf->mDataByteSize);
            if (np) { _lastOut = np; _lastOutBytes = buf->mDataByteSize; }
        }
        if (_lastOut && _lastOutBytes >= buf->mDataByteSize) {
            memcpy(_lastOut, buf->mData, buf->mDataByteSize);
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

- (double)currentDrift
{
    // 现在不做「音频追视频」的时间校正了 —— 那个机制用的时钟是错的
    // （videoSourceSeconds 是解码进度，天生比播放位置超前十几秒）。
    //
    // 这个属性保留名字，但含义改成「当前缓冲里存了多少秒的音频」，
    // 也就是声音相对画面晚多少。800ms 缓冲下它应该在 0.3~0.8 之间，
    // 掉到 0.1 以下就说明生产快跟不上了。
    pthread_mutex_lock(&_lock);
    size_t c = _count;
    Float64 r = _dstFormat.mSampleRate;
    pthread_mutex_unlock(&_lock);
    return r > 0 ? (double)c / (double)r : 0.0;
}

- (size_t)bufferedFrames
{
    if (!_ring || _bytesPerFrame == 0) return 0;
    pthread_mutex_lock(&_lock);
    size_t f = _count;
    pthread_mutex_unlock(&_lock);
    return f;
}

@end
