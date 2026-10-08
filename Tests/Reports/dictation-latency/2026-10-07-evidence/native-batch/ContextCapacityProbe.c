#include <llama/llama.h>
#include <pthread.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/sysctl.h>

// Disposable, private-process diagnostic. Never print a native log line, model path,
// prompt or token. Read the existing runtime's construction parameters unchanged,
// except the explicitly selected logical/physical maximum in the candidate arm.
static pthread_mutex_t lock = PTHREAD_MUTEX_INITIALIZER;
static const char *phase = "none";
static unsigned accepted = 0;
static unsigned refused = 0;

static void metadata_log(enum ggml_log_level level, const char *text, void *user) {
    (void)level; (void)user;
    if (!text) return;
    const struct { const char *marker; const char *kind; } sizes[] = {
        {" compute buffer size = ", "compute"},
        {" output buffer size = ", "output"},
        {" KV buffer size = ", "kv"},
        {" RS buffer size = ", "recurrent"}
    };
    pthread_mutex_lock(&lock);
    bool found = false;
    for (unsigned i = 0; i < sizeof(sizes)/sizeof(sizes[0]); ++i) {
        const char *mark = strstr(text, sizes[i].marker);
        double mib = 0;
        char unit[8] = {0};
        if (mark && sscanf(mark + strlen(sizes[i].marker), "%lf %7s", &mib, unit) == 2
            && strcmp(unit, "MiB") == 0 && mib >= 0 && mib < 1048576) {
            const char *device = strstr(text, "Metal") ? "metal" :
                                 strstr(text, "CPU") ? "cpu" : "other";
            printf("{\"phase\":\"%s\",\"kind\":\"%s\",\"device\":\"%s\",\"reportedMiB\":%.8f}\n",
                   phase, sizes[i].kind, device, mib);
            accepted++; found = true; break;
        }
    }
    if (!found) refused++;
    pthread_mutex_unlock(&lock);
}

static void set_phase(const char *value) {
    pthread_mutex_lock(&lock); phase = value; pthread_mutex_unlock(&lock);
}

static int parser_check(void) {
    set_phase("parser");
    metadata_log(GGML_LOG_LEVEL_INFO, "llama_context: CPU compute buffer size =  12.50 MiB\n", NULL);
    metadata_log(GGML_LOG_LEVEL_INFO, "llama_context: Metal output buffer size = 1.25 MiB\n", NULL);
    metadata_log(GGML_LOG_LEVEL_INFO, "llama_kv_cache: CPU KV buffer size = 32.00 MiB\n", NULL);
    metadata_log(GGML_LOG_LEVEL_INFO, "llama_memory: CPU RS buffer size = 2.00 MiB\n", NULL);
    metadata_log(GGML_LOG_LEVEL_INFO, "private path or prompt must never appear", NULL);
    metadata_log(GGML_LOG_LEVEL_INFO, "CPU compute buffer size = -1 MiB", NULL);
    metadata_log(GGML_LOG_LEVEL_INFO, "CPU compute buffer size = 5 bytes", NULL);
    metadata_log(GGML_LOG_LEVEL_INFO, "CPU compute buffer size = NaN MiB", NULL);
    metadata_log(GGML_LOG_LEVEL_INFO, "CPU compute buffer size = Inf MiB", NULL);
    printf("{\"parserAccepted\":%u,\"parserRefused\":%u}\n", accepted, refused);
    return accepted == 4 && refused == 5 ? 0 : 1;
}

int main(int argc, char **argv) {
    if (argc == 2 && strcmp(argv[1], "--parser-only") == 0) return parser_check();
    if (argc != 4) return 64;
    unsigned ctx = (unsigned)strtoul(argv[2], NULL, 10);
    int gpu = (int)strtol(argv[3], NULL, 10);
    if ((ctx != 2048 && ctx != 8192) || (gpu != 0 && gpu != 99)) return 64;
    ggml_log_callback previous = NULL;
    void *previous_data = NULL;
    llama_log_get(&previous, &previous_data);
    llama_log_set(metadata_log, NULL);
    set_phase("load");
    llama_backend_init();
    struct llama_model_params mp = llama_model_default_params();
    mp.n_gpu_layers = gpu;
    mp.load_mode = LLAMA_LOAD_MODE_MMAP;
    mp.use_extra_bufts = false;
    struct llama_model *model = llama_model_load_from_file(argv[1], mp);
    int status = model ? 0 : 2;
    if (model) {
        int cores = 1; size_t len = sizeof(cores);
        if (sysctlbyname("hw.logicalcpu", &cores, &len, NULL, 0) != 0) cores = 1;
        int threads = cores - 2; if (threads < 1) threads = 1; if (threads > 8) threads = 8;
        for (unsigned arm = 0; arm < 2 && !status; ++arm) {
            set_phase(arm ? "capacity128" : "capacity512");
            struct llama_context_params cp = llama_context_default_params();
            cp.n_ctx = ctx;
            cp.n_batch = arm ? 128 : 512;
            if (arm) cp.n_ubatch = 128;
            cp.n_threads = threads; cp.n_threads_batch = threads;
            struct llama_context *context = llama_init_from_model(model, cp);
            if (!context) { status = 3; break; }
            printf("{\"phase\":\"%s\",\"effectiveContext\":%u,\"effectiveBatch\":%u,\"effectiveMicrobatch\":%u}\n",
                   arm ? "capacity128" : "capacity512", llama_n_ctx(context),
                   llama_n_batch(context), llama_n_ubatch(context));
            // Both contexts are fully destroyed before returning. No decoding, sampler,
            // scheduler, native input or feature accuracy proof is supplied by this arm.
            llama_free(context);
        }
        llama_model_free(model);
    }
    llama_backend_free();
    llama_log_set(previous, previous_data);
    printf("{\"status\":%d,\"acceptedMetadataLines\":%u,\"refusedLines\":%u,\"priorCallbackRestored\":true}\n",
           status, accepted, refused);
    return status;
}
