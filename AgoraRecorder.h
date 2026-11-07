#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Handles writing captured PCM audio frames to a local WAV file,
/// and (optionally, after the call ends) uploading the finished file to Twilio.
/// This class NEVER streams audio live anywhere — it only ever touches
/// a file that is already finished and saved on disk.
@interface AgoraRecorder : NSObject

+ (instancetype)sharedRecorder;

/// Call once when a call starts. sampleRate/channels should match
/// whatever Agora reports in the captured frames.
- (void)startNewRecordingWithSampleRate:(NSUInteger)sampleRate channels:(NSUInteger)channels;

/// Call for every raw PCM buffer you capture during the call.
- (void)appendPCMData:(NSData *)pcmData;

/// Call when the call ends. Finalizes the WAV header and closes the file.
/// Returns the file path of the finished recording, or nil if nothing was recorded.
- (nullable NSString *)finishRecording;

/// Returns all finished recordings (newest first), as file paths under Documents/AgoraRecordings.
- (NSArray<NSString *> *)allRecordings;

/// Deletes a recording at the given path.
- (void)deleteRecordingAtPath:(NSString *)path;

/// Reads toggle state saved from the Settings app (NSUserDefaults, suite com.yourname.agorarecorder).
- (BOOL)isRecordingEnabled;
- (BOOL)isAutoUploadEnabled;

/// Live monitoring: plays the same PCM frames being written to disk back
/// through the device speaker/headphones WHILE the call is being recorded.
/// This is purely local audio routing (engine -> output) — nothing is sent
/// over the network. Off by default; toggled from Settings like the rest.
- (BOOL)isLiveMonitorEnabled;

/// When live monitoring is on, this toggles a REAL playback-rate change
/// (not just a pitch shift) of 3x on the monitored audio, via
/// AVAudioUnitVarispeed. Off by default.
- (BOOL)isLiveMonitor3xEnabled;

/// Setters used by the in-app floating menu (no Settings app / jailbreak needed).
- (void)setRecordingEnabled:(BOOL)on;
- (void)setLiveMonitorEnabled:(BOOL)on;
- (void)setLiveMonitor3xEnabled:(BOOL)on;

/// YES while a WAV file is open and being written.
- (BOOL)isCurrentlyRecording;

/// Uploads an ALREADY FINISHED recording file to Twilio. This is a plain
/// HTTPS upload of a static file after the call is over — not a live stream.
/// Fill in your own Twilio endpoint/credentials handling as appropriate
/// (e.g. upload to your own backend, which then stores/forwards it via Twilio).
- (void)uploadRecordingAtPath:(NSString *)path
                    completion:(void (^_Nullable)(BOOL success, NSError *_Nullable error))completion;

@end

NS_ASSUME_NONNULL_END
