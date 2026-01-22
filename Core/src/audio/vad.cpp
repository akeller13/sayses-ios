/**
 * Voice Activity Detection Implementation
 * Energy-based VAD with smoothing and hold time
 */

#include "vad.h"

#include <cmath>
#include <algorithm>
#include <atomic>

namespace sayses {

class VoiceActivityDetectorImpl : public VoiceActivityDetector {
public:
    explicit VoiceActivityDetectorImpl(const Config& config);
    ~VoiceActivityDetectorImpl() override = default;

    bool process(const int16_t* samples, size_t frames) override;
    bool isVoiceDetected() const override;
    float getSignalLevel() const override;
    void setThreshold(float threshold) override;
    float getThreshold() const override;
    void reset() override;

private:
    float calculateRMS(const int16_t* samples, size_t frames);
    float calculatePeak(const int16_t* samples, size_t frames);

    Config config_;

    // State
    std::atomic<bool> voiceDetected_{false};
    std::atomic<float> signalLevel_{0.0f};
    std::atomic<float> threshold_;

    // Timing
    int holdSamples_;
    int attackSamples_;
    int holdCounter_{0};
    int attackCounter_{0};

    // Smoothing
    float smoothedLevel_{0.0f};
    static constexpr float kSmoothingFactor = 0.1f;
};

// Factory
std::unique_ptr<VoiceActivityDetector> VoiceActivityDetector::create(const Config& config) {
    return std::make_unique<VoiceActivityDetectorImpl>(config);
}

VoiceActivityDetectorImpl::VoiceActivityDetectorImpl(const Config& config)
    : config_(config)
    , threshold_(config.threshold) {

    // Convert milliseconds to samples
    holdSamples_ = (config_.holdTimeMs * config_.sampleRate) / 1000;
    attackSamples_ = (config_.attackTimeMs * config_.sampleRate) / 1000;
}

bool VoiceActivityDetectorImpl::process(const int16_t* samples, size_t frames) {
    // Calculate RMS energy
    float rms = calculateRMS(samples, frames);

    // Smooth the level
    smoothedLevel_ = smoothedLevel_ * (1.0f - kSmoothingFactor) + rms * kSmoothingFactor;
    signalLevel_ = smoothedLevel_;

    float currentThreshold = threshold_.load();

    // Check if above threshold
    bool aboveThreshold = smoothedLevel_ > currentThreshold &&
                          smoothedLevel_ > config_.minSignalLevel;

    if (aboveThreshold) {
        // Count attack time
        attackCounter_ += static_cast<int>(frames);

        if (attackCounter_ >= attackSamples_) {
            // Voice confirmed
            voiceDetected_ = true;
            holdCounter_ = holdSamples_;
        }
    } else {
        // Reset attack counter
        attackCounter_ = 0;

        // Decrement hold counter
        if (holdCounter_ > 0) {
            holdCounter_ -= static_cast<int>(frames);
            if (holdCounter_ <= 0) {
                voiceDetected_ = false;
                holdCounter_ = 0;
            }
        }
    }

    return voiceDetected_;
}

bool VoiceActivityDetectorImpl::isVoiceDetected() const {
    return voiceDetected_;
}

float VoiceActivityDetectorImpl::getSignalLevel() const {
    return signalLevel_;
}

void VoiceActivityDetectorImpl::setThreshold(float threshold) {
    threshold_ = std::max(0.0f, std::min(1.0f, threshold));
}

float VoiceActivityDetectorImpl::getThreshold() const {
    return threshold_;
}

void VoiceActivityDetectorImpl::reset() {
    voiceDetected_ = false;
    signalLevel_ = 0.0f;
    smoothedLevel_ = 0.0f;
    holdCounter_ = 0;
    attackCounter_ = 0;
}

float VoiceActivityDetectorImpl::calculateRMS(const int16_t* samples, size_t frames) {
    if (frames == 0) return 0.0f;

    double sum = 0.0;
    for (size_t i = 0; i < frames; i++) {
        double normalized = samples[i] / 32768.0;
        sum += normalized * normalized;
    }

    return static_cast<float>(std::sqrt(sum / frames));
}

float VoiceActivityDetectorImpl::calculatePeak(const int16_t* samples, size_t frames) {
    if (frames == 0) return 0.0f;

    int16_t peak = 0;
    for (size_t i = 0; i < frames; i++) {
        int16_t absVal = samples[i] >= 0 ? samples[i] : -samples[i];
        if (absVal > peak) {
            peak = absVal;
        }
    }

    return peak / 32768.0f;
}

}  // namespace sayses
