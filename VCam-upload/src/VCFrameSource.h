//
//  VCFrameSource.h
//  本地 MP4 循环源。
//
//  设计取舍：不用定时器推帧，而是由 App 的采集回调驱动「拉」。
//  好处是帧率天然跟随 App 请求（App 要 15fps 我们就给 15fps）、
//  切后台 App 不回调时我们也自动停，不烧电、不积压。
//

#ifndef VCFrameSource_h
#define VCFrameSource_h

#import <Foundation/Foundation.h>
#import <CoreMedia/CoreMedia.h>
#import <AVFoundation/AVFoundation.h>

NS_ASSUME_NONNULL_BEGIN

@class VCFrameSource;

@protocol VCFrameSourceDelegate <NSObject>
- (void)frameSource:(VCFrameSource *)src didChangeStatus:(NSString *)status;
@end

@interface VCFrameSource : NSObject

+ (instancetype)shared;

@property (nonatomic, weak) id<VCFrameSourceDelegate> delegate;
@property (nonatomic, strong, nullable) NSURL *assetURL;
@property (nonatomic, assign) OSType pixelFormat;
@property (nonatomic, assign) double fps;

/// 取下一帧视频。调用方负责 CFRelease。没有可用帧时返回 NULL。
/// 内部线程安全，可以在任意线程调用。
- (nullable CMSampleBufferRef)copyNextVideoSampleBuffer CF_RETURNS_RETAINED;

/// 取下一块音频 PCM（float32 / 48k / 单声道）。
/// 返回 nil 表示暂无可读数据。
- (nullable NSData *)copyNextAudioPCMWithFrameCount:(CMItemCount *)frameCountOut
                                               asbd:(AudioStreamBasicDescription *)asbdOut;

/// 切换素材 / 重启解码
- (BOOL)reloadWithURL:(NSURL *)url error:(NSError **)error;

/// 回到文件开头（切换源、恢复播放时用）
- (void)rewind;

/// 释放解码器（App 退到后台或关闭注入时调用）
- (void)teardown;

@property (nonatomic, readonly) BOOL isReady;
@property (nonatomic, readonly) NSUInteger frameCount;
@property (nonatomic, readonly) CGFloat sourceAspectRatio;

@end

NS_ASSUME_NONNULL_END

#endif /* VCFrameSource_h */
