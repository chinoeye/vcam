//
//  VCFrameSource.m
//

#import "VCFrameSource.h"
#import "VCSampleBufferFactory.h"
#import "VCamConfig.h"
#import "VCLog.h"

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
    }
    return self;
}

- (BOOL)isReady   { return _ready; }
- (NSUInteger)frameCount { return _frameCount; }
- (CGFloat)sourceAspectRatio { return _aspect; }

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
                AVLinearPCMIsNonInterleaved: @NO,
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

- (BOOL)restartVideoReaderLocked
{
    AVAssetTrack *vtrack = [[_asset tracksWithMediaType:AVMediaTypeVideo] firstObject];
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
    return YES;
}

// ------------------------------------------------------------------ 音频拉取

- (NSData *)copyNextAudioPCMWithFrameCount:(CMItemCount *)frameCountOut
                                      asbd:(AudioStreamBasicDescription *)asbdOut
{
    if (!_ready || !_audioReader) return nil;

    [_lock lock];
    NSData *result = nil;
    @try {
        if (_audioReader.status != AVAssetReaderStatusReading) {
            [self restartAudioReaderLocked];
        }
        if (!_audioReader || _audioReader.status != AVAssetReaderStatusReading) {
            return nil;
        }

        CMSampleBufferRef raw = [_audioOutput copyNextSampleBuffer];
        if (!raw) {
            [self restartAudioReaderLocked];
            raw = [_audioOutput copyNextSampleBuffer];
        }
        if (!raw) return nil;

        CMBlockBufferRef block = CMSampleBufferGetDataBuffer(raw);
        CMItemCount frames = CMSampleBufferGetNumSamples(raw);
        CMFormatDescriptionRef fmt = CMSampleBufferGetFormatDescription(raw);

        const AudioStreamBasicDescription *asbd =
            CMAudioFormatDescriptionGetStreamBasicDescription(fmt);
        if (asbd && asbdOut) *asbdOut = *asbd;

        if (block) {
            size_t len = CMBlockBufferGetDataLength(block);
            NSMutableData *buf = [NSMutableData dataWithLength:len];
            if (CMBlockBufferCopyDataBytes(block, 0, len, buf.mutableBytes) == kCMBlockBufferNoErr) {
                result = buf;
                if (frameCountOut) *frameCountOut = frames;
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
        AVLinearPCMIsNonInterleaved: @NO,
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
