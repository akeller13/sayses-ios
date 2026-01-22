/**
 * Opus Codec Implementation
 * Wrapper around libopus for Mumble audio encoding/decoding
 */

#include "codec.h"

#include <opus.h>
#include <cstring>

namespace sayses {

class OpusCodec : public Codec {
public:
    explicit OpusCodec(const Config& config);
    ~OpusCodec() override;

    int encode(const int16_t* input, size_t inputFrames,
               uint8_t* output, size_t maxOutputBytes) override;

    int decode(const uint8_t* input, size_t inputBytes,
               int16_t* output, size_t maxOutputFrames) override;

    int decodePLC(int16_t* output, size_t maxOutputFrames) override;

    void reset() override;

    Type getType() const override { return Type::Opus; }
    int getFrameSize() const override { return config_.frameSize; }
    int getSampleRate() const override { return config_.sampleRate; }

private:
    Config config_;
    OpusEncoder* encoder_{nullptr};
    OpusDecoder* decoder_{nullptr};
};

// Factory method
std::unique_ptr<Codec> Codec::createOpus(const Config& config) {
    return std::make_unique<OpusCodec>(config);
}

OpusCodec::OpusCodec(const Config& config)
    : config_(config) {

    int error;

    // Create encoder
    encoder_ = opus_encoder_create(
        config_.sampleRate,
        config_.channels,
        OPUS_APPLICATION_VOIP,
        &error
    );

    if (error != OPUS_OK || !encoder_) {
        throw std::runtime_error("Failed to create Opus encoder");
    }

    // Configure encoder (matching Android SAYses / Mumla settings)
    // Use 64kbps for good voice quality (as documented)
    int bitrate = config_.bitrate > 0 ? config_.bitrate : 64000;
    opus_encoder_ctl(encoder_, OPUS_SET_BITRATE(bitrate));
    opus_encoder_ctl(encoder_, OPUS_SET_COMPLEXITY(config_.complexity));
    opus_encoder_ctl(encoder_, OPUS_SET_VBR(config_.vbr ? 1 : 0));
    opus_encoder_ctl(encoder_, OPUS_SET_DTX(config_.dtx ? 1 : 0));
    opus_encoder_ctl(encoder_, OPUS_SET_SIGNAL(OPUS_SIGNAL_VOICE));
    opus_encoder_ctl(encoder_, OPUS_SET_INBAND_FEC(1));  // Enable forward error correction
    opus_encoder_ctl(encoder_, OPUS_SET_PACKET_LOSS_PERC(10));  // Expect ~10% packet loss

    // Create decoder
    decoder_ = opus_decoder_create(
        config_.sampleRate,
        config_.channels,
        &error
    );

    if (error != OPUS_OK || !decoder_) {
        opus_encoder_destroy(encoder_);
        encoder_ = nullptr;
        throw std::runtime_error("Failed to create Opus decoder");
    }
}

OpusCodec::~OpusCodec() {
    if (encoder_) {
        opus_encoder_destroy(encoder_);
        encoder_ = nullptr;
    }
    if (decoder_) {
        opus_decoder_destroy(decoder_);
        decoder_ = nullptr;
    }
}

int OpusCodec::encode(const int16_t* input, size_t inputFrames,
                      uint8_t* output, size_t maxOutputBytes) {
    if (!encoder_) {
        return -1;
    }

    int result = opus_encode(
        encoder_,
        input,
        static_cast<int>(inputFrames),
        output,
        static_cast<opus_int32>(maxOutputBytes)
    );

    return result;
}

int OpusCodec::decode(const uint8_t* input, size_t inputBytes,
                      int16_t* output, size_t maxOutputFrames) {
    if (!decoder_) {
        return -1;
    }

    int result = opus_decode(
        decoder_,
        input,
        static_cast<opus_int32>(inputBytes),
        output,
        static_cast<int>(maxOutputFrames),
        0  // decode_fec = 0 (not using FEC for this packet)
    );

    return result;
}

int OpusCodec::decodePLC(int16_t* output, size_t maxOutputFrames) {
    if (!decoder_) {
        return -1;
    }

    // Pass nullptr as input for packet loss concealment
    int result = opus_decode(
        decoder_,
        nullptr,
        0,
        output,
        static_cast<int>(maxOutputFrames),
        0
    );

    return result;
}

void OpusCodec::reset() {
    if (encoder_) {
        opus_encoder_ctl(encoder_, OPUS_RESET_STATE);
    }
    if (decoder_) {
        opus_decoder_ctl(decoder_, OPUS_RESET_STATE);
    }
}

}  // namespace sayses
