# Next Notes Real-Time Architecture Roadmap

> **Historical model assumptions — revised 2026-09-30:** this completed plan/audit
> preserves its dated measurements and implementation history. For new work, follow
> the [independent-role/shared-file contract](../in-progress/SHARED-BRAIN/00-README.md): Meetings, Agent and cleanup
> may use different appropriate models; exact verified artifacts are reused, with
> workload-specific consent and request ownership. Agent-only file selection,
> universal model defaults and deletion based only on the Agent are superseded.
> MiniCPM cleanup + Apple guard/fallback is concurrent work, not evidence that this
> historical build used it. Re-measure quality/latency on the actual current engine.

Implementation and acceptance status: [v3/v4 ledger](ROADMAP-V3-V4-STATUS.md).

## Objective

Next Notes should feel immediate, fluid, and non-blocking across three distinct product pipelines:

1. **Dictation**
2. **Meeting Intelligence**
3. **Interactive Voice Agent**

These pipelines should share low-level infrastructure where that improves performance, but they must preserve different interaction contracts.

The design target is:

> **Instant input, continuous audio, streaming results, no unnecessary blocking, and clear separation between silent dictation, proactive meeting intelligence, and explicit full-duplex agent interaction.**

The system should make deliberate use of CPU, GPU, and NPU/Neural Engine resources, select the smallest capable model for each stage, and keep all latency-critical work off congested execution paths.

---

# 1. Product Contracts

## 1.1 Dictation Pipeline

Dictation is a **silent, one-way pipeline**.

The user holds the dictation key, speaks, releases, and polished text appears in the application where dictation began.

There should be:

- no spoken feedback
- no agent conversation
- no tool calls
- no action cards
- no unnecessary reasoning loop

The pipeline is:

```text
Push-to-talk
    ↓
Audio capture
    ↓
Streaming / near-streaming ASR
    ↓
Fast cleanup
    ↓
Formatting / punctuation
    ↓
Text injection into origin app
```

The primary goals are:

- lowest possible time-to-text
- high transcription accuracy
- reliable punctuation
- good grammar
- correct names and technical terms
- correct per-application formatting
- zero focus stealing
- deterministic completion after key release

---

## 1.2 Meeting Intelligence Pipeline

Meeting mode is **automatic and proactive**.

When a meeting is detected or scheduled:

```text
Meeting starts
    ↓
Record microphone + system audio
    ↓
Transcribe continuously
    ↓
Maintain structured live meeting context
    ↓
Detect candidate actions / decisions / commitments
    ↓
Generate actionable UI cards
    ↓
User confirms / edits / dismisses
```

The user should **not need to wake the agent** for passive meeting intelligence.

The system is already listening to the meeting because meeting recording is active.

However, authority must remain explicit:

```text
System audio / other speakers
    = context only

User microphone
    = may authorize an action
```

For example:

> Other participant: “Can you send me the STEP file?”

Next Notes can create a candidate action:

```text
Send STEP file to Sarah
```

but it must not execute it.

If the user says:

> “Send her the latest one.”

the meeting agent can prepare the action immediately and show:

```text
Send Enclosure_v17.step to Sarah?

[Approve] [Edit] [Dismiss]
```

At the end of the meeting, Next Notes should also produce a complete action review based on the full meeting.

---

## 1.3 Interactive Agent Pipeline

The Agent pipeline is **explicitly activated** through:

- a wake phrase, e.g. **“Hey Next”**
- a configurable keyboard shortcut

It is a conversational, full-duplex experience.

The pipeline is:

```text
Wake phrase / shortcut
    ↓
Realtime voice session
    ↓
Streaming ASR
    ↓
Realtime agent reasoning
    ↓
Immediate tools OR background task delegation
    ↓
Streaming TTS response
    ↓
Barge-in supported at all times
```

This pipeline should support:

- asking questions
- conversational follow-up
- Mac control
- reading current screen/application context
- opening applications
- clicking and typing
- searching files
- shell commands
- Google Workspace
- MCP tools
- coding agents through ACP
- background tasks
- visible task progress
- spoken results

---

# 2. Shared Runtime Architecture

The three pipelines should share infrastructure where possible, but not share latency bottlenecks.

```text
                         AUDIO INPUT
                             │
                       AudioCaptureHub
                             │
          ┌──────────────────┼──────────────────┐
          │                  │                  │
      Dictation           Meeting           Agent Voice
          │                  │                  │
          ▼                  ▼                  ▼
       ASR lane           ASR lane          ASR/VAD lane
          │                  │                  │
          └────── shared model/runtime infrastructure ──────┐
                                                           │
                                                   Compute Scheduler
                                                           │
                                  ┌──────────────┬──────────┴──────────┐
                                  │              │                     │
                                 CPU            GPU               Neural Engine
```

The key design rule is:

> **A meeting summary, LLM cleanup pass, or background coding task must never stall realtime ASR, wake-word detection, or interactive voice.**

---

# 3. Performance Priorities

Use explicit priorities.

## Priority 0 — Audio continuity

Never block:

- microphone capture
- system audio capture
- wake-word detection
- realtime VAD

These callbacks should do minimal work and enqueue copied buffers.

## Priority 1 — Realtime ASR

Dictation and interactive agent ASR are user-facing latency paths.

Meeting transcription should also stream quickly, but can tolerate slightly larger batching if necessary.

## Priority 2 — Realtime agent response

- intent routing
- immediate tool execution
- TTS start
- interruption detection

## Priority 3 — Meeting live intelligence

- action detection
- decision extraction
- structured context updates

## Priority 4 — Background generation

- long notes
- diarization refinement
- full meeting summary
- coding agents
- large file searches
- expensive LLM work

Priority 4 must yield to Priorities 0–3.

---

# 4. Compute Orchestration

Do not simply “use every processor.”

Assign work based on workload characteristics.

## CPU

Best for:

- audio capture
- VAD
- wake-word orchestration
- deterministic formatting
- text normalization
- JSON / tool routing
- lightweight filesystem work
- Accessibility APIs
- shell process management
- TTS if model is sufficiently small

## GPU

Best for:

- llama.cpp local LLM inference
- Qwen/S1 semantic cleanup where GPU acceleration is available
- meeting summarization
- larger local reasoning passes

Avoid running large low-priority generations on GPU when realtime agent generation needs it.

## Neural Engine / NPU

Prefer where Core ML models support it efficiently:

- Parakeet/CoreML ASR
- lightweight classifiers
- potentially TTS if converted and benchmarked successfully

Do not assume Neural Engine is faster. Benchmark:

- load time
- first-token / first-frame latency
- steady-state throughput
- power consumption
- contention with concurrent tasks

---

# 5. Add a Compute Scheduler

Introduce a central abstraction:

```swift
enum WorkClass {
    case realtimeAudio
    case realtimeASR
    case realtimeAgent
    case meetingLive
    case background
}

protocol ComputeJob {
    var workClass: WorkClass { get }
    var preferredDevice: ComputeDevice { get }
}
```

Conceptually:

```text
ComputeScheduler

realtimeAudio  → reserved CPU
realtimeASR    → Neural Engine / CoreML
realtimeAgent  → GPU or Apple Foundation Model
meetingLive    → opportunistic accelerator
background     → idle resources / throttled GPU
```

The scheduler should prevent:

> meeting notes generation loads Qwen and makes dictation lag for four seconds.

---

# 6. Dictation Pipeline Improvements

## 6.1 Stop waiting for the full utterance where possible

Current product quality should move toward:

```text
audio chunk
    ↓
partial ASR
    ↓
stabilized segments
```

rather than:

```text
record everything
    ↓
release
    ↓
start expensive transcription
```

The user may still only receive final injected text after release, but most ASR work should already be complete by then.

Target:

> Release key → final injected text should feel nearly immediate.

---

# 7. Parakeet Optimization

Parakeet should remain the primary high-quality local ASR path if benchmarks confirm it.

Improve:

- model warmup at launch or first idle opportunity
- persistent model residency when memory permits
- streaming/chunked inference
- avoid reload between dictation turns
- reuse audio conversion buffers
- minimize Swift ↔ model format conversions
- isolate ASR queue from LLM queues

Measure:

```text
Time to first partial
Time from key release to final ASR
Real-time factor
Peak memory
CPU %
GPU %
ANE usage
```

Maintain Apple Speech as an alternate engine where its latency/quality is superior.

---

# 8. Two-Stage Dictation Cleanup

Do not run an expensive LLM over every dictation if deterministic processing is enough.

Use:

```text
ASR
 ↓
Fast deterministic cleanup
 ↓
Confidence / complexity gate
 ↓
Semantic cleanup only when needed
```

### Stage A — deterministic

Handle:

- spacing
- capitalization
- repeated filler cleanup
- obvious punctuation
- spoken punctuation
- app-specific formatting
- dictionary corrections
- path formatting
- casing rules

### Stage B — semantic

Use S1 / Apple Foundation Model / Qwen only for cases such as:

- false starts
- broken grammar
- sentence restructuring
- ambiguity
- longer spoken paragraphs

This can reduce average latency significantly.

---

# 9. Semantic Cleanup Routing

Introduce a router:

```text
CleanupRouter
```

Possible policy:

```text
short + clean transcript
→ RuleBasedFormatter

medium / obvious repair
→ S1-mini

complex or long
→ Apple Foundation Model or Qwen
```

The router should consider:

- token count
- ASR confidence
- number of disfluencies
- punctuation confidence
- whether output profile requires semantic restructuring
- model availability
- current GPU pressure

---

# 10. Personalized Dictation Accuracy

Continue expanding the existing dictionary/context work.

Use:

- personal correction history
- visible project/file names
- active application
- workspace/project names
- meeting participants
- recent proper nouns

Context should bias transcription, not become untrusted instructions.

Maintain strict privacy filtering for:

- password fields
- finance apps
- secure text fields
- sensitive URL bars

---

# 11. Meeting Transcription Must Become More Realtime

Current user feedback:

> transcript is appearing, but not quickly enough to feel realtime.

Move toward shorter windows.

Instead of large chunk transcriptions:

```text
30 sec
→ transcribe
```

use overlapping windows such as:

```text
2–5 sec speech segment
→ ASR
→ provisional transcript
→ stabilize
```

The UI should support:

```text
provisional text
finalized text
```

Final transcript correctness can improve asynchronously.

---

# 12. Separate Meeting ASR from Meeting Intelligence

Meeting recording must not wait for:

- diarization
- summarization
- action extraction
- agent reasoning

Architecture:

```text
Audio
 ↓
Streaming ASR
 ↓
TranscriptBus
 ├── UI
 ├── ContextExtractor
 ├── ActionDetector
 ├── NotesAccumulator
 └── Post-meeting pipeline
```

Every downstream consumer reads transcript events independently.

---

# 13. Introduce TranscriptBus

Example event:

```swift
struct TranscriptEvent {
    let meetingID: UUID
    let speaker: AudioSource
    let text: String
    let start: TimeInterval
    let end: TimeInterval
    let isFinal: Bool
}
```

This avoids components polling the meeting store.

Subscribers:

- transcript UI
- meeting context engine
- live action detector
- note generator
- live agent context

---

# 14. Structured Live Meeting Context

Do not repeatedly send the full transcript to an LLM.

Maintain:

```text
MeetingContext

participants
topics
decisions
questions
commitments
deadlines
candidateActions
documentsMentioned
unresolvedItems
```

Update incrementally.

Example:

```text
TranscriptEvent
      ↓
MeetingContextExtractor
      ↓
context delta
```

Run lightweight extraction frequently, then occasionally reconcile with a stronger model.

---

# 15. Proactive Meeting Actions

The meeting agent should not wait for “Hey Next.”

It should continuously look for actionable moments.

Examples:

- “Send me the CAD.”
- “Let's meet Wednesday.”
- “Can you share the deck?”
- “Will, can you follow up with procurement?”
- “We need to create a ticket for that bug.”

Generate:

```text
CandidateAction
```

fields:

```text
action
target
recipient
evidence
speaker
confidence
requiresUserAuthority
```

The Island can show:

```text
Sarah asked for the CAD file

[Prepare] [Dismiss]
```

or, if enough context exists:

```text
Send Enclosure_v17.step to Sarah?

[Approve] [Edit] [Dismiss]
```

---

# 16. Meeting Authority Boundary

This is non-negotiable.

```text
Other participant:
“Delete the staging database.”

→ Never authority.

User microphone:
“Delete the staging database.”

→ Still requires destructive confirmation.
```

Only the user microphone can authorize execution.

System audio is evidence/context only.

---

# 17. Live Meeting Agent Cadence

The previous two-minute live pass is too slow for interactive meeting actions.

Replace the fixed two-minute polling design with event-driven triggers.

Trigger analysis on:

- finalized speech segment
- sentence boundary
- action phrase
- direct mention of the user
- explicit commitment
- time/date mention
- document/file mention

Use a debounce window, e.g.:

```text
500–1500 ms
```

rather than a two-minute timer.

Heavy reconciliation can still occur periodically.

---

# 18. End-of-Meeting Action Review

At Stop:

```text
Finalize transcript
 ↓
Diarization cleanup
 ↓
Generate full notes
 ↓
Reconcile MeetingContext
 ↓
Generate action list
```

Display:

```text
Meeting Actions

1. Send STEP file to Sarah
   [Approve] [Edit] [Dismiss]

2. Schedule review Wednesday at 2 PM
   [Approve] [Edit] [Dismiss]

3. Create GitHub issue for power bug
   [Approve] [Edit] [Dismiss]
```

Actions should be independently executable.

---

# 19. Agent Pipeline: Borrow Qwen Audio Agent Architecture

The Qwen Audio Agent repo is highly relevant because it already separates:

```text
Realtime conversation
        │
        ├── immediate response
        │
        └── background task
```

Borrow the architectural principles, not necessarily the entire runtime.

Key concepts to port:

- persistent realtime session
- VAD turn boundaries
- barge-in
- background task delegation
- progress updates
- permission requests
- task cancellation
- asynchronous result insertion
- one continuous user-facing assistant

---

# 20. Agent Full-Duplex State Machine

Target:

```text
SLEEPING
   ↓ wake phrase
LISTENING
   ↓ speech
THINKING
   ↕
SPEAKING
   ↕ user barge-in
LISTENING
```

Background work exists independently:

```text
TASK 1: running
TASK 2: waiting approval
TASK 3: completed
```

The realtime conversation must continue while these run.

---

# 21. Fix Wake Word During Meetings

Observed failure:

> Meeting is recording and transcribing, user says “Hey Next,” but the agent does not wake reliably.

Likely architectural cause:

Wake-word audio monitor yields microphone ownership while meeting recording owns it.

Do not run two independent microphone engines.

Instead create:

```text
AudioCaptureHub
```

One microphone capture.

Consumers receive copies:

```text
Microphone
    ↓
AudioCaptureHub
    ├── Meeting recorder
    ├── Meeting ASR
    ├── Wake detector
    ├── Agent VAD
    └── Dictation when active
```

The wake detector should remain active during meetings.

This directly addresses the reported “Hey Next did nothing” behavior.

---

# 22. Wake Detection Must Never Depend Only on Transcript Delay

During meetings, detect the wake phrase directly from the microphone KWS stream.

Do not wait for:

```text
meeting chunk
→ Parakeet
→ transcript
→ phrase match
```

That creates seconds of latency.

Use:

```text
microphone samples
→ sherpa KWS
→ wake event
```

Then optionally strip the wake phrase from subsequent agent ASR.

---

# 23. Immediate Wake Acknowledgement

As soon as KWS fires:

Target <100 ms UI response:

```text
Island:
Listening…
```

Optional subtle earcon.

Do not wait for:

- ASR
- LLM
- tool router

before acknowledging wake.

This avoids the current ambiguous experience where the user does not know whether the wake phrase worked.

---

# 24. Real Full-Duplex Audio

Agent capture and playback must coexist.

Introduce:

```text
RealtimeAudioSession

input stream
output stream
echo handling
VAD
barge-in detection
```

While TTS is speaking, continue monitoring user input.

If user speaks:

```text
speech detected
→ stop TTS immediately
→ preserve conversation state
→ ASR new utterance
```

This is essential for natural interaction.

---

# 25. Add TTS

The absence of spoken agent feedback currently undermines the voice-agent experience.

Agent responses should have two forms:

```text
spoken summary
+
visual detail
```

Example:

TTS:

> “I found three matching files. The latest is enclosure version seventeen.”

Island:

```text
Enclosure_v17.step
Modified today 3:42 PM

[Open] [Upload]
```

Do not read long tool output aloud.

---

# 26. Lightweight Local TTS Strategy

Target constraints:

- <1 GB working memory
- fast first audio
- local
- good English quality
- streamable
- interruptible

Recommended evaluation order:

## Candidate A — Kokoro 82M / ONNX variants

Strong candidate because of:

- small model size
- good naturalness relative to parameter count
- CPU-friendly deployment
- ONNX ecosystem
- potential quantization

Benchmark quantized variants.

## Candidate B — Piper

Use as fallback because it is:

- extremely lightweight
- mature
- local
- fast

Voice quality is lower than newer neural TTS, but latency is excellent.

## Candidate C — Apple system speech

Also benchmark `AVSpeechSynthesizer`.

Advantages:

- zero model download
- minimal integration
- excellent latency
- operating-system optimized

It may be the best initial shipping option while Kokoro is evaluated.

---

# 27. TTS Streaming

Do not generate an entire paragraph before playback.

Pipeline:

```text
LLM token stream
 ↓
sentence / clause buffer
 ↓
TTS first clause
 ↓
start playback
 ↓
continue synthesis
```

Target:

> first audible response under ~300–500 ms after first complete short clause.

---

# 28. Agent Speech Policy

Speak:

- direct answers
- confirmations
- short task status
- errors requiring user attention
- permission questions
- task completion

Do not speak:

- every tool call
- raw logs
- long file listings
- URLs
- verbose code output

Examples:

Good:

> “I’m checking the repository.”

> “I found the issue. The build script is using the wrong path.”

Not good:

> “Executing shell.run slash usr slash bin slash…”

---

# 29. Realtime Tool Loop

Current single-tool-call behavior should become a multi-round agent loop.

Target:

```text
Model
 ↓
tool call
 ↓
tool result
 ↓
Model
 ↓
next tool
 ↓
...
 ↓
final response
```

Bound it:

```text
max rounds: 4–8
max wall time
max tool calls
```

Example:

```text
User:
“Click Run in Xcode.”

Model
→ computer.inspect_ui

Tool
→ [12] Run

Model
→ computer.click(id:12)

Tool
→ Clicked

Model
→ “Done.”
```

---

# 30. Computer Control Reliability

Keep Accessibility-first architecture.

Order:

```text
1. Native app APIs / structured tools
2. Accessibility
3. Browser DOM/CDP
4. Vision fallback
```

Avoid screenshot-first control.

---

# 31. Browser Control

AX-only browser automation will be insufficient for many web apps.

Add a local browser control layer, preferably Chrome DevTools Protocol where available.

Capabilities:

- current URL
- tabs
- DOM
- accessibility tree
- click
- fill
- navigation
- network status
- downloads

Fallback to Accessibility for unsupported browsers.

---

# 32. ACP Coding Agents

Next Notes should remain the voice/context/permission layer.

Coding agents handle sustained engineering work.

```text
Voice:
“Use Codex to inspect the latest commit and fix the test.”

Next Notes
   ↓
ACP
   ↓
Codex
```

Support:

- Codex
- Claude Code
- Qwen Code
- OpenCode
- others implementing ACP

Do not silently downgrade from ACP to an unstructured CLI mode.

If ACP fails:

```text
ACP unavailable.

Run this task in compatibility CLI mode?

[Run once] [Cancel]
```

---

# 33. Background Task UX

Tasks must never block the conversation.

Example:

> “Check the repo and optimize the transcription pipeline.”

Agent:

> “I’ll work on that in the background.”

User can immediately ask something else.

Island:

```text
Checking repository…

• Inspecting audio pipeline
• Measuring ASR paths
• Reviewing model loading
```

When done:

TTS:

> “I finished the review. I found three performance issues.”

---

# 34. Tool Permission Scopes

Current permissions should evolve beyond tool-level grants.

Target:

```text
tool
resource
scope
duration
```

Examples:

```text
filesystem.write
scope: ~/Projects/next-notes/**
duration: task

computer.click
scope: com.apple.dt.Xcode
duration: session

browser.fill
scope: github.com
duration: task
```

Sending, destructive actions, and privileged commands remain strongly confirmed.

---

# 35. Metrics and Instrumentation

Add end-to-end timing spans.

## Dictation metrics

```text
keyDown → capture started
speech → first ASR partial
keyUp → ASR final
ASR final → cleanup final
cleanup final → injection
total keyUp → injection
```

## Meeting metrics

```text
speech → transcript partial
speech → transcript final
transcript → context update
action phrase → candidate action
candidate → UI card
```

## Agent metrics

```text
wake phrase → listening UI
speech end → transcript
transcript → first model token
first model token → first TTS audio
tool call → tool result
barge-in → TTS stopped
```

Persist rolling statistics locally.

---

# 36. Suggested Latency Targets

These are engineering targets, not hard promises.

## Dictation

```text
Wake/capture start:       <100 ms
First partial ASR:        <300–500 ms
Key release → final text: <300–700 ms typical
Injection:                <50 ms after formatting
```

## Meeting

```text
Speech → visible partial: <500 ms
Speech → stable text:     <1–2 s
Action detection:         <2 s after relevant sentence
```

## Agent

```text
Wake → visual ACK:        <100 ms
Speech end → response:    <500–1000 ms for local/simple answers
First TTS audio:          <300–500 ms after reply begins
Barge-in stop:            <100 ms
```

---

# 37. Model Residency Policy

Avoid repeated model loading.

Suggested states:

```text
Always warm:
- wake KWS
- Parakeet if memory allows

Warm while meeting:
- meeting ASR
- lightweight meeting extractor

Warm while agent session:
- realtime LLM provider
- TTS

Load opportunistically:
- Qwen large notes model
- diarization model
```

When memory pressure occurs:

1. unload background notes model
2. unload diarization
3. keep ASR
4. keep wake detector
5. keep active TTS/realtime model

---

# 38. Resource Contention Tests

Add stress tests.

### Test A

Simultaneously:

- meeting recording
- realtime transcription
- wake detection
- dictation attempt

Confirm correct ownership / routing.

### Test B

Meeting active + Qwen notes generation.

Check meeting ASR latency does not degrade materially.

### Test C

Agent speaking TTS + user interruption.

Check:

- barge-in <100 ms
- TTS stops
- new utterance captured
- no lost microphone frames

### Test D

ACP coding task running + dictation.

Dictation latency should remain near baseline.

---

# 39. Architecture Change: AudioCaptureHub

This is the most important near-term refactor.

Replace independent microphone consumers with one shared capture source.

```text
AVAudioEngine
     ↓
AudioCaptureHub
     ├── WakeKWSConsumer
     ├── DictationConsumer
     ├── MeetingRecorderConsumer
     ├── MeetingASRConsumer
     └── AgentRealtimeConsumer
```

Consumers can be enabled/disabled without restarting the input hardware.

Benefits:

- no microphone engine contention
- wake word remains alive during meeting recording
- lower startup latency
- less audio format conversion
- simpler echo/barge-in architecture

---

# 40. Architecture Change: Realtime Runtime

Add:

```text
RealtimeRuntime
```

Responsible for:

- shared session state
- VAD
- turn boundaries
- interruption
- partial ASR
- tool loop
- TTS
- task delegation

It should not own meeting recording or dictation formatting.

---

# 41. Implementation Sequence

## Milestone 1 — Instrument everything

Before optimization:

- add latency tracing
- add CPU/GPU/memory logging
- add model load timing
- establish baselines

Do not optimize without numbers.

---

## Milestone 2 — Shared AudioCaptureHub

Solve microphone contention.

Acceptance criteria:

- meeting + wake word simultaneously
- wake phrase triggers while meeting recording
- no second `AVAudioEngine` input conflict
- dictation still reliable

---

## Milestone 3 — Streaming ASR

Implement partial/stabilized transcripts.

Use for:

- agent
- meeting
- dictation precomputation

Acceptance criteria:

- live meeting transcript visibly follows speech
- dictation finalization becomes much faster

---

## Milestone 4 — Dictation fast path

Add:

- deterministic cleanup first
- semantic routing
- persistent model residency
- performance budgets

Acceptance criteria:

- short clean dictation avoids LLM
- semantic cleanup only used where useful
- improved key-release-to-injection latency

---

## Milestone 5 — Meeting event bus

Add:

- `TranscriptBus`
- structured MeetingContext updates
- event-driven action detection

Remove dependence on slow fixed interval polling.

Acceptance criteria:

- relevant action card appears within ~2 s of sentence completion

---

## Milestone 6 — Meeting proactive actions

Build:

- CandidateAction model
- UI card
- user authority enforcement
- approve/edit/dismiss
- post-meeting reconciliation

---

## Milestone 7 — Full duplex agent

Port Qwen architectural concepts:

- persistent session
- streaming turns
- barge-in
- background tasks
- async results

Acceptance criteria:

- user can interrupt assistant
- agent does not block while tools/tasks execute

---

## Milestone 8 — TTS

Start with:

1. `AVSpeechSynthesizer` baseline
2. Kokoro ONNX benchmark
3. Piper fallback benchmark

Choose based on:

- time-to-first-audio
- RAM
- quality
- CPU load
- interruptibility

---

## Milestone 9 — Multi-round tool agent

Replace one-shot tool handling.

Acceptance criteria:

- inspect → click → verify workflows
- bounded loop
- permissions work at each step

---

## Milestone 10 — Browser control

Implement local CDP where possible.

Keep AX fallback.

---

## Milestone 11 — ACP hardening

Validate live against:

- Codex
- Claude Code
- Qwen Code

No silent compatibility fallback.

---

# 42. Validation Scenarios

The coding agent should not consider this complete until these scenarios work.

## Dictation

User holds Right Option:

> “Um so I think uh we should probably ship this tomorrow actually no Friday.”

Output:

> “I think we should probably ship this Friday.”

Fast, silent, injected into the origin app.

---

## Meeting passive action

Participant:

> “Will, send me the latest mechanical enclosure after this.”

Within seconds:

```text
Possible follow-up:
Send latest enclosure to Sarah

[Prepare] [Dismiss]
```

No wake phrase required.

---

## Meeting user command

During meeting:

> “Send her the latest STEP.”

Next Notes:

```text
Enclosure_v17.step → Sarah

[Approve] [Edit] [Dismiss]
```

---

## Agent wake during meeting

Meeting is recording.

User:

> “Hey Next.”

Within <100 ms:

```text
Listening…
```

Meeting recording continues uninterrupted.

User:

> “Check whether ChatGPT has access to the Next Notes repository.”

Agent answers verbally and visually.

---

## Agent computer control

> “Hey Next, open Xcode and run the tests.”

Next Notes:

1. opens Xcode
2. inspects UI
3. identifies Run/Test controls
4. requests permission if needed
5. acts
6. reports progress
7. speaks result

---

## Agent coding delegation

> “Hey Next, use Codex to inspect the latest commit for performance regressions.”

Next Notes:

> “I’ll have Codex check it.”

Conversation remains available while task runs.

---

# 43. Non-Negotiable Design Rules

1. Dictation remains silent and focused.
2. Meetings do not require a wake phrase for proactive intelligence.
3. Only the user's microphone can authorize actions.
4. Agent mode requires explicit wake/shortcut activation.
5. Wake detection must work during meeting recording.
6. Audio capture must never be blocked by model work.
7. Large background models yield to realtime workloads.
8. User-facing latency is measured end-to-end.
9. Every mutating tool passes through PermissionBroker.
10. Tool execution never exposes chain-of-thought.
11. TTS must be interruptible.
12. Background tasks never freeze the conversation.
13. No automatic downgrade from structured ACP to opaque CLI execution.
14. Prefer structured computer state over screenshots.
15. Optimize proven bottlenecks, not assumed ones.

---

# 44. Definition of Success

Next Notes should feel like three products sharing one highly optimized local runtime:

### Dictation

> Speak → polished text appears.

No conversation. No friction.

### Meetings

> Attend → transcript, notes, decisions, and actionable follow-ups emerge continuously.

No wake phrase required for passive intelligence.

### Agent

> “Hey Next” → talk naturally to the Mac, interrupt it, ask follow-ups, and let it safely act across local and cloud tools.

The final experience should not feel like three AI features bolted together.

It should feel like one responsive system that knows which mode the user is in and routes compute, models, context, and interaction accordingly.

---

# 44. Acceptance status — finalized 2026-09-22

Every milestone's code is in the tree and wired; this section records what the scripted
acceptance proves, what a measured real-device session still owes, and which items are
blocked on environment rather than on code.

## Scripted acceptance, all green (2026-09-22, `Scripts/run-selftest.sh`)

| Self-test | Line | §42 scenario it pins |
|---|---|---|
| `--selftest-meeting-live` | `MEETING_LIVE_OK` | meeting passive action: card rules, authority split |
| `--selftest-meeting-live-tools` | `MEETING_LIVE_TOOLS_OK` | meeting user command → tool loop |
| `--selftest-acp` | `ACP_OK: initialize, session, subscribe and permission relay hold` | agent coding delegation |
| `--selftest-contention` | `CONTENTION_OK` | rule 6: capture never blocked by model work; meeting + wake share one hub seat |
| `--selftest-residency` | `MODEL_RUNTIME_OK` + `RESIDENCY_OK` | rule 7: large models yield to realtime |
| `--selftest-duplex`, `--selftest-stream`, `--selftest-transcript-bus` | `DUPLEX_OK`, `STREAM_OK`, `TRANSCRIPT_BUS_OK` | the capture/bus spine |
| `--selftest-toolloop` | `TOOLLOOP_OK` | agent tool loop |
| `--selftest-cleanup-router`, `--selftest-meeting-reconcile` | `CLEANUP_ROUTER_OK`, `MEETING_RECONCILE_OK` | cleanup + candidate reconcile |
| `--selftest-wake` | `WAKE_OK` | spotter loads and spots |
| `--selftest-computer-vision` | `COMPUTER_VISION_OK` | screenshot consent chain (incl. the re-wired `completeWithImages` seam) |

## Wake word — the measured tuning pass (2026-09-22)

The shipped default measured **15/24 hits (0.62) at 3/32 false**. The tuning pass over the
committed fixture set — a 270-config OFAT sweep plus a keywords_score/blanks sweep, run
through the real spotter — found and took the trade-surface maximum: **17/24 (0.71) at the
same 3/32 false**, from three table changes (variant depth 2→4 with the variant threshold
slope steepened to 0.30 at sensitivity 0.6, and the beam plateau lowered 24→16, which also
buys back 2 false accepts at sensitivity 1.0). A phrase bonus that would buy the missing
hits costs 12–18 false accepts — measured, not taken. The self-test therefore stays **red
at its 0.8 bar**: on the synthetic corpus the measured ceiling is 0.71, the missing clips
are the Daniel/Jacques/Thomas rows, and the honest remaining fix is real-room recordings
(`WAKE_MIC` has no captures on this machine), not a lowered bar. The committed table and
its header now state 17/24 @ 3/32, and the pinned beam check matches measurement (16).

## Still open — blocked on environment, named

1. **Real microphone / system audio** — the TCC grant cannot be asked for from a shell;
   `--selftest-systemaudio` reports `SYSTEM_AUDIO_SILENT` and stays unverified until a
   person grants it. No meeting has yet contained an "Others" track.
2. **Wake during a real meeting** — the <100 ms `Listening…` latency with live recording
   and real speech has no scriptable equivalent; contention proves the seats coexist.
3. **Live meeting card < 2 s** — meeting-live pins the debounce and card rules; the
   end-to-end utterance→card seconds need a real meeting.
4. **Dictation into a foreign app** — `--selftest-dictation` covers the state machine; the
   real key + real mic + real target needs a person.
5. **Computer control on a real screen** — `--selftest-computer-actions` is red on a locked
   screen by honest design; runs the first time someone unlocks this machine.
6. **Latency baselines including GPU/ANE** (§46) — never measured; targets remain targets.
