//
//  VCLiveSource.m
//

#import "VCLiveSource.h"
#import "VCSampleBufferFactory.h"
#import "VCamConfig.h"
#import "VCLog.h"

#import <VideoToolbox/VideoToolbox.h>
#import <sys/socket.h>
#import <netinet/in.h>
#import <netinet/tcp.h>
#import <arpa/inet.h>
#import <netdb.h>
#import <unistd.h>
#import <errno.h>
#import <stdio.h>
#import <string.h>

static const uint8_t kMagic[4] = {'V', 'C', 'F', 'M'};
static const NSUInteger kHeaderSize = 26;

static const uint8_t kTypeConfig    = 1;
static const uint8_t kTypeVideo     = 2;
static const uint8_t kTypeHeartbeat = 3;
static const uint8_t kTypeControl   = 4;

// ------------------------------------------------------------------ Annex-B 工具

/// 把 Annex-B 字节流按起始码切成 NAL 列表
static NSArray<NSData *> *VCSplitAnnexB(NSData *data)
{
    NSMutableArray<NSData *> *out = [NSMutableArray array];
    const uint8_t *p = data.bytes;
    NSUInteger len = data.length;
    if (len < 4) return out;

    NSMutableArray<NSNumber *> *starts = [NSMutableArray array];
    NSUInteger i = 0;
    while (i + 3 < len) {
        if (p[i] == 0 && p[i + 1] == 0 && p[i + 2] == 1) {
            [starts addObject:@(i + 3)];
            i += 3;
        } else {
            i++;
        }
    }
    for (NSUInteger k = 0; k < starts.count; k++) {
        NSUInteger begin = starts[k].unsignedIntegerValue;
        NSUInteger end = (k + 1 < starts.count)
            ? starts[k + 1].unsignedIntegerValue - 3
            : len;
        if (end > begin) {
            [out addObject:[data subdataWithRange:NSMakeRange(begin, end - begin)]];
        }
    }
    return out;
}

/// Annex-B → AVCC（4 字节长度前缀），VideoToolbox 解 sample buffer 需要 AVCC
static NSData *VCAnnexBToAVCC(NSData *annexb)
{
    NSArray<NSData *> *nals = VCSplitAnnexB(annexb);
    NSMutableData *out = [NSMutableData data];
    for (NSData *nal in nals) {
        if (nal.length == 0) continue;
        uint32_t be = htonl((uint32_t)nal.length);
        [out appendBytes:&be length:4];
        [out appendData:nal];
    }
    return out;
}

// ------------------------------------------------------------------ 主体

@interface VCLiveSource ()
{
    int _sock;
    NSThread *_thread;
    volatile BOOL _running;
    BOOL _connected;

    CMVideoFormatDescriptionRef _fmtDesc;
    VTDecompressionSessionRef _session;

    CVPixelBufferRef _latestBuffer;
    NSLock *_frameLock;

    NSUInteger _received;
    NSString *_statusText;
}

- (void)storeDecodedFrame:(CVPixelBufferRef)buffer;
- (void)disconnect;
- (void)setStatus:(NSString *)s;
- (BOOL)recvExact:(void *)buf length:(size_t)length;
- (void)receiveLoop;
- (void)rebuildDecoderWithConfig:(NSData *)config;
- (void)teardownDecoder;
- (void)feedVideoPayload:(NSData *)payload keyframe:(BOOL)keyframe;

@end

// ------------------------------------------------------------------ 解码回调

static void VCDecodeCallback(void *decompressionOutputRefCon,
                             void *sourceFrameRefCon,
                             OSStatus status,
                             VTDecodeInfoFlags infoFlags,
                             CVImageBufferRef imageBuffer,
                             CMTime pts,
                             CMTime duration)
{
    if (status != noErr || imageBuffer == NULL) return;
    VCLiveSource *src = (__bridge VCLiveSource *)decompressionOutputRefCon;
    [src storeDecodedFrame:imageBuffer];
}

@implementation VCLiveSource

+ (instancetype)shared
{
    static VCLiveSource *inst = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ inst = [[VCLiveSource alloc] init]; });
    return inst;
}

- (instancetype)init
{
    if ((self = [super init])) {
        _sock = -1;
        _frameLock = [[NSLock alloc] init];
        _statusText = @"未连接";
    }
    return self;
}

- (void)dealloc
{
    [self disconnect];
}

- (BOOL)connected   { return _connected; }
- (NSUInteger)receivedFrames { return _received; }
- (NSString *)statusText { return _statusText ?: @"未连接"; }

- (void)setStatus:(NSString *)s
{
    _statusText = [s copy];
    VCLog(@"实时源: %@", s);
}

// ------------------------------------------------------------------ 连接

- (BOOL)connectToHost:(NSString *)host port:(uint16_t)port
{
    if (host.length == 0) return NO;
    [self disconnect];

    struct addrinfo hints, *res = NULL;
    memset(&hints, 0, sizeof(hints));
    hints.ai_family = AF_INET;
    hints.ai_socktype = SOCK_STREAM;

    char portStr[8];
    snprintf(portStr, sizeof(portStr), "%u", port);

    if (getaddrinfo(host.UTF8String, portStr, &hints, &res) != 0 || !res) {
        [self setStatus:@"解析主机失败"];
        return NO;
    }

    int fd = socket(res->ai_family, res->ai_socktype, res->ai_protocol);
    if (fd < 0) {
        freeaddrinfo(res);
        [self setStatus:@"创建 socket 失败"];
        return NO;
    }

    // 5 秒连接超时
    struct timeval tv = { .tv_sec = 5, .tv_usec = 0 };
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof(tv));
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));

    int rc = connect(fd, res->ai_addr, res->ai_addrlen);
    freeaddrinfo(res);

    if (rc != 0) {
        close(fd);
        [self setStatus:[NSString stringWithFormat:@"连接失败 (%d)", errno]];
        return NO;
    }

    int one = 1;
    setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof(one));

    // 连上之后取消读超时，改成阻塞收
    struct timeval notv = { .tv_sec = 0, .tv_usec = 0 };
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &notv, sizeof(notv));

    _sock = fd;
    _connected = YES;
    _running = YES;
    _received = 0;
    [self setStatus:[NSString stringWithFormat:@"已连接 %@:%u", host, port]];

    _thread = [[NSThread alloc] initWithTarget:self
                                      selector:@selector(receiveLoop)
                                        object:nil];
    _thread.name = @"VCamLiveRX";
    _thread.threadPriority = 0.8;
    [_thread start];
    return YES;
}

- (void)disconnect
{
    _running = NO;
    if (_sock >= 0) {
        shutdown(_sock, SHUT_RDWR);
        close(_sock);
        _sock = -1;
    }
    _connected = NO;
    [self teardownDecoder];
    [_frameLock lock];
    if (_latestBuffer) { CVPixelBufferRelease(_latestBuffer); _latestBuffer = NULL; }
    [_frameLock unlock];
    [self setStatus:@"已断开"];
}

// ------------------------------------------------------------------ 接收

- (BOOL)recvExact:(void *)buf length:(size_t)length
{
    size_t got = 0;
    uint8_t *p = buf;
    while (got < length && _running) {
        ssize_t n = recv(_sock, p + got, length - got, 0);
        if (n <= 0) {
            if (n < 0 && (errno == EINTR)) continue;
            return NO;
        }
        got += (size_t)n;
    }
    return got == length;
}

- (void)receiveLoop
{
    @autoreleasepool {
        uint8_t header[kHeaderSize];
        NSTimeInterval lastHeartbeat = [NSDate timeIntervalSinceReferenceDate];

        while (_running) {
            if (![self recvExact:header length:kHeaderSize]) {
                [self setStatus:@"链路断开"];
                break;
            }

            if (memcmp(header, kMagic, 4) != 0) {
                [self setStatus:@"协议头错乱，断开"];
                break;
            }
            uint8_t type = header[5];

            uint64_t flags = 0;
            memcpy(&flags, header + 6, 8);          // 小端，与 Python struct '<Q' 一致

            uint32_t plen = 0;
            memcpy(&plen, header + 22, 4);

            if (plen > 8 * 1024 * 1024) {           // 单帧上限 8MB
                [self setStatus:@"帧过大，断开"];
                break;
            }

            NSMutableData *payload = [NSMutableData dataWithLength:plen];
            if (plen > 0 && ![self recvExact:payload.mutableBytes length:plen]) {
                [self setStatus:@"载荷接收失败"];
                break;
            }

            switch (type) {
                case kTypeConfig:
                    [self rebuildDecoderWithConfig:payload];
                    break;
                case kTypeVideo:
                    [self feedVideoPayload:payload keyframe:(flags & 1) != 0];
                    _received++;
                    break;
                case kTypeHeartbeat:
                    lastHeartbeat = [NSDate timeIntervalSinceReferenceDate];
                    break;
                case kTypeControl:
                    break;
                default:
                    break;
            }

            // 20 秒没有任何包，认为链路死了
            if ([NSDate timeIntervalSinceReferenceDate] - lastHeartbeat > 20.0) {
                [self setStatus:@"心跳超时"];
                break;
            }
        }
    }
    _connected = NO;
}

// ------------------------------------------------------------------ 解码器

- (void)rebuildDecoderWithConfig:(NSData *)config
{
    NSArray<NSData *> *nals = VCSplitAnnexB(config);
    NSData *sps = nil, *pps = nil;
    for (NSData *n in nals) {
        if (n.length == 0) continue;
        uint8_t t = ((const uint8_t *)n.bytes)[0] & 0x1F;
        if (t == 7) sps = n;
        else if (t == 8) pps = n;
    }
    if (!sps || !pps) {
        VCLog(@"config 包缺 SPS/PPS");
        return;
    }

    [self teardownDecoder];

    const uint8_t *params[2] = { sps.bytes, pps.bytes };
    size_t sizes[2] = { sps.length, pps.length };

    OSStatus st = CMVideoFormatDescriptionCreateFromH264ParameterSets(
        kCFAllocatorDefault, 2, params, sizes, 4, &_fmtDesc);
    if (st != noErr) {
        VCLog(@"创建 H.264 format description 失败: %d", (int)st);
        return;
    }

    NSDictionary *attrs = @{
        (id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange),
        (id)kCVPixelBufferIOSurfacePropertiesKey: @{},
    };

    VTDecompressionOutputCallbackRecord cb;
    cb.decompressionOutputCallback = VCDecodeCallback;
    cb.decompressionOutputRefCon = (__bridge void *)self;

    st = VTDecompressionSessionCreate(kCFAllocatorDefault, _fmtDesc, NULL,
                                      (__bridge CFDictionaryRef)attrs,
                                      &cb, &_session);
    if (st != noErr) {
        VCLog(@"VTDecompressionSession 创建失败: %d", (int)st);
        return;
    }

    VTSessionSetProperty(_session,
                         kVTDecompressionPropertyKey_RealTime,
                         kCFBooleanTrue);
    VCLog(@"实时源解码器就绪");
}

- (void)teardownDecoder
{
    if (_session) {
        VTDecompressionSessionInvalidate(_session);
        CFRelease(_session);
        _session = NULL;
    }
    if (_fmtDesc) {
        CFRelease(_fmtDesc);
        _fmtDesc = NULL;
    }
}

- (void)feedVideoPayload:(NSData *)payload keyframe:(BOOL)keyframe
{
    if (!_session || !_fmtDesc) {
        if (keyframe) VCLog(@"收到关键帧但还没有 config，等下一轮");
        return;
    }

    NSData *avcc = VCAnnexBToAVCC(payload);
    if (avcc.length == 0) return;

    CMBlockBufferRef block = NULL;
    OSStatus st = CMBlockBufferCreateWithMemoryBlock(
        kCFAllocatorDefault, NULL, avcc.length, kCFAllocatorDefault, NULL,
        0, avcc.length, kCMBlockBufferAssureMemoryNowFlag, &block);
    if (st != noErr || !block) return;

    st = CMBlockBufferReplaceDataBytes(avcc.bytes, block, 0, avcc.length);
    if (st != noErr) { CFRelease(block); return; }

    double fps = [VCSampleBufferFactory shared].fps;
    if (fps <= 0) fps = 30.0;

    CMSampleTimingInfo timing;
    timing.duration              = CMTimeMakeWithSeconds(1.0 / fps, 1000000000);
    timing.presentationTimeStamp = CMClockGetTime(CMClockGetHostTimeClock());
    timing.decodeTimeStamp       = kCMTimeInvalid;

    CMSampleBufferRef sbuf = NULL;
    st = CMSampleBufferCreateReady(kCFAllocatorDefault, block, _fmtDesc,
                                   1, 0, &timing, 0, NULL, &sbuf);
    CFRelease(block);
    if (st != noErr) return;

    VTDecodeInfoFlags infoFlags = 0;
    VTDecodeFrameFlags flags = kVTDecodeFrame_EnableAsynchronousDecompression |
                               kVTDecodeFrame_1xRealTimePlayback;
    VTDecompressionSessionDecodeFrame(_session, sbuf, flags, NULL, &infoFlags);
    CFRelease(sbuf);
}

// ------------------------------------------------------------------ 帧缓存

- (void)storeDecodedFrame:(CVPixelBufferRef)buffer
{
    if (!buffer) return;
    CVPixelBufferRetain(buffer);
    [_frameLock lock];
    if (_latestBuffer) CVPixelBufferRelease(_latestBuffer);
    _latestBuffer = buffer;
    [_frameLock unlock];
}

- (CMSampleBufferRef)copyNextVideoSampleBuffer
{
    if (!_connected) return NULL;

    CVPixelBufferRef pb = NULL;
    [_frameLock lock];
    if (_latestBuffer) {
        pb = CVPixelBufferRetain(_latestBuffer);
        CVPixelBufferRelease(_latestBuffer);
        _latestBuffer = NULL;
    }
    [_frameLock unlock];

    if (!pb) return NULL;

    CMSampleBufferRef sbuf = [[VCSampleBufferFactory shared]
                              createVideoSampleBufferFrom:pb
                                     presentationOverride:nil];
    CVPixelBufferRelease(pb);

    if (sbuf) {
        CVPixelBufferRef img = CMSampleBufferGetImageBuffer(sbuf);
        if (img) [[VCSampleBufferFactory shared] updateJPEGFromPixelBuffer:img];
    }
    return sbuf;
}

@end
