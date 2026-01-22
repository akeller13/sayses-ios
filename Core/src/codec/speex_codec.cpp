/**
 * Speex Codec Implementation (Stub)
 * Speex is deprecated in favor of Opus but kept for compatibility
 */

#include "codec.h"

#include <cstring>

namespace sayses {

class SpeexCodec : public Codec {
public:
    explicit SpeexCodec(const Config& config);
    ~SpeexCodec() override = default;

    int encode(const int16_t* input, size_t inputFrames,
               uint8_t* output, size_t maxOutputBytes) override;

    int decode(const uint8_t* input, size_t inputBytes,
               int16_t* output, size_t maxOutputFrames) override;

    int decodePLC(int16_t* output, size_t maxOutputFrames) override;

    void reset() override;

    Type getType() const override { return Type::Speex; }
    int getFrameSize() const override { return config_.frameSize; }
    int getSampleRate() const override { return config_.sampleRate; }

private:
    Config config_;
};

// Factory method
std::unique_ptr<Codec> Codec::createSpeex(const Config& config) {
    return std::make_unique<SpeexCodec>(config);
}

SpeexCodec::SpeexCodec(const Config& config)
    : config_(config) {
    // Note: Speex support is deprecated
    // This is a stub implementation for API compatibility
}

int SpeexCodec::encode(const int16_t* input, size_t inputFrames,
                       uint8_t* output, size_t maxOutputBytes) {
    // Speex encoding not implemented - use Opus instead
    return -1;
}

int SpeexCodec::decode(const uint8_t* input, size_t inputBytes,
                       int16_t* output, size_t maxOutputFrames) {
    // Speex decoding not implemented - use Opus instead
    return -1;
}

int SpeexCodec::decodePLC(int16_t* output, size_t maxOutputFrames) {
    // Output silence
    std::memset(output, 0, maxOutputFrames * sizeof(int16_t));
    return static_cast<int>(maxOutputFrames);
}

void SpeexCodec::reset() {
    // Nothing to reset
}

}  // namespace sayses
