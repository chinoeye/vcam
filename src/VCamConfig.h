//
//  VCamConfig.h
//  运行配置。全部从 NSUserDefaults 读，可在悬浮面板里实时改，
//  不重建 App、不重编译 tweak。
//

#ifndef VCamConfig_h
#define VCamConfig_h

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

typedef NS_ENUM(NSInteger, VCSourceKind) {
    VCSourceKindAsset = 0,   // 本地 MP4 循环（主源）
    VCSourceKindLive  = 1,   // 局域网 TCP 实时帧（备源）
    VCSourceKindNone  = 2,   // 关闭注入，回退真摄像头
};

typedef NS_ENUM(NSInteger, VCAudioMode) {
    VCAudioModeMic   = 0,    // 真麦克风，只替换画面
    VCAudioModeAsset = 1,    // 素材音轨，全虚拟
    VCAudioModeMute  = 2,    // 静音
};

@interface VCamConfig : NSObject

@property (class, nonatomic, readonly) VCamConfig *shared;

// ---- 源 ----
@property (nonatomic, assign) VCSourceKind sourceKind;
@property (nonatomic, assign) VCAudioMode audioMode;
@property (nonatomic, copy)   NSString *assetName;       // 不带扩展名
@property (nonatomic, copy)   NSString *liveHost;        // 备源用
@property (nonatomic, assign) uint16_t livePort;

// ---- 素材自动下载 ----
// 抖音是「苹果正版」，爱思助手不开放沙盒浏览，没法手动往里拖文件。
// 所以 dylib 启动时如果本地找不到素材，就从这个 HTTP 服务拉一份。
// pc/serve_assets.py 默认监听 8088，素材放 pc/assets/ 下。
@property (nonatomic, assign) uint16_t httpPort;

// ---- 画面 ----
@property (nonatomic, assign) BOOL injectEnabled;
@property (nonatomic, assign) BOOL loopEnabled;
@property (nonatomic, assign) BOOL paused;

/// 写入前对亮度做的反补偿 gamma（>1 = 压暗，1.0 = 不补）。
///
/// 抖音**开播页**的渲染链路会给画面加一条提亮曲线（实测同一素材帧：
/// 暗部 +130%、中间调 +19%、高光封顶 255，整体亮度 +26%），录制页没有。
/// 同一份注入像素，录制页正常、开播页过曝，差别就在这一层。
///
/// 这里在写进系统 buffer 之前先压暗一次把它抵掉。只动亮度（Y 平面），
/// 色度和对比度不碰 —— 实测它们本来就没被改。
@property (nonatomic, assign) double outputGamma;

/// 写入前对饱和度做的反补偿（1.0 = 不补，<1 = 降饱和）。
///
///  为什么必须和 outputGamma 一起用：在 YUV 空间里饱和度 ∝ |U-128| / Y，
///  只压 Y 不动 UV，色度会被相对放大 —— 实测只压亮度的版本饱和度凭空涨了 52%，
///  看着比原来更"冲"。配合 0.65 左右能把色度收回去。
@property (nonatomic, assign) double outputSaturation;

/// 固定亮度增益（默认 1.0 = 不处理）。
///
///  实测开播页对画面的处理（录制页正常、开播页偏亮偏艳）：
///      Y' = 1.0943 × Y + 0.72     整体提亮 9%，高光被推到 255（观感发白）
///      饱和度 × 1.356              颜色更浓
///      Cr +4.51                    偏红
///
///  这里做反向补偿：本值设 1/1.0943 ≈ 0.914，让开播页看到的就是录制页那个亮度。
///  用线性增益而不是 gamma —— 线性才能精确抵消线性提亮，gamma 会在两端跑偏。
///
///  注意：这个补偿对**录制页也生效**（它会把录制页压暗 9%）。
///  实际使用只开播不录制，所以以开播页为准。
@property (nonatomic, assign) double outputLumaGain;

/// 音频相对视频的偏移（毫秒，正数=声音往后推）。
///
///  素材自带音画错位时用：实测这段录播「声音比画面快 0.5 秒」，
///  设 500 就能拉回来。只影响音频读取起点，面板里不用手动对轴。
@property (nonatomic, assign) double audioOffsetMs;

/// 绿幕抠像开关。
///
///  开了之后：摄像头对着绿幕，**绿幕区域显示素材**，非绿区域（手、商品、
///  任何挡在镜头前的东西）保留真实摄像头画面。
///
///  和 realCameraInfluence 是两条完全不同的路：
///    realCameraInfluence  改素材亮度（素材会变，实测不想要）
///    greenKeyEnabled      素材不动，只是把绿幕"挖掉"换成素材
@property (nonatomic, assign) BOOL greenKeyEnabled;

/// 绿色判定半径（0~1，越大抠得越狠）。
///  0.15 只抠很纯的绿；0.35 默认；0.6 连偏黄偏青的绿幕都能抠掉。
@property (nonatomic, assign) double greenKeyThreshold;

/// 去绿边强度（0~1，0 = 关闭）。
///
///  绿幕反光打在手部边缘，那圈像素偏绿，直接照搬会有一道绿边。
///  这里把非绿像素里「多余的绿分量」按比例压掉：
///      肤色  绿度 ≈ -2  → 负数，完全不受影响
///      绿边  绿度 ≈ +30 → 压掉 80%，剩 +6，肉眼基本看不出
@property (nonatomic, assign) double despillStrength;

/// 连通区域最小面积（UV 像素数，默认 600）。
///
///  绿幕上的阴影带宽度能到十几个像素，3x3 邻域填不动。
///  这里按「连通块面积」判断：小于这个数的块整块当阴影抹掉，
///  大于的才当成真实物体（手）保留。
///  720p 的 UV 平面是 360x640 = 23 万像素，600 约合画面的 0.26%。
@property (nonatomic, assign) double greenKeyMinArea;

/// 强制屏幕常亮（默认 YES）。
///
///  抖音只在真正录制/直播时置 idleTimerDisabled，停留在「准备开播」页时
///  它不置位，两分钟后系统锁屏 → App 进后台 → 后台线程还在跑 →
///  5 秒内没让出资源 → 被 watchdog 杀死（实测连续崩两次）。
///
///  开启后 hook setIdleTimerDisabled，不管抖音传什么一律置 YES。
///  代价是耗电。不想常亮可以设 false。
@property (nonatomic, assign) BOOL keepScreenOn;

/// 真实麦克风混入音量（0~1，默认 0.35）。
///
///  效果是「助播在旁边说话」：素材里主播的声音保持原样不压，
///  真麦按这个比例叠上去。不说话时就是房间底噪，画面听着更像现场。
///  设 0 = 只有素材（等于 audioMode 1 的老行为）。
@property (nonatomic, assign) double micLevel;

/// 素材音量（0~1，默认 1.0 = 原样）。
///  只有想让素材更小声时才需要动它。
@property (nonatomic, assign) double materialLevel;

/// 真实摄像头对画面的影响力（0 = 不参与，1 = 完全跟随）。
///
/// 手机镜头实时拍着环境，我们**不把真实画面叠上去**，只用它的平均亮度
/// 去调制素材的亮度：屋里开灯、拉窗帘，直播画面跟着变。
/// 观众看到的是活着的光线，取证层面也是真实传感器在响应。
///
/// 手要出镜（绿幕抠像）时另走合成管线，这个开关只负责"有真实参与"这件事。
@property (nonatomic, assign) double realCameraInfluence;

// ---- 伪装 ----
@property (nonatomic, assign) BOOL jitterTimestamps;     // 时间戳抖动
@property (nonatomic, assign) BOOL hideJailbreak;        // 越狱痕迹抹除
@property (nonatomic, assign) BOOL letRealCameraRun;     // 真摄像头空转（更真实）
@property (nonatomic, assign) BOOL hideOverlayQuickly;   // 面板自动隐藏

// ---- 工具 ----
- (void)reload;
- (void)persist;
- (NSArray<NSString *> *)availableAssets;
- (NSURL *)assetURL;
- (NSString *)assetDirectory;

/// 本地没有素材时，从 http://liveHost:httpPort/<assetName>.mp4 拉一份到沙盒。
/// 在后台线程调用，返回 YES 表示文件已就位。
- (BOOL)ensureAssetDownloaded;

@end

#ifdef __cplusplus
extern "C" {
#endif

/// 把一行诊断日志回传到电脑（pc/serve_assets.py 的 /vcam-log 端点）。
///
/// 为什么需要它：真机沙盒里的 NSLog 电脑根本看不到，爱思助手的实时日志
/// 又不落盘 —— 出问题时等于两眼一抹黑。这里让 dylib 直接把自己看到的
/// 情况发回电脑，落在 pc/vcam-device.log 里。
///
/// 内部异步发送，任何线程都能调，不会阻塞调用方。
void VCRemoteLog(NSString *fmt, ...) NS_FORMAT_FUNCTION(1, 2);

#ifdef __cplusplus
}
#endif

#endif /* VCamConfig_h */
