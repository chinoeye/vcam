//
//  VCCaptureProxy.m
//

#import "VCCaptureProxy.h"
#import "VCFrameSource.h"
#import "VCLiveSource.h"
#import "VCSampleBufferFactory.h"
#import "VCOverlay.h"
#import "VCamConfig.h"
#import "VCLog.h"

#import <AudioToolbox/AudioToolbox.h>
#import <string.h>

// ------------------------------------------------------------------ 注册表

// key 用 weak：output 被 App 释放时条目自动消失，不会拖住内存。
// value 用 strong：这是 proxy 唯一的强引用来源，
// 因为 AVCaptureVideoDataOutput.sampleBufferDelegate 本身就是 weak。
static NSMapTable *VCProxyRegistry(void)
{
    static NSMapTable *table = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        table = [NSMapTable mapTableWithKeyOptions:
                    NSPointerFunctionsWeakMemory | NSPointerFunctionsObjectPointerPersonality
                  valueOptions:NSPointerFunctionsStrongMemory];
    });
    return table;
}

static NSLock *VCProxyLock(void)
{
    static NSLock *lock = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ lock = [[NSLock alloc] init]; });
    return lock;
}

// ------------------------------------------------------------------ 代理

@interface VCCaptureProxy ()
- (CMSampleBufferRef)replacementForBuffer:(CMSampleBufferRef)original
                                     drop:(BOOL *)dropOut;
- (void)rewriteVideoBufferInPlace:(CMSampleBufferRef)buffer
                             drop:(BOOL *)dropOut;
- (BOOL)syncInjectingState;
- (AudioStreamBasicDescription)standardAudioFormat;
@end

@implementation VCCaptureProxy
{
    __weak id _target;
    VCProxyKind _kind;
    __weak id _output;
    BOOL _loggedFirstReplacement;
}

+ (instancetype)proxyForTarget:(id)target kind:(VCProxyKind)kind output:(id)output
{
    if (!target || !output) return nil;

    VCCaptureProxy *proxy = [VCCaptureProxy alloc];
    proxy->_target = target;
    proxy->_kind = kind;
    proxy->_output = output;
    proxy->_loggedFirstReplacement = NO;

    [VCProxyLock() lock];
    [VCProxyRegistry() setObject:proxy forKey:output];
    [VCProxyLock() unlock];

    VCLogVerbose(@"建立%@代理: %@ <- %@",
                 kind == VCProxyKindVideo ? @"视频" : @"音频",
                 NSStringFromClass([output class]),
                 NSStringFromClass([target class]));
    return proxy;
}

+ (void)releaseProxyForOutput:(id)output
{
    if (!output) return;
    [VCProxyLock() lock];
    [VCProxyRegistry() removeObjectForKey:output];
    [VCProxyLock() unlock];
}

+ (void)releaseAll
{
    [VCProxyLock() lock];
    [VCProxyRegistry() removeAllObjects];
    [VCProxyLock() unlock];
}

+ (BOOL)hasProxyForOutput:(id)output
{
    if (!output) return NO;
    [VCProxyLock() lock];
    BOOL has = ([VCProxyRegistry() objectForKey:output] != nil);
    [VCProxyLock() unlock];
    return has;
}

// ------------------------------------------------------------------ 转发基础

- (BOOL)respondsToSelector:(SEL)aSelector
{
    if (aSelector == @selector(captureOutput:didOutputSampleBuffer:fromConnection:)) {
        return YES;
    }
    id t = _target;
    return t ? [t respondsToSelector:aSelector] : NO;
}

- (BOOL)conformsToProtocol:(Protocol *)aProtocol
{
    id t = _target;
    return t ? [t conformsToProtocol:aProtocol] : NO;
}

- (BOOL)isKindOfClass:(Class)aClass
{
    id t = _target;
    return t ? [t isKindOfClass:aClass] : NO;
}

- (BOOL)isMemberOfClass:(Class)aClass
{
    id t = _target;
    return t ? [t isMemberOfClass:aClass] : NO;
}

- (Class)class
{
    id t = _target;
    return t ? [t class] : [VCCaptureProxy class];
}

- (NSMethodSignature *)methodSignatureForSelector:(SEL)sel
{
    id t = _target;
    NSMethodSignature *sig = t ? [t methodSignatureForSelector:sel] : nil;
    if (sig) return sig;
    return [NSObject instanceMethodSignatureForSelector:@selector(init)];
}

- (NSString *)description
{
    return [NSString stringWithFormat:@"<VCCaptureProxy %p kind=%ld target=%@>",
            self, (long)_kind, NSStringFromClass([_target class])];
}

// ------------------------------------------------------------------ 拦截

- (void)forwardInvocation:(NSInvocation *)invocation
{
    id target = _target;
    if (!target) return;   // delegate 已被 App 释放，静默丢弃

    SEL sel = invocation.selector;

    if (sel == @selector(captureOutput:didOutputSampleBuffer:fromConnection:)) {
        __unsafe_unretained id output = nil;
        CMSampleBufferRef original = NULL;
        [invocation getArgument:&output atIndex:2];
        [invocation getArgument:&original atIndex:3];

        // ---- 视频：原地改写系统 buffer 的内容 ----
        //
        // 不再伪造 CMSampleBuffer 塞给 App。伪造出来的 buffer 缺少
        // sample attachments / format description extensions，
        // App 一读就是 NULL，然后 CFRelease(NULL)，EXC_BREAKPOINT。
        //
        // 现在只把系统 buffer 里的像素换掉，buffer 本身原样转发。
        if (_kind == VCProxyKindVideo) {
            BOOL drop = NO;
            [self rewriteVideoBufferInPlace:original drop:&drop];

            if (drop) {
                // 拿不到可替换的帧时宁可丢这一帧（画面短暂冻结），
                // 也不能把真摄像头画面漏给 App。
                return;
            }

            @try {
                [invocation invokeWithTarget:target];
            } @catch (NSException *e) {
                VCLog(@"转发 delegate 异常: %@", e.reason);
            }
            return;
        }

        // ---- 音频：沿用替换策略 ----
        BOOL drop = NO;
        CMSampleBufferRef replacement = [self replacementForBuffer:original drop:&drop];

        if (replacement) {
            [invocation setArgument:&replacement atIndex:3];
            @try {
                [invocation invokeWithTarget:target];
            } @catch (NSException *e) {
                VCLog(@"转发 delegate 异常: %@", e.reason);
            } @finally {
                CFRelease(replacement);
            }
            return;
        }

        if (drop) {
            return;
        }
    }

    @try {
        [invocation invokeWithTarget:target];
    } @catch (NSException *e) {
        VCLog(@"转发 delegate 异常: %@", e.reason);
    }
}

// ------------------------------------------------------------------ 注入状态
//
//  注入状态一变，同步覆盖层的可见性。
//  那个 AVSampleBufferDisplayLayer 是 opaque 的全屏层，即便一帧都不推，
//  它仍然要参与 GPU 合成 —— 等于凭空多合成一整屏预览。
//  视频路径和音频路径都要用到，抽出来共用。
- (BOOL)syncInjectingState
{
    VCamConfig *cfg = VCamConfig.shared;
    BOOL injecting = (cfg.injectEnabled && cfg.sourceKind != VCSourceKindNone);

    static BOOL sLastInjecting = YES;
    if (sLastInjecting != injecting) {
        sLastInjecting = injecting;
        [VCOverlay setOverlaysHidden:!injecting];
        VCLog(@"注入状态切换 -> %@，覆盖层已%@",
              injecting ? @"开" : @"关",
              injecting ? @"显示" : @"隐藏");
    }
    return injecting;
}

// ------------------------------------------------------------------ 视频：原地改写
//
//  保留系统给的 CMSampleBuffer，只把它里面的像素换成我们的。
//
//  为什么不再伪造 buffer：
//    用 CMSampleBufferCreateReadyWithImageBuffer 造出来的 buffer 缺少
//    sample attachments、format description extensions（VerInfo /
//    CameraIntrinsicMatrix）等真实摄像头才有的东西。
//    App 一读就拿到 NULL，然后对它 CFRelease ——
//    崩溃现场固定是：
//      CFRelease.cold.1 <- CFRelease <- AwemeCore
//      <- __invoking___ <- VCam.dylib forwardInvocation: <- AVFCapture
//
//  改成原地改写后，PTS / attachments / format description 全是原生，
//  App 完全感知不到差异。代价是每帧一次 memcpy 或一次 GPU 缩放。
- (void)rewriteVideoBufferInPlace:(CMSampleBufferRef)buffer drop:(BOOL *)dropOut
{
    if (dropOut) *dropOut = NO;
    if (!buffer) return;

    if (![self syncInjectingState]) return;   // 不注入，原样透传
    if (_kind != VCProxyKindVideo) return;

    CVPixelBufferRef dst = CMSampleBufferGetImageBuffer(buffer);
    if (!dst) {
        if (dropOut) *dropOut = YES;
        return;
    }

    VCamConfig *cfg = VCamConfig.shared;
    CVPixelBufferRef src = NULL;

    if (cfg.sourceKind == VCSourceKindLive) {
        // 实时源没有现成的 pixelBuffer 接口，借 CMSampleBuffer 中转一下
        CMSampleBufferRef sb = [[VCLiveSource shared] copyNextVideoSampleBuffer];
        if (sb) {
            CVPixelBufferRef pb = CMSampleBufferGetImageBuffer(sb);
            if (pb) src = CVPixelBufferRetain(pb);
            CFRelease(sb);
        }
    } else {
        src = [[VCFrameSource shared] copyNextPixelBuffer];
    }

    if (!src) {
        // 帧源暂时空（素材没加载好、实时源断线），丢帧而不是透传真画面
        if (dropOut) *dropOut = YES;
        return;
    }

    if (![[VCSampleBufferFactory shared] copyPixelBuffer:src into:dst]) {
        CVPixelBufferRelease(src);
        if (dropOut) *dropOut = YES;
        return;
    }

    if (!_loggedFirstReplacement) {
        _loggedFirstReplacement = YES;
        VCLog(@"首帧注入成功（原地改写）%zux%zu fmt=0x%x",
              CVPixelBufferGetWidth(dst), CVPixelBufferGetHeight(dst),
              (unsigned)CVPixelBufferGetPixelFormatType(dst));
    }

    [[VCSampleBufferFactory shared] updateJPEGFromPixelBuffer:dst];
    [VCOverlay pushVideoSampleBuffer:buffer];

    CVPixelBufferRelease(src);
}

// ------------------------------------------------------------------ 音频：替换
//
//  视频走原地改写，这里只剩音频在用替换策略。
//  音频 buffer 没有视频那边那么多附件要求，替换是安全的。

- (CMSampleBufferRef)replacementForBuffer:(CMSampleBufferRef)original drop:(BOOL *)dropOut
{
    if (dropOut) *dropOut = NO;

    if (![self syncInjectingState]) {
        return NULL;   // 关闭注入，原样透传
    }

    if (_kind == VCProxyKindVideo) {
        return NULL;   // 视频已经走 rewriteVideoBufferInPlace:，这里不处理
    }

    VCamConfig *cfg = VCamConfig.shared;

    // ---------------- 音频 ----------------
    // 从「真麦」切到「素材」的瞬间，音频 reader 还停在很久以前读到的位置。
    // 必须先把它跳到视频当前所在处，否则一开口就是几十秒前的音，口型全错。
    static VCAudioMode sLastAudioMode = VCAudioModeMic;
    if (cfg.audioMode == VCAudioModeAsset && sLastAudioMode != VCAudioModeAsset) {
        [[VCFrameSource shared] seekAudioToVideoTime];
    }
    sLastAudioMode = cfg.audioMode;

    switch (cfg.audioMode) {
        case VCAudioModeMic:
            return NULL;   // 真麦克风透传

        case VCAudioModeMute: {
            const CMItemCount frames = 1024;
            AudioStreamBasicDescription asbd = [self standardAudioFormat];
            NSMutableData *silence = [NSMutableData dataWithLength:frames * sizeof(float)];
            return [[VCSampleBufferFactory shared]
                    createAudioSampleBufferWithData:silence asbd:&asbd frameCount:frames];
        }

        case VCAudioModeAsset: {
            CMItemCount frames = 0;
            AudioStreamBasicDescription asbd = {0};
            NSData *pcm = [[VCFrameSource shared] copyNextAudioPCMWithFrameCount:&frames asbd:&asbd];
            if (!pcm || frames <= 0) {
                if (dropOut) *dropOut = YES;
                return NULL;
            }
            if (asbd.mSampleRate <= 0) asbd = [self standardAudioFormat];
            return [[VCSampleBufferFactory shared]
                    createAudioSampleBufferWithData:pcm asbd:&asbd frameCount:frames];
        }
    }
    return NULL;
}

- (AudioStreamBasicDescription)standardAudioFormat
{
    AudioStreamBasicDescription asbd;
    memset(&asbd, 0, sizeof(asbd));
    asbd.mSampleRate       = 48000;
    asbd.mFormatID         = kAudioFormatLinearPCM;
    asbd.mFormatFlags      = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked;
    asbd.mBytesPerPacket   = 4;
    asbd.mFramesPerPacket  = 1;
    asbd.mBytesPerFrame    = 4;
    asbd.mChannelsPerFrame = 1;
    asbd.mBitsPerChannel   = 32;
    return asbd;
}

@end
