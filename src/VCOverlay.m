//
//  VCOverlay.m
//

#import "VCOverlay.h"
#import "VCAudioSource.h"
#import "VCamConfig.h"
#import "VCFrameSource.h"
#import "VCLiveSource.h"
#import "VCSampleBufferFactory.h"
#import "VCLog.h"

#import <QuartzCore/QuartzCore.h>

// ------------------------------------------------------------------ 覆盖层表

static NSMapTable *VCOverlayTable(void)
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

static NSLock *VCOverlayLock(void)
{
    static NSLock *lock = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ lock = [[NSLock alloc] init]; });
    return lock;
}

// 面板窗口必须由我们强引用，否则 UIWindow 可能被回收
static UIWindow *gVCamPanelWindow = nil;

// ------------------------------------------------------------------ 面板

 @interface VCamPanelController : UIViewController
@end

@interface VCamPanelController ()
- (void)togglePanel;
- (void)dragBall:(UIPanGestureRecognizer *)g;
- (void)toggleInject:(UISwitch *)sw;
- (void)toggleLoop:(UISwitch *)sw;
- (void)audioChanged:(UISegmentedControl *)seg;
- (void)togglePause;
- (void)assetTapped:(UIButton *)b;
- (void)refreshStatus;
- (UIView *)separator;
- (UISwitch *)switchRowIn:(UIStackView *)stack
                    title:(NSString *)t
                    value:(BOOL)on
                   action:(SEL)action;
- (UIView *)assetList;
- (void)fillAssetStack;
@end

// ------------------------------------------------------------------
//  触摸穿透容器 VCPassthroughView
//
//  悬浮面板是一个全屏透明 UIWindow（windowLevel = Alert + 100）。
//  iOS 的触摸事件只会分发给**最上层命中的那个 window**，不会往下传。
//  只要这个 window 的 rootView 还接受触摸（userInteractionEnabled 默认 YES），
//  整个屏幕的每一次点击、滑动都会被它吃掉，下面的 App 一个事件都收不到。
//
//  在抖音里的表现：
//    · 视频照播（不需要触摸）
//    · 手指一滑动，界面就僵住不动 —— 用户说的"卡"
//    · 点链接没反应，反复点，看起来像"加载慢"
//    · 跟「注入」开关完全无关，因为面板一直都在
//
//  修法：用一个只转发给子视图的容器当 rootView ——
//  命中自己就返回 nil（穿透），命中子视图（悬浮球 / 面板）才响应。
//  hidden 的子视图本来就不参与 hitTest，所以面板收起时自动只剩球。
//
//  注意 hitTest:withEvent: 是 UIView 的方法，UIViewController 上没有，
//  所以必须落在一个自定义 UIView 上。
// ------------------------------------------------------------------
@interface VCPassthroughView : UIView
@end

@implementation VCPassthroughView

- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event
{
    UIView *hit = [super hitTest:point withEvent:event];
    if (hit == self) return nil;   // 空白区域 → 放行给下层 App
    return hit;
}

@end

@implementation VCamPanelController
{
    UIButton *_ball;
    UIView *_panel;
    UILabel *_status;
    UISwitch *_injectSwitch;
    UISwitch *_loopSwitch;
    UISegmentedControl *_audioSeg;
    UIButton *_pauseButton;
    UIStackView *_assetStack;
    BOOL _expanded;
    CGPoint _ballHome;
    NSTimer *_timer;
}

/// 彻底停掉面板：定时器 invalidate + 视图隐藏。
/// 静默模式下这东西必须在几秒后消失，否则定时器会一直 retain 住 controller，
/// 全屏透明视图也一直参与合成。
- (void)shutdown
{
    [_timer invalidate];
    _timer = nil;
    self.view.hidden = YES;
}

// 用穿透容器替换默认的 rootView。
//
// 尺寸只给 44×44（= 悬浮球大小），不是全屏 —— 宿主 UIWindow 也这么大。
// 原因见 +installPanelIfNeeded 里的说明：全屏透明 window 会强制多合成一整屏。
- (void)loadView
{
    self.view = [[VCPassthroughView alloc] initWithFrame:CGRectMake(0, 0, 44, 44)];
    self.view.backgroundColor = [UIColor clearColor];
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor clearColor];

    // ---- 悬浮球 ----
    // 宿主 window 只有 44×44，球直接铺满它，不再需要屏幕坐标计算
    _ball = [UIButton buttonWithType:UIButtonTypeCustom];
    _ball.frame = self.view.bounds;
    _ballHome = _ball.center;
    _ball.backgroundColor = [UIColor colorWithWhite:0 alpha:0.45];
    _ball.layer.cornerRadius = 22;
    _ball.layer.borderWidth = 1.5;
    _ball.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.5].CGColor;
    _ball.alpha = 0.55;
    [_ball setTitle:@"VC" forState:UIControlStateNormal];
    [_ball setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    _ball.titleLabel.font = [UIFont boldSystemFontOfSize:13];
    [_ball addTarget:self action:@selector(togglePanel)
   forControlEvents:UIControlEventTouchUpInside];
    // 不再挂拖动手势：宿主 window 只有球这么大，拖动等于搬 window，
    // 每次移动都要重建合成面，得不偿失。先固定右上角，稳定后再考虑加回。
    [self.view addSubview:_ball];

    // ---- 面板 ----
    CGFloat w = 272;
    _panel = [[UIView alloc] initWithFrame:CGRectMake(12, 100, w, 420)];
    _panel.backgroundColor = [UIColor colorWithWhite:0.08 alpha:0.94];
    _panel.layer.cornerRadius = 14;
    _panel.layer.masksToBounds = YES;
    _panel.hidden = YES;
    [self.view addSubview:_panel];

    UIStackView *stack = [[UIStackView alloc] initWithFrame:
                          CGRectMake(14, 14, w - 28, 392)];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 10;
    [_panel addSubview:stack];

    UILabel *title = [[UILabel alloc] init];
    title.text = @"VCam 画面注入";
    title.textColor = [UIColor whiteColor];
    title.font = [UIFont boldSystemFontOfSize:15];
    [stack addArrangedSubview:title];

    _status = [[UILabel alloc] init];
    _status.textColor = [UIColor colorWithWhite:0.65 alpha:1];
    _status.font = [UIFont systemFontOfSize:11];
    _status.numberOfLines = 3;
    [stack addArrangedSubview:_status];

    [stack addArrangedSubview:[self separator]];

    _injectSwitch = [self switchRowIn:stack title:@"启用注入"
                                value:VCamConfig.shared.injectEnabled
                               action:@selector(toggleInject:)];
    _loopSwitch = [self switchRowIn:stack title:@"循环播放"
                              value:VCamConfig.shared.loopEnabled
                             action:@selector(toggleLoop:)];

    // 素材切换
    UILabel *assetTitle = [[UILabel alloc] init];
    assetTitle.text = @"素材";
    assetTitle.textColor = [UIColor colorWithWhite:0.6 alpha:1];
    assetTitle.font = [UIFont systemFontOfSize:12];
    [stack addArrangedSubview:assetTitle];
    [stack addArrangedSubview:[self assetList]];

    // 音频
    UILabel *audioTitle = [[UILabel alloc] init];
    audioTitle.text = @"音频";
    audioTitle.textColor = [UIColor colorWithWhite:0.6 alpha:1];
    audioTitle.font = [UIFont systemFontOfSize:12];
    [stack addArrangedSubview:audioTitle];

    _audioSeg = [[UISegmentedControl alloc] initWithItems:@[@"真麦", @"素材", @"静音"]];
    _audioSeg.selectedSegmentIndex = VCamConfig.shared.audioMode;
    [_audioSeg addTarget:self action:@selector(audioChanged:)
        forControlEvents:UIControlEventValueChanged];
    [stack addArrangedSubview:_audioSeg];

    _pauseButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [_pauseButton setTitle:@"暂停 / 继续" forState:UIControlStateNormal];
    [_pauseButton addTarget:self action:@selector(togglePause)
           forControlEvents:UIControlEventTouchUpInside];
    [stack addArrangedSubview:_pauseButton];

    [self refreshStatus];
    _timer = [NSTimer scheduledTimerWithTimeInterval:1.5 target:self
                                            selector:@selector(refreshStatus)
                                            userInfo:nil repeats:YES];
}

- (UIView *)separator
{
    UIView *v = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 1, 1)];
    v.backgroundColor = [UIColor colorWithWhite:0.3 alpha:1];
    [v.heightAnchor constraintEqualToConstant:1].active = YES;
    return v;
}

- (UISwitch *)switchRowIn:(UIStackView *)stack title:(NSString *)t
                    value:(BOOL)on action:(SEL)action
{
    UIView *row = [[UIView alloc] init];
    [row.heightAnchor constraintEqualToConstant:30].active = YES;

    UILabel *l = [[UILabel alloc] initWithFrame:CGRectMake(0, 0, 180, 30)];
    l.text = t;
    l.textColor = [UIColor whiteColor];
    l.font = [UIFont systemFontOfSize:13];
    [row addSubview:l];

    UISwitch *sw = [[UISwitch alloc] init];
    sw.on = on;
    sw.transform = CGAffineTransformMakeScale(0.8, 0.8);
    sw.frame = CGRectMake(200, 0, 51, 31);
    [sw addTarget:self action:action forControlEvents:UIControlEventValueChanged];
    [row addSubview:sw];

    [stack addArrangedSubview:row];
    return sw;
}

- (UIView *)assetList
{
    UIStackView *list = [[UIStackView alloc] init];
    list.axis = UILayoutConstraintAxisVertical;
    list.spacing = 4;
    _assetStack = list;
    [self fillAssetStack];
    return list;
}

- (void)fillAssetStack
{
    for (UIView *v in _assetStack.arrangedSubviews) {
        [_assetStack removeArrangedSubview:v];
        [v removeFromSuperview];
    }

    NSArray<NSString *> *assets = [VCamConfig.shared availableAssets];
    if (assets.count == 0) {
        UILabel *empty = [[UILabel alloc] init];
        empty.text = @"素材目录为空，先用 PC 端 serve_assets 下载";
        empty.textColor = [UIColor colorWithWhite:0.5 alpha:1];
        empty.font = [UIFont systemFontOfSize:11];
        empty.numberOfLines = 2;
        [_assetStack addArrangedSubview:empty];
        return;
    }

    NSString *current = VCamConfig.shared.assetName;
    for (NSString *name in assets) {
        UIButton *b = [UIButton buttonWithType:UIButtonTypeCustom];
        b.contentHorizontalAlignment = UIControlContentHorizontalAlignmentLeft;
        b.titleLabel.font = [UIFont systemFontOfSize:12];
        b.tag = [assets indexOfObject:name];
        NSString *marker = [name isEqualToString:current] ? @"● " : @"○ ";
        [b setTitle:[marker stringByAppendingString:name]
           forState:UIControlStateNormal];
        [b setTitleColor:([name isEqualToString:current]
                          ? [UIColor colorWithRed:0.35 green:0.85 blue:0.45 alpha:1]
                          : [UIColor colorWithWhite:0.82 alpha:1])
                forState:UIControlStateNormal];
        [b.heightAnchor constraintEqualToConstant:26].active = YES;
        [b addTarget:self action:@selector(assetTapped:) forControlEvents:UIControlEventTouchUpInside];
        [_assetStack addArrangedSubview:b];
    }
}

// ------------------------------------------------------------------ 交互

- (void)togglePanel
{
    UIWindow *host = self.view.window;
    if (!host) return;

    UIScreen *screen = [UIScreen mainScreen];
    CGFloat sw = screen.bounds.size.width;
    CGFloat sh = screen.bounds.size.height;
    CGRect ballFrame = CGRectMake(sw - 64, 120, 44, 44);

    _expanded = !_expanded;

    if (_expanded) {
        // 展开：window 只撑到**面板大小**，绝不撑到全屏。
        //
        // 实测结论：注入开着、不点球，刷视频完全正常；
        // 一点球就卡死 —— 因为点球那一下把 44×44 的 window 瞬间撑成了整屏，
        // 全屏透明合成面一出现，正在解码视频的 GPU 立刻被拖死。
        // 所以这里上限就是面板尺寸，合成面积约等于全屏的三分之一，
        // 而且面板本身是不透明的，不参与全屏 blend。
        CGFloat pw = 272;
        CGFloat ph = MIN(420, sh - 140);
        CGRect pf = CGRectMake((sw - pw) / 2, 100, pw, ph);

        host.frame = pf;
        self.view.frame = CGRectMake(0, 0, pw, ph);
        _panel.frame = self.view.bounds;
        _panel.hidden = NO;

        // 球挪进面板右上角，充当「收起」按钮
        _ball.frame = CGRectMake(pw - 44 - 8, 8, 44, 44);
        _ball.alpha = 0.9;
        [self.view bringSubviewToFront:_ball];
    } else {
        // 收起：window 缩回球那么大
        _panel.hidden = YES;
        host.frame = ballFrame;
        self.view.frame = CGRectMake(0, 0, 44, 44);
        _ball.frame = self.view.bounds;
        _ball.alpha = 0.55;
    }
}

- (void)dragBall:(UIPanGestureRecognizer *)g
{
    CGPoint p = [g locationInView:self.view];
    _ball.center = p;
    if (g.state == UIGestureRecognizerStateEnded) {
        // 吸边
        CGFloat x = p.x < self.view.bounds.size.width / 2 ? 50 : self.view.bounds.size.width - 50;
        [UIView animateWithDuration:0.2 animations:^{
            self->_ball.center = CGPointMake(x, p.y);
        }];
        _ballHome = _ball.center;
    }
}

- (void)toggleInject:(UISwitch *)sw
{
    VCamConfig.shared.injectEnabled = sw.isOn;
    [VCamConfig.shared persist];
    if (!sw.isOn) {
        [VCOverlay detachAll];
    }
    [self refreshStatus];
}

- (void)toggleLoop:(UISwitch *)sw
{
    VCamConfig.shared.loopEnabled = sw.isOn;
    [VCamConfig.shared persist];
}

- (void)audioChanged:(UISegmentedControl *)seg
{
    VCamConfig.shared.audioMode = (VCAudioMode)seg.selectedSegmentIndex;
    [VCamConfig.shared persist];
    VCLog(@"音频模式切到 %ld", (long)seg.selectedSegmentIndex);
    [self refreshStatus];
}

- (void)togglePause
{
    VCamConfig.shared.paused = !VCamConfig.shared.paused;
    [VCamConfig.shared persist];
    [self refreshStatus];
}

- (void)assetTapped:(UIButton *)b
{
    NSArray *assets = [VCamConfig.shared availableAssets];
    if (b.tag < 0 || b.tag >= (NSInteger)assets.count) return;

    NSString *name = assets[b.tag];
    VCamConfig.shared.assetName = name;
    VCamConfig.shared.sourceKind = VCSourceKindAsset;
    [VCamConfig.shared persist];

    NSError *err = nil;
    NSURL *url = [VCamConfig.shared assetURL];
    if (url && [[VCFrameSource shared] reloadWithURL:url error:&err]) {
        [[VCAudioSource shared] loadURL:url error:NULL];
        VCLog(@"切素材: %@", name);
    } else {
        VCLog(@"切素材失败: %@", err);
    }

    // 只刷新素材列表的选中态，不重建整个面板（重建会重复挂 timer）
    [self fillAssetStack];
    [self refreshStatus];
}

- (void)refreshStatus
{
    VCamConfig *cfg = VCamConfig.shared;
    NSString *src = @"";
    if (cfg.sourceKind == VCSourceKindAsset) {
        VCFrameSource *fs = [VCFrameSource shared];
        src = [NSString stringWithFormat:@"素材 %@ · %@ 帧",
               cfg.assetName.length ? cfg.assetName : @"未选",
               fs.isReady ? @(fs.frameCount).stringValue : @"未就绪"];
    } else if (cfg.sourceKind == VCSourceKindLive) {
        src = [NSString stringWithFormat:@"实时 · %@",
               [VCLiveSource shared].statusText];
    } else {
        src = @"未启用";
    }

    NSString *audio = @[@"真麦克风", @"素材音轨", @"静音"][MIN(2, (NSUInteger)cfg.audioMode)];
    _status.text = [NSString stringWithFormat:@"%@\n音频：%@\n注入：%@",
                    src, audio, cfg.injectEnabled ? (cfg.paused ? @"已暂停" : @"运行中") : @"关闭"];
}

@end

// ------------------------------------------------------------------ VCOverlay

@implementation VCOverlay

+ (instancetype)shared
{
    static VCOverlay *inst = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ inst = [[VCOverlay alloc] init]; });
    return inst;
}

+ (void)attachToPreviewLayer:(AVCaptureVideoPreviewLayer *)layer
{
    if (!layer || ![layer isKindOfClass:[AVCaptureVideoPreviewLayer class]]) return;

    [VCOverlayLock() lock];
    AVSampleBufferDisplayLayer *ov = [VCOverlayTable() objectForKey:layer];
    BOOL reuse = (ov != nil && ov.superlayer == layer);
    if (!reuse) {
        if (!ov) {
            ov = [[AVSampleBufferDisplayLayer alloc] init];
            ov.videoGravity = AVLayerVideoGravityResizeAspectFill;
            ov.backgroundColor = [UIColor blackColor].CGColor;
            ov.opaque = YES;
            // 不用 autoresizingMask —— 尺寸对齐在 pushVideoSampleBuffer: 里
            // 每帧同步 parent.bounds，比 autoresizing 更可靠。
            [VCOverlayTable() setObject:ov forKey:layer];
        }
        [ov removeFromSuperlayer];
        ov.frame = layer.bounds;
        [layer addSublayer:ov];
        VCLog(@"预览覆盖层已挂载 %@", NSStringFromCGRect(layer.bounds));
    }
    [VCOverlayLock() unlock];
}

+ (void)pushVideoSampleBuffer:(CMSampleBufferRef)sampleBuffer
{
    if (!sampleBuffer) return;

    NSMutableArray<AVSampleBufferDisplayLayer *> *targets = [NSMutableArray array];
    [VCOverlayLock() lock];
    for (id key in VCOverlayTable()) {
        AVSampleBufferDisplayLayer *v = [VCOverlayTable() objectForKey:key];
        if (v && v.superlayer) [targets addObject:v];
    }
    [VCOverlayLock() unlock];

    for (AVSampleBufferDisplayLayer *ov in targets) {
        @try {
            // 兜底对齐：预览层尺寸可能在挂载之后才确定
            CALayer *parent = ov.superlayer;
            if (parent && !CGRectEqualToRect(ov.frame, parent.bounds)) {
                ov.frame = parent.bounds;
            }
            if (ov.status == AVQueuedSampleBufferRenderingStatusFailed) {
                [ov flush];
            }
            // 队列满就丢弃这一帧，绝不让它堆积 —— 堆积会让预览越来越延迟
            if (!ov.readyForMoreMediaData) continue;
            [ov enqueueSampleBuffer:sampleBuffer];
        } @catch (NSException *e) {
            VCLog(@"覆盖层推帧异常: %@", e.reason);
        }
    }
}

+ (void)detachAll
{
    [VCOverlayLock() lock];
    for (id key in VCOverlayTable()) {
        AVSampleBufferDisplayLayer *v = [VCOverlayTable() objectForKey:key];
        [v flushAndRemoveImage];
        [v removeFromSuperlayer];
    }
    [VCOverlayTable() removeAllObjects];
    [VCOverlayLock() unlock];
}

+ (void)setOverlaysHidden:(BOOL)hidden
{
    // CALayer 的 hidden 在后台线程设也行，但和挂载/卸载同一把锁保护才干净
    [VCOverlayLock() lock];
    for (id key in VCOverlayTable()) {
        AVSampleBufferDisplayLayer *v = [VCOverlayTable() objectForKey:key];
        if (v) v.hidden = hidden;
    }
    [VCOverlayLock() unlock];
}

+ (void)installPanelIfNeeded
{
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        dispatch_async(dispatch_get_main_queue(), ^{
            // ---- 宿主 window 只有悬浮球那么大，不是全屏 ----
            //
            // 这是本轮定位的结论：全屏透明 UIWindow 在 iPhone 8 上
            // 会强制多合成一整屏，抖音点开视频正抢 GPU 解码时直接被拖死，
            // 表现为「画面冻住、HOME 键却有反应」。
            // 实测：球在就卡，球一消失立刻正常。
            //
            // 合成面积从整屏降到 44×44（约千分之一），
            // 面板展开时再临时撑大，收起立刻缩回。
            CGFloat sw = [UIScreen mainScreen].bounds.size.width;
            CGRect ballFrame = CGRectMake(sw - 64, 120, 44, 44);

            UIWindow *w = [[UIWindow alloc] initWithFrame:ballFrame];
            w.windowLevel = UIWindowLevelAlert + 100;
            w.backgroundColor = [UIColor clearColor];
            w.rootViewController = [[VCamPanelController alloc] init];

            if (@available(iOS 13.0, *)) {
                for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
                    if ([scene isKindOfClass:[UIWindowScene class]]) {
                        w.windowScene = (UIWindowScene *)scene;
                        break;
                    }
                }
            }
            w.hidden = NO;
            gVCamPanelWindow = w;
            VCLog(@"悬浮球已挂载 %@（window 仅 %.0fx%.0f）",
                  NSStringFromCGRect(ballFrame), ballFrame.size.width, ballFrame.size.height);

            // ---- 静默模式：面板 5 秒后自毁 ----
            //
            // 目的不是省资源，是**做对照实验**：
            // 这个全屏透明 window 挂在 UIWindowLevelAlert + 100 上，
            // 只要它还在，就永远说不清卡顿到底是它还是别的。
            // 留 5 秒是让用户有机会把「注入」重新打开，
            // 之后就彻底销毁 —— window、controller、定时器一起没。
            VCamConfig *cfg = VCamConfig.shared;
            BOOL active = (cfg.injectEnabled && cfg.sourceKind != VCSourceKindNone);
            if (!active) {
                VCamPanelController *vc = (VCamPanelController *)w.rootViewController;
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                             (int64_t)(5.0 * NSEC_PER_SEC)),
                               dispatch_get_main_queue(), ^{
                    [vc shutdown];
                    w.hidden = YES;
                    if (gVCamPanelWindow == w) gVCamPanelWindow = nil;
                    VCLog(@"静默模式：控制面板已自动销毁（window + 定时器）");
                });
            }
        });
    });
}

@end
