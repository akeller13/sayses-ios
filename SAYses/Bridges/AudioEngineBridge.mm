#import "AudioEngineBridge.h"
#include "audio_engine.h"
#include <memory>

@implementation AudioEngineBridge {
    std::unique_ptr<sayses::AudioEngine> _engine;
    AudioCaptureCallback _captureCallback;
    AudioPlaybackCallback _playbackCallback;
}

- (instancetype)initWithSampleRate:(int)sampleRate
                          channels:(int)channels
                   framesPerBuffer:(int)framesPerBuffer {
    self = [super init];
    if (self) {
        NSLog(@"[AudioEngineBridge] Creating with sampleRate=%d, channels=%d, frames=%d", sampleRate, channels, framesPerBuffer);

        sayses::AudioEngine::Config config;
        config.sampleRate = sampleRate;
        config.channels = channels;
        config.framesPerBuffer = framesPerBuffer;

        _engine = sayses::AudioEngine::create(config);

        if (_engine) {
            NSLog(@"[AudioEngineBridge] Engine created successfully");
        } else {
            NSLog(@"[AudioEngineBridge] ERROR: Engine creation failed!");
        }
    }
    return self;
}

- (BOOL)isCapturing {
    return _engine ? _engine->isCapturing() : NO;
}

- (BOOL)isPlaying {
    return _engine ? _engine->isPlaying() : NO;
}

- (BOOL)isVoiceDetected {
    return _engine ? _engine->isVoiceDetected() : NO;
}

- (float)inputLevel {
    return _engine ? _engine->getInputLevel() : 0.0f;
}

- (BOOL)startCaptureWithCallback:(AudioCaptureCallback)callback {
    NSLog(@"[AudioEngineBridge] startCapture called, engine=%p", _engine.get());

    if (!_engine) {
        NSLog(@"[AudioEngineBridge] ERROR: No engine!");
        return NO;
    }

    _captureCallback = [callback copy];

    BOOL result = _engine->startCapture([self](const int16_t* data, size_t frames) {
        if (_captureCallback) {
            _captureCallback(data, frames);
        }
    });

    NSLog(@"[AudioEngineBridge] startCapture result=%d", result);
    return result;
}

- (void)stopCapture {
    if (_engine) {
        _engine->stopCapture();
    }
    _captureCallback = nil;
}

- (BOOL)startPlaybackWithCallback:(AudioPlaybackCallback)callback {
    if (!_engine) return NO;

    _playbackCallback = [callback copy];

    return _engine->startPlayback([self](int16_t* data, size_t frames) -> size_t {
        if (_playbackCallback) {
            return _playbackCallback(data, frames);
        }
        return 0;
    });
}

- (void)stopPlayback {
    if (_engine) {
        _engine->stopPlayback();
    }
    _playbackCallback = nil;
}

- (void)setVadEnabled:(BOOL)enabled {
    if (_engine) {
        _engine->setVadEnabled(enabled);
    }
}

- (void)setVadThreshold:(float)threshold {
    if (_engine) {
        _engine->setVadThreshold(threshold);
    }
}

- (void)addUserAudio:(uint32_t)userId
             samples:(const int16_t *)samples
              frames:(size_t)frames
            sequence:(int64_t)sequence {
    if (_engine) {
        _engine->addUserAudio(userId, samples, frames, sequence);
    }
}

- (void)removeUser:(uint32_t)userId {
    if (_engine) {
        _engine->removeUser(userId);
    }
}

- (void)notifyUserTalkingEnded:(uint32_t)userId {
    if (_engine) {
        _engine->notifyUserTalkingEnded(userId);
    }
}

- (BOOL)startMixedPlayback {
    if (!_engine) return NO;
    return _engine->startMixedPlayback();
}

@end
