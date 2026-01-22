#pragma once

#include <memory>
#include <cstdint>
#include <cstddef>

namespace sayses {

/**
 * Jitter buffer for smoothing audio packet arrival times.
 * Handles packet reordering and loss concealment.
 */
class JitterBuffer {
public:
    struct Config {
        int sampleRate = 48000;
        int frameSize = 480;          // samples per frame
        int minDelayMs = 20;          // minimum buffering delay
        int maxDelayMs = 200;         // maximum buffering delay
        int targetDelayMs = 60;       // target delay
    };

    struct Stats {
        int currentDelayMs;
        int packetsReceived;
        int packetsLost;
        int packetsLate;
        int packetsReordered;
        float lossRate;
    };

    /**
     * Create a jitter buffer instance.
     */
    static std::unique_ptr<JitterBuffer> create(const Config& config);

    virtual ~JitterBuffer() = default;

    /**
     * Add a packet to the buffer.
     * @param data Audio data
     * @param frames Number of frames
     * @param sequence Packet sequence number
     * @param timestamp Packet timestamp
     */
    virtual void put(const int16_t* data, size_t frames,
                     uint32_t sequence, uint32_t timestamp) = 0;

    /**
     * Get audio data from the buffer.
     * @param output Buffer for output data
     * @param frames Number of frames to get
     * @return Number of frames written (may be 0 if buffer empty)
     */
    virtual size_t get(int16_t* output, size_t frames) = 0;

    /**
     * Check if buffer has data available.
     */
    virtual bool hasData() const = 0;

    /**
     * Get buffer statistics.
     */
    virtual Stats getStats() const = 0;

    /**
     * Reset buffer state.
     */
    virtual void reset() = 0;

protected:
    JitterBuffer() = default;
};

}  // namespace sayses
