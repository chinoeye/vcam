//
//  VCOverlay.m
//

#import "VCOverlay.h"
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
}

// 用穿透容器替换默认的 rootView
- (void)loadView
{
    self.view = [[VCPassthroughView alloc] initWithFrame:[UIScreen mainScreen].bounds];
    self.view.backgroundColor = [UIColor clearColor];
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor clearColor];

    // ---- 悬浮球 ----
    _ball = [UIButton buttonWithType:UIButtonTypeCustom];
    _ball.frame = CGRectMake(self.view.bounds.size.width - 64, 120, 44, 44);
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
    [_ball addGestureRecognizer:
        [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(dragBall:)]];
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
    [NSTimer scheduledTimerWithTimeInterval:1.5 target:self
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
    _expanded = !_expanded;
    _panel.hidden = !_expanded;
    if (_expanded) {
        // 面板贴着球出现，别飞出屏幕
        CGFloat w = _panel.bounds.size.width;
        CGFloat x = _ball.center.x + w / 2 + 12 > self.view.bounds.size.width
                    ? self.view.bounds.size.width - w - 12
                    : _ball.center.x + 30;
        CGFloat y = MAX(60, MIN(_ball.center.y - 40,
                                self.view.bounds.size.height - _panel.bounds.size.height - 20));
        _panel.frame = CGRectMake(x, y, w, _panel.bounds.size.height);
        _ball.alpha = 0.9;
    } else {
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
            UIWindow *w = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
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
            VCLog(@"控制面板已显示");
        });
    });
}

@end
