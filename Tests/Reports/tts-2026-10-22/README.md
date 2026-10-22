# Native TTS integration and serial first-audio comparison

22 October 2026. **Five native comparisons completed.** Qwen3-TTS and Phonon generate audio and
pass muted playback through the production source/renderer. The optimized app links, its headless
source regression passes, and the serial runner saves each result, joins its process and deletes its
owned model before the next starts. No app was installed or default changed.

## Measured results

Same English text: “I found three matching files. The latest is enclosure version seventeen.”
Apple M3, 16 GB RAM, macOS 27.2 (26B5091g). Release `-O`, non-WMO batch compilation, two build workers.
Normal owner apps were retained; no other benchmark/model/build overlapped these timed trials.
Inherited swap pressure was present. This does **not** qualify the ASR-plus-voice reference workload.

| Engine | First synthesis after preparation | Warm median, 5 runs | Preparation, including download/load | Accepted raw result |
|---|---:|---:|---:|---|
| Phonon 31m English, Core ML v0.4.0 | 8.32 ms | **7.80 ms** | 7.00 s | [Phonon](native-results/phonon.json) |
| Qwen3-TTS 0.6B CustomVoice 4-bit, Ryan | 3,093.75 ms | **2,709.30 ms** | 17.68 s | [Qwen](native-qwen-headroom/qwen.json) |
| Apple system-default voice | 1,039.27 ms | **8.98 ms** | 0.001 s | [Apple](native-results/apple.json) |
| Pocket INT8, Alba | 1,096.68 ms | **59.00 ms** | 5.70 s | [Pocket](native-results/pocket.json) |
| Kokoro Core ML 82M, Heart | 904.19 ms | **224.11 ms** | 8.55 s | [Kokoro](native-retry/kokoro.json) |

The boundary is **known text request → first non-empty generated PCM**, not audible speaker output,
speech-end→answer, EOU/ASR or full-duplex latency. Phonon and Pocket stream. Kokoro and the current
Qwen adapter return whole clauses; Qwen's first PCM therefore includes full-clause generation.
Apple reuses one prepared synthesizer across trials. The first column is not a hardware-cold test.
Warm trials repeat the same text back-to-back and can differ from human-paced use; earlier failed
Qwen preparation may have warmed OS/GPU caches. No model/default promotion follows these numbers.

[Accepted comparison](accepted-results.json) links the selected runs. Each raw result retains all six
trials, completion time, audio frames/duration, preparation, model identity and process peak RSS.
RSS is not Mach physical footprint; Apple/Core ML host services are not included in the child's RSS.
Power/thermal metadata is a snapshot, not a continuous trace during timing. See
[environment](resume-environment.json), [binary and Metal resource pins](native-binary.json),
[complete app source pins](source-pins.json) and [verification](verification.json).

## Integration and producer repair

Settings selection/download progress, conversation output and long-form narration use the new native
runtimes through the existing `PocketSourceSpeechBacking` and single `AgentPCMRenderer`. They reuse
output tokens, cancellation and the reverse acoustic reference. No microphone path, playback ledger,
queue, extra model pass or conversational gate was added. Startup prepares only an installed selected
voice; no unselected new voice is fetched. Already-installed Qwen files do not require another download's
free-space reserve. Ordinary downloads retain the existing 4 GiB reserve.

Qwen files are pinned to revision `08c72cad5e2fd0f41730c8bd1f28149585e46361`, individual sizes and
SHA-256, totalling 1,693,602,151 bytes. Phonon's public English 31m archive is pinned to v0.4.0,
137,096,081 bytes and SHA-256. Its writable extracted bundle is moved into place instead of making the
SDK installer's extra full copy. No gated Phonon 40m weights are used.

The native output regression exposed two producer faults:

1. The source accepted a listening pause before its first PCM, but the renderer had no matching token
   yet and ignored the pause. Enqueue now publishes the pending pause before publishing the token.
2. The renderer's two-second write deadline counted deliberate paused wall time. It now counts active
   unpaused IO time with a monotonic clock; the two-second budget itself is unchanged.

The identical authored 16-second PCM case fails original, fails with only the initial-pause repair,
and passes with both repairs. [Original](source-original.log), [pause-only](source-pause-only.log),
[fixed](source-fixed.log), [same-body/source pins](fixed-component-pins.json). The focused fixture compiles
the real source, renderer, rings and conversion with native Core Audio output; only the DSP sink and
unreachable default Pocket/settings branch are substituted. The complete app then runs the same
`--selftest-tts-source` case successfully with its real dependencies: [full-app result](source-full-app.log).
Both real new-provider runs additionally pass muted pause-before-PCM, resume, first-render receipt and
native drain after their timing trials. No microphone is opened by these checks.

Qwen's public SDK stream does not expose a join for its hidden mutable producer. The adapter uses the
joined whole-clause generation task; cancellation stops output immediately and a busy decoder follows
the existing Apple fallback. Low-latency Qwen streaming remains a separate contract.

## One model at a time and preservation

The runner creates one marked temporary root and one engine process, checks headroom, prepares and
measures, durably saves JSON, joins the process/helpers, removes the root, verifies absence, and only
then returns to start a successor. Failures/timeouts also save before deletion. A save failure retains
that one root and stops the whole comparison. An abrupt parent kill/power loss cannot guarantee cleanup.
The child's TMPDIR is inside its root, covering transient downloads/helpers. No audio files are retained.

Compatible Pocket/Kokoro owner caches are reused through APFS copy-on-write snapshots (`cp -cRL`).
Only the snapshot may be changed by model variant repair. Kokoro requires its existing shared G2P files
rather than fetching outside the owned lifetime. All **104 existing cache files are unchanged by SHA-256
and count**: [preservation witness](owner-cache-preservation.json). No benchmark model root remains:
[final cleanup](final-model-cleanup.json). OS-managed compiled/runtime caches are not swept.

Diagnostic admission keeps 2 GiB plus an engine estimate and independently stops its owned process
group below 1.5 GiB actual free disk. Ordinary app downloads retain 4 GiB. The run explicitly admitted
up to 12 GiB pre-existing swap; this is recorded in each preflight and is not a production policy.
No capture/voice turn waits for this development coordination.

## Actual failures and retries, retained

- Original SwiftBuild planning collided on PhononCore/NemoTextProcessing module maps. Native SwiftPM
  compiles both; Makefile build/test and macOS CI use that backend. Original `native-build.log` is retained.
- The earlier full build failed an inherited benchmark-settings Section/footer overload, narrowly repaired.
  A later attempt caught the benchmark's live runtime reference mistakenly placed in its Codable report;
  that source error is corrected. [Failed full build](native-build-resume.log.gz).
- The combined 891-file module typecheck passes, and the optimized full app links:
  [typecheck](native-typecheck.log), [build](native-build-combined.log.gz),
  [build command/exit](native-build-result.json). Full-app source check passes. The peer's isolated
  Google/stream/clock checks also pass at root; its inherited nested production-tool-loop failure remains
  explicitly outside this TTS acceptance (see the archive integration report).
- Qwen and Kokoro were initially refused before downloads by per-engine disk admission. Useful task-owned
  app object/dependency/diagnostic outputs were retired after successful link; binary, modules and SDKs
  remain. [Exact retirement](retired-app-build-artifacts.json) records 211,435,520 allocated bytes unlinked
  and an observed free-space increase of 212,725,760 bytes; the latter is not a unique attribution.
- Raw SwiftPM linking removed the manually prepared Cmlx bundle. Qwen's guard refused **before weights**.
  The normal Makefile already runs the Metal helper after build; the diagnostic build recipe now does too.
  The exact publisher MLX 0.32.3 archive is verified, its 2,352,104-byte macOS library retained and its
  212,871,838-byte temporary archive deleted. [Post-link packaging](metal-packaging-after-link.log).
- A subsequent Qwen load at 4,153,139,200 free bytes was stopped when actual disk fell below 1.5 GiB.
  Its failed result was saved and 1,698,364,895 logical temporary bytes were deleted after process join:
  [pressure failure](native-qwen/qwen.json). Swap grew; the allocating producer is **unconfirmed**.
  A cache-retention hypothesis was not treated as a diagnosis or patched without evidence.
- After headroom recovered to about 5 GiB, Qwen succeeded with the **unchanged native executable and
  unchanged guards**. This is a different-resource retry, not an original/fixed memory claim. Its model
  was removed before finishing. No simultaneous model downloads or model processes occurred.

## Checks, lifecycle and remaining acceptance

Eight runner tests pass (seven fake-child lifecycle cases plus the tiny actual macOS APFS preservation
check): serial lifetime, save-before-delete, owner preservation, timeout, active low-disk stop, refusal,
save-failure retention and child TMPDIR routing. [Test output](runner-tests-resume.log).

Source checkpoint `16020462` preserves the six reviewed producer/benchmark changes on main. No push,
install, branch or worktree was created. Temporary native probe binaries were deleted. Completed verbose
logs are compressed, saving 23,017,387 bytes; compact source/model/binary pins and all real verdicts remain.
The current useful executable, dependency checkouts/SDK objects, modules and 2.2 MB Metal library remain.
No recordings, personal files, owner model caches or unrelated processes were removed.

Physical-device route changes, rapid real-room barge-in, actual first audible output, settings/preview
clicks, narration UI, linguistic quality and full-duplex ASR-plus-voice reference acceptance remain open.
The new native generation/playback and scoped TTFA comparison are verified; broader release readiness
and model/default promotion are not claimed. The older independent Apple/Piper probe remains intact.
