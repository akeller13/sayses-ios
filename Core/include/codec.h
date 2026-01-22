#pragma once

#include <memory>
#include <cstdint>
#include <cstddef>
#include <vector>

namespace sayses {

/**
 * Audio codec interface for encoding/decoding audio.
 */
class Codec {
public:
    enum class Type {
        Opus,
        Speex,
        CELT
    };

    struct Config {
        int sampleRate = 48000;
        int channels = 1;
        int bitrate = 64000;      // 64 kbps (good quality for voice, like Mumla)
        int frameSize = 480;       // samples per frame (10ms at 48kHz)
        int complexity = 5;        // 0-10, higher = better quality, more CPU
        bool vbr = true;           // variable bitrate
        bool dtx = true;           // discontinuous transmission
    };

    virtual ~Codec() = default;

    /**
     * Create an Opus codec instance.
     */
    static std::unique_ptr<Codec> createOpus(const Config& config);

    /**
     * Create a Speex codec instance.
     */
    static std::unique_ptr<Codec> createSpeex(const Config& config);

    /**
     * Encode PCM audio to compressed format.
     * @param input PCM input samples (16-bit)
     * @param inputFrames Number of input frames
     * @param output Buffer for encoded data
     * @param maxOutputBytes Maximum output buffer size
     * @return Number of bytes written, or negative on error
     */
    virtual int encode(const int16_t* input, size_t inputFrames,
                       uint8_t* output, size_t maxOutputBytes) = 0;

    /**
     * Decode compressed audio to PCM.
     * @param input Encoded input data
     * @param inputBytes Size of encoded data
     * @param output Buffer for PCM output (16-bit)
     * @param maxOutputFrames Maximum output frames
     * @return Number of frames decoded, or negative on error
     */
    virtual int decode(const uint8_t* input, size_t inputBytes,
                       int16_t* output, size_t maxOutputFrames) = 0;

    /**
     * Decode with packet loss concealment (no input data).
     * @param output Buffer for PCM output (16-bit)
     * @param maxOutputFrames Maximum output frames
     * @return Number of frames generated
     */
    virtual int decodePLC(int16_t* output, size_t maxOutputFrames) = 0;

    /**
     * Reset codec state.
     */
    virtual void reset() = 0;

    /**
     * Get the codec type.
     */
    virtual Type getType() const = 0;

    /**
     * Get frame size in samples.
     */
    virtual int getFrameSize() const = 0;

    /**
     * Get sample rate.
     */
    virtual int getSampleRate() const = 0;

protected:
    Codec() = default;
};

}  // namespace sayses
