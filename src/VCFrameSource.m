//
//  VCFrameSource.m
//

#import "VCFrameSource.h"
#import "VCSampleBufferFactory.h"
#import "VCamConfig.h"
#import "VCLog.h"
#import "VCAudioSource.h"   // 回绕时要用 VCAudioSourceShouldResetNotification

#import <math.h>

@interface VCFrameSource ()
{
    AVAsset *_asset;
    AVAssetReader *_videoReader;
    AVAssetReaderTrackOutput *_videoOutput;

    AVAssetReader *_audioReader;
    AVAssetReaderTrackOutput *_audioOutput;

    NSLock *_lock;
    BOOL _ready;
    NSUInteger _frameCount;
    CGFloat _aspect;
    NSURL *_currentURL;

    // ---- 音画同步状态 ----
    // 视频和音频是两条独立的 AVAssetReader，谁也不看谁。
    // 一旦任何一边丢一次回调，两条轨道的源位置就错开，而且误差只累加不纠正。
    // 这组变量用来把音频强行钉在视频的时间轴上。
    double _videoSourceSeconds;      // 当前视频帧在源文件中的位置
    uint64_t _audioSamplesOut;       // 已输出给 App 的音频样本总数
    uint64_t _audioSamplesRead;      // 已从 reader 读出的样本总数（含被丢弃的）
    double _audioSampleRate;
    NSTimeInterval _assetDuration;   // 素材总时长（秒），音画折返用
    CVPixelBufferRef _pendingPB;     // seek 探针留下的那一帧，优先返回
}

- (BOOL)restartVideoReaderLocked;
- (BOOL)restartAudioReaderLocked;
- (void)seekAudioToVideoTimeLocked;
- (void)teardownLocked;
- (void)notify:(NSString *)status;

@end

@implementation VCFrameSource

+ (instancetype)shared
{
    static VCFrameSource *inst = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        inst = [[VCFrameSource alloc] init];
    });
    return inst;
}

- (instancetype)init
{
    if ((self = [super init])) {
        _lock = [[NSLock alloc] init];
        // ★ 解码输出用 BGRA，而不是 420v。
        //
        //  原因：素材是 BT.709（1080p 惯例），系统采集 buffer 声明 BT.601（720p 惯例）。
        //  VTPixelTransferSession 做 YUV→YUV 时**不查矩阵**（实测：给它挂
        //  kCVImageBufferYCbCrMatrixKey 也没用），只做缩放和 range 扩展 ——
        //  于是 709 编出来的数据被当 601 解释：绿区变亮约 20%、红区变暗，
        //  暖色为主的直播间画面整体提亮发白。
        //
        //  改成让解码器输出 RGB（AVAssetReader 会按素材自己的 709 声明正确转），
        //  再由 VT 做 RGB→YUV(601)。RGB→YUV 这一步 VT 按目标分辨率选矩阵，可靠。
        //  顺带省掉 YUV→YUV 来回下采样的色度损失。
        _pixelFormat = kCVPixelFormatType_32BGRA;
        _fps = 30.0;
        _aspect = 1080.0 / 1920.0;
        _audioSampleRate = 48000.0;
        _videoSourceSeconds = 0.0;
        _audioSamplesOut = 0;
        _audioSamplesRead = 0;
    }
    return self;
}

- (BOOL)isReady   { return _ready; }
- (NSUInteger)frameCount { return _frameCount; }
- (CGFloat)sourceAspectRatio { return _aspect; }
- (CGFloat)sourceFrameRate { return _fps > 1.0 ? _fps : 30.0; }
- (NSTimeInterval)currentVideoSourceTime { return _videoSourceSeconds; }
- (NSTimeInterval)assetDuration { return _assetDuration; }

// ------------------------------------------------------------------ 视频 seek（音画对齐用）

int g_vcVideoSeekCount = 0;
static volatile BOOL g_videoSeeking = NO;   // 有 seek 在跑（避免排队）

- (void)seekVideoToTime:(NSTimeInterval)t
{
    if (!isfinite(t) || t < 0) return;
    if (g_videoSeeking) return;             // 已经有一次在跑了，别排队

    // ★ 必须异步。
    //
    //  600 秒 / 348 MB 的素材上重建 AVAssetReader（cancelReading + init +
    //  startReading + 定位）实测要几百毫秒。以前这在采集回调线程里同步做，
    //  AVCaptureVideoDataOutput 的队列直接被按死 —— 现象就是
    //  「预览一切正常，点录制立刻卡死」（音画对齐第一次 seek 正好发生在这一刻）。
    //
    //  现在丢到串行队列去做，采集线程拿不到锁就跳过这一帧（复用上一帧），
    //  画面最多停几帧，不会卡死。
    static dispatch_queue_t seekQueue;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        seekQueue = dispatch_queue_create("vcam.video.seek", DISPATCH_QUEUE_SERIAL);
    });

    g_videoSeeking = YES;
    dispatch_async(seekQueue, ^{
        double t0 = CACurrentMediaTime();
        [self->_lock lock];
        @try {
            if (!self->_ready || !self->_asset) return;

            AVAssetTrack *vtrack = [[self->_asset tracksWithMediaType:AVMediaTypeVideo] firstObject];
            if (!vtrack) return;

            @try { [self->_videoReader cancelReading]; } @catch (NSException *e) {}

            NSError *err = nil;
            self->_videoReader = [[AVAssetReader alloc] initWithAsset:self->_asset error:&err];
            self->_videoOutput = nil;
            if (!self->_videoReader) {
                VCLog(@"视频 seek 失败: %@", err);
                self->_ready = NO;
                return;
            }

            NSDictionary *vsettings = @{
                (id)kCVPixelBufferPixelFormatTypeKey: @(self->_pixelFormat),
                (id)kCVPixelBufferIOSurfacePropertiesKey: @{},
                // 让解码器直接输出 720x1280，别先解 1080p 再缩。
                //  BGRA 1080p 一帧 8 MB，30fps = 240 MB/s 内存带宽，
                //  采集线程 33ms 预算被吃干净 → 画面卡顿感。
                //  720p BGRA 只有 3.7 MB，VT 那道缩放也省了。
                (id)kCVPixelBufferWidthKey:  @(720),
                (id)kCVPixelBufferHeightKey: @(1280),
            };
            self->_videoOutput = [[AVAssetReaderTrackOutput alloc]
                            initWithTrack:vtrack outputSettings:vsettings];
            self->_videoOutput.alwaysCopiesSampleData = YES;
            if (![self->_videoReader canAddOutput:self->_videoOutput]) return;
            [self->_videoReader addOutput:self->_videoOutput];

            // 从目标位置起读
            self->_videoReader.timeRange = CMTimeRangeMake(CMTimeMakeWithSeconds(t, 1000),
                                                      kCMTimePositiveInfinity);
            if (![self->_videoReader startReading]) {
                VCLog(@"视频 seek 启动失败: %@", self->_videoReader.error);
                self->_ready = NO;
                return;
            }

            self->_videoSourceSeconds = t;
            g_vcVideoSeekCount++;

            // 探针：立刻从新 reader 取一帧，确认真的能读。
            //  以前只看 startReading 的返回值就当成功了，但 startReading 成功
            //  不等于 copyNextSampleBuffer 能出帧（timeRange 起点越界、reader
            //  被上层状态拖住都会返回 nil），而外层只看到「位置被赋值了」，
            //  于是每秒 seek 一次、每秒画面不动 —— 实测就是这个症状。
            CMSampleBufferRef probe = [self->_videoOutput copyNextSampleBuffer];
            if (probe) {
                CMTime pts = CMSampleBufferGetPresentationTimeStamp(probe);
                double at = CMTIME_IS_VALID(pts) ? CMTimeGetSeconds(pts) : -1.0;
                // 顺手把这一帧留下来当下一次输出：seek 之后画面要立刻跟上位置，
                //  否则「位置已经跳过去了、画面还是旧的」会持续一整帧。
                CVPixelBufferRef pb = CMSampleBufferGetImageBuffer(probe);
                if (pb) {
                    if (self->_pendingPB) CVPixelBufferRelease(self->_pendingPB);
                    self->_pendingPB = CVPixelBufferRetain(pb);
                }
                VCLog(@"seek 后取帧正常：目标 %.2f s，首帧 PTS %.3f s", t, at);
                CFRelease(probe);
            } else {
                VCLog(@"seek 后取帧失败：目标 %.2f s，status=%ld，error=%@",
                      t, (long)self->_videoReader.status,
                      self->_videoReader.error.localizedDescription ?: @"无");
            }

            // 注意：这里**不碰音频 reader**。
            // restartVideoReaderLocked 会把音频一起拉回 0，那是「素材回绕」的语义；
            // 音画对齐只该挪视频，否则两条轨道互相拽，永远收敛不了。
        } @finally {
            [self->_lock unlock];
        }
        double ms = (CACurrentMediaTime() - t0) * 1000.0;
        g_videoSeeking = NO;
        VCLog(@"视频 seek 完成：目标 %.2f s，耗时 %.0f ms（累计 %d 次）",
              t, ms, g_vcVideoSeekCount);
    });
}

// ------------------------------------------------------------------ 装载

- (BOOL)reloadWithURL:(NSURL *)url error:(NSError **)error
{
    if (!url) {
        if (error) *error = [NSError errorWithDomain:@"VCam" code:1
                             userInfo:@{NSLocalizedDescriptionKey: @"素材 URL 为空"}];
        return NO;
    }

    [_lock lock];
    @try {
        [self teardownLocked];

        // HTTP 源不要开 PreferPreciseDurationAndTiming。
        //
        //  那个选项要求「精确时长和时间戳」，AVFoundation 会去加载完整索引
        //  （6.5 GB 素材的 moov 有 13 MB，加上逐轨解析），在 WiFi 上很容易
        //  卡十几秒 —— 足以让系统 watchdog 把抖音判为无响应并杀掉。
        //  症状就是：进录制页黑屏 → 闪退。
        //
        //  本地文件保留精确模式（本来就在本地，解析很快）。
        BOOL isRemote = (url.scheme.length > 0 &&
                         ![url.scheme isEqualToString:@"file"]);
        NSDictionary *opts = isRemote
            ? @{ AVURLAssetAllowsCellularAccessKey: @YES }
            : @{ AVURLAssetPreferPreciseDurationAndTimingKey: @YES,
                 AVURLAssetAllowsCellularAccessKey: @YES };
        VCLog(@"装载素材：%@（%@）", url.absoluteString,
              isRemote ? @"远程，非精确模式" : @"本地，精确模式");
        _asset = [AVURLAsset URLAssetWithURL:url options:opts];
        _currentURL = url;

        AVAssetTrack *vtrack = [[_asset tracksWithMediaType:AVMediaTypeVideo] firstObject];
        if (!vtrack) {
            if (error) *error = [NSError errorWithDomain:@"VCam" code:2
                                 userInfo:@{NSLocalizedDescriptionKey: @"素材里没有视频轨"}];
            VCLog(@"素材无视频轨: %@", url.lastPathComponent);
            return NO;
        }

        _fps = (vtrack.nominalFrameRate > 1.0f) ? vtrack.nominalFrameRate : 30.0;
        VCLog(@"素材帧率 %.2f fps", _fps);

        // 素材时长：音画对齐折返要用。
        // 远程 HTTP 源 asset.duration 可能不准，轨道 timeRange 更可靠，优先用它。
        _assetDuration = 0.0;
        CMTimeRange tr = vtrack.timeRange;
        if (CMTIME_IS_VALID(tr.duration) && CMTIME_IS_NUMERIC(tr.duration)) {
            _assetDuration = CMTimeGetSeconds(tr.duration);
        }
        if (!(_assetDuration > 0.0)) {
            CMTime d = _asset.duration;
            if (CMTIME_IS_VALID(d) && CMTIME_IS_NUMERIC(d)) {
                _assetDuration = CMTimeGetSeconds(d);
            }
        }
        VCLog(@"素材时长 %.2f s", _assetDuration);

        CGSize size = vtrack.naturalSize;
        if (size.width > 0 && size.height > 0) {
            _aspect = size.width / size.height;
        }

        _videoReader = [[AVAssetReader alloc] initWithAsset:_asset error:error];
        if (!_videoReader) return NO;

        // alwaysCopiesSampleData 保持 YES：
        // 让 reader 每次给我们独立的 pixelBuffer，避免下一帧解码覆盖上一帧（会撕裂）
        NSDictionary *vsettings = @{
            (id)kCVPixelBufferPixelFormatTypeKey: @(_pixelFormat),
            (id)kCVPixelBufferIOSurfacePropertiesKey: @{},
            (id)kCVPixelBufferWidthKey:  @(720),
            (id)kCVPixelBufferHeightKey: @(1280),
        };
        _videoOutput = [[AVAssetReaderTrackOutput alloc]
                        initWithTrack:vtrack outputSettings:vsettings];
        _videoOutput.alwaysCopiesSampleData = YES;
        if ([_videoReader canAddOutput:_videoOutput]) {
            [_videoReader addOutput:_videoOutput];
        }
        if (![_videoReader startReading]) {
            if (error) *error = _videoReader.error;
            VCLog(@"视频 reader 启动失败: %@", _videoReader.error);
            return NO;
        }

        // 音频单独一条 reader，循环独立维护
        AVAssetTrack *atrack = [[_asset tracksWithMediaType:AVMediaTypeAudio] firstObject];
        if (atrack) {
            _audioReader = [[AVAssetReader alloc] initWithAsset:_asset error:NULL];
            NSDictionary *asettings = @{
                AVFormatIDKey: @(kAudioFormatLinearPCM),
                AVLinearPCMBitDepthKey: @32,
                AVLinearPCMIsFloatKey: @YES,
                AVLinearPCMIsBigEndianKey: @NO,
                AVLinearPCMIsNonInterleavedKey: @NO,   // 必须带 Key 后缀，否则整个 outputSettings 会被判无效
                AVSampleRateKey: @48000,
                AVNumberOfChannelsKey: @1,
            };
            _audioOutput = [[AVAssetReaderTrackOutput alloc]
                            initWithTrack:atrack outputSettings:asettings];
            _audioOutput.alwaysCopiesSampleData = YES;
            if ([_audioReader canAddOutput:_audioOutput]) {
                [_audioReader addOutput:_audioOutput];
                [_audioReader startReading];
            }
        }

        _ready = YES;
        _frameCount = 0;
        _videoSourceSeconds = 0.0;
        _audioSamplesRead = 0;
        _audioSamplesOut = 0;
        [[VCSampleBufferFactory shared] resetTimeline];

        VCLog(@"素材装载成功: %@  比例 %.3f", url.lastPathComponent, _aspect);
        [self notify:[NSString stringWithFormat:@"源：%@", url.lastPathComponent]];
        return YES;
    } @catch (NSException *e) {
        VCLog(@"装载异常: %@", e.reason);
        if (error) *error = [NSError errorWithDomain:@"VCam" code:9
                             userInfo:@{NSLocalizedDescriptionKey: e.reason ?: @"未知"}];
        return NO;
    } @finally {
        [_lock unlock];
    }
}

// ------------------------------------------------------------------ 视频拉取

- (CMSampleBufferRef)copyNextVideoSampleBuffer
{
    if (!_ready || VCamConfig.shared.paused) return NULL;

    CMSampleBufferRef result = NULL;
    [_lock lock];
    @try {
        // 最多重试两次：一次正常读，一次是读到文件尾后回绕重来
        for (int attempt = 0; attempt < 2 && !result; attempt++) {
            if (!_videoReader || _videoReader.status != AVAssetReaderStatusReading) {
                if (![self restartVideoReaderLocked]) break;
            }

            CMSampleBufferRef raw = [_videoOutput copyNextSampleBuffer];
            if (raw) {
                // 记下这一帧在源文件里的位置。音频侧拿它对表，
                // 这是整条音画同步链的基准点。
                CMTime srcPTS = CMSampleBufferGetPresentationTimeStamp(raw);
                if (CMTIME_IS_VALID(srcPTS)) {
                    double t = CMTimeGetSeconds(srcPTS);
                    if (isfinite(t) && t >= 0) {
                        _videoSourceSeconds = t;
                    }
                }
                result = [[VCSampleBufferFactory shared] retimeSampleBuffer:raw];
                CFRelease(raw);
                _frameCount++;
            } else {
                // 到文件尾：循环回绕，或停下来等切源
                if (VCamConfig.shared.loopEnabled) {
                    [self restartVideoReaderLocked];
                } else {
                    break;
                }
            }
        }
    } @finally {
        [_lock unlock];
    }
    return result;
}

// 只解码，不造 CMSampleBuffer、不重打时间戳。
// 供「原地改写系统摄像头 buffer」路线使用 —— 时间戳由系统那份 buffer 提供，
// 我们只负责把像素换掉。
- (CVPixelBufferRef)copyNextPixelBuffer
{
    if (!_ready) {
        static int sNoReady = 0;
        if (sNoReady++ < 3) VCLog(@"取帧失败：帧源未就绪（_ready=NO）");
        return NULL;
    }
    if (VCamConfig.shared.paused) return NULL;

    CVPixelBufferRef result = NULL;
    // tryLock 而不是 lock：后台正在 seek 时不能把采集线程挂在这儿等。
    //  拿不到锁就返回 NULL，上层复用上一帧继续输出，画面最多停一两帧。
    if (![_lock tryLock]) {
        static int sBusy = 0;
        if (sBusy++ < 3) VCLog(@"取帧失败：帧源锁被后台 seek 占用");
        return NULL;
    }
    @try {
        // seek 刚留下的那一帧优先输出：位置已经跳到目标，画面必须立刻跟上
        if (_pendingPB) {
            result = _pendingPB;
            _pendingPB = NULL;
            return result;
        }
        for (int attempt = 0; attempt < 2 && !result; attempt++) {
            if (!_videoReader || _videoReader.status != AVAssetReaderStatusReading) {
                if (![self restartVideoReaderLocked]) break;
            }

            CMSampleBufferRef raw = [_videoOutput copyNextSampleBuffer];
            if (raw) {
                CMTime srcPTS = CMSampleBufferGetPresentationTimeStamp(raw);
                if (CMTIME_IS_VALID(srcPTS)) {
                    double t = CMTimeGetSeconds(srcPTS);
                    if (isfinite(t) && t >= 0) {
                        _videoSourceSeconds = t;
                    }
                }
                CVPixelBufferRef pb = CMSampleBufferGetImageBuffer(raw);
                if (pb) result = CVPixelBufferRetain(pb);
                CFRelease(raw);
                _frameCount++;
            } else {
                if (VCamConfig.shared.loopEnabled) {
                    [self restartVideoReaderLocked];
                } else {
                    break;
                }
            }
        }
    } @finally {
        [_lock unlock];
    }
    return result;
}

- (BOOL)restartVideoReaderLocked
{    AVAssetTrack *vtrack = [[_asset tracksWithMediaType:AVMediaTypeVideo] firstObject];
    if (!vtrack) return NO;

    @try {
        [_videoReader cancelReading];
    } @catch (NSException *e) {
        // 忽略
    }
    _videoReader = nil;
    _videoOutput = nil;

    NSError *err = nil;
    _videoReader = [[AVAssetReader alloc] initWithAsset:_asset error:&err];
    if (!_videoReader) {
        VCLog(@"回绕失败: %@", err);
        _ready = NO;
        return NO;
    }

    NSDictionary *vsettings = @{
        (id)kCVPixelBufferPixelFormatTypeKey: @(_pixelFormat),
        (id)kCVPixelBufferIOSurfacePropertiesKey: @{},
        (id)kCVPixelBufferWidthKey:  @(720),
        (id)kCVPixelBufferHeightKey: @(1280),
    };
    _videoOutput = [[AVAssetReaderTrackOutput alloc]
                    initWithTrack:vtrack outputSettings:vsettings];
    _videoOutput.alwaysCopiesSampleData = YES;
    if (![_videoReader canAddOutput:_videoOutput]) return NO;
    [_videoReader addOutput:_videoOutput];

    if (![_videoReader startReading]) {
        VCLog(@"回绕启动失败: %@", _videoReader.error);
        _ready = NO;
        return NO;
    }

    // 视频回绕 = 素材从头开始，音频必须跟着回绕。
    // 让两条轨道各自回绕的话，一次循环就错开一整个素材长度。
    [self restartAudioReaderLocked];
    _audioSamplesRead = 0;
    _audioSamplesOut = 0;
    _audioConsumedSourceFrames = 0;   // 循环回绕，消费计数一起归零
    _videoSourceSeconds = 0.0;

    // 视频绕回素材开头 —— 必须通知音频源一起重置，
    //  否则视频在 0 秒而音频还在素材中段，每循环一次就多错一个素材长度。
    [[NSNotificationCenter defaultCenter]
        postNotificationName:VCAudioSourceShouldResetNotification
                      object:nil];

    return YES;
}

// ------------------------------------------------------------------ 音频拉取
//
//  音画同步的核心在这里。
//  视频和音频是两条独立 reader，各自的推进节奏不同，误差只累加不纠正。
//  做法：音频的「读指针」始终被拽向视频的源时间位置——
//    - 落后超过 250ms：快速读、丢弃，把指针追上去
//    - 超前超过 250ms：本次不读，原地等视频追上来
//  阈值取 250ms 是因为低于这个量人耳基本察觉不到口型偏差，
//  而太小的阈值会导致频繁跳帧、听感反而更差。

// 音频与视频允许的最大偏差（秒）。
//
//  这个值决定「音画最多能差多少」，不是「多久断一次」。
//
//  实测每秒会累积约 6% 的时间偏差（48000/44100 换算 + 转换器内部延迟）。
//  15 小时的素材如果不校正，累积偏差能到 50 分钟。
//
//  0.25 秒是「校正得足够勤、又不至于太频繁」的平衡点：
//  偏差一到 250ms 就 seek 回正，人耳察觉不到，seek 频率也很低。
// 音频 seek 校正的累计次数。报告里读它 —— 如果这个数一直涨，
// 说明偏差仍在持续产生，断点就是 seek 造成的。
int g_vcSeekCount = 0;

#define VC_AV_MAX_DRIFT 0.25
#define VC_AV_CATCHUP_SLACK 0.10
#define VC_AV_CATCHUP_GUARD 128

- (NSData *)copyNextAudioPCMWithFrameCount:(CMItemCount *)frameCountOut
                                      asbd:(AudioStreamBasicDescription *)asbdOut
{
    if (VCamConfig.shared.audioMode != VCAudioModeAsset) {
        return nil;
    }

    [_lock lock];
    NSData *result = nil;
    @try {
        // _ready / _audioReader 必须在锁内读 —— reloadWithURL 和 teardown
        // 都会并发改这两个，锁外读会拿到中间状态。
        if (!_ready || !_audioReader) {
            return nil;
        }

        AVAssetReaderStatus st = _audioReader.status;

        if (st == AVAssetReaderStatusFailed || st == AVAssetReaderStatusCancelled) {
            // reader 坏了才重建
            [self restartAudioReaderLocked];
            if (!_audioReader || _audioReader.status != AVAssetReaderStatusReading) {
                return nil;
            }
        } else if (st == AVAssetReaderStatusCompleted) {
            // 读到素材音频末尾，**不自行重启**。
            //
            //  如果这里重启，音频会回到 0 秒，而视频还在 15.98 秒附近，
            //  音画立刻错开大半个素材长度。素材 16 秒、音频轨通常比视频轨
            //  短几十毫秒，所以每轮循环都会触发一次 —— 累积起来越来越偏。
            //
            //  正确做法：等视频回绕（restartVideoReaderLocked 会一起重置音频），
            //  这期间返回 nil，管道会延音过渡。
            return nil;
        } else if (st != AVAssetReaderStatusReading) {
            [self restartAudioReaderLocked];
            if (!_audioReader || _audioReader.status != AVAssetReaderStatusReading) {
                return nil;
            }
        }

        // 这里**不再**限制音频相对视频的偏移。
        //
        //  之前有一段「偏差超过 250ms 就 seek 并 return nil」的逻辑，
        //  现在必须去掉 —— 它跟管道架构直接冲突：
        //
        //    管道想让后台预生产，好让实时线程永远有货可取
        //    但预生产会让 _audioSamplesRead 立刻超过 _videoSourceSeconds
        //    于是被判「音频严重超前」→ return nil → 拒绝供数据
        //    → 后台产不出 → 环形缓冲被消费空 → 每次调用都欠载 → 打电报
        //
        //  正确的做法：时间对齐由「环形缓冲的深度」来保证。
        //  缓冲里存多少帧，就是多少延迟。想让音频不超前，就限制缓冲深度，
        //  而不是禁止解码器往前读。解码器一旦被限制，生产者就断粮了。
        //
        //  视频回绕时仍然会重置音频 reader（见 restartVideoReaderLocked），
        //  所以长期播放不会越跑越偏。

        // ---- 正常区间：读一块输出 ----
        CMSampleBufferRef raw = [_audioOutput copyNextSampleBuffer];
        if (!raw) {
            // 读到素材末尾。不自行回绕 —— 等视频回绕时一起处理，
            // 各回各的会立刻错开一整个素材长度。
            return nil;
        }

        CMBlockBufferRef block = CMSampleBufferGetDataBuffer(raw);
        CMItemCount frames = CMSampleBufferGetNumSamples(raw);
        CMFormatDescriptionRef fmt = CMSampleBufferGetFormatDescription(raw);

        const AudioStreamBasicDescription *asbd =
            CMAudioFormatDescriptionGetStreamBasicDescription(fmt);
        if (asbd && asbdOut) *asbdOut = *asbd;
        if (asbd && asbd->mSampleRate > 0) {
            _audioSampleRate = asbd->mSampleRate;
        }

        if (block) {
            size_t len = CMBlockBufferGetDataLength(block);
            NSMutableData *buf = [NSMutableData dataWithLength:len];
            if (CMBlockBufferCopyDataBytes(block, 0, len, buf.mutableBytes) == kCMBlockBufferNoErr) {
                result = buf;
                if (frameCountOut) *frameCountOut = frames;
                _audioSamplesRead += frames;
                _audioSamplesOut += frames;
            }
        }
        CFRelease(raw);
    } @finally {
        [_lock unlock];
    }
    return result;
}

- (BOOL)restartAudioReaderLocked
{
    AVAssetTrack *atrack = [[_asset tracksWithMediaType:AVMediaTypeAudio] firstObject];
    if (!atrack) return NO;

    @try { [_audioReader cancelReading]; } @catch (NSException *e) {}

    _audioReader = [[AVAssetReader alloc] initWithAsset:_asset error:NULL];
    NSDictionary *asettings = @{
        AVFormatIDKey: @(kAudioFormatLinearPCM),
        AVLinearPCMBitDepthKey: @32,
        AVLinearPCMIsFloatKey: @YES,
        AVLinearPCMIsBigEndianKey: @NO,
        AVLinearPCMIsNonInterleavedKey: @NO,   // 必须带 Key 后缀，否则整个 outputSettings 会被判无效
        AVSampleRateKey: @48000,
        AVNumberOfChannelsKey: @1,
    };
    _audioOutput = [[AVAssetReaderTrackOutput alloc]
                    initWithTrack:atrack outputSettings:asettings];
    _audioOutput.alwaysCopiesSampleData = YES;
    if (![_audioReader canAddOutput:_audioOutput]) return NO;
    [_audioReader addOutput:_audioOutput];
    return [_audioReader startReading];
}

/// 把音频轨道跳到视频当前所在位置。
/// 从「真麦」切到「素材」时必须调用 —— 否则音频 reader 还停在很久以前读到的位置，
/// 切过去声音会从几十秒前的地方接上来，口型完全对不上。
- (void)seekAudioToVideoTime
{
    [_lock lock];
    @try {
        [self seekAudioToVideoTimeLocked];
    } @finally {
        [_lock unlock];
    }
}

/// 内部版：调用方必须已持有 _lock。
///
/// 拆出来的原因：播放过程中的「偏差校正」是在 copyNextAudioPCM 里发起的，
/// 那时已经持锁，再调公开版会二次加锁死掉。
- (void)seekAudioToVideoTimeLocked
{
    if (!_asset) return;

    AVAssetTrack *atrack = [[_asset tracksWithMediaType:AVMediaTypeAudio] firstObject];
    if (!atrack) return;

    double v = _videoSourceSeconds;

    @try { [_audioReader cancelReading]; } @catch (NSException *e) {}

    NSError *err = nil;
    _audioReader = [[AVAssetReader alloc] initWithAsset:_asset error:&err];
    if (!_audioReader) {
        VCLog(@"音频 seek 失败: %@", err);
        return;
    }

    // 往前留 50ms 余量，避免正好卡在音频块边界上丢掉半个包
    CMTime start = CMTimeMakeWithSeconds(MAX(0.0, v - 0.05), 1000);
    _audioReader.timeRange = CMTimeRangeMake(start, kCMTimePositiveInfinity);

    NSDictionary *asettings = @{
        AVFormatIDKey: @(kAudioFormatLinearPCM),
        AVLinearPCMBitDepthKey: @32,
        AVLinearPCMIsFloatKey: @YES,
        AVLinearPCMIsBigEndianKey: @NO,
        AVLinearPCMIsNonInterleavedKey: @NO,   // 必须带 Key 后缀，否则整个 outputSettings 会被判无效
        AVSampleRateKey: @48000,
        AVNumberOfChannelsKey: @1,
    };
    _audioOutput = [[AVAssetReaderTrackOutput alloc] initWithTrack:atrack
                                                   outputSettings:asettings];
    _audioOutput.alwaysCopiesSampleData = YES;
    if (![_audioReader canAddOutput:_audioOutput]) return;
    [_audioReader addOutput:_audioOutput];

    if (![_audioReader startReading]) {
        VCLog(@"音频 seek 启动失败: %@", _audioReader.error);
        return;
    }

    _audioSamplesRead = (uint64_t)(MAX(0.0, v) * _audioSampleRate);
    _audioSamplesOut = _audioSamplesRead;

    // 同步重置「实际消费位置」。
    //
    // 这两个必须一起动：readerT 优先读 _audioConsumedSourceFrames，
    // 如果 seek 只重置 _audioSamplesRead 而不管它，
    // readerT 会停在旧的小值上，被判定为「音频严重落后」→ 立刻再 seek
    // → 永远落后、永远 seek，一个样本都放不出来（实测 254 次调用触发 254 次 seek）。
    _audioConsumedSourceFrames = _audioSamplesRead;
}

// ------------------------------------------------------------------ 生命周期

- (void)rewind
{
    [_lock lock];
    [self restartVideoReaderLocked];
    [self restartAudioReaderLocked];
    [[VCSampleBufferFactory shared] resetTimeline];
    [_lock unlock];
}

- (void)teardown
{
    [_lock lock];
    [self teardownLocked];
    [_lock unlock];
}

- (void)teardownLocked
{
    @try { [_videoReader cancelReading]; } @catch (NSException *e) {}
    @try { [_audioReader cancelReading]; } @catch (NSException *e) {}
    _videoReader = nil;
    _videoOutput = nil;
    _audioReader = nil;
    _audioOutput = nil;
    _asset = nil;
    _currentURL = nil;
    _ready = NO;
    _frameCount = 0;
    if (_pendingPB) { CVPixelBufferRelease(_pendingPB); _pendingPB = NULL; }
}

- (void)notify:(NSString *)status
{
    id<VCFrameSourceDelegate> d = self.delegate;
    if (d && [d respondsToSelector:@selector(frameSource:didChangeStatus:)]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [d frameSource:self didChangeStatus:status];
        });
    }
}

@end
