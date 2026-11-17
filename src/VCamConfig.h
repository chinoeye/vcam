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

#endif /* VCamConfig_h */
