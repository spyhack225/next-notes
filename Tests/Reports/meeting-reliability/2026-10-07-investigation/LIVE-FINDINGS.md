# Live Google Meet reproduction and producer repair

## Finding

The 7 October live reproduction identifies **unbounded asynchronous recursion in `NeedleServer.ensureRunning`**, the fast listening helper warmed by meeting transcript events. This is no longer merely a hypothesis based on memory totals.

The owner joined Google Meet. Next Notes automatically began a real recording at **12:12:12 EDT**, with its meeting window visible. The pre-recording footprint had been steady around 1.72 GB for several minutes. At the first manual incident snapshot, footprint was **8.912 GB**, including **7.482 GB Malloc Small**; graphics stayed around its original baseline. After pausing, the retained footprint snapshot measured **10.904 GB**, including **10.486 GB Malloc Small**. VM inspection counted about **10.8 million allocations in the default malloc zone**, roughly 9.6 GiB of allocated bytes.

The paused call graph contains roughly **510 consecutive `NeedleServer.ensureRunning` frames** at the same original source line 227, with `swift_task_alloc` at the top. The frame-count extraction counts 512 occurrences including summary lines. These frames are the producer's recursive completed-task branch, not an audio queue, a large notes model, or graphics buffers. The stack and category evidence are retained in `live-1207/incident-paused-*`; numeric meeting events are in `live-1207/meeting-metrics.json`.

## Broken contract

`FunctionCallWatcher.ingest` calls `warmEngine` for transcript events. Each call launches background work through `NeedleRunner.warm` into `NeedleServer.warm`. Multiple callers can reach the same startup concurrently.

Originally, the launch task only returned a child. Its **calling function** adopted the child and cleared `startTask` after awaiting it. Meanwhile, another caller awaited that task with `try?` and recursively called `ensureRunning` again. If this waiter resumed before the launching caller, it could find the same completed task still installed. Repeated immediate awaits recursively retained async contexts and prevented the owner from performing the cleanup that would end the loop. Startup failure was swallowed along the same route. The real stack shows that route repeating while the heap grows.

## Producer repair

The same existing startup task now performs its child adoption, generation check, record write and task cleanup **before completing**. All waiters therefore observe a fully resolved startup. Startup errors propagate to the existing warm/fallback handling instead of recursively revisiting a failed task. No extra model load, scheduler, queue, store, sleep or sequential turn-path await was added.

Changed production file: `Sources/NextNotes/Agent/FunctionCalling/NeedleServer.swift`. The existing `--selftest-function-calls` includes a new maintained `NeedleServerStartupSelfTest` which exercises overlapping real Process/HTTP startup calls using a temporary failing child. Source hashes are in `fixed-source-pins.json`.

## Before/after evidence

The standalone runner compiles the **actual source file intact**, with actual response/buffer types extracted from `NeedleEngine.swift`. Only the logger/first-line dependency wrapper is supplied. It calls the real actor through its public `complete` and `warm` production methods; it does not replace the faulty helper.

| Case | Original | Repaired |
|---|---|---|
| Sixteen concurrent callers, one failing native Process startup cohort | **FAIL**, memory watchdog at 186.959 MB versus 1.754 MB baseline; exit 2 | **PASS**, all16 return errors, exactly three existing launch attempts, about5.1 MB |
| Maintained case: sixteen complete callers, then sixteen meeting warm callers | Not reached by original runaway | **PASS**, all32 settle; exactly three attempts per cohort; no adopted child |
| Actual cached Needle engine/model: sixteen simultaneous cold warms, then completion | **FAIL**, same memory watchdog at186.500 MB vs1.721 MB baseline during the concurrent warms; exit2 | **PASS**, one shared child, one completion, about5.4–5.7 MB parent footprint; own child stopped |

Logs: `startup-original.log`, `startup-original-native.log`, `startup-fixed.log`, `startup-fixed-maintained.log`, `startup-fixed-native.log`. The original source used by the native comparison was verified byte-identical to the incident source hash. Both original watchdog cases stop the disposable test below200 MB, without loading ASR or notes, proving the same defective branch independently of those components. Native control uses the already-cached35 MB helper model, localhost HTTP only, generated tool/facts and a disposable working directory. It downloads nothing and executes no user tools. The runner cleans only a native child whose executable and unique generated system-file path match this test.

These cases prove the startup producer repair. They do not replace the required repaired full-app/physical-meeting acceptance.

## Diagnostic guard failure and correction

The first live monitor used the `footprint` command for each sample. During recording this command timed out after four seconds, and the monitor exited at12:13:01. This was a diagnostic failure: its automatic2.5 GB cutoff did not run. On the next read the app was already8.9 GB; it was manually paused using `SIGSTOP`, preserving the runaway state. This limitation is explicitly retained rather than claiming the original monitor protected the limit.

The corrected monitor reads `proc_pid_rusage` v0 directly through libproc. Its measured query took about0.026 ms. Full category/stack snapshots are triggered separately and cannot block that guard. A disposable200 MB child crossed a100 MB test threshold and was paused within the next0.1-second sampling interval. `guard-validation.log` records the actual pause; the disposable child and diagnostic processes were then removed. The monitor binds the process-start identity to avoid signalling a reused PID.

## Owner recording and application state

Normal capture saved `audio.caf`; the latest observed file was8,138,156 bytes and metadata recorded captured coverage through12:14:15 EDT. The paused app retained roughly10 GB. After a specific approval explaining the effect on the active recording and unsaved words, the owner authorized force-quit. Only the verified paused owner PID1529 was killed. The saved recording and all diagnostic evidence were retained; no metadata was manually rewritten. `live-1207/authorized-force-quit.json` records this action. PID1529 subsequently exited.

The installed binary was not replaced by this investigation. A separate optimized, signed release bundle finished building and was launched normally against the owner’s existing data, without self-test flags or preference overrides. It is `/Users/sergekadjo/Library/Caches/NextNotesBuild/install-14840/Next Notes.app`, executable UUID `8F85CDCD-3E0A-3814-B275-F02C864C844E`. It remains the useful running build; the original installed bundle is retained. Reopening the original installed binary during a live call could re-enter the original bug.

## Repaired full-app and physical recording checks

The maintained startup regression passed in both the existing staged debug app and the newly built release app: all16 failed-start callers and all16 warm callers settled, with exactly three attempts per cohort. The release app also passed health90, integrity67, resource/writer bounds and reconcile-LLM checks. `MEETING_RESOURCES_FAILED_WRITER` in that log labels its injected failed-writer fixture, followed by the real `MEETING_RESOURCES_OK` verdict.

The broader `--selftest-function-calls` flag is **not green**. Debug finished with one native listening-quality mismatch: the “no address anywhere” fixture produced a raw email candidate with confidence0.3025, below the acceptance threshold, and no accepted call. Release passed the new startup case and completed the native phase with the same raw confidence0.3025/no-accepted-call result, then timed out in its local-model fallback phase at180s during concurrent machine load; sampled parent peak583 MB. Its aggregate native quality assertions were therefore not reached, and no native-quality pass is claimed. These are actual failed/open verdicts. This repair does not change the model, confidence gate, fixtures, or fallback logic and does not claim their quality fixed. Full logs/results are retained.

The owner rejoined Google Meet. The repaired release automatically recorded **12:53:52–13:00:27 EDT**, approximately395 seconds, with the actual meeting window visible. The external guard captured2,836 samples during recording. Its sampled peak was **1.421 GB**, versus the original incident’s10.904 GB; footprint at the normal stop was **1.266 GB**. Including startup recovery and post-stop work, the sampled peak was2.068 GB; the2.5 GB diagnostic pause was never reached. The same app then completed final transcription, diarization’s silent-system-track handling and MiniCPM5-2B notes. Saved audio was25,264,688 bytes; metadata records a normal end and full saved coverage through13:00:27, zero missing capture frames and no write failure. There were53 live transcript segments and48 final segments. Transcript counts alone are not word-accuracy evidence.

**Responsiveness acceptance failed during competing work.** The owner reported frozen desktop transitions and choppy video; native UI observations took about114s and72s. A concurrent debug build/model testing and heavy existing paging were present. The same machine snapshot showed roughly7 GB swap used, Chrome processes’ summed charged footprint7.37 GB and Codex processes3.78 GB. Per-process footprint sums include compressed/swapped charges and are not physical RAM totals or unique-memory measurements. This evidence supports contention, not an exclusive attribution of every stall. The owner authorized a pause message to the dictation chat. Competing compiler/test processes subsequently exited. Later checks of the same running meeting app completed in0.41–0.67s and displayed the saved recording and its generated notes. No fresh physical recording after that load cleared has been verified yet.

The selected owner-process logs contain146 generic “capture delivery backlog” messages. **They cannot be counted as meeting loss.** The source emits that string only for subscribers using the default overflow callback; the meeting installs its own overflow callback and health counters. Every observed meeting resource row recorded missedFrames=0 and missedBuffers=0, and saved integrity likewise recorded zero. The emitting consumer is absent from this generic log and remains unidentified. An initial commentary attributed these drops too strongly to the meeting; the correction is retained here.

The native helper startup is independently proved by the real cached-engine concurrent regression. Its actual adopted child was not captured in the physical check, and retained helper-info queries returned no events. Tool preparation files did update during recording. Neither an empty retained log nor a later absent child record proves whether or when it successfully warmed; that consumer observation remains a gap.

Live speech-to-final lag across53 events had median2.017s and maximum6.463s; partial lag had median1.587s and maximum5.872s. These are measurements under competing load, not quiet-machine speed claims. Final-pass/diarization/notes metrics in this interval include the earlier interrupted recording’s recovery as well as the new recording; they must not be attributed entirely to the new call. The short recording’s notes contain a duration mismatch (about two minutes versus395 seconds recorded), and the Actions panel reported a Workspace CLI10-second timeout. The silent system track produced a diarization warning despite microphone speech. These quality/availability findings stay open.

Evidence: `release-build.json`, `release-check-results.json`, `repaired-live-summary.json`, `repaired-meeting-metadata.json`, `repaired-meeting-metrics.json`, `repaired-current-footprint.txt`, `repaired-system-memory.json` and corresponding logs. The guard is a diagnostic, not a production guarantee: OS scheduling during paging can delay sampling even though category/stack collection no longer blocks its loop.

## Remaining optimization work

The original report's measured pressure-policy blind spot remains relevant as defense against another allocator failure. Whole-channel post-stop reads and background index I/O are separate optimization work; neither caused this captured startup recursion. Graphics-baseline suspicion is superseded by the live heap/stack evidence for this incident. No notes-model switch or broad dictation change is needed to repair this producer.

## Integration and retained artifacts

Only the three owned startup producer/self-test files were committed on canonical main as `422ba5f`. Eight unrelated staged files were verified unchanged across that commit. Diagnostic reports remain explicitly retained, uncommitted; no push, PR, worktree or installed-app swap was performed. The useful signed release bundle is118 MB and is running with owner data. Exact owned temporary cleanup and reclaimed bytes are in `cleanup.json`. Original source can be reproduced from `422ba5f^:Sources/NextNotes/Agent/FunctionCalling/NeedleServer.swift`; its hash was verified before deleting the disposable source copy. The final allowlisted inventory contains15 saved meetings (the original13 plus the two live reproductions), with no transcript content.

## Owner-requested installation — 7 October, 13:34 EDT

The owner subsequently explicitly requested installation. The optimized tested release now occupies `/Applications/Next Notes.app` and runs normally with the existing15 meetings, confirmed in the native window. Its SHA-256 exactly matches `release-build.json`, source pins still match commit `422ba5f`, and strict deep signature verification passes. `installed-release.json` records the exact binary/UUID identity, new normal process, attached lightweight guard and retained original-app rollback. Only the verified staged normal process was gracefully terminated; all meetings were terminal first. No owner data/settings or other agent processes were modified. The earlier statements that the installed app was unchanged describe the earlier investigation state.

The superseded owned `install-14840` bundle was removed after checking no active process used it; its tested identity and logs remain. Exact size and total reclamation are in `cleanup.json`. The original installed bundle is explicitly retained for rollback until the new owner meeting check is evaluated. The installed app is ready for that check; no new Meet performance result is claimed by installation.

The owner also requested a shared [performance standard](../../../../PERFORMANCE-STANDARDS.md), an AGENTS.md reference and an agent-relay broadcast of findings/implementation. The standard distinguishes inherited targets, confirmed repairs, measured behavior and outstanding native/quality acceptance.

The full handoff was sent through agent-relay to all four registered project peers as `meeting-performance-20261007-422ba5f-installed` (cursor338), with six source/report attachments, and verified in a recipient inbox. The active dictation chat received a direct notice as well. [The receipt](agent-relay-broadcast-result.json) records delivery; it does not claim anyone has read or acknowledged it. The own [AGENTS.md insertion](AGENTS-performance-section.md) remains saved in the canonical working tree alongside foreign changes and is retained separately for safe integration.
