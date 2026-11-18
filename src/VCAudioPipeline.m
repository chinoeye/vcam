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
#import "VCAudioSource.h"
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
    size_t   _takeThisCall;     // 本次调用从环形缓冲取走的字节数
    uint64_t _starved;          // 拿不到数据的次数
    NSData  *_probeData;        // 探测源格式时取走的那一块，必须留着复用
    CMItemCount _probeFrames;
    int      _seekCount;

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
    _probeData = nil;
    _probeFrames = 0;
    _produced = 0;
    _consumed = 0;
    _underrun = 0;
    _seekCount = 0;

    // 源格式先不写死：等第一次真正拿到数据，用 length/frames 反推。
    //
    //  之前写死 mono（4 字节/帧），但素材是 stereo（8 字节/帧）——
    //  交错数据被当成连续单声道样本解释，左右声道交替播放，
    //  听感就是频率翻倍的「哒哒哒」。
    //  想靠 AVAssetReaderTrackOutput 的 AVNumberOfChannelsKey 强制下混，
    //  实测不一定生效（那套 settings 对音频支持有限）。
    //  所以改成实测：谁也别猜，用数据本身说话。
    _srcFormat = (AudioStreamBasicDescription){0};
    VCLog(@"音频管道目标格式：%.0fHz / %u ch / %u bit / %u B每帧",
          _dstFormat.mSampleRate, (unsigned)_dstFormat.mChannelsPerFrame,
          (unsigned)_dstFormat.mBitsPerChannel, (unsigned)_dstFormat.mBytesPerFrame);

    pthread_mutex_unlock(&_lock);

    if (!_ring) {
        VCLog(@"音频管道：环形缓冲分配失败");
        return;
    }

    VCLog(@"音频管道就绪：目标 %.0fHz/x%u/%u bit，缓冲 %zu 帧（源格式等首块数据实测）",
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
    if (wantFrames == 0) return;

    // ---- 第一次拿到数据时，用实测格式建转换器 ----
    if (!_conv) {
        [self probeSourceFormatLocked];
        if (!_conv) return;
    }

    // 需要多少源帧。倍率按源/目标采样率算；声道数不影响帧数，只影响字节。
    double ratio = (_srcFormat.mSampleRate > 0 && _dstFormat.mSampleRate > 0)
                 ? (_srcFormat.mSampleRate / _dstFormat.mSampleRate)
                 : 1.0;
    size_t needSrcFrames = (size_t)((double)wantFrames * ratio) + 2;
    size_t srcBpf = _srcFormat.mBytesPerFrame;      // 4=mono, 8=stereo（float32）

    NSMutableData *srcData = [NSMutableData dataWithCapacity:needSrcFrames * srcBpf];

    // 攒够 needSrcFrames 个**真帧**。先放探测时取走的那一块。
    size_t haveFrames = 0;
    if (_probeData.length > 0) {
        [srcData appendData:_probeData];
        haveFrames += (size_t)_probeFrames;
        _probeData = nil;
        _probeFrames = 0;
    }
    int guard = 0;
    while (haveFrames < needSrcFrames && guard++ < 64) {
        CMItemCount got = 0;
        AudioStreamBasicDescription a = {0};
        NSData *more = [[VCAudioSource shared] nextPCMWithFrames:&got asbd:&a];
        if (!more || more.length == 0) break;
        [srcData appendData:more];

        // 用「返回的字节数 ÷ 帧数」反推每帧字节，比任何声明都可靠
        if (got > 0 && more.length > 0) {
            haveFrames += (size_t)got;
        }
    }

    if (haveFrames == 0) {
        _starved++;
        if (_starved <= 3 || _starved % 500 == 0) {
            VCLog(@"音频管道：本轮拿不到素材数据 (累计 %llu 次)", _starved);
        }
        return;
    }

    // 不够就延音补齐（帧数维度，不是样本维度）
    size_t availFrames = srcData.length / srcBpf;
    if (availFrames < needSrcFrames) {
        size_t padFrames = needSrcFrames - availFrames;
        NSMutableData *p2 = [NSMutableData dataWithLength:padFrames * srcBpf];
        // 用最后一帧的内容重复填充，保持幅度连续
        const uint8_t *last = (const uint8_t *)srcData.bytes
                            + (availFrames - 1) * srcBpf;
        uint8_t *dst = (uint8_t *)p2.mutableBytes;
        for (size_t k = 0; k < padFrames; k++) {
            memcpy(dst + k * srcBpf, last, srcBpf);
        }
        [srcData appendData:p2];
        availFrames = needSrcFrames;
    }

    size_t outBytes = wantFrames * _bytesPerFrame;
    NSMutableData *out = [NSMutableData dataWithLength:outBytes];

    VCConvCtx ctx;
    ctx.data     = (const float *)srcData.bytes;
    ctx.total    = availFrames;
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
        _decodedMaterialSeconds += (double)producedFrames / _dstFormat.mSampleRate;
    }
    pthread_mutex_unlock(&_lock);
}

/// 用第一块真实数据反推源格式，然后建转换器。
///
///  为什么要反推：素材是 stereo（8 字节/帧），但 AVAssetReaderTrackOutput
///  的 AVNumberOfChannelsKey 不一定生效。声明错了，交错数据就会被当成
///  连续单声道样本播，听感是频率翻倍的「哒哒哒」。与其猜，不如量。
- (void)probeSourceFormatLocked
{
    CMItemCount got = 0;
    AudioStreamBasicDescription a = {0};
    NSData *probe = [[VCAudioSource shared] nextPCMWithFrames:&got asbd:&a];
    if (!probe || probe.length == 0 || got == 0) return;

    // 这块数据已经被 reader 消费掉了，必须留着重用 ——
    // 丢掉它会凭空少一块音频，正好造成一个咔哒。
    _probeData   = probe;
    _probeFrames = got;

    size_t bpf = probe.length / (size_t)got;      // 实测每帧字节
    UInt32 ch = 1;
    if (bpf >= 8)      ch = 2;
    else if (bpf >= 4) ch = 1;

    AudioStreamBasicDescription src = {0};
    src.mSampleRate       = a.mSampleRate > 0 ? a.mSampleRate
                            : ([VCAudioSource shared].sampleRate > 0
                               ? [VCAudioSource shared].sampleRate : 48000);
    src.mFormatID         = kAudioFormatLinearPCM;
    src.mFormatFlags      = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked;
    src.mBytesPerFrame    = (UInt32)bpf;
    src.mBytesPerPacket   = (UInt32)bpf;
    src.mFramesPerPacket  = 1;
    src.mChannelsPerFrame = ch;
    src.mBitsPerChannel   = 32;

    AudioConverterRef conv = NULL;
    OSStatus st = AudioConverterNew(&src, &_dstFormat, &conv);

    VCLog(@"音频管道源格式(实测)：%.0fHz / %u ch / %u bit / %zu B每帧  -> 转换器 %@(%d)",
          src.mSampleRate, (unsigned)src.mChannelsPerFrame,
          (unsigned)src.mBitsPerChannel, bpf,
          st == noErr ? @"创建成功" : @"创建失败", (int)st);

    if (st == noErr) {
        _conv = conv;
        _srcFormat = src;
    } else {
        if (bpf >= 8) {
            VCLog(@"音频管道：stereo 转换器创建失败，试 mono 兜底");
        }
    }
}

// ------------------------------------------------------------------ 消费

- (void)fillIOData:(AudioBufferList *)ioData frames:(UInt32)frames
{
    if (!ioData || frames == 0) return;

    pthread_mutex_lock(&_lock);

    if (!_ring || _bytesPerFrame == 0) {
        for (UInt32 b = 0; b < ioData->mNumberBuffers; b++) {
            AudioBuffer *buf = &ioData->mBuffers[b];
            if (buf->mData && buf->mDataByteSize) {
                memset(buf->mData, 0, buf->mDataByteSize);
            }
        }
        pthread_mutex_unlock(&_lock);
        return;
    }

    // ---- 可写长度：以 AudioUnit 的契约为准 ----
    //
    //  契约是 mDataByteSize == frames * bytesPerFrame。
    //  实测抖音这里给的 mDataByteSize 是 40960，而 frames=1024、bpf=4
    //  算出来只有 4096 —— 差 10 倍。上一版盲目信任 mDataByteSize，
    //  每次都往 4KB 的缓冲里写 40KB，越界 36KB，
    //  这就是「越做越差」的重要原因之一。
    //
    //  现在一律取两者较小值，绝不越界。
    const size_t contractBytes = (size_t)frames * _bytesPerFrame;

    _takeThisCall = 0;      // 每次调用都要重置，否则会沿用上次的残留值

    for (UInt32 b = 0; b < ioData->mNumberBuffers; b++) {
        AudioBuffer *buf = &ioData->mBuffers[b];
        if (!buf->mData || buf->mDataByteSize == 0) continue;

        size_t writable = buf->mDataByteSize < contractBytes
                        ? buf->mDataByteSize : contractBytes;
        writable -= writable % _bytesPerFrame;
        if (writable == 0) continue;

        if (b == 0) {
            size_t avail0 = _count * _bytesPerFrame;
            _takeThisCall = writable < avail0 ? writable : avail0;
            _takeThisCall -= _takeThisCall % _bytesPerFrame;
        }
        size_t take = _takeThisCall;

        if (take >= writable) {
            // 缓冲够：整块拷贝（实时线程唯一的工作）
            size_t tail = _ringBytes - _readPos;
            if (take <= tail) {
                memcpy(buf->mData, _ring + _readPos, take);
            } else {
                memcpy(buf->mData, _ring + _readPos, tail);
                memcpy((uint8_t *)buf->mData + tail, _ring, take - tail);
            }
        } else {
            // 缓冲不够：这一块直接输出静音，并计数。
            //
            //  不重复上一块 —— 重复整块 1024 帧（21ms）会让声音变成
            //  机械的「哒哒哒」，就是用户说的打电报。
            //  静音至少听感是「短暂空白」，不会制造假的节奏感。
            memset(buf->mData, 0, writable);
            _underrun++;
        }

        // 契约外的那部分（mDataByteSize 比 needBytes 大的时候）清掉，
        // 避免残留上一次的数据被当成有效样本播出来。
        if (buf->mDataByteSize > writable) {
            memset((uint8_t *)buf->mData + writable, 0,
                   buf->mDataByteSize - writable);
        }
    }

    if (_takeThisCall > 0) {
        _readPos = (_readPos + _takeThisCall) % _ringBytes;
        size_t takenFrames = _takeThisCall / _bytesPerFrame;
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
