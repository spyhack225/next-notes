#include "NextNotesAEC.h"
#include "api/audio/audio_processing.h"
#include "api/audio/echo_control.h"
#include "api/audio/echo_canceller3_config.h"
#include "api/scoped_refptr.h"
#include "modules/audio_processing/aec3/echo_canceller3.h"
#include <algorithm>
#include <array>
#include <cmath>
#include <memory>
#include <optional>

struct NextNotesAEC {
  rtc::scoped_refptr<webrtc::AudioProcessing> apm;
  webrtc::StreamConfig format{16000, 1};
};

namespace {
constexpr uint32_t kExportLinear = 1u << 0;
constexpr uint32_t kZeroInitialFilter = 1u << 1;
constexpr uint32_t kDisableNonlinearReverb = 1u << 2;
constexpr uint32_t kSensitiveDominantNearend = 1u << 3;
constexpr uint32_t kBoundedDominantNearend = 1u << 4;
constexpr uint32_t kKnownOptions = kExportLinear | kZeroInitialFilter
    | kDisableNonlinearReverb | kSensitiveDominantNearend
    | kBoundedDominantNearend;
}

// AudioProcessing::Config controls allocation of the public linear-output
// buffer, while EchoCanceller3 has its own filter.export_linear_aec_output
// switch controlling whether the AEC3 instance actually fills it. The
// configured factory keeps those AEC3 options together. It remains isolated
// from the default APM factory and is never selected by aec_create().
class ConfiguredEchoControlFactory final : public webrtc::EchoControlFactory {
 public:
  ConfiguredEchoControlFactory(bool export_linear_aec_output,
                               bool zero_initial_filter,
                               bool disable_nonlinear_reverb,
                               bool sensitive_dominant_nearend,
                               bool bounded_dominant_nearend)
      : export_linear_aec_output_(export_linear_aec_output),
        zero_initial_filter_(zero_initial_filter),
        disable_nonlinear_reverb_(disable_nonlinear_reverb),
        sensitive_dominant_nearend_(sensitive_dominant_nearend),
        bounded_dominant_nearend_(bounded_dominant_nearend) {}

  std::unique_ptr<webrtc::EchoControl> Create(
      int sample_rate_hz, int num_render_channels,
      int num_capture_channels) override {
    auto config = webrtc::EchoCanceller3Config{};
    config.filter.export_linear_aec_output = export_linear_aec_output_;
    if (zero_initial_filter_) {
      config.filter.initial_state_seconds = 0.f;
    }
    if (disable_nonlinear_reverb_) {
      config.echo_model.model_reverb_in_nonlinear_mode = false;
    }
    if (sensitive_dominant_nearend_) {
      config.suppressor.dominant_nearend_detection.enr_threshold = 0.5f;
    }
    if (bounded_dominant_nearend_) {
      // This field only selects the spectrum passed to the dominant-nearend
      // detector; the suppressor's own residual spectrum remains unchanged.
      config.suppressor.dominant_nearend_detection
          .use_unbounded_echo_spectrum = false;
    }
    return std::make_unique<webrtc::EchoCanceller3>(
        config, std::nullopt, sample_rate_hz, num_render_channels,
        num_capture_channels);
  }

 private:
  const bool export_linear_aec_output_;
  const bool zero_initial_filter_;
  const bool disable_nonlinear_reverb_;
  const bool sensitive_dominant_nearend_;
  const bool bounded_dominant_nearend_;
};

extern "C" {
static NextNotesAEC *create_instance(uint32_t options) {
  if (options & ~kKnownOptions) return nullptr;
  const bool export_linear_aec_output = (options & kExportLinear) != 0;
  const bool zero_initial_filter = (options & kZeroInitialFilter) != 0;
  const bool disable_nonlinear_reverb = (options & kDisableNonlinearReverb) != 0;
  const bool sensitive_dominant_nearend = (options & kSensitiveDominantNearend) != 0;
  const bool bounded_dominant_nearend = (options & kBoundedDominantNearend) != 0;
  auto *instance = new NextNotesAEC;
  auto config = webrtc::AudioProcessing::Config{};
  config.echo_canceller.enabled = true;
  config.echo_canceller.export_linear_aec_output = export_linear_aec_output;
  config.echo_canceller.mobile_mode = false;
  // The default forces an extra HPF even when high_pass_filter is disabled.
  // In the fixed-latency double-talk fixture it reduced near speech retention
  // from 0.733 to 0.584, without improving echo attenuation.
  config.echo_canceller.enforce_high_pass_filtering = false;
  config.high_pass_filter.enabled = false;
  config.noise_suppression.enabled = false;
  config.transient_suppression.enabled = false;
  config.gain_controller1.enabled = false;
  config.gain_controller2.enabled = false;
  webrtc::AudioProcessingBuilder builder;
  builder.SetConfig(config);
  if (export_linear_aec_output || zero_initial_filter
      || disable_nonlinear_reverb || sensitive_dominant_nearend
      || bounded_dominant_nearend) {
    builder.SetEchoControlFactory(std::make_unique<ConfiguredEchoControlFactory>(
        export_linear_aec_output, zero_initial_filter,
        disable_nonlinear_reverb, sensitive_dominant_nearend,
        bounded_dominant_nearend));
  }
  instance->apm = builder.Create();
  if (!instance->apm) {
    delete instance;
    return nullptr;
  }
  return instance;
}

NextNotesAEC *aec_create() { return create_instance(0); }

NextNotesAEC *aec_create_linear_v1() {
  // This is intentionally a separate, versioned constructor. It exists only
  // for the explicit local AEC3 diagnostic and must not change production's
  // final (suppressed) ProcessStream output.
  return create_instance(kExportLinear);
}

NextNotesAEC *aec_create_options_v1(uint32_t options) {
  return create_instance(options);
}

void aec_destroy(NextNotesAEC *instance) { delete instance; }

int aec_feed_render(NextNotesAEC *instance, const float *input) {
  if (!instance || !input) return -1;
  const float *source[] = {input};
  float discard[160] = {};
  float *target[] = {discard};
  return instance->apm->ProcessReverseStream(source, instance->format,
                                             instance->format, target);
}

int aec_process_capture(NextNotesAEC *instance, const float *input,
                        float *output, int delay_ms) {
  if (!instance || !input || !output) return -1;
  if (instance->apm->set_stream_delay_ms(delay_ms) != 0) return -2;
  const float *source[] = {input};
  float *target[] = {output};
  return instance->apm->ProcessStream(source, instance->format,
                                      instance->format, target);
}

int aec_get_linear_aec_output_v1(NextNotesAEC *instance, float *output) {
  if (!instance || !output) return -1;
  // GetLinearAecOutput returns the latest 10 ms at 16 kHz. The SDK converts
  // its internal FloatS16 samples back to Float32, so this ABI has the same
  // [-1, 1] scale as ProcessStream and exactly 160 samples.
  std::array<std::array<float, 160>, 1> linear{};
  if (!instance->apm->GetLinearAecOutput(linear)) return -2;
  std::copy(linear[0].begin(), linear[0].end(), output);
  return 0;
}

int aec_stats(NextNotesAEC *instance, double *erl, double *erle,
              double *residual, int *delay) {
  if (!instance) return -1;
  const auto stats = instance->apm->GetStatistics();
  if (erl) *erl = stats.echo_return_loss.value_or(NAN);
  if (erle) *erle = stats.echo_return_loss_enhancement.value_or(NAN);
  if (residual) *residual = stats.residual_echo_likelihood.value_or(NAN);
  if (delay) *delay = stats.delay_ms.value_or(-1);
  return 0;
}
}
