#pragma once

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct NNWakeSpotter NNWakeSpotter;

const char *nn_wake_last_error(void);

/// Loads libonnxruntime and libsherpa-onnx-c-api from `dylib_directory`, then
/// constructs a keyword spotter. Returns NULL on failure; read nn_wake_last_error().
NNWakeSpotter *nn_wake_create(
    const char *dylib_directory,
    const char *encoder,
    const char *decoder,
    const char *joiner,
    const char *tokens,
    const char *keywords_file,
    float threshold
);

/// Tell the stream no more audio is coming, then decode. Returns 1 if a keyword fired.
int32_t nn_wake_finish(NNWakeSpotter *spotter);

/// Feed mono float32 PCM in [-1, 1]. Returns 1 if a keyword fired this chunk.
int32_t nn_wake_accept(
    NNWakeSpotter *spotter,
    const float *samples,
    int32_t n,
    int32_t sample_rate
);

/// Last fired keyword, or empty string. Owned by the spotter.
const char *nn_wake_keyword(NNWakeSpotter *spotter);

void nn_wake_reset(NNWakeSpotter *spotter);
void nn_wake_destroy(NNWakeSpotter *spotter);

#ifdef __cplusplus
}
#endif
