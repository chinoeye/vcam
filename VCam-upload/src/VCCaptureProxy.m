//
//  VCCaptureProxy.m
//

#import "VCCaptureProxy.h"
#import "VCFrameSource.h"
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
            // 拿不到可替换的帧时宁可丢这一帧（画面短暂冻结），
            // 也不能把真摄像头画面漏给 App。
            return;
        }
    }

    @try {
        [invocation invokeWithTarget:target];
    } @catch (NSException *e) {
        VCLog(@"转发 delegate 异常: %@", e.reason);
    }
}

// ------------------------------------------------------------------ 替换逻辑

- (CMSampleBufferRef)replacementForBuffer:(CMSampleBufferRef)original drop:(BOOL *)dropOut
{
    if (dropOut) *dropOut = NO;

    VCamConfig *cfg = VCamConfig.shared;
    if (!cfg.injectEnabled || cfg.sourceKind == VCSourceKindNone) {
        return NULL;   // 关闭注入，原样透传
    }

    if (_kind == VCProxyKindVideo) {
        CMSampleBufferRef fresh = [[VCFrameSource shared] copyNextVideoSampleBuffer];
        if (fresh) {
            if (!_loggedFirstReplacement) {
                _loggedFirstReplacement = YES;
                VCLog(@"首帧注入成功");
            }
            CVPixelBufferRef pb = CMSampleBufferGetImageBuffer(fresh);
            if (pb) {
                [[VCSampleBufferFactory shared] updateJPEGFromPixelBuffer:pb];
            }
            // 同一帧也喂给预览覆盖层 —— 只解码一次，两处共用
            [VCOverlay pushVideoSampleBuffer:fresh];
            return fresh;
        }
        // 帧源暂时空（换素材、实时源断线），丢帧而不是透传真画面
        if (dropOut) *dropOut = YES;
        return NULL;
    }

    // ---------------- 音频 ----------------
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
