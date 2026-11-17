//
//  VCLiveSource.h
//  局域网实时帧源（备源）。
//
//  协议与 PC 端 obs_live_push.py 严格对应：
//    头部 26 字节，小端：
//      0..3    magic  "VCFM"
//      4       ver    1
//      5       type   1=config 2=video 3=heartbeat 4=control
//      6..13   flags  (bit0 = 关键帧)
//      14..21  pts_ms
//      22..25  payload 长度
//

#ifndef VCLiveSource_h
#define VCLiveSource_h

#import <Foundation/Foundation.h>
#import <CoreMedia/CoreMedia.h>
#import <AVFoundation/AVFoundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface VCLiveSource : NSObject

+ (instancetype)shared;

@property (nonatomic, readonly) BOOL connected;
@property (nonatomic, readonly) NSString *statusText;
@property (nonatomic, readonly) NSUInteger receivedFrames;

- (BOOL)connectToHost:(NSString *)host port:(uint16_t)port;
- (void)disconnect;

/// 取当前最新一帧（覆盖式，旧帧直接丢弃）。
/// 调用方负责 CFRelease。
- (nullable CMSampleBufferRef)copyNextVideoSampleBuffer CF_RETURNS_RETAINED;

@end

NS_ASSUME_NONNULL_END

#endif /* VCLiveSource_h */
