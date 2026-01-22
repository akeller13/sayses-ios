#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/**
 * Objective-C bridge for the C++ AudioEngine.
 * Enables Swift to interact with the native audio capture/playback system.
 */
@interface AudioEngineBridge : NSObject

typedef void (^AudioCaptureCallback)(const int16_t *data, size_t frames);
typedef size_t (^AudioPlaybackCallback)(int16_t *data, size_t frames);

@property (nonatomic, readonly) BOOL isCapturing;
@property (nonatomic, readonly) BOOL isPlaying;
@property (nonatomic, readonly) BOOL isVoiceDetected;
@property (nonatomic, readonly) float inputLevel;

- (instancetype)initWithSampleRate:(int)sampleRate
                          channels:(int)channels
                   framesPerBuffer:(int)framesPerBuffer;

// Capture
- (BOOL)startCaptureWithCallback:(AudioCaptureCallback)callback;
- (void)stopCapture;

// Playback
- (BOOL)startPlaybackWithCallback:(AudioPlaybackCallback)callback;
- (void)stopPlayback;

// VAD
- (void)setVadEnabled:(BOOL)enabled;
- (void)setVadThreshold:(float)threshold;

// User Audio Management (for multi-user playback with mixing)

/// Add decoded audio for a user (uses per-user buffers with float mixing)
/// @param userId User/session ID
/// @param samples Decoded PCM samples
/// @param frames Number of samples
/// @param sequence Packet sequence number for jitter buffer
- (void)addUserAudio:(uint32_t)userId
             samples:(const int16_t *)samples
              frames:(size_t)frames
            sequence:(int64_t)sequence;

/// Remove user's audio buffer
- (void)removeUser:(uint32_t)userId;

/// Notify that user stopped talking (triggers crossfade)
- (void)notifyUserTalkingEnded:(uint32_t)userId;

/// Start playback using internal user mixing (no callback needed)
- (BOOL)startMixedPlayback;

@end

NS_ASSUME_NONNULL_END
