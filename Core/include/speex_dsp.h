/**
 * Speex DSP Wrapper
 * Provides noise suppression, AGC, dereverb, and resampling
 */

#pragma once

#include <memory>
#include <cstdint>
#include <cstddef>

namespace sayses {

/**
 * Speex Preprocessor for audio enhancement.
 * Applies noise suppression, AGC, and dereverb to input audio.
 */
class SpeexPreprocessor {
public:
    struct Config {
        int sampleRate = 48000;
        int frameSize = 480;          // 10ms at 48kHz

        // Noise suppression
        bool denoiseEnabled = true;
        int denoiseLevel = -30;       // dB suppression

        // AGC (Automatic Gain Control)
        bool agcEnabled = true;
        int agcTarget = 30000;        // Target level (like Mumla)
        int agcMaxGain = 30;          // Max gain in dB

        // Dereverb
        bool dereverbEnabled = true;
        float dereverbLevel = 0.0f;
        float dereverbDecay = 0.0f;

        // VAD (internal)
        bool vadEnabled = false;      // We use our own VAD
    };

    /**
     * Create a Speex preprocessor instance.
     */
    static std::unique_ptr<SpeexPreprocessor> create(const Config& config);

    virtual ~SpeexPreprocessor() = default;

    /**
     * Process audio frame.
     * @param samples In/out audio samples (16-bit, modified in place)
     * @param frames Number of frames (must match frameSize)
     * @return VAD result if enabled, otherwise true
     */
    virtual bool process(int16_t* samples, size_t frames) = 0;

    /**
     * Get speech probability from last processed frame.
     * @return Probability 0.0 - 1.0
     */
    virtual float getSpeechProbability() const = 0;

    /**
     * Get current input level (after AGC).
     * @return Level 0.0 - 1.0
     */
    virtual float getInputLevel() const = 0;

    /**
     * Update configuration.
     */
    virtual void setDenoiseEnabled(bool enabled) = 0;
    virtual void setAgcEnabled(bool enabled) = 0;
    virtual void setDereverbEnabled(bool enabled) = 0;

    /**
     * Reset preprocessor state.
     */
    virtual void reset() = 0;

protected:
    SpeexPreprocessor() = default;
};

/**
 * Speex Resampler for sample rate conversion.
 * High-quality resampling for Bluetooth (16kHz) to Opus (48kHz) conversion.
 */
class SpeexResampler {
public:
    /**
     * Resampler quality levels.
     */
    enum class Quality {
        Fastest = 0,      // Lowest quality, fastest
        VoIP = 3,         // Good for voice (like Mumla)
        Default = 4,
        Desktop = 5,
        Best = 10         // Highest quality, slowest
    };

    /**
     * Create a resampler instance.
     * @param channels Number of channels (1 = mono)
     * @param inputRate Input sample rate (e.g., 16000)
     * @param outputRate Output sample rate (e.g., 48000)
     * @param quality Resampling quality
     */
    static std::unique_ptr<SpeexResampler> create(
        int channels,
        int inputRate,
        int outputRate,
        Quality quality = Quality::VoIP
    );

    virtual ~SpeexResampler() = default;

    /**
     * Resample audio data.
     * @param input Input samples
     * @param inputFrames Number of input frames (updated with consumed frames)
     * @param output Output buffer
     * @param outputFrames Maximum output frames (updated with produced frames)
     * @return true on success
     */
    virtual bool process(
        const int16_t* input, size_t& inputFrames,
        int16_t* output, size_t& outputFrames
    ) = 0;

    /**
     * Get the input/output ratio.
     */
    virtual float getRatio() const = 0;

    /**
     * Reset resampler state.
     */
    virtual void reset() = 0;

    /**
     * Get latency in input samples.
     */
    virtual int getLatency() const = 0;

protected:
    SpeexResampler() = default;
};

}  // namespace sayses
