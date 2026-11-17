//
//  Tweak.xm
//  主 hook。所有出口都在这里封堵。
//
//  hook 全部落在 AVFoundation 层，因此对抖音/快手/微信天然通用，
//  新增 App 只需要往 VCam.plist 的 Filter.Bundles 里加 bundle id。
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <QuartzCore/QuartzCore.h>

#import "VCamConfig.h"
#import "VCFrameSource.h"
#import "VCLiveSource.h"
#import "VCCaptureProxy.h"
#import "VCOverlay.h"
#import "VCHide.h"
#import "VCSampleBufferFactory.h"
#import "VCLog.h"
#import "VCSubstrateCompat.h"

#import <math.h>
#import <stdlib.h>

// ------------------------------------------------------------------ 工具

static NSArray<NSString *> *VCTargetBundles(void)
{
    static NSArray<NSString *> *list = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        list = @[
            @"com.ss.iphone.ugc.Aweme",
            @"com.ss.iphone.ugc.AwemeLite",
            @"com.jiangjia.gif",
            @"com.kuaishou.nebula",
            @"com.tencent.xin",
            @"com.ss.iphone.ugc.live",
        ];
    });
    return list;
}

static BOOL VCIsTargetProcess(void)
{
    NSString *bid = [NSBundle mainBundle].bundleIdentifier;
    return bid && [VCTargetBundles() containsObject:bid];
}

static BOOL VCInjectionActive(void)
{
    VCamConfig *cfg = VCamConfig.shared;
    return cfg.injectEnabled && cfg.sourceKind != VCSourceKindNone;
}

/// 判断某个 device 是不是我们要伪装的那颗后置摄像头
static BOOL VCIsBackCamera(AVCaptureDevice *d)
{
    if (!d) return NO;
    if (d.position != AVCaptureDevicePositionBack) return NO;
    return [d hasMediaType:AVMediaTypeVideo];
}

/// 逐帧极缓慢漂移，模拟真摄像头的自动曝光微调。
/// 参数一动不动反而是破绽 —— 真硬件每帧都在抖。
static double VCDrift(double amplitude, double speed)
{
    return 1.0 + amplitude * sin(CACurrentMediaTime() * speed);
}

// ==================================================================
#pragma mark - 采集输出：数据通道（最关键的一条）
// ==================================================================
// 注意：setSampleBufferDelegate:queue: 并不定义在基类 AVCaptureOutput 上，
// 视频输出和音频输出各自实现了一份。必须分别 hook，
// 否则 Logos 会落到错误的 IMP 上，整条替换链失效。

%hook AVCaptureVideoDataOutput

- (void)setSampleBufferDelegate:(id)delegate queue:(dispatch_queue_t)queue
{
    // 只要是有效 delegate 就一律挂代理，装不装由代理内部按「实时配置」决定。
    // 这里如果按当前模式做判断，之后在面板里切换音频模式就再也装不上了。
    if (!delegate) {
        [VCCaptureProxy releaseProxyForOutput:self];
        %orig(delegate, queue);
        return;
    }

    VCCaptureProxy *proxy = [VCCaptureProxy proxyForTarget:delegate
                                                     kind:VCProxyKindVideo
                                                   output:self];
    %orig(proxy ?: delegate, queue);
}

// 记录 App 请求的像素格式。它要 420v 我们就不能给 420f，
// 否则编码器参数对不上，画面会花。
- (void)setVideoSettings:(NSDictionary *)videoSettings
{
    %orig;
    id fmt = videoSettings[(id)kCVPixelBufferPixelFormatTypeKey];
    if ([fmt isKindOfClass:[NSNumber class]]) {
        [VCSampleBufferFactory shared].requestedVideoFormat = [fmt unsignedIntValue];
        VCLogVerbose(@"App 请求像素格式 0x%x", [fmt unsignedIntValue]);
    }
}

%end

%hook AVCaptureAudioDataOutput

- (void)setSampleBufferDelegate:(id)delegate queue:(dispatch_queue_t)queue
{
    // 同视频：一律挂代理。麦克风模式由代理内部透传原 buffer，
    // 这样面板里随时切「真麦 / 素材 / 静音」都能立刻生效。
    if (!delegate) {
        [VCCaptureProxy releaseProxyForOutput:self];
        %orig(delegate, queue);
        return;
    }

    VCCaptureProxy *proxy = [VCCaptureProxy proxyForTarget:delegate
                                                     kind:VCProxyKindAudio
                                                   output:self];
    %orig(proxy ?: delegate, queue);
}

%end

// ==================================================================
#pragma mark - 采集输出：预览通道
// ==================================================================
// AVCaptureVideoPreviewLayer 走的是 GPU 直连，不经过 delegate，
// 只替换 data output 的话预览窗口还是真画面。这里叠一层盖住。

%hook AVCaptureVideoPreviewLayer

- (instancetype)initWithSession:(AVCaptureSession *)session
{
    id layer = %orig;
    if (layer) [VCOverlay attachToPreviewLayer:layer];
    return layer;
}

- (void)setSession:(AVCaptureSession *)session
{
    %orig;
    [VCOverlay attachToPreviewLayer:self];
}

%end

// ==================================================================
#pragma mark - 拍照通道
// ==================================================================
// 直播 App 会取静帧做封面/首帧校验。这里直接返回我们自己的 JPEG。

%hook AVCapturePhoto

- (NSData *)fileDataRepresentation
{
    if (VCInjectionActive()) {
        NSData *ours = [[VCSampleBufferFactory shared] currentJPEG];
        if (ours.length > 0) {
            return ours;
        }
    }
    return %orig;
}

%end

// ==================================================================
#pragma mark - 设备能力与硬件参数
// ==================================================================
// 只在「真摄像头不启动」的模式下需要伪造。
// 默认让真摄像头空转，它自己就会报出正确的硬件参数，比我们伪造得更真。

%hook AVCaptureDevice

- (BOOL)isConnected
{
    if (!VCIsBackCamera(self)) return %orig;
    return YES;
}

- (BOOL)hasTorch
{
    if (!VCIsBackCamera(self)) return %orig;
    return YES;   // iPhone 8 后置有闪光灯
}

- (BOOL)hasFlash
{
    if (!VCIsBackCamera(self)) return %orig;
    return YES;
}

- (CMTime)exposureDuration
{
    if (!VCIsBackCamera(self) || VCamConfig.shared.letRealCameraRun) return %orig;

    // iPhone 8 后置在室内典型 1/60s，叠加缓慢漂移
    double base = 1.0 / 60.0;
    return CMTimeMakeWithSeconds(base * VCDrift(0.15, 0.3), 1000000000);
}

- (float)ISO
{
    if (!VCIsBackCamera(self) || VCamConfig.shared.letRealCameraRun) return %orig;

    return (float)(100.0 * VCDrift(0.25, 0.3));
}

- (float)lensPosition
{
    if (!VCIsBackCamera(self) || VCamConfig.shared.letRealCameraRun) return %orig;
    return 0.52f;
}

- (AVCaptureWhiteBalanceGains)deviceWhiteBalanceGains
{
    AVCaptureWhiteBalanceGains g = %orig;

    if (!VCIsBackCamera(self) || VCamConfig.shared.letRealCameraRun) return g;

    // 全 0 或 NaN 等于自报「我不是真摄像头」
    if (!isfinite(g.redGain) || g.redGain <= 0.0f) {
        g.redGain = 1.82f;
        g.greenGain = 1.0f;
        g.blueGain = 1.64f;
    }
    return g;
}

- (CMTime)activeVideoMinFrameDuration
{
    if (!VCIsBackCamera(self) || VCamConfig.shared.letRealCameraRun) return %orig;
    double fps = [VCSampleBufferFactory shared].fps > 0 ? [VCSampleBufferFactory shared].fps : 30.0;
    return CMTimeMakeWithSeconds(1.0 / fps, 1000000000);
}

- (CMTime)activeVideoMaxFrameDuration
{
    return [self activeVideoMinFrameDuration];
}

%end

// ==================================================================
#pragma mark - 启动与生命周期
// ==================================================================

static void VCBootstrap(void);

%hook UIApplication

- (BOOL)application:(UIApplication *)application
didFinishLaunchingWithOptions:(NSDictionary *)launchOptions
{
    BOOL ret = %orig;
    VCBootstrap();
    return ret;
}

%end

%hook UIWindow

- (void)makeKeyAndVisible
{
    %orig;
    VCBootstrap();
}

%end

// ------------------------------------------------------------------

static void VCBootstrap(void)
{
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        VCamConfig *cfg = VCamConfig.shared;

        if (![VCFrameSource shared].isReady) {
            NSURL *url = [cfg assetURL];
            if (url) {
                NSError *err = nil;
                if (![[VCFrameSource shared] reloadWithURL:url error:&err]) {
                    VCLog(@"素材装载失败: %@", err);
                }
            } else {
                VCLog(@"没有可用素材，等面板里选");
            }
        }

        if (cfg.sourceKind == VCSourceKindLive && cfg.liveHost.length > 0) {
            [[VCLiveSource shared] connectToHost:cfg.liveHost port:cfg.livePort];
        }

        // 面板稍后再挂，等 App 自己的 UI 起来，避免抢 window
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            [VCOverlay installPanelIfNeeded];
        });

        VCLog(@"VCam 已就绪");
    });
}

// ==================================================================
#pragma mark - 入口
// ==================================================================

%ctor {
    @autoreleasepool {
        if (VCIsTargetProcess()) {
            VCLog(@"注入 %@", [NSBundle mainBundle].bundleIdentifier);

            // 1. 先抹越狱痕迹（必须在 App 做任何检测之前）
            if (VCamConfig.shared.hideJailbreak) {
                [VCHide installHooks];
            }

            // 2. 兜底：即使 didFinishLaunching hook 没命中（SceneDelegate 流程），
            //    延迟一段时间也把面板和素材拉起来
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                VCBootstrap();
            });
        }
    }
}
