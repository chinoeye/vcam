//
//  Tweak.xm
//  主 hook。所有出口都在这里封堵。
//
//  hook 全部落在 AVFoundation 层，因此对抖音/快手/微信天然通用，
//  新增 App 只需要往 VCam.plist 的 Filter.Bundles 里加 bundle id。
//

#include <dlfcn.h>   // dlsym / RTLD_NEXT
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <QuartzCore/QuartzCore.h>

#import "VCamConfig.h"
#import "VCFrameSource.h"
#import "VCAudioPipeline.h"
#import "VCAudioSource.h"
#import "VCLiveSource.h"
#import "VCCaptureProxy.h"
#import "VCOverlay.h"
#import "VCHide.h"
#import "VCSampleBufferFactory.h"
#import "VCLog.h"
#import "VCSubstrateCompat.h"

#import <math.h>
#import <stdlib.h>
#import <string.h>
#import <objc/runtime.h>
#import <mach-o/dyld.h>
#import <mach-o/nlist.h>
#import <mach-o/loader.h>
#import <mach/vm_types.h>

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

// 前向声明：这两个定义在文件末尾，但 %hook UIWindow 里要先用到。
// 忘了这一行就是 "call to undeclared function" 编译错误。
static void VCDumpLogAlert(void);
static void VCDumpAudioReport(void);

/// 取当前 key window。
///
/// UIApplication.windows 在 iOS 15 被标记废弃，而本项目开了 -Werror，
/// 分散在各个函数里写会把 deprecation 警告升成编译错误。
/// 统一收口到这里，用 pragma 局部关掉警告，其余代码照常严格。
static UIWindow *VCKeyWindow(void)
{
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    UIWindow *win = nil;
    for (UIWindow *w in UIApplication.sharedApplication.windows) {
        if (w.isKeyWindow) { win = w; break; }
    }
    if (!win) win = UIApplication.sharedApplication.windows.firstObject;
    return win;
#pragma clang diagnostic pop
}

/// 从 key window 找到最顶层的 view controller，用来弹 alert。
static UIViewController *VCTopViewController(void)
{
    UIViewController *vc = VCKeyWindow().rootViewController;
    while (vc.presentedViewController) {
        vc = vc.presentedViewController;
    }
    return vc;
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
#pragma mark - 音频会话：强制 48000Hz
// ==================================================================
//
//  实测这台机器上系统侧是 44100Hz，而素材和解码器都是 48000Hz。
//  两边不一致会带来两个麻烦：
//    1) 每块都要重采样，48k -> 44.1k，多一次运算
//    2) 按源样本数推算的时间比实际播放快 8.8%，几秒就撞同步阈值导致断音
//
//  与其在转换链路上打补丁，不如把音频会话直接设成 48000 ——
//  两边对齐之后 ratio = 1.0，既没有重采样开销，也没有速率差。
//
//  注意：这里只是「偏好设置」，系统可能拒绝。拒绝也不会崩，退回重采样即可。

%hook AVAudioSession

- (BOOL)setSampleRate:(double)sampleRate error:(NSError **)outError
{
    double target = 48000.0;
    BOOL ok = %orig(target, outError);
    if (ok) {
        if (fabs(sampleRate - target) > 1.0) {
            VCLog(@"音频会话采样率已改写: %.0f -> %.0f", sampleRate, target);
        }
    } else {
        VCLog(@"音频会话采样率改写失败（原 %.0f），继续走重采样", sampleRate);
    }
    return ok;
}

- (BOOL)setPreferredSampleRate:(double)sampleRate error:(NSError **)outError
{
    double target = 48000.0;
    BOOL ok = %orig(target, outError);
    if (ok) {
        VCLog(@"音频会话首选采样率已设为 %.0f", target);
    }
    return ok;
}

%end
// AVAudioEngine 的 tap 路径已废弃：抖音音频走 AudioUnit，
// 这条路从未被调用过（实测 installTapOnBus 一次都没命中）。


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


// ---- AudioUnitSetProperty hook：把音频格式的采样率钉成 48000 ----
//
//  抖音的音频会话走的是私有的 AudioSession.framework，
//  hook AVAudioSession 的 setSampleRate 完全不起作用（实测系统仍是 44100）。
//  但它最终一定要调 AudioUnitSetProperty 设置具体 AudioUnit 的格式，
//  那一步绕不过去。
//
//  两边采样率一致之后：
//    ratio = 1.0 -> 不需要重采样 -> 没有速率差 -> 不会周期性 seek -> 没有断点
typedef OSStatus (*VC_AUSetProp_FN)(AudioUnit, AudioUnitPropertyID, AudioUnitScope,
                                    AudioUnitElement, const void *, UInt32);
static VC_AUSetProp_FN orig_AudioUnitSetProperty = NULL;

// ==================================================================
#pragma mark - AudioUnitAddRenderNotify 诊断
// ==================================================================
//
//  为什么加这个：
//    hook AudioUnitRender 拿到的 ioData->mBuffers[0].mDataByteSize 是 40960，
//    而 frames=1024、bytesPerFrame=4 按契约只应该是 4096 —— 差 10 倍。
//    分不清是抖音配置特殊，还是我读的时机不对（读到的是缓冲区容量
//    而不是本次要填的长度）。
//
//    AudioUnitAddRenderNotify 是系统标准 API：每次渲染**前**(PreRender)
//    和**后**(PostRender)各回调一次，frames 和 ioData 都由系统直接给出，
//    时机明确，可以对照出真实值。
//
//  这里只记录，绝不修改 ioData —— 不影响现有音频输出。

typedef OSStatus (*VC_AddRenderNotify_FN)(AudioUnit, AURenderCallback, void *);
static VC_AddRenderNotify_FN orig_AddRenderNotify = NULL;

static volatile int    g_rnInstalled  = 0;
static volatile int    g_rnRegResult  = -999;
static volatile UInt32 g_rnCalls      = 0;
static volatile UInt32 g_rnPreCalls   = 0;
static volatile UInt32 g_rnPostCalls  = 0;
static volatile UInt32 g_rnPreFrames  = 0;
static volatile UInt32 g_rnPreBytes   = 0;
static volatile UInt32 g_rnPostBytes  = 0;
static volatile UInt32 g_rnBus        = 0xFFFF;
static volatile UInt32 g_rnBufs       = 0;
static volatile UInt32 g_rnBpf        = 0;

static OSStatus VCRenderNotify(void *refCon,
                               AudioUnitRenderActionFlags *flags,
                               const AudioTimeStamp *ts,
                               UInt32 bus,
                               UInt32 frames,
                               AudioBufferList *ioData)
{
    g_rnCalls++;
    g_rnBus  = bus;
    g_rnBufs = ioData ? ioData->mNumberBuffers : 0;

    if (flags && (*flags & kAudioUnitRenderAction_PreRender)) {
        g_rnPreCalls++;
        g_rnPreFrames = frames;
        if (ioData && ioData->mNumberBuffers > 0) {
            g_rnPreBytes = (UInt32)ioData->mBuffers[0].mDataByteSize;
            if (frames > 0) {
                g_rnBpf = (UInt32)(ioData->mBuffers[0].mDataByteSize / frames);
            }
        }
    } else if (flags && (*flags & kAudioUnitRenderAction_PostRender)) {
        g_rnPostCalls++;
        if (ioData && ioData->mNumberBuffers > 0) {
            g_rnPostBytes = (UInt32)ioData->mBuffers[0].mDataByteSize;
        }
    }
    return noErr;
}

/// 给某个 unit 挂 RenderNotify。重复调用无副作用。
static void VCInstallRenderNotify(AudioUnit unit)
{
    if (!unit) return;
    if (!orig_AddRenderNotify) {
        orig_AddRenderNotify = (VC_AddRenderNotify_FN)
            dlsym(RTLD_NEXT, "AudioUnitAddRenderNotify");
        if (!orig_AddRenderNotify) {
            VCLog(@"RenderNotify: dlsym 拿不到符号");
            return;
        }
    }
    OSStatus r = orig_AddRenderNotify(unit, VCRenderNotify, NULL);
    g_rnRegResult = (int)r;
    g_rnInstalled = (r == noErr) ? 1 : 0;
    VCLog(@"RenderNotify 注册 %@ (ret=%d, unit=%p)",
          r == noErr ? @"成功" : @"失败", (int)r, unit);
}

static OSStatus hook_AudioUnitSetProperty(AudioUnit unit,
                                          AudioUnitPropertyID prop,
                                          AudioUnitScope scope,
                                          AudioUnitElement elem,
                                          const void *data,
                                          UInt32 size)
{
    if (!orig_AudioUnitSetProperty) return -1;

    if (prop == kAudioUnitProperty_StreamFormat &&
        data && size == sizeof(AudioStreamBasicDescription)) {
        AudioStreamBasicDescription asbd =
            *(const AudioStreamBasicDescription *)data;

        // ★ 第 15 版：**不再把采样率改成 48000**。
        //
        //  以前这里会把 44100 强行改成 48000，理由是「素材是 48k，省一次重采样」。
        //  代价是致命的：AudioUnit 跑在 48k，而抖音写文件时仍然按它自己记录的
        //  44100 封装 —— 于是每一秒的真实时间被写成 1.088 秒的音频，
        //  音频整体慢 8.8%、降调 8.8%，而且和画面越拉越远。
        //
        //  实测铁证（IMG_1090.MOV，16.35 s 的录制成品）：
        //      音频样本数 731136（按 48k 产出） ÷ 44100 = 16.58 s
        //      成品音轨 L/R 相关系数 = 1.000000  ← 确实是我们的单声道复制
        //      但与素材音轨做互相关，任何位置都只有 0.03  ← 时基被改了
        //
        //  保持 App 自己请求的采样率，让我们的填充与它的写入时基一致。
        static int sCount = 0;
        if (sCount++ < 3) {
            VCLog(@"AudioUnitSetProperty: 采样率 %.0f（保持原样，不强改）",
                  asbd.mSampleRate);
        }
    }
    // 遇到「输入回调」或「格式设置」时挂 RenderNotify。
    // 2005 = kAudioOutputUnitProperty_SetInputCallback
    if (prop == kAudioUnitProperty_StreamFormat || prop == 2005) {
        if (!g_rnInstalled && g_rnRegResult != 0) {
            VCInstallRenderNotify(unit);
        }
    }

    return orig_AudioUnitSetProperty(unit, prop, scope, elem, data, size);
}

// hook 命中统计。诊断报告里直接读这些值，一眼看出 hook 到底装没装上、
// 有没有被调用、调的时候 bus 是多少。
static volatile int    g_auHookInstalled = 0;
static volatile int    g_auRenderHits    = 0;
static volatile int    g_auBus1Hits      = 0;
static volatile UInt32 g_auLastBus       = 0xFFFF;
static volatile UInt32 g_auLastFrames    = 0;
static volatile UInt32 g_auLastBuffers   = 0;
static volatile UInt32 g_auLastChannels  = 0;
static volatile UInt32 g_auLastBytes     = 0;
static volatile uintptr_t g_auFirstUnit  = 0;      // 第一个 AudioUnit 实例
static volatile int    g_auUnitSwitches  = 0;      // 换过几个不同实例
static volatile UInt32 g_auMinFrames     = 0xFFFFFFFF;
static volatile UInt32 g_auMaxFrames     = 0;
static volatile double g_auSumFrames     = 0;
static volatile UInt32 g_auSysSampleRate = 0;      // 系统实际采样率
static volatile UInt32 g_auSysChannels   = 0;
static volatile UInt32 g_auSysBits       = 0;
static volatile UInt32 g_auSysFlags      = 0;
static volatile UInt32 g_auSysBytesPerFrame = 0;
static volatile int    g_auAsbdProbed    = 0;

// 素材 PCM 的实际格式 —— 在真正写入的那一刻捕获。
// 不能用 copyNextAudioPCM 单独探测：那个函数带音画同步逻辑，
// 超前/落后时会主动返回 nil，探测出来全是 0。

// 音频写入每次提前返回的原因。
// 报告里直接读，一眼看出卡在哪一步 —— 比猜省事。
//   0 = 正常写入
//   1 = audioMode 是 Mic
//   2 = audioMode 是 Mute
//   3 = 系统格式无效（g_auSys* 还没探到）
//   4 = 转换器创建失败
//   5 = 源数据为空（copyNextAudioPCM 一直返回 nil）
static volatile int g_audioBail = 0;
static volatile int g_audioWriteOK = 0;

// ---- 音频处理说明 ----
//
//  实测这台机器上两侧格式完全不同：
//    素材侧（AVAssetReader）  float32 / 单声道 / 48000 Hz / 每样本 4 字节
//    系统侧（AudioUnit 采集）  int16   / 双声道 / 44100 Hz / 每帧 4 字节
//                              formatFlags = 0xc = packed | signed int
//
//  所以必须做真正的重采样 + 位深转换 + 声道扩展。
//  这部分逻辑现在全部在 VCAudioPipeline 的后台线程里完成，
//  实时线程只从环形缓冲 memcpy —— 不在这里做任何转换。

// 原始函数的保存点。fishhook 绑定成功后把原地址写到这里，
// hook 内部必须先调它、再处理数据 —— 少这一行整个 hook 逻辑就崩了。
static VC_AURender_FN orig_AudioUnitRender = NULL;


// ---- 手机端指标上报用的全局计数器 ----
//  必须在 hook 之前声明：hook_AudioUnitRender 在文件中部，会用到这些。
volatile int    g_statVideoDelegates = 0;
volatile int    g_statAudioCalls     = 0;

static OSStatus hook_AudioUnitRender(AudioUnit unit,
                                     AudioUnitRenderActionFlags *flags,
                                     const AudioTimeStamp *ts,
                                     UInt32 bus,
                                     UInt32 frames,
                                     AudioBufferList *ioData)
{
    if (!orig_AudioUnitRender) return -1;

    g_auRenderHits++;
    g_statAudioCalls++;

    // 记录 AudioUnit 实例：如果换过实例，说明抖音开了多条音频通路
    if (g_auFirstUnit == 0) {
        g_auFirstUnit = (uintptr_t)unit;
    } else if ((uintptr_t)unit != g_auFirstUnit) {
        g_auUnitSwitches++;
    }

    // 帧数分布：判断是不是变长 buffer
    if (frames < g_auMinFrames) g_auMinFrames = frames;
    if (frames > g_auMaxFrames) g_auMaxFrames = frames;
    g_auSumFrames += (double)frames;

    // 只查一次系统音频格式 —— 采样率对不上会导致变速、变调、沙沙声
    if (!g_auAsbdProbed) {
        AudioStreamBasicDescription asbd;
        UInt32 sz = sizeof(asbd);
        // 注意 scope：AudioUnitRender(..., bus=1, ...) 取的是 input element
        // 的 **output scope**。之前写成 kAudioUnitScope_Input，拿到的是
        // 麦克风硬件那一侧的格式，跟实际填进 buffer 的不是同一个东西 ——
        // 所以报告里出现「缓冲区声道=2 / 系统声道=1」这种矛盾。
        OSStatus r = AudioUnitGetProperty(unit,
                                          kAudioUnitProperty_StreamFormat,
                                          kAudioUnitScope_Output,
                                          bus,
                                          &asbd,
                                          &sz);
        if (r == noErr) {
            g_auAsbdProbed    = 1;
            g_auSysSampleRate = (UInt32)asbd.mSampleRate;
            g_auSysChannels   = asbd.mChannelsPerFrame;
            g_auSysBits       = asbd.mBitsPerChannel;
            g_auSysFlags      = asbd.mFormatFlags;
            g_auSysBytesPerFrame = asbd.mBytesPerFrame;
        }
    }

    g_auLastBus      = bus;
    g_auLastFrames   = frames;
    g_auLastBuffers  = ioData ? ioData->mNumberBuffers : 0;
    g_auLastChannels = (ioData && ioData->mNumberBuffers)
                       ? ioData->mBuffers[0].mNumberChannels : 0;
    g_auLastBytes    = (ioData && ioData->mNumberBuffers)
                       ? (UInt32)ioData->mBuffers[0].mDataByteSize : 0;

    OSStatus st = orig_AudioUnitRender(unit, flags, ts, bus, frames, ioData);
    if (st != noErr || !ioData) return st;

    // 只碰 input bus（1 = 采集）。碰 bus 0（播放）会把麦克风数据灌进扬声器。
    if (bus != 1) return st;
    g_auBus1Hits++;

    static BOOL sLoggedHit = NO;
    if (!sLoggedHit) {
        sLoggedHit = YES;
        VCLog(@"★ AudioUnitRender 命中 input bus：frames=%u buffers=%u ch=%u —— hook 生效",
              (unsigned)frames, (unsigned)ioData->mNumberBuffers,
              ioData->mNumberBuffers ? (unsigned)ioData->mBuffers[0].mNumberChannels : 0);
    }

    // ---- 音频处理：全部交给管道 ----
    //
    // 这里只做两件事：
    //   1) 告诉管道目标格式（第一次拿到就设，之后内部自己判断是否变化）
    //   2) 让它填数据
    //
    // 解码、重采样、时间同步、seek 校正都在管道后台线程里做，
    // 这一行实际只是从环形缓冲 memcpy —— 纳秒级，不会拖住实时线程。
    VCamConfig *cfg = VCamConfig.shared;
    if (cfg.audioMode == VCAudioModeMic) {
        return st;                    // 真麦：原样透传，什么都不动
    }

    VCAudioPipeline *pipe = [VCAudioPipeline shared];

    if (cfg.audioMode == VCAudioModeMute) {
        for (UInt32 b = 0; b < ioData->mNumberBuffers; b++) {
            AudioBuffer *buf = &ioData->mBuffers[b];
            if (buf->mData && buf->mDataByteSize) {
                memset(buf->mData, 0, buf->mDataByteSize);
            }
        }
        [pipe stop];
        g_audioBail = 2;
        return st;
    }

    // 素材音轨。
    //
    // setTargetFormat 只在格式真的变化时才调用 —— 它内部会重建环形缓冲
    // 和转换器，每秒调 47 次等于每秒重建 47 次，缓冲永远是空的。
    // 这里用人手做一次「上次设置的格式」缓存，避免每帧都进去比较。
    static UInt32 sLastRate = 0, sLastCh = 0, sLastBits = 0, sLastFlags = 0, sLastBpf = 0;
    if (g_auSysSampleRate > 0 &&
        (g_auSysSampleRate  != sLastRate  ||
         g_auSysChannels    != sLastCh    ||
         g_auSysBits        != sLastBits  ||
         g_auSysFlags       != sLastFlags ||
         g_auSysBytesPerFrame != sLastBpf)) {

        sLastRate  = g_auSysSampleRate;
        sLastCh    = g_auSysChannels;
        sLastBits  = g_auSysBits;
        sLastFlags = g_auSysFlags;
        sLastBpf   = g_auSysBytesPerFrame;

        AudioStreamBasicDescription dst = {0};
        dst.mSampleRate       = g_auSysSampleRate;
        dst.mFormatID         = kAudioFormatLinearPCM;
        dst.mFormatFlags      = g_auSysFlags;
        dst.mChannelsPerFrame = g_auSysChannels;
        dst.mBitsPerChannel   = g_auSysBits;
        dst.mBytesPerFrame    = g_auSysBytesPerFrame;
        dst.mBytesPerPacket   = g_auSysBytesPerFrame;
        dst.mFramesPerPacket  = 1;
        [pipe setTargetFormat:dst];
    }

    [pipe fillIOData:ioData frames:frames];
    g_audioBail = 0;
    g_audioWriteOK++;
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

// ==================================================================
#pragma mark - 手机端指标上报
// ==================================================================
//
//  电脑上看不到手机发生了什么：iOS 15 上 syslog_relay 废弃、
//  os_trace_relay 拿不到 NSLog、house_arrest 要求 App 开 UIFileSharingEnabled、
//  com.apple.afc 被拒。四条路全断。
//
//  所以 dylib 主动把关键指标 GET 回电脑（VCRemoteLog → /vcam-log），
//  电脑端 rangeserver 落到 logs/phone-YYYYMMDD.log，可以实时 tail 看。
//
//  每秒一行，只报变化量，避免刷屏。


static void VCStartStatReporter(void)
{
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        dispatch_source_t t = dispatch_source_create(
            DISPATCH_SOURCE_TYPE_TIMER, 0, 0,
            dispatch_get_global_queue(QOS_CLASS_UTILITY, 0));
        dispatch_source_set_timer(t,
            dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC),
            1 * NSEC_PER_SEC, 100 * NSEC_PER_MSEC);
        dispatch_source_set_event_handler(t, ^{
            static int sPrevV = 0, sPrevA = 0;
            int v = g_statVideoDelegates;
            int a = g_statAudioCalls;
            int dv = v - sPrevV;
            int da = a - sPrevA;
            sPrevV = v; sPrevA = a;

            VCAudioPipeline *pipe = [VCAudioPipeline shared];
            VCRemoteLog(@"STAT vDeleg=%d/s(%d) aCalls=%d/s(%d) "
                        @"vSrc=%.2f aDec=%.2f buf=%.0fms err=%+.0fms "
                        @"produced=%llu consumed=%llu under=%llu",
                        dv, v, da, a,
                        [VCFrameSource shared].currentVideoSourceTime,
                        pipe.decodedMaterialSeconds,
                        pipe.currentDrift * 1000.0,
                        (pipe.decodedMaterialSeconds - pipe.currentDrift
                         - [VCFrameSource shared].currentVideoSourceTime) * 1000.0,
                        pipe.producedFrames, pipe.consumedFrames,
                        pipe.underrunCount);
        });
        dispatch_resume(t);
        VCLog(@"指标上报已启动（每秒一次 → /vcam-log）");
    });
}

/// 预热音频管道：在 App 启动时就建好环形缓冲并填满数据。
///
/// 为什么必须预热：
///   管道若等到第一次 AudioUnitRender 才启动，环形缓冲是空的，
///   填满 2 秒期间实时线程只能输出静音；而抖音的音频时间照走，
///   于是音频内容永远比视频晚一个「填缓冲耗时」—— 实测 -2.38 秒。
///
///   在这里提前跑，等用户真去点录制时缓冲已经满了，
///   AudioUnitRender 第一次调用就能拿到真实数据，没有静音段。
///
/// 格式用 44100/2ch/16bit：这是抖音**真实**的系统格式（日志实测）。
///
///  以前这里写的是 48000 —— 那是我们强行改采样率时代的残留。
///  结果每次录制都会因为「格式不符」重建一次管道：
///  预热的 2 秒白填，还得靠 setTargetFormat 重新填，录制开头就有缺口。
///  现在预设与真实一致，录制开始时缓冲已经是满的。
static void VCPrewarmAudioPipeline(void)
{
    VCamConfig *cfg = VCamConfig.shared;
    if (cfg.audioMode != VCAudioModeAsset) return;
    if (![VCAudioSource shared].ready) {
        VCLog(@"预热跳过：音频源还没就绪");
        return;
    }

    AudioStreamBasicDescription def = {0};
    def.mSampleRate       = 44100;
    def.mFormatID         = kAudioFormatLinearPCM;
    def.mFormatFlags      = kAudioFormatFlagIsSignedInteger |
                            kAudioFormatFlagsNativeEndian |
                            kAudioFormatFlagIsPacked;
    def.mChannelsPerFrame = 2;
    def.mBitsPerChannel   = 16;
    def.mBytesPerFrame    = 4;
    def.mBytesPerPacket   = 4;
    def.mFramesPerPacket  = 1;

    [[VCAudioPipeline shared] setTargetFormat:def];
    VCLog(@"音频管道预热已触发（缓冲将在约 2 秒内填满）");
}

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
            // 音频走独立模块，需要单独加载同一个素材
            [[VCAudioSource shared] loadURL:u error:NULL];
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
    // 用 performSelector：这个方法在本 %hook 块里定义在后面，
    // 直接调会被编译器判「no visible @interface」。
    [self performSelector:@selector(vc_installGesturesIfNeeded)];
}

/// 给这个 window 装双指/三指长按，重复调用无副作用。
///
/// 不能只依赖 makeKeyAndVisible：抖音的窗口可能在我们注入之前就已经可见，
/// 那个方法之后再也不被调用 —— 手势永远装不上，症状是「长按完全没反应」。
/// %ctor 里还挂了个定时器反复补装。
- (void)vc_installGesturesIfNeeded
{
    static const void *kGestureKey = &kGestureKey;
    if (objc_getAssociatedObject(self, kGestureKey)) return;

    UILongPressGestureRecognizer *g2 =
        [[UILongPressGestureRecognizer alloc]
            initWithTarget:self
                    action:@selector(vc_handleTwoFinger:)];
    g2.numberOfTouchesRequired = 2;
    g2.minimumPressDuration = 1.5;
    g2.cancelsTouchesInView = NO;
    [self addGestureRecognizer:g2];

    UILongPressGestureRecognizer *g3 =
        [[UILongPressGestureRecognizer alloc]
            initWithTarget:self
                    action:@selector(vc_handleThreeFinger:)];
    g3.numberOfTouchesRequired = 3;
    g3.minimumPressDuration = 1.0;
    g3.cancelsTouchesInView = NO;
    [self addGestureRecognizer:g3];

    objc_setAssociatedObject(self, kGestureKey, g2,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    VCLog(@"手势已装上: %@ (共 %lu 个手势)",
          NSStringFromClass([self class]),
          (unsigned long)self.gestureRecognizers.count);
}

- (void)vc_handleTwoFinger:(UILongPressGestureRecognizer *)g
{
    if (g.state == UIGestureRecognizerStateBegan) {
        VCDumpAudioReport();
    }
}

// 三指长按：循环切换 audioMode。
//
// 存在的意义是省掉「改代码 → 编译 2 分钟 → 注入 → 重开」这个循环。
// 三种模式互相对照，几秒钟就能判断问题出在采集、写入还是素材本身：
//   0 真麦   → 应该听到自己的声音（验证链路本身没坏）
//   1 素材   → 应该听到 test_demo
//   2 静音   → 应该完全无声（验证清零范围够不够）
- (void)vc_handleThreeFinger:(UILongPressGestureRecognizer *)g
{
    if (g.state != UIGestureRecognizerStateBegan) return;

    VCamConfig *cfg = VCamConfig.shared;
    NSInteger next = ((NSInteger)cfg.audioMode + 1) % 3;
    [cfg setAudioMode:(VCAudioMode)next];

    NSString *name = next == 0 ? @"真麦克风" : (next == 1 ? @"素材音轨" : @"静音");
    VCLog(@"三指切换 audioMode -> %ld (%@)", (long)next, name);

    // 轻震动反馈
    UIImpactFeedbackGenerator *fb =
        [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleMedium];
    [fb impactOccurred];

    UIAlertController *a =
        [UIAlertController alertControllerWithTitle:@"音频模式"
                                           message:[NSString stringWithFormat:
                        @"已切换到 %@ (%ld)\n\n直接录一段试试，不用重新编译。",
                        name, (long)next]
                                    preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"好"
                                          style:UIAlertActionStyleCancel
                                        handler:nil]];
    UIViewController *vc = VCTopViewController();
    [vc presentViewController:a animated:NO completion:nil];
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
    [[VCAudioSource shared] loadURL:url error:NULL];
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
            // 沙盒，没法手动拖文件进去。
            //
            // ★ 第 19 版：**先加载，再后台补缓存**，绝不能等下载完。
            //
            //  以前这里是「ensureAssetDownloaded 下完 → 才 VCLoadAssetNow」。
            //  7 MB 的素材没事，348 MB 的就要几分钟 —— 而这几分钟里用户点进
            //  录制页，帧源一帧都拿不到：黑屏，然后被系统 watchdog 杀掉。
            //  实测日志：
            //      本地无素材，从 192.168.3.88:8088 拉 /current.mp4
            //      出帧 #1..已出=0 本次取=0 素材位置=0.000   ← 连续 25 次拿不到帧
            //      （进程消失）
            //
            //  现在assetURL 本来就是「本地有就用本地，没有就 HTTP 直连」，
            //  所以直接加载即可：小素材本地秒开，大素材按需拉几 MB 开播。
            //  下载退化成后台缓存，只为下次启动更快，不再挡路。
            dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
                VCamConfig *c = VCamConfig.shared;
                if (c.sourceKind == VCSourceKindAsset) {
                    dispatch_async(dispatch_get_main_queue(), ^{
                        VCLoadAssetNow();
                        VCPrewarmAudioPipeline();
                        VCStartStatReporter();
                    });
                    BOOL got = [c ensureAssetDownloaded];
                    VCRemoteLog(@"后台缓存%@（不影响当前播放）", got ? @"已就绪" : @"未完成");
                } else {
                    dispatch_async(dispatch_get_main_queue(), ^{
                        VCLoadAssetNow();
                        VCPrewarmAudioPipeline();
                        VCStartStatReporter();
                    });
                }
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
#pragma mark - 日志上屏
// ==================================================================
//
//  现场调试最大的障碍是「看不见」。iOS 15 上：
//    syslog_relay      不出数据
//    os_trace_relay    协议不符
//    house_arrest      抖音没开 UIFileSharingEnabled
//    com.apple.afc     被拒
//
//  所以直接弹到屏幕上，用户截图即可。
//  触发方式：摇一摇手机（UIEventSubtypeMotionShake）。

static void VCDumpLogAlert(void)
{
    NSString *path = VCLogFilePath();
    NSString *content = path.length
        ? [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:NULL]
        : nil;

    if (content.length == 0) {
        content = [NSString stringWithFormat:@"日志为空\npath=%@", path ?: @"(nil)"];
    }

    // 只显示最后 24 行，太长塞不下
    NSMutableArray<NSString *> *lines =
        [[content componentsSeparatedByString:@"\n"] mutableCopy];
    if (lines.count > 24) {
        [lines removeObjectsInRange:NSMakeRange(0, lines.count - 24)];
    }
    NSString *text = [lines componentsJoinedByString:@"\n"];
    if (text.length > 1800) {
        text = [text substringFromIndex:text.length - 1800];
    }

    dispatch_async(dispatch_get_main_queue(), ^{
        UIAlertController *alert =
            [UIAlertController alertControllerWithTitle:@"VCam 日志（摇一摇）"
                                               message:text
                                        preferredStyle:UIAlertControllerStyleAlert];

        [alert addAction:[UIAlertAction actionWithTitle:@"复制"
                                                  style:UIAlertActionStyleDefault
                                                handler:^(UIAlertAction *a) {
            [UIPasteboard generalPasteboard].string = content;
        }]];
        [alert addAction:[UIAlertAction actionWithTitle:@"关闭"
                                                  style:UIAlertActionStyleCancel
                                                handler:nil]];

        UIViewController *vc = VCTopViewController();
        if (vc) {
            [vc presentViewController:alert animated:NO completion:nil];
        } else {
            // 拿不到 viewController 时退回到剪贴板
            [UIPasteboard generalPasteboard].string = content;
        }
    });
}

// ==================================================================
#pragma mark - 音频架构诊断（一次性看清，不用穷举）
// ==================================================================
//
//  前三次 hook 全部落空（AVCaptureAudioDataOutput / AVAudioEngine tap /
//  AudioUnitRender），根本问题是：不知道抖音到底用什么采音频，
//  每次改都是在赌。
//
//  这个函数把答案直接读出来：
//    · 已加载的全部镜像（谁在里面）
//    · 所有名称里含 Audio/Mic/Voice/Record/Capture/PCM/Sound/Unit 的类
//    · 这些类里跟采集相关的 selector
//
//  抖音的 __TEXT,__text 是加密的（cryptid=1），但 ObjC 的类名和方法名
//  存在 __objc_classname / __objc_methname 段，**不加密**，
//  运行时通过 runtime API 就能全部拿到。
//
//  结果写文件 + 塞剪贴板，再弹窗提示。

/// 列出某个镜像「导入了哪些外部符号」。
///
/// 这是判断一个 C/C++ framework 用什么系统 API 最直接的办法：
/// byteaudio 没有 ObjC 类名（纯 C++），但它的 __la_symbol_ptr / __got
/// 里存着它调用的每个系统函数名 —— AudioUnitRender 还是 AudioQueueNewInput，
/// 一眼就能看出来，不用再逐个 hook 试探。
__attribute__((unused))
static void VCDumpImageImports(const char *pathFragment, NSMutableString *out)
{
    if (!pathFragment || !out) return;

    uint32_t n = _dyld_image_count();
    for (uint32_t i = 0; i < n; i++) {
        const char *nm = _dyld_get_image_name(i);
        if (!nm || !strstr(nm, pathFragment)) continue;

        const struct mach_header_64 *h =
            (const struct mach_header_64 *)_dyld_get_image_header(i);
        if (!h) continue;
        intptr_t slide = _dyld_get_image_vmaddr_slide(i);

        [out appendFormat:@"\n--- %s ---\n", nm];

        // 找 __LINKEDIT / LC_SYMTAB / LC_DYSYMTAB
        const struct symtab_command  *symtab  = NULL;
        const struct dysymtab_command *dysym  = NULL;
        uintptr_t linkeditVM = 0, linkeditOff = 0;

        const struct load_command *cmd =
            (const struct load_command *)(h + 1);
        for (uint32_t c = 0; c < h->ncmds; c++) {
            if (cmd->cmd == LC_SEGMENT_64) {
                const struct segment_command_64 *seg =
                    (const struct segment_command_64 *)cmd;
                if (strncmp(seg->segname, "__LINKEDIT", 16) == 0) {
                    linkeditVM  = seg->vmaddr;
                    linkeditOff = seg->fileoff;
                }
            } else if (cmd->cmd == LC_SYMTAB) {
                symtab = (const struct symtab_command *)cmd;
            } else if (cmd->cmd == LC_DYSYMTAB) {
                dysym = (const struct dysymtab_command *)cmd;
            }
            cmd = (const struct load_command *)((const char *)cmd + cmd->cmdsize);
        }

        if (!symtab || !dysym || !linkeditVM) {
            [out appendString:@"  (找不到符号表)\n"];
            continue;
        }

        intptr_t base = (intptr_t)(linkeditVM - linkeditOff) + slide;
        const struct nlist_64 *syms = (const struct nlist_64 *)(base + symtab->symoff);
        const char *strs = (const char *)(base + symtab->stroff);
        const uint32_t *indirect = (const uint32_t *)(base + dysym->indirectsymoff);

        // 只关心音频相关的导入
        static const char *kw[] = { "Audio", "audio", "AURemote", "AudioUnit",
                                     "AudioQueue", "AVAudio", "Mic", "PCM" };
        int shown = 0;

        // 直接扫 indirect symbol table 的全部条目
        for (uint32_t idx = 0;
             idx < dysym->nindirectsyms && shown < 60; idx++) {
            uint32_t symIdx = indirect[idx];
            if (symIdx == INDIRECT_SYMBOL_LOCAL || symIdx == INDIRECT_SYMBOL_ABS) continue;
            if (symIdx >= symtab->nsyms) continue;

            const struct nlist_64 *s = &syms[symIdx];
            if (!s->n_un.n_strx) continue;

            const char *name = strs + s->n_un.n_strx;
            if (!name || !*name) continue;
            if (*name == '_') name++;

            BOOL hit = NO;
            for (size_t k = 0; k < sizeof(kw) / sizeof(kw[0]); k++) {
                if (strstr(name, kw[k])) { hit = YES; break; }
            }
            if (!hit) continue;

            [out appendFormat:@"  %s\n", name];
            shown++;
        }

        if (shown == 0) {
            [out appendString:@"  (没有音频相关的导入符号)\n"];
        }
    }
}

static NSString *VCRunAudioDiagnosis(void)
{
    NSMutableString *out = [NSMutableString string];

    // 精简版：只留判断依据。
    // 类名列表、section 扫描记录、镜像清单这些一次性排查用的内容
    // 已经完成使命，留着只会让人复制不动。
    [out appendString:@"=== VCam 音频诊断 ===\n\n"];

    [out appendFormat:@"hook 已安装   : %@\n", g_auHookInstalled ? @"是" : @"否"];
    [out appendFormat:@"orig          : %p\n", orig_AudioUnitRender];
    [out appendFormat:@"调用次数      : %d\n", g_auRenderHits];
    [out appendFormat:@"bus==1 次数   : %d\n", g_auBus1Hits];
    [out appendFormat:@"最近 bus      : %u\n", (unsigned)g_auLastBus];
    [out appendFormat:@"frames 最小/最大 : %u / %u\n",
        (unsigned)(g_auMinFrames == 0xFFFFFFFF ? 0 : g_auMinFrames),
        (unsigned)g_auMaxFrames];
    [out appendFormat:@"frames 平均   : %.1f\n",
        g_auRenderHits > 0 ? g_auSumFrames / g_auRenderHits : 0.0];
    [out appendFormat:@"buffers       : %u\n", (unsigned)g_auLastBuffers];
    [out appendFormat:@"声道数        : %u\n", (unsigned)g_auLastChannels];
    [out appendFormat:@"字节数        : %u\n", (unsigned)g_auLastBytes];

    [out appendFormat:@"SetProperty hook: %@ (orig=%p)\n",
        orig_AudioUnitSetProperty ? @"已装" : @"未装", orig_AudioUnitSetProperty];

    [out appendString:@"\n--- 音频管道 ---\n"];
    {
        VCAudioPipeline *pipe = [VCAudioPipeline shared];
        [out appendFormat:@"运行中        : %@\n", pipe.isRunning ? @"是" : @"否"];
        [out appendFormat:@"后台产出帧数  : %llu\n", pipe.producedFrames];
        [out appendFormat:@"实时取走帧数  : %llu\n", pipe.consumedFrames];
        [out appendFormat:@"缓冲存货帧数  : %zu\n", pipe.bufferedFrames];
        [out appendFormat:@"缓冲欠载次数  : %llu   (大于0说明后台供不上)\n", pipe.underrunCount];
        [out appendFormat:@"缓冲延迟      : %.0f ms\n", pipe.currentDrift * 1000.0];
        [out appendFormat:@"视频位置      : %.2f s\n", pipe.videoSourceSeconds];
        [out appendFormat:@"音频位置      : %.2f s\n", pipe.decodedMaterialSeconds];
        [out appendFormat:@"音频播放位置  : %.2f s  (音频位置−缓冲)\n",
            pipe.decodedMaterialSeconds - pipe.currentDrift];
        [out appendFormat:@">>> 音画偏差    : %+.2f s  (负=音频落后)\n",
            pipe.decodedMaterialSeconds - pipe.currentDrift - pipe.videoSourceSeconds];
        [out appendFormat:@"视频 seek 校正: %d 次  (音画对齐改写过视频读指针)\n",
            g_vcVideoSeekCount];
        [out appendFormat:@"素材时长      : %.2f s\n", [VCFrameSource shared].assetDuration];
        // 录完之后预览会继续推帧，所以「当前」偏差会越来越大 —— 那个数不算数。
        // 这三个才是判据。
        [out appendFormat:@"录制中最大偏差: %.2f s  (音频在走时采样，超过 0.30 应触发校正)\n",
            g_vcRecordSyncErrMax];
        if (g_vcRecordEndVideoPos >= 0.0) {
            [out appendFormat:@"停录瞬间      : 视频 %.2f s / 音频 %.2f s / 偏差 %+.2f s\n",
                g_vcRecordEndVideoPos, g_vcRecordEndAudioPos, g_vcRecordEndErr];
        } else {
            [out appendString:@"停录瞬间      : (还没录过一轮)\n"];
        }
        [out appendFormat:@"微调次数      : %llu  (稳定后应停止增长)\n", pipe.tuneBlocks];
        [out appendFormat:@"上次欠载时刻  : %.2f s（录音开始后）\n", pipe.lastUnderrunAt];
        [out appendFormat:@"单次生产最长  : %.0f ms\n", pipe.maxProduceMs];
        [out appendString:@"\n--- 静音来源细分 ---\n"];
        [out appendFormat:@"缓冲未就绪静音: %llu 帧 (%.0f ms)\n",
            pipe.silentNoRing, pipe.silentNoRing / 48.0];
        [out appendFormat:@"缓冲不足静音  : %llu 帧 (%.0f ms)\n",
            pipe.silentShort, pipe.silentShort / 48.0];
        [out appendFormat:@"writable=0    : %llu 次\n", pipe.zeroBytes];
        [out appendFormat:@"实际填充帧数  : %llu\n", pipe.totalFilled];
        [out appendFormat:@"恒定值段      : %llu 次  (必须为 0，否则上游有补齐残留)\n",
            pipe.dcSegments];
    }
    [out appendFormat:@"hook 填充次数 : %d\n", g_audioWriteOK];
    {
        VCAudioSource *asrc = [VCAudioSource shared];
        [out appendFormat:@"素材音频源    : %@  %.0fHz / %u ch\n",
            asrc.ready ? @"已加载" : @"未加载",
            asrc.sampleRate, (unsigned)asrc.channels];
        [out appendFormat:@"源累计交付帧  : %llu\n", asrc.framesDelivered];
    }
    [out appendFormat:@"最近返回原因  : %d  (0=正常 1=Mic 2=Mute)\n", g_audioBail];

    [out appendString:@"\n--- RenderNotify 诊断（系统标准 API）---\n"];
    [out appendFormat:@"注册状态      : %@  (ret=%d)\n",
        g_rnInstalled ? @"已注册" : @"未注册", g_rnRegResult];
    [out appendFormat:@"回调次数      : %u  (Pre %u / Post %u)\n",
        (unsigned)g_rnCalls, (unsigned)g_rnPreCalls, (unsigned)g_rnPostCalls];
    [out appendFormat:@"PreRender 帧数: %u\n", (unsigned)g_rnPreFrames];
    [out appendFormat:@"PreRender 字节: %u\n", (unsigned)g_rnPreBytes];
    [out appendFormat:@"PostRender 字节: %u\n", (unsigned)g_rnPostBytes];
    [out appendFormat:@"反推每帧字节  : %u   (格式报告是 %u)\n",
        (unsigned)g_rnBpf, (unsigned)g_auSysBytesPerFrame];
    [out appendFormat:@"最近 bus/bufs : %u / %u\n",
        (unsigned)g_rnBus, (unsigned)g_rnBufs];

    [out appendString:@"\n--- 系统音频格式 ---\n"];
    [out appendFormat:@"采样率        : %u Hz\n", (unsigned)g_auSysSampleRate];
    [out appendFormat:@"声道          : %u\n", (unsigned)g_auSysChannels];
    [out appendFormat:@"位深          : %u bit\n", (unsigned)g_auSysBits];
    [out appendFormat:@"formatFlags   : 0x%x\n", (unsigned)g_auSysFlags];
    [out appendFormat:@"bytesPerFrame : %u\n", (unsigned)g_auSysBytesPerFrame];

    [out appendString:@"\n--- 音频实例 ---\n"];
    [out appendFormat:@"首个实例      : 0x%lx\n", (unsigned long)g_auFirstUnit];
    [out appendFormat:@"实例切换      : %d\n", g_auUnitSwitches];

    [out appendString:@"\n--- 配置 ---\n"];
    [out appendFormat:@"audioMode     : %ld\n", (long)VCamConfig.shared.audioMode];
    [out appendFormat:@"已注入帧数    : %lu\n",
        (unsigned long)[VCFrameSource shared].frameCount];

    return out;
}

static void VCDumpAudioReport(void)
{
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        @autoreleasepool {
            NSString *report = VCRunAudioDiagnosis();

            // 写文件（方便以后用别的办法取）
            NSString *logPath = VCLogFilePath();
            NSString *diagPath = [logPath stringByAppendingString:@".audio"];
            [report writeToFile:diagPath
                     atomically:YES
                       encoding:NSUTF8StringEncoding
                          error:NULL];

            VCLog(@"音频诊断完成，%lu 字符，已存 %@",
                  (unsigned long)report.length, diagPath);

            dispatch_async(dispatch_get_main_queue(), ^{
                // 塞剪贴板：用户可以粘到备忘录/微信发出来
                [UIPasteboard generalPasteboard].string = report;

                UIAlertController *a =
                    [UIAlertController alertControllerWithTitle:@"音频诊断（已复制到剪贴板）"
                                                       message:[NSString stringWithFormat:
                                    @"报告 %lu 字符，已复制到剪贴板。\n\n捏到备忘录里粘贴，或直接发出来。\n\n文件：Documents/VCam/diag.log.audio",
                                    (unsigned long)report.length]
                                                preferredStyle:UIAlertControllerStyleAlert];
                [a addAction:[UIAlertAction actionWithTitle:@"好"
                                                      style:UIAlertActionStyleCancel
                                                    handler:nil]];

                UIViewController *vc = VCTopViewController();
                [vc presentViewController:a animated:NO completion:nil];
            });
        }
    });
}

// ==================================================================
#pragma mark - 手势补装
// ==================================================================
//
//  makeKeyAndVisible 只在窗口第一次显示时调用。抖音的窗口可能在我们
//  注入之前就已可见，那个方法之后再不被调用 —— 手势永远装不上。
//  这里每 2 秒找一次 key window 补装，装过就跳过。

static void VCEnsureGesturesInstalled(void)
{
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    for (UIWindow *w in UIApplication.sharedApplication.windows) {
        if (!w.isKeyWindow) continue;
        if ([w respondsToSelector:@selector(vc_installGesturesIfNeeded)]) {
            [w performSelector:@selector(vc_installGesturesIfNeeded)];
        }
        return;
    }
#pragma clang diagnostic pop
}

// ==================================================================
#pragma mark - 入口
// ==================================================================

%ctor {
    @autoreleasepool {
        if (VCIsTargetProcess()) {
            // 每次启动清空日志，保证剪贴板里拿到的是这一次的完整过程
            VCLogReset();

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
            g_auHookInstalled = (auHooked && orig_AudioUnitRender) ? 1 : 0;

            // 同时把设置格式那一步的采样率钉成 48000，
            // 让系统和素材（48000）一致，从根上消除速率差。
            BOOL spHooked = VCHookSymbol("AudioUnitSetProperty",
                                         (void *)hook_AudioUnitSetProperty,
                                         (void **)&orig_AudioUnitSetProperty);
            VCLog(@"AudioUnitSetProperty hook %@ (orig=%p)",
                  spHooked ? @"已安装" : @"失败", orig_AudioUnitSetProperty);
            VCLog(@"AudioUnitRender hook %@ (orig=%p)",
                  auHooked ? @"已安装" : @"失败", orig_AudioUnitRender);

            // 3. 日志上屏的最后手段：剪贴板。
            //
            //    iOS 15 上 syslog_relay / os_trace_relay 都抓不到 NSLog，
            //    house_arrest 要求 App 开 UIFileSharingEnabled（抖音没开），
            //    com.apple.afc 直接被拒。四条通道全断。
            //
            //    但剪贴板不需要任何权限：App 退到后台时把整个 diag.log
            //    塞进系统剪贴板，用户打开备忘录粘贴就能看到全文。
            [[NSNotificationCenter defaultCenter]
                addObserverForName:UIApplicationDidEnterBackgroundNotification
                            object:nil
                             queue:[NSOperationQueue mainQueue]
                        usingBlock:^(NSNotification *note) {
                NSString *path = VCLogFilePath();
                NSString *content = [NSString stringWithContentsOfFile:path
                                                              encoding:NSUTF8StringEncoding
                                                                 error:NULL];
                if (content.length == 0) return;
                [UIPasteboard generalPasteboard].string = content;
                VCLogToFile(@"==== 日志已复制到剪贴板 ====");
            }];

            // 4. 兜底：即使 didFinishLaunching hook 没命中（SceneDelegate 流程），
            //    延迟一段时间也把素材拉起来
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                VCBootstrap();
            });

            // 5. 手势补装定时器。
            //    makeKeyAndVisible 可能永远不会被调用（窗口早在注入前就显示了），
            //    所以这里独立起一个定时器，每 2 秒找 key window 补装。
            //    装过之后靠 associated object 去重，不会重复添加。
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                __block int tries = 0;
                dispatch_source_t gtm = dispatch_source_create(
                    DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
                dispatch_source_set_timer(gtm,
                    dispatch_time(DISPATCH_TIME_NOW, 0),
                    2 * NSEC_PER_SEC, 1 * NSEC_PER_SEC);
                dispatch_source_set_event_handler(gtm, ^{
                    if (++tries > 90) { dispatch_source_cancel(gtm); return; }
                    VCEnsureGesturesInstalled();
                });
                dispatch_resume(gtm);
            });
        }
    }
}
