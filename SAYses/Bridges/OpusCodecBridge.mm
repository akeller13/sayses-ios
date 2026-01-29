//
//  OpusCodecBridge.mm
//  SAYses
//
//  Bridge implementation for C++ Opus codec
//

#import "OpusCodecBridge.h"
#include "codec.h"
#include <memory>
#include <vector>
#include <mutex>

@implementation OpusCodecBridge {
    std::unique_ptr<sayses::Codec> _codec;
    int _frameSize;
    int _sampleRate;
    std::vector<int16_t> _sampleBuffer;  // Buffer for accumulating samples
    std::mutex _bufferMutex;  // Protects _sampleBuffer from concurrent access (IO thread + main thread)
}

- (instancetype)init {
    return [self initWithSampleRate:48000 channels:1 bitrate:64000];
}

- (instancetype)initWithSampleRate:(int)sampleRate
                          channels:(int)channels
                           bitrate:(int)bitrate {
    self = [super init];
    if (self) {
        _sampleRate = sampleRate;
        _frameSize = sampleRate / 100;  // 10ms frame = sampleRate / 100

        sayses::Codec::Config config;
        config.sampleRate = sampleRate;
        config.channels = channels;
        config.bitrate = bitrate;
        config.frameSize = _frameSize;
        config.complexity = 5;
        config.vbr = true;
        config.dtx = true;

        try {
            _codec = sayses::Codec::createOpus(config);
            NSLog(@"[OpusCodecBridge] Created: sampleRate=%d, channels=%d, bitrate=%d, frameSize=%d",
                  sampleRate, channels, bitrate, _frameSize);
        } catch (const std::exception& e) {
            NSLog(@"[OpusCodecBridge] ERROR: Failed to create codec: %s", e.what());
            return nil;
        }
    }
    return self;
}

- (nullable NSData *)encodeWithPCM:(const int16_t *)pcmData
                        frameCount:(int)frameCount {
    if (!_codec || !pcmData) {
        return nil;
    }

    // Frame count MUST be exactly _frameSize (480 for 48kHz/10ms)
    if (frameCount != _frameSize) {
        NSLog(@"[OpusCodecBridge] WARNING: encodeWithPCM called with %d frames, expected %d. Use addSamplesAndEncode instead.",
              frameCount, _frameSize);
        return nil;
    }

    // Opus max packet size is around 4000 bytes, but typical voice is much smaller
    constexpr size_t kMaxPacketSize = 4000;
    uint8_t outputBuffer[kMaxPacketSize];

    int encodedBytes = _codec->encode(pcmData, frameCount, outputBuffer, kMaxPacketSize);

    if (encodedBytes < 0) {
        NSLog(@"[OpusCodecBridge] Encode error: %d", encodedBytes);
        return nil;
    }

    return [NSData dataWithBytes:outputBuffer length:encodedBytes];
}

- (void)addSamplesAndEncode:(const int16_t *)pcmData
                 frameCount:(int)frameCount
                   callback:(void (^)(NSData *encodedData))callback {
    if (!_codec || !pcmData || frameCount <= 0 || !callback) {
        return;
    }

    std::lock_guard<std::mutex> lock(_bufferMutex);

    // Add samples to buffer
    _sampleBuffer.insert(_sampleBuffer.end(), pcmData, pcmData + frameCount);

    // Encode in chunks of _frameSize (480 samples)
    while (_sampleBuffer.size() >= static_cast<size_t>(_frameSize)) {
        constexpr size_t kMaxPacketSize = 4000;
        uint8_t outputBuffer[kMaxPacketSize];

        int encodedBytes = _codec->encode(_sampleBuffer.data(), _frameSize, outputBuffer, kMaxPacketSize);

        // Remove encoded samples from buffer
        _sampleBuffer.erase(_sampleBuffer.begin(), _sampleBuffer.begin() + _frameSize);

        if (encodedBytes > 0) {
            NSData *encoded = [NSData dataWithBytes:outputBuffer length:encodedBytes];
            callback(encoded);
        } else {
            NSLog(@"[OpusCodecBridge] Encode error in addSamplesAndEncode: %d", encodedBytes);
        }
    }
}

- (int)decodeWithOpusData:(NSData *)opusData
             outputBuffer:(int16_t *)outputBuffer
                maxFrames:(int)maxFrames {
    if (!_codec || !opusData || !outputBuffer) {
        return -1;
    }

    int decodedFrames = _codec->decode(
        static_cast<const uint8_t *>(opusData.bytes),
        opusData.length,
        outputBuffer,
        maxFrames
    );

    if (decodedFrames < 0) {
        NSLog(@"[OpusCodecBridge] Decode error: %d", decodedFrames);
    }

    return decodedFrames;
}

- (int)decodePLCWithOutputBuffer:(int16_t *)outputBuffer
                       maxFrames:(int)maxFrames {
    if (!_codec || !outputBuffer) {
        return -1;
    }

    int generatedFrames = _codec->decodePLC(outputBuffer, maxFrames);

    if (generatedFrames < 0) {
        NSLog(@"[OpusCodecBridge] PLC error: %d", generatedFrames);
    }

    return generatedFrames;
}

- (void)reset {
    if (_codec) {
        _codec->reset();
    }
    {
        std::lock_guard<std::mutex> lock(_bufferMutex);
        _sampleBuffer.clear();
    }
    NSLog(@"[OpusCodecBridge] Reset (buffer cleared)");
}

- (void)clearBuffer {
    std::lock_guard<std::mutex> lock(_bufferMutex);
    _sampleBuffer.clear();
}

- (int)frameSize {
    return _frameSize;
}

- (int)sampleRate {
    return _sampleRate;
}

@end
