//
//  VCLog.m
//  把日志落到沙盒 Documents/VCam/diag.log。
//
//  用途：iOS 15 上 syslog_relay / os_trace_relay 都抓不到 NSLog，
//  现场调试等于闭着眼睛。写文件之后电脑端可以用 usbmuxd 的
//  house_arrest 服务直接读出来（tools/ios_pull_log.py）。

#import "VCLog.h"

#import <pthread.h>

static const NSUInteger kMaxLogBytes = 256 * 1024;   // 256 KB 滚动

NSString *VCLogFilePath(void)
{
    NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory,
                                                         NSUserDomainMask, YES).firstObject;
    if (docs.length == 0) return nil;

    NSString *dir = [docs stringByAppendingPathComponent:@"VCam"];
    NSFileManager *fm = [NSFileManager defaultManager];
    if (![fm fileExistsAtPath:dir]) {
        [fm createDirectoryAtPath:dir
       withIntermediateDirectories:YES
                        attributes:nil
                             error:NULL];
    }
    return [dir stringByAppendingPathComponent:@"diag.log"];
}

void VCLogReset(void)
{
    NSString *path = VCLogFilePath();
    if (path.length == 0) return;
    [[NSFileManager defaultManager] removeItemAtPath:path error:NULL];
}

void VCLogToFile(NSString *msg)
{
    if (msg.length == 0) return;

    static dispatch_queue_t q = NULL;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        q = dispatch_queue_create("com.yg.vcam.diaglog", DISPATCH_QUEUE_SERIAL);
        dispatch_set_target_queue(q, dispatch_get_global_queue(QOS_CLASS_UTILITY, 0));
    });

    NSString *line = [NSString stringWithFormat:@"%.3f %@\n",
                      [NSDate date].timeIntervalSince1970, msg];

    dispatch_async(q, ^{
        @autoreleasepool {
            NSString *path = VCLogFilePath();
            if (path.length == 0) return;

            NSFileManager *fm = [NSFileManager defaultManager];
            NSData *data = [line dataUsingEncoding:NSUTF8StringEncoding];
            if (!data) return;

            if (![fm fileExistsAtPath:path]) {
                [data writeToFile:path atomically:YES];
                return;
            }

            NSDictionary *attrs = [fm attributesOfItemAtPath:path error:NULL];
            unsigned long long size = [attrs fileSize];
            if (size > kMaxLogBytes) {
                // 滚动：留最后 1/4，前面丢掉
                NSData *old = [NSData dataWithContentsOfFile:path];
                if (old.length > kMaxLogBytes / 4) {
                    NSData *tail = [old subdataWithRange:
                                    NSMakeRange(old.length - kMaxLogBytes / 4,
                                                kMaxLogBytes / 4)];
                    [tail writeToFile:path atomically:YES];
                } else {
                    [fm removeItemAtPath:path error:NULL];
                }
                return;
            }

            NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:path];
            if (!fh) {
                [data writeToFile:path atomically:YES];
                return;
            }
            @try {
                [fh seekToEndOfFile];
                [fh writeData:data];
            } @catch (NSException *e) {
                // 写失败就算了，日志不能影响主流程
            } @finally {
                [fh closeFile];
            }
        }
    });
}
