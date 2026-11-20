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

/// 写入时对亮度的额外增益（1.0 = 不变）。
///
/// 由「真实摄像头参与」那条链路每帧算出来：真实画面的平均亮度相对启动时
/// 偏移多少，素材就跟着亮/暗多少 —— 屋里开灯、拉窗帘，直播画面会跟着变。
/// 这是预录素材做不出来的东西。
@property (nonatomic, assign) double lumaGain;

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

/// 把 src 的像素画进 dst（尺寸或格式不同会自动缩放/转换）。
///
/// 这是「原地改写」路线的核心：
/// 不去伪造 CMSampleBuffer，而是保留系统给的那个 buffer，
/// 只把它里面的像素内容换掉。这样 PTS、attachments、format description
/// 全是系统原生的 —— 之前伪造 buffer 导致 App 侧 CFRelease(NULL) 的坑全绕开。
- (BOOL)copyPixelBuffer:(CVPixelBufferRef)src into:(CVPixelBufferRef)dst;

/// 当前帧的 JPEG 快照，供 AVCapturePhoto 出口使用
- (void)updateJPEGFromPixelBuffer:(CVPixelBufferRef)pixelBuffer;
- (nullable NSData *)currentJPEG;

/// 重置时间戳状态（切源 / 重连时必须调用，否则时间戳会跳变）
- (void)resetTimeline;

@end

NS_ASSUME_NONNULL_END

#endif /* VCSampleBufferFactory_h */
