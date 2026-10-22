# Next Notes Unified Action Runtime & Performance Roadmap

> **Historical model assumptions — revised 2026-09-30:** this completed plan/audit
> preserves its dated measurements and implementation history. For new work, follow
> the [independent-role/shared-file contract](../in-progress/SHARED-BRAIN/00-README.md): Meetings, Agent and cleanup
> may use different appropriate models; exact verified artifacts are reused, with
> workload-specific consent and request ownership. Agent-only file selection,
> universal model defaults and deletion based only on the Agent are superseded.
> MiniCPM cleanup + Apple guard/fallback is concurrent work, not evidence that this
> historical build used it. Re-measure quality/latency on the actual current engine.

Implementation and acceptance status: [v3/v4 ledger](ROADMAP-V3-V4-STATUS.md).

## Purpose

This document defines the next major implementation phase for **Next Notes**.

The application has three distinct product pipelines:

1. **Dictation**
2. **Meeting Intelligence**
3. **Interactive Agent**

These pipelines should remain distinct in user experience, but share the infrastructure required for low latency, reliable execution, model orchestration, context handling, permissions, and action execution.

The central architectural change is:

> **Meeting actions and Agent actions should share the same action lifecycle: Judge → Verify → Prepare → Permission → Fire → Verify Result.**

Dictation remains outside the action runtime.

This roadmap incorporates useful architectural lessons from Qwen Audio Agent, Sentient OS, Eveclaw, and the current Next Notes codebase without copying their implementations.

---

# 1. Product Architecture

```text
                           NEXT NOTES
                               │
          ┌────────────────────┼────────────────────┐
          │                    │                    │
      DICTATION             MEETING               AGENT
          │                    │                    │
      one-way             proactive            full duplex
      silent               contextual           interactive
          │                    │                    │
          ▼                    ▼                    ▼
      Text Output         Action Intents      Action Intents
                               │                    │
                               └─────────┬──────────┘
                                         ▼
                                 ActionOrchestrator
```

## 1.1 Dictation

Dictation stays silent and one-way:

```text
Push-to-talk
    ↓
Audio capture
    ↓
Streaming ASR
    ↓
Fast cleanup
    ↓
Grammar / punctuation / formatting
    ↓
Text injection
```

There is no agent conversation, spoken feedback, tool use, or action card in this pipeline.

Primary goals:

- near-instant release-to-injection
- strong punctuation and grammar
- correct technical names
- personal vocabulary learning
- application-aware formatting
- minimal model invocation
- no focus stealing

## 1.2 Meeting Intelligence

Meeting mode is automatic and proactive:

```text
Meeting starts
    ↓
Mic + system audio
    ↓
Streaming transcription
    ↓
TranscriptBus
    ↓
MeetingContext
    ↓
CandidateAction detection
    ↓
ActionOrchestrator
    ↓
Prepared Action Card
    ↓
Approve / Edit / Dismiss
```

The user should not need to say **“Hey Next”** for passive meeting intelligence.

Authority boundary:

```text
System audio / other speakers
→ context only

User microphone
→ may authorize an action
```

## 1.3 Interactive Agent

The global Agent is explicitly activated through the wake phrase, shortcut, or UI.

```text
Wake / Shortcut
    ↓
Realtime voice session
    ↓
Streaming ASR
    ↓
RealtimeAgent
    ↓
Answer / Tool / Background Task
    ↓
ActionOrchestrator
    ↓
Tool or Agent Backend
    ↓
Streaming TTS
```

The user must be able to interrupt the assistant, ask follow-ups while background work continues, inspect progress, approve work, and cancel work.

---

# 2. Unified Action Runtime

Meeting and Agent should not have separate side-effect machinery.

Introduce a single:

```text
ActionOrchestrator
```

with this lifecycle:

```text
INTENT
  ↓
JUDGE
  ↓
VERIFY
  ↓
PREPARE
  ↓
PERMISSION
  ↓
FIRE
  ↓
VERIFY RESULT
```

This runtime owns consequential actions from:

- meeting follow-ups
- interactive agent commands
- computer control
- filesystem writes
- shell execution
- Google Workspace
- MCP
- Composio
- ACP-backed background tasks

---

# 3. Core Action Models

## 3.1 ActionIntent

```swift
struct ActionIntent {
    let id: UUID

    let source: ActionSource
    let authority: ActionAuthority

    let verb: String
    let target: String?
    let arguments: [String: String]

    let evidence: [ContextReference]

    let risk: AgentRisk
    let confidence: Double

    let createdAt: Date
}
```

Suggested sources:

```text
meeting
agent
system
background
```

Suggested authority:

```text
user
otherParticipant
systemDerived
```

## 3.2 CandidateAction

```swift
struct CandidateAction {
    let id: UUID
    let meetingID: UUID?

    let action: String
    let object: String?
    let recipient: String?

    let speaker: String?
    let evidence: String

    let confidence: Double
    let authority: ActionAuthority
}
```

## 3.3 PreparedAction

```swift
struct PreparedAction {
    let id: UUID
    let intentID: UUID

    let title: String

    let preparedContent: PreparedContent?
    let routing: ActionRouting
    let executionPlan: ActionExecutionPlan

    let evidence: [ContextReference]

    let risk: AgentRisk
    let status: PreparedActionStatus
}
```

## 3.4 ActionReceipt

```swift
struct ActionReceipt {
    let actionID: UUID
    let status: ActionReceiptStatus

    let result: String
    let artifacts: [String]

    let verification: String?

    let startedAt: Date
    let completedAt: Date
}
```

---

# 4. Stage 1 — Judge

The Judge answers:

- Is this actionable?
- Who requested it?
- Is the requester authoritative?
- Is there enough context?
- What is the risk?
- Is this actually a question rather than an action?
- Should the system clarify?
- Should it become a background task?

Possible outcomes:

```text
IGNORE
ANSWER
CLARIFY
PREPARE_ACTION
BACKGROUND_TASK
```

The Judge is a **logical stage**, not necessarily an LLM call.

For explicit Agent commands like:

> “Open Xcode.”

use deterministic routing:

```text
authority=user
intent=computer.open_app
confidence=high
```

For passive meeting speech like:

> “Will, can you send Sarah the STEP after this?”

use lightweight semantic classification:

```text
candidate action
authority=otherParticipant
action=send_file
recipient=Sarah
object=STEP
```

Target deterministic Judge latency for obvious commands:

```text
5–20 ms
```

---

# 5. Stage 2 — Verify

Verify resolves real-world state instead of letting the model guess.

Example:

> “Send Sarah the latest STEP.”

Verification:

```text
Sarah
→ Sarah Chen
→ participant in current meeting
→ sarah@example.com

latest STEP
→ Enclosure_v17.step
→ newest matching enclosure model

Gmail
→ connected
```

Verification tools may include:

```text
meeting.participants
meeting.search
filesystem.search
filesystem.stat
workspace.search_email
workspace.get_agenda
workspace.find_drive_files
computer.active_app
browser.current_url
```

If verification is ambiguous, ask instead of guessing.

---

# 6. Stage 3 — Prepare

Prepare creates the exact artifact or plan the user will review.

## Email example

```text
To: sarah@example.com
Subject: Latest enclosure STEP

Hi Sarah,

Attached is the latest enclosure STEP from today's discussion.

Attachment:
Enclosure_v17.step
```

## Calendar example

```text
Design review

Wednesday, 2:00–2:30 PM

Attendees:
Sarah
John
```

## Computer-use example

```text
1. Open Xcode
2. Open the Next Notes project
3. Select the test scheme
4. Run tests
5. Report failures
```

## Shell example

```text
Working directory:
~/Projects/next-notes

Command:
swift test
```

Principle:

> **What the user approves should be what is executed.**

---

# 7. Separate Prepared Content From Routing

Do not mix user-approved content with execution internals.

For email:

```text
preparedContent:
  exact subject + body

routing:
  Gmail
  recipient
  thread
  attachment path
```

For computer use:

```text
preparedContent:
  exact visible plan

routing:
  target application
  window
  URL
```

This minimizes post-approval reinterpretation.

---

# 8. Stage 4 — Permission

All actions pass through the existing `PermissionBroker`.

There should be no separate approval logic hidden in MeetingAgent, RealtimeAgent, MCP, Composio, or ACP.

```text
PreparedAction
      ↓
PermissionBroker
      ├── automatic
      ├── once
      ├── task-scoped
      ├── resource-scoped
      └── deny
```

## 8.1 Resource-scoped grants

Evolve beyond tool-only grants.

Bad:

```text
Always allow computer.click
```

Better:

```text
computer.click
scope: com.apple.dt.Xcode
duration: session
```

Other examples:

```text
filesystem.write
scope: ~/Projects/next-notes/**
duration: task

browser.fill
scope: github.com
duration: task

shell.run
scope: ~/Projects/next-notes
duration: task
```

Suggested scope structure:

```swift
struct PermissionScope {
    let toolID: String
    let resource: String?
    let application: String?
    let domain: String?
    let path: String?
    let taskID: String?
    let meetingID: UUID?
    let duration: PermissionDuration
}
```

---

# 9. Permission Defaults

## Observe

Examples:

- active app
- meeting context
- frontmost window metadata

Default: automatic.

## Read

Examples:

- calendar
- email search
- file metadata
- Drive search

Default: automatic or user-configurable.

## Modify

Examples:

- click
- type
- edit file

Default: ask unless scoped grant exists.

## Communicate

Examples:

- send email
- send Slack message
- reply to thread

Default: explicit confirmation.

## Destructive

Examples:

- delete file
- cancel calendar event
- delete cloud object

Default: strong confirmation.

## Privileged

Examples:

- sudo
- system configuration
- security permissions

Default: deny or specialized workflow.

---

# 10. Stage 5 — Fire

Fire should be deliberately narrow.

It receives a `PreparedAction` and executes that scope.

It must not reinterpret the user's original request and expand it into additional tasks.

The execution engine cannot turn:

> “Send this email.”

into:

> “Send the email, update Notion, and message Slack.”

without new actions entering the orchestrator.

---

# 11. Stage 6 — Verify Result

A tool returning without error is not sufficient proof of success.

Examples:

## Email

```text
send
↓
message ID
↓
confirm accepted
```

## File

```text
write
↓
file exists
↓
size/hash expected
```

## Computer

```text
click Run
↓
inspect UI
↓
running state visible
```

## Browser

```text
click Submit
↓
snapshot
↓
confirmation UI appears
```

Outcome should be:

```text
DONE
```

or:

```text
COULD_NOT
```

not optimistic success without evidence.

---

# 12. Meeting Action Runtime

Meeting flow becomes:

```text
TranscriptBus
    ↓
MeetingContextExtractor
    ↓
CandidateActionDetector
    ↓
Judge
    ↓
Verify
    ↓
Prepare
    ↓
Action Card
    ↓
Permission
    ↓
Fire
    ↓
Verify Result
```

## 12.1 Event-driven action detection

Do not wait for a fixed two-minute poll.

Trigger lightweight detection on:

- finalized utterance
- sentence boundary
- explicit request
- commitment phrase
- deadline mention
- file/document mention
- direct mention of the user

Debounce:

```text
500–1500 ms
```

Heavy reconciliation can still run periodically.

## 12.2 Passive meeting action

Participant:

> “Will, can you send me the latest enclosure after this?”

Within seconds:

```text
Potential follow-up

Send latest enclosure to Sarah

[Prepare] [Dismiss]
```

No wake phrase.

## 12.3 User command during meeting

User says:

> “Send her the latest STEP.”

Because meeting mode is already active, this can be treated as a user-authorized meeting action without requiring “Hey Next.”

```text
mic speech
→ authority=user
→ Judge
→ Verify
→ Prepare
→ card
```

---

# 13. End-of-Meeting Action Review

At meeting completion:

```text
Finalize transcript
↓
Diarization refinement
↓
Notes generation
↓
MeetingContext reconciliation
↓
CandidateAction reconciliation
↓
Prepared action list
```

Example:

```text
Meeting Actions

1. Send STEP to Sarah
   [Approve] [Edit] [Dismiss]

2. Schedule review Wednesday
   [Approve] [Edit] [Dismiss]

3. Create GitHub issue
   [Approve] [Edit] [Dismiss]
```

Actions execute independently.

---

# 14. Agent Action Runtime

Agent commands use the same orchestrator.

Example:

> “Hey Next, send Sarah the latest STEP.”

```text
RealtimeAgent
    ↓
ActionIntent
    ↓
Judge
    ↓
Verify
    ↓
Prepare
    ↓
Permission
    ↓
Fire
    ↓
Verify Result
```

This avoids duplicated execution semantics between Meeting and Agent.

---

# 15. Background Agent Tasks

Long-running work still uses `AgentTaskManager`.

However, consequential side effects inside a task must go through `ActionOrchestrator`.

Example:

> “Fix the failing tests and create a PR.”

Task flow:

```text
read repo
→ automatic read

run tests
→ scoped execution

edit code
→ scoped write

push branch
→ explicit approval

create PR
→ explicit approval
```

The background agent remains intelligent, while the action runtime owns authority.

---

# 16. Action References

Actions should have stable references.

Example:

```text
action://meeting/123/A17
```

Then:

> “Hey Next, do the second action.”

can resume:

```text
CandidateAction
→ Verify latest state
→ Prepare
→ Permission
→ Fire
```

without reconstructing the intent.

---

# 17. Full-Duplex Agent Runtime

Continue the Qwen-inspired architecture.

```text
RealtimeAgent
    │
    ├── answer directly
    ├── immediate safe tool
    └── background task
```

Conversation must remain available while background work runs.

State machine:

```text
SLEEPING
   ↓
LISTENING
   ↓
THINKING
   ↔
SPEAKING
   ↔ barge-in
LISTENING
```

---

# 18. Barge-In

While TTS is speaking, the microphone remains active.

```text
user begins speaking
↓
speech detected
↓
stop TTS
↓
preserve context
↓
capture new utterance
```

Target interruption latency:

```text
<100 ms
```

---

# 19. TTS

Add local spoken responses.

Initial benchmark order:

1. `AVSpeechSynthesizer`
2. Kokoro 82M ONNX / quantized
3. Piper

Selection criteria:

- time to first audio
- RAM
- naturalness
- CPU use
- interruptibility
- deployment complexity

Use a short spoken summary plus detailed visual content.

---

# 20. Streaming TTS

Do not wait for a whole paragraph.

```text
LLM stream
↓
clause buffer
↓
TTS clause
↓
play
↓
synthesize next clause
```

Target first audio:

```text
~300–500 ms after first complete short clause
```

---

# 21. Shared AudioCaptureHub

Implement one microphone engine with fan-out consumers.

```text
Microphone
    ↓
AudioCaptureHub
    ├── DictationConsumer
    ├── MeetingRecorderConsumer
    ├── MeetingASRConsumer
    ├── WakeWordConsumer
    └── AgentRealtimeConsumer
```

This is critical to solve wake-word failures during active meetings.

---

# 22. Wake Detection During Meetings

The wake detector should operate directly on microphone samples:

```text
mic
→ sherpa KWS
→ wake event
```

Do not depend on:

```text
meeting chunk
→ ASR
→ transcript
→ wake phrase string match
```

The wake detector must stay alive while meeting recording runs.

Immediate acknowledgement target:

```text
wake detected → Island listening state <100 ms
```

---

# 23. TranscriptBus

Introduce an event bus for transcript consumers.

```swift
struct TranscriptEvent {
    let source: AudioSource
    let text: String

    let start: TimeInterval
    let end: TimeInterval

    let isFinal: Bool
    let meetingID: UUID?
}
```

Subscribers:

- meeting transcript UI
- MeetingContext
- CandidateActionDetector
- notes accumulator
- live agent context

This removes polling-based coupling.

---

# 24. Streaming Meeting ASR

Move toward short provisional/stable segments.

```text
speech
→ partial transcript
→ stable transcript
```

Targets:

```text
visible partial <500 ms
stable text <1–2 s
```

---

# 25. Dictation Performance Architecture

Dictation pipeline:

```text
audio
→ streaming ASR
→ deterministic cleanup
→ semantic escalation only if needed
→ injection
```

Deterministic cleanup handles:

- punctuation
- capitalization
- spoken punctuation
- duplicate fillers
- personal dictionary
- known technical words
- application-specific formatting
- path formatting

Semantic models are reserved for actual restructuring.

---

# 26. CleanupRouter

Introduce:

```text
CleanupRouter
```

Suggested policy:

```text
short + clean
→ RuleBasedFormatter

moderate repair
→ S1

complex / long
→ Foundation Model or Qwen
```

Routing considers:

- transcript length
- disfluency count
- punctuation uncertainty
- model residency
- GPU pressure
- application profile

---

# 27. ModelRuntimeManager

Borrow Sentient OS's runtime discipline, not its code.

Introduce:

```text
ModelRuntimeManager
```

Managed runtimes:

```text
ParakeetRuntime
S1Runtime
QwenRuntime
FoundationModelRuntime
WakeRuntime
TTSRuntime
```

States:

```text
unloaded
loading
warming
ready
busy
wedged
recovering
```

---

# 28. Runtime Metrics

Every inference should expose metrics.

For LLMs:

```text
load_ms
first_token_ms
input_tokens
output_tokens
prefill_tok_s
decode_tok_s
total_ms
peak_memory
backend
```

For ASR:

```text
first_partial_ms
finalization_ms
realtime_factor
```

These metrics should be locally persisted in rolling diagnostics.

---

# 29. Model Prewarming

## App launch

Warm:

- wake KWS
- Apple Speech
- audio format path

## Idle

Best-effort:

- Parakeet

## Meeting armed

Ensure:

- meeting ASR ready
- lightweight context model available

## Agent activation

Ensure:

- TTS ready
- realtime model warm

---

# 30. Hard Output Budgets

Use workload-specific caps.

Suggested starting points:

```text
Dictation cleanup:
128–256 tokens

Meeting action classification:
128–256

Realtime voice answer:
256–500

Meeting summary:
larger / chunked

Background task:
backend-controlled
```

Realtime paths should never inherit meeting-summary token budgets.

---

# 31. GPU Runtime Recovery

If a model's GPU runtime repeatedly fails:

```text
mark wedged
↓
destroy runtime
↓
allow Metal cleanup
↓
reload
↓
retry once
```

One bad runtime should not require restarting Next Notes.

---

# 32. ComputeScheduler

Introduce a central scheduler with work classes:

```swift
enum WorkClass {
    case realtimeAudio
    case realtimeASR
    case realtimeAgent
    case meetingLive
    case background
}
```

Priority:

```text
1. realtimeAudio
2. realtimeASR
3. realtimeAgent
4. meetingLive
5. background
```

A large notes generation must yield before it degrades realtime ASR.

---

# 33. CPU / GPU / NPU Strategy

## CPU

Use primarily for:

- capture
- VAD
- wake orchestration
- deterministic formatting
- tool routing
- permission logic
- Accessibility
- filesystem
- shell management
- lightweight TTS

## GPU

Use for:

- llama.cpp
- Qwen
- heavier semantic cleanup
- local summarization
- reasoning

## Neural Engine

Use where Core ML benchmarks prove useful:

- Parakeet
- small classifiers
- possibly TTS

Do not route workloads to the NPU based on theory alone. Measure first-token/first-frame latency and total throughput.

---

# 34. Foreground vs Background UX

Internally allow concurrent tasks, but make the Island narrate only one foreground task.

```text
AgentTaskManager
    ├── foregroundTask
    └── backgroundTasks
```

Island:

```text
one foreground narrative
```

Agent View:

```text
all tasks
```

---

# 35. Humanized Activity Projection

Raw internal events should become user-level language.

Bad:

```text
filesystem.search "*.step"
```

Good:

```text
Finding the latest STEP file…
```

Bad:

```text
computer.inspect_ui
```

Good:

```text
Looking at Xcode…
```

Expand `AgentActivityProjector` accordingly.

---

# 36. Fast / Balanced / Deep

Add an Agent responsiveness control:

```text
Fast
Balanced
Deep
```

It may affect:

- reasoning effort
- model selection
- background delegation threshold
- verification depth

It must **not** slow down Dictation.

---

# 37. Hotkey Experiment

Independently test whether Right Command/Right Option can use `NSEvent.flagsChanged` and device-specific modifier bits reliably.

Compare against current `CGEventTap` for:

- permissions
- reliability
- missed release behavior
- focus
- launch behavior

Keep CGEventTap where required, especially `fn`.

---

# 38. Browser Control

Preferred hierarchy:

```text
1. native integration
2. browser CDP / DOM
3. Accessibility
4. vision fallback
```

Add local Chrome-family CDP support for:

- tabs
- URL
- DOM
- accessibility tree
- click
- fill
- submit
- downloads

AX remains useful fallback.

---

# 39. ACP

ACP remains the preferred coding-agent interface.

Support:

- Codex
- Claude Code
- Qwen Code
- OpenCode
- additional ACP agents

Do not silently fall back from ACP to opaque CLI prompt mode.

Instead:

```text
ACP unavailable.

Run using compatibility CLI mode?

[Run once] [Cancel]
```

---

# 40. MCP

Continue the native MCP implementation.

Improve discovery so:

```text
MCP inputSchema
→ AgentTool parameters

MCP annotations
→ risk hints
```

Next Notes remains the final permission authority.

---

# 41. Canonical Tool IDs

Prefer capability names independent of implementation.

Example:

```text
github.create_issue
```

rather than:

```text
mcp.Composio.GITHUB_CREATE_ISSUE
```

`ToolRouter` chooses:

- native
- MCP
- Composio
- ACP

---

# 42. Google Workspace

Keep Google Workspace native.

Resolution order:

```text
1. Native
2. Explicit MCP
3. Composio
```

Examples:

```text
Gmail → native
Calendar → native
Drive → native
GitHub → MCP/Composio
Notion → MCP/Composio
```

---

# 43. NextMemory

Do not build a full "read the user's entire life" ingestion engine yet.

Create a constrained local memory derived naturally from Next Notes activity:

```text
People
Projects
Vocabulary
Meetings
Commitments
Files
Tool preferences
Recurring actions
```

This makes commands such as:

> “Send Sarah the latest enclosure.”

much easier to resolve.

---

# 44. Audit & Receipts

Every meaningful action should leave a receipt.

Example:

```text
15:31
Detected:
Sarah asked for latest enclosure

15:31
Verified:
Sarah Chen
Enclosure_v17.step

15:32
Prepared email

15:32
Approved by user

15:32
Sent

15:32
Verified message ID
```

---

# 45. Diagnostics and Latency Spans

## Dictation

Track:

```text
keyDown
captureReady
firstSpeech
firstPartial
keyUp
asrFinal
cleanupFinal
injected
```

## Meeting

Track:

```text
speech
partialTranscript
finalTranscript
contextUpdated
candidateDetected
cardVisible
```

## Agent

Track:

```text
wakeDetected
listeningVisible
speechEnd
asrFinal
firstModelToken
firstTTSAudio
toolStart
toolEnd
bargeIn
```

---

# 46. Suggested Latency Targets

## Dictation

```text
capture start: <100 ms
first partial: <300–500 ms
key release → final text: <300–700 ms typical
injection: <50 ms after formatting
```

## Meeting

```text
speech → visible partial: <500 ms
speech → stable text: <1–2 s
action sentence → card: <2 s
```

## Agent

```text
wake → visual acknowledgement: <100 ms
speech end → simple response: <500–1000 ms
first TTS audio: <300–500 ms after first complete clause
barge-in: <100 ms
```

---

# 47. Implementation Milestones

## Milestone 0 — Baseline instrumentation

Implement before major optimization:

- timing spans
- model metrics
- CPU/GPU/memory tracking
- current latency baseline

### Acceptance

Every Dictation, Meeting, and Agent turn can be broken down into measured stages.

---

## Milestone 1 — Core action models

Implement:

- `ActionIntent`
- `CandidateAction`
- `PreparedAction`
- `ActionReceipt`
- `ActionRouting`
- `ActionExecutionPlan`

### Acceptance

Objects persist safely and have stable IDs.

---

## Milestone 2 — ActionOrchestrator

Implement:

```text
judge()
verify()
prepare()
requestPermission()
fire()
verifyResult()
```

### Acceptance

One action originating from Meeting and one from Agent both execute through the same runtime.

---

## Milestone 3 — Meeting integration

Replace direct meeting proposal execution with ActionOrchestrator.

### Acceptance

- passive speaker request creates CandidateAction
- other speaker never authorizes execution
- user can prepare/approve/edit/dismiss

---

## Milestone 4 — Agent integration

Route consequential Agent tool use through ActionOrchestrator.

Keep bounded, safe reads on the low-latency path where appropriate.

### Acceptance

Email send, file modification, and computer actions share the unified lifecycle.

---

## Milestone 5 — Shared AudioCaptureHub

Implement fan-out audio.

### Acceptance

- meeting recording + wake KWS simultaneously
- no microphone engine contention
- "Hey Next" reliably wakes during meetings
- dictation remains stable

---

## Milestone 6 — Streaming ASR

Implement partial/stabilized transcript events.

### Acceptance

- meeting transcript visibly follows speech
- dictation performs most recognition before key release
- agent turn boundary no longer waits for large batch transcription

---

## Milestone 7 — TranscriptBus

Replace polling with transcript events.

### Acceptance

- MeetingContext updates incrementally
- CandidateActionDetector receives finalized utterances directly

---

## Milestone 8 — Proactive meeting actions

Implement Judge → Verify → Prepare for live meetings.

### Acceptance

Relevant action card appears within approximately two seconds of the triggering sentence.

---

## Milestone 9 — TTS

Ship an Apple-system TTS baseline, then benchmark Kokoro and Piper.

### Acceptance

- spoken Agent responses
- interruption works
- detailed output remains visual

---

## Milestone 10 — Full duplex

Implement:

- continuous conversational session
- barge-in
- TTS streaming
- background task continuity

### Acceptance

User can interrupt and immediately continue the conversation.

---

## Milestone 11 — Multi-round tool loop

Implement:

```text
model
→ tool
→ result
→ model
→ next tool
→ result
→ final answer
```

Bound by:

- max rounds
- max wall time
- max tool calls

### Acceptance

"Inspect Xcode, click Run, verify it started" works as one conversational turn.

---

## Milestone 12 — Resource-scoped permissions

Add app/path/domain/task/meeting scopes.

### Acceptance

User can allow Xcode control without globally allowing all computer control.

---

## Milestone 13 — MCP schema translation

Translate input schemas and annotations into `AgentTool`.

### Acceptance

External tools expose correct required fields and risk hints.

---

## Milestone 14 — Browser CDP

Add structured browser control for Chrome-family browsers.

### Acceptance

Common browse/fill/click workflows avoid pixel guessing.

---

## Milestone 15 — ModelRuntimeManager

Centralize model lifecycle and metrics.

### Acceptance

Models can prewarm, unload, recover, and report performance consistently.

---

## Milestone 16 — ComputeScheduler

Prioritize realtime work.

### Acceptance

A large notes generation does not materially degrade active Dictation, Meeting ASR, or Agent voice latency.

---

## Milestone 17 — NextMemory

Implement constrained structured local memory.

### Acceptance

People, projects, recent meetings, and user-specific vocabulary improve entity resolution.

---

# 48. Validation Scenarios

## Dictation

User says:

> “Um I think we should probably ship this tomorrow, actually no Friday.”

Expected output:

> “I think we should probably ship this Friday.”

No conversation. No feedback. Fast injection.

---

## Meeting passive action

Sarah says:

> “Will, send me the latest enclosure after this.”

Expected:

```text
Potential follow-up

Send latest enclosure to Sarah

[Prepare] [Dismiss]
```

---

## Meeting user authorization

User says:

> “Send her the latest STEP.”

Expected:

```text
Enclosure_v17.step
→ Sarah Chen

[Approve] [Edit] [Dismiss]
```

---

## Agent wake during meeting

Meeting continues recording.

User:

> “Hey Next.”

Expected within ~100 ms:

```text
Listening…
```

Then:

> “Check whether Codex can access this repo.”

Agent responds verbally and visually without interrupting meeting capture.

---

## Agent computer use

User:

> “Hey Next, open Xcode and run the tests.”

Expected flow:

```text
Judge
→ Verify Xcode/project
→ Prepare plan
→ Permission
→ Fire
→ Verify running/test state
→ spoken result
```

---

## Background coding task

User:

> “Use Codex to fix the failing tests and prepare a PR.”

The conversation remains available.

When push/PR side effects are reached:

```text
PreparedAction
→ explicit approval
```

---

# 49. Required Invariants

1. Dictation never enters ActionOrchestrator.
2. Other meeting participants cannot authorize actions.
3. All consequential Meeting and Agent actions share ActionOrchestrator.
4. PermissionBroker remains the central authority.
5. Fire cannot expand beyond PreparedAction.
6. Meaningful side effects are verified afterward.
7. Wake detection works during meeting recording.
8. Audio capture never blocks on model work.
9. Background tasks never freeze conversation.
10. TTS is interruptible.
11. Every model workload has a specific budget.
12. External tools never bypass Next Notes permissions.
13. ACP compatibility execution is never substituted silently.
14. Computer control prefers structured state over screenshots.
15. Every consequential action leaves an audit receipt.
16. Large background inference yields to realtime workloads.
17. The Island shows one coherent foreground activity narrative.
18. User-approved content is separated from routing/execution metadata.

---

# 50. Definition of Success

Next Notes should feel like three products powered by one optimized local runtime.

## Dictation

> Speak → polished text appears.

Silent, fast, reliable.

## Meetings

> Attend → live transcript → decisions → prepared actions → one-tap execution.

Proactive, contextual, safe.

## Agent

> “Hey Next” → talk naturally → interrupt naturally → act across the Mac and cloud → continue talking while tasks run.

Fluid, full duplex, action-capable.

The common action protocol underneath Meeting and Agent is:

```text
Judge
→ Verify
→ Prepare
→ Permission
→ Fire
→ Verify Result
```

That should become the core execution protocol of Next Notes.
