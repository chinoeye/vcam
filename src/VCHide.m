//
//  VCHide.m
//
//  性能说明（v2）：
//  stat / lstat / access 是 App 运行期调用量最大的三个系统调用，
//  抖音启动阶段单次可达十万级。旧实现每次调用都要：
//    · [NSString stringWithUTF8String:] 一次
//    · 遍历 43 条黑名单，每条做 2 次 VCNormalize（内部 substringToIndex）
//      + stringByAppendingString 一次 + 若干 hasPrefix/hasSuffix
//    → 约 90 次 NSString 分配 / 每次调用
//  这就是"打开抖音整体发卡"的真正来源（不只是摄像头链路）。
//
//  v2 改成纯 C 比较：黑名单在安装 hook 时预展开成 C 字符串表，
//  运行期只做 strlen + memcmp，零堆分配。
//

#import "VCHide.h"
#import "VCamConfig.h"
#import "VCLog.h"
#import "VCSubstrateCompat.h"

#import <UIKit/UIKit.h>
#import <sys/stat.h>
#import <unistd.h>
#import <errno.h>
#import <string.h>
#import <stdlib.h>
#import <mach-o/dyld.h>
#import <dlfcn.h>

// ------------------------------------------------------------------ 黑名单（纯 C 表）
//
//  安装时一次性展开。除了原始写法，还预展开 "/private" 别名
//  （/var/jb 与 /private/var/jb 是同一个位置，两种写法都要挡），
//  避免旧实现在运行期反复 substring/拼接。

typedef struct {
    char     *s;
    uint32_t  len;
} VCBlockedItem;

static VCBlockedItem *gBlocked      = NULL;
static size_t         gBlockedCount = 0;

/// 自家路径白名单：素材、配置都在这下面，必须对 App 可见
static inline BOOL VCPathIsOursC(const char *path)
{
    return (path && strstr(path, "VCam") != NULL);
}

static void VCBlockedBuild(void)
{
    NSArray<NSString *> *src = @[
        @"/var/jb",
        @"/var/jb/usr/bin/ssh",
        @"/var/jb/usr/bin/ssh-keygen",
        @"/var/jb/usr/bin/cycript",
        @"/var/jb/bin/sh",
        @"/var/jb/bin/bash",
        @"/var/jb/Applications",
        @"/var/jb/Library/MobileSubstrate",
        @"/var/jb/Library/dpkg",
        @"/var/jb/Library/PreferenceBundles",
        @"/var/jb/Library/TweakInject",
        @"/var/jb/usr/lib/libhooker.dylib",
        @"/var/jb/usr/lib/libsubstrate.dylib",
        @"/var/jb/usr/lib/libsubstitute.dylib",
        @"/var/jb/usr/lib/ElleKit",
        @"/var/jb/usr/share/jailbreak",
        @"/private/preboot",
        @"/private/preboot/jb",
        @"/Applications/Cydia.app",
        @"/Applications/Sileo.app",
        @"/Applications/Sileo-Nightly.app",
        @"/Applications/Zebra.app",
        @"/Applications/Filza.app",
        @"/Library/MobileSubstrate",
        @"/Library/MobileSubstrate/MobileSubstrate.dylib",
        @"/usr/lib/libsubstrate.dylib",
        @"/usr/lib/libhooker.dylib",
        @"/usr/lib/libsubstitute.dylib",
        @"/usr/lib/libellekit.dylib",
        @"/usr/lib/TweakInject",
        @"/usr/bin/ssh",
        @"/usr/bin/cycript",
        @"/etc/apt",
        @"/var/lib/dpkg",
        @"/var/lib/cydia",
        @"/var/cache/apt",
        @"/var/log/syslog",
        @"/usr/sbin/frida-server",
        @"/usr/bin/frida-server",
        @"/tmp/frida-server",
    ];

    NSMutableArray<NSString *> *all = [NSMutableArray arrayWithCapacity:src.count * 2];
    for (NSString *p in src) {
        [all addObject:p];
        if ([p hasPrefix:@"/var/"]) {
            [all addObject:[@"/private" stringByAppendingString:p]];
        }
    }

    gBlockedCount = all.count;
    gBlocked = (VCBlockedItem *)calloc(gBlockedCount, sizeof(VCBlockedItem));
    if (!gBlocked) {
        gBlockedCount = 0;
        return;
    }

    for (size_t i = 0; i < gBlockedCount; i++) {
        const char *c = all[i].UTF8String;
        if (!c) c = "";
        size_t n = strlen(c);
        char *dup = (char *)malloc(n + 1);
        if (!dup) { gBlocked[i].s = NULL; gBlocked[i].len = 0; continue; }
        memcpy(dup, c, n + 1);
        gBlocked[i].s = dup;
        gBlocked[i].len = (uint32_t)n;
    }
}

/// 判断路径是否命中黑名单。纯 C，无堆分配。
/// 语义与旧实现对齐：
///   1) 完全相等命中
///   2) 以「黑名单 + /」开头命中（目录屏蔽）
///   3) /private 别名双向等值（已在表里预展开）
///   4) 兼容 /xxx/var/jb 这类"以黑名单结尾"的写法
static BOOL VCBlockedCString(const char *path)
{
    if (!path || path[0] != '/' || !gBlocked || gBlockedCount == 0) return NO;
    if (VCPathIsOursC(path)) return NO;

    size_t len = strlen(path);
    while (len > 1 && path[len - 1] == '/') len--;   // 去尾部斜杠

    // ---- 阶段 1：前缀匹配（绝大多数命中在这里结束） ----
    for (size_t i = 0; i < gBlockedCount; i++) {
        const char *b = gBlocked[i].s;
        uint32_t bl = gBlocked[i].len;
        if (!b || bl == 0 || bl > len) continue;
        if (path[0] != b[0]) continue;              // 首字节剪枝
        if (memcmp(path, b, bl) != 0) continue;
        if (bl == len) return YES;                  // 完全相等
        if (path[bl] == '/') return YES;            // 目录前缀
    }

    // ---- 阶段 2：后缀匹配（对齐旧逻辑的 hasSuffix 分支） ----
    // 旧逻辑只在 path 以 /private 开头时才走这里；这里对所有路径都做，
    // 语义是旧逻辑的超集，但只多出一批"确实指向越狱路径"的判断，不会误伤。
    for (size_t i = 0; i < gBlockedCount; i++) {
        const char *b = gBlocked[i].s;
        uint32_t bl = gBlocked[i].len;
        if (!b || bl == 0 || bl >= len) continue;
        if (path[len - bl - 1] != '/') continue;    // 必须是路径段边界
        if (memcmp(path + len - bl, b, bl) == 0) return YES;
    }

    return NO;
}

@implementation VCHide

+ (BOOL)isBlockedPath:(NSString *)path
{
    if (path.length == 0) return NO;
    const char *c = [path fileSystemRepresentation];
    return VCBlockedCString(c);
}

// ------------------------------------------------------------------ hook 实现

static BOOL (*orig_fileExistsAtPath)(id, SEL, NSString *);
static BOOL hook_fileExistsAtPath(id self, SEL _cmd, NSString *path)
{
    if (path && VCBlockedCString([path fileSystemRepresentation])) return NO;
    return orig_fileExistsAtPath(self, _cmd, path);
}

static BOOL (*orig_fileExistsAtPathIsDir)(id, SEL, NSString *, BOOL *);
static BOOL hook_fileExistsAtPathIsDir(id self, SEL _cmd, NSString *path, BOOL *isDir)
{
    if (path && VCBlockedCString([path fileSystemRepresentation])) {
        if (isDir) *isDir = NO;
        return NO;
    }
    return orig_fileExistsAtPathIsDir(self, _cmd, path, isDir);
}

static BOOL (*orig_isReadableFile)(id, SEL, NSString *);
static BOOL hook_isReadableFile(id self, SEL _cmd, NSString *path)
{
    if (path && VCBlockedCString([path fileSystemRepresentation])) return NO;
    return orig_isReadableFile(self, _cmd, path);
}

static BOOL (*orig_canOpenURL)(id, SEL, NSURL *);

// 每次调用都 [NSSet setWithObjects:] 会分配 7 个对象 —— 改成一次性常量。
static BOOL hook_canOpenURL(id self, SEL _cmd, NSURL *url)
{
    static NSSet<NSString *> *bad = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        bad = [NSSet setWithObjects:@"cydia", @"sileo", @"zbra",
                                     @"filza", @"undecimus", @"frida", nil];
    });

    NSString *scheme = url.scheme.lowercaseString;
    if (scheme && [bad containsObject:scheme]) return NO;
    return orig_canOpenURL(self, _cmd, url);
}

static int (*orig_access)(const char *, int);
static int hook_access(const char *path, int mode)
{
    if (VCBlockedCString(path)) {
        errno = ENOENT;
        return -1;
    }
    return orig_access(path, mode);
}

static int (*orig_stat)(const char *, struct stat *);
static int hook_stat(const char *path, struct stat *buf)
{
    if (VCBlockedCString(path)) {
        errno = ENOENT;
        return -1;
    }
    return orig_stat(path, buf);
}

static int (*orig_lstat)(const char *, struct stat *);
static int hook_lstat(const char *path, struct stat *buf)
{
    if (VCBlockedCString(path)) {
        errno = ENOENT;
        return -1;
    }
    return orig_lstat(path, buf);
}

static pid_t (*orig_fork)(void);
static pid_t hook_fork(void)
{
    // 沙盒内 App 本来就不该 fork 成功
    errno = EPERM;
    return -1;
}

// ==================================================================
#pragma mark - dyld 镜像隐藏
// ==================================================================
//
//  旧实现的问题：每次 _dyld_get_image_name(i) 都重新做一次
//  「第 i 个可见镜像 → 真实索引」的换算，每次换算都要遍历全部镜像
//  （iOS 上 500+ 个），每个镜像跑 8 个 strstr，并且 _dyld_image_count
//  自己也要遍历一遍。有些 SDK 会 for 循环直接拉全表，开销瞬间爆炸。
//
//  v2：把可见索引 → 真实索引的映射缓存成一张表，
//  只在镜像数量变化时重建（正常情况下进程内只建一次）。

static uint32_t *gImageMap       = NULL;   // visible index -> real index
static uint32_t  gImageMapCount  = 0;      // 可见镜像数
static uint32_t  gImageMapTotal  = 0;      // 建立映射时的真实镜像总数
static NSLock   *gImageMapLock   = nil;

static BOOL VCShouldHideImage(const char *name)
{
    if (!name) return NO;
    if (strstr(name, "VCam.dylib"))  return YES;
    if (strstr(name, "/var/jb/"))    return YES;
    if (strstr(name, "MobileSubstrate")) return YES;
    if (strstr(name, "TweakInject")) return YES;
    if (strstr(name, "ElleKit"))     return YES;
    if (strstr(name, "libhooker"))   return YES;
    if (strstr(name, "Substrate"))   return YES;
    if (strstr(name, "libsubstitute")) return YES;
    return NO;
}

static uint32_t (*orig_dyld_image_count)(void);
static const char *(*orig_dyld_get_image_name)(uint32_t);
static const struct mach_header *(*orig_dyld_get_image_header)(uint32_t);

/// 调用方必须持 gImageMapLock。
static void VCImageMapRebuildLocked(uint32_t total)
{
    free(gImageMap);
    gImageMap = NULL;
    gImageMapCount = 0;
    gImageMapTotal = total;
    if (total == 0) return;

    uint32_t *map = (uint32_t *)malloc(sizeof(uint32_t) * total);
    if (!map) return;

    uint32_t visible = 0;
    for (uint32_t i = 0; i < total; i++) {
        if (VCShouldHideImage(orig_dyld_get_image_name(i))) continue;
        map[visible++] = i;
    }
    gImageMap = map;
    gImageMapCount = visible;
}

/// 调用方必须持 gImageMapLock。
static void VCImageMapEnsureLocked(void)
{
    if (!orig_dyld_image_count || !orig_dyld_get_image_name) return;
    uint32_t total = orig_dyld_image_count();
    if (gImageMap && total == gImageMapTotal) return;
    VCImageMapRebuildLocked(total);
}

static uint32_t hook_dyld_image_count(void)
{
    // MSHookFunction 替换过程中若被内部逻辑反调，orig 可能尚未赋值
    if (!orig_dyld_image_count || !orig_dyld_get_image_name) return 0;

    uint32_t visible;
    [gImageMapLock lock];
    VCImageMapEnsureLocked();
    visible = gImageMapCount;
    [gImageMapLock unlock];
    return visible;
}

/// 可见索引 → 真实索引。命中缓存后是 O(1)。
static int VCRealIndexFor(uint32_t idx)
{
    if (!orig_dyld_image_count || !orig_dyld_get_image_name) return -1;

    int real = -1;
    [gImageMapLock lock];
    VCImageMapEnsureLocked();
    if (gImageMap && idx < gImageMapCount) {
        real = (int)gImageMap[idx];
    }
    [gImageMapLock unlock];
    return real;
}

static const char *hook_dyld_get_image_name(uint32_t idx)
{
    if (!orig_dyld_get_image_name) return NULL;
    int real = VCRealIndexFor(idx);
    if (real < 0) return NULL;
    return orig_dyld_get_image_name((uint32_t)real);
}

static const struct mach_header *hook_dyld_get_image_header(uint32_t idx)
{
    if (!orig_dyld_get_image_header) return NULL;
    int real = VCRealIndexFor(idx);
    if (real < 0) return NULL;
    return orig_dyld_get_image_header((uint32_t)real);
}

static int (*orig_dladdr)(const void *, Dl_info *);
static int hook_dladdr(const void *addr, Dl_info *info)
{
    if (!orig_dladdr) return 0;
    int r = orig_dladdr(addr, info);
    if (r != 0 && info && info->dli_fname && VCShouldHideImage(info->dli_fname)) {
        // 查询到的是我们的 dylib：伪装成系统库，抹掉符号信息
        info->dli_fname = "/usr/lib/libSystem.B.dylib";
        info->dli_sname = NULL;
        info->dli_saddr = NULL;
    }
    return r;
}

/// ObjC 运行时也有一条独立路径能列出镜像名
static const char **(*orig_objc_copyImageNames)(unsigned int *);
static const char **hook_objc_copyImageNames(unsigned int *outCount)
{
    if (!orig_objc_copyImageNames) return NULL;
    const char **names = orig_objc_copyImageNames(outCount);
    if (!names || !outCount) return names;

    unsigned int total = *outCount;
    unsigned int visible = 0;

    // 原地压缩：把要隐藏的条目往后挪，最后返回时截断计数
    const char **kept = (const char **)malloc(sizeof(char *) * (total + 1));
    if (!kept) return names;
    for (unsigned int i = 0; i < total; i++) {
        if (!VCShouldHideImage(names[i])) {
            kept[visible++] = names[i];
        }
    }
    kept[visible] = NULL;
    *outCount = visible;
    return kept;
}

// ------------------------------------------------------------------ 安装

+ (void)installHooks
{
    static dispatch_once_t once;
    dispatch_once(&once, ^{

        // 黑名单表与锁必须先就绪，后面所有 hook 都依赖它
        VCBlockedBuild();
        if (!gImageMapLock) gImageMapLock = [[NSLock alloc] init];

        MSHookMessageEx([NSFileManager class],
                        @selector(fileExistsAtPath:),
                        (IMP)&hook_fileExistsAtPath,
                        (IMP *)&orig_fileExistsAtPath);

        MSHookMessageEx([NSFileManager class],
                        @selector(fileExistsAtPath:isDirectory:),
                        (IMP)&hook_fileExistsAtPathIsDir,
                        (IMP *)&orig_fileExistsAtPathIsDir);

        MSHookMessageEx([NSFileManager class],
                        @selector(isReadableFileAtPath:),
                        (IMP)&hook_isReadableFile,
                        (IMP *)&orig_isReadableFile);

        MSHookMessageEx([UIApplication class],
                        @selector(canOpenURL:),
                        (IMP)&hook_canOpenURL,
                        (IMP *)&orig_canOpenURL);

        // ---- C 函数：按符号名重绑定 ----
        // 不再用 MSHookFunction —— TrollStore 环境没有 substrate。
        // stat/lstat 在 64 位 iOS 上导出的名字带 $INODE64 后缀，两个都挂上。
        VCSymbolHook symHooks[] = {
            { "access",                 (void *)hook_access,                 (void **)&orig_access },
            { "stat",                   (void *)hook_stat,                   (void **)&orig_stat },
            { "stat$INODE64",           (void *)hook_stat,                   (void **)&orig_stat },
            { "lstat",                  (void *)hook_lstat,                  (void **)&orig_lstat },
            { "lstat$INODE64",          (void *)hook_lstat,                  (void **)&orig_lstat },
            { "fork",                   (void *)hook_fork,                   (void **)&orig_fork },

            // dyld 镜像隐藏
            { "_dyld_image_count",      (void *)hook_dyld_image_count,       (void **)&orig_dyld_image_count },
            { "_dyld_get_image_name",   (void *)hook_dyld_get_image_name,    (void **)&orig_dyld_get_image_name },
            { "_dyld_get_image_header", (void *)hook_dyld_get_image_header,  (void **)&orig_dyld_get_image_header },
            { "dladdr",                 (void *)hook_dladdr,                 (void **)&orig_dladdr },
            { "objc_copyImageNames",    (void *)hook_objc_copyImageNames,    (void **)&orig_objc_copyImageNames },
            { NULL, NULL, NULL }
        };
        VCHookSymbols(symHooks);

        VCLog(@"越狱痕迹隐藏已安装：%zu 条黑名单（纯 C 匹配），dyld 映射已缓存",
              gBlockedCount);
    });
}

@end
