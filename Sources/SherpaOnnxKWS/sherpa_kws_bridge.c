#include "sherpa_kws_bridge.h"

#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* Structs copied from sherpa-onnx v1.13.8 c-api.h. Layout must match the dylib. */

typedef struct {
    const char *encoder;
    const char *decoder;
    const char *joiner;
} SherpaOnnxOnlineTransducerModelConfig;

typedef struct {
    const char *encoder;
    const char *decoder;
} SherpaOnnxOnlineParaformerModelConfig;

typedef struct {
    const char *model;
} SherpaOnnxOnlineZipformer2CtcModelConfig;

typedef struct {
    const char *model;
} SherpaOnnxOnlineNemoCtcModelConfig;

typedef struct {
    const char *model;
} SherpaOnnxOnlineToneCtcModelConfig;

typedef struct {
    SherpaOnnxOnlineTransducerModelConfig transducer;
    SherpaOnnxOnlineParaformerModelConfig paraformer;
    SherpaOnnxOnlineZipformer2CtcModelConfig zipformer2_ctc;
    const char *tokens;
    int32_t num_threads;
    const char *provider;
    int32_t debug;
    const char *model_type;
    const char *modeling_unit;
    const char *bpe_vocab;
    const char *tokens_buf;
    int32_t tokens_buf_size;
    SherpaOnnxOnlineNemoCtcModelConfig nemo_ctc;
    SherpaOnnxOnlineToneCtcModelConfig t_one_ctc;
} SherpaOnnxOnlineModelConfig;

typedef struct {
    int32_t sample_rate;
    int32_t feature_dim;
} SherpaOnnxFeatureConfig;

typedef struct {
    SherpaOnnxFeatureConfig feat_config;
    SherpaOnnxOnlineModelConfig model_config;
    int32_t max_active_paths;
    int32_t num_trailing_blanks;
    float keywords_score;
    float keywords_threshold;
    const char *keywords_file;
    const char *keywords_buf;
    int32_t keywords_buf_size;
} SherpaOnnxKeywordSpotterConfig;

typedef struct {
    const char *keyword;
    const char *tokens;
    const char *const *tokens_arr;
    int32_t count;
    float *timestamps;
    float start_time;
    const char *json;
} SherpaOnnxKeywordResult;

typedef struct SherpaOnnxKeywordSpotter SherpaOnnxKeywordSpotter;
typedef struct SherpaOnnxOnlineStream SherpaOnnxOnlineStream;

typedef const SherpaOnnxKeywordSpotter *(*CreateSpotterFn)(const SherpaOnnxKeywordSpotterConfig *);
typedef void (*DestroySpotterFn)(const SherpaOnnxKeywordSpotter *);
typedef const SherpaOnnxOnlineStream *(*CreateStreamFn)(const SherpaOnnxKeywordSpotter *);
typedef void (*DestroyStreamFn)(const SherpaOnnxOnlineStream *);
typedef void (*AcceptFn)(const SherpaOnnxOnlineStream *, int32_t, const float *, int32_t);
typedef void (*InputFinishedFn)(const SherpaOnnxOnlineStream *);
typedef int32_t (*IsReadyFn)(const SherpaOnnxKeywordSpotter *, const SherpaOnnxOnlineStream *);
typedef void (*DecodeFn)(const SherpaOnnxKeywordSpotter *, const SherpaOnnxOnlineStream *);
typedef void (*ResetFn)(const SherpaOnnxKeywordSpotter *, const SherpaOnnxOnlineStream *);
typedef const SherpaOnnxKeywordResult *(*GetResultFn)(const SherpaOnnxKeywordSpotter *, const SherpaOnnxOnlineStream *);
typedef void (*DestroyResultFn)(const SherpaOnnxKeywordResult *);

struct NNWakeSpotter {
    void *handle;
    const SherpaOnnxKeywordSpotter *spotter;
    const SherpaOnnxOnlineStream *stream;
    CreateSpotterFn create;
    DestroySpotterFn destroy;
    CreateStreamFn create_stream;
    DestroyStreamFn destroy_stream;
    AcceptFn accept;
    InputFinishedFn input_finished;
    IsReadyFn is_ready;
    DecodeFn decode;
    ResetFn reset;
    GetResultFn get_result;
    DestroyResultFn destroy_result;
    char keyword[256];
};

static char g_error[512];

const char *nn_wake_last_error(void) {
    return g_error;
}

static void set_error(const char *message) {
    snprintf(g_error, sizeof(g_error), "%s", message);
}

static void *load_lib(const char *directory, const char *name) {
    char path[1024];
    snprintf(path, sizeof(path), "%s/%s", directory, name);
    void *handle = dlopen(path, RTLD_NOW | RTLD_GLOBAL);
    if (!handle) {
        snprintf(g_error, sizeof(g_error), "dlopen %s: %s", path, dlerror());
    }
    return handle;
}

static void *must_sym(void *handle, const char *name) {
    void *symbol = dlsym(handle, name);
    if (!symbol) {
        snprintf(g_error, sizeof(g_error), "dlsym %s: %s", name, dlerror());
    }
    return symbol;
}

NNWakeSpotter *nn_wake_create(
    const char *dylib_directory,
    const char *encoder,
    const char *decoder,
    const char *joiner,
    const char *tokens,
    const char *keywords_file,
    float threshold
) {
    return nn_wake_create_tuned(dylib_directory, encoder, decoder, joiner, tokens,
                                keywords_file, threshold, 0, 0.0f, 0);
}

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
) {
    g_error[0] = 0;
    if (!dylib_directory || !encoder || !decoder || !joiner || !tokens || !keywords_file) {
        set_error("wake spotter is missing a required path");
        return NULL;
    }

    /* onnxruntime first so the C API dylib can resolve it. */
    void *ort = load_lib(dylib_directory, "libonnxruntime.dylib");
    if (!ort) {
        return NULL;
    }
    void *handle = load_lib(dylib_directory, "libsherpa-onnx-c-api.dylib");
    if (!handle) {
        dlclose(ort);
        return NULL;
    }

    NNWakeSpotter *spotter = calloc(1, sizeof(*spotter));
    if (!spotter) {
        set_error("out of memory");
        dlclose(handle);
        return NULL;
    }
    spotter->handle = handle;

    spotter->create = must_sym(handle, "SherpaOnnxCreateKeywordSpotter");
    spotter->destroy = must_sym(handle, "SherpaOnnxDestroyKeywordSpotter");
    spotter->create_stream = must_sym(handle, "SherpaOnnxCreateKeywordStream");
    spotter->destroy_stream = must_sym(handle, "SherpaOnnxDestroyOnlineStream");
    spotter->accept = must_sym(handle, "SherpaOnnxOnlineStreamAcceptWaveform");
    spotter->input_finished = must_sym(handle, "SherpaOnnxOnlineStreamInputFinished");
    spotter->is_ready = must_sym(handle, "SherpaOnnxIsKeywordStreamReady");
    spotter->decode = must_sym(handle, "SherpaOnnxDecodeKeywordStream");
    spotter->reset = must_sym(handle, "SherpaOnnxResetKeywordStream");
    spotter->get_result = must_sym(handle, "SherpaOnnxGetKeywordResult");
    spotter->destroy_result = must_sym(handle, "SherpaOnnxDestroyKeywordResult");
    if (!spotter->create || !spotter->destroy || !spotter->create_stream || !spotter->destroy_stream
        || !spotter->accept || !spotter->input_finished || !spotter->is_ready || !spotter->decode
        || !spotter->reset || !spotter->get_result || !spotter->destroy_result) {
        free(spotter);
        dlclose(handle);
        return NULL;
    }

    SherpaOnnxKeywordSpotterConfig config;
    memset(&config, 0, sizeof(config));
    config.feat_config.sample_rate = 16000;
    config.feat_config.feature_dim = 80;
    config.model_config.transducer.encoder = encoder;
    config.model_config.transducer.decoder = decoder;
    config.model_config.transducer.joiner = joiner;
    config.model_config.tokens = tokens;
    config.model_config.num_threads = 1;
    config.model_config.provider = "cpu";
    config.model_config.debug = 0;
    config.max_active_paths = max_active_paths > 0 ? max_active_paths : 4;
    config.num_trailing_blanks = num_trailing_blanks > 0 ? num_trailing_blanks : 1;
    config.keywords_score = keywords_score > 0 ? keywords_score : 1.0f;
    config.keywords_threshold = threshold > 0 ? threshold : 0.25f;
    config.keywords_file = keywords_file;

    spotter->spotter = spotter->create(&config);
    if (!spotter->spotter) {
        set_error("SherpaOnnxCreateKeywordSpotter returned NULL");
        free(spotter);
        dlclose(handle);
        return NULL;
    }
    spotter->stream = spotter->create_stream(spotter->spotter);
    if (!spotter->stream) {
        set_error("SherpaOnnxCreateKeywordStream returned NULL");
        spotter->destroy(spotter->spotter);
        free(spotter);
        dlclose(handle);
        return NULL;
    }
    return spotter;
}

int32_t nn_wake_accept(
    NNWakeSpotter *spotter,
    const float *samples,
    int32_t n,
    int32_t sample_rate
) {
    if (!spotter || !spotter->stream || !samples || n <= 0) {
        return 0;
    }
    spotter->keyword[0] = 0;
    spotter->accept(spotter->stream, sample_rate, samples, n);
    while (spotter->is_ready(spotter->spotter, spotter->stream)) {
        spotter->decode(spotter->spotter, spotter->stream);
    }
    const SherpaOnnxKeywordResult *result = spotter->get_result(spotter->spotter, spotter->stream);
    if (!result) {
        return 0;
    }
    int32_t hit = result->keyword && result->keyword[0] != 0;
    if (hit) {
        snprintf(spotter->keyword, sizeof(spotter->keyword), "%s", result->keyword);
        spotter->reset(spotter->spotter, spotter->stream);
    }
    spotter->destroy_result(result);
    return hit;
}

int32_t nn_wake_finish(NNWakeSpotter *spotter) {
    if (!spotter || !spotter->stream) {
        return 0;
    }
    spotter->input_finished(spotter->stream);
    while (spotter->is_ready(spotter->spotter, spotter->stream)) {
        spotter->decode(spotter->spotter, spotter->stream);
    }
    const SherpaOnnxKeywordResult *result = spotter->get_result(spotter->spotter, spotter->stream);
    if (!result) {
        return 0;
    }
    int32_t hit = result->keyword && result->keyword[0] != 0;
    if (hit) {
        snprintf(spotter->keyword, sizeof(spotter->keyword), "%s", result->keyword);
    }
    spotter->destroy_result(result);
    return hit;
}

const char *nn_wake_keyword(NNWakeSpotter *spotter) {
    return spotter ? spotter->keyword : "";
}

void nn_wake_reset(NNWakeSpotter *spotter) {
    if (!spotter) {
        return;
    }
    spotter->reset(spotter->spotter, spotter->stream);
    spotter->keyword[0] = 0;
}

int32_t nn_wake_reset_independent_audio(NNWakeSpotter *spotter) {
    if (!spotter) return 0;
    const SherpaOnnxOnlineStream *old = spotter->stream;
    spotter->stream = spotter->create_stream(spotter->spotter);
    if (old) spotter->destroy_stream(old);
    spotter->keyword[0] = 0;
    if (!spotter->stream) {
        set_error("SherpaOnnxCreateKeywordStream returned NULL");
        return 0;
    }
    return 1;
}

/* Local callback fixture exercises the adapter, not sherpa accuracy. */
typedef struct WakeResetFixture WakeResetFixture;
typedef struct {
    WakeResetFixture *owner;
    int queued_frames;
    int finished;
} WakeResetFixtureStream;
struct WakeResetFixture {
    WakeResetFixtureStream streams[4];
    int next_stream, created, destroyed, reset, accepted, finished, refuse;
};
static const SherpaOnnxOnlineStream *wake_fixture_create(const SherpaOnnxKeywordSpotter *model) {
    WakeResetFixture *f = (WakeResetFixture *)model;
    ++f->created;
    if (f->refuse) return NULL;
    WakeResetFixtureStream *s = &f->streams[f->next_stream++];
    s->owner = f;
    return (const SherpaOnnxOnlineStream *)s;
}
static void wake_fixture_destroy(const SherpaOnnxOnlineStream *stream) {
    ++((WakeResetFixtureStream *)stream)->owner->destroyed;
}
static void wake_fixture_reset(const SherpaOnnxKeywordSpotter *model, const SherpaOnnxOnlineStream *stream) {
    (void)stream; /* v1.13.8 keyword reset retains feature/input-finished state. */
    ++((WakeResetFixture *)model)->reset;
}
static void wake_fixture_accept(const SherpaOnnxOnlineStream *stream, int32_t rate, const float *pcm, int32_t n) {
    (void)rate; (void)pcm; (void)n;
    ++((WakeResetFixtureStream *)stream)->owner->accepted;
}
static void wake_fixture_finished(const SherpaOnnxOnlineStream *stream) {
    ++((WakeResetFixtureStream *)stream)->owner->finished;
}
static int32_t wake_fixture_ready(const SherpaOnnxKeywordSpotter *model, const SherpaOnnxOnlineStream *stream) {
    (void)model; (void)stream; return 0;
}
static const SherpaOnnxKeywordResult *wake_fixture_result(const SherpaOnnxKeywordSpotter *model, const SherpaOnnxOnlineStream *stream) {
    (void)model; (void)stream; return NULL;
}
int32_t nn_wake_independent_audio_failures_for_testing(void) {
    char previous_error[sizeof(g_error)];
    memcpy(previous_error, g_error, sizeof(g_error));
    WakeResetFixture f = {0};
    f.next_stream = 1;
    f.streams[0] = (WakeResetFixtureStream){.owner=&f, .queued_frames=17, .finished=1};
    NNWakeSpotter s = {0};
    s.spotter = (const SherpaOnnxKeywordSpotter *)&f;
    s.stream = (const SherpaOnnxOnlineStream *)&f.streams[0];
    s.create_stream = wake_fixture_create; s.destroy_stream = wake_fixture_destroy;
    s.reset = wake_fixture_reset; s.accept = wake_fixture_accept;
    s.input_finished = wake_fixture_finished; s.is_ready = wake_fixture_ready;
    s.get_result = wake_fixture_result;
    int32_t failures = 0;
    const SherpaOnnxOnlineStream *old = s.stream;
    nn_wake_reset(&s);
    if (s.stream != old || f.created || f.destroyed || f.reset != 1 ||
        f.streams[0].queued_frames != 17 || !f.streams[0].finished) failures |= 1;
    strcpy(s.keyword, "old clip");
    if (!nn_wake_reset_independent_audio(&s)) failures |= 2;
    if (f.created != 1 || f.destroyed != 1) failures |= 4;
    WakeResetFixtureStream *fresh = (WakeResetFixtureStream *)s.stream;
    if (!fresh || s.stream == old || fresh->queued_frames || fresh->finished) failures |= 8;
    if (s.spotter != (const SherpaOnnxKeywordSpotter *)&f || s.keyword[0]) failures |= 16;
    old = s.stream;
    if (!nn_wake_reset_independent_audio(&s) || s.stream == old ||
        f.created != 2 || f.destroyed != 2) failures |= 32;
    f.refuse = 1;
    strcpy(s.keyword, "old clip");
    if (nn_wake_reset_independent_audio(&s)) failures |= 64;
    if (s.stream || s.keyword[0] || f.created != 3 || f.destroyed != 3) failures |= 128;
    float pcm = 0;
    if (nn_wake_accept(&s, &pcm, 1, 16000) || nn_wake_finish(&s) ||
        f.accepted || f.finished) failures |= 256;
    f.refuse = 0;
    if (!nn_wake_reset_independent_audio(&s) || !s.stream ||
        f.created != 4 || f.destroyed != 3) failures |= 512;
    if (nn_wake_reset_independent_audio(NULL)) failures |= 1024;
    if (s.stream) s.destroy_stream(s.stream);
    memcpy(g_error, previous_error, sizeof(g_error));
    return failures;
}

void nn_wake_destroy(NNWakeSpotter *spotter) {
    if (!spotter) {
        return;
    }
    if (spotter->stream) {
        spotter->destroy_stream(spotter->stream);
    }
    if (spotter->spotter) {
        spotter->destroy(spotter->spotter);
    }
    if (spotter->handle) {
        dlclose(spotter->handle);
    }
    free(spotter);
}
