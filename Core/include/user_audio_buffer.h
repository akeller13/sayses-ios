/**
 * User Audio Buffer
 * Per-user audio buffer with sequence tracking, float processing, and crossfade
 * Based on Mumla/Humla implementation
 */

#pragma once

#include <memory>
#include <cstdint>
#include <cstddef>
#include <vector>
#include <deque>
#include <mutex>

namespace sayses {

/**
 * Audio buffer for a single user's incoming audio.
 * Handles:
 * - Sequence-based packet ordering
 * - Adaptive jitter buffering
 * - Float sample storage for clipping-safe mixing
 * - Sine-wave crossfade for smooth transitions
 * - Packet loss concealment integration
 */
class UserAudioBuffer {
public:
    struct Config {
        int sampleRate = 48000;
        int frameSize = 480;           // 10ms at 48kHz
        int minBufferMs = 60;          // Minimum buffer before playback
        int maxBufferMs = 200;         // Maximum buffer size
        int targetBufferMs = 80;       // Target buffer size
    };

    struct Stats {
        uint32_t packetsReceived = 0;
        uint32_t packetsDecoded = 0;
        uint32_t sequenceGaps = 0;
        uint32_t plcFrames = 0;
        uint32_t bufferUnderruns = 0;
        uint32_t bufferOverruns = 0;
        uint32_t fadeIns = 0;
        uint32_t fadeOuts = 0;
        int64_t lastSequence = -1;
        size_t currentBufferSize = 0;
        int maxGapMs = 0;
    };

    /**
     * Create a user audio buffer.
     */
    static std::unique_ptr<UserAudioBuffer> create(uint32_t userId, const Config& config);

    virtual ~UserAudioBuffer() = default;

    /**
     * Get the user ID.
     */
    virtual uint32_t getUserId() const = 0;

    /**
     * Add decoded audio samples.
     * @param samples PCM samples (16-bit)
     * @param frames Number of frames
     * @param sequence Packet sequence number
     * @param isPLC true if this is PLC-generated audio
     */
    virtual void addSamples(const int16_t* samples, size_t frames,
                            int64_t sequence, bool isPLC = false) = 0;

    /**
     * Read audio as float samples for mixing.
     * @param output Float output buffer
     * @param frames Number of frames to read
     * @return Number of frames actually read
     */
    virtual size_t readFloat(float* output, size_t frames) = 0;

    /**
     * Check if buffer has enough data to start playback.
     */
    virtual bool isReady() const = 0;

    /**
     * Check if buffer is currently active (has data).
     */
    virtual bool isActive() const = 0;

    /**
     * Get buffer statistics.
     */
    virtual Stats getStats() const = 0;

    /**
     * Reset buffer state.
     */
    virtual void reset() = 0;

    /**
     * Notify that user stopped talking (trigger fade-out).
     */
    virtual void notifyTalkingEnded() = 0;

protected:
    UserAudioBuffer() = default;
};

/**
 * Crossfade utility for smooth audio transitions.
 */
class Crossfade {
public:
    /**
     * Create crossfade tables for given frame size.
     */
    static std::unique_ptr<Crossfade> create(int frameSize);

    virtual ~Crossfade() = default;

    /**
     * Apply fade-in to samples.
     * @param samples Samples to modify in place
     * @param frames Number of frames
     */
    virtual void applyFadeIn(float* samples, size_t frames) = 0;

    /**
     * Apply fade-out to samples.
     * @param samples Samples to modify in place
     * @param frames Number of frames
     */
    virtual void applyFadeOut(float* samples, size_t frames) = 0;

    /**
     * Get the fade length in frames.
     */
    virtual int getFadeLength() const = 0;

protected:
    Crossfade() = default;
};

/**
 * Float mixer for combining multiple audio streams.
 * Implements clipping-safe mixing like Humla's BasicClippingShortMixer.
 */
class FloatMixer {
public:
    /**
     * Create a float mixer.
     * @param frameSize Frames per buffer
     */
    static std::unique_ptr<FloatMixer> create(int frameSize);

    virtual ~FloatMixer() = default;

    /**
     * Clear the mix buffer.
     */
    virtual void clear() = 0;

    /**
     * Add samples to the mix.
     * @param samples Float samples to add
     * @param frames Number of frames
     */
    virtual void add(const float* samples, size_t frames) = 0;

    /**
     * Get mixed result as int16 with clipping.
     * @param output Int16 output buffer
     * @param frames Number of frames
     */
    virtual void getMixed(int16_t* output, size_t frames) = 0;

    /**
     * Get the raw float mix buffer (before clipping).
     */
    virtual const float* getFloatBuffer() const = 0;

protected:
    FloatMixer() = default;
};

}  // namespace sayses
