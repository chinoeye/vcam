//
//  VCLog.h
//  统一日志出口。
//
//  除了 NSLog，还会追加写一份到沙盒的 Documents/VCam/diag.log。
//
//  为什么要写文件：
//    iOS 15 的 syslog_relay / os_trace_relay 协议都拿不到 NSLog 输出，
//    而现场调试时「看不见日志」等于闭着眼睛改代码。
//    写到 Documents 之后，电脑端可以通过 usbmuxd 的 house_arrest 服务
//    把文件直接读出来（tools/ios_pull_log.py）。
//

#ifndef VCLog_h
#define VCLog_h

#import <Foundation/Foundation.h>

#ifdef __cplusplus
extern "C" {
#endif

/// 追加一行到沙盒日志文件。异步、串行队列，不会阻塞调用线程。
/// 超过上限会自动滚动（把旧内容丢掉重来），避免无限增长。
void VCLogToFile(NSString *msg);

/// 日志文件在沙盒里的绝对路径（懒创建目录）。
NSString *VCLogFilePath(void);

/// 清空日志文件（测试前调用，保证日志干净）。
void VCLogReset(void);

#ifdef __cplusplus
}
#endif

#define VCLog(fmt, ...) do { \
    NSString *_vclog_msg = [NSString stringWithFormat:@"[VCam] " fmt, ##__VA_ARGS__]; \
    NSLog(@"%@", _vclog_msg); \
    VCLogToFile(_vclog_msg); \
} while (0)

#define VCLogVerbose(fmt, ...) do { \
    if ([[NSUserDefaults standardUserDefaults] boolForKey:@"com.yg.vcam.verbose"]) { \
        VCLog(fmt, ##__VA_ARGS__); \
    } \
} while (0)

#endif /* VCLog_h */
