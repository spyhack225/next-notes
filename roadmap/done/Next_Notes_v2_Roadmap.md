# Next Notes v2

> **Historical model assumptions — revised 2026-09-30:** this completed plan/audit
> preserves its dated measurements and implementation history. For new work, follow
> the [independent-role/shared-file contract](../in-progress/SHARED-BRAIN/00-README.md): Meetings, Agent and cleanup
> may use different appropriate models; exact verified artifacts are reused, with
> workload-specific consent and request ownership. Agent-only file selection,
> universal model defaults and deletion based only on the Agent are superseded.
> MiniCPM cleanup + Apple guard/fallback is concurrent work, not evidence that this
> historical build used it. Re-measure quality/latency on the actual current engine.

## From Local Dictation + Meeting Notes to a Local Voice Interface for Your Computer

**Status:** Architecture roadmap — implementation progress as of 2026-09-13 is in [Progress](#progress-2026-09-13)  
**Primary platform:** macOS  
**Design principle:** Local-first, user-authorized, voice-native agent execution

---

# Progress (2026-09-13)

The design in the rest of this document is unchanged. This section is only what has landed in the macOS tree, what a self-test can prove today, and what still needs a model, grant or account on the user's machine. Windows was not given these features and is out of scope.

**Overall (2026-09-13):** 13 of 13 phases have code. **12 Done** against a self-test that does not need a missing grant or model. **1 In tree (unproven)** — Composio, which cannot handshake without the user's API key. **0 Not started.** Remaining live gaps are user action (TCC, `gws`, Qwen, a coding CLI, a real meeting).

Verified on 2026-09-13:

| Check | Result |
|---|---|
| `make build` | pass |
| `make test` (23 dictionary + spoken-form vectors) | pass |
| `--selftest-tools` | `TOOLS_OK` |
| `--selftest-wake` | `WAKE_OK` — `WAKE_LOADED` + `WAKE_SPOTTED: LIGHT_UP` |
| `--selftest-tasks` | `TASKS_OK` |
| `--selftest-meeting-context` | `MEETING_CONTEXT_OK` |
| `--selftest-realtime` | `REALTIME_OK: context, capabilities, harness routing and duplex VAD hold` |
| `--selftest-computer` | `COMPUTER_OK: inspected, clicked OK, typed hello` — empty pid reports `stub tree, 0 names` |
| `--selftest-mcp` | `MCP_OK: initialize, session, list and call hold` (local stdio fixture) |
| `--selftest-acp` | `ACP_OK: initialize, session, subscribe and permission relay hold` |
| `--selftest-activity` | `ACTIVITY_OK: tool runs project public titles` |
| `--selftest-fs` | `FS_OK: search, read and privileged-shell refuse hold` |
| `--selftest-browser` | `BROWSER_OK: stub trees invent no elements; Eve loop needs a snapshot id` |
| `make install` | `/Applications/Next Notes.app`, signed **Next Notes Local Signing** |

Status language used below:

| Status | Means |
|---|---|
| **Done** | In the tree and proven by a self-test that does not need a missing grant or model |
| **In tree (unproven)** | Written and compiled; the live path needs a model, TCC grant, account or CLI |
| **Blocked** | Cannot finish here until the user supplies that model, grant or account |
| **Not started** | No implementation |

### Phase checklist

| Phase | Status | How to verify |
|---|---|---|
| 0 Foundation | **Done** | `--selftest-tools` |
| 1 Permission broker | **Done** | `--selftest-tools` |
| 2 Realtime agent | **Done** (duplex + capabilities) | `--selftest-realtime`; ⇧⌘ Space then speak — no Done |
| 3 Wake + shortcut | **Done** | `--selftest-wake`; Settings ▸ Agent ▸ Voice wake |
| 4 Meeting context | **Done** (heuristic path) | `--selftest-meeting-context` |
| 5 In-context actions | **Done** (wiring) | `--selftest-meeting-context`; `--selftest-realtime` |
| 6 Task manager | **Done** | `--selftest-tasks`; harness pick before `submit` |
| 7 Computer tools | **Done** | `--selftest-computer`; sidebar **Agent** “click the OK button” |
| 8 Filesystem + shell | **Done** | `--selftest-fs`; sidebar “find…” still asks |
| 9 MCP | **Done** (fixture handshake) | `--selftest-mcp` |
| 10 Composio | **In tree (unproven)** | Settings ▸ Integrations — needs the user's API key |
| 11 ACP backends | **Done** (stdio session) | `--selftest-acp`; live CLI still user-installed |
| 12 Browser | **Done** (honest stub + Eve loop) | `--selftest-browser`; `--selftest-computer` |

### What the user still must do

1. **Try the agent.** Sidebar **Agent**, or ⇧⌘ Space (Settings ▸ Agent). Type **“what can you do”** — that must answer without a model. Then “What’s on my calendar today?” Push-to-talk stays dictation. Stop leaves a visible “Stopped.”
2. **TCC, if a toggle lies.** This install is signed with the stable **Next Notes Local Signing** certificate, so a grant given once should survive later `make install`s. If Accessibility or Microphone still fails, reset that one row — never omit the bundle ID — then re-grant:
   `tccutil reset Accessibility ai.pivotstudio.nextnotes`
   `tccutil reset Microphone ai.pivotstudio.nextnotes`
   Then quit System Settings entirely (⌘Q) before reopening.
3. **“Hey Next” from sleep.** Settings ▸ Agent ▸ Voice wake + Listen while sleeping. The sherpa-onnx keyword model is on disk (`WAKE_LOADED` / `WAKE_SPOTTED`). Microphone grant required. System audio still never authorises a command.
4. **Computer control.** Settings ▸ Agent ▸ “Click and type without asking” for a standing yes; otherwise the island / Agent sidebar asks. Try “click the OK button” or “type hello in the focused field”. Accessibility grant required.
5. **Calendar and mail answers.** Sign in `gws` on Settings ▸ Workspace. Reads can auto-run; sends always ask.
6. **Richer conversation.** Download Qwen3.5-4B, or use Apple Foundation Models, in Settings ▸ Models. Without a model, meeting-context and calendar-shaped questions still answer; open-ended chat falls back.
7. **Meetings with “Others”.** System Audio Recording grant. `--selftest-systemaudio` is the honest probe (`SYSTEM_AUDIO_SILENT` when the tap is digital silence). There is no `hasSystemAudio` checklist row.
8. **Composio / ACP.** API key in Settings ▸ Integrations (no key has been entered). Install Claude Code, Codex or Qwen Code for a live ACP hand-off — `--selftest-acp` already speaks the session protocol to a local fixture. `cli -p` is only the fallback when `initialize` fails, and that path is labelled as not ACP.

---

# 1. Product Vision

Next Notes currently combines three useful capabilities:

1. Push-to-talk local dictation
2. Local meeting recording, transcription, diarization, and notes
3. Agent-generated Google Workspace follow-up actions

The next architecture should unify these into a larger system:

> **Next Notes becomes the persistent voice interface between the user, their computer, their meetings, their local tools, and their cloud applications.**

The user should eventually be able to say:

> “Next, find the latest STEP file and send it to John.”

> “Next, what did Sarah just ask me to do?”

> “Create a GitHub issue from that action item.”

> “Open the project in Xcode and run the tests.”

> “Check my calendar before agreeing to that meeting.”

> “Work on this while I continue the call.”

Next Notes should be able to understand the current context, determine whether the request can be executed immediately or requires a longer-running agent task, request permission when necessary, execute the action through the appropriate local or cloud tool, and report the result naturally.

This is not simply adding more function calls to the current `MeetingAgent`.

It requires separating:

- conversation,
- context,
- reasoning,
- task execution,
- tools,
- permissions,
- and integrations.

---

# 2. Architecture Principles

## 2.1 Voice is the interface, not the execution engine

The realtime conversational agent should remain responsive.

It should not block for 30 seconds while:

- searching files,
- editing documents,
- running terminal commands,
- waiting for another coding agent,
- navigating a browser,
- or interacting with a cloud application.

The architecture should separate:

**foreground conversation**

from:

**background execution**

This is one of the most important concepts to borrow from `qwen-audio-agent`.

Qwen Audio Agent explicitly separates its realtime voice frontend from a backend action agent. Requests requiring sustained work are delegated as Tasks while the voice conversation continues. 

---

## 2.2 Local first

Next Notes should continue to treat the Mac as the primary runtime.

Whenever practical:

- audio capture stays local,
- wake-word detection stays local,
- transcription stays local,
- meeting context stays local,
- computer control stays local,
- files stay local,
- permission policy stays local.

Cloud access should occur when the user intentionally invokes a cloud capability such as Gmail, Calendar, GitHub, Notion, Slack, etc.

---

## 2.3 Other people provide context, not authority

This should become a hard security invariant.

Next Notes already separates:

**microphone audio: the user**

from:

**system audio: other meeting participants**

Therefore:

```text
USER MICROPHONE
    ↓
May contain commands

SYSTEM AUDIO
    ↓
Context only
```

Example:

Sarah says:

> “Will, send me the CAD files.”

Next Notes may understand:

```text
Candidate action:
Send CAD files to Sarah
```

But it must **not execute that instruction**.

The user then says:

> “Next, send her the latest STEP file.”

Now there is explicit user authority.

This protects against both accidental execution and voice-based prompt injection during meetings.

---

# 3. Target Architecture

```text
                          NEXT NOTES
┌───────────────────────────────────────────────────────────────┐
│                                                               │
│                         ACTIVATION                            │
│                                                               │
│       Push-to-talk │ Wake Phrase │ Keyboard Shortcut          │
│                              │                                │
├──────────────────────────────┼────────────────────────────────┤
│                              ▼                                │
│                    REALTIME VOICE AGENT                       │
│                                                               │
│       ASR ─► Conversation ─► Intent ─► Response/TTS           │
│                              │                                │
│                ┌─────────────┴─────────────┐                  │
│                │                           │                  │
│          Immediate Tool              Background Task          │
│                │                           │                  │
├────────────────┼───────────────────────────┼──────────────────┤
│                │                           ▼                  │
│                │                     TASK MANAGER             │
│                │                           │                  │
│                │                     Agent Backend            │
│                │                           │                  │
│                │          ┌────────────────┼──────────────┐   │
│                │          │                │              │   │
│                │       Local          ACP Agent       Future  │
│                │       Agent          Backend          Cloud  │
│                │                                              │
├────────────────┴────────────────────────────────────────────-─┤
│                        TOOL REGISTRY                          │
│                                                               │
│ Meeting │ Computer │ Shell │ Files │ Browser │ Cloud Apps     │
│                                                               │
├──────────────────────────────────────────────────────────--───┤
│                      INTEGRATION LAYER                        │
│                                                               │
│ Native Google Workspace     MCP      Optional Composio MCP    │
│                                                               │
├───────────────────────────────────────────────────────────--──┤
│                     PERMISSION BROKER                         │
│                                                               │
│ Read │ Write │ External Communication │ Destructive │ Admin.  │
│                                                               │
├────────────────────────────────────────────────────────────--─┤
│                       CONTEXT ENGINE                          │
│                                                               │
│ Meeting │ Active App │ Selection │ Screen │ Files │ Memory    │
│                                                               │
└───────────────────────────────────────────────────────────--──┘
```

---

# 4. Component 1: Activation Layer

Next Notes should support three simultaneous activation mechanisms.

## A. Push-to-talk

Keep the current mechanism.

This remains the most deterministic interaction:

```text
hold key
→ speak
→ release
→ process
```

It is ideal for dictation and explicit commands.

---

## B. Global agent shortcut

Add a dedicated shortcut separate from dictation.

Example:

```text
⇧⌘Space
```

Pressing it opens the Next Notes Island in agent mode.

The user can immediately speak:

> “What's on my calendar this afternoon?”

This should work regardless of the currently focused application.

Qwen Audio Agent uses a similar desktop shortcut and makes it configurable in Settings. 

---

## C. Wake phrase

Default:

> **“Hey Next”**

Alternative:

> **“Next”**

I recommend a two-word default because a single common word increases accidental activations.

### Local detection

Borrow the wake architecture from Qwen Audio Agent.

Its desktop client performs keyword detection locally while sleeping and does not send wake-word audio to a remote service. The current implementation uses sherpa-onnx and downloads approximately 33 MB of wake-word model assets when first enabled. 

Qwen's current shipped keyword is effectively baked into its keyword configuration. Its model manager writes the keyword into `keywords.txt`. 

Next Notes should improve this.

---

# 5. User-configurable wake phrase

Settings should contain:

```text
Settings
  └── Agent
      └── Activation

          Voice Wake               [ ON ]

          Wake phrase
          ┌──────────────────────┐
          │ Hey Next             │
          └──────────────────────┘

          [ Test phrase ]

          Sensitivity
          Conservative ───●──── Sensitive

          Listen while sleeping   [ ON ]

          Agent shortcut
          ⇧⌘ Space

          Push-to-talk
          Right Option
```

## Changing the wake phrase

The user enters:

```text
Computer
```

or:

```text
Hey Nova
```

Next Notes should:

1. Normalize the phrase.
2. Check that the phrase can be represented by the installed keyword model.
3. Generate/update the local keyword configuration.
4. Restart the lightweight wake detector.
5. Ask the user to say the phrase 2–3 times.
6. Display detection confidence.
7. Save it only if detection reliability is acceptable.

Example:

```text
Wake phrase: "Hey Nova"

Say it normally.

Listening...

Attempt 1     0.91 ✓
Attempt 2     0.86 ✓
Attempt 3     0.89 ✓

[Use "Hey Nova"]
```

No wake-word audio needs to leave the device.

### Important fallback

Changing the wake phrase must never make the agent inaccessible.

The configurable keyboard shortcut always remains available.

---

# 6. Command capture during meetings

Wake-word activation becomes particularly useful during calls.

Normal microphone speech:

```text
"This quarter we shipped three versions..."
```

goes into the meeting transcript.

But:

```text
"Hey Next, remind me what John said about pricing."
```

should create an **agent interaction**.

Architecture:

```text
Microphone
    │
    ├── ordinary speech
    │       ↓
    │   Meeting transcript
    │
    └── wake phrase detected
            ↓
        Command capture
            ↓
        Realtime Agent
```

Agent commands should still be recorded internally for audit/history but marked:

```text
source: user
type: agent_command
includeInMeetingNotes: false
```

This prevents:

> “Hey Next, email the proposal”

from appearing as a normal meeting statement and polluting the final meeting notes.

---

# 7. Component 2: Realtime Voice Agent

Today Next Notes largely performs:

```text
speech
→ transcription
→ formatting
→ output
```

The new architecture introduces a persistent conversational agent:

```text
speech
→ ASR
→ RealtimeAgent
→ intent
```

The realtime agent decides among three outcomes:

### Answer directly

Example:

> “What did she just say?”

Uses local meeting context.

### Execute a bounded tool

Example:

> “What's on my calendar tomorrow?”

Uses a safe Calendar read tool.

### Delegate work

Example:

> “Open the Next Notes project, investigate why the test is failing, fix it, and tell me what changed.”

That becomes an `AgentTask`.

This distinction is borrowed directly from Qwen Audio Agent's foreground-conversation/background-execution model. 

---

# 8. Component 3: Agent Task Manager

Introduce:

```text
AgentTaskManager
```

This is one of the biggest architectural changes.

An `AgentTask` should contain structured state such as:

```text
AgentTask

id
objective
source
createdAt

contextReferences

status
    queued
    running
    waitingForPermission
    waitingForInput
    completed
    failed
    cancelled

progress
result
artifacts
```

Do **not** put execution details into the conversational prompt unnecessarily.

Qwen Audio Agent makes the Task record a delivery/lifecycle object rather than exposing the backend's complete execution graph to the voice agent. This is the right model for Next Notes. 

---

# 9. Task UX

When the user says:

> “Find the latest enclosure STEP file and upload it to Drive.”

The Island can transition:

```text
NEXT

Finding latest enclosure…

◉ Searching files
```

Then:

```text
NEXT

Found:
Enclosure_v17.step

Upload to Google Drive?

[Approve] [Dismiss]
```

After approval:

```text
NEXT

Uploaded Enclosure_v17.step

[Open in Drive]
```

The important difference is that the user can continue speaking while the task works.

---

# 10. Borrow Qwen's BackendPort abstraction

Qwen Audio Agent has a protocol-neutral backend interface covering:

- start,
- health,
- submit,
- status,
- cancel,
- authorization responses,
- user-input responses,
- subscriptions,
- shutdown. 

Build a Swift equivalent:

```text
AgentBackend

start()
health()

submit(task)
status(taskID)
cancel(taskID)

respondPermission(...)
respondInput(...)

events(taskID)
```

Initial implementations:

```text
LocalAgentBackend
ACPAgentBackend
```

Future:

```text
CloudAgentBackend
RemoteAgentBackend
```

This prevents Next Notes from becoming coupled to one agent runtime.

---

# 11. ACP support

ACP should become the main interface for delegating complex computer work to external agents.

Possible backends:

```text
Claude Code
Codex
Qwen Code
OpenCode
OpenClaw
Kimi Code
etc.
```

Qwen Audio Agent already uses ACP as the common interface for many of these backends. 

Next Notes does not need to recreate all of these agents.

It should become the **voice/context/permission layer above them**.

Example:

```text
User
 │
 │ "Fix the failing Next Notes build."
 ▼
Next Notes
 │
 ├── understands request
 ├── knows active project
 ├── knows current files
 │
 ▼
ACP
 │
 ▼
Codex / Claude Code
 │
 ├── inspect repo
 ├── run build
 ├── modify code
 ├── run tests
 │
 ▼
Result
 │
 ▼
Next Notes
 │
 ▼
"It's fixed. The issue was..."
```

---

# 12. Component 4: Generic Tool Registry

The existing architecture centers around:

```text
WorkspaceTools
```

This should become:

```text
AgentToolRegistry
```

A tool should contain:

```text
id
namespace
name
description
parameters

risk
source
executionMode

executor
```

Namespaces:

```text
meeting.*
computer.*
shell.*
filesystem.*
browser.*
workspace.*
github.*
notion.*
slack.*
mcp.*
```

---

# 13. Tool categories

## Meeting

```text
meeting.current
meeting.transcript
meeting.recent_context
meeting.participants
meeting.action_items
meeting.decisions
meeting.search
```

## Computer

```text
computer.active_app
computer.windows
computer.inspect_ui
computer.click
computer.focus
computer.open_app
computer.open_url
computer.press_key
computer.get_selection
computer.set_text
computer.clipboard
```

## Filesystem

```text
filesystem.search
filesystem.read
filesystem.write
filesystem.move
filesystem.copy
filesystem.delete
filesystem.reveal
```

## Shell

```text
shell.run
shell.status
shell.cancel
```

## Browser

```text
browser.navigate
browser.snapshot
browser.click
browser.fill
browser.select
browser.download
```

## Workspace

Existing Google Workspace capabilities move here.

---

# 14. Component 5: Permission Broker

This must sit **above every execution source**.

Do not allow each integration to invent its own user-safety model.

Introduce:

```text
PermissionBroker
```

Risk levels:

| Risk | Example | Default behavior |
|---|---|---|
| Observe | active app, current meeting | Automatic |
| Read | read local file, check calendar | Automatic/configurable |
| Modify | edit local file | Confirmation depending on scope |
| Write cloud | create Doc/event | Confirmation |
| Communicate | send email/message | Explicit confirmation |
| Destructive | delete file/event | Strong confirmation |
| Privileged | install software, sudo | Strong confirmation |

Qwen's frontend MCP implementation explicitly notes that MCP annotations are metadata rather than enforcement and that safety may need to be enforced at the capability boundary. 

Next Notes should go further:

> **No tool bypasses the Next Notes Permission Broker merely because it came from MCP.**

---

# 15. Permission scopes

Users should eventually be able to grant scoped policies.

Example:

```text
Allow Next Notes to:

✓ Read calendar without asking
✓ Search local files without asking
✓ Create Gmail drafts without asking

Ask before:

✓ Editing files
✓ Creating calendar events
✓ Uploading files

Always ask:

✓ Sending email
✓ Sending Slack messages
✓ Deleting anything
✓ Running privileged commands
```

Temporary scope:

```text
Allow once

Allow for this task

Allow for this meeting

Always allow this action
```

Never give a model an unrestricted “always allow everything” switch.

---

# 16. Component 6: Meeting Context Engine

The meeting agent should stop thinking solely in terms of:

```text
transcript → proposals
```

Instead create a continuously updated meeting state.

```text
MeetingContext

participants
topics
decisions
questions
commitments
deadlines
documentsMentioned
actionItems
unresolvedItems
```

Transcript chunks feed:

```text
Transcript
    ↓
Context Extractor
    ↓
MeetingContext
```

The realtime agent can then ask:

```text
meeting.current.actionItems
```

without rereading an hour-long transcript.

---

# 17. Two meeting-agent modes

## Passive mode

Next Notes observes and detects:

- decisions,
- promises,
- tasks,
- deadlines,
- questions,
- files mentioned,
- follow-ups.

Example:

```text
Sarah:
"Can you send the STEP file after the call?"
```

Next Notes stores:

```text
Candidate action

recipient: Sarah
action: share file
object: STEP file
confidence: high
```

It does not execute.

---

## Interactive mode

The user says:

> “Hey Next, do that now.”

Because the system knows the active meeting context, “that” resolves to the candidate action.

Then:

```text
find Sarah
     ↓
search STEP files
     ↓
determine latest version
     ↓
draft action
     ↓
permission
     ↓
execute
```

This is where Next Notes becomes meaningfully different from conventional meeting assistants.

---

# 18. Component 7: Google Workspace integration strategy

Do **not** replace the existing native Google Workspace implementation with Composio.

Use both.

Architecture:

```text
              Cloud Tool Router
                    │
          ┌─────────┴──────────┐
          │                    │
   Native Workspace      Composio MCP
          │                    │
 Google APIs / gws        Other apps
```

---

# 19. Native Google Workspace remains first-class

Keep:

```text
Gmail
Calendar
Drive
Docs
```

as native Next Notes tools.

Reasons:

- existing implementation already works,
- predictable schemas,
- direct permission control,
- easier local-first story,
- fewer dependencies,
- better auditing,
- better optimization for meetings.

Native tools should be preferred automatically where an equivalent capability exists.

Example:

```text
workspace.gmail.search
```

uses the native implementation rather than Composio.

---

# 20. Optional Composio MCP

Borrow Eveclaw's integration strategy.

Eveclaw connects to Composio through MCP, giving its agent a gateway to a much larger set of applications such as Gmail, Calendar, Notion, Slack, GitHub and Linear. 

Next Notes can expose:

```text
Settings
  └── Integrations

      Google Workspace
      ● Native
      Connected

      GitHub
      ○ Connect

      Slack
      ○ Connect

      Notion
      ○ Connect

      Linear
      ○ Connect

      More apps
      [Connect through Composio]
```

The user never needs to think about MCP during normal usage.

---

# 21. Tool-routing precedence

When an agent asks for a capability:

```text
Tool Router
```

resolves:

```text
1. Native tool available?
       ↓ yes
   use Native

2. User configured MCP?
       ↓ yes
   use configured MCP

3. Composio connected?
       ↓ yes
   use Composio

4. No capability
       ↓
   ask user to connect integration
```

Example:

```text
send Gmail
→ Native Google Workspace

create GitHub issue
→ Composio MCP

update Notion
→ Composio MCP
```

---

# 22. Normalize native and MCP tools

The model should not need to understand whether something is native or Composio.

Internally:

```text
Canonical Tool

cloud.github.create_issue
```

may resolve to:

```text
Composio:
GITHUB_CREATE_ISSUE
```

while:

```text
cloud.gmail.send
```

resolves to:

```text
NativeGoogleWorkspaceExecutor
```

This gives Next Notes one consistent:

- permission system,
- audit log,
- UI,
- tool result format,
- activity representation.

---

# 23. MCP support

Borrow Qwen Audio Agent's idea of supporting:

```text
stdio MCP
```

and:

```text
Streamable HTTP MCP
```

with explicit tool allowlists. 

Eventually:

```text
Settings
  └── Developer
      └── MCP Servers

          Filesystem       Connected
          GitHub           Connected
          ProductFlo       Connected
          Custom           +
```

This makes Next Notes extensible without requiring every capability to ship inside the Swift application.

---

# 24. Component 8: Computer Context

Next Notes should understand what the user is currently working on.

Create:

```text
ComputerContext
```

containing:

```text
activeApplication
activeWindow
selectedText
focusedUIElement
visibleDocument
currentURL
clipboard
recentApplications
workspace/project
```

Because Next Notes already requires macOS Accessibility access for several existing capabilities, it has a strong foundation for this layer.

---

# 25. Context references instead of prompt dumping

Do not continuously inject the full screen and meeting transcript into the model.

Use references.

Example:

```text
Context

meeting://current
window://active
selection://current
file://current
project://active
```

The agent asks for detailed information only when necessary.

This keeps:

- prompts smaller,
- private data exposure lower,
- latency lower,
- context more accurate.

---

# 26. Component 9: Computer Control

Create a native macOS tool executor.

```text
ComputerToolExecutor
```

Initial implementation should use:

- Accessibility APIs,
- `NSWorkspace`,
- `CGEvent`,
- clipboard APIs,
- existing AX harvesting infrastructure.

Do **not** begin with screenshot-only computer use.

Prefer structured native accessibility information whenever possible.

Example:

```text
computer.inspect_ui
```

might return:

```text
Window: Xcode

Button
  id: 12
  label: Run

TextField
  id: 18
  value: Search

Tab
  id: 22
  label: Issues
```

The model can then request:

```text
computer.click(12)
```

This is safer and cheaper than repeatedly interpreting screenshots.

Vision can be a fallback where AX information is insufficient.

---

# 27. Component 10: Shell execution

The local agent should eventually control the CLI.

But do not expose:

```text
execute arbitrary shell command
```

as an unrestricted realtime tool.

Instead:

```text
Realtime Agent
      ↓
Agent Task
      ↓
Shell Tool
      ↓
Permission Broker
```

Commands should report:

```text
command
workingDirectory
status
stdout
stderr
exitCode
startedAt
completedAt
```

And long-running commands should be cancellable.

---

# 28. Component 11: Agent Activity Stream

Borrow Qwen's normalization of backend activity.

The Island should be able to display:

```text
Thinking…
Searching…
Reading package.json…
Running tests…
Editing MeetingAgent.swift…
Waiting for permission…
Done
```

without exposing model chain-of-thought.

Qwen similarly projects backend events into generic activity rather than leaking internal reasoning. 

Create:

```text
AgentActivity

id
taskID

kind
    thinking
    searching
    reading
    writing
    executing
    waiting
    completed

title
detail
progress
```

---

# 29. Component 12: Audit Log

Anything the agent does should become inspectable.

```text
Agent History

10:43 AM
Read Calendar

10:44 AM
Searched ~/Projects/ProductFlo

10:44 AM
Found enclosure_v17.step

10:45 AM
Requested permission:
Upload enclosure_v17.step

10:45 AM
Approved by user

10:45 AM
Uploaded to Drive
```

This is essential once Next Notes can manipulate a computer.

---

# 30. Proposed source layout

```text
Sources/NextNotes/

Agent/
    RealtimeAgent.swift
    AgentSession.swift

    Tasks/
        AgentTask.swift
        AgentTaskManager.swift
        AgentTaskStore.swift

    Backend/
        AgentBackend.swift
        LocalAgentBackend.swift
        ACPAgentBackend.swift

    Tools/
        AgentTool.swift
        AgentToolRegistry.swift
        AgentToolExecutor.swift
        AgentToolResult.swift
        ToolRouter.swift

    Permissions/
        PermissionBroker.swift
        PermissionPolicy.swift
        PermissionRequest.swift

    Activity/
        AgentActivity.swift
        AgentActivityStore.swift

Activation/
    ActivationController.swift
    PushToTalkActivation.swift
    ShortcutActivation.swift

    WakeWord/
        WakeWordDetector.swift
        WakeWordModelManager.swift
        WakeWordConfiguration.swift
        WakeWordTrainer.swift

Context/
    ContextEngine.swift
    AgentContext.swift
    ComputerContext.swift

Meeting/
    MeetingContext.swift
    MeetingContextExtractor.swift
    MeetingIntentDetector.swift

Computer/
    ComputerToolExecutor.swift
    Accessibility/
    Applications/
    Keyboard/
    Pointer/

Shell/
    ShellExecutor.swift
    ShellProcess.swift

Integrations/
    GoogleWorkspace/
        NativeWorkspaceProvider.swift

    MCP/
        MCPClient.swift
        MCPServer.swift
        MCPToolProvider.swift

    Composio/
        ComposioProvider.swift
```

---

# 31. Implementation Roadmap

## Phase 0 — Refactor the existing agent foundation

Goal:

Decouple the current meeting agent from Google Workspace.

Replace:

```text
MeetingAgent
      ↓
WorkspaceTools
      ↓
WorkspaceToolRunner
```

with:

```text
MeetingAgent
      ↓
AgentToolRegistry
      ↓
ToolRouter
      ↓
ToolExecutor
```

Keep all current functionality working.

**Exit criteria:**

Existing Gmail, Calendar, Drive and Docs actions behave exactly as before through the new generic tool interface.

**Progress (2026-09-12)**

- **Status:** Done
- **Landed:** `AgentToolRegistry`, `ToolRouter` (native Gmail/Calendar first), `AgentToolExecutor`. Workspace tools keep short names (`search_email`) plus `workspace.*` aliases. `MeetingAgent` / `AgentService` go through the executor.
- **Verify:** `--selftest-tools` → `TOOLS_OK`
- **User still must do:** nothing for the refactor. Live GWS writes still need `gws` signed in (Settings ▸ Workspace).

---

# Phase 1 — Central Permission Broker

Move authorization out of individual tools.

Implement:

```text
AgentRisk

observe
read
modify
write
communicate
destructive
privileged
```

Every tool request passes through:

```text
PermissionBroker.authorize()
```

**Exit criteria:**

No mutating tool can execute without the broker.

**Progress (2026-09-12)**

- **Status:** Done
- **Landed:** `AgentRisk` (`observe`, `read`, `modify`, `write`, `send`, `destructive`, `privileged`). Unknown tools resolve to `.send`. `PermissionBroker.authorize()` sits above every executor. `.once` grants are in-memory only. Sends are held for confirmation under `.denyMutations`.
- **Verify:** `--selftest-tools` (a send without approval fails; observe can auto-run)
- **User still must do:** set standing read answers in Settings ▸ Agent ▸ Allow without asking. There is no switch that allows everything.

---

# Phase 2 — Persistent Realtime Agent

Introduce:

```text
RealtimeAgent
AgentSession
```

Support:

```text
voice → question → answer
voice → tool → result
```

without requiring a meeting.

The Island becomes the agent's persistent UI.

**Exit criteria:**

From any application:

> “What's on my calendar tomorrow?”

works through Next Notes.

**Progress (2026-09-13)**

- **Status:** Done for the reply path, harness pick, and duplex listen
- **Landed:** “what can you do” / help answers from a canned list. Every turn has a 25 s deadline. Wake / ⇧⌘ Space opens a **session**: energy VAD (900 ms silence) endpoints one turn; listening resumes. Done / idle (25 s) / goodbye ends the session. Dictation stays push-to-talk. `AgentHarnessRouter` picks Local vs ACP per request.
- **Verify:** `--selftest-realtime` fails if capabilities produce no text, if harness routing is wrong, or if a duplex turn still needs Done.
- **User still must do:** ⇧⌘ Space, speak, wait — do not press Done for each ask. Sign in `gws` for a real agenda. Qwen or Apple Intelligence for open-ended chat.

---

# Phase 3 — Wake phrase + shortcut

Borrow Qwen's local wake-detection architecture.

Implement:

- Voice Wake toggle
- configurable phrase
- configurable shortcut
- local keyword model
- wake sensitivity
- test workflow
- sleep/wake state
- no cloud wake-word audio

**Exit criteria:**

The user can configure:

> “Hey Next”

or another supported phrase and wake the agent while Next Notes is sleeping.

**Progress (2026-09-13)**

- **Status:** Done
- **Landed:** Settings ▸ Agent download of `sherpa-onnx-kws-zipformer-zh-en-3M-2025-12-20` (SHA `68447f4f…`, same archive as Qwen) plus the sherpa-onnx 1.13.8 C API dylib. `WakeWordAudioMonitor` listens on the **microphone** while sleeping. Phrase spotting on transcripts still runs for meetings. System audio never authorises. `--selftest-wake` is `WAKE_MODEL_MISSING` when files are absent, and `WAKE_OK` only after load + a real spot (`LIGHT_UP` on the bundled English test wav).
- **Verify:** `--selftest-wake` → `WAKE_LOADED` / `WAKE_SPOTTED` / `WAKE_OK`. Settings ▸ Agent ▸ Voice wake + Listen while sleeping. Say “Hey Next” with the app idle.
- **User still must do:** turn Voice wake on (it is off by default). Microphone grant. The model is already on this machine.

---

# Phase 4 — Meeting Context Engine

Replace periodic transcript-only reasoning with structured context extraction.

Detect:

- decisions,
- tasks,
- commitments,
- questions,
- deadlines,
- document references.

Establish the authority rule:

```text
system audio → context only
microphone → potential authority
```

**Exit criteria:**

During a meeting the user can ask:

> “Hey Next, what action items do I have so far?”

and receive an immediate answer from structured meeting context.

**Progress (2026-09-12)**

- **Status:** Done (heuristic extractor). Live meetings with an “Others” track remain In tree (unproven).
- **Landed:** `MeetingContext`, `MeetingContextExtractor`, `MeetingContextStore` (`context.json`). Authority rule: system audio = context only; microphone = potential authority. `TranscriptSegment.kind` + `includeInMeetingNotes`; agent commands stripped from `plainText`. New meeting fields use `decodeIfPresent`.
- **Verify:** `--selftest-meeting-context` → `MEETING_CONTEXT_OK`. `--selftest-realtime` answers an action-item question from structured context.
- **User still must do:** record a real meeting (mic + System Audio Recording). Ask on the **mic**: “Hey Next, what action items do I have so far?”

---

# Phase 5 — In-context meeting actions

Connect MeetingContext to AgentToolRegistry.

Example:

Other participant:

> “Send me the CAD file.”

Next Notes identifies the candidate action.

User:

> “Hey Next, do that after the meeting.”

Next Notes creates a pending task.

**Exit criteria:**

Meeting conversation can generate context-aware actions without treating other participants as authorized commanders.

**Progress (2026-09-12)**

- **Status:** Done (wiring). Live “do that after the meeting” is In tree (unproven) until a real meeting produces a candidate.
- **Landed:** System-track speech becomes a *candidate*, not a command. “do that” / “after the meeting” on the mic resolves the latest candidate and submits a pending task (`RealtimeAgent.answerDirectly`). Writes still wait for the broker.
- **Verify:** `--selftest-meeting-context` (`that did not resolve` / system audio did not become authority). `--selftest-realtime` for the question path.
- **User still must do:** run a meeting where someone asks for a file, then say on the **mic** “Hey Next, do that after the meeting.” Approve the task when it asks.

---

# Phase 6 — Agent Task Manager

Implement asynchronous work:

```text
submit
progress
cancel
permission
input
result
```

Borrow the conceptual lifecycle from Qwen Audio Agent.

The user can continue talking while tasks execute.

**Exit criteria:**

A 30-second agent operation no longer blocks the realtime conversation.

**Progress (2026-09-13)**

- **Status:** Done (local backend + per-request harness pick)
- **Landed:** `AgentTaskManager` (`submit` / progress / cancel / permission / input / result). `AgentHarnessRouter` chooses Local vs ACP **before** `submit`: explicit name in the utterance, else last successful coding harness in `agent-harness-history.json`, else session last-used, else Settings ▸ Agent. Calendar / mail / Drive / Docs / click / type stay local unless named. Island and sidebar show “Using Codex” / “Using local tools”.
- **Verify:** `--selftest-tasks` → `TASKS_OK`. `--selftest-realtime` fails if “use claude code to …” does not select Claude/ACP, if a calendar ask selects a coding harness, or if a second coding ask does not reuse history.
- **User still must do:** install a coding CLI for a live ACP run. `--selftest-acp` already speaks a real stdio session to a fixture.

---

# Phase 7 — Local computer tools

Add:

```text
computer.active_app
computer.inspect_ui
computer.open_app
computer.focus
computer.click
computer.press_key
computer.set_text
computer.selection
```

Reuse existing Accessibility infrastructure.

**Exit criteria:**

The user can say:

> “Hey Next, open Xcode.”

or:

> “Click Run.”

with permission-aware structured computer actions.

**Progress (2026-09-12)**

- **Status:** Done
- **Landed:** The same tools, plus `computer.type`. `RealtimeAgent` parses “click …”, “type …”, “open …”, “inspect” without a model. Clicks/types go through `PermissionBroker`; the island and Agent sidebar show Approve. Settings ▸ Agent ▸ “Click and type without asking” is the standing yes. `askModel` is now offered computer tools up to `.modify`. `--selftest-computer` inspects, clicks OK, and types hello on a window this process owns.
- **Verify:** `--selftest-computer` → `COMPUTER_OK: inspected, clicked OK, typed hello`. Then sidebar **Agent**: “type hello in the focused field” / “click the OK button”.
- **User still must do:** Accessibility grant. Approve the first click, or turn on the standing toggle.

---

# Phase 8 — Filesystem + Shell

Add filesystem operations.

Then controlled CLI execution.

Integrate them with TaskManager rather than the conversational loop.

**Exit criteria:**

> “Find the latest Next Notes build.”

and:

> “Run the tests in this project.”

work locally.

**Progress (2026-09-13)**

- **Status:** Done
- **Landed:** `filesystem.search` / read / write / trash (bounded). `shell.run` is cancellable zsh; privileged commands (`sudo`, and the like) are refused. Long jobs go through `AgentTaskManager`. `--selftest-fs` writes a temp file, searches and reads it, and fails if `sudo` runs.
- **Verify:** `--selftest-fs` → `FS_OK`. `--selftest-activity` projects “Searching…”.
- **User still must do:** try a real “find…” / “run the tests” from the Agent sidebar. Writes and shell still ask.

---

# Phase 9 — MCP

Implement:

```text
stdio
Streamable HTTP
```

support.

All discovered MCP tools pass through the canonical tool registry and Next Notes permission policy.

**Exit criteria:**

A user can connect an external MCP server without modifying the Next Notes source.

**Progress (2026-09-13)**

- **Status:** Done (handshake against a local stdio fixture)
- **Landed:** Persistent MCP session: `initialize` + session id, then `tools/list` / `tools/call` on the same process. HTTP carries `Mcp-Session-Id`. Allowlist is enforced. Annotations are metadata only — `PermissionBroker` still sits on every call. Settings ▸ Integrations adds a server by name + command or URL.
- **Verify:** `--selftest-mcp` → `MCP_OK: initialize, session, list and call hold`. Fails if initialize never completed.
- **User still must do:** add a real MCP server in Settings ▸ Integrations. No third-party server has been connected on this machine.

---

# Phase 10 — Composio

Add optional Composio MCP.

Keep Google Workspace native.

Architecture:

```text
Google
   ↓
Native

GitHub
Slack
Notion
Linear
etc.
   ↓
Composio MCP
```

**Exit criteria:**

Users can connect additional cloud applications through Settings without bloating the native application.

**Progress (2026-09-13)**

- **Status:** In tree (unproven) — **Blocked** on the user's Composio API key
- **Landed:** Settings ▸ Integrations ▸ More apps — toggle, API key, MCP URL, Save connection. Native GWS stays on the Workspace tab and wins when both exist (`ToolRouter`). Connecting uses the same MCP initialize/session path as Phase 9.
- **Verify:** Settings ▸ Integrations. `--selftest-mcp` checks the default Composio URL is present. A live Composio handshake is not faked.
- **User still must do:** a Composio API key. No key has been entered on this machine.

---

# Phase 11 — ACP backend agents

Implement `ACPAgentBackend`.

Allow users to choose installed agent backends.

Example:

```text
Settings
  └── Agent
      └── Execution

          Local Agent

          Coding Agent
          Claude Code ✓
          Codex
          Qwen Code
```

**Exit criteria:**

Voice can hand off sustained work to an external agent and receive progress, permission requests, and results.

**Progress (2026-09-13)**

- **Status:** Done (stdio session against a local fixture)
- **Landed:** `ACPSession` speaks initialize → session/new → session/prompt over stdio. `subscribe` forwards public `session/update` titles (thought chunks are dropped). `session/request_permission` is relayed. Qwen `BackendPort` methods: start, health, submit, status, cancel, permission/input, subscribe, close. `cli -p` is only the fallback when initialize fails, and the outcome says so. Harness routing unchanged (Phase 6).
- **Verify:** `--selftest-acp` → `ACP_OK`. Fails if a session id was never minted. `--selftest-realtime` still checks harness pick.
- **User still must do:** put Claude Code, Codex or Qwen Code on PATH for a live hand-off. No coding CLI is assumed on this machine.

---

# Phase 12 — Browser control

Implement local browser automation.

Prefer structured browser state where possible.

Borrow Eveclaw's useful conceptual flow:

```text
navigate
→ snapshot
→ element references
→ click/fill
→ snapshot
```

Eveclaw itself uses `@agent-browser/eve` with Chromium inside a Vercel sandbox, so that implementation should not become Next Notes' local browser layer.  

**Progress (2026-09-13)**

- **Status:** Done (honest stub + Eve loop)
- **Landed:** `browser.snapshot` / navigate / click / fill. An empty or non-browser tree reports `stub tree, 0 names` and invents no controls. Click/fill follow Eve’s loop: snapshot → act only on an id from that snapshot → snapshot. Not Eve’s Chromium sandbox.
- **Verify:** `--selftest-browser` → `BROWSER_OK`. `--selftest-computer` fails if a dead pid invents an OK button, or if the post-click snapshot is stub.
- **User still must do:** Accessibility grant; try a snapshot from the Agent sidebar while a browser is frontmost. Chrome/Cursor with accessibility off stay stub — that is the honest answer.

---

# 32. User Experience Target

Eventually this interaction should work:

### During a meeting

Sarah:

> “Could you send me the enclosure CAD after this?”

Next Notes silently records:

```text
Potential follow-up
Sarah → enclosure CAD
```

The user says:

> “Hey Next.”

Island expands.

> “Find the latest STEP version and send it to her.”

Next:

> “I found `Enclosure_v17.step`, modified today at 3:42 PM. Sarah's email from the meeting invite is sarah@example.com.”

Island:

```text
Send to Sarah?

Enclosure_v17.step
8.3 MB

[Approve] [Edit] [Dismiss]
```

User:

> “Approve.”

Next:

> “Sent.”

The meeting continues.

That is the interaction model the architecture should optimize for.

---

# 33. What we borrow versus build

| Capability | Qwen Audio Agent | Eveclaw | Next Notes |
|---|---|---|---|
| Full-duplex voice architecture | Borrow architecture | — | Native implementation |
| Wake-word architecture | Borrow | — | Improve with customizable phrase |
| Task manager | Borrow concepts | — | Native |
| Background agent execution | Borrow | — | Native |
| Backend abstraction | Borrow BackendPort concept | — | Swift `AgentBackend` |
| ACP | Borrow integration pattern | — | Implement |
| MCP | Borrow architecture | Uses MCP | Implement |
| Permission relay | Borrow | — | Stronger centralized broker |
| Native GWS | — | No | **Keep existing** |
| Composio | — | Borrow | Optional |
| Computer control | No direct solution | No local solution | **Build natively** |
| Meeting context | — | — | **Core Next Notes advantage** |
| Mic/system authority split | — | — | **Core Next Notes advantage** |

---

# 34. Product Positioning After This Architecture

Today:

> Local dictation + meeting notes + Google Workspace follow-ups.

Intermediate:

> Local voice agent for meetings and desktop workflows.

Long-term:

> **Talk to your computer and let agents do the work.**

The differentiating stack becomes:

```text
Voice
+
Meeting awareness
+
Computer context
+
Local execution
+
Cloud tools
+
Agent backends
```

The strongest differentiator is not simply that Next Notes can control a computer.

Other agents can control computers.

It is that Next Notes can understand:

> **what you are doing, what meeting you are in, what people just asked for, what application you are working in, and what you explicitly told it to do**

and connect those contexts to action without making every conversation an agent command.

That should be the architectural north star.