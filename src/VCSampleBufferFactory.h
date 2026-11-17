//
//  VCSampleBufferFactory.h
//  把解码出来的 CVPixelBuffer / PCM 重新封装成「看起来像真摄像头」的 CMSampleBuffer。
//
//  这是整套方案的技术核心：AVCaptureVideoDataOutput 交给 App 的就是 CMSampleBuffer，
//  只要我们能造出结构完全一致的 buffer，App 无法分辨来源。
//

#ifndef VCSampleBufferFactory_h
#define VCSampleBufferFactory_h

#import <Foundation/Foundation.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <AVFoundation/AVFoundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface VCSampleBufferFactory : NSObject

+ (instancetype)shared;

/// App 通过 setVideoSettings: 请求的像素格式（默认 420v，与真机一致）
@property (nonatomic, assign) OSType requestedVideoFormat;
/// 目标帧率，用于填 duration
@property (nonatomic, assign) double fps;

/// 视频：把 pixelBuffer 包成 CMSampleBuffer。
/// 返回的 buffer 由调用方负责 CFRelease。
/// 时间戳带人工抖动 + 强制单调递增，模拟真实传感器的调度浮动。
- (nullable CMSampleBufferRef)createVideoSampleBufferFrom:(CVPixelBufferRef)pixelBuffer
                                      presentationOverride:(nullable NSValue *)ptsOrNil
                                              CF_RETURNS_RETAINED;

/// 视频：从解码器直接得到的 CMSampleBuffer 重新打时间戳后复制。
/// 不复制像素数据，只重建 buffer 头，开销极小。
- (nullable CMSampleBufferRef)retimeSampleBuffer:(CMSampleBufferRef)src
                                          CF_RETURNS_RETAINED;

/// 音频：把 PCM 数据包成 CMSampleBuffer。
- (nullable CMSampleBufferRef)createAudioSampleBufferWithData:(NSData *)pcm
                                                  asbd:(const AudioStreamBasicDescription *)asbd
                                          frameCount:(CMItemCount)frames
                                              CF_RETURNS_RETAINED;

/// 像素格式转换（App 请求的格式与解码输出不一致时兜底）
- (nullable CVPixelBufferRef)transferPixelBuffer:(CVPixelBufferRef)src
                                        toFormat:(OSType)format
                                        CF_RETURNS_RETAINED;

/// 当前帧的 JPEG 快照，供 AVCapturePhoto 出口使用
- (void)updateJPEGFromPixelBuffer:(CVPixelBufferRef)pixelBuffer;
- (nullable NSData *)currentJPEG;

/// 重置时间戳状态（切源 / 重连时必须调用，否则时间戳会跳变）
- (void)resetTimeline;

@end

NS_ASSUME_NONNULL_END

#endif /* VCSampleBufferFactory_h */
