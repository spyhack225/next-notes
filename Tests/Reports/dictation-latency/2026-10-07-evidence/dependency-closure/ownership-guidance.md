# Exact dictation dependency review (Source7)

This inventory is a read-only proposal, never authority to integrate a whole changed file.
The historical task patch does not establish ownership of later hunks. The canonical
working tree, the seventh frozen source pins and named owner reviews are authoritative.

## Source7 hunks and direct prerequisites

- `ParakeetEngine.swift`: the three-line digital-zero inference-input guard requires the
  existing current `transcribe(_:with:isSegment:)` producer. Its current pipeline uses
  `DictationSegmenter`, `ParakeetInput` and `ParakeetKeyUp`, shared per-pass scheduling,
  captured PCM coverage, session-owned workers and bounded retained PCM. Registry changes
  below the Engine actor include foreign native shutdown/termination seams and require
  that owner's review; do not stage that registry body by default.
- `CleanupRouter.swift`: the nine-line ready-head shortcut requires its current
  `resolvePrecleanGroups`, `CleanupHead.completed` from `IncrementalCleanup.swift`, the
  existing same-task completion producer and `withBoundedWait`. Keep deterministic spoken
  structure, final global planning, sentence remapping, dictionary and tagging behavior.
  Later controller/semantic admission/preview work is required for the real consumer flow.

## Mixed ownership that must be split by exact lines

| Path | Dictation review scope | Other ownership / open boundary |
|---|---|---|
| NotesModelRuntime.swift | resident-file admission, cleanup native reservation, explicit selection, prefix preservation, phase spans | Root optional completion admission/loading checks and native lifecycle helpers; review together where signatures share a hunk |
| ComputeScheduler.swift | immediate cleanup lane acquisition and parked-checkpoint attribution | Existing cancellation/priority/native reservation semantics; preserve root and previously integrated fixes |
| DictationController.swift | accepted capture drain, committed pre-cleaning, finishing preview, private replay, correlation and delivery guards | Other command/voice/UI consumers; all live shared fields still forbid overlapping holds (D-13 remains open) |
| AudioCaptureHub.swift | stop admission synchronously and drain accepted dictation packets; same producer regression | Foreign physical PCM/route/meeting/termination work; no buffer-size or queue-budget change |
| NextNotesApp.swift | named dictation/segments/polishing/router regression dispatch only | Root bounded-reader/pause/context-order flags and numerous foreign task/model/UI flags; never stage the whole dispatcher |
| IslandPanel/State/View, HUDView, DictationView | retained bounded live words and finishing progress | Agent/voice presentation and unrelated UI work; exact owner review needed |
| Makefile / Scripts/dictation-gates.sh | explicit optimized app verification and relevant dictation flags | Native framework/build lifecycle and other release gates; preserve those owners' contracts |

The remaining inventory paths identify referenced definitions/tests/consumers for review.
Files with an empty diff are already-present dependencies, not work to recommit. Native
capacity, copied-token decoding, new cadence, rejected compact layout transports and the
new retired-pass metric patch are excluded. Build linkage alone does not accept quiet
words, full polishing speed, physical display/insertion or an owner store migration.
