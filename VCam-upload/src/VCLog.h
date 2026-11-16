//
//  VCLog.h
//  统一日志出口。Release 下走 os_log，Debug 下同时打控制台。
//

#ifndef VCLog_h
#define VCLog_h

#import <Foundation/Foundation.h>

#define VCLog(fmt, ...) do { \
    NSLog(@"[VCam] " fmt, ##__VA_ARGS__); \
} while (0)

#define VCLogVerbose(fmt, ...) do { \
    if ([[NSUserDefaults standardUserDefaults] boolForKey:@"com.yg.vcam.verbose"]) { \
        NSLog(@"[VCam] " fmt, ##__VA_ARGS__); \
    } \
} while (0)

#endif /* VCLog_h */
