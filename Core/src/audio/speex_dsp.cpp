/**
 * Speex DSP Implementation
 * Wrapper around libspeexdsp for preprocessing and resampling
 */

#include "speex_dsp.h"

#include <speex/speex_preprocess.h>
#include <speex/speex_resampler.h>

#include <cmath>
#include <algorithm>

namespace sayses {

// ============================================================================
// SpeexPreprocessor Implementation
// ============================================================================

class SpeexPreprocessorImpl : public SpeexPreprocessor {
public:
    explicit SpeexPreprocessorImpl(const Config& config);
    ~SpeexPreprocessorImpl() override;

    bool process(int16_t* samples, size_t frames) override;
    float getSpeechProbability() const override;
    float getInputLevel() const override;
    void setDenoiseEnabled(bool enabled) override;
    void setAgcEnabled(bool enabled) override;
    void setDereverbEnabled(bool enabled) override;
    void reset() override;

private:
    void applyConfig();

    Config config_;
    SpeexPreprocessState* state_{nullptr};
    float speechProbability_{0.0f};
    float inputLevel_{0.0f};
};

std::unique_ptr<SpeexPreprocessor> SpeexPreprocessor::create(const Config& config) {
    return std::make_unique<SpeexPreprocessorImpl>(config);
}

SpeexPreprocessorImpl::SpeexPreprocessorImpl(const Config& config)
    : config_(config) {

    // Create preprocessor state
    state_ = speex_preprocess_state_init(config_.frameSize, config_.sampleRate);

    if (state_) {
        applyConfig();
    }
}

SpeexPreprocessorImpl::~SpeexPreprocessorImpl() {
    if (state_) {
        speex_preprocess_state_destroy(state_);
        state_ = nullptr;
    }
}

void SpeexPreprocessorImpl::applyConfig() {
    if (!state_) return;

    int val;

    // Noise suppression
    val = config_.denoiseEnabled ? 1 : 0;
    speex_preprocess_ctl(state_, SPEEX_PREPROCESS_SET_DENOISE, &val);

    if (config_.denoiseEnabled) {
        val = config_.denoiseLevel;
        speex_preprocess_ctl(state_, SPEEX_PREPROCESS_SET_NOISE_SUPPRESS, &val);
    }

    // AGC (Automatic Gain Control)
    val = config_.agcEnabled ? 1 : 0;
    speex_preprocess_ctl(state_, SPEEX_PREPROCESS_SET_AGC, &val);

    if (config_.agcEnabled) {
        val = config_.agcTarget;
        speex_preprocess_ctl(state_, SPEEX_PREPROCESS_SET_AGC_TARGET, &val);

        val = config_.agcMaxGain;
        speex_preprocess_ctl(state_, SPEEX_PREPROCESS_SET_AGC_MAX_GAIN, &val);
    }

    // Dereverb
    val = config_.dereverbEnabled ? 1 : 0;
    speex_preprocess_ctl(state_, SPEEX_PREPROCESS_SET_DEREVERB, &val);

    if (config_.dereverbEnabled) {
        float level = config_.dereverbLevel;
        speex_preprocess_ctl(state_, SPEEX_PREPROCESS_SET_DEREVERB_LEVEL, &level);

        float decay = config_.dereverbDecay;
        speex_preprocess_ctl(state_, SPEEX_PREPROCESS_SET_DEREVERB_DECAY, &decay);
    }

    // VAD (internal - we typically use our own)
    val = config_.vadEnabled ? 1 : 0;
    speex_preprocess_ctl(state_, SPEEX_PREPROCESS_SET_VAD, &val);
}

bool SpeexPreprocessorImpl::process(int16_t* samples, size_t frames) {
    if (!state_ || frames != static_cast<size_t>(config_.frameSize)) {
        return false;
    }

    // Run preprocessor (modifies samples in place)
    int vadResult = speex_preprocess_run(state_, samples);

    // Get speech probability
    int prob;
    speex_preprocess_ctl(state_, SPEEX_PREPROCESS_GET_PROB, &prob);
    speechProbability_ = prob / 100.0f;

    // Calculate input level (RMS after processing)
    double sum = 0.0;
    for (size_t i = 0; i < frames; i++) {
        double normalized = samples[i] / 32768.0;
        sum += normalized * normalized;
    }
    inputLevel_ = static_cast<float>(std::sqrt(sum / frames));

    return vadResult != 0;
}

float SpeexPreprocessorImpl::getSpeechProbability() const {
    return speechProbability_;
}

float SpeexPreprocessorImpl::getInputLevel() const {
    return inputLevel_;
}

void SpeexPreprocessorImpl::setDenoiseEnabled(bool enabled) {
    config_.denoiseEnabled = enabled;
    if (state_) {
        int val = enabled ? 1 : 0;
        speex_preprocess_ctl(state_, SPEEX_PREPROCESS_SET_DENOISE, &val);
    }
}

void SpeexPreprocessorImpl::setAgcEnabled(bool enabled) {
    config_.agcEnabled = enabled;
    if (state_) {
        int val = enabled ? 1 : 0;
        speex_preprocess_ctl(state_, SPEEX_PREPROCESS_SET_AGC, &val);
    }
}

void SpeexPreprocessorImpl::setDereverbEnabled(bool enabled) {
    config_.dereverbEnabled = enabled;
    if (state_) {
        int val = enabled ? 1 : 0;
        speex_preprocess_ctl(state_, SPEEX_PREPROCESS_SET_DEREVERB, &val);
    }
}

void SpeexPreprocessorImpl::reset() {
    if (state_) {
        speex_preprocess_state_destroy(state_);
        state_ = speex_preprocess_state_init(config_.frameSize, config_.sampleRate);
        if (state_) {
            applyConfig();
        }
    }
    speechProbability_ = 0.0f;
    inputLevel_ = 0.0f;
}

// ============================================================================
// SpeexResampler Implementation
// ============================================================================

class SpeexResamplerImpl : public SpeexResampler {
public:
    SpeexResamplerImpl(int channels, int inputRate, int outputRate, Quality quality);
    ~SpeexResamplerImpl() override;

    bool process(const int16_t* input, size_t& inputFrames,
                 int16_t* output, size_t& outputFrames) override;
    float getRatio() const override;
    void reset() override;
    int getLatency() const override;

private:
    int channels_;
    int inputRate_;
    int outputRate_;
    SpeexResamplerState* state_{nullptr};
};

std::unique_ptr<SpeexResampler> SpeexResampler::create(
    int channels, int inputRate, int outputRate, Quality quality) {
    return std::make_unique<SpeexResamplerImpl>(channels, inputRate, outputRate, quality);
}

SpeexResamplerImpl::SpeexResamplerImpl(int channels, int inputRate, int outputRate, Quality quality)
    : channels_(channels)
    , inputRate_(inputRate)
    , outputRate_(outputRate) {

    int err;
    state_ = speex_resampler_init(
        channels,
        inputRate,
        outputRate,
        static_cast<int>(quality),
        &err
    );

    if (err != RESAMPLER_ERR_SUCCESS) {
        state_ = nullptr;
    }
}

SpeexResamplerImpl::~SpeexResamplerImpl() {
    if (state_) {
        speex_resampler_destroy(state_);
        state_ = nullptr;
    }
}

bool SpeexResamplerImpl::process(const int16_t* input, size_t& inputFrames,
                                  int16_t* output, size_t& outputFrames) {
    if (!state_) {
        return false;
    }

    spx_uint32_t inLen = static_cast<spx_uint32_t>(inputFrames);
    spx_uint32_t outLen = static_cast<spx_uint32_t>(outputFrames);

    int err = speex_resampler_process_int(
        state_,
        0,  // Channel 0 (mono)
        input,
        &inLen,
        output,
        &outLen
    );

    inputFrames = inLen;
    outputFrames = outLen;

    return err == RESAMPLER_ERR_SUCCESS;
}

float SpeexResamplerImpl::getRatio() const {
    return static_cast<float>(outputRate_) / inputRate_;
}

void SpeexResamplerImpl::reset() {
    if (state_) {
        speex_resampler_reset_mem(state_);
    }
}

int SpeexResamplerImpl::getLatency() const {
    if (!state_) return 0;
    return speex_resampler_get_input_latency(state_);
}

}  // namespace sayses
