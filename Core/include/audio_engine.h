#pragma once

#include <functional>
#include <memory>
#include <cstdint>
#include <cstddef>

namespace sayses {

/**
 * Audio Engine for capturing and playing back audio.
 * Platform-specific implementations handle the actual audio I/O.
 */
class AudioEngine {
public:
    using AudioCallback = std::function<void(const int16_t* data, size_t frames)>;
    using PlaybackCallback = std::function<size_t(int16_t* data, size_t frames)>;

    struct Config {
        int sampleRate = 48000;
        int channels = 1;
        int framesPerBuffer = 480;  // 10ms at 48kHz
    };

    /**
     * Create platform-specific audio engine instance.
     */
    static std::unique_ptr<AudioEngine> create(const Config& config);

    virtual ~AudioEngine() = default;

    /**
     * Start audio capture with callback for each buffer.
     * @param callback Called with audio data for each captured buffer
     * @return true if capture started successfully
     */
    virtual bool startCapture(AudioCallback callback) = 0;

    /**
     * Stop audio capture.
     */
    virtual void stopCapture() = 0;

    /**
     * Check if currently capturing audio.
     */
    virtual bool isCapturing() const = 0;

    /**
     * Start audio playback with callback to request data.
     * @param callback Called to request audio data for playback
     * @return true if playback started successfully
     */
    virtual bool startPlayback(PlaybackCallback callback) = 0;

    /**
     * Stop audio playback.
     */
    virtual void stopPlayback() = 0;

    /**
     * Check if currently playing audio.
     */
    virtual bool isPlaying() const = 0;

    /**
     * Enable/disable Voice Activity Detection.
     */
    virtual void setVadEnabled(bool enabled) = 0;

    /**
     * Set VAD threshold (0.0 - 1.0).
     */
    virtual void setVadThreshold(float threshold) = 0;

    /**
     * Check if voice is currently detected.
     */
    virtual bool isVoiceDetected() const = 0;

    /**
     * Get current input level (0.0 - 1.0).
     */
    virtual float getInputLevel() const = 0;

    // =========================================================================
    // User Audio Management (for multi-user playback with mixing)
    // =========================================================================

    /**
     * Add decoded audio samples for a specific user.
     * Uses per-user buffers with float mixing, jitter buffering, and crossfade.
     * @param userId User/session ID
     * @param samples Decoded PCM samples (int16)
     * @param frames Number of samples
     * @param sequence Packet sequence number for jitter buffer
     */
    virtual void addUserAudio(uint32_t userId, const int16_t* samples,
                              size_t frames, int64_t sequence) = 0;

    /**
     * Remove user's audio buffer (when user leaves).
     * @param userId User/session ID to remove
     */
    virtual void removeUser(uint32_t userId) = 0;

    /**
     * Notify that user stopped talking (for crossfade).
     * @param userId User/session ID
     */
    virtual void notifyUserTalkingEnded(uint32_t userId) = 0;

    /**
     * Start playback using internal user mixing (no callback needed).
     * Audio from addUserAudio is automatically mixed and played.
     * @return true if playback started successfully
     */
    virtual bool startMixedPlayback() = 0;

    /**
     * Get the playback callback invocation count.
     * Used to detect when the AudioUnit has silently stopped calling back.
     * @return Number of times the playback callback has been invoked
     */
    virtual uint64_t getPlaybackCallbackCount() const = 0;

protected:
    AudioEngine() = default;
};

}  // namespace sayses
