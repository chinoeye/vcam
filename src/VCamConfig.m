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
    // 默认素材名。文件名用最普通的名字，避免在沙盒里显得突兀。
    _assetName         = @"video";
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
    // 1.0 = 不补偿。开播页那条提亮曲线要靠这个抵掉，默认先关着，
    // 由 config.plist 的 outputGamma 决定（实测 1.5 左右抵得住）。
    _outputGamma = 1.0;
    _outputSaturation = 1.0;
    _audioOffsetMs = 0.0;   // 素材自带音画错位时用，正数=声音往后推
    _greenKeyEnabled = NO;
    _greenKeyThreshold = 0.35;
    // 默认关：先让用户确认"不参与"时画面是什么样，再决定要不要开。
    _realCameraInfluence = 0.0;
}

/// 候选目录是否真的可用（能建、能写）。
///
/// 必须真的试写一次，不能只看 fileExistsPath ——
/// 非越狱 / TrollStore 环境下 /var/mobile 对 App 是只读的，
/// 路径"看起来存在"但写不进去，直接用作素材目录会导致后面的写入全部静默失败。
static BOOL VCAssetDirUsable(NSString *p, BOOL createIfMissing,
                            BOOL *outWasCreated)
{
    if (p.length == 0) return NO;
    NSFileManager *fm = [NSFileManager defaultManager];
    BOOL isDir = NO;

    if ([fm fileExistsAtPath:p isDirectory:&isDir]) {
        if (!isDir) return NO;
    } else {
        if (!createIfMissing) return NO;
        NSError *err = nil;
        if (![fm createDirectoryAtPath:p withIntermediateDirectories:YES
                            attributes:nil error:&err]) {
            VCLog(@"素材目录候选不可用：%@（%@）", p,
                  err.localizedDescription ?: @"创建失败");
            return NO;
        }
        if (outWasCreated) *outWasCreated = YES;
    }

    // 试写一个探针文件，确认真能落地
    NSString *probe = [p stringByAppendingPathComponent:@".vc_probe"];
    BOOL ok = [[NSData data] writeToFile:probe atomically:YES];
    if (ok) [fm removeItemAtPath:probe error:NULL];
    return ok;
}

- (NSString *)resolveAssetDirectory
{
    NSMutableArray *candidates = [NSMutableArray array];

    // ① 越狱环境优先：抖音沙盒之外。
    //
    //   素材是个几百 MB 的成品视频，放在 App 自己的 Documents 里
    //   （`.../Aweme/Documents/VCam/assets/current.mp4`）是唯一的**文件级**
    //   痕迹 —— API 层我们已经是原地改写、PTS/attachments 全原生，
    //   抖音看不出画面来源，唯一能抓的就是这个文件名。
    //
    //   /var/mobile/Media 在越狱环境下可读可写（需预建并 chown 给 _installd），
    //   非越狱时它对 App 只读 —— 下面的探针写会失败，自动降级到 ②，
    //   所以两种环境都不会因此失效。
    [candidates addObject:@"/var/mobile/Media/VCamAssets"];

    // ② 非越狱 / TrollStore：只有容器内可写。
    //
    //   ★ 现在优先放 **Library/Caches** 下一个伪装成抖音自己缓存目录的位置。
    //
    //     为什么换：以前是 `Documents/VCam/assets/current.mp4` ——
    //     「VCam」直接写明用途、「current」写明是当前播放的那份，
    //     一个几 GB 的 mp4 摆在那儿，翻一眼沙盒就知道是什么。
    //     现在改成：
    //         Library/Caches/com.ss.iphone.ugc.Aweme.cache/video.mp4
    //     目录名看着就是抖音自己的缓存，文件名是最普通的 video.mp4。
    //
    //     代价：Caches 可能被系统/App 清理，素材会消失。
    //     使用方式是「每次开播前换素材」，所以这个代价可以接受 ——
    //     而且清掉了也只是回到「没素材」状态，不会崩。
    NSString *caches = NSSearchPathForDirectoriesInDomains(NSCachesDirectory,
                                                            NSUserDomainMask, YES).firstObject;
    if (caches.length > 0) {
        [candidates addObject:[caches stringByAppendingPathComponent:@"com.ss.iphone.ugc.Aweme.cache"]];
    }

    // 旧的 Documents 位置保留在探测链后面，方便平滑过渡（存量的素材还能用）
    NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory,
                                                         NSUserDomainMask, YES).firstObject;
    if (docs.length > 0) {
        [candidates addObject:[docs stringByAppendingPathComponent:@"VCam/assets"]];
    }
    // ③ 最后的兜底
    [candidates addObject:[NSTemporaryDirectory() stringByAppendingPathComponent:@"VCam/assets"]];

    for (NSString *p in candidates) {
        BOOL created = NO;
        if (VCAssetDirUsable(p, YES, &created)) {
            if (![p containsString:@"/Documents/"] && ![p containsString:@"/tmp/"]) {
                VCLog(@"素材目录：%@（沙盒外，越狱路径）", p);
            } else {
                VCLog(@"素材目录：%@（沙盒内）", p);
            }
            return p;
        }
    }

    // 全都不行：用 Documents 那条，至少路径是合法的
    NSString *fallback = candidates.count > 1 ? candidates[1] : candidates.lastObject;
    [[NSFileManager defaultManager] createDirectoryAtPath:fallback
                              withIntermediateDirectories:YES attributes:nil error:NULL];
    VCLog(@"素材目录：%@（兜底）", fallback);
    return fallback;
}

/// config.plist 的读取位置：**优先新目录，其次老位置**。
///
///  新：Library/Caches/com.ss.iphone.ugc.Aweme.cache/config.plist
///  旧：Documents/VCam/config.plist（兼容存量，不暴露就还能用）
///
///  搬家的原因和素材一样 —— Documents/VCam 这个名字本身就说明用途。
- (void)applyConfigFile
{
    NSMutableArray<NSString *> *paths = [NSMutableArray array];

    NSString *caches = NSSearchPathForDirectoriesInDomains(NSCachesDirectory,
                                                            NSUserDomainMask, YES).firstObject;
    if (caches.length > 0) {
        [paths addObject:[caches stringByAppendingPathComponent:@"com.ss.iphone.ugc.Aweme.cache/config.plist"]];
    }
    NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory,
                                                         NSUserDomainMask, YES).firstObject;
    if (docs.length > 0) {
        [paths addObject:[docs stringByAppendingPathComponent:@"VCam/config.plist"]];
    }

    NSString *path = nil;
    NSDictionary *d = nil;
    for (NSString *p in paths) {
        NSDictionary *tmp = [NSDictionary dictionaryWithContentsOfFile:p];
        if ([tmp isKindOfClass:[NSDictionary class]]) { path = p; d = tmp; break; }
    }
    if (!d) return;

    if (d[@"injectEnabled"])     _injectEnabled = [d[@"injectEnabled"] boolValue];
    if (d[@"paused"])            _paused = [d[@"paused"] boolValue];
    if (d[@"loopEnabled"])       _loopEnabled = [d[@"loopEnabled"] boolValue];
    if (d[@"jitterTimestamps"])  _jitterTimestamps = [d[@"jitterTimestamps"] boolValue];
    if (d[@"hideJailbreakV2"])   _hideJailbreak = [d[@"hideJailbreakV2"] boolValue];
    if (d[@"assetName"])         _assetName = [d[@"assetName"] description];
    if (d[@"audioMode"])         _audioMode = (VCAudioMode)[d[@"audioMode"] integerValue];
    if (d[@"outputGamma"])       _outputGamma = [d[@"outputGamma"] doubleValue];
    if (d[@"outputSaturation"])  _outputSaturation = [d[@"outputSaturation"] doubleValue];
    if (d[@"audioOffsetMs"])     _audioOffsetMs = [d[@"audioOffsetMs"] doubleValue];
    if (d[@"greenKeyEnabled"])   _greenKeyEnabled = [d[@"greenKeyEnabled"] boolValue];
    if (d[@"greenKeyThreshold"]) _greenKeyThreshold = [d[@"greenKeyThreshold"] doubleValue];
    if (d[@"realCameraInfluence"]) _realCameraInfluence = [d[@"realCameraInfluence"] doubleValue];

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
