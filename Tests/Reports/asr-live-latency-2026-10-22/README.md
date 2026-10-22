# Paced ASR latency — 22 October 2026

Status: **partial**. Whistle completed six paced holds on the owner's M3. Cached
Parakeet v3 was aborted during short-prefix warmup as disk/swap pressure rose;
the remaining six variants could not start. No cross-model live ranking or default
promotion is supported. Existing whole-file results remain a separate experiment.

| Whistle CPU metric | English, median (range), n=3 | French, median (range), n=3 |
|---|---|---|
| First provisional word from clip start | 421 ms (411–429) | 420 ms (414–421) |
| First native committed word | 2,443 ms (2,438–2,455) | 1,439 ms (1,435–1,446) |
| Release → full ASR final | 68 ms (64–70) | 86 ms (83–172) |
| Final short-hold word edits | 1 / 20 each run (5%) | 6 / 22 each run (27.27%) |

These are warmed, paced **runtime** observations under the machine's current
pressure, not physical microphone/UI/cleanup delivery. Initial English text was
`Okay.` once and `OK.` twice: the strict first-reference-word metric treats those
spellings differently, which is not evidence of a semantic first-word mistake.
French misrecognized substantive words as well as number spelling. The English
and French short-hold errors do not replace the original 136/151-word scores.

The matched 10-second English audit returned internal first-token times of
**12.4, 14.7, 14.2 ms**; total processing **60.2, 62.4, 59.9 ms**, decoder
**1,006–1,070 tokens/s**. This is much closer to the vendor's 11.1 ms / 1,319/s
on M4 Pro than our earlier longer-clip M3 number. French ten-second internal
first token varied 16.5–31.8 ms and whole-call time 100.8–253.1 ms; report the
variation rather than treating the fastest sample as typical. A returned batch
statistic does not expose a live word at that timestamp. With the shared 400 ms
first-prefix policy, live text first arrived around 420 ms; native commitment
required agreement across passes and took substantially longer.

| Candidate | New live test status |
|---|---|
| Whistle native CPU | Measured, with pressure/workload caveat |
| Parakeet v3 cached CoreML | Warmup aborted; no accepted timing |
| Redux / Ultra CoreML | Blocked; neither downloaded |
| Phonon-2 CoreML | Blocked; not downloaded; English only |
| Qwen3-ASR 0.6B / 1.7B 4-bit MLX | Blocked; neither downloaded |
| Voz CoreML SDK | Blocked; neither SDK nor weights downloaded |

## Resource incident and lifecycle

The agreed machine window began at 15:31 UTC after the TTS chat released its
build claim. The bounded cached-object probe linked successfully. Immediately
before native launch, free disk was 3,659,251,712 bytes; swap used 6,235.69 MB.
The model loader returned its ready message, but warmup had not completed when
free disk fell below 500 MB and swap used reached 10,321.75 MB. Only our verified
probe PID 88377 was stopped and joined. The allocating producer is **unconfirmed**:
RSS is insufficient attribution, no native stack was captured before stopping,
and ANECompilerService's vmmap was denied by macOS. No service/foreign process
was killed. The exact outstanding warmup prefix was not retained by the original
RPC error path; that diagnostic gap is now covered by a model-free failure test.

The retained cache objects were rebuilt during the preceding shared build:
281 common object hashes differ from the earlier whole-file probe. This is
another reason not to inherit its native acceptance or call the new probe the
installed app. `probe-build.json` pins all 283 linked inputs. All 23 original
owner-model file hashes remain unchanged (`retained-input-parity.json`).

Only the known-small Whistle CPU case then ran with an explicit 256 MiB disk
reserve checked every second, no CoreML compiler, and a prior bounded memory
profile. Its observed peak RSS was 105,299,968 bytes (not Mach physical footprint).
It passed and its child exited/joined before the exact temporary model/runtime
directory was deleted. The 19,373,776-byte standalone probe was also removed; no new
model/runtime remains. OS specialization caches, swap, other agents' builds,
owner models, recordings and other user files were preserved. Known removed files
total 36,293,183 bytes (probe plus model), with the small native runtime additional.
The remaining artifacts are compact source, traces, hashes and reports. Machine claims
were returned before the agreed slot ended. Larger model budgets still fail;
the owner was asked to restore at least 5 GB internal space and reduce unused
app memory before resuming. A freed-space reply is still required; no automatic
retry or destructive cleanup is authorized by this report.

## Definitions

The same authored EN/FR fixtures as the whole-file comparison are fed at speaking
speed, measuring from clip start (these fixtures begin with speech). Each excerpt contains the first
two complete sentences: English 7.25 s / 116,000 samples, French 6.65 s / 106,400.
The final quiet margins end before the third sentence begins. This is a short-hold
probe, not a long-meeting or independent speech-quality corpus.

The shared policy follows the app's `StreamingASR`: first prefix at 0.4 s, then
1 s refreshes. Native requests are serialized and coalesce audio if an inference
runs slowly. Only elapsed audio is supplied. Release has an independent monotonic
deadline; unfinished inference and final inference both count toward its latency.
Three repeats per language follow an explicit warmup of each scheduled prefix and
the final shape. Qwen uses the runtime's token-output generator and timestamps the
first completed word boundary; completion is still drained before the next request.
Other runtimes deliver their prefix text in a single response. Repeats are timing samples,
not three independent quality examples. No percentile claim is made.

- `first_text_ms`: delivery of the first nonempty word, which can still be wrong.
- `first_correct_reference_word_ms`: first prefix beginning with the gold first
  word (exact Unicode/casefold word normalization; no manual synonym substitutions).
- `first_final_consistent_word_ms`: first prefix whose first word matches the
  final's first word. This is retrospective consistency, not a native commit.
- `first_committed_ms`: only populated where the runtime actually commits words.
- `release_to_final_ms`: full ASR final delivery after scheduled release, including
  in-flight drain. It excludes cleanup, text insertion and UI rendering.

Whistle uses its incremental C API: each input is the previously unsent delta;
returned committed text is a delta and must be accumulated, with its pending tail
kept separate. Other candidates re-transcribe the available prefix through their
native batch APIs. This is a comparison under a common app-like policy, not proof
of every vendor's optimal native streaming policy or Next Notes integration.
RPC probes include prefix file reading/transport; direct Python workers include
array preparation. Those boundaries are retained and must not be called UI timing.

## Whistle discrepancy and CoreML audit

Primary sources checked on 22 October:

- [Cactus Whistle announcement](https://cactuscompute.com/blog/whistle): vendor
  11.1 ms internal first token and 1,319 tokens/s are for an already-recorded
  **10-second clip on M4 Pro CPU**. The architecture describes five beams.
- [Pinned runtime header](https://huggingface.co/Cactus-Compute/needle3/blob/d6c7d6a2e9655505e0f8e23339356dd1705900eb/macos-arm64/needle.h):
  batch `ttft_ms` is a returned statistic, not a callback delivering a word.
  Live API re-decodes buffered audio and commits agreement between consecutive
  passes; `stop` commits its pending tail. Our prior M3 whole-file EN warm median
  (~403 ms for 60.6 s, internal first token ~41 ms) measures different boundaries,
  clip length and hardware. It is not a failed reproduction of the vendor's 11 ms.
- [Whistle artifact tree](https://huggingface.co/Cactus-Compute/whistle/tree/741118687e1f008f06d1351a402a731274789790):
  runtime `whistle.cact` **16,919,407 B**, training checkpoint **220,618,620 B**.
  There is no published `.mlpackage` / `.mlmodelc` in this pinned tree.
- [Needle source tree](https://github.com/cactus-compute/needle/tree/b4fc11b04f1852888d375c8c6dfbaca44572d014):
  `needle/model/whistle.py` uses JAX/Flax. `needle/model/export.py` writes `.cact`.
  This inspected tree has no CoreML exporter and no C/C++ engine source files.
- [Apple's conversion formats](https://apple.github.io/coremltools/docs-guides/source/target-conversion-formats.html),
  [MIL / ML programs](https://github.com/apple/coremltools/blob/main/docs-guides/source/convert-to-ml-program.md):
  supported conversion inputs include TensorFlow, PyTorch and MIL; `.cact` is not
  a supported input. Setting CPU_AND_NE only applies after a CoreML model exists.

Feasible engineering path, **not implemented or speed-validated**: reproduce the
encoder and decoder math in a supported export representation; preserve frontend
normalization, custom residual/attention operations, tokenization, quantization,
beam search and caches; verify numerical and transcript parity; compile representative
fixed audio shapes; measure actual device placement, storage and live latency.
An encoder-on-ANE / decoder-on-CPU split is a candidate, but the published C ABI
does not accept externally computed encoder states, so it requires additional
runtime integration rather than a configuration toggle. A CoreML export may grow
substantially from the custom 16.9 MB packed file and may not improve short-prefix
latency. No CoreML speedup or storage figure is claimed; no large conversion
toolchain or training checkpoint was downloaded for this audit.

## Validation and remaining contracts

`Tools/test_asr_live.py` verifies future audio cannot leak into a timed prefix,
release latency includes a straddling slow inference, and a failed RPC retains
the last requested sample count and readiness fact. The seven retained download,
digest, bounds, lock and WER tests also pass (ten total). The RPC driver now
polls disk while awaiting a reply and refuses below 512 MiB; this is diagnostic
containment, not a repair of the unconfirmed pressure producer or a product gate.
Other native candidates, microphone/UI delivery, duplex contention, polished-text
delivery and default promotion remain unverified. Existing models/preferences remain
untouched; disposable candidate assets are removed before loading the next model.

Developer continuation: after resources recover, agree another machine window and
run `python3 -B Tools/run_asr_live_serial.py --output-dir <fresh-report-directory>`.
Keep this pressure run intact. The runner refuses to blend its Whistle diagnostic
with a later comparable suite, preserves earlier build/context receipts on resume,
and stops on a failed child. No app rebuild/install is needed for these probes.
