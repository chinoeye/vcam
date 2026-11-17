//
//  VCAudioSource.m
//
//  独立音频解码器。要点：
//
//  1. 自己的 AVAssetReader，只挂音频轨，和视频那条零共享
//  2. 所有 reader 操作走一个串行队列，外界调 nextPCM 是线程安全的
//  3. 不在锁里做重活：解码本身就在这个串行队列上，不存在"等锁"问题
//  4. 输出保持素材原始格式（float32 / 原声道 / 原采样率），
//     重采样交给 VCAudioPipeline 的 AudioConverter —— 那一层有目标格式
//

#import "VCAudioSource.h"
#import "VCLog.h"

#import <pthread.h>

NSString *const VCAudioSourceShouldResetNotification =
    @"VCAudioSourceShouldResetNotification";

@implementation VCAudioSource
{
    dispatch_queue_t _queue;        // 串行：所有 reader 操作都在这上面

    AVURLAsset              *_asset;
    AVAssetReader           *_reader;
    AVAssetReaderTrackOutput *_output;
    AVAssetTrack            *_track;
    NSURL                   *_url;

    double   _sampleRate;
    uint32_t _channels;
    uint32_t _bitsPerChannel;
    BOOL     _ready;

    uint64_t _delivered;
    uint64_t _underrun;
    int      _consecutiveNil;       // 连续拿不到数据的次数，用于兜底重启
}

+ (instancetype)shared
{
    static VCAudioSource *inst = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        inst = [[VCAudioSource alloc] init];
    });
    return inst;
}

- (instancetype)init
{
    if ((self = [super init])) {
        _queue = dispatch_queue_create("com.yg.vcam.audiosource",
                                       DISPATCH_QUEUE_SERIAL);
        dispatch_set_target_queue(_queue,
            dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0));

        // 视频回绕时跟着回到素材开头，避免音画错开一个素材长度
        __weak typeof(self) weakSelf = self;
        [[NSNotificationCenter defaultCenter]
            addObserverForName:VCAudioSourceShouldResetNotification
                        object:nil
                         queue:nil
                    usingBlock:^(NSNotification *note) {
            [weakSelf reset];
        }];
    }
    return self;
}

// ------------------------------------------------------------------ 加载

- (BOOL)loadURL:(NSURL *)url error:(NSError **)error
{
    if (!url) {
        if (error) *error = [NSError errorWithDomain:@"VCam" code:1
                             userInfo:@{NSLocalizedDescriptionKey: @"素材 URL 为空"}];
        return NO;
    }

    __block BOOL ok = NO;
    __block NSError *inner = nil;

    dispatch_sync(_queue, ^{
        if (self->_url && [self->_url isEqual:url] && self->_ready && self->_reader) {
            ok = YES;                       // 同一个素材，不用重来
            return;
        }

        [self teardownLocked];

        NSDictionary *opts = @{
            AVURLAssetPreferPreciseDurationAndTimingKey: @YES,
            AVURLAssetAllowsCellularAccessKey: @YES,
        };
        self->_asset = [AVURLAsset URLAssetWithURL:url options:opts];
        self->_url = url;

        AVAssetTrack *atrack =
            [[self->_asset tracksWithMediaType:AVMediaTypeAudio] firstObject];
        if (!atrack) {
            inner = [NSError errorWithDomain:@"VCam" code:2
                     userInfo:@{NSLocalizedDescriptionKey: @"素材里没有音频轨"}];
            VCLog(@"音频源：素材无音频轨 %@", url.lastPathComponent);
            return;
        }
        self->_track = atrack;

        NSError *rerr = nil;
        self->_reader = [[AVAssetReader alloc] initWithAsset:self->_asset
                                                      error:&rerr];
        if (!self->_reader) {
            inner = rerr;
            VCLog(@"音频源：reader 创建失败 %@", rerr.localizedDescription);
            return;
        }

        // 输出保持素材原始格式，转换交给管道那层
        NSDictionary *settings = @{
            AVFormatIDKey:               @(kAudioFormatLinearPCM),
            AVLinearPCMBitDepthKey:      @32,
            AVLinearPCMIsFloatKey:       @YES,
            AVLinearPCMIsBigEndianKey:   @NO,
            AVLinearPCMIsNonInterleavedKey: @NO,
        };

        self->_output = [[AVAssetReaderTrackOutput alloc]
                         initWithTrack:atrack outputSettings:settings];
        self->_output.alwaysCopiesSampleData = YES;

        if (![self->_reader canAddOutput:self->_output]) {
            inner = [NSError errorWithDomain:@"VCam" code:3
                     userInfo:@{NSLocalizedDescriptionKey: @"无法添加音频输出"}];
            VCLog(@"音频源：无法添加输出");
            return;
        }
        [self->_reader addOutput:self->_output];

        if (![self->_reader startReading]) {
            inner = self->_reader.error;
            VCLog(@"音频源：startReading 失败 %@",
                  self->_reader.error.localizedDescription);
            return;
        }

        // 从轨道格式描述里读出采样率/声道
        CMFormatDescriptionRef fd = (__bridge CMFormatDescriptionRef)
            atrack.formatDescriptions.firstObject;
        if (fd) {
            const AudioStreamBasicDescription *asbd =
                CMAudioFormatDescriptionGetStreamBasicDescription(fd);
            if (asbd) {
                self->_sampleRate     = asbd->mSampleRate;
                self->_channels       = asbd->mChannelsPerFrame;
                self->_bitsPerChannel = asbd->mBitsPerChannel;
            }
        }

        self->_ready = YES;
        self->_delivered = 0;
        self->_underrun = 0;
        self->_consecutiveNil = 0;
        ok = YES;

        VCLog(@"音频源就绪：%@  %.0fHz / %u ch / %u bit",
              url.lastPathComponent, self->_sampleRate,
              (unsigned)self->_channels, (unsigned)self->_bitsPerChannel);
    });

    if (!ok && error) *error = inner;
    return ok;
}

// ------------------------------------------------------------------ 重置

- (void)reset
{
    dispatch_async(_queue, ^{
        [self restartLocked];
    });
}

- (void)restartLocked
{
    if (!_asset || !_track) return;

    if (_output) [_reader cancelReading];
    _output = nil;
    _reader = nil;

    NSError *err = nil;
    _reader = [[AVAssetReader alloc] initWithAsset:_asset error:&err];
    if (!_reader) {
        VCLog(@"音频源：重置时 reader 创建失败 %@", err.localizedDescription);
        _ready = NO;
        return;
    }

    NSDictionary *settings = @{
        AVFormatIDKey:               @(kAudioFormatLinearPCM),
        AVLinearPCMBitDepthKey:      @32,
        AVLinearPCMIsFloatKey:       @YES,
        AVLinearPCMIsBigEndianKey:   @NO,
        AVLinearPCMIsNonInterleavedKey: @NO,
    };
    _output = [[AVAssetReaderTrackOutput alloc] initWithTrack:_track
                                             outputSettings:settings];
    _output.alwaysCopiesSampleData = YES;

    if (![_reader canAddOutput:_output]) { _ready = NO; return; }
    [_reader addOutput:_output];

    if (![_reader startReading]) {
        VCLog(@"音频源：重置后 startReading 失败 %@",
              _reader.error.localizedDescription);
        _ready = NO;
        return;
    }

    _ready = YES;
    _consecutiveNil = 0;
}

- (void)teardownLocked
{
    if (_output) [_reader cancelReading];
    _output = nil;
    _reader = nil;
    _track  = nil;
    _asset  = nil;
    _url    = nil;
    _ready  = NO;
    _consecutiveNil = 0;
}

// ------------------------------------------------------------------ 取数据

- (NSData *)nextPCMWithFrames:(CMItemCount *)frames
                         asbd:(AudioStreamBasicDescription *)asbd
{
    __block NSData *result = nil;

    dispatch_sync(_queue, ^{
        if (!self->_ready || !self->_output) {
            self->_underrun++;
            return;
        }

        CMSampleBufferRef sbuf = [self->_output copyNextSampleBuffer];
        if (!sbuf) {
            self->_underrun++;
            self->_consecutiveNil++;

            // 兜底：连续拿不到数据，且 reader 已经读完，就自己回到开头。
            // 正常情况下视频回绕会通过通知先一步重置，走不到这里；
            // 这里是为了防止通知丢失导致永久静音。
            if (self->_consecutiveNil >= 3 &&
                self->_reader.status == AVAssetReaderStatusCompleted) {
                VCLog(@"音频源：读到末尾且无通知，自行回到素材开头");
                [self restartLocked];
                self->_consecutiveNil = 0;
            }
            return;
        }

        self->_consecutiveNil = 0;

        CMItemCount n = CMSampleBufferGetNumSamples(sbuf);
        CMBlockBufferRef block = CMSampleBufferGetDataBuffer(sbuf);
        CMFormatDescriptionRef fd = CMSampleBufferGetFormatDescription(sbuf);

        if (fd && asbd) {
            const AudioStreamBasicDescription *a =
                CMAudioFormatDescriptionGetStreamBasicDescription(fd);
            if (a) {
                *asbd = *a;
                if (a->mSampleRate > 0) self->_sampleRate = a->mSampleRate;
                if (a->mChannelsPerFrame > 0) self->_channels = a->mChannelsPerFrame;
            }
        }

        if (block && n > 0) {
            size_t len = CMBlockBufferGetDataLength(block);
            NSMutableData *buf = [NSMutableData dataWithLength:len];
            if (CMBlockBufferCopyDataBytes(block, 0, len, buf.mutableBytes)
                == kCMBlockBufferNoErr) {
                result = buf;
                if (frames) *frames = n;
                self->_delivered += n;
            }
        }

        CFRelease(sbuf);
    });

    return result;
}

// ------------------------------------------------------------------ 查询

- (BOOL)ready              { return _ready; }
- (double)sampleRate       { return _sampleRate; }
- (uint32_t)channels       { return _channels; }
- (uint64_t)framesDelivered { return _delivered; }
- (uint64_t)underrunCount  { return _underrun; }
- (NSURL *)currentURL      { return _url; }

@end
