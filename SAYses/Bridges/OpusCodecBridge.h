//
//  OpusCodecBridge.h
//  SAYses
//
//  Bridge for C++ Opus codec to Swift
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Opus audio codec bridge for encoding/decoding audio
/// Configuration matches Mumble protocol requirements (48kHz, mono, 64kbps)
@interface OpusCodecBridge : NSObject

/// Initialize with default Mumble settings (48kHz, mono, 64kbps)
/// @return nil if Opus codec initialization fails
- (nullable instancetype)init;

/// Initialize with custom settings
/// @param sampleRate Sample rate (typically 48000)
/// @param channels Number of channels (typically 1 for mono)
/// @param bitrate Target bitrate in bps (typically 64000)
/// @return nil if Opus codec initialization fails
- (nullable instancetype)initWithSampleRate:(int)sampleRate
                                   channels:(int)channels
                                    bitrate:(int)bitrate;

/// Encode PCM audio to Opus
/// @param pcmData PCM samples (16-bit signed integers)
/// @param frameCount Number of samples (must be 480 for 10ms at 48kHz)
/// @return Encoded Opus data, or nil on error
- (nullable NSData *)encodeWithPCM:(const int16_t *)pcmData
                        frameCount:(int)frameCount;

/// Add PCM samples to internal buffer and encode when 480 samples are available
/// iOS AudioUnit may deliver variable frame counts (512, 1024, etc.)
/// This method buffers samples and encodes in 480-sample chunks
/// @param pcmData PCM samples (16-bit signed integers)
/// @param frameCount Number of samples (can be any size)
/// @param callback Called for each encoded 480-sample chunk
- (void)addSamplesAndEncode:(const int16_t *)pcmData
                 frameCount:(int)frameCount
                   callback:(void (^)(NSData *encodedData))callback;

/// Decode Opus to PCM audio
/// @param opusData Encoded Opus data
/// @param outputBuffer Buffer for decoded PCM samples (must hold frameCount samples)
/// @param maxFrames Maximum frames to decode
/// @return Number of decoded frames, or -1 on error
- (int)decodeWithOpusData:(NSData *)opusData
             outputBuffer:(int16_t *)outputBuffer
                maxFrames:(int)maxFrames;

/// Decode with Packet Loss Concealment (when packet is missing)
/// @param outputBuffer Buffer for generated PCM samples
/// @param maxFrames Maximum frames to generate
/// @return Number of generated frames, or -1 on error
- (int)decodePLCWithOutputBuffer:(int16_t *)outputBuffer
                       maxFrames:(int)maxFrames;

/// Reset encoder and decoder state
- (void)reset;

/// Clear the internal sample buffer without resetting codec state
- (void)clearBuffer;

/// Frame size in samples (480 for 10ms at 48kHz)
@property (nonatomic, readonly) int frameSize;

/// Sample rate (48000)
@property (nonatomic, readonly) int sampleRate;

@end

NS_ASSUME_NONNULL_END
