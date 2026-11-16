//
//  VCamConfig.m
//

#import "VCamConfig.h"
#import "VCLog.h"

static NSString *const kDomain = @"com.yg.vcam";

// rootless 环境所有 tweak 资源在 /var/jb 下；rootful 直接是根
static NSString *VCJailbreakRoot(void)
{
    static NSString *root = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        if ([[NSFileManager defaultManager] fileExistsAtPath:@"/var/jb/usr/lib"] ||
            [[NSFileManager defaultManager] fileExistsAtPath:@"/var/jb/Library"]) {
            root = @"/var/jb";
        } else {
            root = @"";
        }
    });
    return root;
}

@interface VCamConfig ()
@property (nonatomic, copy) NSString *assetDir;
@end

@implementation VCamConfig

+ (VCamConfig *)shared
{
    static VCamConfig *inst = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        inst = [[VCamConfig alloc] init];
        [inst reload];
    });
    return inst;
}

- (instancetype)init
{
    if ((self = [super init])) {
        _assetDir = [self resolveAssetDirectory];
        [self applyDefaults];
    }
    return self;
}

- (void)applyDefaults
{
    _sourceKind        = VCSourceKindAsset;
    _audioMode         = VCAudioModeMic;
    _assetName         = @"";
    _liveHost          = @"";
    _livePort          = 8099;
    _injectEnabled     = YES;
    _loopEnabled       = YES;
    _paused            = NO;
    _jitterTimestamps  = YES;
    _hideJailbreak     = YES;
    _letRealCameraRun  = YES;
    _hideOverlayQuickly = NO;
}

- (NSString *)resolveAssetDirectory
{
    // 优先 /Library/Application Support（App 进程可读，不受沙盒限制）
    NSArray *candidates = @[
        [VCJailbreakRoot() stringByAppendingPathComponent:
            @"Library/Application Support/VCam/assets"],
        @"/var/mobile/Library/Application Support/VCam/assets",
        [NSTemporaryDirectory() stringByAppendingPathComponent:@"VCam/assets"],
    ];
    NSFileManager *fm = [NSFileManager defaultManager];
    for (NSString *p in candidates) {
        BOOL isDir = NO;
        if ([fm fileExistsAtPath:p isDirectory:&isDir] && isDir) {
            return p;
        }
    }
    // 都不存在就用第一个并创建
    NSString *first = candidates.firstObject;
    [fm createDirectoryAtPath:first withIntermediateDirectories:YES
                   attributes:nil error:NULL];
    return first;
}

- (NSString *)assetDirectory
{
    return _assetDir;
}

// ------------------------------------------------------------------ 读写

- (void)reload
{
    NSUserDefaults *d = [[NSUserDefaults alloc] initWithSuiteName:kDomain];
    if (!d) d = [NSUserDefaults standardUserDefaults];

    [self applyDefaults];

    if ([d objectForKey:@"sourceKind"])       _sourceKind = (VCSourceKind)[d integerForKey:@"sourceKind"];
    if ([d objectForKey:@"audioMode"])        _audioMode = (VCAudioMode)[d integerForKey:@"audioMode"];
    if ([d objectForKey:@"assetName"])        _assetName = [d stringForKey:@"assetName"] ?: @"";
    if ([d objectForKey:@"liveHost"])         _liveHost = [d stringForKey:@"liveHost"] ?: @"";
    if ([d objectForKey:@"livePort"])         _livePort = (uint16_t)[d integerForKey:@"livePort"];
    if ([d objectForKey:@"injectEnabled"])    _injectEnabled = [d boolForKey:@"injectEnabled"];
    if ([d objectForKey:@"loopEnabled"])      _loopEnabled = [d boolForKey:@"loopEnabled"];
    if ([d objectForKey:@"paused"])           _paused = [d boolForKey:@"paused"];
    if ([d objectForKey:@"jitterTimestamps"]) _jitterTimestamps = [d boolForKey:@"jitterTimestamps"];
    if ([d objectForKey:@"hideJailbreak"])    _hideJailbreak = [d boolForKey:@"hideJailbreak"];
    if ([d objectForKey:@"letRealCameraRun"]) _letRealCameraRun = [d boolForKey:@"letRealCameraRun"];
    if ([d objectForKey:@"hideOverlayQuickly"]) _hideOverlayQuickly = [d boolForKey:@"hideOverlayQuickly"];

    if (_livePort == 0) _livePort = 8099;
    if (_assetName.length == 0) {
        NSArray *all = [self availableAssets];
        _assetName = all.firstObject ?: @"";
    }

    VCLog(@"配置已加载: source=%ld audio=%ld asset=%@ inject=%d",
          (long)_sourceKind, (long)_audioMode, _assetName, _injectEnabled);
}

- (void)persist
{
    NSUserDefaults *d = [[NSUserDefaults alloc] initWithSuiteName:kDomain];
    if (!d) d = [NSUserDefaults standardUserDefaults];

    [d setInteger:_sourceKind forKey:@"sourceKind"];
    [d setInteger:_audioMode forKey:@"audioMode"];
    [d setObject:_assetName ?: @"" forKey:@"assetName"];
    [d setObject:_liveHost ?: @"" forKey:@"liveHost"];
    [d setInteger:_livePort forKey:@"livePort"];
    [d setBool:_injectEnabled forKey:@"injectEnabled"];
    [d setBool:_loopEnabled forKey:@"loopEnabled"];
    [d setBool:_paused forKey:@"paused"];
    [d setBool:_jitterTimestamps forKey:@"jitterTimestamps"];
    [d setBool:_hideJailbreak forKey:@"hideJailbreak"];
    [d setBool:_letRealCameraRun forKey:@"letRealCameraRun"];
    [d setBool:_hideOverlayQuickly forKey:@"hideOverlayQuickly"];
    [d synchronize];
}

// ------------------------------------------------------------------ 素材

- (NSArray<NSString *> *)availableAssets
{
    NSFileManager *fm = [NSFileManager defaultManager];
    NSArray *files = [fm contentsOfDirectoryAtPath:_assetDir error:NULL] ?: @[];
    NSMutableArray *out = [NSMutableArray array];
    NSSet *exts = [NSSet setWithObjects:@"mp4", @"mov", @"m4v", nil];
    for (NSString *f in files) {
        if ([exts containsObject:f.pathExtension.lowercaseString]) {
            [out addObject:f.stringByDeletingPathExtension];
        }
    }
    [out sortUsingSelector:@selector(compare:)];
    return out;
}

- (NSURL *)assetURL
{
    if (_assetName.length == 0) return nil;
    NSArray *cands = @[
        [_assetDir stringByAppendingPathComponent:
            [_assetName stringByAppendingPathExtension:@"mp4"]],
        [_assetDir stringByAppendingPathComponent:
            [_assetName stringByAppendingPathExtension:@"mov"]],
    ];
    NSFileManager *fm = [NSFileManager defaultManager];
    for (NSString *p in cands) {
        if ([fm fileExistsAtPath:p]) {
            return [NSURL fileURLWithPath:p];
        }
    }
    return nil;
}

@end
