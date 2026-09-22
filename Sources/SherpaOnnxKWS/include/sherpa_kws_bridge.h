#pragma once

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct NNWakeSpotter NNWakeSpotter;

const char *nn_wake_last_error(void);

/// Loads libonnxruntime and libsherpa-onnx-c-api from `dylib_directory`, then
/// constructs a keyword spotter. Returns NULL on failure; read nn_wake_last_error().
///
/// Uses sherpa's stock decoding width (4 active paths). A keywords file that holds
/// several pronunciations of one phrase needs `nn_wake_create_tuned` instead: with a
/// beam of 4 the variants crowd each other out of the lattice and recall *drops*.
NNWakeSpotter *nn_wake_create(
    const char *dylib_directory,
    const char *encoder,
    const char *decoder,
    const char *joiner,
    const char *tokens,
    const char *keywords_file,
    float threshold
);

/// Same, with the decoder knobs exposed.
///
/// `max_active_paths` is the beam width. Measured on this 3M zh-en model with a
/// four-variant "Hey Will" keywords file: 4 paths → 53/90 accented clips, 16 paths →
/// 62/90. Pass <= 0 for sherpa's default (4).
///
/// `keywords_score` is the global boost applied to keyword lines that carry no `:`
/// token of their own. Pass <= 0 for sherpa's default (1.0). Measured: raising this
/// above 1.0 *lowered* recall and raised false accepts on the same fixtures, so the
/// app leaves it at the default and tunes per-keyword thresholds instead.
///
/// `num_trailing_blanks` is how many blank frames must follow the last keyword token
/// before it fires. Pass <= 0 for sherpa's default (1). Raising it to 2 trades recall
/// (62 → 58) for fewer false accepts (5 → 2).
NNWakeSpotter *nn_wake_create_tuned(
    const char *dylib_directory,
    const char *encoder,
    const char *decoder,
    const char *joiner,
    const char *tokens,
    const char *keywords_file,
    float threshold,
    int32_t max_active_paths,
    float keywords_score,
    int32_t num_trailing_blanks
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
