//
//  VCamConfig.m
//

#import "VCamConfig.h"
#import "VCLog.h"

#import <sys/socket.h>
#import <netinet/in.h>
#import <netdb.h>
#import <arpa/inet.h>
#import <unistd.h>
#import <string.h>
#import <stdarg.h>

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
    _audioMode         = VCAudioModeAsset;   // 素材音轨（0=真麦 1=素材 2=静音）
    // 默认素材名。没有 config.plist 时靠它去电脑拉 test_demo.mp4，
    // 因为抖音是苹果正版、爱思不给浏览沙盒，没法手动把文件塞进来。
    _assetName         = @"current";   // 指向 6.5GB 成品，避免用到手机沙盒里的旧 test_demo 缓存
    // 默认电脑地址（局域网）。IP 变了要么改这里重编，要么放 config.plist 覆盖。
    _liveHost          = @"192.168.3.88";
    _livePort          = 8099;   // 实时帧 TCP（obs_live_push.py）
    _httpPort          = 8088;   // 素材下载 HTTP（serve_assets.py）
    _injectEnabled     = YES;
    _loopEnabled       = YES;
    _paused            = NO;
    _jitterTimestamps  = YES;
    // 路径遮蔽（stat/lstat/access + fileExistsAtPath 那一套）默认关。
    //
    // 为什么：这三个是 App 运行期调用量最大的系统调用，hook 它们等于给
    // 每次文件操作都套一遍路径匹配。而它存在的意义只有一个 —— 藏起
    // /var/jb 那套越狱目录。现在走的是 TrollStore + TrollFools 注入，
    // 系统里根本没有 /var/jb 可藏，这层是纯负担。
    //
    // dyld 镜像隐藏是另一回事（防止 App 发现 VCam.dylib 本身），
    // 那部分在 VCHide 里始终安装，不受这个开关影响。
    //
    // 将来真要重新越狱用 ellekit 加载，把这里改回 YES。
    _hideJailbreak     = NO;
    _letRealCameraRun  = YES;
    _hideOverlayQuickly = NO;
}

- (NSString *)resolveAssetDirectory
{
    // 优先 /Library/Application Support（App 进程可读，不受沙盒限制）
    // TrollStore 注入的 dylib 跑在 App 自己的沙盒里，只能碰得到本容器的目录。
    // 老版本那几条 /var/jb、/var/mobile/Library 的路径在无越狱环境下全部无效。
    //
    // 现在统一用 App 自己的 Documents ——
    // 爱思助手 → 文件管理 → 应用 → 抖音 → Documents，可以直接往里拖素材。
    // 或者把素材下载到「文件」App 再用爱思搬进来。
    NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory,
                                                         NSUserDomainMask, YES).firstObject;
    NSMutableArray *candidates = [NSMutableArray array];
    if (docs.length > 0) {
        [candidates addObject:[docs stringByAppendingPathComponent:@"VCam/assets"]];
    }
    [candidates addObject:[NSTemporaryDirectory() stringByAppendingPathComponent:@"VCam/assets"]];

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

/// Documents/VCam/config.plist 里的键优先于 UserDefaults。
/// 用爱思助手改这个文件，重启抖音就生效 —— 这是后台模式唯一的控制入口。
- (void)applyConfigFile
{
    NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory,
                                                         NSUserDomainMask, YES).firstObject;
    if (docs.length == 0) return;

    NSString *path = [docs stringByAppendingPathComponent:@"VCam/config.plist"];
    NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:path];
    if (![d isKindOfClass:[NSDictionary class]]) return;

    if (d[@"injectEnabled"])     _injectEnabled = [d[@"injectEnabled"] boolValue];
    if (d[@"paused"])            _paused = [d[@"paused"] boolValue];
    if (d[@"loopEnabled"])       _loopEnabled = [d[@"loopEnabled"] boolValue];
    if (d[@"jitterTimestamps"])  _jitterTimestamps = [d[@"jitterTimestamps"] boolValue];
    if (d[@"hideJailbreakV2"])   _hideJailbreak = [d[@"hideJailbreakV2"] boolValue];
    if (d[@"assetName"])         _assetName = [d[@"assetName"] description];
    if (d[@"audioMode"])         _audioMode = (VCAudioMode)[d[@"audioMode"] integerValue];

    // 实时源（OBS 推流）：sourceKind=1 时走 VCLiveSource
    if (d[@"sourceKind"])        _sourceKind = (VCSourceKind)[d[@"sourceKind"] integerValue];
    if (d[@"liveHost"])          _liveHost = [d[@"liveHost"] description];
    if (d[@"livePort"])          _livePort = (uint16_t)[d[@"livePort"] integerValue];
    if (d[@"httpPort"])          _httpPort = (uint16_t)[d[@"httpPort"] integerValue];

    VCLog(@"已加载配置文件 %@（inject=%d asset=%@）",
          path, _injectEnabled, _assetName);
}

- (NSString *)assetDirectory
{
    return _assetDir;
}

// ------------------------------------------------------------------ 读写

- (void)reload
{
    // 面板已经移除（那个全屏 window 是画面卡死的元凶），
    // UserDefaults 里的历史值现在只有害处：
    // 你之前在面板里关过「注入」，persist 把 injectEnabled=NO 写进去了，
    // 之后每次启动都读回 NO → VCInjectionActive() 永远假 → 素材压根不加载。
    //
    // 所以这里不再读 UserDefaults，只认「默认值 + Documents/VCam/config.plist」。
    [self applyDefaults];

    if (_livePort == 0) _livePort = 8099;

    // Documents/VCam/config.plist 里的键覆盖默认值（文件存在才生效）
    [self applyConfigFile];

    // 素材名兜底：配置里没写、沙盒里也没有，就用默认的 test_demo
    if (_assetName.length == 0) {
        NSArray *all = [self availableAssets];
        _assetName = all.firstObject ?: @"test_demo";
    }

    VCLog(@"配置已加载: source=%ld audio=%ld asset=%@ inject=%d host=%@:%u/%u",
          (long)_sourceKind, (long)_audioMode, _assetName, _injectEnabled,
          _liveHost, _httpPort, _livePort);
}

- (void)persist
{    NSUserDefaults *d = [[NSUserDefaults alloc] initWithSuiteName:kDomain];
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
    [d setBool:_hideJailbreak forKey:@"hideJailbreakV2"];
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

    // ① 本地沙盒里有就直接用本地文件（最快，无网络依赖）
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

    // ② 本地没有就直接返回 HTTP URL —— 让 AVAssetReader 边下边播。
    //
    //   以前这里返回 nil，依赖 ensureAssetDownloaded 先同步下载完整个文件。
    //   7 MB 的素材没问题，但 6.5 GB 的成品要下 30 多分钟，而且
    //   VCDownloadHTTP 是同步的，抖音整个卡住不能动。
    //
    //   AVURLAsset 对 HTTP 源本来就支持按需拉取（配合服务端 Range），
    //   所以直接给 URL 最合适：只拉几 MB 头部就能开播。
    if (_liveHost.length > 0) {
        uint16_t port = _httpPort > 0 ? _httpPort : 8088;
        NSString *escaped = [_assetName stringByAddingPercentEncodingWithAllowedCharacters:
                             [NSCharacterSet URLPathAllowedCharacterSet]];
        NSString *urlStr = [NSString stringWithFormat:@"http://%@:%u/%@.mp4",
                            _liveHost, port, escaped];
        NSURL *u = [NSURL URLWithString:urlStr];
        if (u) {
            VCLog(@"素材走 HTTP 直连：%@", urlStr);
            return u;
        }
    }

    return nil;
}

// ------------------------------------------------------------------ 素材自动下载
//
//  抖音是「苹果正版」，爱思助手不给浏览沙盒，没法手动拖文件进去。
//  所以改成：本地找不到素材就自己去电脑拉。
//
//  为什么用裸 socket 而不是 NSURLSession：
//    ATS 默认禁止 http 明文，而抖音的 Info.plist 在别人的签名里，我们改不了。
//    BSD socket 走的是底层，不受 ATS 那套检查约束。

static BOOL VCDownloadHTTP(NSString *host, uint16_t port, NSString *path, NSString *dest)
{
    if (host.length == 0 || path.length == 0 || dest.length == 0) return NO;

    struct hostent *he = gethostbyname(host.UTF8String);
    if (!he || he->h_addrtype != AF_INET || !he->h_addr_list[0]) return NO;

    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) return NO;

    struct timeval tv;
    tv.tv_sec = 15;
    tv.tv_usec = 0;
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof(tv));

    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_port   = htons(port);
    memcpy(&addr.sin_addr.s_addr, he->h_addr_list[0], sizeof(uint32_t));

    if (connect(fd, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
        close(fd);
        return NO;
    }

    char req[512];
    snprintf(req, sizeof(req),
             "GET %s HTTP/1.0\r\nHost: %s\r\nUser-Agent: VCam\r\n"
             "Accept: */*\r\nConnection: close\r\n\r\n",
             path.UTF8String, host.UTF8String);

    if (send(fd, req, strlen(req), 0) <= 0) {
        close(fd);
        return NO;
    }

    NSMutableData *buf = [NSMutableData dataWithCapacity:4 * 1024 * 1024];
    char tmp[32768];
    ssize_t n;
    while ((n = recv(fd, tmp, sizeof(tmp), 0)) > 0) {
        [buf appendBytes:tmp length:(NSUInteger)n];
    }
    close(fd);

    if (buf.length == 0) return NO;

    NSData *sep = [@"\r\n\r\n" dataUsingEncoding:NSUTF8StringEncoding];
    NSRange r = [buf rangeOfData:sep options:0
                           range:NSMakeRange(0, MIN(buf.length, (NSUInteger)8192))];
    if (r.location == NSNotFound) return NO;

    NSString *head = [[NSString alloc] initWithData:[buf subdataWithRange:NSMakeRange(0, r.location)]
                                           encoding:NSUTF8StringEncoding];
    if (![head hasPrefix:@"HTTP/1.0 200"] && ![head hasPrefix:@"HTTP/1.1 200"]) {
        VCLog(@"下载被拒: %@", [head componentsSeparatedByString:@"\r\n"].firstObject);
        return NO;
    }

    NSData *body = [buf subdataWithRange:
                    NSMakeRange(r.location + r.length,
                                buf.length - r.location - r.length)];
    if (body.length < 4096) return NO;   // 太小，肯定不是视频

    return [body writeToFile:dest atomically:YES];
}

- (BOOL)ensureAssetDownloaded
{
    if (_assetName.length == 0) return NO;

    NSString *dir  = [self assetDirectory];
    NSString *dest = [dir stringByAppendingPathComponent:
                      [_assetName stringByAppendingPathExtension:@"mp4"]];

    NSFileManager *fm = [NSFileManager defaultManager];
    if ([fm fileExistsAtPath:dest]) {
        return YES;   // 已经有了
    }
    [fm createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:NULL];

    if (_liveHost.length == 0) {
        VCLog(@"素材缺失，且没配 liveHost，无法自动下载");
        return NO;
    }

    uint16_t port = _httpPort > 0 ? _httpPort : 8088;
    NSString *escaped = [_assetName stringByAddingPercentEncodingWithAllowedCharacters:
                         [NSCharacterSet URLPathAllowedCharacterSet]];
    NSString *path = [NSString stringWithFormat:@"/%@.mp4", escaped];

    VCLog(@"本地无素材，从 %@:%u 拉 %@", _liveHost, port, path);
    BOOL ok = VCDownloadHTTP(_liveHost, port, path, dest);
    VCLog(@"素材下载%@", ok ? @"成功" : @"失败");
    return ok;
}

// ------------------------------------------------------------------ 远程日志
//
//  真机里的 NSLog 电脑看不到，爱思的实时日志又不落盘。
//  出问题时只能让 dylib 自己把线索发回来。

/// 发一个 GET 就走，不等响应。服务端收到就会落盘。
static void VCSendGet(NSString *host, uint16_t port, NSString *path)
{
    if (host.length == 0 || path.length == 0) return;

    struct hostent *he = gethostbyname(host.UTF8String);
    if (!he || !he->h_addr_list[0]) return;

    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) return;

    struct timeval tv;
    tv.tv_sec = 3;
    tv.tv_usec = 0;
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof(tv));

    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_port   = htons(port);
    memcpy(&addr.sin_addr.s_addr, he->h_addr_list[0], sizeof(uint32_t));

    if (connect(fd, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
        close(fd);
        return;
    }

    char req[1600];
    snprintf(req, sizeof(req),
             "GET %s HTTP/1.0\r\nHost: %s\r\nConnection: close\r\n\r\n",
             path.UTF8String, host.UTF8String);
    send(fd, req, strlen(req), 0);
    close(fd);
}

void VCRemoteLog(NSString *fmt, ...)
{
    va_list ap;
    va_start(ap, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    if (msg.length == 0) return;

    VCLog(@"[远程] %@", msg);

    // 内部异步：任何线程调用都不会被网络阻塞
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        VCamConfig *c = VCamConfig.shared;
        if (c.liveHost.length == 0) return;
        uint16_t port = c.httpPort > 0 ? c.httpPort : 8088;
        NSString *enc = [msg stringByAddingPercentEncodingWithAllowedCharacters:
                         [NSCharacterSet URLQueryAllowedCharacterSet]];
        VCSendGet(c.liveHost, port,
                  [NSString stringWithFormat:@"/vcam-log?m=%@", enc ?: @"..."]);
    });
}

@end
