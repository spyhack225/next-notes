# Native TTS integration and first-audio comparison

22 October 2026. **Incomplete: native verification and all timing runs are blocked.**
The new SDKs and runtime adapter objects compiled, but the full app did not link. No new app was
installed, no existing model was deleted and no TTS weights were downloaded. There is no accepted
current timing table. See [verification](verification.json) and [per-engine blocked status](resource-blocked.json).

## Engines and implementation

| Engine | Implementation | Generated-audio delivery |
|---|---|---|
| Apple | Existing AVSpeechSynthesizer | Native PCM callback |
| Pocket | Existing FluidAudio INT8, Alba | Streaming |
| Kokoro | Existing FluidAudio Core ML 82M, Heart | Whole clause; existing OS exclusions retained |
| Phonon | Native ptts 0.4.0, Phonon 31m English, ANE | Streaming mono 24 kHz Float PCM |
| Qwen3-TTS | MLXAudioTTS 0.1.6, 0.6B CustomVoice 4-bit, Ryan | Joined whole clause; low-latency streaming remains open |

Phonon's public 137 MB archive is pinned to release v0.4.0 and SHA-256. All Qwen model/tokenizer files
are pinned to revision `08c72cad5e2fd0f41730c8bd1f28149585e46361`, byte counts and SHA-256, totalling
about 1.69 GB. Phonon's archive requires additional unpacking/Core ML compilation space. No gated
Phonon 40m weights are selected.

The source integrates settings selection/download progress, realtime speech and long-form narration.
The new engines reuse `PocketSourceSpeechBacking`, `AgentPCMRenderer`, cancellation tokens, the
single output graph and reverse acoustic reference. No microphone path, queue, delivery ledger,
turn-path gate or additional model pass was introduced. Startup prepares only an installed selected
voice; it fetches no unselected new voice. Stored preferences and the existing default are preserved.

The Phonon bundle is moved into place on the same volume instead of making the SDK installer's
additional full copy. The archive and owned extraction directory are removed. Qwen uses a joined
native generation task because the public streaming API does not expose its hidden producer's join;
interruption stops output immediately, and a busy decoder uses the existing Apple fallback. This
whole-clause adapter must not be presented as a low-latency streaming implementation.

## Storage and measurement contracts

`Tools/tts_compare.py` runs one engine in one process at a time: check headroom, create a marked
owned temporary root, prepare/measure, durably save the result, join the process and its helpers,
remove the root, verify removal, then start the successor. Failure/timeout results are also saved
before cleanup. If saving fails, retain that single owned root and stop the entire comparison.
An abrupt parent kill or power loss cannot guarantee cleanup; unknown directories are never swept.

Compatible owner caches are reused with APFS copy-on-write `cp -cRL` snapshots. The SDK may modify
only the disposable copy. Child TMPDIR also points inside the owned root so transient downloads and
helper files share its lifetime. Kokoro requires its already-installed shared pronunciation files;
it refuses rather than downloading them outside the owned lifetime. Owner originals are retained.
The diagnostic reserve is 2 GiB plus a per-engine estimate; ordinary app downloads retain their
existing 4 GiB reserve. The runner independently stops its own process below 1.5 GiB actual free disk.

The metric is **known text request → first non-empty generated PCM**, milliseconds. It is not first
audible output, speech-end→answer, ASR/EOU or full-duplex latency. Download/load preparation, first
synthesis after preparation and five subsequent warm samples are separate. Trial zero is not a
hardware-cold measurement. Warm runs are back-to-back and can differ from human-paced use.
Whole-clause and streamed adapters are labelled. Every trial retains first PCM, completion, frames
and audio duration. Reports retain model identity, OS, RAM, process peak RSS and executable SHA-256.
Peak RSS is not Mach physical footprint. Reference workload, thermal/power state, whole-machine
memory trends and audio quality remain separate acceptance requirements.

After a verified optimized executable exists:

```sh
python3 Tools/tts_compare.py --app /absolute/path/to/NextNotes --output /absolute/path/to/new-results
```

The runner never builds or installs. The headless flag executes before SwiftUI and owner task-store
startup. Each new provider also has a separate muted native playback check after timing: pause before
PCM, resume, actual first-render receipt and drain. That check opens muted output, with no microphone.
The independent `--selftest-tts-source` drives authored PCM through the real renderer to exercise a
pause longer than the active IO budget and immediate stop. Neither native check has run yet.

## Verification and actual failure evidence

- Eight Python tests pass: seven real fake-child lifecycle cases plus the tiny actual macOS APFS
  clone/symlink preservation case. They cover serial lifetime, save-before-delete ordering,
  owner preservation, timeout, active low-disk interruption, no-space refusal, save failure retention
  and child temporary-directory routing. These are not model or speech tests.
- Dependencies resolve. Native SDK and new runtime/benchmark Swift objects compiled.
- Default SwiftBuild planning failed because PhononCore and NemoTextProcessing flattened two module
  maps into one output. The native backend compiled both. Build/test Makefile and macOS CI select it.
  The original log is `native-build.log`; the interrupted one-worker experiment is
  `native-build-native.log`; the two-worker full-app attempt is `native-build-j2.log`.
- The optimized full-app attempt used two workers, non-WMO batch optimization (16 batches), one native
  thread and the shared scratch cache. It stopped on an inherited `Section("Benchmark results")` plus
  footer overload in GeneralSettingsTab. A narrow explicit-header syntax repair is applied; no rebuilt
  executable proves it yet. All source changes remain uninstalled.
- The Metal compiler is absent. `Tools/build-mlx-metal.sh` verifies the exact official MLX 0.32.3
  Cmlx release archive, extracts only the macOS default.metallib and deletes the 212,871,838-byte
  archive. About 2.2 MB is retained. `metal-packaging.log` records success. GPU execution is unrun.
- At 15:32 UTC the other ASR agent aborted its own load as free disk fell from about 3.4 GiB to
  362 MiB and swap reached 10.30 GiB. No TTS download/inference was running. This does not establish
  the pressure's allocating producer. Native work is deferred, and the owner was asked to free
  space or restart. The actual later resource snapshot is in verification.json.
- No model timing, playback verdict, original/fixed pause verdict, winner, reference acceptance or
  default promotion is claimed. Potential pending-pause/paused-budget behavior in the shared renderer
  still needs the original native regression before changing its producer.

## Remaining work

Recover resources and the coordinated machine window, incrementally link the app, run the original
source regression, repair its producer if the actual case fails, rerun unchanged, then run serial
measurements/playback checks and save/exit/delete after every engine. Settings/preview/narration UI,
rapid interruption/successor/fallback, route changes, acoustic reference and full-duplex ASR-plus-voice
acceptance also remain open. Keep generated-PCM timings distinct from those broader contracts.

## Artifact lifecycle

All tiny test fixtures are removed. The temporary Metal archive is removed. No benchmark model roots
or TTS model downloads exist. Useful shared dependency checkouts, incremental objects, the Metal library
and failure evidence are deliberately retained for completion; deleting them would require downloading
and compiling them again. Existing owner caches, models, recordings, installed app, processes and other
agents' staged/uncommitted files are preserved. No worktree or branch was created.

Whole-file source hashes are in [source-pins.json](source-pins.json); inherited changes are included and
are not attributed wholesale to this task. This source is retained uncommitted in the shared working
tree pending native verification; no unrelated staged files were incorporated into a commit.
