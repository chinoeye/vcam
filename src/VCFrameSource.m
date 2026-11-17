//
//  VCFrameSource.m
//

#import "VCFrameSource.h"
#import "VCSampleBufferFactory.h"
#import "VCamConfig.h"
#import "VCLog.h"

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
}

- (BOOL)restartVideoReaderLocked;
- (BOOL)restartAudioReaderLocked;
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
        _pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange;
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
- (NSTimeInterval)currentVideoSourceTime { return _videoSourceSeconds; }

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

        NSDictionary *opts = @{
            AVURLAssetPreferPreciseDurationAndTimingKey: @YES,
            AVURLAssetAllowsCellularAccessKey: @YES,
        };
        _asset = [AVURLAsset URLAssetWithURL:url options:opts];
        _currentURL = url;

        AVAssetTrack *vtrack = [[_asset tracksWithMediaType:AVMediaTypeVideo] firstObject];
        if (!vtrack) {
            if (error) *error = [NSError errorWithDomain:@"VCam" code:2
                                 userInfo:@{NSLocalizedDescriptionKey: @"素材里没有视频轨"}];
            VCLog(@"素材无视频轨: %@", url.lastPathComponent);
            return NO;
        }

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
    if (!_ready || VCamConfig.shared.paused) return NULL;

    CVPixelBufferRef result = NULL;
    [_lock lock];
    @try {
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
    _videoSourceSeconds = 0.0;

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
//  0.25 太紧：稍微超前或落后就 return nil 拒绝供数据，上层补静音，
//  听感是「中间有一两声断音」；0.5 只是把断音从 3 秒推到 8 秒。
//
//  根因是 48000/44100 的换算让推算时间比实际播放快约 8.8%，偏差持续累积。
//  在没找到不引入死锁的精确时钟方案之前，先把阈值放到足够大 ——
//  让同步逻辑基本不触发，宁可接受慢漂移（素材 16 秒就回绕重置），
//  也不要周期性断音。
#define VC_AV_MAX_DRIFT 30.0
#define VC_AV_CATCHUP_SLACK 0.10
#define VC_AV_CATCHUP_GUARD 128

- (NSData *)copyNextAudioPCMWithFrameCount:(CMItemCount *)frameCountOut
                                      asbd:(AudioStreamBasicDescription *)asbdOut
{
    if (!_ready || !_audioReader || VCamConfig.shared.audioMode != VCAudioModeAsset) {
        return nil;
    }

    [_lock lock];
    NSData *result = nil;
    @try {
        if (_audioReader.status != AVAssetReaderStatusReading) {
            [self restartAudioReaderLocked];
        }
        if (!_audioReader || _audioReader.status != AVAssetReaderStatusReading) {
            return nil;
        }

        double videoT = _videoSourceSeconds;

        // 用「已读源样本数 / 源采样率」估算素材内的音频位置。
        //
        // 曾经试过改用外部回报的「实际播放时间」，但那会造成死锁：
        // 播放时间只在成功转换后才更新，而它又是判断能否转换的前提 ——
        // 视频先跑起来后 videoT 已经几百毫秒，音频位置还是 0，
        // 被判为「严重落后」→ 追赶 → return nil → 时间永不更新 → 彻底无声。
        //
        // 所以这里保持按源样本数推算。速率偏差交给下面的阈值兜底。
        double readerT = (double)_audioSamplesRead / _audioSampleRate;

        // ---- 超前：原地等，不消耗数据 ----
        if (readerT > videoT + VC_AV_MAX_DRIFT) {
            return nil;
        }

        // ---- 落后：快速读并丢弃，把读指针追到视频附近 ----
        if (readerT < videoT - VC_AV_MAX_DRIFT) {
            int guard = 0;
            while (guard++ < VC_AV_CATCHUP_GUARD) {
                double cur = (double)_audioSamplesRead / _audioSampleRate;
                if (cur >= videoT - VC_AV_CATCHUP_SLACK) break;

                CMSampleBufferRef skip = [_audioOutput copyNextSampleBuffer];
                if (!skip) break;
                _audioSamplesRead += CMSampleBufferGetNumSamples(skip);
                CFRelease(skip);
            }
            VCLogVerbose(@"音频追赶：%.0fms -> %.0fms",
                         readerT * 1000, (double)_audioSamplesRead / _audioSampleRate * 1000);
            // 本次不输出，让 proxy 丢掉这一帧音频
            return nil;
        }

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

        VCLog(@"音频已对齐到视频位置 %.2fs", v);
    } @finally {
        [_lock unlock];
    }
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
