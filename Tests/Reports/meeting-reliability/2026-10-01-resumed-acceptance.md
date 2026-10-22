# Resumed meeting-reliability acceptance

## Provenance and scope

The owner's continuation request resumes the existing roadmap without changing
its acceptance gates. Tests use the signed staged `install-25062` bundle on the
same Apple M3 / 16 GiB Mac, macOS 27.2 (26B5091g). At preflight the source matched the
final refinement-suite source manifest. Subsequent concurrent workspace edits
are recorded separately; these tests attest to that pinned signed bundle. Executable SHA-256 is
`c0afc53c2eea4b7e8b6105aaa49d9bb584d1e944a11c2a5371032e6aa530f22e`.
The installed production app is not replaced or terminated. No owner preference,
meeting metadata or retained recording is edited.

Local raw evidence and reproducible runners are under
`/private/tmp/meeting-reliability-validation/normal-resumed-1/`,
`normal-resumed-2/` and `physical-resumed-1/`. Reports contain measurements and
verdicts, never private speech or owner-store contents.

## Physical audio and dictation: passed

All three flags launch the same signed bundle through the existing
`Scripts/run-selftest.sh --via-open` path. This changes the responsible-process
launch context; it does not grant permission or modify privacy settings.
A generated 440 Hz, low-amplitude tone supplies nonprivate sound for the physical
audio probes. No microphone recording is retained by these probes.

| Flag | Exit / verdict | Observed evidence |
| --- | --- | --- |
| `--selftest-microphone` | 0 / `MICROPHONE_OK` | After real input-engine recovery, 48 kHz native delivery has 20 buffers / 96,000 samples, peak 0.04815; converted 16 kHz delivery has 20 buffers / 31,780 samples, peak 0.04757. The existing assertion also requires nonzero samples and peaks before recovery. |
| `--selftest-systemaudio` | 0 / `SYSTEM_AUDIO_OK` | Actual 48 kHz stereo process tap delivers 51,024 converted 16 kHz mono frames, RMS 0.04315 and peak 0.06104. |
| `--selftest-dictation` | 0 / `DICTATION_OK` | The existing hold/release fixture completes through the real dictation consumer: “every hold came back to idle.” |

The earlier direct-launch dictation failure remains recorded. This successful
LaunchServices rerun clears that environment block; it does not rewrite the
earlier verdict. Together with the previous 22 verified original suite entries,
all 23 original entries now have a passing signed result across the recorded
runs. This is not a claim that all 23 ran again on this exact final bundle.
The two physical audio probes are short hardware checks, not a long physical
meeting, pressure survival or visible notification-delivery proof. Dictation's
scripted transcript assertions are not an ASR accuracy evaluation.

## Normal-operation comparison: first resumed attempt

Before retrying, a read-only 60-second preflight observed no changes in any
watched owner-store file. Each arm still applies the original full file and
preference guard at setup, identity reads, ASR load, capture and notes shutdown.
The current source and original strict guard are unchanged.

The former-prewarm arm passes, including exact sample readback, actual native
inference and the final owner-store guard. Both tracks contain exactly
2,908,098 saved frames, zero missing originals and no write failure; the CAF is
11,636,488 bytes. Native ASR completes 48 calls, 186.2361 input seconds and
7.8998 compute seconds. Fixture-word recall is 0.9286 microphone / 0.9846 system.
Median / 95th percentile live final-segment lag is 0.4210 / 0.6337 seconds.
The final 30 capture seconds have 30 footprint samples, all with notes loaded;
median process footprint is 151,816,520 bytes. Capture-stage sampled peak is
175,278,432 bytes; CPU is 15.397 seconds. These include harness replay and
sampling overhead, and exclude separate-service/device allocations.
After-stop preparation takes 0.004 seconds; first / warm fixture notes completion
takes 17.366 / 2.946 seconds. Filesystem and CoreML compile-cache conditions are
not cold-storage controlled.

The removed-prewarm arm exits 1 after 93.562 seconds: the real pressure observer
reports **warning**, generation 1, with 8,491,184,128 bytes immediately available
and no cancellation. No warning is injected. The safety guard stops this
normal-condition experiment; its failure must not be credited as a completed
capture, normal-condition comparison or physical survival result.
System swap afterward is 11,264 MiB total / 10,233.50 MiB used. This observation
does not identify the process responsible for pressure. The normal-comparison
test deliberately requires normal pressure throughout capture; a warning here
is not evidence that the production capture path stopped under pressure.

The first arm's passing result and second arm's failed result are both retained.
No paired reduction or operating-envelope ceiling is credited from this attempt.

## Further capacity and pressure checks

A reverse-order retry also passed a 60-second quiet-store preflight, with
observed OS pressure level 1 throughout. Its removed arm exits 1 after 32.795
seconds: pressure is normal (generation zero), but immediate capacity has fallen
to 7,975,870,464 bytes, below the unchanged 8 GB diagnostic minimum. No former
arm is run. This is a capacity rejection, not capture-loss evidence.

Three obsolete signed staged copies made during this work (`install-21209`,
`install-22324`, `install-23179`) were verified and removed. Their pre-removal
allocated size totals 452,628,480 bytes. Binary digests and the cleanup receipt
are retained locally; proof logs, the final build and the before-fix routing build
remain. Owner models, preferences, recordings and production app are untouched.
A further reverse-order preflight measures actual available filesystem bytes:
the minimum is 8,252,706,816 bytes over 60.565 seconds, with no owner-file
changes. However, observed OS pressure levels include both 1 and 2. The
preflight exits 2 without launching a native process. The resource environment
has not remained stable enough for another normal-condition experiment;
no admission threshold or isolation check is weakened to obtain a pass.
Neither earlier failed pair is credited. No additional model load, forced
system pressure or owner-app shutdown is attempted.

## Remaining acceptance

The owner-file and short physical audio/grant blocks have been cleared in the
recorded successful runs. The immediate normal-comparison block is now unstable
system memory pressure, with storage close enough to the diagnostic minimum
to have rejected the prior arm. A stable suitable environment is required to
finish that comparison. A final source comparison detects concurrent edits in
Agent, scheduling, computer and UI files (including meeting views). This
continuation made no source edits. The results apply to the pinned signed bundle,
not a newly built current working tree. The changed-source list and final
manifest are retained locally. `git diff --check` passes. The latest evidence improves acceptance coverage,
but does not complete the parent roadmap.
Native/device allocation attribution, the full upstream audio-byte envelope,
representative long physical overlap and visible warning delivery remain
required. The historical start-time keep-choice discrepancy remains unexplained.
