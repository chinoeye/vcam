//
//  VCHide.m
//

#import "VCHide.h"
#import "VCamConfig.h"
#import "VCLog.h"

#import <substrate.h>
#import <UIKit/UIKit.h>
#import <sys/stat.h>
#import <unistd.h>
#import <errno.h>
#import <string.h>

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

        MSHookFunction((void *)access, (void *)hook_access, (void **)&orig_access);
        MSHookFunction((void *)stat,   (void *)hook_stat,   (void **)&orig_stat);
        MSHookFunction((void *)lstat,  (void *)hook_lstat,  (void **)&orig_lstat);
        MSHookFunction((void *)fork,   (void *)hook_fork,   (void **)&orig_fork);

        VCLog(@"越狱痕迹隐藏已安装");
    });
}

@end
