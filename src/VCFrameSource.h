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

/// 只解码并返回像素缓冲，不造 CMSampleBuffer、不改时间戳。
///
/// 供「原地改写系统 buffer」路线使用：调用方拿到 pixelBuffer 后，
/// 用 VCSampleBufferFactory 的 copyPixelBuffer:into: 把内容画进
/// 系统摄像头给的那个 buffer 里，buffer 本身原样转发给 App。
/// 调用方负责 CVPixelBufferRelease。
- (nullable CVPixelBufferRef)copyNextPixelBuffer CF_RETURNS_RETAINED;

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

/// 当前视频帧在源文件里的时间位置（秒）。
/// 音频侧靠它对表，保证音画不会各跑各的。
@property (nonatomic, readonly) NSTimeInterval currentVideoSourceTime;

/// 音频实际已播放到的位置（秒），由外部每写完一块就更新。
///
/// 为什么需要它：音频输出的是 44100Hz，而内部按「已读样本数 / 48000」
/// 推算时间 —— 两者相差 8.8%，偏差累积到 VC_AV_MAX_DRIFT 就 return nil，
/// 上层补静音，听感是「每隔几秒断一下」。
/// 用真实的输出帧数换算时间，才能和系统播放进度严格一致。
@property (nonatomic, assign) double audioPlaybackSeconds;

/// 音频 seek 校正的累计次数（诊断用，定义在 .m 里）。
extern int g_vcSeekCount;

/// 把音频轨道跳到视频当前所在的位置。
/// 从「真麦」切到「素材」时必须调用，否则声音会从很久以前的地方接上。
- (void)seekAudioToVideoTime;

@end

NS_ASSUME_NONNULL_END

#endif /* VCFrameSource_h */
