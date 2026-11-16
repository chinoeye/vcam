//
//  VCCaptureProxy.h
//  delegate 透明转发代理。
//
//  为什么必须用 NSProxy 而不是替换掉 delegate：
//  App 的 delegate 往往还实现了可选方法（didDropSampleBuffer、didStartRecording...），
//  直接换掉会让这些回调消失，轻则功能异常，重则崩溃。
//  这里只定向拦截「收到样本」这一个方法，其余全部原样转发。
//

#ifndef VCCaptureProxy_h
#define VCCaptureProxy_h

#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, VCProxyKind) {
    VCProxyKindVideo = 0,
    VCProxyKindAudio = 1,
};

@interface VCCaptureProxy : NSProxy

/// 创建一个转发代理。内部会强持有，直到 releaseProxyFor: 被调用。
+ (instancetype)proxyForTarget:(id)target
                          kind:(VCProxyKind)kind
                        output:(id)output;

/// 释放某个 output 对应的代理（App 换 delegate / 销毁 output 时调用）
+ (void)releaseProxyForOutput:(id)output;

/// 全部释放（App 退出 / 关闭注入时）
+ (void)releaseAll;

/// 当前是否已为某个 output 建立代理
+ (BOOL)hasProxyForOutput:(id)output;

@end

NS_ASSUME_NONNULL_END

#endif /* VCCaptureProxy_h */
