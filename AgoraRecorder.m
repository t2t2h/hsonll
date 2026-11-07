#import "AgoraRecorder.h"
#import <AVFoundation/AVFoundation.h>
#import <QuartzCore/QuartzCore.h>

static NSString *const kDefaultsSuiteName = @"com.yourname.agorarecorder";
static NSString *const kKeyRecordingEnabled = @"RecordingEnabled";
static NSString *const kKeyAutoUploadEnabled = @"AutoUploadEnabled";
static NSString *const kKeyTwilioUploadURL = @"TwilioUploadURLString"; // your own backend endpoint
static NSString *const kKeyLiveMonitorEnabled = @"LiveMonitorEnabled";
static NSString *const kKeyLiveMonitor3xEnabled = @"LiveMonitor3xEnabled";

@interface AgoraRecorder ()
@property (nonatomic, strong) NSFileHandle *fileHandle;
@property (nonatomic, copy) NSString *currentPath;
@property (nonatomic, assign) NSUInteger bytesWritten;
@property (nonatomic, assign) NSUInteger sampleRate;
@property (nonatomic, assign) NSUInteger channels;
@property (nonatomic, assign) CFTimeInterval lastFrameTime;
@property (nonatomic, strong) dispatch_source_t idleTimer;

// Live monitor graph: playerNode -> varispeed (rate control) -> mainMixer -> output.
// Built fresh per-call and torn down when the call ends; never touches disk
// or the network, so it stays consistent with the "local-only" design above.
@property (nonatomic, strong) AVAudioEngine *monitorEngine;
@property (nonatomic, strong) AVAudioPlayerNode *monitorPlayerNode;
@property (nonatomic, strong) AVAudioUnitVarispeed *monitorVarispeed;
@property (nonatomic, strong) AVAudioFormat *monitorFormat;
@end

@implementation AgoraRecorder

+ (instancetype)sharedRecorder {
    static AgoraRecorder *shared;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        shared = [AgoraRecorder new];
    });
    return shared;
}

#pragma mark - Paths

- (NSString *)recordingsDirectory {
    NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    NSString *dir = [docs stringByAppendingPathComponent:@"AgoraRecordings"];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir
                               withIntermediateDirectories:YES
                                                attributes:nil
                                                     error:nil];
    return dir;
}

#pragma mark - Recording lifecycle

- (void)startNewRecordingWithSampleRate:(NSUInteger)sampleRate channels:(NSUInteger)channels {
    if (![self isRecordingEnabled]) return;

    @synchronized (self) {
        if (self.fileHandle) return; // already recording

        self.sampleRate = sampleRate;
        self.channels = channels;
        self.bytesWritten = 0;

        NSDateFormatter *fmt = [NSDateFormatter new];
        fmt.dateFormat = @"yyyy-MM-dd_HH-mm-ss";
        NSString *name = [NSString stringWithFormat:@"call_%@.wav", [fmt stringFromDate:[NSDate date]]];
        self.currentPath = [[self recordingsDirectory] stringByAppendingPathComponent:name];

        [[NSFileManager defaultManager] createFileAtPath:self.currentPath contents:nil attributes:nil];
        self.fileHandle = [NSFileHandle fileHandleForWritingAtPath:self.currentPath];

        // Placeholder 44-byte WAV header; sizes get patched in on finish.
        NSMutableData *header = [self wavHeaderWithDataLength:0];
        [self.fileHandle writeData:header];

        self.lastFrameTime = CACurrentMediaTime();
        [self startIdleWatcher];
    }
}

- (void)appendPCMData:(NSData *)pcmData {
    if (![self isRecordingEnabled]) return;

    @synchronized (self) {
        if (!self.fileHandle) return;
        [self.fileHandle writeData:pcmData];
        self.bytesWritten += pcmData.length;
        self.lastFrameTime = CACurrentMediaTime();

        if ([self isLiveMonitorEnabled]) {
            if (!self.monitorEngine) {
                [self setupLiveMonitorWithSampleRate:self.sampleRate channels:self.channels];
            }
            [self feedLiveMonitorWithPCMData:pcmData];
        } else if (self.monitorEngine) {
            [self teardownLiveMonitor];
        }
    }
}

- (BOOL)isCurrentlyRecording {
    @synchronized (self) {
        return self.fileHandle != nil;
    }
}

// If no audio frames arrive for 3 seconds, the call is considered over
// and the file is finalized. This replaces the need to hook join/leave
// callbacks, whose names differ between Agora SDK versions.
- (void)startIdleWatcher {
    [self stopIdleWatcher];
    dispatch_source_t t = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0,
                                                 dispatch_get_global_queue(QOS_CLASS_UTILITY, 0));
    dispatch_source_set_timer(t, dispatch_time(DISPATCH_TIME_NOW, 1 * NSEC_PER_SEC),
                              1 * NSEC_PER_SEC, 100 * NSEC_PER_MSEC);
    __weak typeof(self) weakSelf = self;
    dispatch_source_set_event_handler(t, ^{
        AgoraRecorder *strongSelf = weakSelf;
        if (!strongSelf) return;
        if (CACurrentMediaTime() - strongSelf.lastFrameTime > 3.0) {
            [strongSelf finishRecording];
        }
    });
    dispatch_resume(t);
    self.idleTimer = t;
}

- (void)stopIdleWatcher {
    if (self.idleTimer) {
        dispatch_source_cancel(self.idleTimer);
        self.idleTimer = nil;
    }
}

#pragma mark - Live monitoring (listen while recording)

// Builds a tiny AVAudioEngine graph the first time it's needed for this
// call. Runs alongside whatever AVAudioSession/engine Agora itself is
// already using for the call; it does not change the session category,
// since the host app (via Agora) has normally already configured
// PlayAndRecord, which is what simultaneous mic capture + local playback
// needs. If the host app uses a plain Record-only category, local
// monitoring will not produce audio until that's changed.
- (void)setupLiveMonitorWithSampleRate:(NSUInteger)sampleRate channels:(NSUInteger)channels {
    if (self.monitorEngine) return; // already set up for this call

    // AVAudioEngine's real-time graph wants float32, non-interleaved —
    // the raw frames Agora hands us are 16-bit signed PCM, interleaved,
    // so appendPCMData converts on the fly in feedLiveMonitorWithPCMData:.
    self.monitorFormat = [[AVAudioFormat alloc] initWithCommonFormat:AVAudioPCMFormatFloat32
                                                            sampleRate:(double)sampleRate
                                                              channels:(AVAudioChannelCount)channels
                                                           interleaved:NO];

    self.monitorEngine = [[AVAudioEngine alloc] init];
    self.monitorPlayerNode = [[AVAudioPlayerNode alloc] init];
    self.monitorVarispeed = [[AVAudioUnitVarispeed alloc] init];
    self.monitorVarispeed.rate = [self isLiveMonitor3xEnabled] ? 3.0f : 1.0f;

    [self.monitorEngine attachNode:self.monitorPlayerNode];
    [self.monitorEngine attachNode:self.monitorVarispeed];
    [self.monitorEngine connect:self.monitorPlayerNode to:self.monitorVarispeed format:self.monitorFormat];
    [self.monitorEngine connect:self.monitorVarispeed to:self.monitorEngine.mainMixerNode format:self.monitorFormat];

    NSError *error;
    if (![self.monitorEngine startAndReturnError:&error]) {
        // Don't let a monitoring failure break the actual recording/call.
        self.monitorEngine = nil;
        self.monitorPlayerNode = nil;
        self.monitorVarispeed = nil;
        self.monitorFormat = nil;
        return;
    }
    [self.monitorPlayerNode play];
}

// Converts one chunk of interleaved 16-bit PCM into a float32 buffer and
// schedules it on the player node immediately, so it comes out of the
// speaker/headphones essentially as it's captured. Re-reads the 3x
// setting on every chunk so toggling it mid-call takes effect right away.
- (void)feedLiveMonitorWithPCMData:(NSData *)pcmData {
    if (!self.monitorEngine || !self.monitorPlayerNode || self.channels == 0) return;

    self.monitorVarispeed.rate = [self isLiveMonitor3xEnabled] ? 3.0f : 1.0f;

    NSUInteger channels = self.channels;
    NSUInteger totalSamples = pcmData.length / sizeof(int16_t);
    NSUInteger frameCount = totalSamples / channels;
    if (frameCount == 0) return;

    AVAudioPCMBuffer *buffer = [[AVAudioPCMBuffer alloc] initWithPCMFormat:self.monitorFormat
                                                              frameCapacity:(AVAudioFrameCount)frameCount];
    if (!buffer) return;
    buffer.frameLength = (AVAudioFrameCount)frameCount;

    const int16_t *src = (const int16_t *)pcmData.bytes;
    for (NSUInteger ch = 0; ch < channels; ch++) {
        float *dst = buffer.floatChannelData[ch];
        for (NSUInteger i = 0; i < frameCount; i++) {
            int16_t sample = src[i * channels + ch];
            dst[i] = (float)sample / 32768.0f;
        }
    }

    [self.monitorPlayerNode scheduleBuffer:buffer completionHandler:nil];
}

- (void)teardownLiveMonitor {
    [self.monitorPlayerNode stop];
    [self.monitorEngine stop];
    self.monitorEngine = nil;
    self.monitorPlayerNode = nil;
    self.monitorVarispeed = nil;
    self.monitorFormat = nil;
}

- (nullable NSString *)finishRecording {
    NSString *finishedPath = nil;
    BOOL shouldUpload = NO;

    @synchronized (self) {
        if (!self.fileHandle) return nil;
        [self stopIdleWatcher];

        // Patch the WAV header now that we know the final size.
        [self.fileHandle seekToFileOffset:0];
        NSMutableData *header = [self wavHeaderWithDataLength:(uint32_t)self.bytesWritten];
        [self.fileHandle writeData:header];
        [self.fileHandle closeFile];

        finishedPath = self.currentPath;
        self.fileHandle = nil;
        self.currentPath = nil;

        [self teardownLiveMonitor];

        if (self.bytesWritten == 0) {
            // Nothing actually recorded — clean up the empty file.
            [[NSFileManager defaultManager] removeItemAtPath:finishedPath error:nil];
            return nil;
        }
        shouldUpload = [self isAutoUploadEnabled];
    }

    if (shouldUpload) {
        [self uploadRecordingAtPath:finishedPath completion:nil];
    }
    return finishedPath;
}

- (NSMutableData *)wavHeaderWithDataLength:(uint32_t)dataLength {
    uint32_t sampleRate = (uint32_t)self.sampleRate;
    uint16_t channels = (uint16_t)self.channels;
    uint16_t bitsPerSample = 16;
    uint32_t byteRate = sampleRate * channels * bitsPerSample / 8;
    uint16_t blockAlign = channels * bitsPerSample / 8;
    uint32_t chunkSize = 36 + dataLength;

    NSMutableData *header = [NSMutableData data];
    [header appendBytes:"RIFF" length:4];
    [header appendBytes:&chunkSize length:4];
    [header appendBytes:"WAVE" length:4];
    [header appendBytes:"fmt " length:4];
    uint32_t subchunk1Size = 16;
    [header appendBytes:&subchunk1Size length:4];
    uint16_t audioFormat = 1; // PCM
    [header appendBytes:&audioFormat length:2];
    [header appendBytes:&channels length:2];
    [header appendBytes:&sampleRate length:4];
    [header appendBytes:&byteRate length:4];
    [header appendBytes:&blockAlign length:2];
    [header appendBytes:&bitsPerSample length:2];
    [header appendBytes:"data" length:4];
    [header appendBytes:&dataLength length:4];
    return header;
}

#pragma mark - Listing / deleting

- (NSArray<NSString *> *)allRecordings {
    NSString *dir = [self recordingsDirectory];
    NSArray *names = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:dir error:nil];
    NSArray *sorted = [names sortedArrayUsingComparator:^NSComparisonResult(NSString *a, NSString *b) {
        return [b compare:a]; // newest first (filenames are timestamped)
    }];
    NSMutableArray *paths = [NSMutableArray array];
    for (NSString *name in sorted) {
        [paths addObject:[dir stringByAppendingPathComponent:name]];
    }
    return paths;
}

- (void)deleteRecordingAtPath:(NSString *)path {
    [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
}

#pragma mark - Settings (synced from the Settings app via PreferenceLoader)

- (NSUserDefaults *)defaults {
    static NSUserDefaults *d;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        d = [[NSUserDefaults alloc] initWithSuiteName:kDefaultsSuiteName];
    });
    return d;
}

- (void)setRecordingEnabled:(BOOL)on {
    [[self defaults] setBool:on forKey:kKeyRecordingEnabled];
}

- (void)setLiveMonitorEnabled:(BOOL)on {
    [[self defaults] setBool:on forKey:kKeyLiveMonitorEnabled];
}

- (void)setLiveMonitor3xEnabled:(BOOL)on {
    [[self defaults] setBool:on forKey:kKeyLiveMonitor3xEnabled];
}

- (BOOL)isRecordingEnabled {
    NSNumber *val = [[self defaults] objectForKey:kKeyRecordingEnabled];
    return val ? val.boolValue : NO; // off by default
}

- (BOOL)isAutoUploadEnabled {
    NSNumber *val = [[self defaults] objectForKey:kKeyAutoUploadEnabled];
    return val ? val.boolValue : NO;
}

- (BOOL)isLiveMonitorEnabled {
    NSNumber *val = [[self defaults] objectForKey:kKeyLiveMonitorEnabled];
    return val ? val.boolValue : NO; // off by default
}

- (BOOL)isLiveMonitor3xEnabled {
    NSNumber *val = [[self defaults] objectForKey:kKeyLiveMonitor3xEnabled];
    return val ? val.boolValue : NO; // off by default
}

#pragma mark - Upload (post-call only, never live)

- (void)uploadRecordingAtPath:(NSString *)path
                    completion:(void (^)(BOOL, NSError *_Nullable))completion {
    NSString *urlString = [[self defaults] stringForKey:kKeyTwilioUploadURL];
    if (urlString.length == 0) {
        if (completion) completion(NO, [NSError errorWithDomain:@"AgoraRecorder" code:1
                                                         userInfo:@{NSLocalizedDescriptionKey: @"No upload endpoint configured"}]);
        return;
    }

    NSData *fileData = [NSData dataWithContentsOfFile:path];
    if (!fileData) {
        if (completion) completion(NO, [NSError errorWithDomain:@"AgoraRecorder" code:2
                                                         userInfo:@{NSLocalizedDescriptionKey: @"Could not read finished recording"}]);
        return;
    }

    NSURL *url = [NSURL URLWithString:urlString];
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
    req.HTTPMethod = @"POST";
    [req setValue:@"audio/wav" forHTTPHeaderField:@"Content-Type"];
    req.HTTPBody = fileData;

    NSURLSessionUploadTask *task = [[NSURLSession sharedSession]
        uploadTaskWithRequest:req fromData:fileData
            completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        BOOL ok = !error && [(NSHTTPURLResponse *)response statusCode] / 100 == 2;
        if (completion) completion(ok, error);
    }];
    [task resume];
}

@end
