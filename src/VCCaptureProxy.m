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
#import "VCAudioPipeline.h"
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
- (void)syncVideoToAudioClockNow:(double)now;
@end

// 视频出帧配额 —— 必须是全局的，不能是实例变量。
//
//  抖音在预览、录制、切页时会反复重建 VCCaptureProxy（每次 proxyForTarget:
//  都是新对象）。如果配额存在实例里，新实例的计数从 0 开始，
//  「总帧数 ≤ 时间×帧率」这条约束就被反复重置 —— 实测跑出 1005 帧
//  而上限本该是 457 帧，等于完全没限速。
//
//  放成文件级静态量，所有实例共享同一份会话起点和累计计数。
static double   g_videoSessionStart = 0.0;   // 首次出帧的绝对时刻，只赋值一次
static uint64_t g_videoTotalFetched = 0;     // 累计出帧数，只增不减
static double   g_recordStartAt = 0.0;       // 开始录制（首次有音频时钟）的绝对时刻

// 录制开始时由 Tweak 置 1，让帧源重新取音频时钟基准。
//
//  playedSeconds 是「管道启动以来的累计消费时长」（绝对值），而素材位置是
//  「从录制起点算起」（相对值）。两者原点不同，直接相减就会一路加速 ——
//  实测：素材 88 秒时音频计数已经 834 秒，追帧永远追不上，每次回调都取满 4 帧。
volatile int g_vcNeedAudioRebase = 0;
// 只有「素材回绕」才需要把音频素材真的 seek 回 0（管道那时已经读到末尾了）。
// 录制起点不需要 —— 管道本来就从素材 0 秒开始，seek 反而带进转换器残留数据。
volatile int g_vcNeedAudioRewind = 0;

// 音画对齐的诊断量（报告读它们）。
//  为什么单独记：录完之后预览会继续推帧，直接用「当前视频位置 − 当前音频位置」
//  会把停录后那几秒算成误差。分开记，报告里才说人话。
double g_vcRecordSyncErrMax  = 0.0;   // 本轮录制中（音频还在走）的最大偏差
double g_vcRecordEndVideoPos = -1.0;  // 停录瞬间的视频位置（-1 = 还没录过）
double g_vcRecordEndAudioPos = -1.0;  // 停录瞬间的音频位置
double g_vcRecordEndErr      = 0.0;   // 停录瞬间的偏差

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
    double _lastFetchTime;         // 已废弃
    double _quotaStart;            // 当前配额窗口起点（秒）
    uint32_t _quotaFetched;        // 已废弃
    double _sessionStart;          // 本次会话首次出帧的绝对时刻（永不重置）
    uint64_t _totalFetched;        // 累计出帧数（只增不减）
    uint64_t _srcFetched;          // 实际从素材取了几个新帧（诊断）

    // ---- 绿幕抠像 ----
    //  每帧流程：备份真实画面 Y/UV → 素材覆盖 → 只把「非绿色」区域还原。
    //  缓冲按需分配一次后复用（720x1280 约 1.4 MB）。
    uint8_t *_gkRealY;
    uint8_t *_gkRealUV;
    size_t   _gkRealYCap;
    size_t   _gkRealUVCap;
    int      _gkLoggedFrames;
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

// ------------------------------------------------------------------ 音画对齐
//
//  问题现场（第 11 版实测）：
//      视频位置 24.73 s  /  音频播放位置 15.25 s  /  偏差 -9.50 s
//      743 帧 ÷ 30 = 24.77 s ≈ 视频位置  →  帧率本来就是严格的 30 fps
//
//  也就是说「视频消耗倍数 1.624」根本不是限速失效：
//  分子（视频读指针）从**预览阶段第一次出帧**就开始算，
//  分母（录制时长）从**按下录制**才开始算 —— 预览期消耗的 9.5 秒全被算成了超速。
//
//  音频为什么没有这个问题：AudioUnit 只在真正开始录制（或录音页）才有回调，
//  音频管道从那一刻才起跑，所以「音频播放位置 15.25 ≈ 录制时长 15.23」。
//
//  结论：视频读指针不该自己跑，它必须跟住音频真正播到的位置。
//  音频是实时率输出的，它才是真实时间轴。
//
//  第 12 版实测（2026-11-19 22:31）：
//      音画偏差 -9.50 s → -0.33 s，视频位置 24.73 → 15.57 s  ✓
//      但预览页也触发了 10 次校正：那时音频还没被消费、位置恒为 0，
//      视频被每秒拽回 0 秒，预览画面卡死在第一秒 —— 第 13 版补上两个门槛。
- (void)syncVideoToAudioClockNow:(double)now
{
    VCAudioPipeline *pipe = [VCAudioPipeline shared];

    // 音频正在做「录制起点对齐」：这个窗口里它的位置还是旧值，
    //  照着旧值校就会把画面拽回开头，等它跳完再拽回来 —— 画面来回跳。
    if (pipe.isAligning) return;

    // 门槛 1：音频必须真的被**消费**过。
    //
    //  isRunning 不够 —— 管道在 bootstrap 时就启动了，预览页也一直是「运行中」，
    //  但那时实时线程根本没来取数据（没有录制），音频位置恒为 0。
    //  拿这个 0 当基准，就会把预览画面钉死在第 0 秒。
    if (!pipe.isRunning || pipe.consumedFrames == 0) return;

    VCFrameSource *src = [VCFrameSource shared];
    double dur = src.assetDuration;
    if (!(dur > 0.5)) return;                                    // 时长未知，不做折返

    // 真正「播出去」的素材位置 = 已产出位置 − 还压在环形缓冲里的秒数。
    // 用解码进度会天然超前一个缓冲深度（实测 1.2~1.8 秒），越校越偏。
    double audioPos = pipe.decodedMaterialSeconds - pipe.currentDrift;
    if (audioPos < 0) audioPos = 0;
    if (audioPos > dur) audioPos = fmod(audioPos, dur);          // 长跑折返，素材只有十几秒

    // 门槛 2：音频时间轴必须还在前进。
    //  停止录制后音频停在原地（实测 15.23 s 不再动），而预览还在推帧 ——
    //  这时再校正就是把画面往回拽，一秒一次，纯属捣乱。
    static double sPrevAudioPos = -1.0;
    static double sPrevAudioAt  = 0.0;
    if (sPrevAudioPos < 0 || fabs(audioPos - sPrevAudioPos) > 0.002) {
        sPrevAudioPos = audioPos;
        sPrevAudioAt  = now;
    } else if (now - sPrevAudioAt > 0.5) {
        // 音频停走了 = 这一轮录制结束。趁视频还没继续跑远，快照一次。
        //  报告里的「音画偏差」如果在这里不冻结，就会把停录后预览推进的量
        //  算进去 —— 实测录完 3 秒再点诊断，报告显示 -2.77 s，
        //  其实录制中一直 < 0.3 s。那个数字只会误导人。
        if (g_vcRecordEndVideoPos < 0.0) {
            g_vcRecordEndVideoPos  = src.currentVideoSourceTime;
            g_vcRecordEndAudioPos  = audioPos;
            g_vcRecordEndErr       = g_vcRecordEndVideoPos - audioPos;
        }
        return;
    }

    double vpos = src.currentVideoSourceTime;
    double err  = vpos - audioPos;

    // 音频重新开始走 = 新一轮录制。先把上一轮留下的快照清掉。
    if (g_vcRecordEndVideoPos >= 0.0) {
        g_vcRecordEndVideoPos = -1.0;
        g_vcRecordEndAudioPos = -1.0;
        g_vcRecordEndErr      = 0.0;
        g_vcRecordSyncErrMax  = 0.0;
    }

    // 阈值 0.3 s：第 12 版对齐后还剩 0.33 s，口型错位是能看出来的，收一点。
    // 限频 1 s：seek 要重建 reader（~140 ms），不能每帧都做。
    static double sLastSeekAt = 0.0;
    static int    sSyncLogs   = 0;
    BOOL needSeek = (fabs(err) > 0.3 && (now - sLastSeekAt) > 1.0);

    // 只统计**稳态**误差。正在被校正的那一帧记的是「待修复的错误」（录制刚开始时
    // 会是预览期攒下的 20 多秒），把它算进最大值会让人以为一直没对齐。
    if (!needSeek && fabs(err) > g_vcRecordSyncErrMax) {
        g_vcRecordSyncErrMax = fabs(err);
    }

    if (needSeek) {
        sLastSeekAt = now;
        [src seekVideoToTime:audioPos];
        // seek 之后时间轴基准整个跳了，配额基准跟着重置，别让它算成"超速"
        g_videoSessionStart = now;
        g_videoTotalFetched = 0;

        if (sSyncLogs < 20) {
            sSyncLogs++;
            VCLog(@"音画对齐 #%d：视频 %.2f s -> 音频 %.2f s（原来差 %+.2f s，已校正 %d 次）",
                  sSyncLogs, vpos, audioPos, err, g_vcVideoSeekCount);
        }
    }
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
// ------------------------------------------------------------------ 真实摄像头参与
//
//  思路：dst 在这一刻还是**真实摄像头画面**（我们还没覆盖它）。
//  覆盖之前先读一眼它的亮度，用这个亮度相对「启动时基准」的偏移，
//  去调制素材的亮度 —— 屋里开灯、拉窗帘、换光源，直播画面会跟着变。
//
//  为什么值得做：预录素材最大的破绽就是"死的" —— 环境变了画面不变。
//  真实摄像头的传感器噪声和自动曝光是活的，这一层让输出也活起来。
//
//  成本：720x1280 每 16 像素采一点 ≈ 3600 次读，微秒级。

static double VCSampleLumaFast(CVPixelBufferRef pb)
{
    if (!pb || CVPixelBufferGetPlaneCount(pb) < 1) return -1.0;
    if (CVPixelBufferLockBaseAddress(pb, kCVPixelBufferLock_ReadOnly) != kCVReturnSuccess) {
        return -1.0;
    }

    double sum = 0;
    size_t n = 0;
    uint8_t *base = CVPixelBufferGetBaseAddressOfPlane(pb, 0);
    size_t h   = CVPixelBufferGetHeightOfPlane(pb, 0);
    size_t w   = CVPixelBufferGetWidthOfPlane(pb, 0);
    size_t bpr = CVPixelBufferGetBytesPerRowOfPlane(pb, 0);

    if (base) {
        for (size_t y = 0; y < h; y += 16) {
            const uint8_t *row = base + y * bpr;
            for (size_t x = 0; x < w; x += 16) {
                sum += row[x];
                n++;
            }
        }
    }
    CVPixelBufferUnlockBaseAddress(pb, kCVPixelBufferLock_ReadOnly);
    return n ? (sum / (double)n) : -1.0;
}

/// 由真实画面亮度算素材的亮度增益。返回 1.0 表示不干预。
static double VCComputeLumaGainFromRealCamera(double realLuma)
{
    double influence = VCamConfig.shared.realCameraInfluence;
    if (!(influence > 0.001) || !(realLuma > 0)) return 1.0;

    static double sSmooth = -1.0;
    static double sBaseline = -1.0;
    static int    sLogs = 0;

    // 指数平滑：真实场景的测光本身就在抖，直接用会闪
    sSmooth = (sSmooth < 0) ? realLuma : (sSmooth * 0.85 + realLuma * 0.15);

    if (sBaseline < 0) {
        sBaseline = sSmooth;
        VCLog(@"真实摄像头参与：基准亮度 %.1f，influence=%.2f", sBaseline, influence);
        return 1.0;
    }

    // 偏移量归一化到 [-1, 1]：128 级 ≈ 满量程
    double delta = (sSmooth - sBaseline) / 128.0;
    if (delta >  1.0) delta =  1.0;
    if (delta < -1.0) delta = -1.0;

    // 最大 ±35%，避免环境剧变时画面跟着失控
    double gain = 1.0 + delta * influence * 0.35;
    if (gain < 0.70) gain = 0.70;
    if (gain > 1.30) gain = 1.30;

    if (sLogs < 5 && fabs(gain - 1.0) > 0.02) {
        sLogs++;
        VCLog(@"光照跟随：真实 %.1f（基准 %.1f）→ 素材增益 %.3f", sSmooth, sBaseline, gain);
    }
    return gain;
}

// ------------------------------------------------------------------ 绿幕抠像
//
//  思路：摄像头对着绿幕时，绿幕区域显示素材，别的（手、商品）保留真实画面。
//
//  为什么这么做而不是「亮度跟随」：
//    亮度跟随会去改素材的明暗 —— 素材就不是原来那个素材了。
//    绿幕抠像是「素材一格不动，只把绿幕挖掉换成素材」，
//    素材本身零改动，只是叠加了一层真实的东西。
//
//  实现：素材覆盖**之前**备份真实画面，覆盖**之后**把非绿色区域写回去。
//    YCbCr 里绿幕的特征是 Cb/Cr 都明显低于 128（纯绿大约 Cb=54 / Cr=34），
//    用「到纯绿参考点的距离」判断比单看某一路稳，能覆盖偏黄偏青的绿幕。
//
//  开销：720x1280 的 UV 平面是 360x640 = 23 万次循环，每帧约 3~6 ms。
//    只在 greenKeyEnabled 时执行，关掉是零成本。

- (void)gkBackupRealFrame:(CVPixelBufferRef)dst
{
    if (!dst || CVPixelBufferGetPlaneCount(dst) < 2) return;
    if (CVPixelBufferLockBaseAddress(dst, kCVPixelBufferLock_ReadOnly) != kCVReturnSuccess) return;

    uint8_t *y  = CVPixelBufferGetBaseAddressOfPlane(dst, 0);
    uint8_t *uv = CVPixelBufferGetBaseAddressOfPlane(dst, 1);
    size_t yH   = CVPixelBufferGetHeightOfPlane(dst, 0);
    size_t yBpr = CVPixelBufferGetBytesPerRowOfPlane(dst, 0);
    size_t uvH  = CVPixelBufferGetHeightOfPlane(dst, 1);
    size_t uvBpr = CVPixelBufferGetBytesPerRowOfPlane(dst, 1);

    size_t yLen  = yH * yBpr;
    size_t uvLen = uvH * uvBpr;

    if (y && yLen) {
        if (!_gkRealY || _gkRealYCap < yLen) {
            free(_gkRealY);
            _gkRealY = (uint8_t *)malloc(yLen);
            _gkRealYCap = _gkRealY ? yLen : 0;
        }
        if (_gkRealY) memcpy(_gkRealY, y, yLen);
    }
    if (uv && uvLen) {
        if (!_gkRealUV || _gkRealUVCap < uvLen) {
            free(_gkRealUV);
            _gkRealUV = (uint8_t *)malloc(uvLen);
            _gkRealUVCap = _gkRealUV ? uvLen : 0;
        }
        if (_gkRealUV) memcpy(_gkRealUV, uv, uvLen);
    }

    CVPixelBufferUnlockBaseAddress(dst, kCVPixelBufferLock_ReadOnly);
}

- (void)gkRestoreNonGreenInto:(CVPixelBufferRef)dst
{
    if (!_gkRealY || !_gkRealUV) return;
    if (!dst || CVPixelBufferGetPlaneCount(dst) < 2) return;
    if (CVPixelBufferLockBaseAddress(dst, 0) != kCVReturnSuccess) return;

    uint8_t *y   = CVPixelBufferGetBaseAddressOfPlane(dst, 0);
    uint8_t *uv  = CVPixelBufferGetBaseAddressOfPlane(dst, 1);
    size_t yW    = CVPixelBufferGetWidthOfPlane(dst, 0);
    size_t yH    = CVPixelBufferGetHeightOfPlane(dst, 0);
    size_t yBpr  = CVPixelBufferGetBytesPerRowOfPlane(dst, 0);
    size_t uvW   = CVPixelBufferGetWidthOfPlane(dst, 1);
    size_t uvH   = CVPixelBufferGetHeightOfPlane(dst, 1);
    size_t uvBpr = CVPixelBufferGetBytesPerRowOfPlane(dst, 1);

    double th = VCamConfig.shared.greenKeyThreshold;
    if (!(th > 0.01)) th = 0.35;

    // ★ 用「绿度」而不是「到纯绿的距离」。
    //
    //  实测数据：摄像头拍绿幕读出来是 Cb≈114 / Cr≈87，
    //  而标准纯绿是 (54, 34) —— 差了 60 多。
    //  手机 sensor 的白平衡和色彩矩阵会把绿幕饱和度压掉一大截，
    //  拿「到纯绿的绝对距离」判断，绿幕永远判不进去（实测 100% 非绿）。
    //
    //  绿度 = (128 - Cb) + (128 - Cr)，越大越绿：
    //      纯绿幕 (54,34)   → 168
    //      实际绿幕 (114,87) →  55
    //      中性灰 (128,128)  →   0
    //      亚洲肤色(110,148) →  -2      ← 天然是负数，不会把手指抠掉
    //      红色 (90,180)     → -14
    //  阈值映射到 0~170，默认 0.25 → 42.5，落在 0 和 55 之间。
    int greenMin = (int)(th * 170.0);
    if (greenMin < 5) greenMin = 5;

    // 诊断：判定失败时得知道实际读到什么
    if (_gkLoggedFrames < 3) {
        VCLog(@"绿幕诊断：UV %zux%zu bpr=%zu   Y %zux%zu bpr=%zu  绿度阈值=%d",
              uvW, uvH, uvBpr, yW, yH, yBpr, greenMin);
        int px[5] = { (int)(uvW * 0.15), (int)(uvW * 0.85), (int)(uvW * 0.5),
                      (int)(uvW * 0.30), (int)(uvW * 0.70) };
        int py[5] = { (int)(uvH * 0.15), (int)(uvH * 0.15), (int)(uvH * 0.5),
                      (int)(uvH * 0.60), (int)(uvH * 0.60) };
        for (int i = 0; i < 5; i++) {
            size_t off = (size_t)py[i] * uvBpr + (size_t)px[i] * 2;
            if (off + 1 < _gkRealUVCap) {
                int cb = _gkRealUV[off], cr = _gkRealUV[off + 1];
                int g = (128 - cb) + (128 - cr);
                VCLog(@"  点%d (%d,%d) Cb=%d Cr=%d  绿度=%d %@",
                      i, px[i], py[i], cb, cr, g, (g >= greenMin) ? @"→绿" : @"→非绿");
            }
        }
    }

    long nonGreen = 0, total = 0;

    for (size_t uy = 0; uy < uvH; uy++) {
        uint8_t *drow = uv + uy * uvBpr;
        uint8_t *rrow = _gkRealUV + uy * uvBpr;
        for (size_t ux = 0; ux < uvW; ux++) {
            size_t off = ux * 2;
            if (off + 1 >= uvBpr) break;
            int g = (128 - (int)rrow[off]) + (128 - (int)rrow[off + 1]);
            total++;
            if (g >= greenMin) continue;   // 够绿 → 保留素材

            // 不是绿色 → 还原真实画面（UV + 对应的 2x2 亮度块）
            drow[off]     = rrow[off];
            drow[off + 1] = rrow[off + 1];
            nonGreen++;

            for (int dy = 0; dy < 2; dy++) {
                size_t yy = uy * 2 + dy;
                if (yy >= yH) break;
                uint8_t *dyl = y + yy * yBpr;
                uint8_t *ryl = _gkRealY + yy * yBpr;
                size_t x0 = ux * 2;
                if (x0 < yW)     dyl[x0] = ryl[x0];
                if (x0 + 1 < yW) dyl[x0 + 1] = ryl[x0 + 1];
            }
        }
    }

    CVPixelBufferUnlockBaseAddress(dst, 0);

    if (_gkLoggedFrames < 6) {
        _gkLoggedFrames++;
        VCLog(@"绿幕：非绿区域 %.1f%%（阈值 %.2f → 绿度 %d）",
              total ? (100.0 * nonGreen / (double)total) : 0.0, th, greenMin);
    }
}

- (void)dealloc
{
    free(_gkRealY);  _gkRealY = NULL;
    free(_gkRealUV); _gkRealUV = NULL;
    if (_lastSrcPB) CVPixelBufferRelease(_lastSrcPB);
}

- (void)rewriteVideoBufferInPlace:(CMSampleBufferRef)buffer drop:(BOOL *)dropOut
{
    extern volatile int g_statVideoDelegates;
    g_statVideoDelegates++;

    // 采集回调耗时：正常结束路径上量一次，超过 50ms 记一笔。
    //  卡死时能看出是哪一帧开始变慢（解码 / 转换 / seek）。
    double __t0 = CACurrentMediaTime();

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

        // ---- 累计配额：总出帧数 ≤ 真实时间 × 帧率 ----
        //
        //  前九版失败的根本原因，是都用了「某个会重置的基准」：
        //    · 时间预算窗口 —— 每次窗口重置就重新计数
        //    · _playStartPos  —— 素材回绕 / reader 重启时归零，
        //                        之前攒下的超前量全部洗白，又能再超前一次
        //  于是每一轮重置都会再偷一点，累积起来就是 1.6~2.1 倍。
        //
        //  这里换成两条永不重置的累计量：
        //    _sessionStart  —— 本次会话第一次出帧的绝对时刻，只赋值一次
        //    _totalFetched  —— 累计出帧数，只增不减
        //
        //  约束：_totalFetched ≤ (now − _sessionStart) × fps + 2
        //  满足这条不等式时，平均帧率在数学上不可能超过 fps。
        //  基准不重置，任何 reader 重启 / 素材回绕都影响不到它。
        CGFloat fps = [VCFrameSource shared].sourceFrameRate;
        if (fps < 1.0) fps = 30.0;
        double now = CACurrentMediaTime();

        // ---- 不再做周期性音画校正 ----
        //
        //  旧会话里这套东西试过五轮，每次都把链路搞坏：
        //    T163  seek 死循环（254 次 = 调用次数）
        //    T186  96 次 seek，丢 25 秒数据，103 次缓冲欠载
        //    T230  疯狂触发 634 次，13.5 秒静音
        //  结论（T187）：实时链路里禁止任何 seek。
        //
        //  现在只保留「追帧」：目标位置由音频已播时长决定，落后就多取几帧、
        //  追上就停。全程不重建 reader，不跳位置。
        //  录制起点由 Tweak 层一次性把视频拉回 0 秒，那是唯一的一次 seek。

        if (g_videoSessionStart <= 0) {
            g_videoSessionStart = now;
            g_videoTotalFetched = 0;
        }

        double allowed = (now - g_videoSessionStart) * (double)fps * 1.5 + 4.0;

        // ---- 追帧：素材帧率 ≠ 输出帧率时必须一次取多帧 ----
        //
        //  病灶：以前每次采集回调只取**一帧**素材。
        //    素材 30 fps、抖音 30 fps 回调 → 1:1，刚好。
        //    素材 60 fps、回调还是 30 次/秒 → 每秒只走 30 帧素材 = 0.5 秒内容
        //    → 画面变成**半速**，声音却按真实时间走，音画立刻错开。
        //    （60 fps 素材在视频号里很常见，这就是个通用坑，不是这一个素材的问题。）
        //
        //  正确做法：以音频时间轴为目标位置，一次回调里连续取帧、把该丢的丢掉，
        //  直到读指针追上目标。这样不管素材是 24 / 25 / 30 / 60 / 120 fps，
        //  输出都是真实时间速度。
        double audioTarget = -1.0;
        double wallSeconds = -1.0;
        {
            VCAudioPipeline *pipe = [VCAudioPipeline shared];
            if (pipe.isRunning && pipe.consumedFrames > 0) {
                // ★ 必须用**增量**，不能用 playedSeconds 的绝对值。
                //
                //  playedSeconds = _consumed / 44100，是从管道启动算起的累计量，
                //  预览阶段也在增长（实测：App 跑了 840 秒，它就到 834 秒）。
                //  而素材位置从这里录制起点算起，从 0 开始。
                //  两者原点不同，拿绝对值当目标就会一路加速：
                //      节奏 素材=88.67 音频=834.88 本次取=4   ← 追不上，每次取满 4 帧
                //
                //  所以录制开始时记一个基准，之后只取差值 —— 从 0 起跑，
                //  与「视频被 seek 回 0」是同一条起跑线。
                static double sAudioBase = -1.0;
                if (g_vcNeedAudioRebase) {
                    g_vcNeedAudioRebase = 0;
                    sAudioBase = -1.0;
                    if (g_vcNeedAudioRewind) {
                        g_vcNeedAudioRewind = 0;
                        [pipe resetToStart];       // 素材回绕：音频也回 0
                    }
                    VCLog(@"音频时钟重取基准（录制起点 / 素材回绕）");
                }
                double nowPlayed = pipe.playedSeconds;
                if (sAudioBase < 0.0) {
                    sAudioBase = nowPlayed;
                    g_recordStartAt = now;
                    VCLog(@"音频时钟基准 = %.2f s", sAudioBase);
                }
                double p = nowPlayed - sAudioBase;
                if (isfinite(p) && p >= 0.0) {
                    audioTarget = p;
                    // 兜底：真实流逝是硬上限，音频计数再虚高也不许超
                    wallSeconds = now - g_recordStartAt;
                    if (wallSeconds < audioTarget) audioTarget = wallSeconds;
                }
            }
        }
        // 预览期没有音频时钟（还没开录，没人消费音频），退化成真实时间当目标。
        //  不退的话就变成「每次回调取一帧」—— 60 fps 素材在预览页会以半速播放，
        //  看着像慢动作，很容易被当成同步出问题。
        if (audioTarget < 0.0 && g_videoSessionStart > 0.0) {
            audioTarget = now - g_videoSessionStart;
        }

        int guard = 0;
        int fetchedThisCallback = 0;
        double loopT0 = CACurrentMediaTime();
        while (guard < 4) {
            // 采集线程不能被解码堵死，但也不能卡得太紧。
            //
            //  以前是 18 ms：1080p BGRA 解码一帧要 20~30 ms，18 ms 连一帧都取不完，
            //  于是「抖音 29.48 fps 回调 vs 素材 30 fps」这点固有差距永远补不上，
            //  视频内容每秒只走 0.959 秒，15 秒录制下来比音频落后 0.6 秒 ——
            //  这就是「音画对不上」的实测来源。
            //
            //  放宽到 28 ms（仍小于一帧间隔 33.9 ms），让追帧有机会一次取两帧。
            if (CACurrentMediaTime() - loopT0 > 0.028) break;

            // 配额（防超速）与追帧（防落后）同时生效
            //
            //  录制期间（有音频时钟）配额必须让路：
            //    素材 30 fps 时配额只给 45 帧/秒，而正常推进要 30 帧、
            //    追回 1 秒落后还要 30 帧 —— 60 > 45，追帧永远被截断，
            //    结果就是「每秒固定落后 1 秒 → 每秒 seek 一次」的死循环（实测）。
            //    有音频时钟时它本身就是硬约束（音频实时率输出），不会超速。
            BOOL quotaOK = ((double)g_videoTotalFetched <
                            (now - g_videoSessionStart) * (double)fps + 2.0);
            BOOL canFetchNow = (audioTarget > 0.0) ? YES : quotaOK;
            if (_lastSrcPB && !canFetchNow) break;          // 配额满，复用上一帧
            if (audioTarget > 0.0 && _lastSrcPB &&
                [VCFrameSource shared].currentVideoSourceTime + 0.002 >= audioTarget) {
                break;                                       // 已追上目标位置
            }

            CVPixelBufferRef pb = [[VCFrameSource shared] copyNextPixelBuffer];
            if (!pb) break;

            if (_lastSrcPB) CVPixelBufferRelease(_lastSrcPB);
            _lastSrcPB = CVPixelBufferRetain(pb);
            CVPixelBufferRelease(pb);
            g_videoTotalFetched++;
            guard++;
            fetchedThisCallback++;
        }

        {
            static int sDbg = 0;
            if (sDbg < 25) {
                sDbg++;
                VCLog(@"出帧 #%d 已出=%llu 允许=%.1f 本次取=%d 目标=%.2f 素材位置=%.3f",
                      sDbg, g_videoTotalFetched, allowed, guard,
                      audioTarget, [VCFrameSource shared].currentVideoSourceTime);
            }
        }

        // 节奏日志：每 2 秒一行，长期跑也能看出是哪一边失控。
        //  正常时三条数应该几乎相等；素材 > 真实 = 加速，素材 < 真实 = 卡顿。
        //  最后两项是「本次实际取了几帧」——用来判断追帧有没有被时间上限截断：
        //  稳定在 1 说明刚好跟上，频繁 2~4 说明在补差距，持续 0 说明被锁/解码拖住。
        {
            static double sLastPaceLog = 0.0;
            if (now - sLastPaceLog > 2.0) {
                sLastPaceLog = now;
                VCLog(@"节奏 素材=%.2f 音频=%.2f 真实=%.2f 本次取=%d 累计出帧=%llu",
                      [VCFrameSource shared].currentVideoSourceTime,
                      audioTarget, wallSeconds, fetchedThisCallback, g_videoTotalFetched);
            }
        }

        if (_lastSrcPB) src = CVPixelBufferRetain(_lastSrcPB);
    }

    if (!src) {
        // 素材还没装载好 → 透传系统给的原始帧，绝不能丢。
        //
        //  丢帧的后果实测过：进录制页时素材还在下载，帧源返回 NULL，
        //  这里 dropOut=YES 把每一帧都丢掉 → App 拿不到任何画面 → 黑屏 →
        //  系统 watchdog 直接把抖音杀掉（"进入录制页黑屏闪退"）。
        //
        //  素材就绪之后的「暂时空」仍然丢帧 —— 那时透传会把真实摄像头画面
        //  放出去，那是另一类问题。
        if (![VCFrameSource shared].isReady) {
            if (dropOut) *dropOut = NO;
            return;
        }
        if (dropOut) *dropOut = YES;
        return;
    }

    // 覆盖之前先读一眼真实画面，算出素材该跟着亮多少
    {
        double realLuma = VCSampleLumaFast(dst);
        [VCSampleBufferFactory shared].lumaGain = VCComputeLumaGainFromRealCamera(realLuma);
    }

    // 绿幕：素材覆盖**之前**把真实画面备份下来
    BOOL gk = VCamConfig.shared.greenKeyEnabled;
    if (gk) [self gkBackupRealFrame:dst];

    if (![[VCSampleBufferFactory shared] copyPixelBuffer:src into:dst]) {
        CVPixelBufferRelease(src);
        if (dropOut) *dropOut = YES;
        return;
    }

    // 绿幕：素材已经铺满，把「非绿色」区域（手、商品、任何挡镜头的东西）还原回去
    if (gk) [self gkRestoreNonGreenInto:dst];

    if (!_loggedFirstReplacement) {
        _loggedFirstReplacement = YES;
        VCLog(@"首帧注入成功（原地改写）");
    }

    // ---- 格式诊断：偏白/偏色的元凶基本都在这里 ----
    //
    //  原地改写时，CMSampleBuffer 的 format description（含 YCbCr 矩阵、
    //  primaries、transfer function）是**系统给的那份**，没动过；
    //  而像素是我们按素材的样子转出来写进去的。
    //  两者只要有一项对不上，出来的就是偏色 / 偏白 / 对比度变平。
    //
    //  range 尤其关键：素材经 H.264 出来是 420v（video range，Y 16~235），
    //  系统 buffer 若是 420f（full range，Y 0~255），按错方向映射就等于
    //  把亮度整体拉伸一遍 —— 暗部发灰、亮部裁切，看着就是"偏白"。
    {
        static OSType sLastDFmt = 0;
        static size_t sLastDW = 0, sLastDH = 0;
        OSType dFmt = CVPixelBufferGetPixelFormatType(dst);
        size_t dW = CVPixelBufferGetWidth(dst);
        size_t dH = CVPixelBufferGetHeight(dst);
        if (dFmt != sLastDFmt || dW != sLastDW || dH != sLastDH) {
            sLastDFmt = dFmt; sLastDW = dW; sLastDH = dH;

            CMFormatDescriptionRef fd = CMSampleBufferGetFormatDescription(buffer);
            CFDictionaryRef ext = fd ? CMFormatDescriptionGetExtensions(fd) : NULL;
            NSString *mMatrix = @"(无声明)", *mPrim = @"(无声明)", *mTf = @"(无声明)";
            if (ext) {
                id v = (__bridge id)CFDictionaryGetValue(ext, kCVImageBufferYCbCrMatrixKey);
                if (v) mMatrix = [v description];
                v = (__bridge id)CFDictionaryGetValue(ext, kCVImageBufferColorPrimariesKey);
                if (v) mPrim = [v description];
                v = (__bridge id)CFDictionaryGetValue(ext, kCVImageBufferTransferFunctionKey);
                if (v) mTf = [v description];
            }

            NSString *dRange = (dFmt == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange) ? @"full(0-255)" :
                               (dFmt == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange) ? @"video(16-235)" : @"?";

            OSType sFmt = _lastSrcPB ? CVPixelBufferGetPixelFormatType(_lastSrcPB) : 0;
            NSString *sRange = (sFmt == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange) ? @"full(0-255)" :
                               (sFmt == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange) ? @"video(16-235)" : @"?";
            size_t sW = _lastSrcPB ? CVPixelBufferGetWidth(_lastSrcPB) : 0;
            size_t sH = _lastSrcPB ? CVPixelBufferGetHeight(_lastSrcPB) : 0;

            VCLog(@"── 注入格式诊断 ──");
            VCLog(@"  dst  %zux%zu fmt=0x%x  range=%@", dW, dH, (unsigned)dFmt, dRange);
            VCLog(@"  dst  matrix=%@ primaries=%@ transfer=%@", mMatrix, mPrim, mTf);
            VCLog(@"  src  %zux%zu fmt=0x%x  range=%@", sW, sH, (unsigned)sFmt, sRange);
            VCLog(@"  路径 %@", (sW == dW && sH == dH && sFmt == dFmt)
                  ? @"同尺寸同格式 memcpy" : @"VTPixelTransferSession 缩放+转换");
        }
    }

    [[VCSampleBufferFactory shared] updateJPEGFromPixelBuffer:dst];
    [VCOverlay pushVideoSampleBuffer:buffer];

    CVPixelBufferRelease(src);

    double __ms = (CACurrentMediaTime() - __t0) * 1000.0;
    if (__ms > 50.0) {
        static int sSlowLogs = 0;
        if (sSlowLogs++ < 15) {
            VCLog(@"采集回调耗时 %.0f ms（超过 50ms，会卡顿/丢帧）", __ms);
        }
    }
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
