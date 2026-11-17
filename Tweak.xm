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

/// 判断某个 device 是不是我们要伪装的那颗后置摄像头。
///
/// 注入未启用时一律返回 NO —— 这一行的作用是把 AVCaptureDevice 上
/// 那 9 个属性 hook（ISO / exposureDuration / lensPosition /
/// activeVideoMinFrameDuration / 白平衡 ...）全部压回 %orig 透传，
/// 等于「静默模式」下这些 hook 完全不存在。
static BOOL VCIsBackCamera(AVCaptureDevice *d)
{
    if (!d) return NO;
    if (!VCInjectionActive()) return NO;
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

    // 注入未启用：不挂代理，保持 App 原始回调通路。
    // 静默模式下 NSInvocation 转发这层完全不参与，用来判断问题是否出在代理层。
    if (!VCInjectionActive()) {
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

    // 静默模式：连这个单例都不要碰。
    //
    // VCSampleBufferFactory 的 init 里会创建 CIContext ——
    // 那是 GPU 上下文，iPhone 8 的显存本来就紧张，
    // 抖音点开视频正在抢 GPU 做解码时，被它占住一块，画面会直接冻住。
    // 而主线程不受影响，表现出来正是「画面卡死、HOME 键却有反应」。
    if (!VCInjectionActive()) return;

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

    // 同视频：静默模式下不挂代理
    if (!VCInjectionActive()) {
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
#pragma mark - 音频：AVAudioEngine 路径
// ==================================================================
//
//  实测抖音的直播音频不走 AVCaptureAudioDataOutput：
//  把 audioMode 切成静音，录出来还是真麦克风的声音 —— 说明那条 hook
//  压根没碰到它的采集链路。它用的是 AVAudioEngine / 底层 AudioUnit。
//
//  这里走跟视频同一套「原地改内容」的思路：
//    tap 回调给的是 AVAudioPCMBuffer（系统原生对象）
//    我们只改它里面的 floatChannelData，不造任何东西
//    然后把**同一个 buffer** 交给原始 block
//
//  这样格式、所有权、时间戳全是系统的，不存在伪造导致崩溃的风险。

static void VCRewritePCMBuffer(AVAudioPCMBuffer *buf)
{
    if (!buf) return;

    VCamConfig *cfg = VCamConfig.shared;
    if (cfg.audioMode == VCAudioModeMic) return;   // 真麦，不碰

    AVAudioFrameCount frames = buf.frameLength;
    if (frames == 0) return;

    AVAudioFormat *fmt = buf.format;
    if (!fmt) return;

    // 静音：整块清零
    if (cfg.audioMode == VCAudioModeMute) {
        if (fmt.commonFormat == AVAudioPCMFormatFloat32 && buf.floatChannelData) {
            UInt32 ch = fmt.channelCount;
            for (UInt32 c = 0; c < ch; c++) {
                memset(buf.floatChannelData[c], 0, frames * sizeof(float));
            }
        }
        return;
    }

    // 素材音轨：只处理 float32
    if (fmt.commonFormat != AVAudioPCMFormatFloat32 || !buf.floatChannelData) {
        static BOOL sWarned = NO;
        if (!sWarned) {
            sWarned = YES;
            VCLog(@"AVAudioPCMBuffer 不是 float32（commonFormat=%ld），素材音轨无法灌入",
                  (long)fmt.commonFormat);
        }
        return;
    }

    CMItemCount srcFrames = 0;
    AudioStreamBasicDescription asbd = {0};
    NSData *pcm = [[VCFrameSource shared] copyNextAudioPCMWithFrameCount:&srcFrames asbd:&asbd];
    if (!pcm || srcFrames == 0) return;

    const float *src = (const float *)pcm.bytes;
    size_t avail = pcm.length / sizeof(float);
    if (avail == 0) return;

    size_t n = ((size_t)frames < avail) ? (size_t)frames : avail;
    UInt32 ch = fmt.channelCount;

    static BOOL sLogged = NO;
    if (!sLogged) {
        sLogged = YES;
        VCLog(@"AVAudioEngine 音频注入接通：系统 %.0fHz x%u，每块 %u 帧，灌入 %zu 帧",
              fmt.sampleRate, (unsigned)ch, (unsigned)frames, n);
    }

    for (UInt32 c = 0; c < ch; c++) {
        float *dst = buf.floatChannelData[c];
        if (!dst) continue;
        memcpy(dst, src, n * sizeof(float));
        if (n < (size_t)frames) {
            memset(dst + n, 0, ((size_t)frames - n) * sizeof(float));
        }
    }
}

%hook AVAudioEngine

- (void)installTapOnBus:(AVAudioNodeBus)bus
             bufferSize:(AVAudioFrameCount)bufferSize
                 format:(AVAudioFormat *)format
                  block:(AVAudioNodeTapBlock)tapBlock
{
    VCLog(@"AVAudioEngine installTapOnBus 命中：bus=%u size=%u fmt=%@",
          (unsigned)bus, (unsigned)bufferSize, format);

    // 包一层：先改系统给的这个 buffer 的内容，再交给原始 block。
    // 传下去的还是同一个 buffer 对象，不新建、不折腾所有权。
    AVAudioNodeTapBlock wrapped = ^(AVAudioPCMBuffer *buffer, AVAudioTime *when) {
        VCRewritePCMBuffer(buffer);
        if (tapBlock) tapBlock(buffer, when);
    };

    %orig(bus, bufferSize, format, wrapped);
}

%end

// ==================================================================
#pragma mark - 音频：AudioUnit (RemoteIO) 路径  ★真正在这条
// ==================================================================
//
//  崩溃日志的镜像列表把答案写得很清楚：
//    AudioSession.framework        私有音频会话
//    libEmbeddedSystemAUs.dylib    内嵌系统 AudioUnit
//
//  抖音既不走 AVCaptureAudioDataOutput，也不走 AVAudioEngine 的 tap ——
//  它直接用 AudioUnit（RemoteIO / VoiceProcessingIO）拉麦克风数据。
//  前两次 hook 完全没反应，就是因为挂错了地方。
//
//  AudioUnitRender 是从 input bus 取采集数据的唯一入口。
//  在它返回之后改写 ioData 里的 PCM，跟视频的原地改写同一套逻辑：
//    · 不造 buffer，不动所有权
//    · 只改 mData 里的样本
//    · 只碰 bus == 1（采集），绝不碰 bus == 0（播放，否则出回声）

typedef OSStatus (*VC_AURender_FN)(AudioUnit, AudioUnitRenderActionFlags *,
                                   const AudioTimeStamp *, UInt32, UInt32,
                                   AudioBufferList *);

static VC_AURender_FN orig_AudioUnitRender = NULL;

static void VCRewriteAudioBufferList(AudioBufferList *ioData, UInt32 frames)
{
    if (!ioData || frames == 0) return;

    VCamConfig *cfg = VCamConfig.shared;
    if (cfg.audioMode == VCAudioModeMic) return;

    // ---- 静音：整块清零 ----
    if (cfg.audioMode == VCAudioModeMute) {
        for (UInt32 b = 0; b < ioData->mNumberBuffers; b++) {
            AudioBuffer *buf = &ioData->mBuffers[b];
            if (buf->mData && buf->mDataByteSize) {
                memset(buf->mData, 0, buf->mDataByteSize);
            }
        }
        return;
    }

    // ---- 素材音轨 ----
    CMItemCount srcFrames = 0;
    AudioStreamBasicDescription asbd = {0};
    NSData *pcm = [[VCFrameSource shared] copyNextAudioPCMWithFrameCount:&srcFrames asbd:&asbd];
    if (!pcm || srcFrames == 0) return;

    const float *src = (const float *)pcm.bytes;
    size_t avail = pcm.length / sizeof(float);
    if (avail == 0) return;

    static BOOL sLogged = NO;
    if (!sLogged) {
        sLogged = YES;
        VCLog(@"AudioUnit 音频注入接通：%u 帧/块，%u 个 buffer，素材 %zu 样本 %.0fHz",
              (unsigned)frames, (unsigned)ioData->mNumberBuffers,
              avail, asbd.mSampleRate);
    }

    for (UInt32 b = 0; b < ioData->mNumberBuffers; b++) {
        AudioBuffer *buf = &ioData->mBuffers[b];
        if (!buf->mData || buf->mDataByteSize == 0) continue;

        UInt32 ch = buf->mNumberChannels ? buf->mNumberChannels : 1;
        float *dst = (float *)buf->mData;
        size_t total = buf->mDataByteSize / sizeof(float);
        size_t frameCount = total / ch;
        if (frameCount > frames) frameCount = frames;

        // 单声道素材展开到 N 声道交错布局，尾部补静音
        for (size_t i = 0; i < frameCount; i++) {
            float v = (i < avail) ? src[i] : 0.0f;
            for (UInt32 c = 0; c < ch; c++) {
                dst[i * ch + c] = v;
            }
        }
    }
}

static OSStatus hook_AudioUnitRender(AudioUnit unit,
                                     AudioUnitRenderActionFlags *flags,
                                     const AudioTimeStamp *ts,
                                     UInt32 bus,
                                     UInt32 frames,
                                     AudioBufferList *ioData)
{
    if (!orig_AudioUnitRender) return -1;

    OSStatus st = orig_AudioUnitRender(unit, flags, ts, bus, frames, ioData);
    if (st != noErr || !ioData) return st;

    // RemoteIO / VoiceProcessingIO：output bus = 0（播放），input bus = 1（采集）
    if (bus != 1) return st;

    static BOOL sLoggedBus = NO;
    if (!sLoggedBus) {
        sLoggedBus = YES;
        VCLog(@"AudioUnitRender 命中 input bus：frames=%u buffers=%u ch=%u",
              (unsigned)frames, (unsigned)ioData->mNumberBuffers,
              ioData->mNumberBuffers ? (unsigned)ioData->mBuffers[0].mNumberChannels : 0);
    }

    VCRewriteAudioBufferList(ioData, frames);
    return st;
}

// ==================================================================
#pragma mark - 采集输出：预览通道
// ==================================================================
// AVCaptureVideoPreviewLayer 走的是 GPU 直连，不经过 delegate，
// 只替换 data output 的话预览窗口还是真画面。这里叠一层盖住。

%hook AVCaptureVideoPreviewLayer

- (instancetype)initWithSession:(AVCaptureSession *)session
{
    id layer = %orig;
    if (layer && VCInjectionActive()) [VCOverlay attachToPreviewLayer:layer];
    return layer;
}

- (void)setSession:(AVCaptureSession *)session
{
    %orig;
    // 注入未启用：不往预览层上挂任何东西。
    // 那个 AVSampleBufferDisplayLayer 是 opaque 全屏层，
    // 挂在 AVCaptureVideoPreviewLayer 上会改变它的合成路径。
    if (!VCInjectionActive()) return;
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
#pragma mark - 后台控制：URL Scheme
// ==================================================================
//
//  完全去掉了悬浮球和面板 —— 那个全屏 window 是画面卡死的元凶，
//  而且它挡着抖音界面。改成用 URL Scheme 从外部控制：
//
//      vcam://on              开启注入
//      vcam://off             关闭注入
//      vcam://pause           暂停/继续
//      vcam://asset/demo1     切换素材（demo1 = 素材文件名，不带扩展）
//      vcam://audio/0|1|2     音频：0=真麦 1=素材 2=静音
//      vcam://status          仅拉起 App，不改配置
//
//  用法：Safari 地址栏敲一行，系统会问「是否在抖音中打开」，确认即可。
//  或者做成快捷指令放到桌面，点一下就切。

static void VCBootstrap(void);

static void VCApplyURL(NSURL *url)
{
    if (!url) return;

    NSString *host = url.host.lowercaseString;
    NSString *path = url.path;
    VCamConfig *cfg = VCamConfig.shared;

    if ([host isEqualToString:@"on"]) {
        cfg.injectEnabled = YES;
        [cfg persist];
        VCLog(@"URL 控制: 注入已开启");
    } else if ([host isEqualToString:@"off"]) {
        cfg.injectEnabled = NO;
        [cfg persist];
        VCLog(@"URL 控制: 注入已关闭");
    } else if ([host isEqualToString:@"pause"]) {
        cfg.paused = !cfg.paused;
        [cfg persist];
        VCLog(@"URL 控制: %@", cfg.paused ? @"已暂停" : @"已继续");
    } else if ([host isEqualToString:@"asset"]) {
        if (path.length > 1) {
            NSString *name = [path substringFromIndex:1];
            cfg.assetName = name;
            cfg.sourceKind = VCSourceKindAsset;
            [cfg persist];
            NSURL *u = [cfg assetURL];
            NSError *err = nil;
            if (u && [[VCFrameSource shared] reloadWithURL:u error:&err]) {
                VCLog(@"URL 控制: 素材切到 %@", name);
            } else {
                VCLog(@"URL 控制: 素材切换失败 %@", err);
            }
        }
    } else if ([host isEqualToString:@"audio"]) {
        NSInteger mode = path.length > 1 ? [[path substringFromIndex:1] integerValue] : -1;
        if (mode >= 0 && mode <= 2) {
            cfg.audioMode = (VCAudioMode)mode;
            [cfg persist];
            VCLog(@"URL 控制: 音频模式 %ld", (long)mode);
        }
    } else if ([host isEqualToString:@"status"]) {
        VCLog(@"URL 控制: 状态查询 inject=%d asset=%@",
              cfg.injectEnabled, cfg.assetName);
    } else {
        VCLog(@"URL 控制: 未知命令 %@", host);
    }
}

// ==================================================================
#pragma mark - 启动与生命周期
// ==================================================================

%hook UIApplication

- (BOOL)application:(UIApplication *)application
didFinishLaunchingWithOptions:(NSDictionary *)launchOptions
{
    BOOL ret = %orig;
    VCBootstrap();
    return ret;
}

// 后台控制入口：vcam://on / off / pause / asset/xxx / audio/0|1|2
- (BOOL)application:(UIApplication *)app
            openURL:(NSURL *)url
            options:(NSDictionary<UIApplicationOpenURLOptionsKey, id> *)options
{
    if ([url.scheme.lowercaseString isEqualToString:@"vcam"]) {
        VCApplyURL(url);
        VCBootstrap();   // 冷启动时 didFinishLaunching 可能还没走到
        return YES;
    }
    return %orig;
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

/// 真正去加载素材。下载线程回调到主线程后调用。
static void VCLoadAssetNow(void)
{
    VCamConfig *c = VCamConfig.shared;
    if ([VCFrameSource shared].isReady) {
        VCRemoteLog(@"装载跳过：已经是就绪状态");
        return;
    }

    NSURL *url = [c assetURL];
    if (!url) {
        VCRemoteLog(@"装载失败：沙盒里没有 %@.mp4，目录=%@",
                    c.assetName, [c assetDirectory]);
        return;
    }

    NSError *err = nil;
    if (![[VCFrameSource shared] reloadWithURL:url error:&err]) {
        VCRemoteLog(@"装载失败：%@ (%@)", err.localizedDescription, url.lastPathComponent);
    } else {
        VCRemoteLog(@"装载成功：%@", url.lastPathComponent);
    }
}

static void VCBootstrap(void)
{
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        VCamConfig *cfg = VCamConfig.shared;

        // 静默模式：注入没开就完全不碰素材、不连实时源、不解码。
        if (VCInjectionActive()) {
            VCRemoteLog(@"bootstrap: asset=%@ host=%@:%u src=%ld inject=%d",
                        cfg.assetName, cfg.liveHost, cfg.httpPort,
                        (long)cfg.sourceKind, cfg.injectEnabled);

            // 实时源先连上，跟素材下载互不干扰
            if (cfg.sourceKind == VCSourceKindLive && cfg.liveHost.length > 0) {
                [[VCLiveSource shared] connectToHost:cfg.liveHost port:cfg.livePort];
            }

            // 素材可能还在电脑上 —— 抖音是「苹果正版」，爱思助手不给浏览
            // 沙盒，没法手动拖文件进去。所以这里后台拉一次再加载。
            dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
                VCamConfig *c = VCamConfig.shared;
                if (c.sourceKind == VCSourceKindAsset) {
                    BOOL got = [c ensureAssetDownloaded];
                    VCRemoteLog(@"素材就位=%d 目录=%@", got, [c assetDirectory]);
                }
                dispatch_async(dispatch_get_main_queue(), ^{
                    VCLoadAssetNow();
                });
            });
        } else {
            VCRemoteLog(@"注入未启用 → 静默模式：不加载素材、不连实时源");
        }

        // 面板不再挂载 —— 改成后台程序，用 URL Scheme 控制（见 VCApplyURL）。
        // 那个全屏 UIWindow 是「点一下画面就冻住」的元凶，去掉之后
        // dylib 在进程里只剩帧注入这一条链路，屏幕上什么都不多出来。

        VCLog(@"VCam 已就绪（后台模式，无 UI。用 vcam://on 开启注入）");
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

            // 2. AudioUnit 采集入口 —— 抖音的音频真正走这条。
            //    AudioUnitRender 是 C 函数，用 fishhook 按符号名重绑定。
            //    挂不上也不会崩，只是没效果，这里把结果打出来便于判断。
            BOOL auHooked = VCHookSymbol("AudioUnitRender",
                                         (void *)hook_AudioUnitRender,
                                         (void **)&orig_AudioUnitRender);
            VCLog(@"AudioUnitRender hook %@ (orig=%p)",
                  auHooked ? @"已安装" : @"失败", orig_AudioUnitRender);

            // 3. 兜底：即使 didFinishLaunching hook 没命中（SceneDelegate 流程），
            //    延迟一段时间也把素材拉起来
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                VCBootstrap();
            });
        }
    }
}
