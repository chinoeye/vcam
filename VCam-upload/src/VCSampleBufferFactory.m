//
//  VCSampleBufferFactory.m
//

#import "VCSampleBufferFactory.h"
#import "VCamConfig.h"
#import "VCLog.h"

#import <ImageIO/ImageIO.h>
#import <VideoToolbox/VTPixelTransferSession.h>
#import <CoreImage/CoreImage.h>
#import <AudioToolbox/AudioToolbox.h>
#import <stdlib.h>

@interface VCSampleBufferFactory ()
{
    CMTime _lastPTS;
    CIContext *_ciContext;
    CVPixelBufferPoolRef _jpegPool;
    NSData *_lastJPEG;
    CFMutableDataRef _jpegScratch;
    VTPixelTransferSessionRef _transfer;
    NSLock *_lock;
    NSUInteger _frameCounter;
}
@end

@implementation VCSampleBufferFactory

+ (instancetype)shared
{
    static VCSampleBufferFactory *inst = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        inst = [[VCSampleBufferFactory alloc] init];
    });
    return inst;
}

- (instancetype)init
{
    if ((self = [super init])) {
        _requestedVideoFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange;
        _fps = 30.0;
        _lastPTS = kCMTimeInvalid;
        _lock = [[NSLock alloc] init];

        // CIContext 创建很贵，必须复用
        _ciContext = [CIContext contextWithOptions:@{
            kCIContextUseSoftwareRenderer: @NO,
            kCIContextWorkingColorSpace: (id)kCFNull,
        }];
        _jpegScratch = CFDataCreateMutable(kCFAllocatorDefault, 0);
    }
    return self;
}

- (void)dealloc
{
    if (_jpegPool) CVPixelBufferPoolRelease(_jpegPool);
    if (_jpegScratch) CFRelease(_jpegScratch);
    if (_transfer) VTPixelTransferSessionInvalidate(_transfer);
    if (_transfer) CFRelease(_transfer);
}

- (void)resetTimeline
{
    [_lock lock];
    _lastPTS = kCMTimeInvalid;
    [_lock unlock];
}

// ------------------------------------------------------------------ 时间戳

/// 真摄像头的帧间隔不是完美 33.333ms：自动曝光/增益调整会让它上下浮动。
/// 完美等间隔的帧序是「这是本地文件」最明显的一个统计特征。
- (CMTime)nextPresentationTime
{
    CMTime host = CMClockGetTime(CMClockGetHostTimeClock());

    if (VCamConfig.shared.jitterTimestamps) {
        // -2.0ms ~ +2.0ms 均匀分布
        int32_t r = (int32_t)arc4random_uniform(4001) - 2000;
        host = CMTimeAdd(host, CMTimeMake(r, 1000000));
    }

    [_lock lock];
    if (CMTIME_IS_VALID(_lastPTS) && CMTimeCompare(host, _lastPTS) <= 0) {
        // 严格单调递增，VideoToolbox 编码器遇到非单调 PTS 会直接报错
        host = CMTimeAdd(_lastPTS, CMTimeMake(1, 1000));
    }
    _lastPTS = host;
    [_lock unlock];

    return host;
}

- (CMTime)frameDuration
{
    double fps = self.fps > 0 ? self.fps : 30.0;
    return CMTimeMakeWithSeconds(1.0 / fps, 1000000000);
}

// ------------------------------------------------------------------ 视频

- (CMSampleBufferRef)createVideoSampleBufferFrom:(CVPixelBufferRef)pixelBuffer
                              presentationOverride:(NSValue *)ptsOrNil
{
    if (!pixelBuffer) return NULL;

    CMVideoFormatDescriptionRef fmt = NULL;
    OSStatus st = CMVideoFormatDescriptionCreateForImageBuffer(
        kCFAllocatorDefault, pixelBuffer, &fmt);
    if (st != noErr || !fmt) {
        VCLog(@"CMVideoFormatDescription 创建失败: %d", (int)st);
        return NULL;
    }

    // 真机后置摄像头输出的 buffer 一定带这三个色彩附件；
    // 缺了的话某些 App 会走"非摄像头来源"的回退分支。
    CVBufferSetAttachment(pixelBuffer, kCVImageBufferYCbCrMatrixKey,
                          kCVImageBufferYCbCrMatrix_ITU_R_709_2,
                          kCVAttachmentMode_ShouldNotPropagate);
    CVBufferSetAttachment(pixelBuffer, kCVImageBufferColorPrimariesKey,
                          kCVImageBufferColorPrimaries_ITU_R_709_2,
                          kCVAttachmentMode_ShouldNotPropagate);
    CVBufferSetAttachment(pixelBuffer, kCVImageBufferTransferFunctionKey,
                          kCVImageBufferTransferFunction_ITU_R_709_2,
                          kCVAttachmentMode_ShouldNotPropagate);

    CMTime pts = ptsOrNil ? [ptsOrNil CMTimeValue] : [self nextPresentationTime];

    CMSampleTimingInfo timing;
    timing.duration              = [self frameDuration];
    timing.presentationTimeStamp = pts;
    timing.decodeTimeStamp       = kCMTimeInvalid;

    CMSampleBufferRef sbuf = NULL;
    st = CMSampleBufferCreateReadyWithImageBuffer(
        kCFAllocatorDefault, pixelBuffer, fmt, &timing, &sbuf);
    CFRelease(fmt);

    if (st != noErr) {
        VCLog(@"CMSampleBufferCreateReadyWithImageBuffer 失败: %d", (int)st);
        return NULL;
    }
    return sbuf;
}

- (CMSampleBufferRef)retimeSampleBuffer:(CMSampleBufferRef)src
{
    if (!src) return NULL;

    CVPixelBufferRef pb = CMSampleBufferGetImageBuffer(src);
    if (!pb) return NULL;

    // 解码器出来的 buffer 已经是 IOSurface-backed、420v/420f，
    // 形状和真摄像头几乎一样，只需要重打时间戳。
    return [self createVideoSampleBufferFrom:pb presentationOverride:nil];
}

// ------------------------------------------------------------------ 音频

- (CMSampleBufferRef)createAudioSampleBufferWithData:(NSData *)pcm
                                                asbd:(const AudioStreamBasicDescription *)asbd
                                          frameCount:(CMItemCount)frames
{
    if (!pcm.length || !asbd || frames <= 0) return NULL;

    size_t total = pcm.length;
    CMBlockBufferRef block = NULL;
    OSStatus st = CMBlockBufferCreateWithMemoryBlock(
        kCFAllocatorDefault, NULL, total, kCFAllocatorDefault, NULL,
        0, total, kCMBlockBufferAssureMemoryNowFlag, &block);
    if (st != noErr || !block) return NULL;

    st = CMBlockBufferReplaceDataBytes(pcm.bytes, block, 0, total);
    if (st != noErr) {
        CFRelease(block);
        return NULL;
    }

    CMFormatDescriptionRef fmt = NULL;
    st = CMAudioFormatDescriptionCreate(kCFAllocatorDefault, asbd,
                                        0, NULL, 0, NULL, NULL, &fmt);
    if (st != noErr || !fmt) {
        CFRelease(block);
        return NULL;
    }

    CMSampleTimingInfo timing;
    timing.duration              = CMTimeMake(1, (int32_t)asbd->mSampleRate);
    timing.presentationTimeStamp = [self nextPresentationTime];
    timing.decodeTimeStamp       = kCMTimeInvalid;

    CMSampleBufferRef sbuf = NULL;
    st = CMSampleBufferCreateReady(kCFAllocatorDefault, block, fmt,
                                   frames, 1, &timing, 1, NULL, &sbuf);
    CFRelease(fmt);
    CFRelease(block);

    if (st != noErr) {
        VCLog(@"音频 CMSampleBuffer 创建失败: %d", (int)st);
        return NULL;
    }
    return sbuf;
}

// ------------------------------------------------------------------ 像素格式

- (CVPixelBufferRef)transferPixelBuffer:(CVPixelBufferRef)src toFormat:(OSType)format
{
    if (!src) return NULL;
    if (CVPixelBufferGetPixelFormatType(src) == format) {
        return CVPixelBufferRetain(src);
    }

    if (!_transfer) {
        if (VTPixelTransferSessionCreate(kCFAllocatorDefault, &_transfer) != noErr) {
            return NULL;
        }
        // 这里原本想显式开硬件加速，但 kVTPixelTransferPropertyKey_EnableHardwareAcceleratedTransfer
        // 在 iOS SDK 里并不存在（那是 macOS 侧的常量），写了直接编译失败。
        // 而且 VTPixelTransferSession 默认就走硬件路径，不需要手动开。
    }

    size_t w = CVPixelBufferGetWidth(src);
    size_t h = CVPixelBufferGetHeight(src);

    NSDictionary *attrs = @{
        (id)kCVPixelBufferIOSurfacePropertiesKey: @{},
        (id)kCVPixelBufferPixelFormatTypeKey: @(format),
        (id)kCVPixelBufferWidthKey: @(w),
        (id)kCVPixelBufferHeightKey: @(h),
    };

    CVPixelBufferRef dst = NULL;
    if (CVPixelBufferCreate(kCFAllocatorDefault, w, h, format,
                            (__bridge CFDictionaryRef)attrs, &dst) != kCVReturnSuccess) {
        return NULL;
    }

    OSStatus st = VTPixelTransferSessionTransferImage(_transfer, src, dst);
    if (st != noErr) {
        VCLog(@"像素格式转换失败: %d", (int)st);
        CVPixelBufferRelease(dst);
        return NULL;
    }
    return dst;
}

// ------------------------------------------------------------------ 快照

- (void)updateJPEGFromPixelBuffer:(CVPixelBufferRef)pixelBuffer
{
    if (!pixelBuffer) return;

    // 每 30 帧更新一次就够，拍照出口不会抢到"过期"画面
    if ((_frameCounter++ % 30) != 0 && _lastJPEG) return;

    @try {
        CIImage *ci = [CIImage imageWithCVPixelBuffer:pixelBuffer];
        CGImageRef cg = [_ciContext createCGImage:ci fromRect:ci.extent];
        if (!cg) return;

        CFMutableDataRef data = CFDataCreateMutable(kCFAllocatorDefault, 0);
        if (!data) { CGImageRelease(cg); return; }

        CGImageDestinationRef dest = CGImageDestinationCreateWithData(
            data, CFSTR("public.jpeg"), 1, NULL);
        if (dest) {
            CGImageDestinationAddImage(dest, cg, (__bridge CFDictionaryRef)@{
                (id)kCGImageDestinationLossyCompressionQuality: @0.9,
            });
            CGImageDestinationFinalize(dest);
            CFRelease(dest);

            _lastJPEG = [NSData dataWithBytes:CFDataGetBytePtr(data)
                                       length:CFDataGetLength(data)];
        }
        CFRelease(data);
        CGImageRelease(cg);
    } @catch (NSException *e) {
        VCLog(@"JPEG 快照失败: %@", e.reason);
    }
}

- (NSData *)currentJPEG
{
    return _lastJPEG;
}

@end
