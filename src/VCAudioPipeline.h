//
//  VCAudioPipeline.h
//
//  音频生产-消费管道。
//
//  背景：
//    之前所有音频处理都挤在 AudioUnitRender 的实时线程里同步做 ——
//    加锁、AVAssetReader 解码、AudioConverter 重采样、时间同步判断、
//    必要时还要重建 reader（阻塞 140ms）。
//    只要任何一步慢，就会掉帧、断音、卡顿，而且一旦时间基准算错
//    就会陷入「永远 seek」的死循环，直接没声音。
//
//  现在的结构：
//    后台线程（生产者）  持续解码 → 转换 → 写入环形缓冲
//    实时线程（消费者）  AudioUnitRender 里只做一次 memcpy
//
//    环形缓冲里存的是**最终格式**（int16 / 系统声道数 / 系统采样率），
//    实时线程拿到的就是能直接拷进 ioData 的字节，不碰任何重型操作。
//
//  时间同步、seek 校正、carry 累积全部在后台完成，慢一点也没关系 ——
//  只要环形缓冲里有存货，实时线程就不会察觉到。
//

#ifndef VCAudioPipeline_h
#define VCAudioPipeline_h

#import <Foundation/Foundation.h>
#import <AudioToolbox/AudioToolbox.h>

NS_ASSUME_NONNULL_BEGIN

@interface VCAudioPipeline : NSObject

+ (instancetype)shared;

/// 目标格式（由 hook 从 AudioUnitGetProperty 拿到后设置）。
/// 设置后会自动重建转换器和环形缓冲；格式没变则什么都不做。
- (void)setTargetFormat:(AudioStreamBasicDescription)format;

/// 启动/停止后台生产线程。素材切换、注入开关都会调用。
- (void)start;
- (void)stop;

/// 实时线程调用：把音频写进 ioData。
/// 内部只做一次 memcpy，从环形缓冲取数据，绝不阻塞。
/// 缓冲里没数据时重复上一次的内容，不会写静音造成突降。
- (void)fillIOData:(AudioBufferList *)ioData frames:(UInt32)frames;

/// 诊断用的计数器
@property (nonatomic, readonly) uint64_t producedFrames;   // 后台产出的帧数
@property (nonatomic, readonly) uint64_t consumedFrames;   // 实时线程取走的帧数
@property (nonatomic, readonly) uint64_t underrunCount;    // 缓冲空了的次数
@property (nonatomic, readonly) int      seekCount;        // 后台 seek 校正次数
@property (nonatomic, readonly) BOOL     isRunning;
@property (nonatomic, readonly) size_t   bufferedFrames;   // 当前缓冲里的帧数

/// 当前音画偏差（秒）。正值 = 视频比音频快（音频落后）。
/// 5 小时长跑时随时读它，判断闭环校正有没有把偏差钳住。
@property (nonatomic, readonly) double   currentDrift;

/// 上次欠载发生在管道启动后第几秒（用于定位断点位置）
@property (nonatomic, readonly) double   lastUnderrunAt;
/// 音频已解码到素材的哪个时间（秒）
@property (nonatomic, readonly) double   decodedMaterialSeconds;
/// 视频当前解码到素材的哪个时间（秒）—— 对齐基准
@property (nonatomic, readonly) double   videoSourceSeconds;
/// 累计微调次数。稳定后应停止增长。
@property (nonatomic, readonly) uint64_t tuneBlocks;
/// 单次生产最长耗时（毫秒）
@property (nonatomic, readonly) double   maxProduceMs;

// 静音来源细分：报告里「欠载次数」只统计其中一种，
// 这两项才是「有静音但欠载不涨」的原因。
@property (nonatomic, readonly) uint64_t silentNoRing;  // 缓冲未就绪的帧数
@property (nonatomic, readonly) uint64_t silentShort;   // 缓冲不足的帧数
@property (nonatomic, readonly) uint64_t zeroBytes;     // writable=0 的次数
@property (nonatomic, readonly) uint64_t totalFilled;   // 实际填充的帧数
/// 产出的数据里出现「整段恒定值」的次数。>0 说明上游还有补齐残留。
@property (nonatomic, readonly) uint64_t dcSegments;

@end

NS_ASSUME_NONNULL_END

#endif /* VCAudioPipeline_h */
