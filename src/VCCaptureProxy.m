//
//  VCCaptureProxy.m
//

#import <QuartzCore/QuartzCore.h>
#import "VCCaptureProxy.h"
#import "VCFrameSource.h"
#import "VCLiveSource.h"
#import "VCSampleBufferFactory.h"
#import "VCOverlay.h"
#import "VCamConfig.h"
#import "VCLog.h"

#import <AudioToolbox/AudioToolbox.h>
#import <string.h>
#import <math.h>

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
- (void)rewriteVideoBufferInPlace:(CMSampleBufferRef)buffer
                             drop:(BOOL *)dropOut;
- (void)rewriteAudioBufferInPlace:(CMSampleBufferRef)buffer
                             drop:(BOOL *)dropOut;
- (BOOL)syncInjectingState;
@end

@implementation VCCaptureProxy
{
    __weak id _target;
    VCProxyKind _kind;
    __weak id _output;
    BOOL _loggedFirstReplacement;
    CVPixelBufferRef _lastSrcPB;   // 上一帧源数据，用于按素材帧率节流
    double _lastSrcTime;           // 上次出帧时刻
    double _nextFrameTime;         // 下一帧允许出的绝对时刻（已废弃，保留字段）
    double _srcBudget;             // 已废弃，保留字段
    double _playStartTime;         // 开始播放的绝对时刻（PTS 对齐用）
    double _playStartPos;          // 开始播放时素材所在位置（秒）
    double _lastFetchTime;         // 上次实际出帧的绝对时刻（硬限速用）
    uint64_t _srcFetched;          // 实际从素材取了几个新帧（诊断）
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

    VCLog(@"建立%@代理: %@ <- %@",
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

        // ---- 音频：同样原地改写系统 buffer ----
        //
        // 原来是伪造一个新的 CMSampleBuffer 塞给 App，
        // 跟视频那边是一样的坑，只是音频对附件的依赖没那么多，
        // 崩得没那么早而已。统一改成原地写内容。
        BOOL drop = NO;
        [self rewriteAudioBufferInPlace:original drop:&drop];

        if (drop) {
            return;
        }

        @try {
            [invocation invokeWithTarget:target];
        } @catch (NSException *e) {
            VCLog(@"转发 delegate 异常: %@", e.reason);
        }
        return;
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
    extern volatile int g_statVideoDelegates;
    g_statVideoDelegates++;

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
        // 按素材帧率节流。
        //
        //  抖音的 AVCaptureVideoDataOutput 按 60fps 回调，而素材是 30fps。
        //  以前每次回调都推进一帧素材 → 15 秒录制消耗 30 秒素材
        //  （实测视频位置 29.93s vs 音频 17.00s，差一整个录制时长）。
        //  这里缓存上一帧，没到间隔就复用，让视频消耗速度和音频一致。
        // 累积式节流：用「下一帧的绝对时刻」而不是「距上次多久」。
        //
        //  为什么必须改：
        //    之前用 (now - _lastSrcTime) < minInterval * 0.85 判据。
        //    素材 60fps → minInterval 16.67ms，阈值 14.2ms；
        //    而抖音请求间隔实测 14ms —— 每次都刚好挤进阈值，每次都出帧，
        //    结果消耗 71.6fps（1.19 倍），音画还是差 3.35 秒。
        //
        //  累积式判据每 minInterval 只放行一帧，不管请求多密，
        //  消耗严格等于素材帧率 → 视频和音频都是实时 1:1。
        // ---- 素材 PTS 对齐实时时钟 ----
        //
        //  前面试过三种「按请求节奏节流」的做法，都不稳：
        //    单次间隔判断    80 fps（1.33 倍）
        //    累积预算钳 1 帧  54.9 fps
        //    累积预算容差     49~52 fps
        //
        //  根本原因是抖音的请求频率本身在动（实测 99~120fps 之间漂），
        //  而且请求间隔不均匀，任何「基于请求间隔」的算法都会被带偏。
        //
        //  改成以真实时间为准：
        //    记下开始播放的时刻和当时的素材位置，
        //    之后每来一次请求就检查「素材位置是否跟上真实时间」，
        //    落后超过半帧才推进 reader。
        //  这样素材位置的推进速度严格等于真实时间 1:1，
        //  跟抖音怎么请求完全无关。
        CGFloat fps = [VCFrameSource shared].sourceFrameRate;
        double frameDur = (fps > 1.0) ? (1.0 / fps) : (1.0 / 30.0);
        double now = CACurrentMediaTime();
        double curPos = [VCFrameSource shared].currentVideoSourceTime;

        if (_playStartTime <= 0) {
            // 首次：以当前素材位置为基准
            _playStartTime = now;
            _playStartPos = curPos;
        }

        double target = _playStartPos + (now - _playStartTime);
        // 素材循环回绕时 target 会跑过素材长度，就地重置基准，避免一直落后
        if (target - curPos > 5.0) {
            _playStartTime = now;
            _playStartPos = curPos;
            target = curPos;
        }

        // ---- 硬限速：每帧至少间隔 frameDur 才出 ----
        //
        //  前面所有「按请求节奏推断」的算法都失败，诊断日志给出了确切原因：
        //    抖音请求 56.9fps（间隔 17.5ms），素材 30fps（一帧 33.3ms）。
        //    只要每次请求都取一帧，素材就按 56.9×33.3ms = 1.9 秒/秒 消耗，
        //    视频必然比音频跑得快一倍。
        //
        //  「追到 target 就停」这个判据本身没错，但 target 按真实时间涨 17.5ms，
        //  而取一帧 curPos 就跳 33.3ms —— 目标步长比时间步长还大，
        //  于是每 1.5 次请求必然触发一次取帧，等于没限速。
        //
        //  真正有效的约束是：**两次出帧之间必须至少隔 frameDur 真实时间**。
        //  这条约束和请求频率完全解耦：
        //    请求再密，出帧也不会快于素材帧率；
        //    请求稀疏时靠后面的追赶逻辑补齐。
        CGFloat fps = [VCFrameSource shared].sourceFrameRate;
        double frameDur = (fps > 1.0) ? (1.0 / fps) : (1.0 / 30.0);
        double now = CACurrentMediaTime();
        double curPos = [VCFrameSource shared].currentVideoSourceTime;

        if (_playStartTime <= 0) {
            _playStartTime = now;
            _playStartPos = curPos;
        }
        double target = _playStartPos + (now - _playStartTime);
        if (target - curPos > 5.0) {          // 素材回绕后重新对齐基准
            _playStartTime = now;
            _playStartPos = curPos;
            target = curPos;
        }

        int fetched = 0;

        // 硬限速：距上次出帧不足 frameDur 就不推进
        BOOL rateOK = (_lastFetchTime <= 0) || ((now - _lastFetchTime) >= frameDur * 0.98);

        if (!_lastSrcPB) {
            CVPixelBufferRef nb = [[VCFrameSource shared] copyNextPixelBuffer];
            if (nb) {
                _lastSrcPB = CVPixelBufferRetain(nb);
                CVPixelBufferRelease(nb);
                _lastFetchTime = now;
                fetched = 1;
            }
        } else if (rateOK && curPos < target - frameDur * 0.5) {
            CVPixelBufferRef nb = [[VCFrameSource shared] copyNextPixelBuffer];
            if (nb) {
                CVPixelBufferRelease(_lastSrcPB);
                _lastSrcPB = CVPixelBufferRetain(nb);
                CVPixelBufferRelease(nb);
                _lastFetchTime = now;
                fetched = 1;
            }
        }

        // 严重落后（超过 1 秒）时允许连续补帧，避免长时间卡在一个位置
        if (curPos < target - 1.0) {
            int guard = 0;
            while (guard++ < 90) {
                CVPixelBufferRef nb = [[VCFrameSource shared] copyNextPixelBuffer];
                if (!nb) break;
                CVPixelBufferRelease(_lastSrcPB);
                _lastSrcPB = CVPixelBufferRetain(nb);
                CVPixelBufferRelease(nb);
                fetched++;
                curPos = [VCFrameSource shared].currentVideoSourceTime;
            }
            _lastFetchTime = CACurrentMediaTime();
        }

        {
            static int sDbg = 0;
            if (sDbg < 25) {
                sDbg++;
                VCLog(@"出帧 #%d 落后=%+.3fs 取=%d 限速=%@ curPos=%.3f",
                      sDbg, target - curPos, fetched, rateOK ? @"Y" : @"N", curPos);
            }
        }

        if (_lastSrcPB) src = CVPixelBufferRetain(_lastSrcPB);
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

// ------------------------------------------------------------------ 音频：原地改写
//
//  跟视频同一套思路：保留系统给的 CMSampleBuffer，
//  用 CMBlockBufferReplaceDataBytes 把里面的 PCM 换掉。
//
//  系统麦克风的 buffer 格式由 AURemoteIO 决定，通常是
//  Float32 / 48kHz / 双声道。素材音轨我们是按单声道 48k 取的，
//  所以这里做一次「单声道 → N 声道」的复制展开。
//  采样率不一致的情况没有做重采样，直接丢帧 —— 宁肯短暂静音，
//  也不要放出一段变速变调的声音。

- (void)rewriteAudioBufferInPlace:(CMSampleBufferRef)buffer drop:(BOOL *)dropOut
{
    if (dropOut) *dropOut = NO;
    if (!buffer) return;

    if (![self syncInjectingState]) return;
    if (_kind != VCProxyKindAudio) return;

    VCamConfig *cfg = VCamConfig.shared;
    if (cfg.audioMode == VCAudioModeMic) return;   // 真麦，原样透传

    // 只处理「静音」，素材音轨一律交给 AudioUnitRender 那条路。
    //
    // 原因：抖音的直播/拍摄音频实际走 AudioUnit（byteaudio），
    // 我们已经在 hook_AudioUnitRender 里用 AudioConverter 做了
    // float32/mono/48k -> int16/stereo/44.1k 的完整转换。
    //
    // 如果这里也往素材里写，两条路径会抢同一个 VCFrameSource 的读指针：
    //   · 数据被消耗两次，音频被加速
    //   · 互相打断连续性，表现为「每隔几秒断一下」
    //   · 而且这里没有格式转换，写进去的 float 会被当 int16 播
    //
    // 所以素材音轨这条路彻底让给 AudioUnitRender，这里只保留静音能力。
    if (cfg.audioMode != VCAudioModeMute) {
        return;
    }

    CMBlockBufferRef block = CMSampleBufferGetDataBuffer(buffer);
    if (!block) {
        if (dropOut) *dropOut = YES;
        return;
    }
    size_t dstLen = CMBlockBufferGetDataLength(block);
    if (dstLen == 0) {
        if (dropOut) *dropOut = YES;
        return;
    }

    NSMutableData *silence = [NSMutableData dataWithLength:dstLen];
    if (CMBlockBufferReplaceDataBytes(silence.bytes, block, 0, dstLen) != kCMBlockBufferNoErr) {
        if (dropOut) *dropOut = YES;
    }
}

@end
