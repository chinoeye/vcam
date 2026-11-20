//
//  VCAudioSource.h
//
//  独立的音频素材解码器。
//
//  【为什么单独做一个模块】
//    之前音频解码寄生在 VCFrameSource 里，和视频解码共用一把 NSLock。
//    视频解码持锁期间（seek、重建 reader、慢帧），音频生产线程就被挡住，
//    生产跟不上消费 → 环形缓冲被取空 → 声音断续。
//
//    实测数据：hook 填充 713 次录 15 秒，但欠载 103 次（14.5%）。
//    视频那条链路本身没问题，是被共用锁牵连的。
//
//    现在音频有自己的 AVAssetReader、自己的串行队列、自己的格式描述，
//    和视频零共享。视频怎么慢都影响不到音频供给侧。
//
//  【循环策略】
//    音频读到素材末尾不自己重启，等 VCFrameSource 视频回绕时通过
//    通知一起重置 —— 各回各的会立刻错开一整个素材长度。
//    同时内部保留一个兜底：连续多次拿不到数据且队列已 completed 时
//    自行回到开头，避免因为通知丢失而永久静音。
//

#ifndef VCAudioSource_h
#define VCAudioSource_h

#import <Foundation/Foundation.h>
#import <CoreMedia/CoreMedia.h>
#import <AVFoundation/AVFoundation.h>

NS_ASSUME_NONNULL_BEGIN

/// 视频回绕时发出，音频监听后一起回到素材开头
extern NSString *const VCAudioSourceShouldResetNotification;

@interface VCAudioSource : NSObject

+ (instancetype)shared;

/// 加载素材的音频轨。重复调用同一个 URL 会直接返回 YES。
- (BOOL)loadURL:(NSURL *)url error:(NSError **)error;

/// 回到素材开头（视频回绕时调用）
- (void)reset;

/// 跳到素材内的指定秒（用于音画对齐校正）
- (void)seekToTime:(double)seconds;

/// 音频相对视频的整体偏移（秒），seekToTime 内部会自动加上。
///
///  直播录播素材常常自带音画错位（两条流独立录制、合成时差几十到几百毫秒）。
///  实测这段素材「声音比画面快 0.5 秒」—— 是素材自己的问题，原样注入就会
///  把这个错位一起带过去。
///
///  设 +0.5 表示音频读取位置整体往后挪 0.5 秒（读更晚的内容），听感上声音
///  就往后推了 0.5 秒，与画面对齐。
@property (nonatomic, assign) double offsetSeconds;

/// 取下一块 PCM（float32 / 素材原始声道 / 素材原始采样率）。
/// 没有数据时返回 nil。内部串行，可多线程调用。
- (nullable NSData *)nextPCMWithFrames:(CMItemCount *)frames
                                  asbd:(AudioStreamBasicDescription *)asbd;

@property (nonatomic, readonly) BOOL     ready;
@property (nonatomic, readonly) double   sampleRate;
@property (nonatomic, readonly) uint32_t channels;
@property (nonatomic, readonly) uint64_t framesDelivered;   // 累计交付帧数
@property (nonatomic, readonly) uint64_t underrunCount;     // 返回 nil 的次数
@property (nonatomic, readonly, nullable) NSURL *currentURL;

@end

NS_ASSUME_NONNULL_END

#endif /* VCAudioSource_h */
