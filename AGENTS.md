# Working on this repo

Read this before changing anything. It is written for a coding agent picking the project up
cold, and it is mostly a list of things that look wrong but aren't, plus things that look
fine and will bite you.

---

## What this is

Push-to-talk dictation. Hold a key, talk, release, and cleaned-up text is typed into
whatever had focus. Two independent implementations:

| | macOS | Windows |
|---|---|---|
| Language | Swift 6 | C# / .NET 10 |
| UI | SwiftUI | Avalonia |
| Speech | Apple `SpeechAnalyzer`, or Parakeet via FluidAudio | Parakeet via sherpa-onnx |
| Location | repo root | `windows/` |

**The macOS app works and is in daily use.**

The macOS app is no longer only dictation, and the second half of it is younger and far
less exercised than the first. It reads the calendar (EventKit and, optionally, the Google
Calendar API), arms and records a meeting on its own, captures the microphone and a Core
Audio process tap as two separate tracks, transcribes both with Parakeet, tells the
speakers on the system track apart, writes notes with a local Qwen3.5-4B (or Apple
Foundation Models), and — when it is switched on — proposes follow-up actions in Gmail,
Calendar, Drive and Docs through Google's `gws` CLI, which a person approves one at a time.
Its status shows in a card at the notch. None of that exists on Windows and none of it is
in scope there.

Where the code lives: `Calendar/`, `Meetings/`, `Agent/`, `Formatting/LLM/`, `UI/Island/`,
one section per `UI/<Section>/`, one Settings tab per file in `UI/Settings/`. The tree in
`README.md` is kept current and is the map.

Every subsystem has a `--selftest-…` flag, and adding one for new work is the convention
rather than a courtesy — most of this app needs a permission, a model or an account that a
coding agent cannot obtain, so a flag that answers one question from a terminal is usually
the only verification available. They live in `SpeechifyApp.runRequestedSelfTest` and each
prints one `<NAME>_OK` / `<NAME>_FAILED` line last:

```
--selftest-s1        --selftest-parakeet   --selftest-systemaudio
--selftest-transcribe <wav>                --selftest-calendar
--selftest-notes <wav> [--diarize]         --selftest-llm-metal
--selftest-island    --selftest-orb        --selftest-gws
--selftest-agent <meeting-dir>             --selftest-cleanup [engine]
--selftest-dictation --selftest-calls
```

A self-test must **fail** when the thing it names did not happen. `--selftest-systemaudio`
reporting `SYSTEM_AUDIO_SILENT` on a zero peak, and the Metal probe failing on zero
generated tokens, are the shape to copy: on this machine most of these run without the
grant or the model they are really about, and a probe that passes anyway is worse than none.

**The Windows app is complete but has never run on real hardware.** Every layer exists;
CI builds it, runs 63 tests, publishes a single-file executable, launches it on Windows and
confirms the platform layer loads and constructs. What has never happened is a person
holding the key and speaking into a microphone. Describe it that way — not as "working",
not as "unfinished".

---

## The one rule that matters

**`shared/dictionary-test-vectors.json` is the specification for correction behaviour.**

Both implementations run it in CI. If you change how corrections work, change the vectors
first, watch both sides go red, then make them green. Changing one implementation to "fix"
a failing vector without changing the other is how the two silently diverge — and only one
of them can be exercised by hand.

```bash
make test                                          # macOS side, the vectors and nothing else
cd windows && dotnet test Speechify.CrossPlatform.slnf # Windows side, runs anywhere
```

(`make test`, not a bare `swift test`, for the same scratch-path reason as `make build`
below.)

The Swift copy at `Tests/SpeechifyDictionaryTests/dictionary-test-vectors.json` is a copy, and
CI fails if it drifts from `shared/`. After editing the shared file:

```bash
cp shared/dictionary-test-vectors.json Tests/SpeechifyDictionaryTests/
```

---

## Things that look like bugs and are not

**Transcript text in the Dictation list cannot be selected with the mouse.** Deliberate. The
list is a multi-select `List`, and selectable text competes with row selection for the same
mouse-down: with `.textSelection(.enabled)` on the transcript, clicking the body of a row
places a caret instead of selecting the row, and the body is most of the row. Copy is on the
hover button and the context menu, for one row or for many. If free text selection is wanted
back it belongs in a detail view, not in the list.

**A self-test must never call `RunLog.record`.** `DictationController` takes a `record:` seam
exactly like `insert:`, and `--selftest-dictation` passes `{ _ in }`. Without it the test files
its fixtures into the user's own Dictation history — it did, silently, until 2026-09-09, and
55 rows of "Self test transcript." had to be cleaned out of a real machine's `runs.jsonl`.
If you add a self-test that drives the controller, pass both seams.

**`dotnet build Speechify.sln` fails on macOS** with `NETSDK1073`. Expected —
`Speechify.Platform.Windows` targets `net10.0-windows`. Use `Speechify.CrossPlatform.slnf`, which
omits it; everything else, including the whole UI suite, builds and tests on macOS in about
half a second.

**`swift build` fails with "input file was modified during the build."** The repo lives in an
iCloud-synced folder and the sync engine touches files mid-compile. **Always build with
`make`**, which uses `--scratch-path` outside the synced tree. A bare `swift build` also
writes a `.build/` directory into iCloud, which makes every subsequent build minutes slower.
If you see this error, wait a few seconds and retry.

**Compare mode doesn't type anything.** By design — `Settings.compareMode` runs every engine
on one recording and shows them side by side. If both injected, two transcripts would fight
over one text field. This is the single most confusing behaviour in the app.

**The timing column isn't comparing like with like.** Apple and Parakeet are timed on local
compute with the clock started *after* model load. Wispr Flow's number is its own
`e2eLatency`, which includes a network round trip and its cleanup pass. Don't present them
as one ranking.

**`MainActor.assumeIsolated` will crash the process.** It does not check the claim, it
asserts it. Use `await MainActor.run` from any non-main-actor context. This took the app
down once already.

**Mutating `@State` inside a `Canvas` draw closure floods the log and corrupts state.** The
VU meter keeps its needle physics in a plain reference type the view merely holds, which is
invisible to SwiftUI's state graph. Don't "clean that up" into `@State`.

**A system-audio tap without permission returns silence, not an error.** Every call in
`SystemAudioCapture` succeeds — the tap is created, the aggregate device is created, the
IOProc runs at the right rate — and every sample is zero. The only trace is
`Client is not granted access to the tap` from `coreaudiod` in the unified log:

```bash
/usr/bin/log show --last 5m --predicate 'process == "coreaudiod"' | grep "access to the tap"
```

So nothing in the app claims to know whether system audio is allowed: the Permissions
checklist shows that row as unanswerable, and `--selftest-systemaudio` reports
`SYSTEM_AUDIO_SILENT` rather than success when the peak is zero. Like Accessibility, the
grant is keyed to the code signature, so it has to be re-granted after an ad-hoc rebuild —
`tccutil reset AudioCapture ai.pivotstudio.speechify` resets that one row.

**Every await in the dictation tail has a deadline, and the deadlines are the point.**
`DictationController.endDictation` drains the audio, calls `engine.finish()`, awaits the
transcript stream and then the cleanup pass. All four used to be unbounded, and the state
machine sits in `.finishing` for the whole of it — a state the HUD and the island both used
to draw as a live recording. So anything that did not come back (a model still loading, a
transcript stream nobody finished, a cleanup pass on a machine that had started swapping)
showed up to the user as "it looks stuck and it keeps recording in the background", with the
next press refused because `.finishing` still counts as active. Every leg now goes through
`withBoundedWait`, `DictationController.Limits` names each deadline, and every failure path
stops capture and returns to `.idle`. `--selftest-dictation` is the guard: remove a bound
and it reports `DICTATION_STUCK: still finishing`. `withBoundedWait` is a hand-rolled latch
rather than a task group on purpose — a group awaits every child before it returns, which
would re-introduce exactly the wait it exists to remove.

**`DictationController.session` is not a counter, it is what keeps two holds apart.**
`engine`, `consumeTask`, `feedTask` and `audioContinuation` are one slot each, and starting
a recording is slow — Parakeet is eleven seconds cold. Release the key during that and hold
again, and two start-up tasks are in flight against one set of slots. Unguarded, the late
one writes its engine over the live one's, and `endDictation` then finishes engine B while
awaiting engine A's stream — a stream nobody will ever close. Every continuation that writes
back into those slots re-checks `session` first, and a superseded start-up finishes its own
engine and touches nothing else. It is also why capture is started *after* that check rather
than before it.

**The dictation tail logs its own split.** `runs.jsonl` records one `processSeconds` for
everything between key-up and injected text, and one number cannot say which of draining,
transcribing and cleaning up was slow. Every run also writes
`dictation tail · drain …s · transcribe …s · cleanup …s` at info level, which is the first
thing to read when someone says dictation got slow:

```bash
/usr/bin/log show --predicate 'subsystem == "ai.pivotstudio.speechify"' --last 30m --info \
  | grep "dictation tail"
```

Info-level entries age out of the unified log within minutes, so this is only useful
promptly — a slow run reported an hour later has already lost its evidence.

**A meeting reaches "Done" minutes after you press Stop.** Everything after the transcript is
handed to `MeetingPipeline` — identify speakers, then write notes — rather than awaited inside
`MeetingSession.stop()`. Clustering a long recording and summarising it are each minutes of
model time, and a `stop()` that waited would keep the session — and therefore the Record
button — alive for all of them. The session hands the meeting over at `.diarizing` or
`.summarizing` and lets go; `DiarizationService` and `NotesService` own the rest of the walk
to `.done`. So the Record button comes back long before the Notes tab fills in, and that is
the intended order.

**The notes model unloads itself.** `NotesModelRuntime` frees its weights ten minutes after
the last generation, so the first meeting summarised after a quiet afternoon pays a cold
start again. That is deliberate on a 16 GB machine: 2.7 GB resident for a meeting that
ended an hour ago is 2.7 GB the rest of the Mac wanted. It also refuses to *load* while a
dictation cleanup is in flight (`LlamaBackend.awaitCleanupIdle`) — both models running is
fine, both loading at once is where the machine starts swapping.

**A meeting records audio even when "Keep the recorded audio" is off.** Diarization reads
the system channel of `audio.caf`, so turning "Tell the other speakers apart" on makes every
meeting write the file whether or not the user asked to keep one — and
`MeetingStore.releaseAudio` deletes it again at the end of the pipeline. Which of the two it
was is answered when the recording *starts* and stored on the meeting as
`audioIsTemporary`, not read back out of the settings when it ends: switching keep-audio off
next month must not reach back and delete a recording the user asked for. The rule lives in
that one method, and it is: a recording made only for diarization goes; a recording the user
kept goes only when "delete after notes" is on *and* notes were actually written; and
nothing goes while a failed diarization pass is still offering "Identify again", which has
nothing to read without it. Nothing else deletes a recording, so if a file is being kept
that shouldn't be, that is the method to read.

**A transcript segment is a sentence, not a window, and punctuation is what makes it one.**
`ChunkedTranscriber` cuts 30–60 second windows because that is what Parakeet is cheap to run
on, then splits each window again before emitting it: `buildWordTimings` groups the token
times into words, and a segment ends at a pause of 600 ms **or** at a sentence-ending mark
once the segment is at least two seconds long.

The second half of that rule looks redundant and is not. Parakeet reports token times on an
80 ms grid, and measured on continuous speech the largest gap between two words is about
half a second and lands wherever the speaker drew breath — "settled around | 84%", not at
the turn. Drop the punctuation rule and a two-minute, two-speaker recording collapses back
to three segments and comes back labelled "Speaker 1" throughout, with the log showing the
model found two. Splitting on sentences takes the same recording to twenty segments and two
speakers. Lowering the pause threshold instead is the wrong repair: at 0.4 s it cuts
mid-clause, because that is where the gaps actually are.

**`gws` prints to stderr when it succeeds, so stderr is not an error channel.** Every run
begins `Using keyring backend: keyring` before it does anything. `GoogleWorkspaceCLI` used to
report the first stderr line as the reason a command failed, which made every Workspace
failure read "Google refused the request: Using keyring backend: keyring" — a sentence that
is not an error and names none, and which sends you to the Keychain instead of to the request
that was actually refused. Failure is judged by exit code; the reason skips the known
informational prefixes.

**`gws ... --dry-run` validates locally and will not catch a bad timestamp.** It happily
echoes `"2026-09-09 14:10"` back as a request body; Google then rejects it, after the user has
already approved the action. Anything time-shaped going to the Calendar API goes through
`WorkspaceToolRunner.rfc3339` first, and the tool schema states the format with an example —
a tool description reading "When it starts." is a specification a small model cannot meet.

**There is no `Permissions.hasSystemAudio`, and adding one makes things worse.** Every other
grant can be asked about, so its absence looks like an oversight. The obvious probe — create a
process tap and destroy it — *succeeds without the grant*: the tap is created, it simply
delivers digital silence. A checklist row driven by that would report "granted" on a machine
that records nothing, which is the one answer worse than "unknown". The row is deliberately
unanswerable until the feature runs, and `--selftest-systemaudio` is the honest test: it fails
with `SYSTEM_AUDIO_SILENT` and says why.

**⌘⇧R is a main-menu command, so it only fires while Speechify is frontmost — on purpose.**
The obvious complaint is that the one moment you want it is while Zoom has the foreground.
Making it global needs a second `CGEventTap` on a real key combination rather than a bare
modifier, and ⌘⇧R is hard-reload in every browser: swallow it and you break that everywhere,
pass it through and starting a recording also reloads whatever page is open. The menu bar item
("Record meeting now" / "Stop meeting · 12:34") is the global path and needs no tap at all.

**The island panel is always the size of its expanded card.** `IslandPanel`'s frame never
changes; collapsing and expanding happen entirely inside the SwiftUI view. A window
animating its own frame while its content animates its own layout gives two curves fighting
over the same pixels and the seam shows. The cost is that most of that window is transparent
most of the time, which is why `IslandContainerView.hitTest` returns nil outside the island's
own rectangle — without it a notice sitting under the notch would swallow clicks meant for
whatever is behind it for eight seconds.

**The island finds the pointer with event monitors, not an `NSTrackingArea`.** A collapsed
island sets `ignoresMouseEvents`, so the menu bar either side of the notch keeps working —
and a window that ignores mouse events gets no tracking-area callbacks either. Global and
local `NSEvent` monitors see the pointer without taking it. They need no Accessibility grant
(that is only keyboard events), and they are also what tells the island which display the
user is on.

**`IslandGeometry.hasNotch` asks every screen, not `NSScreen.main`.** `main` is the screen
holding the key window, and this app's panels never become key — so with an external monitor
plugged in it answers "no notch" for a MacBook that plainly has one, and the default HUD
placement comes out wrong. The same trap is why `HUDPanel.reposition` falls back to
`screens.first`.

**`gws auth status` exits 0 when nobody is signed in.** The Workspace CLI's exit codes
describe the *command*, not the account — 0 here means "I successfully told you there are no
credentials". So `GoogleWorkspaceCLI.authState` is read out of the JSON fields
(`client_config_exists`, the three credential flags) and never off the status code. The exit
codes still matter everywhere else, and they are the CLI's documented contract: 1 API error,
2 not authenticated, 3 bad arguments. `WorkspaceCLIError` keeps them apart because the app
answers each differently — a 2 sends the user to the Workspace tab, and a 3 is a bug in the
tool catalogue rather than anything they did.

**The agent searches your mail without asking, and can't send anything without asking.**
Both halves are deliberate and they are the whole permission model. `AgentRisk` grades every
tool by what can't be taken back: a read is invisible to everyone else, so with
`agentAutoRunReadTools` on the agent runs one by itself and feeds the answer into its next
round; anything that creates or sends waits for a person, and anything that speaks in the
user's name shows the full message on the card first. An unknown tool name — a proposal
written by a newer build — resolves to `.send`, the most cautious class, so a decoding
surprise can never auto-run. The model proposes and `WorkspaceToolRunner` performs; nothing
else runs a `gws` write.

**Terminal is reached by writing a `.command` file and opening it.** Installing `gws`,
authorising a Cloud project and signing in all happen in front of the user, and `open` on a
`.command` needs no Automation grant — an `NSAppleScript` telling Terminal to run something
would prompt for one, and would leave nothing the user could read afterwards. The scripts
land in `Application Support/Speechify/Scripts/`.

**A proposal outlives the process.** Unanswered proposals are `proposals.json` in the
meeting's own folder, because the notes land minutes after a meeting ends and get read the
next morning. That is also why `AgentService.decide` falls back to scanning meetings for a
proposal id: a button pressed on a notification left over from a previous launch names a
proposal this process has never seen.

**`CalendarService.refresh()` queues behind the pass in flight instead of returning
early.** The obvious `guard !isRefreshing` was written first and was wrong twice over: a
caller that had just ticked a calendar got a pass that had already read the old settings,
and a self-test awaiting `refresh()` was handed an empty list because the scene graph had
started one concurrently. Chaining keeps the reads serialised *and* guarantees every caller
sees a pass that began after it asked. Do not "simplify" it back to a flag.

**Adding a property to `Meeting` without `decodeIfPresent` orphans every meeting on
disk.** Swift's synthesized `init(from:)` does not use a property's default value as a
fallback for a missing key, so a new field makes every existing `meeting.json` fail to
decode and the meeting simply vanishes from the list. `MeetingModels.swift` therefore has a
hand-written `init(from:)`; new fields go in it as `decodeIfPresent`. `id`, `title` and
`start` stay required on purpose — minting a fresh id would orphan the folder instead.

**An armed meeting's `end` is the time the calendar said, not a time anything measured.**
That is what the "stop five minutes after the scheduled end" rule reads, and it survives a
relaunch where an in-memory map would not; `MeetingSession` overwrites it at stop. The
visible cost is that an armed row shows the scheduled duration. Auto-stop — the overrun and
the ten-minutes-of-silence rule — applies only to calendar-backed sessions: a recording
someone started by hand is never cut off for being quiet.

**`--fake-calendar` replaces the real providers, it does not join them.** A flag that added
an invented meeting beside the real ones could start recording something that is actually
happening. It is a modifier, not a self-test, and it is the only way to watch
armed → notified → recording → done without waiting for a real meeting.

**The microphone flag flickers, and the debounce is not paranoia.** Sampling
`kAudioProcessPropertyIsRunningInput` at 1 Hz during *continuous* microphone use showed it
read on, then report nobody for three consecutive samples, then read on again. That is
measured on this machine, not feared. So `CallPolicy` announces a call only after it has
held both flags for `onThreshold`, and ends one only after it has been gone for
`offThreshold` — which is five times longer, because a card that lingers a few seconds is a
much cheaper mistake than a card that blinks off and on in the middle of a call. Lowering
`offThreshold` to make the island disappear promptly is the repair that re-introduces the
bug. The state machine is a pure function of (state, observation, elapsed), so
`--selftest-calls` drives minutes of it instantly; the Core Audio subscription underneath is
the part no self-test can reach.

**`corespeechd` holds the microphone with nobody on a call, and Speechify holds it whenever
you dictate.** Both showed up in the probe, and either one taken at face value arms a
meeting for a call that is not happening — the second one every time the user talks to this
app. Hence the three filters in front of the both-flags rule: our own pid, our own bundle
identifier (a helper or a second copy shares the id but not the pid), and
`CallPolicy.deniedBundleIDs` for the speech and accessibility daemons that hold the
microphone on somebody else's behalf. It is a **denylist, not an allowlist**, on purpose: a
conferencing app nobody here has heard of has to work on the day it is installed. Fathom is
deliberately *not* denied even though it records meetings — it only holds the microphone
during a call, so denying it would suppress a real detection, and the per-app answer in
Settings is where a user who dislikes that says so.

**Chrome is offered only "Ask first" and "Never", and that missing third option is the
feature.** Chrome holding the microphone and the speakers might be a Meet call in a tab and
might be a video conference in a web app nobody has heard of, or a page that opened the
microphone and never used it. Nothing cheap tells them apart — reading the window title over
Accessibility was considered and rejected as fragile. So `CallPolicy.askOnlyBundleIDs`
refuses to record a browser without asking, `availableAnswers(forApp:)` does not offer
"Always record" for one, and `effectiveAnswer(…)` downgrades a stored `always` rather than
displaying a promise the policy will not keep. Google Meet installed as a Chrome web app
carries its **own** bundle id
(`com.google.Chrome.app.kjgfgldnnfoeklkmfkjfagphfepbbdan`), is not in that set, and keeps all
three answers — the precise case stays precise. Related: the app list in Meetings settings is
**empty until an app has actually held the microphone**, because it is a record of what
happened on this Mac rather than a table of bundle identifiers somebody typed. Empty is what
a fresh machine correctly looks like.

**Meetings record two tracks on purpose.** Microphone and system audio are captured,
transcribed and stored separately (left and right channels of `audio.caf` when keep-audio
is on). That is what gives "You / Others" attribution for free and what lets diarization
run on the system track alone. The known cost: with laptop speakers and the built-in
microphone, remote voices bleed onto the mic track.

---

## Design system

`Sources/Speechify/UI/DesignSystem.swift` defines every colour, size, radius, duration
and material token. **Views must not contain literal values.** If a component needs a number
that isn't a token, add the token rather than inlining it. That rule is the only thing that
survived the redesign.

The direction is **a native macOS app**: `NavigationSplitView` with a sidebar, system
materials, the system font at system text styles, standard controls, `Form { }` with
`.formStyle(.grouped)` in Settings, `ContentUnavailableView` for empty states, and
`.glassEffect` on the HUD. It should look like it shipped with the OS, and it should inherit
the user's appearance, accent colour and accessibility settings without a line of code here
knowing about them — which is why nearly every token resolves to a semantic system value
(`.controlBackgroundColor`, `.accentColor`, `.body`) rather than a literal.

Two colour rules are not negotiable, and they are the same two as before:

- **Red means recording.** `DS.Color.record` appears in `RecordingIndicator` and on the
  Record button while it is active. Nothing else in the app is red.
- **Green, yellow and red on a meter are instrumentation only** — `LevelMeter` and
  `LevelBar`, never UI chrome. Status *text* uses `DS.Color.success` / `.warning`.

Gone with the 1980s field-recorder direction, and not to be revived: `BrushedPanel`, `Well`,
`DeckWindow`, `Silkscreen`, `Screw`, `Vents`, `Lamp`, `TransportKey`, `Readout`, `VUMeter`,
the `Brand` gradient, the HUD `Waveform`, and every chassis/ink/deck/seam token along with
the procedural brushed grain. There are **no gradients on chrome**. Depth comes from the
system's own materials and separators.

Shared components live in `Sources/Speechify/UI/Components/` — `LevelMeter` (+ `LevelBar`),
`RecordingIndicator`, `ModelStatusRow`, `CopyButton`, `StatusChip` (+ `SpeakerLabel`),
`MarkdownView`, `ProblemBanner`, `FlowLayout`, and `ThinkingOrb` in
`Components/ThinkingOrbs/`. Sections live in `UI/<Section>/`, one Settings tab per file in
`UI/Settings/`. Reach for an existing component before writing a new one; three hand-rolled
model-status rows is what `ModelStatusRow` exists to prevent.

The notch island in `UI/Island/` is the one place that breaks the semantic-colour rule, and
only there: while it hugs the notch its substrate is continuous with the machine's black
bezel, so `DS.Color.island` and `DS.Color.islandInk` are literal black and white. `.primary`
on a permanently black card resolves to black in light mode. Floating below the menu bar on a
display without a notch it uses glass and ordinary semantic ink instead.

`ThinkingOrb` stands in for a spinner where the wait is minutes rather than frames. All nine
upstream states are ported, and each is bound to one situation — they say *which* long thing
is happening, which a `ProgressView` cannot, so picking the wrong one is a lie rather than a
style choice:

| State | Where | Why that one |
|---|---|---|
| `listening` | dictation HUD and island | one voice, a waveform through rings |
| `weaving` | a meeting recording | two channels braided into one transcript |
| `working` | transcribing | particles grinding round orbits |
| `solving` | diarizing | a clustering problem scrambling and clicking back |
| `composing` | notes being written | an undulating sash |
| `searching` | the agent reading mail and calendar | a meridian sweeping a globe |
| `breathing` | an armed meeting awaiting an answer | idling on purpose, nothing processing |
| `connecting` | Google / Workspace sign-in | a constellation wiring two parties together |
| `shaping` | a model downloading and loading | an outline being formed from nothing |

An orb never replaces the red dot: red still means recording and only recording, and the orb
sits beside it saying what kind of work is running. In the HUD it also does not replace the
level bar — an orb animates on a clock, so it would keep dancing over a muted microphone and
answer "is it hearing me?" with a confident yes. Note `connecting` at the inline 20pt preset
draws almost no wires, because upstream's proximity threshold is not a count-scaled key; that
is its tuning, not a porting slip. The geometry in `OrbGeometry` is a port of
[thinking-orbs](https://github.com/Jakubantalik/thinking-orbs) (MIT, licence vendored beside
it); its tuning tables are data rather than view constants and are deliberately not `DS`
tokens.

The **app icon is the orb too**, not a picture of one. `Tools/makeicon.swift` is compiled
*with* `OrbGeometry.swift` by the `icon` target rather than run as a script, so the mark is
the `listening` state at t=1.7 — the same instant `ThinkingOrb` freezes on for Reduce Motion,
picked there because it reads as a diagram rather than as motion caught mid-frame. Change the
animation and the icon follows. It draws the *inline* preset below 96px: the large design's
134 dots are correct at 64pt and turn to grey mud at 32px, which is the whole reason the
library ships two designs instead of one and a scale factor. Monochrome, because an icon with
a gradient would advertise a design this app does not have.

Red is still only ever recording — a recording island shows the same
`RecordingIndicator` dot as everywhere else, with the `weaving` orb beside it saying what
kind of recording it is, exactly as the HUD sets an orb beside the dot and the level bar.

## macOS specifics

**Ad-hoc signing is not "unsigned", it is a new identity every build.** An ad-hoc signature
is a hash of the binary, so the designated requirement reads `cdhash H"…"` and changes with
every compile. TCC stores that requirement beside each grant, so Accessibility, Audio
Recording and Notifications are all invalidated together by every `make install` — and the
symptom lies twice over: the toggle still reads as on, and *toggling it off and on does not
repair it*, because what is stale is the stored requirement, not the switch. The only fix for
a wedged row is `tccutil reset <service> ai.pivotstudio.speechify` (never without the bundle
ID), then re-grant.

`make signing-cert` ends this. With a stable certificate the requirement becomes
`identifier "ai.pivotstudio.speechify" and certificate leaf = H"…"`, which is **identical
across rebuilds** — verify with `codesign -d -r-` before and after a build. Creating the
certificate through Certificate Assistant is easy to get wrong and fails silently; the
reliable route is openssl, and two traps are worth knowing: OpenSSL 3 writes PKCS#12 that
macOS rejects with a misleading "wrong password" unless `-certbe/-keypbe PBE-SHA1-3DES
-macalg sha1` are given, and an imported self-signed certificate reports **zero** identities
until `security add-trusted-cert -p codeSign` is run on it.

**Code signing is load-bearing, not cosmetic.** TCC stores a code-signing *requirement* per
entry, not just a path. An ad-hoc signature changes every build, so the rebuilt binary stops
satisfying the stored requirement — and the symptom lies: the Accessibility toggle still
shows as **on** while the app is untrusted. The `Makefile` auto-detects a Developer ID via
`security find-identity`. Don't replace that with `--sign -`.

If a grant does get wedged, reset that one row — never toggle, and never omit the bundle ID:

```bash
tccutil reset Accessibility ai.pivotstudio.speechify
```

A bare `tccutil reset Accessibility` wipes every app on the machine. Then quit System
Settings entirely (⌘Q) before reopening; the Privacy pane caches its list.

**`log` may be shadowed in the user's shell.** Use `/usr/bin/log` explicitly.

**Don't run the `.app` from the repo folder.** It's iCloud-synced and the sync engine can
corrupt the signature. `make install` puts the running copy in `/Applications`.

---

## Windows specifics

The specifics below were expensive to establish and several were found the hard way. Treat
them as load-bearing. Full detail in `windows/README.md` and `docs/PARAKEET-WINDOWS.md`.

**Three pinned versions that break silently at "latest":**

| Package | Pin | Why |
|---|---|---|
| `NAudio` | 2.3.0 | 3.x targets .NET 9+ and will not restore |
| `Avalonia.Headless.XUnit` | 11.3.20 | 12.x requires xUnit **v3**, a different package line |
| `org.k2fsa.sherpa.onnx` | 1.13.5 | Bundles ONNX Runtime — never also reference `Microsoft.ML.OnnxRuntime` |

**Right Alt is AltGr** on German, Polish, UK, Nordic and most Latin-American layouts. Binding
push-to-talk there — and especially suppressing it — breaks typing `@`, `€`, `\`, `|` for
those users. Default is **Right Ctrl**, and the hook **observes without swallowing**: if the
key-down is swallowed and the key-up escapes, the target app believes Ctrl is held forever.

**UI Automation cannot inject text.** `TextPattern` is documented read-only and
`ValuePattern` replaces a whole field rather than inserting at the caret. `SendInput` is the
primary path, not a fallback.

**`Speechify.App` loads the platform layer by reflection, not by reference.** A direct
reference would force the UI onto `net10.0-windows` and you would lose the ability to run it
on your own machine. Two consequences that have already bitten once: the assembly is
invisible to `PublishSingleFile`, so it is published as a loose file beside the exe *and*
resolved by an explicit `AssemblyLoadContext` handler; and the published self-test checks
this, because when it breaks the app starts perfectly and then does nothing at all when the
key is pressed.

**Keep `Speechify.Platform.Windows` logic-free.** Anything living there is code CI cannot
exercise. Retries, debouncing and device-change handling belong in the platform-neutral
projects behind an interface — those target plain `net10.0`, so `CA1416` turns any accidental
Win32 call into a build error.

**CI is the only place the Windows code is compiled.** Warnings are errors and the analyzers
are strict on purpose. `--no-incremental` is mandatory: Roslyn does not re-emit analyzer
warnings on a cached build, so without it the gate proves nothing.

---

## Regex, if you touch the dictionary

The two engines are not identical. Measured across 30 cases, **9 diverged**. Two affect this
code and are handled — don't remove either:

- `RegexOptions.CultureInvariant` on the C# side, or Turkish `İ` matches `i`.
- **NFC normalization on both sides.** macOS returns decomposed strings, so without it an
  accented trigger silently never fires.

Two more are unfixable and simply avoided: ICU folds `ß` to `ss` and .NET doesn't; .NET's `.`
splits surrogate pairs. Stay inside the safe subset — `\b`, `\d`, `\w`, `\s`, character
classes, greedy/lazy quantifiers, alternation, `(?<name>…)`, fixed-length lookbehind,
lookahead, `\p{L}`, and `$1`–`$9` in replacements. Nothing else.

---

## What isn't built

1. **Notarization** (macOS) and **code signing** (Windows). Both apps are unsigned for
   distribution, so Windows users will meet SmartScreen.
2. **An installer** for Windows, and model download from inside the app rather than by
   following `docs/PARAKEET-WINDOWS.md` by hand.
3. **A Claude-backed cleanup or notes provider.** `TextFormatter`, `TextCommandProcessor`
   and `LLMProvider` are all seams for one; there is no credential storage or network path.

## What has never run, on macOS

Distinct from the list above: these are written, compile, and have a self-test wherever one
is possible, but the permission, model or account they need has never been available on the
development machine. Treat anything here as unproven, and do not describe it as working.

- **The system-audio tap with its TCC grant.** Every call succeeds without it and every
  sample is zero, so no meeting has yet contained an "Others" track.
- **Qwen3.5-4B.** Never downloaded (~7 GB of free disk is needed: 2.74 GB plus the
  downloader's 4 GB reserve), so `NotesModels.spec.expectedSHA256` is still `nil` — the
  downloader logs the computed digest and the next agent to get it pins it — and every
  notes and agent run so far has gone through Apple Foundation Models instead.
- **Both real calendars.** EventKit reports `.notDetermined` here; Google has never had an
  account connected, and needs the user's own Desktop-type OAuth client (id *and* secret —
  Google's installed-app client type requires the secret at the token endpoint even with
  PKCE).
- **Every Workspace write.** `gws auth status` reports no credentials, so no proposal has
  ever been approved and `WorkspaceToolRunner` has never spoken to the API. Each tool's
  flags were checked against `gws <service> <helper> --help`, not against a live call.
- **The redesigned UI, by eye.** Screenshots need Screen Recording and driving the UI needs
  Accessibility; neither can be granted non-interactively. Nobody has seen the sidebar, the
  onboarding sheet, or the island expand out of the notch.

## What no amount of CI can verify

On Windows, nobody has yet held the key and spoken. Specifically unverified:

- Text injection landing in a foreground app — runners have an interactive desktop but
  cannot take the foreground.
- A real microphone: format negotiation, the OS privacy block, unplugging mid-capture.
- The keyboard hook firing on a physical keypress.
- Parakeet transcribing real speech, and whether ~2 GB resident is tolerable.

Everything those feed into is behind an interface and tested with fakes. The bindings
themselves are not. **First real-hardware run should start with `--selftest`, then a single
short dictation into Notepad.**
