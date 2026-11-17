//
//  VCHide.h
//  越狱环境痕迹抹除。
//
//  只在白名单 App 内生效（tweak filter plist 已经限定注入范围）。
//  策略是精确黑名单而不是整目录屏蔽 —— 因为素材本身就放在 /var/jb 下，
//  一刀切会把自家资源也挡掉。
//

#ifndef VCHide_h
#define VCHide_h

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface VCHide : NSObject

/// 安装所有隐藏 hook。只应在目标 App 的进程里调用一次。
+ (void)installHooks;

/// 判断某个路径是否应该"看不见"（供内部和其他 hook 复用）
+ (BOOL)isBlockedPath:(NSString *)path;

@end

NS_ASSUME_NONNULL_END

#endif /* VCHide_h */
