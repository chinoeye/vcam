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
#import <string.h>

@interface VCSampleBufferFactory ()
{
    CMTime _lastPTS;
    CIContext *_ciContext;
    CVPixelBufferPoolRef _jpegPool;
    NSData *_lastJPEG;
    CFTimeInterval _lastJPEGTime;
    CFMutableDataRef _jpegScratch;
    VTPixelTransferSessionRef _transfer;
    NSLock *_lock;

    // ---- 视频格式描述缓存 ----
    // 旧实现每帧都 CMVideoFormatDescriptionCreateForImageBuffer，
    // 30fps 就是每秒 30 次 CF 对象分配/销毁。同一素材的宽高/格式恒定，
    // 缓存一份复用即可（CMSampleBufferCreateReadyWithImageBuffer 会自行 retain）。
    CMVideoFormatDescriptionRef _cachedFormat;
    size_t _cachedW;
    size_t _cachedH;
    OSType _cachedType;
    NSLock *_formatLock;

    // ---- JPEG 快照：后台生成，绝不占采集线程 ----
    dispatch_queue_t _jpegQueue;
    volatile BOOL _jpegBusy;
}

- (CMVideoFormatDescriptionRef)copyFormatForPixelBuffer:(CVPixelBufferRef)pixelBuffer
                                     CF_RETURNS_RETAINED;
- (void)encodeJPEGNow:(CVPixelBufferRef)pixelBuffer;
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
        _formatLock = [[NSLock alloc] init];

        // CIContext 创建很贵，必须复用
        _ciContext = [CIContext contextWithOptions:@{
            kCIContextUseSoftwareRenderer: @NO,
            kCIContextWorkingColorSpace: (id)kCFNull,
        }];
        _jpegScratch = CFDataCreateMutable(kCFAllocatorDefault, 0);

        // 快照走独立低优先级串行队列：采集线程只投递，不等结果
        _jpegQueue = dispatch_queue_create("com.yg.vcam.jpeg", DISPATCH_QUEUE_SERIAL);
        dispatch_set_target_queue(_jpegQueue,
            dispatch_get_global_queue(QOS_CLASS_UTILITY, 0));
        _jpegBusy = NO;
    }
    return self;
}

- (void)dealloc
{
    if (_jpegPool) CVPixelBufferPoolRelease(_jpegPool);
    if (_jpegScratch) CFRelease(_jpegScratch);
    if (_cachedFormat) CFRelease(_cachedFormat);
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

/// 取（并 retain）一份格式描述。同尺寸同格式直接复用缓存。
- (CMVideoFormatDescriptionRef)copyFormatForPixelBuffer:(CVPixelBufferRef)pixelBuffer
{
    if (!pixelBuffer) return NULL;

    size_t w = CVPixelBufferGetWidth(pixelBuffer);
    size_t h = CVPixelBufferGetHeight(pixelBuffer);
    OSType type = CVPixelBufferGetPixelFormatType(pixelBuffer);

    [_formatLock lock];

    if (_cachedFormat && _cachedW == w && _cachedH == h && _cachedType == type) {
        CMVideoFormatDescriptionRef hit = (CMVideoFormatDescriptionRef)CFRetain(_cachedFormat);
        [_formatLock unlock];
        return hit;
    }

    CMVideoFormatDescriptionRef created = NULL;
    OSStatus st = CMVideoFormatDescriptionCreateForImageBuffer(
        kCFAllocatorDefault, pixelBuffer, &created);
    if (st != noErr || !created) {
        [_formatLock unlock];
        VCLog(@"CMVideoFormatDescription 创建失败: %d", (int)st);
        return NULL;
    }

    if (_cachedFormat) CFRelease(_cachedFormat);
    _cachedFormat = created;
    _cachedW = w;
    _cachedH = h;
    _cachedType = type;

    CMVideoFormatDescriptionRef out = (CMVideoFormatDescriptionRef)CFRetain(_cachedFormat);
    [_formatLock unlock];
    return out;
}

- (CMSampleBufferRef)createVideoSampleBufferFrom:(CVPixelBufferRef)pixelBuffer
                              presentationOverride:(NSValue *)ptsOrNil
{
    if (!pixelBuffer) return NULL;

    // 同尺寸同格式的素材：这里命中缓存，不再每帧新建格式描述
    CMVideoFormatDescriptionRef fmt = [self copyFormatForPixelBuffer:pixelBuffer];
    if (!fmt) return NULL;

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
    OSStatus st = CMSampleBufferCreateReadyWithImageBuffer(
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

// ------------------------------------------------------------------ 原地改写
//
//  为什么需要这条路线：
//    之前的做法是用 CMSampleBufferCreateReadyWithImageBuffer 伪造一个 buffer
//    塞给 App。但真实摄像头的 buffer 里还有很多我们造不出来的东西 ——
//    sample attachments、format description extensions（VerInfo /
//    CameraIntrinsicMatrix）、data buffer 结构。App 一读就拿到 NULL，
//    然后对这个 NULL 调 CFRelease，直接 EXC_BREAKPOINT。
//
//    崩溃堆栈每次都一模一样：
//      CFRelease.cold.1 <- CFRelease <- AwemeCore
//      <- __invoking___ <- VCam.dylib forwardInvocation: <- AVFCapture
//
//  现在改成：保留系统给的那个 buffer，只把像素内容换掉。
//  PTS、attachments、format description 全部原生，App 不会察觉。
//  代价是每帧多一次 memcpy（同格式）或一次 GPU 缩放（异格式）。

// 采样 Y 平面，看 range 到底有没有被转换。
//
//  "偏白"在数值上只有两种形态：
//    src Y 16~235（video）→ dst Y 也是 16~235  → range 没转，暗部发灰、亮部封顶
//    src Y 16~235          → dst Y 变成 0~255  → range 转了
//  量出来就不用猜了。
static void VCSampleYRange(CVPixelBufferRef pb, const char *tag)
{
    if (!pb || CVPixelBufferGetPlaneCount(pb) < 1) return;
    if (CVPixelBufferLockBaseAddress(pb, kCVPixelBufferLock_ReadOnly) != kCVReturnSuccess) return;

    uint8_t *base = CVPixelBufferGetBaseAddressOfPlane(pb, 0);
    size_t h   = CVPixelBufferGetHeightOfPlane(pb, 0);
    size_t w   = CVPixelBufferGetWidthOfPlane(pb, 0);
    size_t bpr = CVPixelBufferGetBytesPerRowOfPlane(pb, 0);

    if (base && h > 0 && w > 0) {
        uint8_t mn = 255, mx = 0;
        double sum = 0; size_t n = 0;
        for (size_t y = 0; y < h; y += 24) {
            const uint8_t *row = base + y * bpr;
            for (size_t x = 0; x < w; x += 24) {
                uint8_t v = row[x];
                if (v < mn) mn = v;
                if (v > mx) mx = v;
                sum += v; n++;
            }
        }
        if (n) {
            VCLog(@"Y范围[%s] min=%u max=%u mean=%.1f（%zu 点）", tag, mn, mx, sum / n, n);
        }
    }
    CVPixelBufferUnlockBaseAddress(pb, kCVPixelBufferLock_ReadOnly);
}

// 亮度反补偿：把开播页那条提亮曲线抵掉。
//
//  只动 Y 平面（亮度），色度 U/V 完全不动 —— 实测开播页只改了亮度曲线
//  （暗部 +130%、中间调 +19%、高光封顶），对比度和饱和度基本没变。
//
//  gamma > 1 是压暗：out = 255 × (in/255)^gamma
//  对 720x1280 来说 92 万次查表，约 1~3 ms，可接受。
static void VCApplyOutputGamma(CVPixelBufferRef dst, double gamma)
{
    if (!dst || !(gamma > 0.01) || fabs(gamma - 1.0) < 0.005) return;
    if (CVPixelBufferGetPlaneCount(dst) < 1) return;
    if (CVPixelBufferLockBaseAddress(dst, 0) != kCVReturnSuccess) return;

    static uint8_t sLut[256];
    static double  sLutGamma = -1.0;
    if (fabs(sLutGamma - gamma) > 0.001) {
        for (int i = 0; i < 256; i++) {
            double v = pow(i / 255.0, gamma) * 255.0;
            sLut[i] = (uint8_t)(v < 0 ? 0 : (v > 255 ? 255 : v + 0.5));
        }
        sLutGamma = gamma;
    }

    uint8_t *base = CVPixelBufferGetBaseAddressOfPlane(dst, 0);
    size_t h   = CVPixelBufferGetHeightOfPlane(dst, 0);
    size_t w   = CVPixelBufferGetWidthOfPlane(dst, 0);
    size_t bpr = CVPixelBufferGetBytesPerRowOfPlane(dst, 0);
    if (base) {
        for (size_t y = 0; y < h; y++) {
            uint8_t *row = base + y * bpr;
            for (size_t x = 0; x < w; x++) row[x] = sLut[row[x]];
        }
    }
    CVPixelBufferUnlockBaseAddress(dst, 0);
}

- (BOOL)copyPixelBuffer:(CVPixelBufferRef)src into:(CVPixelBufferRef)dst
{
    if (!src || !dst) return NO;

    size_t sw = CVPixelBufferGetWidth(src);
    size_t sh = CVPixelBufferGetHeight(src);
    size_t dw = CVPixelBufferGetWidth(dst);
    size_t dh = CVPixelBufferGetHeight(dst);
    OSType sf = CVPixelBufferGetPixelFormatType(src);
    OSType df = CVPixelBufferGetPixelFormatType(dst);

    // ---- 同尺寸同格式：按平面直接 memcpy，最快 ----
    if (sw == dw && sh == dh && sf == df) {
        if (CVPixelBufferLockBaseAddress(src, kCVPixelBufferLock_ReadOnly) != kCVReturnSuccess) {
            return NO;
        }
        if (CVPixelBufferLockBaseAddress(dst, 0) != kCVReturnSuccess) {
            CVPixelBufferUnlockBaseAddress(src, kCVPixelBufferLock_ReadOnly);
            return NO;
        }

        BOOL ok = YES;
        size_t planes = CVPixelBufferGetPlaneCount(src);

        if (planes == 0) {
            void *sbase = CVPixelBufferGetBaseAddress(src);
            void *dbase = CVPixelBufferGetBaseAddress(dst);
            size_t slen  = CVPixelBufferGetDataSize(src);
            size_t dlen  = CVPixelBufferGetDataSize(dst);
            if (sbase && dbase && slen <= dlen) {
                memcpy(dbase, sbase, slen);
            } else {
                ok = NO;
            }
        } else {
            for (size_t i = 0; i < planes; i++) {
                void  *sbase = CVPixelBufferGetBaseAddressOfPlane(src, i);
                void  *dbase = CVPixelBufferGetBaseAddressOfPlane(dst, i);
                size_t h     = CVPixelBufferGetHeightOfPlane(src, i);
                size_t sbpr  = CVPixelBufferGetBytesPerRowOfPlane(src, i);
                size_t dbpr  = CVPixelBufferGetBytesPerRowOfPlane(dst, i);
                if (!sbase || !dbase) { ok = NO; break; }
                size_t rowLen = (sbpr < dbpr) ? sbpr : dbpr;
                for (size_t y = 0; y < h; y++) {
                    memcpy((uint8_t *)dbase + y * dbpr,
                           (uint8_t *)sbase + y * sbpr,
                           rowLen);
                }
            }
        }

        CVPixelBufferUnlockBaseAddress(dst, 0);
        CVPixelBufferUnlockBaseAddress(src, kCVPixelBufferLock_ReadOnly);
        return ok;
    }

    // ---- 尺寸或格式不同：交给 VTPixelTransferSession 缩放 + 转格式 ----
    if (!_transfer) {
        if (VTPixelTransferSessionCreate(kCFAllocatorDefault, &_transfer) != noErr) {
            return NO;
        }
    }

    // ---- 告诉 VTPixelTransferSession 源和目标各是什么矩阵 ----
    //
    //  实测（诊断日志）：素材解码出来是 1080p / 420v / BT.709，
    //  系统采集 buffer 是 720p / 420f，format description 声明 **BT.601**
    //  （720p 的惯例）。两边矩阵不同。
    //
    //  但 VT 拿到的是 CVPixelBuffer，看不到 CMSampleBuffer 的 format
    //  description —— 它按分辨率猜，两边都猜成 601，于是只做缩放和 range
    //  扩展，**不做矩阵转换**。结果 709 的 YCbCr 被写进声明为 601 的 buffer，
    //  偏色、发灰、对比度变平（看起来就是"偏白"）。
    //
    //  把矩阵显式挂在 buffer 上，VT 才有机会做真正的矩阵转换。
    //  若实测证明它忽略这两个 attachment，就必须改 Metal 自己算 709→601。
    CVBufferSetAttachment(src, kCVImageBufferYCbCrMatrixKey,
                          kCVImageBufferYCbCrMatrix_ITU_R_709_2,
                          kCVAttachmentMode_ShouldPropagate);
    CVBufferSetAttachment(dst, kCVImageBufferYCbCrMatrixKey,
                          kCVImageBufferYCbCrMatrix_ITU_R_601_4,
                          kCVAttachmentMode_ShouldPropagate);

    OSStatus st = VTPixelTransferSessionTransferImage(_transfer, src, dst);
    {
        static int sConvLogs = 0;
        if (sConvLogs < 3) {
            sConvLogs++;
            VCLog(@"像素转换 %zux%zu 0x%x → %zux%zu 0x%x  %@",
                  sw, sh, (unsigned)sf, dw, dh, (unsigned)df,
                  st == noErr ? @"成功" : @"失败");
            if (st == noErr) {
                // 转换前后各量一次 Y 范围，直接看出 range 有没有被处理
                VCSampleYRange(src, "转换前 素材");
                VCSampleYRange(dst, "转换后 系统");
            }
        }
    }
    if (st != noErr) {
        VCLog(@"写入系统帧失败 %d (src %zux%zu 0x%x -> dst %zux%zu 0x%x)",
              (int)st, sw, sh, (unsigned)sf, dw, dh, (unsigned)df);
        return NO;
    }

    // 开播页那条提亮曲线的反补偿（config.plist 的 outputGamma，1.0 = 不补）
    {
        static int sGammaLogs = 0;
        double g = VCamConfig.shared.outputGamma;
        if (g > 0.01 && fabs(g - 1.0) > 0.005) {
            if (sGammaLogs++ < 3) {
                VCLog(@"亮度反补偿 gamma=%.2f 已应用", g);
            }
            VCApplyOutputGamma(dst, g);
        }
    }
    return YES;
}

// ------------------------------------------------------------------ 快照
/// 采集线程只做一件事：把这一帧 retain 后扔进后台队列，立刻返回。
///
/// 旧实现在采集回调里同步跑 CIContext → CGImage → JPEG，
/// 1080p 一次约 30~60ms（GPU→CPU 回读是同步的），每秒一次，
/// 表现为「抖音每秒固定顿一下」，并且这段时间采集回调被完全堵死、直接丢帧。
- (void)updateJPEGFromPixelBuffer:(CVPixelBufferRef)pixelBuffer
{
    if (!pixelBuffer || !_jpegQueue) return;

    // 上一次还没做完 → 直接丢弃（快照本来就不需要每帧新鲜）
    if (_jpegBusy) return;

    // 结果够新就不重做，2 秒一次对拍照出口足够
    if (_lastJPEG) {
        CFTimeInterval now = CFAbsoluteTimeGetCurrent();
        if (now - _lastJPEGTime < 2.0) return;
    }

    _jpegBusy = YES;
    CVPixelBufferRetain(pixelBuffer);
    dispatch_async(_jpegQueue, ^{
        [self encodeJPEGNow:pixelBuffer];
        CVPixelBufferRelease(pixelBuffer);
        self->_jpegBusy = NO;
    });
}

/// 真正的编码，跑在 _jpegQueue 上。
- (void)encodeJPEGNow:(CVPixelBufferRef)pixelBuffer
{
    if (!pixelBuffer) return;

    @autoreleasepool {
        NSData *encoded = nil;
        @try {
            CIImage *ci = [CIImage imageWithCVPixelBuffer:pixelBuffer];
            CGImageRef cg = [_ciContext createCGImage:ci fromRect:ci.extent];
            if (cg) {
                CFMutableDataRef data = CFDataCreateMutable(kCFAllocatorDefault, 0);
                if (data) {
                    CGImageDestinationRef dest = CGImageDestinationCreateWithData(
                        data, CFSTR("public.jpeg"), 1, NULL);
                    if (dest) {
                        CGImageDestinationAddImage(dest, cg, (__bridge CFDictionaryRef)@{
                            (id)kCGImageDestinationLossyCompressionQuality: @0.9,
                        });
                        if (CGImageDestinationFinalize(dest)) {
                            encoded = [NSData dataWithBytes:CFDataGetBytePtr(data)
                                                     length:CFDataGetLength(data)];
                        }
                        CFRelease(dest);
                    }
                    CFRelease(data);
                }
                CGImageRelease(cg);
            }
        } @catch (NSException *e) {
            VCLog(@"JPEG 快照失败: %@", e.reason);
        }

        if (encoded.length > 0) {
            [_lock lock];
            _lastJPEG = encoded;
            _lastJPEGTime = CFAbsoluteTimeGetCurrent();
            [_lock unlock];
        }
    }
}

- (NSData *)currentJPEG
{
    [_lock lock];
    NSData *d = _lastJPEG;
    [_lock unlock];
    return d;
}

@end
