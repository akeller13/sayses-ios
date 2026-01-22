#pragma once

#include <memory>
#include <cstdint>
#include <cstddef>

namespace sayses {

/**
 * Voice Activity Detection using signal energy analysis.
 */
class VoiceActivityDetector {
public:
    struct Config {
        int sampleRate = 48000;
        float threshold = 0.01f;          // Energy threshold (0.0 - 1.0)
        int holdTimeMs = 300;             // Time to hold voice state after detection
        int attackTimeMs = 10;            // Time to confirm voice onset
        float minSignalLevel = 0.001f;    // Minimum signal level to consider
    };

    /**
     * Create a voice activity detector.
     */
    static std::unique_ptr<VoiceActivityDetector> create(const Config& config);

    virtual ~VoiceActivityDetector() = default;

    /**
     * Process audio samples and detect voice activity.
     * @param samples PCM audio samples (16-bit)
     * @param frames Number of frames
     * @return true if voice is detected
     */
    virtual bool process(const int16_t* samples, size_t frames) = 0;

    /**
     * Check if voice is currently detected (includes hold time).
     */
    virtual bool isVoiceDetected() const = 0;

    /**
     * Get current signal level (0.0 - 1.0).
     */
    virtual float getSignalLevel() const = 0;

    /**
     * Set detection threshold.
     * @param threshold Value between 0.0 and 1.0
     */
    virtual void setThreshold(float threshold) = 0;

    /**
     * Get current threshold.
     */
    virtual float getThreshold() const = 0;

    /**
     * Reset detector state.
     */
    virtual void reset() = 0;

protected:
    VoiceActivityDetector() = default;
};

}  // namespace sayses
