//
//  VCOverlay.h
//  预览层覆盖 + 悬浮控制面板。
//
//  AVCaptureVideoPreviewLayer 直接从 connection 取 GPU 画面，不经过 delegate，
//  所以只替换 data output 是不够的 —— 预览窗口仍然会显示真摄像头。
//  这里的做法是在预览层内部叠加一个 AVSampleBufferDisplayLayer，
//  用同一份 OBS 帧渲染，把它完全盖住。
//
//  悬浮面板是独立 UIWindow，不在采集链路里，永远不会出现在直播画面上。
//

#ifndef VCOverlay_h
#define VCOverlay_h

#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface VCOverlay : NSObject

+ (instancetype)shared;

/// 给预览层挂上覆盖层。重复调用安全。
+ (void)attachToPreviewLayer:(AVCaptureVideoPreviewLayer *)layer;

/// 把一帧推给所有已挂载的覆盖层
+ (void)pushVideoSampleBuffer:(CMSampleBufferRef)sampleBuffer;

/// 移除所有覆盖层（关闭注入时）
+ (void)detachAll;

/// 显示悬浮控制面板
+ (void)installPanelIfNeeded;

@end

NS_ASSUME_NONNULL_END

#endif /* VCOverlay_h */
