#ifndef NEXTNOTES_AEC_H
#define NEXTNOTES_AEC_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// All audio is mono Float32 at 16 kHz, in exactly 160-sample (10 ms) blocks.
// Feed the actual rendered speaker signal before processing the corresponding
// microphone block. One instance belongs to one voice session.
typedef struct NextNotesAEC NextNotesAEC;
NextNotesAEC *aec_create(void);
// Versioned self-test-only diagnostic ABI. This creates an APM configured to
// retain the linear AEC output before EchoCanceller3's nonlinear suppressor.
// The normal aec_create/aec_process_capture ABI remains unchanged.
NextNotesAEC *aec_create_linear_v1(void);
// Versioned evaluation-only constructor. Unknown option bits are rejected.
// Mask 0x1 exports linear AEC output; mask 0x2 starts the AEC3 filter with a
// zero initial-state duration; mask 0x4 disables nonlinear reverb modeling;
// mask 0x8 uses sensitive dominant-nearend activation (ENR 0.5); mask 0x10
// uses the bounded residual echo spectrum for dominant-nearend detection.
// These options are evaluation-only and are never used by production creation.
NextNotesAEC *aec_create_options_v1(uint32_t options);
void aec_destroy(NextNotesAEC *instance);
int aec_feed_render(NextNotesAEC *instance, const float *rendered_160);
int aec_process_capture(NextNotesAEC *instance, const float *captured_160,
                        float *output_160, int stream_delay_ms);
// Copies the most recent 160-sample, 16 kHz Float32 linear AEC output into
// output_160. Returns 0 when an output is available, or a negative error.
int aec_get_linear_aec_output_v1(NextNotesAEC *instance, float *output_160);
int aec_stats(NextNotesAEC *instance, double *echo_return_loss,
              double *echo_return_loss_enhancement,
              double *residual_echo_likelihood, int *delay_ms);

#ifdef __cplusplus
}
#endif
#endif
