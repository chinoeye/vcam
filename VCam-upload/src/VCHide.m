//
//  VCHide.m
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

// ------------------------------------------------------------------ 黑名单

static NSArray<NSString *> *VCBlockedPaths(void)
{
    static NSArray<NSString *> *paths = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        paths = @[
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
    });
    return paths;
}

/// 自家路径白名单：素材、配置都在这下面，必须对 App 可见
static BOOL VCPathIsOurs(NSString *path)
{
    return ([path rangeOfString:@"VCam" options:NSCaseInsensitiveSearch].location != NSNotFound);
}

static NSString *VCNormalize(NSString *path)
{
    if (!path) return @"";
    // 去掉尾部斜杠，统一小写比较
    while (path.length > 1 && [path hasSuffix:@"/"]) {
        path = [path substringToIndex:path.length - 1];
    }
    return path;
}

@implementation VCHide

+ (BOOL)isBlockedPath:(NSString *)path
{
    if (path.length == 0) return NO;
    if (VCPathIsOurs(path)) return NO;

    NSString *norm = VCNormalize(path);

    for (NSString *blocked in VCBlockedPaths()) {
        NSString *bn = VCNormalize(blocked);
        if ([norm isEqualToString:bn]) return YES;
        if ([norm hasPrefix:[bn stringByAppendingString:@"/"]]) return YES;
        // /private/var 与 /var 是同一位置，两种写法都要挡
        if ([bn hasPrefix:@"/private"]) {
            NSString *alt = [bn substringFromIndex:8];
            if ([norm isEqualToString:alt]) return YES;
            if ([norm hasPrefix:[alt stringByAppendingString:@"/"]]) return YES;
        }
        if ([norm hasPrefix:@"/private"] && [norm hasSuffix:bn]) return YES;
    }
    return NO;
}

// ------------------------------------------------------------------ hook 实现

static BOOL (*orig_fileExistsAtPath)(id, SEL, NSString *);
static BOOL hook_fileExistsAtPath(id self, SEL _cmd, NSString *path)
{
    if ([VCHide isBlockedPath:path]) return NO;
    return orig_fileExistsAtPath(self, _cmd, path);
}

static BOOL (*orig_fileExistsAtPathIsDir)(id, SEL, NSString *, BOOL *);
static BOOL hook_fileExistsAtPathIsDir(id self, SEL _cmd, NSString *path, BOOL *isDir)
{
    if ([VCHide isBlockedPath:path]) {
        if (isDir) *isDir = NO;
        return NO;
    }
    return orig_fileExistsAtPathIsDir(self, _cmd, path, isDir);
}

static BOOL (*orig_isReadableFile)(id, SEL, NSString *);
static BOOL hook_isReadableFile(id self, SEL _cmd, NSString *path)
{
    if ([VCHide isBlockedPath:path]) return NO;
    return orig_isReadableFile(self, _cmd, path);
}

static BOOL (*orig_canOpenURL)(id, SEL, NSURL *);
static BOOL hook_canOpenURL(id self, SEL _cmd, NSURL *url)
{
    NSString *scheme = url.scheme.lowercaseString;
    NSSet *bad = [NSSet setWithObjects:@"cydia", @"sileo", @"zbra",
                  @"filza", @"undecimus", @"frida", nil];
    if (scheme && [bad containsObject:scheme]) return NO;
    return orig_canOpenURL(self, _cmd, url);
}

static int (*orig_access)(const char *, int);
static int hook_access(const char *path, int mode)
{
    if (path) {
        NSString *p = [NSString stringWithUTF8String:path];
        if ([VCHide isBlockedPath:p]) {
            errno = ENOENT;
            return -1;
        }
    }
    return orig_access(path, mode);
}

static int (*orig_stat)(const char *, struct stat *);
static int hook_stat(const char *path, struct stat *buf)
{
    if (path) {
        NSString *p = [NSString stringWithUTF8String:path];
        if ([VCHide isBlockedPath:p]) {
            errno = ENOENT;
            return -1;
        }
    }
    return orig_stat(path, buf);
}

static int (*orig_lstat)(const char *, struct stat *);
static int hook_lstat(const char *path, struct stat *buf)
{
    if (path) {
        NSString *p = [NSString stringWithUTF8String:path];
        if ([VCHide isBlockedPath:p]) {
            errno = ENOENT;
            return -1;
        }
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
//  这是最容易被抓的一条：
//  任何 App 都能用 _dyld_image_count() 遍历自己加载的所有动态库，
//  一眼就能看到 /var/jb/.../VCam.dylib。
//  标准做法是 hook 这几个函数，把越狱相关条目从列表里过滤掉。
//
//  注意：_dyld_get_image_name 和 _dyld_get_image_header 的索引必须
//  经过同一套映射，否则调用方拿到的名字和 header 会对不上。

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

static uint32_t hook_dyld_image_count(void)
{
    // MSHookFunction 替换过程中若被内部逻辑反调，orig 可能尚未赋值
    if (!orig_dyld_image_count || !orig_dyld_get_image_name) return 0;

    uint32_t total = orig_dyld_image_count();
    uint32_t visible = 0;
    for (uint32_t i = 0; i < total; i++) {
        const char *n = orig_dyld_get_image_name(i);
        if (!VCShouldHideImage(n)) visible++;
    }
    return visible;
}

/// 把"调用方看到的第 idx 个可见镜像"换算成"真实索引"，找不到返回 -1
static int VCRealIndexFor(uint32_t idx)
{
    if (!orig_dyld_image_count || !orig_dyld_get_image_name) return -1;

    uint32_t total = orig_dyld_image_count();
    uint32_t visible = 0;
    for (uint32_t i = 0; i < total; i++) {
        const char *n = orig_dyld_get_image_name(i);
        if (VCShouldHideImage(n)) continue;
        if (visible == idx) return (int)i;
        visible++;
    }
    return -1;
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

        VCLog(@"越狱痕迹隐藏已安装（路径 + dyld 镜像，无 substrate 依赖）");
    });
}

@end
