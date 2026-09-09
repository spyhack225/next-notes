# Speechify

Push-to-talk dictation for macOS. Hold a key, talk, release — cleaned-up text lands in
whatever text field has focus. A Wispr Flow-shaped app, built native and fully on-device.

**Status:** the macOS app is in daily use. It supports Apple and Parakeet transcription,
deterministic or on-device LLM cleanup, personal dictionary bias and corrections, and an
opt-in voice Command Mode for editing selected text. It also records meetings: the
microphone and the system's own output are captured as two separate tracks and transcribed
separately, which is where the "You" and "Others" attribution in a meeting transcript comes
from. A finished recording then walks itself the rest of the way — tell the speakers on the
system track apart, write Granola-style notes with a local LLM, and offer follow-up actions
in Gmail, Calendar, Drive and Docs that only happen if you approve them. Everything runs on
this Mac; the only network traffic is a model download, your own calendar, and a Workspace
action you approved. The Windows app builds and is exercised in CI, but has not yet been
used for a real microphone/key/injection session on Windows hardware.

**Meetings record themselves by default.** Once Calendar access is granted, Speechify reads
your calendars (Apple Calendar through EventKit, and optionally Google Calendar through its
API), and any event that looks like a real meeting — a conference link or at least one other
attendee, not all-day, not declined — is armed a minute before it starts and recorded when
it does. It announces itself first with a notification carrying **Record now** and **Skip**,
every event has its own Record checkbox in the Upcoming list, and the whole behaviour is one
switch in Settings ▸ Meetings (*Record calendar meetings automatically*, with the lead time
beside it). Turn that off and meetings only record when you press the button.

**Pressing Stop is not the end of a meeting.** The session writes the transcript and hands
the meeting to a pipeline that runs on its own: optionally identify the speakers on the
system track, then write the notes, then — if the Workspace agent is enabled — read the
notes and propose what to do about them. Each stage has its own status in the meeting list
(*Identifying speakers*, *Writing notes*), so the Record button comes back long before the
Notes tab fills in.

**The island.** On a MacBook with a notch, Speechify's status lives in a small card hugging
it — what is being dictated, a meeting about to start with **Record now** / **Skip**, the
elapsed recording, notes being written, and an agent proposal with **Approve** / **Dismiss**.
Hover expands it. On a display without a notch it is a floating capsule under the menu bar,
and Settings ▸ Dictation can put dictation back on the old bottom-of-screen HUD instead.

---

## Coexisting with another dictation app

This app is built to run alongside other dictation tools without colliding with them, which
is not automatic on macOS and is worth understanding before changing anything:

- **Bundle ID `ai.pivotstudio.speechify`** — TCC keys Accessibility and Microphone
  grants to the bundle ID, so granting or revoking a permission here has no effect on any
  other app, and vice versa.
- **Executable `Speechify`** — distinct enough that `pkill -x Speechify` cannot
  match a differently-named binary. The `Makefile` only ever targets `$(EXEC)`.
- **Hotkey is configurable** (Right ⌥ / fn / Right ⌘) precisely because another tool may
  already own the key you'd reach for first. The event tap inspects only its own keycode
  and passes everything else through untouched.

If you run more than one dictation app, give each a different push-to-talk key. Two apps on
the same key both record, and whichever injects text will fight the other.

---

## Quick start

```bash
make install     # builds, bundles, signs, copies to /Applications, launches
```

Then grant these permissions — none is optional, and none can be requested silently:

| Permission | Where | Needed for |
|---|---|---|
| **Accessibility** | System Settings ▸ Privacy & Security ▸ Accessibility | The `CGEventTap` that sees the hotkey, and the AX text insert |
| **Microphone** | Prompted on first dictation | Audio capture |
| **Audio Recording** | System Settings ▸ Privacy & Security ▸ Audio Recording, after the first meeting | The process tap that records what the other people in a meeting say |
| **Calendar** | Prompted from Settings ▸ Calendar, or the onboarding checklist | Reading which meetings are coming up, so they can record themselves |
| **Notifications** | Prompted at first launch | The armed-meeting alert, "notes are ready", and agent proposals |

Audio Recording is the odd one out: there is no API to ask whether it was granted, and a
tap without it succeeds and returns pure silence rather than an error. So the Permissions
checklist shows that row as unanswerable, and a flat "Others" meter during a meeting is the
only symptom you will get. `--selftest-systemaudio` reports `SYSTEM_AUDIO_SILENT` for the
same reason, and `tccutil reset AudioCapture ai.pivotstudio.speechify` resets that one row.

Restart Speechify after granting Accessibility. Then hold **Right ⌥** and talk.

### How rebuilds affect grants

TCC stores a *code-signing requirement* per entry, not just a path. An ad-hoc signature
changes on every build, so the rebuilt binary stops satisfying the stored requirement —
and the symptom is nasty: the Accessibility toggle still **shows as on** while the app is
reported untrusted, and flipping it changes nothing because the stale row is the problem.

The `Makefile` auto-detects a stable Developer ID through `security find-identity` and falls
back to ad-hoc signing. Developer ID builds retain their grants across rebuilds. Ad-hoc builds
need a fresh Accessibility grant after each rebuild; Speechify now detects that the event tap
did not arm, shows the repair action, and retries automatically after the grant is restored.

If a grant ever does get wedged, reset that one row and re-add — never toggle:

```bash
tccutil reset Accessibility ai.pivotstudio.speechify
tccutil reset Microphone   ai.pivotstudio.speechify
```

Always pass the bundle ID. A bare `tccutil reset Accessibility` wipes **every** app on the
machine. Then quit System Settings entirely (⌘Q) before reopening — that pane caches its
list and will otherwise show the row you just deleted.

> **Keep the build out of iCloud.** `~/Desktop` and `~/Documents` are file-provider synced
> on this machine; the sync engine can materialize/dematerialize files inside an `.app` and
> corrupt its signature. `make install` puts the running copy in `/Applications`.

Other targets: `make app` (bundle only), `make run` (run in place), `make clean`.

---

## Architecture

```
 hold key ─► HotkeyMonitor ──► DictationController ◄── Settings
                                │
                     ┌──────────┼──────────┐
                     ▼          ▼          ▼
              AudioCapture  HUDPanel   TranscriptionEngine
                     │                      │
                (AudioChunk) ──ordered──► AppleSpeechEngine
                                            │
                                       (transcript)
                                            ▼
                                      TextFormatter
                                            ▼
                                      TextInjector ─► focused app

 selected text ─► Command hotkey ─► speech command ─► Foundation Model
                                                              │
                                                              └─► guarded replacement

 calendar ─► CalendarService ─► MeetingScheduler ─► MeetingController
                                                          │
                                              ┌───────────┴───────────┐
                                              ▼                       ▼
                                        AudioCapture          SystemAudioCapture
                                          (You)                    (Others)
                                              │                       │
                                        ChunkedTranscriber ──────────┘
                                              │ (Parakeet, one queue)
                                              ▼
                                        MeetingPipeline
                                              │
                          ┌───────────────────┼───────────────────┐
                          ▼                   ▼                   ▼
                  DiarizationService    NotesService        AgentService
                  (speaker labels)      (local LLM)      (proposals, approved
                                                          one at a time)
```

### Decisions worth knowing

**The HUD must never take focus.** `HUDPanel` is a `.nonactivatingPanel` with
`canBecomeKey == false`. This is the load-bearing detail of the whole app: if the overlay
took key status, the user's text field would lose focus and there'd be nothing left to
inject into. Everything else is replaceable; this isn't.

**The hotkey needs a `CGEventTap`, not `NSEvent`.** `fn` and left/right modifier
discrimination don't surface through `NSEvent.addGlobalMonitorForEvents` or the Carbon
hotkey API. A session event tap is the only way to see them — which is why Accessibility
permission is a hard requirement rather than a nicety.

**Audio ordering is explicit.** `AudioCapture` yields into an `AsyncStream` drained by a
single task. Spawning a `Task` per buffer would be simpler and would silently corrupt the
transcript, because unstructured tasks have no ordering guarantee.

**Buffers are copied, never borrowed.** `AVAudioEngine` recycles the buffer it hands to a
tap the instant the callback returns. `AudioChunk`'s `@unchecked Sendable` is only sound
because `AudioCapture` always allocates fresh storage before handing off.

**Three swappable seams.** `TranscriptionEngine`, `TextFormatter`, and
`TextCommandProcessor` are protocols so speech recognition, transcript cleanup, and selected
text editing can change providers without rewiring capture or injection.

### Layout

```
Sources/Speechify/
├── SpeechifyApp.swift              @main, AppDelegate, MenuBarExtra
├── Core/
│   ├── DictationController.swift   state machine, wires everything
│   ├── HotkeyMonitor.swift         CGEventTap on .flagsChanged
│   ├── AudioCapture.swift          AVAudioEngine tap on the microphone
│   ├── SystemAudioCapture.swift    Core Audio process tap on everything the Mac plays
│   ├── AudioConversion.swift       format conversion + RMS, shared by both captures
│   └── TextInjector.swift          AX selection capture/insert, pasteboard+⌘V fallback
├── Transcription/
│   ├── TranscriptionEngine.swift   protocol + AudioChunk
│   ├── AppleSpeechEngine.swift     SpeechAnalyzer / SpeechTranscriber
│   └── ParakeetEngine.swift        local FluidAudio/CoreML batch ASR
├── Formatting/
│   ├── TextFormatter.swift         protocol + RuleBasedFormatter
│   ├── FoundationModelFormatter.swift
│   ├── S1MiniFormatter.swift       local llama.cpp cleanup
│   ├── FoundationModelCommandProcessor.swift
│   └── LLM/
│       ├── LlamaBackend.swift      one llama.cpp backend for both local models
│       ├── LlamaHelpers.swift      tokenize/detokenize/batch, shared
│       ├── LLMProvider.swift       protocol + LLMProviderID, provider resolution
│       ├── NotesModels.swift       the Qwen3.5-4B ModelSpec
│       ├── NotesModelRuntime.swift the notes model, Metal-offloaded, self-unloading
│       ├── LlamaLLMProvider.swift  Qwen behind the protocol
│       └── FoundationModelLLMProvider.swift   Apple's on-device model behind it
├── Calendar/
│   ├── CalendarProvider.swift      MeetingEvent + the protocol both accounts implement
│   ├── CalendarService.swift       every enabled calendar merged, polled, deduped
│   ├── EventKitCalendarProvider.swift  the Mac's own calendars
│   ├── ConferenceURLDetector.swift Zoom/Meet/Teams/Webex links in a location or note
│   ├── FakeCalendarProvider.swift  --fake-calendar: one meeting 90 seconds out
│   └── Google/                     OAuth (PKCE + loopback), Keychain token store,
│                                   DTOs, and the Calendar API provider
├── Meetings/
│   ├── MeetingModels.swift         Meeting, MeetingStatus, TranscriptSegment, AudioSource
│   ├── MeetingStore.swift          one directory per meeting under Application Support
│   ├── ChunkedTranscriber.swift    cuts a live track into windows, one per audio source
│   ├── MeetingAudioWriter.swift    stereo CAF, left = you, right = everyone else
│   ├── MeetingSession.swift        one recording: both captures, both transcribers
│   ├── MeetingScheduler.swift      arms, starts and stops calendar meetings on a 30 s tick
│   ├── MeetingController.swift     the single place a meeting starts or stops
│   ├── MeetingPipeline.swift       what happens after the last window: diarize, then notes
│   ├── MeetingDiarizer.swift       FluidAudio clustering over the system track
│   ├── DiarizationService.swift    owns the .diarizing → next transition, per meeting
│   ├── NotesPrompts.swift          every prompt and the five headings
│   ├── NotesGenerator.swift        single pass, or map/reduce when the transcript is long
│   └── NotesService.swift          owns the .summarizing → .done transition
├── Agent/
│   ├── GoogleWorkspaceCLI.swift    locates `gws`, reads its auth state, runs it
│   ├── WorkspaceTools.swift        the eleven-tool catalogue and its risk classes
│   ├── WorkspaceToolRunner.swift   the only place a `gws` write is performed
│   ├── AgentModels.swift           AgentRisk, AgentProposal, AgentActionRecord
│   ├── AgentPrompts.swift, AgentToolCall.swift, LLMProviderTools.swift
│   ├── MeetingAgent.swift          plans over notes + transcript, returns proposals
│   ├── AgentService.swift          files, announces, and executes approved proposals
│   └── WorkspaceInstaller.swift    writes the .command scripts Terminal opens
├── UI/
│   ├── DesignSystem.swift          every colour, size, radius, duration token
│   ├── MainWindow.swift            NavigationSplitView shell
│   ├── Sidebar.swift               section list, plus the live "Recording" row
│   ├── HUDPanel.swift              non-activating floating panel
│   ├── HUDView.swift               capsule: red dot + level bar + transcript, glass
│   ├── Island/                     IslandGeometry (where the notch is), IslandPanel,
│   │                               IslandState (what to show), IslandView
│   ├── Components/                 LevelMeter (+LevelBar), RecordingIndicator,
│   │                               ModelStatusRow, CopyButton, StatusChip, MarkdownView,
│   │                               ProblemBanner, FlowLayout, ThinkingOrbs/
│   ├── Dictation/                  DictationView, TranscriptionRow
│   ├── Dictionary/                 DictionaryPanel
│   ├── Comparison/                 ComparisonView
│   ├── Meetings/                   MeetingsView, MeetingLiveView, MeetingDetailView,
│   │                               TranscriptView, MeetingActionsView,
│   │                               ProposalArgumentsSheet, SpeakerNamesSheet
│   ├── Onboarding/                 PermissionsChecklist, OnboardingSheet
│   └── Settings/                   SettingsWindow + one Form per tab: General, Dictation,
│                                   Meetings, Calendar, Workspace, Models, Permissions
└── Support/
    ├── Settings.swift, LocalModelStore.swift, Permissions.swift, Log.swift
    ├── ModelDownloader.swift       one ModelSpec download path with progress + SHA-256
    ├── Notifications.swift         armed meetings, notes ready, agent proposals, and
    │                               the action buttons on each
    └── NavigationState.swift       which section is showing
```

### Self-tests

Each flag runs one thing and exits, so a subsystem can be answered from a terminal instead
of by using the app. Run them from the installed bundle:

```bash
S=/Applications/Speechify.app/Contents/MacOS/Speechify

$S --selftest-s1                    # S1-mini cleanup through the shared llama.cpp backend
$S --selftest-parakeet              # Parakeet loads and transcribes a silent second
$S --selftest-systemaudio           # 3 s process tap: frames, format, peak, RMS
$S --selftest-transcribe <wav>      # WAV → ChunkedTranscriber → segments JSON + RTF
$S --selftest-calendar              # provider states, deduped events, auto-record rules
$S --selftest-notes <wav> [--diarize]   # transcribe → notes; prints tok/s and peak RSS
$S --selftest-llm-metal             # a Metal runtime and a CPU runtime in one process
$S --selftest-island                # island geometry per display, panel invariants, states
$S --selftest-orb                   # the four ThinkingOrb modes at both sizes
$S --selftest-gws                   # locate `gws`, read its version and auth state
$S --selftest-agent <meeting-dir>   # proposals as JSON; executes nothing
```

Each prints a single `<NAME>_OK` or `<NAME>_FAILED` line last, so they can be read by a
script. Two are worth knowing about in detail:

`--selftest-calendar` prints each provider's state, what it would record out of the next
day, and the result of running the auto-record rules over invented events — that last half
needs no account and no grant, so a change that starts recording declined invitations or
all-day blocks fails it anywhere. `--selftest-agent` likewise checks the tool catalogue,
the `<tool_call>` parser and the risk gate without a Google account, so it is runnable on a
machine where `gws` was never signed in.

`--fake-calendar` is not a self-test but a modifier: it replaces every real provider with
one invented meeting starting 90 seconds out, so the whole armed → notified → recording →
done path can be watched without waiting for a real meeting. It never runs alongside the
real calendars, so a test can't record something that is actually happening.

---

## Meetings

A meeting is a directory under `~/Library/Application Support/Speechify/Meetings/<uuid>/`
holding `meeting.json`, `transcript.json`, `notes.md`, `proposals.json` and — while one is
needed — `audio.caf`. Nothing about a meeting lives only in memory, which is what lets the
app be quit in the middle of one and repair it at the next launch.

**Two tracks, never a mixdown.** The microphone and a Core Audio process tap on everything
the Mac plays are captured, transcribed and stored separately, and that is where "You" and
"Others" come from. `ChunkedTranscriber` cuts each track into windows — the first pause
after 30 seconds, hard cut at 60 — and one `TranscriptionQueue` serialises Parakeet across
both. The known cost of using the built-in microphone with laptop speakers is that remote
voices bleed onto the mic track.

**Speakers.** With *Tell the other speakers apart* on (Settings ▸ Meetings), FluidAudio's
offline diarizer clusters the system track after the recording and the clusters are mapped
onto transcript segments by overlap, giving *Speaker 1…n* — renamable, with the invite's
attendees offered as suggestions. Labels land per sentence: a transcription window is split
on pauses and sentence endings before it is stored, so each turn carries its own speaker
rather than the whole window taking whoever held most of it.

**Notes.** `NotesGenerator` writes markdown under five fixed headings — Summary, Key
points, Decisions, Action items, Open questions — in one pass when the transcript fits the
model's context, and otherwise by mapping chunks to attributed facts and reducing them.
Two providers are interchangeable and either can be picked per meeting from **Regenerate**:

| Provider | Where it runs | Context | Notes |
|---|---|---|---|
| **Qwen3.5-4B Q4_K_M** (default) | bundled llama.cpp, Metal | up to 32K here | 2.74 GB download from Settings ▸ Models; frees itself ten minutes after the last generation |
| **Apple Foundation Models** | the OS | 4096 tokens | no download; long transcripts always take the map/reduce path |

Notes are written automatically when a recording finishes (*Write notes when a meeting
ends*), and **Regenerate** rewrites them with either provider afterwards.

---

## The Workspace agent

Optional, off until you turn it on, and it is a proposer rather than an actor. After a
meeting — and, if *Watch during the meeting* is on, every two minutes during one — the same
local LLM reads the notes and transcript and returns proposals: create a Doc with the notes,
email the action items to the people who were on the invite, put a dated follow-up on the
calendar. They appear in the meeting's **Actions** tab, on the island, and as a notification.

Tools are performed by Google's [`gws` CLI](https://github.com/googleworkspace/cli), which
Settings ▸ Workspace installs and signs in through Terminal — four states, each with the one
next step it needs. Nothing is silent: `gws` is never installed, authorised or signed into
behind your back, and the tab shows the whole catalogue.

Every tool is graded by what cannot be taken back, and the grade decides who presses the
button:

| Class | Tools | Behaviour |
|---|---|---|
| **read** | `search_email`, `get_agenda`, `find_drive_files`, `read_doc` | Run by the agent itself while it plans, if *Let it look things up* is on |
| **write** | `create_doc`, `append_doc`, `upload_to_drive`, `create_event`, `draft_email` | One approval each |
| **send** | `send_email`, `reply_email` | One approval each, with the full message shown first, and only from the Actions tab |

Arguments are editable before approval, results (a document link, an event, a message id)
are recorded on the meeting, and an unanswered proposal survives a quit.

---

## Speech engine

Default is Apple's **`SpeechAnalyzer` / `SpeechTranscriber`**, new in macOS 26: no
dependency, no bundled model, no cloud path, real streaming with `.volatileResults` so
text appears while you're still talking. The OS downloads and manages model assets, so the
first run for a locale may pause on `AssetInstallationRequest`.

The other built-in choice is **Parakeet v3** via FluidAudio and CoreML. Speechify validates
every required model artifact before marking it ready and prepares it when selected. The
encoder currently uses deterministic CPU placement because accelerator compilation can
stall or wedge on macOS 26.
Both engines feed the same cleanup, dictionary, history, and injection pipeline.

| | Apple SpeechTranscriber | Parakeet v3 (FluidAudio) |
|---|---|---|
| Dependency | none | SwiftPM |
| Model download | OS-managed | one-time, about 470 MB |
| Processing | streaming | batch on key release |
| Compute | OS-managed | local CoreML, CPU placement |

---

## Formatting, dictionary, and Command Mode

- **Rule-based cleanup** removes common fillers, interprets spoken line/paragraph markers,
  fixes spacing, capitalizes sentences, and adds terminal punctuation.
- **On-device cleanup** is selectable in Settings. Apple's Foundation Models formatter
  handles false starts, spoken self-corrections, paragraphing, and list formatting. S1-mini
  by Superwhisper is an embedded open-weight transcript normalizer; Speechify downloads its
  462 MiB Q4 model once, verifies its SHA-256 digest, and runs it through the bundled
  llama.cpp runtime with no network request during formatting. Both fall back to the
  deterministic pass when unavailable or unsuccessful.
- **Cleanup controls** expose five user-facing tone positions, list formatting, and a
  general/email context. S1-mini natively has four controls, so Balanced maps to its
  semi-formal control; the Apple formatter receives all five directly.
- **Personal dictionary** entries are supplied to Apple Speech as short
  `AnalysisContext.contextualStrings` before audio arrives. Correction pairs then run
  deterministically after cleanup on both macOS and Windows. This implements names and short
  jargon; pronunciation-trained `SFCustomLanguageModelData` models are not built.
- **Command Mode** is opt-in. Select editable text, hold its independently configured second
  hotkey, and speak an instruction such as "make this more formal." Speechify snapshots the
  AX selection, applies the instruction with Apple's on-device model, and replaces it only if
  focus and selection are unchanged. A timeout/model failure leaves the source text intact.

## Landing page

`docs/` is a self-contained landing page for GitHub Pages — one `index.html` with its CSS and
JavaScript inline, the app icon beside it, and a `.nojekyll` marker so Pages serves the files
as written rather than running them through Jekyll.

To publish it: **Settings ▸ Pages ▸ Source: Deploy from a branch**, branch `main`, folder
`/docs`. That is the whole setup — no workflow and no build step — and the site appears at
`https://per-simmons.github.io/murmur-youtube/`. Editing `docs/index.html` and pushing
redeploys it.

The orb on the page is not a picture. Its `listening` geometry is ported from
`OrbGeometry.swift`, using the same preset the app resolves at the large size, so the mark on
the site is the mark in the app. It honours `prefers-reduced-motion` by freezing on the same
frame the app does.

The page claims no download, because there is no signed release to download — it tells people
to build from source, which is the truth. If a release ever ships, that section is the one to
change.

## Not built yet

1. **Claude cleanup/command provider.** The formatter and command processor have seams for a
   server-backed higher-quality tier, but no credential storage, consent UI, or network path
   is present.
2. **Windows local cleanup.** S1-mini by Superwhisper is a strong candidate; the integration
   design and constraints are in [`docs/S1-MINI-WINDOWS.md`](docs/S1-MINI-WINDOWS.md).
3. **Notarization and Windows distribution signing.** Local macOS builds use a stable
   Developer ID when available, but neither platform has a complete distribution pipeline.
4. **Meetings on Windows.** Everything from the process tap onwards is macOS-only; the
   Windows app is still dictation.

### Written but never exercised end to end

Every one of these compiles, has a self-test where a self-test is possible, and has never
had the one real thing it needs:

- **The system-audio tap with its grant.** `--selftest-systemaudio` has only ever reported
  `SYSTEM_AUDIO_SILENT` here, and no recording has yet contained an "Others" track.
- **Qwen3.5-4B.** Never downloaded on the development machine (it needs ~7 GB free: the
  model plus the downloader's 4 GB reserve), so its SHA-256 is not pinned yet and every
  notes run so far has used Apple Foundation Models.
- **Google Calendar.** The OAuth loopback flow, the token store and the provider are
  written; no account has been connected. It needs your own Desktop-type OAuth client.
- **Apple Calendar.** Compile-verified only — the Calendar grant has not been given here.
- **Workspace writes.** `gws` reports no credentials on this machine, so no proposal has
  ever been approved and no Doc, event or email has been created by the agent.

---

## Verified

Driven with a synthetic Right ⌥ hold (`scratchpad/ptt/ptt2.swift` posts `flagsChanged`
events) and confirmed via `/usr/bin/log show --predicate 'subsystem ==
"ai.pivotstudio.speechify"'`:

- Builds clean under Swift 6 strict concurrency.
- Signs with Developer ID when one is installed. Ad-hoc development builds require a fresh
  Accessibility grant after rebuilding because macOS keys that permission to the signature.
- Launches as a regular macOS app with its main window and menu bar item present.
- Event tap arms on grant without a restart (the poller catches it).
- Full state machine: `starting → listening → finishing → idle`, no errors.
- `SpeechAnalyzer` starts; models already installed, no download stall.
- Audio capture runs and converts native 48 kHz → 16 kHz for the engine.
- HUD renders bottom-center, at the size `DS.Size.hud` names, without taking focus.
- Silence produces an empty transcript and injects nothing.
- A WAV goes through `ChunkedTranscriber` to segments, and those segments to notes with all
  five headings (`--selftest-notes`).
- A Metal-offloaded llama.cpp runtime and a CPU one are alive and correct in one process
  (`--selftest-llm-metal`) — the gate on sharing one backend between the two local models.
- The island panel appears at the right frame on each attached display, never becomes key,
  and passes clicks through outside its own rectangle (`--selftest-island`).
- The auto-record rules over invented events, and the agent's tool catalogue, parser and
  risk gate (`--selftest-calendar`, `--selftest-agent`) — both need no account.

**Nobody has looked at the redesigned UI or the island on screen.** The self-tests prove
geometry and behaviour, not appearance: hover-to-expand, the growth out of the notch, the
sidebar in light and dark, and the onboarding sheet are all unverified by eye.

**Command Mode still needs a manual app-compatibility pass.** AX selection reading is only
available in editable accessibility text elements, and Electron/browser editors vary in how
faithfully they implement it. The implementation refuses to replace text when the captured
selection cannot be revalidated.

> `log` is shadowed in this shell — use `/usr/bin/log` explicitly or it returns nothing.
