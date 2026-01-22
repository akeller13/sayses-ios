/**
 * User Audio Buffer Implementation
 * Per-user audio handling with float processing and crossfade
 * Based on Mumla/Humla implementation
 */

#include "user_audio_buffer.h"

#include <cmath>
#include <algorithm>
#include <chrono>

#ifndef M_PI
#define M_PI 3.14159265358979323846
#endif

namespace sayses {

// ============================================================================
// Crossfade Implementation
// ============================================================================

class CrossfadeImpl : public Crossfade {
public:
    explicit CrossfadeImpl(int frameSize);

    void applyFadeIn(float* samples, size_t frames) override;
    void applyFadeOut(float* samples, size_t frames) override;
    int getFadeLength() const override { return fadeLength_; }

private:
    int fadeLength_;
    std::vector<float> fadeIn_;
    std::vector<float> fadeOut_;
};

std::unique_ptr<Crossfade> Crossfade::create(int frameSize) {
    return std::make_unique<CrossfadeImpl>(frameSize);
}

CrossfadeImpl::CrossfadeImpl(int frameSize)
    : fadeLength_(frameSize) {

    fadeIn_.resize(fadeLength_);
    fadeOut_.resize(fadeLength_);

    // Sine-wave crossfade (like Mumla)
    float mul = static_cast<float>(M_PI) / (2.0f * fadeLength_);
    for (int i = 0; i < fadeLength_; ++i) {
        fadeIn_[i] = std::sin(static_cast<float>(i) * mul);
        fadeOut_[i] = std::sin(static_cast<float>(fadeLength_ - i - 1) * mul);
    }
}

void CrossfadeImpl::applyFadeIn(float* samples, size_t frames) {
    size_t applyFrames = std::min(frames, static_cast<size_t>(fadeLength_));
    for (size_t i = 0; i < applyFrames; ++i) {
        samples[i] *= fadeIn_[i];
    }
}

void CrossfadeImpl::applyFadeOut(float* samples, size_t frames) {
    size_t applyFrames = std::min(frames, static_cast<size_t>(fadeLength_));
    size_t startIdx = frames - applyFrames;
    for (size_t i = 0; i < applyFrames; ++i) {
        samples[startIdx + i] *= fadeOut_[fadeLength_ - applyFrames + i];
    }
}

// ============================================================================
// FloatMixer Implementation
// ============================================================================

class FloatMixerImpl : public FloatMixer {
public:
    explicit FloatMixerImpl(int frameSize);

    void clear() override;
    void add(const float* samples, size_t frames) override;
    void getMixed(int16_t* output, size_t frames) override;
    const float* getFloatBuffer() const override { return mixBuffer_.data(); }

private:
    int frameSize_;
    std::vector<float> mixBuffer_;
};

std::unique_ptr<FloatMixer> FloatMixer::create(int frameSize) {
    return std::make_unique<FloatMixerImpl>(frameSize);
}

FloatMixerImpl::FloatMixerImpl(int frameSize)
    : frameSize_(frameSize)
    , mixBuffer_(frameSize, 0.0f) {
}

void FloatMixerImpl::clear() {
    std::fill(mixBuffer_.begin(), mixBuffer_.end(), 0.0f);
}

void FloatMixerImpl::add(const float* samples, size_t frames) {
    size_t addFrames = std::min(frames, static_cast<size_t>(frameSize_));
    for (size_t i = 0; i < addFrames; ++i) {
        mixBuffer_[i] += samples[i];
    }
}

void FloatMixerImpl::getMixed(int16_t* output, size_t frames) {
    size_t outFrames = std::min(frames, static_cast<size_t>(frameSize_));
    for (size_t i = 0; i < outFrames; ++i) {
        float sample = mixBuffer_[i];

        // Soft clipping
        if (sample > 1.0f) sample = 1.0f;
        if (sample < -1.0f) sample = -1.0f;

        output[i] = static_cast<int16_t>(sample * 32767.0f);
    }
}

// ============================================================================
// UserAudioBuffer Implementation
// ============================================================================

class UserAudioBufferImpl : public UserAudioBuffer {
public:
    UserAudioBufferImpl(uint32_t userId, const Config& config);

    uint32_t getUserId() const override { return userId_; }
    void addSamples(const int16_t* samples, size_t frames,
                    int64_t sequence, bool isPLC) override;
    size_t readFloat(float* output, size_t frames) override;
    bool isReady() const override;
    bool isActive() const override;
    Stats getStats() const override;
    void reset() override;
    void notifyTalkingEnded() override;

private:
    void convertToFloat(const int16_t* input, size_t frames);
    void detectSequenceGap(int64_t sequence);

    uint32_t userId_;
    Config config_;
    std::unique_ptr<Crossfade> crossfade_;

    mutable std::mutex mutex_;

    // Float buffer (ring buffer)
    std::deque<float> buffer_;
    size_t minBufferSize_;
    size_t maxBufferSize_;

    // Sequence tracking
    int64_t lastSequence_{-1};
    int64_t sequenceIncrement_{1};

    // State
    bool playbackStarted_{false};
    bool needsFadeIn_{true};
    bool needsFadeOut_{false};
    std::chrono::steady_clock::time_point lastPacketTime_;

    // Statistics
    Stats stats_;
};

std::unique_ptr<UserAudioBuffer> UserAudioBuffer::create(uint32_t userId, const Config& config) {
    return std::make_unique<UserAudioBufferImpl>(userId, config);
}

UserAudioBufferImpl::UserAudioBufferImpl(uint32_t userId, const Config& config)
    : userId_(userId)
    , config_(config)
    , crossfade_(Crossfade::create(config.frameSize)) {

    // Calculate buffer sizes in samples
    minBufferSize_ = (config_.minBufferMs * config_.sampleRate) / 1000;
    maxBufferSize_ = (config_.maxBufferMs * config_.sampleRate) / 1000;

    lastPacketTime_ = std::chrono::steady_clock::now();
}

void UserAudioBufferImpl::addSamples(const int16_t* samples, size_t frames,
                                      int64_t sequence, bool isPLC) {
    std::lock_guard<std::mutex> lock(mutex_);

    auto now = std::chrono::steady_clock::now();

    // Track packet timing
    if (lastSequence_ >= 0) {
        auto gapMs = std::chrono::duration_cast<std::chrono::milliseconds>(
            now - lastPacketTime_
        ).count();
        if (gapMs > stats_.maxGapMs) {
            stats_.maxGapMs = static_cast<int>(gapMs);
        }
    }
    lastPacketTime_ = now;

    // Detect sequence gaps
    detectSequenceGap(sequence);

    stats_.packetsReceived++;
    if (isPLC) {
        stats_.plcFrames++;
    } else {
        stats_.packetsDecoded++;
    }
    stats_.lastSequence = sequence;
    lastSequence_ = sequence;

    // Convert and add to buffer
    convertToFloat(samples, frames);

    // Handle buffer overflow
    while (buffer_.size() > maxBufferSize_) {
        buffer_.pop_front();
        stats_.bufferOverruns++;
    }

    stats_.currentBufferSize = buffer_.size();
}

void UserAudioBufferImpl::convertToFloat(const int16_t* input, size_t frames) {
    // Convert int16 to float and add to buffer
    for (size_t i = 0; i < frames; ++i) {
        float sample = input[i] / 32768.0f;
        buffer_.push_back(sample);
    }
}

void UserAudioBufferImpl::detectSequenceGap(int64_t sequence) {
    if (lastSequence_ < 0) {
        // First packet
        return;
    }

    int64_t expectedSequence = lastSequence_ + sequenceIncrement_;
    if (sequence != expectedSequence) {
        int64_t gap = sequence - lastSequence_;
        if (gap > sequenceIncrement_) {
            stats_.sequenceGaps++;
        }

        // Update sequence increment estimate
        if (gap > 0 && gap < 100) {
            sequenceIncrement_ = gap;
        }
    }
}

size_t UserAudioBufferImpl::readFloat(float* output, size_t frames) {
    std::lock_guard<std::mutex> lock(mutex_);

    // Check if we should start playback
    if (!playbackStarted_) {
        if (buffer_.size() >= minBufferSize_) {
            playbackStarted_ = true;
            needsFadeIn_ = true;
        } else {
            // Not ready - output silence
            std::fill(output, output + frames, 0.0f);
            return 0;
        }
    }

    // Check for buffer underrun
    if (buffer_.empty()) {
        playbackStarted_ = false;
        needsFadeIn_ = true;
        stats_.bufferUnderruns++;
        std::fill(output, output + frames, 0.0f);
        return 0;
    }

    // Read from buffer
    size_t readFrames = std::min(frames, buffer_.size());
    for (size_t i = 0; i < readFrames; ++i) {
        output[i] = buffer_.front();
        buffer_.pop_front();
    }

    // Pad with zeros if needed
    if (readFrames < frames) {
        std::fill(output + readFrames, output + frames, 0.0f);
    }

    // Apply fade-in if needed
    if (needsFadeIn_) {
        crossfade_->applyFadeIn(output, readFrames);
        needsFadeIn_ = false;
        stats_.fadeIns++;
    }

    // Apply fade-out if user stopped talking
    if (needsFadeOut_ && buffer_.empty()) {
        crossfade_->applyFadeOut(output, readFrames);
        needsFadeOut_ = false;
        stats_.fadeOuts++;
    }

    stats_.currentBufferSize = buffer_.size();
    return readFrames;
}

bool UserAudioBufferImpl::isReady() const {
    std::lock_guard<std::mutex> lock(mutex_);
    return buffer_.size() >= minBufferSize_;
}

bool UserAudioBufferImpl::isActive() const {
    std::lock_guard<std::mutex> lock(mutex_);
    return !buffer_.empty() || playbackStarted_;
}

UserAudioBuffer::Stats UserAudioBufferImpl::getStats() const {
    std::lock_guard<std::mutex> lock(mutex_);
    return stats_;
}

void UserAudioBufferImpl::reset() {
    std::lock_guard<std::mutex> lock(mutex_);

    buffer_.clear();
    lastSequence_ = -1;
    playbackStarted_ = false;
    needsFadeIn_ = true;
    needsFadeOut_ = false;
    stats_ = Stats{};
}

void UserAudioBufferImpl::notifyTalkingEnded() {
    std::lock_guard<std::mutex> lock(mutex_);
    needsFadeOut_ = true;
}

}  // namespace sayses
