# Meeting reliability integration — 2026-10-01

Implementation is in progress. This report separates confirmed producer repairs
from acceptance still requiring execution or suitable hardware. No owner meeting
content or raw diagnostic logs are included.

## Producer changes

- The meeting record stores interruption, supported capture boundary, missing
  capture and file-write facts separately from notes-processing state. Recording
  repair persists these facts before dispatch; processing-only repair retains its
  normal Stop time. Store merges preserve facts across stale pipeline saves.
- Meeting startup no longer speculatively loads the notes model. Remembered
  normal/warning/critical pressure controls optional loads, including rechecks
  after waits; required work and active native/voice ownership stay protected.
- The first writer rejection releases abandoned arrays. Pressure recovery requires
  successful writes of original samples, rather than mere queue acceptance;
  trimming permanently revokes that track's recovery authority.
- A bounded, content-free writer progress projection is readable while a native
  file write occupies the writer actor. No lock spans that write. Health reads
  therefore do not wait behind the condition they need to detect.
- Capture loss, missing system capture, storage risk, file rejection and metadata
  rejection have distinct warning producers. Saving lag alone is a risk, not
  confirmed loss. Failed initial system capture keeps its gap after successful retry.
- Retention and final-pass settings explain temporary whole audio and the existing
  up-to-72-hour retention/low-space release contract.

## Storage query measurement

The previous important-use query measured p50 11.26 ms, p95 82.42 ms and maximum
502.24 ms across 200 fresh URLs, and could overstate immediately writable space.
The replacement uses read-only open/fstatfs/close. The actual production function
was compiled into a standalone probe and run 1,000 times with fresh URLs:
p50 **0.010834 ms**, p95 **0.011917 ms**, maximum **0.070542 ms**. Immediate
availability was 205,459,456 bytes at the observation. These are local query-cost
measurements, not a system paging guarantee or a whole-process resource ceiling.

The existing five-second transcript cadence also schedules one health task at a
time. At 64,000 PCM bytes/second, five seconds adds 320,000 bytes of recording.
Checks run off audio callbacks; capacity checks run off MainActor. Warning
scheduling and metadata-write cost under representative load remain unmeasured.
The existing scheduler owns expiry cleanup; no cleanup timer or store was added.

## Build and environment

Two unrelated compile blockers were found and corrected with owner authorization:
a nested task-history fixture lacked MainActor isolation, and AgentView offered
an unimplemented repair action. The unavailable button was removed; retained
history failure remains visible and no storage repair/replay was introduced.

Source compilation/linking completed, but code signing initially failed. The
signature allocator independently reported ENOSPC. Only regenerable dependency
symbol cache was reclaimed; the macOS symbols and original metadata were restored
from the existing archive when the dependency validator required them. The cached
build description was refreshed. No owner models/recordings/stores were removed.
A subsequent source build and signed-bundle checks are pending below.

## Acceptance still open

- Installed new integrity, resource-policy, resource and health fixtures; original
  false-complete before/after proof and related installed regressions.
- Actual normal Stop, capture overflow, isolated process death and rendered warning
  consumers; notification-transport absence is narrower than physical delivery.
- Native loaded-model floor, attributable release effect, CPU/wakeups, equal-build
  normal-efficiency comparison and realistic long-meeting/voice/dictation overlap.
- Current native diagnostic refuses unknown or less than 8 GB immediate storage
  before loading. Safe headroom is unavailable; no real-model result is claimed.
- The recalled keep-audio intent versus saved temporary incident row remains
  unexplained. Start-time snapshot tests cannot retroactively settle that intent.

All MR-01–MR-06 contracts remain open until their own evidence is recorded.
