/**
 * Jitter Buffer Implementation
 * Handles packet reordering, timing, and loss concealment for VoIP audio
 */

#include "jitter_buffer.h"

#include <deque>
#include <map>
#include <mutex>
#include <cstring>
#include <chrono>
#include <algorithm>

namespace sayses {

class JitterBufferImpl : public JitterBuffer {
public:
    explicit JitterBufferImpl(const Config& config);
    ~JitterBufferImpl() override = default;

    void put(const int16_t* data, size_t frames,
             uint32_t sequence, uint32_t timestamp) override;
    size_t get(int16_t* output, size_t frames) override;
    bool hasData() const override;
    Stats getStats() const override;
    void reset() override;

private:
    struct Packet {
        std::vector<int16_t> data;
        uint32_t sequence;
        uint32_t timestamp;
        std::chrono::steady_clock::time_point arrivalTime;
    };

    void adjustDelay();
    void discardOldPackets();

    Config config_;

    // Buffer storage - keyed by sequence number
    mutable std::mutex mutex_;
    std::map<uint32_t, Packet> packets_;

    // Playback state
    uint32_t nextPlaySequence_{0};
    bool initialized_{false};

    // Timing
    int currentDelayMs_{0};
    std::chrono::steady_clock::time_point lastGetTime_;

    // Statistics
    int packetsReceived_{0};
    int packetsLost_{0};
    int packetsLate_{0};
    int packetsReordered_{0};

    // Constants
    static constexpr size_t kMaxPackets = 100;  // Maximum packets to buffer
};

// Factory
std::unique_ptr<JitterBuffer> JitterBuffer::create(const Config& config) {
    return std::make_unique<JitterBufferImpl>(config);
}

JitterBufferImpl::JitterBufferImpl(const Config& config)
    : config_(config)
    , currentDelayMs_(config.targetDelayMs) {

    lastGetTime_ = std::chrono::steady_clock::now();
}

void JitterBufferImpl::put(const int16_t* data, size_t frames,
                           uint32_t sequence, uint32_t timestamp) {
    std::lock_guard<std::mutex> lock(mutex_);

    packetsReceived_++;

    // Initialize on first packet
    if (!initialized_) {
        nextPlaySequence_ = sequence;
        initialized_ = true;
    }

    // Check if packet is too old (already played)
    if (sequence < nextPlaySequence_) {
        packetsLate_++;
        return;
    }

    // Check if packet is reordered (out of expected order)
    if (!packets_.empty()) {
        auto lastIt = packets_.rbegin();
        if (sequence < lastIt->first) {
            packetsReordered_++;
        }
    }

    // Store packet
    Packet packet;
    packet.data.assign(data, data + frames);
    packet.sequence = sequence;
    packet.timestamp = timestamp;
    packet.arrivalTime = std::chrono::steady_clock::now();

    packets_[sequence] = std::move(packet);

    // Limit buffer size
    while (packets_.size() > kMaxPackets) {
        packets_.erase(packets_.begin());
    }
}

size_t JitterBufferImpl::get(int16_t* output, size_t frames) {
    std::lock_guard<std::mutex> lock(mutex_);

    auto now = std::chrono::steady_clock::now();
    lastGetTime_ = now;

    // Check if we should wait for more buffering
    if (!initialized_ || packets_.empty()) {
        // Output silence
        std::memset(output, 0, frames * sizeof(int16_t));
        return 0;
    }

    // Calculate buffered amount
    int bufferedPackets = static_cast<int>(packets_.size());
    int minPacketsNeeded = (config_.minDelayMs * config_.sampleRate) /
                           (config_.frameSize * 1000);

    // If buffer is too low, output silence to build up buffer
    if (bufferedPackets < minPacketsNeeded) {
        std::memset(output, 0, frames * sizeof(int16_t));
        return 0;
    }

    // Look for the next expected packet
    auto it = packets_.find(nextPlaySequence_);

    if (it != packets_.end()) {
        // Got the expected packet
        const Packet& packet = it->second;

        size_t copyFrames = std::min(frames, packet.data.size());
        std::memcpy(output, packet.data.data(), copyFrames * sizeof(int16_t));

        // Pad with zeros if needed
        if (copyFrames < frames) {
            std::memset(output + copyFrames, 0, (frames - copyFrames) * sizeof(int16_t));
        }

        packets_.erase(it);
        nextPlaySequence_++;

        return copyFrames;
    } else {
        // Packet lost - try to find next available
        packetsLost_++;

        // Find the next available packet
        if (!packets_.empty()) {
            it = packets_.begin();

            // If we're too far behind, skip ahead
            if (nextPlaySequence_ < it->first) {
                int skipped = it->first - nextPlaySequence_;
                packetsLost_ += skipped - 1;  // Already counted one
                nextPlaySequence_ = it->first;
            }

            const Packet& packet = it->second;

            size_t copyFrames = std::min(frames, packet.data.size());
            std::memcpy(output, packet.data.data(), copyFrames * sizeof(int16_t));

            if (copyFrames < frames) {
                std::memset(output + copyFrames, 0, (frames - copyFrames) * sizeof(int16_t));
            }

            packets_.erase(it);
            nextPlaySequence_++;

            return copyFrames;
        }

        // No packets available - output silence
        std::memset(output, 0, frames * sizeof(int16_t));
        return 0;
    }
}

bool JitterBufferImpl::hasData() const {
    std::lock_guard<std::mutex> lock(mutex_);

    if (packets_.empty()) {
        return false;
    }

    // Check if we have the next expected packet or any packets to play
    return packets_.find(nextPlaySequence_) != packets_.end() ||
           !packets_.empty();
}

JitterBuffer::Stats JitterBufferImpl::getStats() const {
    std::lock_guard<std::mutex> lock(mutex_);

    Stats stats;
    stats.currentDelayMs = currentDelayMs_;
    stats.packetsReceived = packetsReceived_;
    stats.packetsLost = packetsLost_;
    stats.packetsLate = packetsLate_;
    stats.packetsReordered = packetsReordered_;

    if (packetsReceived_ > 0) {
        stats.lossRate = static_cast<float>(packetsLost_) / packetsReceived_;
    } else {
        stats.lossRate = 0.0f;
    }

    return stats;
}

void JitterBufferImpl::reset() {
    std::lock_guard<std::mutex> lock(mutex_);

    packets_.clear();
    nextPlaySequence_ = 0;
    initialized_ = false;
    currentDelayMs_ = config_.targetDelayMs;
    packetsReceived_ = 0;
    packetsLost_ = 0;
    packetsLate_ = 0;
    packetsReordered_ = 0;
}

void JitterBufferImpl::adjustDelay() {
    // Adaptive delay adjustment based on jitter
    // TODO: Implement adaptive jitter buffer algorithm
}

void JitterBufferImpl::discardOldPackets() {
    // Remove packets that are too old
    while (packets_.size() > kMaxPackets) {
        auto it = packets_.begin();
        if (it->first < nextPlaySequence_) {
            packets_.erase(it);
        } else {
            break;
        }
    }
}

}  // namespace sayses
