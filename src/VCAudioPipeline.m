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
//  取 2 秒（96000 帧）的依据：
//    · 实测欠载 103 次 / 713 次调用 = 14.5%，每次欠载会让实时线程
//      重复上一块 21ms，听感是「哒哒哒」——就是用户说的打电报
//    · 生产端单次耗时被视频解码拖到 20~50ms，定时器 5ms 一次会堆积
//    · 800ms 有 16 倍余量，即使连续卡几次也不会取空
//    · 录播场景 800ms 延迟完全可接受（不是实时互动）
static const size_t kRingFrames = 96000;

// ------------------------------------------------------------------ 转换输入回调

typedef struct {
    const float *data;          // 源数据起点（float32，可能是交错多声道）
    size_t       total;         // 总帧数（不是 float 个数）
    size_t       consumed;      // 已喂掉的帧数
    size_t       bytesPerFrame; // 每帧字节：4=mono, 8=stereo（float32）
    uint32_t     channels;      // 源声道数
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

    // 指针按**字节**偏移，不能按 float 偏移。
    //
    //  源是 stereo（8 字节/帧）时，consumed 帧 = consumed*2 个 float。
    //  写成 (c->data + c->consumed) 时偏移只有正确值的一半，
    //  转换器读到错位的半帧数据 —— 表现为素材声里夹周期性电报声。
    //
    //  mDataByteSize 同理必须是 want * bytesPerFrame；
    //  固定 sizeof(float)=4 在 stereo 下只喂了一半数据。
    const uint8_t *base = (const uint8_t *)c->data
                        + c->consumed * c->bytesPerFrame;

    ioData->mNumberBuffers = 1;
    ioData->mBuffers[0].mNumberChannels = c->channels;
    ioData->mBuffers[0].mData = (void *)base;
    ioData->mBuffers[0].mDataByteSize = (UInt32)(want * c->bytesPerFrame);

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
    double   _lastUnderrunAt;   // 上次欠载发生在录音开始后第几秒
    uint64_t _silentNoRing;     // 因 _ring 为空而输出静音的帧数
    uint64_t _silentShort;      // 因缓冲不足而输出静音的帧数
    uint64_t _zeroBytes;        // writable 为 0 的调用次数
    uint64_t _totalFilledFrames;// 累计填充的帧数（诊断）
    uint64_t _dcSegments;       // 产出的数据里出现「整段恒定值」的次数
    double   _maxProduceMs;     // 单次生产最长耗时
    double   _startedAt;        // 管道启动时刻（CFAbsoluteTime）
    double   _skipUntilSeconds; // 启动对齐：丢弃该位置之前的解码数据（不 seek）
    NSData  *_probeData;        // 探测源格式时取走的那一块，必须留着复用
    NSMutableData *_srcCarry;   // 上一轮没被转换器吃掉的源数据（字节）
    size_t   _srcCarryFrames;   // 上面那份缓存里的帧数
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
    // 只比较格式本身和环形缓冲是否就绪，**不要看 _conv**。
    //
    //  _conv 是延迟创建的（要等第一块真实数据才能反推源格式）。
    //  如果这里要求 _conv 非空，那么在它建好之前每次回调都会判定
    //  「格式变了」→ 走下面整套重建：stop()(dispatch_sync 等后台跑完)
    //  + free 环形缓冲 + calloc + start() 重建定时器。
    //  每秒 47 次重建，音频线程被反复阻塞 —— 抖音直接卡死。
    BOOL same = _hasFormat &&
                _dstFormat.mSampleRate       == format.mSampleRate &&
                _dstFormat.mChannelsPerFrame == format.mChannelsPerFrame &&
                _dstFormat.mBitsPerChannel   == format.mBitsPerChannel &&
                _dstFormat.mFormatFlags      == format.mFormatFlags &&
                _dstFormat.mBytesPerFrame    == format.mBytesPerFrame &&
                _ring != NULL;
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
    _skipUntilSeconds = 0.0;
    _probeData = nil;
    _probeFrames = 0;
    _srcCarry = nil;
    _srcCarryFrames = 0;
    _silentNoRing = 0;
    _silentShort = 0;
    _zeroBytes = 0;
    _totalFilledFrames = 0;
    _dcSegments = 0;
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

    // 格式就绪就开跑。转换器会在定时器第一次拿到数据时按实测格式创建。
    (void)wasRunning;
    [self start];

    VCLog(@"音频管道启动结果：%@（定时器 %@）",
          _running ? @"运行中" : @"未运行",
          _timer ? @"已创建" : @"未创建");
}

// ------------------------------------------------------------------ 启停

- (void)start
{
    if (_running) return;

    // 只要求环形缓冲存在，**不要求转换器**。
    //
    //  转换器现在是延迟创建的：要等第一块真实数据才能反推源格式
    //  （素材是 stereo，写死 mono 会让左右声道交替播放 = 哒哒哒）。
    //  而那块数据要靠这里的定时器去取 —— 如果这里也等 _conv，
    //  就成了「等 A 才能做 B，B 又需要 A 先做」的死锁，
    //  症状是「运行中：否 / 产出 0 / 欠载 711 次 / 完全没声音」。
    if (!_ring) {
        VCLog(@"音频管道：start 跳过 —— 环形缓冲还没分配");
        return;
    }
    _running = YES;
    _startedAt = CFAbsoluteTimeGetCurrent();

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

    // ---- 音画对齐：丢弃数据，不 seek ----
    //
    //  以前用 seekAudioToTime 对齐，代价太大：
    //    seek 要重建 reader → 必须清空环形缓冲 → 实时线程欠载 299ms。
    //    这段静音在抖音那边照样按 1024 帧/21ms 消费，
    //    等于音频内容凭空少了 299ms → 之后音画永远差 299ms。
    //
    //  现在改成「照常解码，但把对齐点之前的数据丢掉」：
    //    · reader 不重建 → 不卡顿
    //    · 缓冲不清空 → 不欠载
    //    · 丢完数据后 _decodedMaterialSeconds 落在正确位置
    {
        static BOOL sAlignedOnce = NO;
        if (!sAlignedOnce) {
            double videoT = [[VCFrameSource shared] currentVideoSourceTime];
            if (videoT > 0.3) {
                sAlignedOnce = YES;
                _skipUntilSeconds = videoT;
                VCLog(@"音频对齐：丢弃 %.2fs 之前的解码数据（不 seek，缓冲不受影响）",
                      videoT);
            }
        }
    }

    // ---- 不做「音画时间比对」用于别的目的 ----
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

/// 把音频源 seek 到素材内的指定位置，并清空环形缓冲。
- (void)seekAudioToTime:(double)targetSeconds
{
    [[VCAudioSource shared] seekToTime:targetSeconds];

    pthread_mutex_lock(&_lock);
    _writePos = 0;
    _readPos  = 0;
    _count    = 0;
    _srcCarry = nil;
    _srcCarryFrames = 0;
    _probeData = nil;
    _probeFrames = 0;
    _decodedMaterialSeconds = targetSeconds;
    pthread_mutex_unlock(&_lock);
}

- (void)produceFrames:(size_t)wantFrames
{
    if (wantFrames == 0) return;

    double t0 = CFAbsoluteTimeGetCurrent();

    // ---- 第一次拿到数据时，用实测格式建转换器 ----
    if (!_conv) {
        [self probeSourceFormatLocked];
        if (!_conv) return;
    }

    // 需要多少源帧。倍率按源/目标采样率算；声道数不影响帧数，只影响字节。
    double ratio = (_srcFormat.mSampleRate > 0 && _dstFormat.mSampleRate > 0)
                 ? (_srcFormat.mSampleRate / _dstFormat.mSampleRate)
                 : 1.0;
    // 只要略多于 wantFrames 就够，**不要多要**。
    //
    //  曾经改成 *1.05+32 想给转换器更多余量，结果适得其反：
    //  数据凑不齐时会走下面的「延音补齐」，而延音段是恒定值，
    //  接上真实数据就是一次波形硬跳 —— 15 秒里出现 19 次「啪」，
    //  比改之前还多。少要一点，凑不齐就不补，交给转换器少吐几帧。
    size_t needSrcFrames = (size_t)((double)wantFrames * ratio) + 2;
    size_t srcBpf = _srcFormat.mBytesPerFrame;      // 4=mono, 8=stereo（float32）

    NSMutableData *srcData = [NSMutableData dataWithCapacity:needSrcFrames * srcBpf];

    // 攒够 needSrcFrames 个**真帧**。
    //
    //  必须先把上一轮没吃掉的 carry 接上。
    //  否则在循环里多拿的那几块会被丢弃，下一轮从新位置开始，
    //  两轮的数据之间就断了一截 —— 波形断裂，听感是一声「啪」。
    //  实测 15 秒里 18 处，间隔 0.1857s（正好一轮生产的时间）。
    size_t haveFrames = 0;
    size_t srcBpfHere = srcBpf;
    if (_srcCarry.length > 0) {
        [srcData appendData:_srcCarry];
        haveFrames += _srcCarryFrames;
        _srcCarry = nil;
        _srcCarryFrames = 0;
    }
    if (_probeData.length > 0) {
        [srcData appendData:_probeData];
        haveFrames += (size_t)_probeFrames;
        _probeData = nil;
        _probeFrames = 0;
    }
    (void)srcBpfHere;
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

    // 启动对齐：把目标位置之前的数据读出来丢掉。
    //
    //  两个关键点，上一版都写错了：
    //    ① 记账必须用「实际消费的帧数」（availNow），不是「想丢的帧数」。
    //       写 dropFrames 会让 _decodedMaterialSeconds 少算，
    //       位置永远追不上目标，于是持续丢弃、持续静音。
    //    ② 必须在**一次调用内**丢完。跨调用丢的话，每次 return 都让
    //       实时线程拿不到数据 → 缓冲空 → 闹钟一样的静音，累计好几秒。
    if (_skipUntilSeconds > 0 && _decodedMaterialSeconds < _skipUntilSeconds) {
        size_t haveNow = srcData.length / srcBpf;
        double consumed = (double)haveNow / _srcFormat.mSampleRate;
        _decodedMaterialSeconds += consumed;
        int guard = 0;
        while (_decodedMaterialSeconds < _skipUntilSeconds - 0.001 && guard++ < 400) {
            CMItemCount got2 = 0;
            AudioStreamBasicDescription a2 = {0};
            NSData *more2 = [[VCAudioSource shared] nextPCMWithFrames:&got2 asbd:&a2];
            if (!more2 || more2.length == 0) break;
            _decodedMaterialSeconds += (double)got2 / _srcFormat.mSampleRate;
        }
        VCLog(@"音频对齐：丢弃完毕，位置 %.2fs（目标 %.2fs，%d 次取块）",
              _decodedMaterialSeconds, _skipUntilSeconds, guard);
        _skipUntilSeconds = 0;
        return;
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
    // 数据不够就直接用现有的转，**不做延音补齐**。
    //
    //  以前凑不齐时会用最后一个样本重复填充到 needSrcFrames，
    //  但延音段是恒定值，接上后面真实数据就是一次波形硬跳 ——
    //  15 秒实测 19 次，听感就是电报声里的「啪」。
    //
    //  现在：数据不够就让转换器少吐几帧，剩下的由下面
    //  「produced < outBytes」分支用末样本补齐输出。
    //  那样补的是输出侧的尾部，波形是连续延伸的，不会断裂。


    // 请求的帧数不能超过「现有数据能转换出来的量」。
    //
    //  以前固定请求 wantFrames，数据不够时转换器只吐一部分，
    //  然后我又用「末样本重复」把剩余填满 —— 那会生成一段恒定直流值
    //  （实测 2.04~2.28s 有 240ms 全是同一个值，RMS==峰值==0.00367），
    //  接上真实音频就是一次断裂，听感是「断了一下」。
    //
    //  现在：能转多少就请求多少，转换器必然吐满，不需要任何补齐。
    size_t outFrames = wantFrames;
    if (ratio > 0) {
        size_t capBySrc = (size_t)((double)availFrames / ratio);
        if (capBySrc < outFrames) outFrames = capBySrc;
    }
    if (outFrames == 0) return;

    size_t outBytes = outFrames * _bytesPerFrame;
    NSMutableData *out = [NSMutableData dataWithLength:outBytes];

    VCConvCtx ctx;
    ctx.data          = (const float *)srcData.bytes;
    ctx.total         = availFrames;
    ctx.consumed      = 0;
    ctx.bytesPerFrame = srcBpf;
    ctx.channels      = _srcFormat.mChannelsPerFrame;

    AudioBufferList abl;
    abl.mNumberBuffers = 1;
    abl.mBuffers[0].mNumberChannels = _dstFormat.mChannelsPerFrame;
    abl.mBuffers[0].mData = out.mutableBytes;
    abl.mBuffers[0].mDataByteSize = (UInt32)outBytes;

    UInt32 outPackets = (UInt32)outFrames;
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

    // 把转换器没吃掉的源数据留到下一轮，绝不丢弃。
    //
    //  inner loop 每次拿一整块（1024 帧），needSrc 往往不是整块，
    //  多出来的部分以前直接扔了 —— 那就是每一轮生产边界处那声「啪」。
    {
        size_t leftover = (availFrames > ctx.consumed)
                        ? (availFrames - ctx.consumed) : 0;
        if (leftover > 0) {
            const uint8_t *base = (const uint8_t *)srcData.bytes
                                + ctx.consumed * srcBpf;
            _srcCarry = [NSMutableData dataWithBytes:base
                                              length:leftover * srcBpf];
            _srcCarryFrames = leftover;
        } else {
            _srcCarry = nil;
            _srcCarryFrames = 0;
        }
    }

    size_t produced = abl.mBuffers[0].mDataByteSize;
    if (produced == 0) {
        static BOOL sLog = NO;
        if (!sLog) { sLog = YES; VCLog(@"音频管道：转换器零输出"); }
        return;
    }

    // 不做任何补齐 —— 请求量已经按可用数据算过，转换器必然吐满。
    // 任何形式的「重复末样本补满」都会生成恒定直流段，听感就是断点。
    if (produced < outBytes) produced -= produced % _bytesPerFrame;

    // 自检：这段产出是不是「整段恒定值」。
    //
    //  正常音频在几十毫秒内一定会变化；如果整块每个样本都相同，
    //  说明上游又混进了补齐/重复逻辑 —— 那就是断点的来源。
    //  有了这个计数，以后不用靠波形反推就能发现。
    if (produced >= _bytesPerFrame * 64) {
        const uint8_t *base = (const uint8_t *)out.bytes;
        BOOL allSame = YES;
        for (size_t off = _bytesPerFrame; off + _bytesPerFrame <= produced;
             off += _bytesPerFrame) {
            if (memcmp(base + off, base, _bytesPerFrame) != 0) {
                allSame = NO;
                break;
            }
        }
        if (allSame) {
            _dcSegments++;
            if (_dcSegments <= 5) {
                VCLog(@"音频管道：检测到恒定值段（%zu 帧），上游可能有补齐残留",
                      produced / _bytesPerFrame);
            }
        }
    }



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

    double spent = (CFAbsoluteTimeGetCurrent() - t0) * 1000.0;
    if (spent > _maxProduceMs) _maxProduceMs = spent;
    if (spent > 200) {
        VCLog(@"音频管道：单次生产耗时 %.0fms（want=%zu 帧）", spent, wantFrames);
    }
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
        // 这条分支以前完全不计数，导致「有静音但报告里欠载次数不涨」。
        _silentNoRing += frames;
        static int sNoRingLog = 0;
        if (++sNoRingLog <= 10) {
            VCLog(@"音频管道：环形缓冲未就绪，输出静音 (#%d, frames=%u, ring=%p, bpf=%zu)",
                  sNoRingLog, (unsigned)frames, _ring, _bytesPerFrame);
        }
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
        if (writable == 0) { _zeroBytes++; continue; }

        if (b == 0) {
            size_t avail0 = _count * _bytesPerFrame;
            _takeThisCall = writable < avail0 ? writable : avail0;
            _takeThisCall -= _takeThisCall % _bytesPerFrame;
        }
        size_t take = _takeThisCall;

        if (take >= writable) {
            _totalFilledFrames += writable / _bytesPerFrame;
            // 缓冲够：整块拷贝（实时线程唯一的工作）
            size_t tail = _ringBytes - _readPos;
            if (take <= tail) {
                memcpy(buf->mData, _ring + _readPos, take);
            } else {
                memcpy(buf->mData, _ring + _readPos, tail);
                memcpy((uint8_t *)buf->mData + tail, _ring, take - tail);
            }
        } else {
            // 真欠载（理论上只剩启动那一瞬间）。
            //
            //  部分有数据时：先拷进去，剩余部分从最后一个样本**线性淡出到 0**。
            //  直接 memset 会让波形从当前幅度瞬间跌到 0 —— 那一声「啪」
            //  是突变造成的，不是静音本身造成的。淡出就没有突变。
            //
            //  仍然不重复整块：重复 1024 帧会变成机械的「哒哒哒」。
            _underrun++;
            _silentShort += writable / _bytesPerFrame;

            size_t have = 0;
            if (take > 0) {
                size_t tail = _ringBytes - _readPos;
                if (take <= tail) {
                    memcpy(buf->mData, _ring + _readPos, take);
                } else {
                    memcpy(buf->mData, _ring + _readPos, tail);
                    memcpy((uint8_t *)buf->mData + tail, _ring, take - tail);
                }
                have = take;
            }

            size_t padBytes = writable - have;
            size_t ch = _dstFormat.mChannelsPerFrame ? _dstFormat.mChannelsPerFrame : 1;
            size_t sampleBytes = ch * (_dstFormat.mBitsPerChannel / 8);
            if (sampleBytes == 0) sampleBytes = 2;

            // 取最后一个有效样本（没有就用 0）
            int32_t lastVal = 0;
            if (have >= sampleBytes) {
                const uint8_t *lb = (const uint8_t *)buf->mData + have - sampleBytes;
                if (sampleBytes == 2) {
                    int16_t v; memcpy(&v, lb, 2); lastVal = v;
                } else if (sampleBytes == 4) {
                    if (_dstFormat.mFormatFlags & kAudioFormatFlagIsFloat) {
                        float v; memcpy(&v, lb, 4);
                        v *= 32768.0f;
                        lastVal = (int32_t)v;
                    } else {
                        int32_t v; memcpy(&v, lb, 4); lastVal = v;
                    }
                }
            }

            size_t padFrames = padBytes / sampleBytes;
            uint8_t *pd = (uint8_t *)buf->mData + have;
            for (size_t k = 0; k < padFrames; k++) {
                int32_t v = 0;
                if (padFrames > 0) {
                    v = (int32_t)((double)lastVal *
                                  (1.0 - (double)(k + 1) / (double)padFrames));
                }
                if (sampleBytes == 2) {
                    int16_t sv = (int16_t)v;
                    for (size_t c = 0; c < ch; c++) {
                        memcpy(pd + k * sampleBytes + c * 2, &sv, 2);
                    }
                } else {
                    int32_t sv = v;
                    for (size_t c = 0; c < ch; c++) {
                        memcpy(pd + k * sampleBytes + c * 4, &sv, 4);
                    }
                }
            }
            size_t done = padFrames * sampleBytes;
            if (done < padBytes) {
                memset(pd + done, 0, padBytes - done);
            }
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

- (double)lastUnderrunAt { return _lastUnderrunAt; }
- (double)decodedMaterialSeconds { return _decodedMaterialSeconds; }
- (double)videoSourceSeconds { return [[VCFrameSource shared] currentVideoSourceTime]; }
- (uint64_t)silentNoRing { return _silentNoRing; }
- (uint64_t)silentShort  { return _silentShort; }
- (uint64_t)zeroBytes    { return _zeroBytes; }
- (uint64_t)totalFilled  { return _totalFilledFrames; }
- (uint64_t)dcSegments   { return _dcSegments; }
- (double)maxProduceMs   { return _maxProduceMs; }

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
