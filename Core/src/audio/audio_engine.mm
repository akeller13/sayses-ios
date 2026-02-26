/**
 * AudioEngine Implementation for iOS
 * Complete audio pipeline based on SAYses Android / Mumla architecture
 *
 * Features:
 * - AudioUnit for low-latency I/O
 * - Speex Preprocessor (Denoise, AGC, Dereverb)
 * - Speex Resampler for Bluetooth (16kHz <-> 48kHz)
 * - Float-sample mixing for clipping-safe multi-user playback
 * - Per-user audio buffers with adaptive jitter buffering
 * - Sine-wave crossfade for smooth transitions
 * - Hardware AEC support via VoiceCommunication mode
 */

#include "audio_engine.h"
#include "speex_dsp.h"
#include "user_audio_buffer.h"
#include "codec.h"
#include "vad.h"

#include <AudioToolbox/AudioToolbox.h>
#include <AVFoundation/AVFoundation.h>

#include <atomic>
#include <mutex>
#include <map>
#include <memory>
#include <vector>
#include <cmath>
#include <cstring>
#include <thread>

namespace sayses {

// Constants matching Android implementation
constexpr int kOpusSampleRate = 48000;
constexpr int kOpusFrameSize = 480;    // 10ms at 48kHz
constexpr int kBluetoothSampleRate = 16000;
constexpr int kResamplerQuality = 3;   // VoIP quality (like Mumla)

class AudioEngineImpl : public AudioEngine {
public:
    explicit AudioEngineImpl(const Config& config);
    ~AudioEngineImpl() override;

    bool startCapture(AudioCallback callback) override;
    void stopCapture() override;
    bool isCapturing() const override;

    bool startPlayback(PlaybackCallback callback) override;
    void stopPlayback() override;
    bool isPlaying() const override;

    void setVadEnabled(bool enabled) override;
    void setVadThreshold(float threshold) override;
    bool isVoiceDetected() const override;
    float getInputLevel() const override;

    // Extended interface for SAYses
    void setPreprocessingEnabled(bool enabled);
    void setAecEnabled(bool enabled);
    void setBluetoothMode(bool enabled);

    // User audio management (public interface)
    void addUserAudio(uint32_t userId, const int16_t* samples, size_t frames, int64_t sequence) override;
    void removeUser(uint32_t userId) override;
    void notifyUserTalkingEnded(uint32_t userId) override;
    bool startMixedPlayback() override;
    uint64_t getPlaybackCallbackCount() const override;

private:
    bool setupAudioSession();
    bool setupAudioUnits();
    void cleanupAudioUnits();
    void initResamplers();
    void initPreprocessor();
    void setThreadPriority();

    // Audio callbacks
    static OSStatus captureCallback(void* inRefCon,
                                    AudioUnitRenderActionFlags* ioActionFlags,
                                    const AudioTimeStamp* inTimeStamp,
                                    UInt32 inBusNumber,
                                    UInt32 inNumberFrames,
                                    AudioBufferList* ioData);

    static OSStatus playbackCallback(void* inRefCon,
                                     AudioUnitRenderActionFlags* ioActionFlags,
                                     const AudioTimeStamp* inTimeStamp,
                                     UInt32 inBusNumber,
                                     UInt32 inNumberFrames,
                                     AudioBufferList* ioData);

    void processCapturedAudio(int16_t* data, size_t frames);
    void processPlaybackAudio(int16_t* data, size_t frames);

    // Configuration
    Config config_;
    bool bluetoothMode_{false};
    bool aecEnabled_{false};
    bool preprocessingEnabled_{false};  // DISABLED: Speex-iOS doesn't support AGC/Denoise/Dereverb
    int inputDeviceSampleRate_{kOpusSampleRate};
    int outputDeviceSampleRate_{kOpusSampleRate};

    // Audio Units
    AudioComponentInstance audioUnit_{nullptr};

    // State
    std::atomic<bool> capturing_{false};
    std::atomic<bool> playing_{false};
    std::atomic<bool> voiceDetected_{false};
    std::atomic<float> inputLevel_{0.0f};

    // Callbacks (atomic for lock-free access in audio thread)
    std::atomic<AudioCallback*> captureCallbackPtr_{nullptr};
    std::atomic<PlaybackCallback*> playbackCallbackPtr_{nullptr};
    std::unique_ptr<AudioCallback> captureCallbackStorage_;
    std::unique_ptr<PlaybackCallback> playbackCallbackStorage_;
    std::mutex callbackSetupMutex_;  // Only for setup/teardown, NOT in audio thread

    // Buffers
    AudioBufferList* captureBufferList_{nullptr};
    std::vector<int16_t> resampleInputBuffer_;
    std::vector<int16_t> resampleOutputBuffer_;
    std::vector<int16_t> preprocessBuffer_;
    std::vector<float> userMixBuffer_;
    std::vector<int16_t> playbackOutputBuffer_;

    // Speex DSP
    std::unique_ptr<SpeexPreprocessor> preprocessor_;
    std::unique_ptr<SpeexResampler> inputResampler_;   // device -> Opus
    std::unique_ptr<SpeexResampler> outputResampler_;  // Opus -> device

    // VAD
    std::unique_ptr<VoiceActivityDetector> vad_;

    // User audio buffers (use try_lock in audio thread to avoid blocking)
    std::mutex userBuffersMutex_;
    std::map<uint32_t, std::unique_ptr<UserAudioBuffer>> userBuffers_;

    // Pre-allocated buffer for playback mixing (avoid allocation in audio callback)
    std::vector<float> perUserBuffer_;

    // Playback heartbeat counter (incremented in each playback callback)
    std::atomic<uint64_t> playbackCallbackCount_{0};

    // Float mixer
    std::unique_ptr<FloatMixer> mixer_;

    // Crossfade
    std::unique_ptr<Crossfade> crossfade_;
};

// Factory
std::unique_ptr<AudioEngine> AudioEngine::create(const Config& config) {
    return std::make_unique<AudioEngineImpl>(config);
}

AudioEngineImpl::AudioEngineImpl(const Config& config)
    : config_(config)
    , resampleInputBuffer_(config.framesPerBuffer * 3)    // Extra space for resampling
    , resampleOutputBuffer_(config.framesPerBuffer * 3)
    , preprocessBuffer_(kOpusFrameSize)
    , userMixBuffer_(kOpusFrameSize)
    , playbackOutputBuffer_(config.framesPerBuffer * 3)
    , perUserBuffer_(kOpusFrameSize) {

    // Initialize mixer and crossfade
    mixer_ = FloatMixer::create(kOpusFrameSize);
    crossfade_ = Crossfade::create(kOpusFrameSize);

    // Initialize VAD
    VoiceActivityDetector::Config vadConfig;
    vadConfig.sampleRate = kOpusSampleRate;
    vadConfig.threshold = 0.01f;
    vadConfig.holdTimeMs = 300;
    vad_ = VoiceActivityDetector::create(vadConfig);

    // Initialize Speex preprocessor (only if enabled)
    if (preprocessingEnabled_) {
        initPreprocessor();
    }

    setupAudioSession();
}

AudioEngineImpl::~AudioEngineImpl() {
    stopCapture();
    stopPlayback();
    cleanupAudioUnits();
}

void AudioEngineImpl::initPreprocessor() {
    SpeexPreprocessor::Config config;
    config.sampleRate = kOpusSampleRate;
    config.frameSize = kOpusFrameSize;
    config.denoiseEnabled = true;
    config.denoiseLevel = -30;
    config.agcEnabled = true;
    config.agcTarget = 30000;      // Like Mumla
    config.agcMaxGain = 30;
    config.dereverbEnabled = true;
    config.vadEnabled = false;     // We use our own VAD

    preprocessor_ = SpeexPreprocessor::create(config);
}

void AudioEngineImpl::initResamplers() {
    NSLog(@"[AudioEngine] initResamplers: input=%d->%d, output=%d->%d",
          inputDeviceSampleRate_, kOpusSampleRate,
          kOpusSampleRate, outputDeviceSampleRate_);

    // Only create resamplers if needed (Bluetooth mode)
    if (inputDeviceSampleRate_ != kOpusSampleRate) {
        NSLog(@"[AudioEngine] Creating input resampler %d -> %d", inputDeviceSampleRate_, kOpusSampleRate);
        inputResampler_ = SpeexResampler::create(
            1,  // Mono
            inputDeviceSampleRate_,
            kOpusSampleRate,
            SpeexResampler::Quality::VoIP
        );
    } else {
        NSLog(@"[AudioEngine] No input resampler needed (already at 48kHz)");
        inputResampler_.reset();
    }

    if (outputDeviceSampleRate_ != kOpusSampleRate) {
        NSLog(@"[AudioEngine] Creating output resampler %d -> %d", kOpusSampleRate, outputDeviceSampleRate_);
        outputResampler_ = SpeexResampler::create(
            1,  // Mono
            kOpusSampleRate,
            outputDeviceSampleRate_,
            SpeexResampler::Quality::VoIP
        );
    } else {
        NSLog(@"[AudioEngine] No output resampler needed (already at 48kHz)");
        outputResampler_.reset();
    }
}

bool AudioEngineImpl::setupAudioSession() {
#if TARGET_OS_IPHONE
    @autoreleasepool {
        // Audio session is already configured in AppDelegate with voiceChat mode
        // Just read the actual values here
        AVAudioSession* session = [AVAudioSession sharedInstance];

        // Get actual sample rate (AppDelegate sets 48000)
        inputDeviceSampleRate_ = static_cast<int>(session.sampleRate);
        outputDeviceSampleRate_ = static_cast<int>(session.sampleRate);

        NSLog(@"[AudioEngine] Using existing audio session:");
        NSLog(@"[AudioEngine]   - sampleRate=%d", inputDeviceSampleRate_);
        NSLog(@"[AudioEngine]   - ioBufferDuration=%.4f", session.IOBufferDuration);
        NSLog(@"[AudioEngine]   - inputChannels=%d", (int)session.inputNumberOfChannels);
        NSLog(@"[AudioEngine]   - outputChannels=%d", (int)session.outputNumberOfChannels);
        NSLog(@"[AudioEngine]   - category=%@", session.category);
        NSLog(@"[AudioEngine]   - mode=%@", session.mode);

        return true;
    }
#else
    return true;
#endif
}

bool AudioEngineImpl::setupAudioUnits() {
    NSLog(@"[AudioEngine] setupAudioUnits: deviceSampleRate=%d", inputDeviceSampleRate_);
    OSStatus status;

    // Audio component description
    AudioComponentDescription desc;
    desc.componentType = kAudioUnitType_Output;
#if TARGET_OS_IPHONE
    desc.componentSubType = kAudioUnitSubType_RemoteIO;
#else
    desc.componentSubType = kAudioUnitSubType_HALOutput;
#endif
    desc.componentManufacturer = kAudioUnitManufacturer_Apple;
    desc.componentFlags = 0;
    desc.componentFlagsMask = 0;

    AudioComponent component = AudioComponentFindNext(nullptr, &desc);
    if (!component) {
        return false;
    }

    status = AudioComponentInstanceNew(component, &audioUnit_);
    if (status != noErr) {
        return false;
    }

    // Enable input
    UInt32 enableInput = 1;
    status = AudioUnitSetProperty(audioUnit_,
                                  kAudioOutputUnitProperty_EnableIO,
                                  kAudioUnitScope_Input,
                                  1,
                                  &enableInput,
                                  sizeof(enableInput));
    if (status != noErr) {
        return false;
    }

    // Set audio format
    AudioStreamBasicDescription audioFormat;
    audioFormat.mSampleRate = inputDeviceSampleRate_;
    audioFormat.mFormatID = kAudioFormatLinearPCM;
    audioFormat.mFormatFlags = kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked;
    audioFormat.mBytesPerPacket = 2;
    audioFormat.mFramesPerPacket = 1;
    audioFormat.mBytesPerFrame = 2;
    audioFormat.mChannelsPerFrame = 1;
    audioFormat.mBitsPerChannel = 16;

    // Set format for capture output (from mic)
    status = AudioUnitSetProperty(audioUnit_,
                                  kAudioUnitProperty_StreamFormat,
                                  kAudioUnitScope_Output,
                                  1,
                                  &audioFormat,
                                  sizeof(audioFormat));
    if (status != noErr) {
        return false;
    }

    // Set format for playback input (to speaker)
    audioFormat.mSampleRate = outputDeviceSampleRate_;
    status = AudioUnitSetProperty(audioUnit_,
                                  kAudioUnitProperty_StreamFormat,
                                  kAudioUnitScope_Input,
                                  0,
                                  &audioFormat,
                                  sizeof(audioFormat));
    if (status != noErr) {
        return false;
    }

    // Set capture callback
    AURenderCallbackStruct captureCallbackStruct;
    captureCallbackStruct.inputProc = AudioEngineImpl::captureCallback;
    captureCallbackStruct.inputProcRefCon = this;

    status = AudioUnitSetProperty(audioUnit_,
                                  kAudioOutputUnitProperty_SetInputCallback,
                                  kAudioUnitScope_Global,
                                  0,
                                  &captureCallbackStruct,
                                  sizeof(captureCallbackStruct));
    if (status != noErr) {
        return false;
    }

    // Set playback callback
    AURenderCallbackStruct playbackCallbackStruct;
    playbackCallbackStruct.inputProc = AudioEngineImpl::playbackCallback;
    playbackCallbackStruct.inputProcRefCon = this;

    status = AudioUnitSetProperty(audioUnit_,
                                  kAudioUnitProperty_SetRenderCallback,
                                  kAudioUnitScope_Input,
                                  0,
                                  &playbackCallbackStruct,
                                  sizeof(playbackCallbackStruct));
    if (status != noErr) {
        return false;
    }

    // Allocate capture buffer - use larger size to handle variable callback sizes
    // iOS audio callbacks can return 512, 1024, or more frames depending on system state
    constexpr UInt32 kMaxCaptureFrames = 4096;
    UInt32 bufferSize = kMaxCaptureFrames * sizeof(int16_t);
    captureBufferList_ = static_cast<AudioBufferList*>(malloc(sizeof(AudioBufferList)));
    captureBufferList_->mNumberBuffers = 1;
    captureBufferList_->mBuffers[0].mNumberChannels = 1;
    captureBufferList_->mBuffers[0].mDataByteSize = bufferSize;
    captureBufferList_->mBuffers[0].mData = malloc(bufferSize);

    // Initialize audio unit
    status = AudioUnitInitialize(audioUnit_);
    if (status != noErr) {
        return false;
    }

    // Initialize resamplers based on actual device sample rate
    initResamplers();

    return true;
}

void AudioEngineImpl::cleanupAudioUnits() {
    if (audioUnit_) {
        AudioUnitUninitialize(audioUnit_);
        AudioComponentInstanceDispose(audioUnit_);
        audioUnit_ = nullptr;
    }

    if (captureBufferList_) {
        if (captureBufferList_->mBuffers[0].mData) {
            free(captureBufferList_->mBuffers[0].mData);
        }
        free(captureBufferList_);
        captureBufferList_ = nullptr;
    }
}

void AudioEngineImpl::setThreadPriority() {
#if TARGET_OS_IPHONE
    // Set thread priority to real-time audio priority
    // Similar to Android's THREAD_PRIORITY_URGENT_AUDIO
    pthread_t thread = pthread_self();
    struct sched_param param;
    param.sched_priority = sched_get_priority_max(SCHED_FIFO);
    pthread_setschedparam(thread, SCHED_FIFO, &param);
#endif
}

bool AudioEngineImpl::startCapture(AudioCallback callback) {
    NSLog(@"[AudioEngine] startCapture called, capturing_=%d", capturing_.load());

    if (capturing_) {
        NSLog(@"[AudioEngine] Already capturing, returning false");
        return false;
    }

    {
        std::lock_guard<std::mutex> lock(callbackSetupMutex_);
        captureCallbackStorage_ = std::make_unique<AudioCallback>(std::move(callback));
        captureCallbackPtr_.store(captureCallbackStorage_.get(), std::memory_order_release);
    }

    if (!audioUnit_) {
        NSLog(@"[AudioEngine] Setting up audio units...");
        if (!setupAudioUnits()) {
            NSLog(@"[AudioEngine] ERROR: setupAudioUnits failed!");
            return false;
        }
        NSLog(@"[AudioEngine] Audio units setup complete");
    }

    OSStatus status = AudioOutputUnitStart(audioUnit_);
    if (status != noErr) {
        return false;
    }

    capturing_ = true;
    return true;
}

void AudioEngineImpl::stopCapture() {
    if (!capturing_) {
        return;
    }

    capturing_ = false;

    {
        std::lock_guard<std::mutex> lock(callbackSetupMutex_);
        captureCallbackPtr_.store(nullptr, std::memory_order_release);
        // Small delay to ensure audio thread sees the null pointer
        std::this_thread::sleep_for(std::chrono::milliseconds(20));
        captureCallbackStorage_.reset();
    }
}

bool AudioEngineImpl::isCapturing() const {
    return capturing_;
}

bool AudioEngineImpl::startPlayback(PlaybackCallback callback) {
    if (playing_) {
        return false;
    }

    {
        std::lock_guard<std::mutex> lock(callbackSetupMutex_);
        playbackCallbackStorage_ = std::make_unique<PlaybackCallback>(std::move(callback));
        playbackCallbackPtr_.store(playbackCallbackStorage_.get(), std::memory_order_release);
    }

    if (!audioUnit_) {
        if (!setupAudioUnits()) {
            return false;
        }
        OSStatus status = AudioOutputUnitStart(audioUnit_);
        if (status != noErr) {
            return false;
        }
    }

    playing_ = true;
    return true;
}

void AudioEngineImpl::stopPlayback() {
    if (!playing_) {
        return;
    }

    playing_ = false;

    {
        std::lock_guard<std::mutex> lock(callbackSetupMutex_);
        playbackCallbackPtr_.store(nullptr, std::memory_order_release);
        // Small delay to ensure audio thread sees the null pointer
        std::this_thread::sleep_for(std::chrono::milliseconds(20));
        playbackCallbackStorage_.reset();
    }
}

bool AudioEngineImpl::isPlaying() const {
    return playing_;
}

void AudioEngineImpl::setVadEnabled(bool enabled) {
    // VAD is always running, this controls whether we report it
}

void AudioEngineImpl::setVadThreshold(float threshold) {
    if (vad_) {
        vad_->setThreshold(threshold);
    }
}

bool AudioEngineImpl::isVoiceDetected() const {
    return voiceDetected_;
}

float AudioEngineImpl::getInputLevel() const {
    return inputLevel_;
}

void AudioEngineImpl::setPreprocessingEnabled(bool enabled) {
    preprocessingEnabled_ = enabled;
}

void AudioEngineImpl::setAecEnabled(bool enabled) {
    aecEnabled_ = enabled;
    setupAudioSession();  // Reconfigure with new mode
}

void AudioEngineImpl::setBluetoothMode(bool enabled) {
    bluetoothMode_ = enabled;
    setupAudioSession();
    initResamplers();
}

// User audio management
void AudioEngineImpl::addUserAudio(uint32_t userId, const int16_t* samples, size_t frames, int64_t sequence) {
    std::lock_guard<std::mutex> lock(userBuffersMutex_);

    auto it = userBuffers_.find(userId);
    if (it == userBuffers_.end()) {
        // Create new buffer for user
        UserAudioBuffer::Config config;
        config.sampleRate = kOpusSampleRate;
        config.frameSize = kOpusFrameSize;
        config.minBufferMs = 60;
        config.maxBufferMs = 200;
        config.targetBufferMs = 80;

        userBuffers_[userId] = UserAudioBuffer::create(userId, config);
        it = userBuffers_.find(userId);
    }

    it->second->addSamples(samples, frames, sequence, false);
}

void AudioEngineImpl::removeUser(uint32_t userId) {
    std::lock_guard<std::mutex> lock(userBuffersMutex_);
    userBuffers_.erase(userId);
}

void AudioEngineImpl::notifyUserTalkingEnded(uint32_t userId) {
    std::lock_guard<std::mutex> lock(userBuffersMutex_);
    auto it = userBuffers_.find(userId);
    if (it != userBuffers_.end()) {
        it->second->notifyTalkingEnded();
    }
}

bool AudioEngineImpl::startMixedPlayback() {
    if (playing_) {
        return true;  // Already playing
    }

    if (!audioUnit_) {
        if (!setupAudioUnits()) {
            return false;
        }
        OSStatus status = AudioOutputUnitStart(audioUnit_);
        if (status != noErr) {
            return false;
        }
    }

    playing_ = true;
    NSLog(@"[AudioEngine] Started mixed playback");
    return true;
}

uint64_t AudioEngineImpl::getPlaybackCallbackCount() const {
    return playbackCallbackCount_.load(std::memory_order_relaxed);
}

// Static capture callback
OSStatus AudioEngineImpl::captureCallback(void* inRefCon,
                                          AudioUnitRenderActionFlags* ioActionFlags,
                                          const AudioTimeStamp* inTimeStamp,
                                          UInt32 inBusNumber,
                                          UInt32 inNumberFrames,
                                          AudioBufferList* ioData) {
    AudioEngineImpl* engine = static_cast<AudioEngineImpl*>(inRefCon);

    if (!engine->capturing_) {
        return noErr;
    }

    // Safety check: ensure we don't exceed buffer capacity
    constexpr UInt32 kMaxCaptureFrames = 4096;
    if (inNumberFrames > kMaxCaptureFrames) {
        NSLog(@"[AudioEngine] WARNING: inNumberFrames (%u) exceeds buffer size, clamping", inNumberFrames);
        inNumberFrames = kMaxCaptureFrames;
    }

    // Render input into our buffer
    engine->captureBufferList_->mBuffers[0].mDataByteSize = inNumberFrames * sizeof(int16_t);

    OSStatus status = AudioUnitRender(engine->audioUnit_,
                                      ioActionFlags,
                                      inTimeStamp,
                                      1,
                                      inNumberFrames,
                                      engine->captureBufferList_);

    if (status == noErr) {
        int16_t* data = static_cast<int16_t*>(engine->captureBufferList_->mBuffers[0].mData);
        engine->processCapturedAudio(data, inNumberFrames);
    } else {
        NSLog(@"[AudioEngine] ERROR: AudioUnitRender failed with status %d", (int)status);
    }

    return status;
}

// Static playback callback
OSStatus AudioEngineImpl::playbackCallback(void* inRefCon,
                                           AudioUnitRenderActionFlags* ioActionFlags,
                                           const AudioTimeStamp* inTimeStamp,
                                           UInt32 inBusNumber,
                                           UInt32 inNumberFrames,
                                           AudioBufferList* ioData) {
    AudioEngineImpl* engine = static_cast<AudioEngineImpl*>(inRefCon);

    int16_t* data = static_cast<int16_t*>(ioData->mBuffers[0].mData);
    size_t frames = inNumberFrames;

    // Zero the buffer first
    memset(data, 0, frames * sizeof(int16_t));

    // Always increment heartbeat counter (even when not playing)
    engine->playbackCallbackCount_.fetch_add(1, std::memory_order_relaxed);

    if (!engine->playing_) {
        return noErr;
    }

    engine->processPlaybackAudio(data, frames);

    return noErr;
}

void AudioEngineImpl::processCapturedAudio(int16_t* data, size_t frames) {
    int16_t* processBuffer = data;
    size_t processFrames = frames;

    // Step 1: Resample if needed (Bluetooth 16kHz -> Opus 48kHz)
    if (inputResampler_) {
        size_t inputFrames = frames;
        size_t outputFrames = resampleInputBuffer_.size();

        inputResampler_->process(data, inputFrames,
                                  resampleInputBuffer_.data(), outputFrames);

        processBuffer = resampleInputBuffer_.data();
        processFrames = outputFrames;
    }

    // Step 2: Apply Speex preprocessing (Denoise, AGC, Dereverb)
    if (preprocessingEnabled_ && preprocessor_) {
        // Process in Opus frame sizes
        size_t offset = 0;
        while (offset + kOpusFrameSize <= processFrames) {
            preprocessor_->process(processBuffer + offset, kOpusFrameSize);
            offset += kOpusFrameSize;
        }

        inputLevel_ = preprocessor_->getInputLevel();
    } else {
        // Calculate input level manually
        double sum = 0.0;
        for (size_t i = 0; i < processFrames; i++) {
            double normalized = processBuffer[i] / 32768.0;
            sum += normalized * normalized;
        }
        inputLevel_ = static_cast<float>(std::sqrt(sum / processFrames));
    }

    // Step 3: Voice Activity Detection
    if (vad_) {
        voiceDetected_ = vad_->process(processBuffer, processFrames);
    }

    // Step 4: Call capture callback with processed audio (lock-free)
    AudioCallback* callback = captureCallbackPtr_.load(std::memory_order_acquire);
    if (callback) {
        (*callback)(processBuffer, processFrames);
    }
}

void AudioEngineImpl::processPlaybackAudio(int16_t* data, size_t frames) {
    // Step 1: Mix all user audio buffers (float mixing)
    mixer_->clear();

    {
        std::lock_guard<std::mutex> lock(userBuffersMutex_);
        for (auto& [userId, buffer] : userBuffers_) {
            if (buffer->isActive()) {
                // Use pre-allocated buffer instead of creating new vector
                size_t readFrames = buffer->readFloat(perUserBuffer_.data(), kOpusFrameSize);
                if (readFrames > 0) {
                    mixer_->add(perUserBuffer_.data(), readFrames);
                }
            }
        }
    }

    // Step 2: Get mixed result as int16
    mixer_->getMixed(playbackOutputBuffer_.data(), kOpusFrameSize);

    // Step 3: Resample if needed (Opus 48kHz -> Bluetooth 16kHz)
    if (outputResampler_) {
        size_t inputFrames = kOpusFrameSize;
        size_t outputFrames = frames;

        outputResampler_->process(playbackOutputBuffer_.data(), inputFrames,
                                   data, outputFrames);
    } else {
        // Copy directly
        size_t copyFrames = std::min(frames, static_cast<size_t>(kOpusFrameSize));
        memcpy(data, playbackOutputBuffer_.data(), copyFrames * sizeof(int16_t));
    }

    // Step 4: Request more audio data if callback is set (lock-free)
    PlaybackCallback* callback = playbackCallbackPtr_.load(std::memory_order_acquire);
    if (callback) {
        // The playback callback can add more audio to user buffers
        (*callback)(data, frames);
    }
}

}  // namespace sayses
