# IM-17 — design: the ask, the assertion, the count

**Written 2026-09-26.** `03-PHASE-2-P1-SLICE.md` §7 is the task. This file is its design, and §7 now
points here. Read this before implementing IM-17; the two questions §7 left open are answered in §1
and §2 below, with the reasoning attached rather than the answer alone.

**Nothing here has been built and nothing has been run.** No `make build`, no self-test, no
install. Two other workstreams are building this tree; this file is prose and code fences, and
`git status` outside `roadmap/` is untouched. Treat the tree as possibly broken.

## 0. What already exists, and is not to be replaced

| Piece | Where | What it already decides |
|---|---|---|
| the permission row and `PermissionRow` | `UI/Onboarding/PermissionsChecklist.swift` | a row's shape, and that `isGranted == nil` means *the system offers no way to ask* |
| the Full Disk Access section and `MessagesAccessVerdict` | `UI/Settings/MessagesAccessSection.swift` | the `○`/`✓` and the four sentences, as a **pure** value a test can hold |
| the grant surface, `fdaAddAdvice`, `fdaRepairAdvice` | `Support/Permissions.swift:117, 240, 250` | that the only honest answer is a real read of a real row, and the two advice strings |
| the sheet chrome | `UI/Onboarding/OnboardingChrome.swift:10` (`OnboardingScreen`), `DS.Onboarding` | the window, the column, the card, the pill, `poll`, `staleGrantHint` |
| the grant-row pattern with a live answer | `UI/Onboarding/OnboardingSteps.swift:103` (`OnboardingDictationStep`) | a screen that asks for a grant macOS cannot prompt for, polls, and escalates its own advice after a press |
| the usage log and its sanitiser | `Support/Usage/UsageLog.swift:115` (`UsageLog.sanitise`) | what may be in `errorMessage`, and that the log never leaves the Mac |
| the one local record of a pass | `Support/Usage/UsageRecord.swift` | `UsageFeature`, `UsageProvider`, `UsageErrorClass`, and the correlation ids |
| the settings-pane width gate | `UI/Settings/AgentSettingsTab.swift:28` (`MessagesAccessSection()`), `--selftest-settings` | that a section is one line in the tab, and that 12 panes are hosted at the floor today |

`AgentCapabilityManifest` is **planned** (AO `P1-03`) and is not used anywhere below. `TaskBridge`,
`TaskDelivery` and `OutputScheduler` are planned too, so nothing here depends on them.

---

## 1. Decision 1 — when Full Disk Access is asked

### 1.1 The rule

**Not in first-run onboarding, and not in the Settings pane on its own: in a sheet, presented from
the switch, at the moment the feature is switched on.**

`STATUS.md` records the reason it is not in onboarding — *a first-run person is asked for nothing
they have not yet asked to use* — and `AGENTS.md`'s is the same: safety lives at the irreversible
boundary, not in the path of everything. Full Disk Access is a grant with no prompt, no preflight
and no query API; the only honest answer is a real read, which is `MessagesDatabaseHealth.probe()`.
An ask that has to be *explained* before it can be *checked* cannot live in a pane with six other
things in it. It gets a screen of its own.

Three consequences, and they are the design:

1. **The switch is not the consent.** Turning it on opens the sheet. **The switch only becomes on
   when the sheet reaches `connected`.** If the sheet is dismissed at any point, the switch goes
   back off and one line appears under it (§1.4). A feature switch that reads *on* with nothing
   behind it is the state that teaches people to distrust switches.
2. **A person who already has the grant is not asked for it again.** Step 2 is skipped and the
   sheet collapses to one screen. Returning to a feature you set up last week is one `Continue`,
   not a re-walk — this is the difference between a setup and a toll.
3. **Nothing re-asks, ever, in this session.** No countdown, no "are you sure", no second chance
   at the end of the window. A person who says no gets the sentence in §1.4 and their Settings
   back.

`03-PHASE-2-P1-SLICE.md` §7 described a **five-screen wizard**: screen 1 (*Use Next from iMessage*)
is folded into the switch's own label and the sheet's subhead, so the sheet is **four**. Chosen,
and the reason: a person who has just flipped a switch labelled *Ask me from Messages* has already
been told what the feature is. What they do not know — and what the sheet exists to answer — is
**what it can see**. A screen restating the feature's name is the screen that gets skipped, and a
skipped screen is where a consent goes to be ignored. Screens 2–5 survive unchanged and keep
IM-03's verbatim copy.

### 1.2 The screens, verbatim

**Where it starts — the switch row in Settings → Agent.**

| | |
|---|---|
| Toggle | **Ask me from Messages** |
| Detail | **Message yourself from your phone and your assistant answers you there. It needs one thing from macOS first.** |
| Under the switch, after a refusal | the refusal sentence, §1.4 |
| Below, when on | **Stop** — one button, §1.3 |

**The sheet's title bar:** *Set up Messages*.

**Step 1 — what it can see.**

> ### One conversation, and only the words you sent
> Next Notes reads the conversation you have with yourself. It uses the words you sent it, and nothing else.
>
> | | |
> |---|---|
> | **The conversation** | The one where both sides are you. No other conversation is read. |
> | **What is used** | Just the words you sent. Anything that arrived with a message — a picture, a link, an offer from someone else — is left alone. |
> | **Who answers** | The same assistant you already talk to by voice. |
>
> `[ Continue ]`

The third row is about *who*, not *where*. That is deliberate and it is a decision, not an
omission — see §2.7.

**Step 2 — the grant.** This screen contains no new copy. It renders `MessagesAccessVerdict`
exactly as `MessagesAccessSection` renders it: same glyph, same two words, same `purpose`, same
`advice(hasPressed:)`.

> ### One switch in macOS
> macOS will only open your messages for an app you have chosen, and this is where you choose Next Notes.
>
> | | |
> |---|---|
> | **Full Disk Access** | *IM-03's `purpose`, verbatim*<br>*○ Not on yet*<br>*Next Notes isn't in that list yet. Press the + button below the list, choose Applications, then click Next Notes.* |
>
> `[ Open Full Disk Access settings… ]`  `[ Not now ]`

After a press the button becomes `[ Check again… ]` — the same second-press relabel
`PermissionRow.actionTitle` already does at `PermissionsChecklist.swift:111` — and the advice line
becomes `Permissions.fdaRepairAdvice`, on the same `DS.Onboarding.staleGrantHint` interval
`OnboardingDictationStep` uses for Accessibility. **`○` → `✓` needs no click**: a `.readable`
verdict moves to step 3 by itself, which is the rule the dictation screen already established at
`OnboardingSteps.swift:227`. The orb beside the button while checking is `.searching`, the same one
`MessagesAccessSection.swift:69` uses, for the same reason.

**Step 3 — say hello.**

> ### Say hello from your phone
> Open Messages on your phone, start a conversation with yourself, and send: Hi Next
>
> ◦ *Waiting for your message…*
>
> `[ Send test message ]`  `[ I'll do this later ]`

`.listening` is the right orb: one channel, live, being listened to, and the watcher really is
running. A `[ Send test message ]` that is **disabled** until a command has actually arrived is on
this screen, not on step 4 — the phase file put it on step 4 and it reads as a reward.

**Step 4 — connected.** Reached only after the pairing is observed (IM-07) *and* the confirmation
send is observed (IM-10). Never on a timer, never on "the chat looks right".

> ### ✓ Connected
> **<name> is ready. Ask me anything from here.**
>
> `[ Done ]`

The name is `AgentIdentityStore.shared.name`, interpolated. `--selftest-persona` fails a spelled-out
one and `--selftest-imessage-consent` case 10 holds the same line here.

**Two words that stay, and why.** *Full Disk Access* is the system's own name for the switch the
person has to find, and the app already uses it in two shipped strings. It is used here for the
switch and for nothing else; *macOS* names the OS, and *Messages* names the app the person is
already looking at. Every other noun in these screens is a thing, not a mechanism.

### 1.3 The state machine

One pure value, and the view holds no state of its own. This is the shape
`OnboardingDictationStep.microphoneState` already uses, and the reason is IM-04a's: a `@State`
inside a view renders the right glyph and cannot be held by a self-test.

```swift
enum IMessageConsentState: Equatable, Sendable {
    case off
    case explaining
    case askingForFullDiskAccess(hasOpenedPane: Bool)
    case waitingForTheMessage
    case confirming
    case connected
    case declined(reason: IMessageDeclineReason)
}

enum IMessageDeclineReason: String, Sendable {
    case notNow          // "Not now" on step 2
    case later           // "I'll do this later" on step 3
    case dismissed       // ✕, Escape, or the window closed
}
```

| From | Event | To | Note |
|---|---|---|---|
| `off` | switch on | `explaining` | **local act only** — see below |
| `explaining` | Continue | `askingForFullDiskAccess(hasOpenedPane: false)` | |
| `askingForFullDiskAccess` | Open settings… | same, `hasOpenedPane: true` | advice line escalates |
| `askingForFullDiskAccess` | verdict becomes `.readable` | `waitingForTheMessage` | **no click** |
| `askingForFullDiskAccess` | verdict is `.granted` on entry | `waitingForTheMessage` | the returning person's skip |
| `askingForFullDiskAccess` | Not now | `declined(.notNow)` → `off` | refusal line |
| `waitingForTheMessage` | a command arrives | `confirming` | |
| `confirming` | the confirmation send is verified | `connected` | switch becomes on here |
| `confirming` | verification times out | `waitingForTheMessage` | the button re-enables; the wait continues |
| `waitingForTheMessage` | I'll do this later | `declined(.later)` → `off` | refusal line |
| any | ✕ / Escape / window close | `declined(.dismissed)` → `off` | refusal line |
| `declined(…)` | switch on, **any time later** | `explaining` | from the beginning, same copy, no variant |
| `connected` | switch off, or **Stop** | `off` | **immediate** |

Two of those rows are load-bearing.

**`off → explaining` is a local act, and the refusal is a value.** The transition function takes an
`ActionOriginContext` beside the event, and any event whose origin is `.iMessage` returns
`nil` — refused, not ignored. This is IM-12's "a remote turn must not widen its own authority"
applied to consent itself, and it is the case §2.5's *a second paired chat cannot be added without
a local act* generalises to: **no transition in this graph can be driven from the phone.** It
covers turning the feature on, turning it off, re-pairing, and un-suspending, and it is the reason
the graph takes an origin at all.

**`connected → off` is immediate — no confirmation, no drain, no countdown.** The asymmetry with
IM-12's `stop remote access` is IM-12's rule and not a new one, and it is the right way round:
turning the feature *off* is the safe direction and the person is the one who asked for it, while
turning it back on is the act that needs deliberating. So `Stop` flips the switch on the spot and
the reading stops; the next `on` goes through the sheet again, which is what "re-enabling needs
local confirmation" means when the confirmation *is* the local act. A dialog here would be a second
confirmation on a path where the person has already decided.

### 1.4 The refusal, verbatim

Saying no is a first-class outcome with a sentence, because that is what a person does when they
do not understand the ask. One sentence, one string, shown under the switch in the pane and at the
bottom of the sheet, so it is read in the place the person is standing:

> **That's fine. Dictation, meetings and your assistant all keep working — only talking to me from
> your phone is off.**

It names what still works, names what does not, and blames nobody. The button that produces it is
**`[ Not now ]`**, not "Turn it off" — the person never turned it on, the switch is still off, and
a button labelled with a consequence that has not happened is a small lie. (Apple's own dialog
says *Not Now* for the same reason.)

On step 2 the refusal sentence is followed by `Permissions.fdaAddAdvice`, because there is a next
click to offer and the person is standing in front of the pane. On step 3 there is nothing to add:
the switch is in front of them.

### 1.5 Said no, then switched it on later

The sheet opens at step 1, with the same headline, the same three rows and the same button. **No
shortened copy, no "you've already said no" variant, no remembered refusal, and no second chance
later in the session.** A refusal is recorded as a **count** in one usage row (§3.2) and changes
nothing else — there is no suppression timer, because a cooldown on a consent is a penalty for
saying no, and the whole point of §1.1's third consequence is that saying no is cheap.

If the grant is already on, the sheet is one screen and `Continue` is the default button. That is
not a second confirmation; it is the same screen with two rows fewer.

### 1.6 What the sheet must not contain

- **No second `isGranted`.** The `○`/`✓` is `MessagesAccessVerdict`, from the probe, in all three
  places a person can see it (the Permissions checklist row, the Settings section, the sheet).
  Three places, one string, one verdict — the `fdaAddAdvice` rule, generalised.
- **No "almost done" framing, no progress dots, no count of steps.** The dictation screen has
  none, and a progress indicator on a four-screen consent is an invitation to rush the one screen
  that matters.
- **No orb on step 1 or step 4.** `isAnimated` orbs run on a clock, and there is no work on those
  two screens. One animating orb per screen, and it is on steps 2 and 3 only.
- **No `sleep`, no debounce, no second press to be believed.** The poll is `DS.Onboarding.poll`
  and the activation is `NSApplication.didBecomeActiveNotification`, which is what
  `OnboardingDictationStep.watch()` already does. A person on a second display never "comes back",
  so the poll is not optional and the notification is not sufficient.

---

## 2. Decision 2 — the privacy assertion

### 2.1 The claim, exactly

> **Next Notes reads one conversation: the one you have with yourself. It uses the words you sent
> it, and nothing else — not the pictures, links or offers that come with them.**

Two claims, not one, and they have two different enforcements:

| | Claim | Enforced at | Pinned by |
|---|---|---|---|
| **A** | only the paired chat is ever read | the query seam, `IMessageBridge.messages(after:)` | `--selftest-imessage-privacy` case 1 |
| **B** | of what is read, only the sender's own words are ever used | **the decoder's return type** | cases 3, 4, 5 |

Claim A is the phase file's existing assertion, restated. **Claim B is new, and it exists because
of the 2026-09-26 measurement.**

### 2.2 What the measurement forbids

`TYPEDSTREAM-NOTES.md` §"The stream is an attribute graph, not a string" records, inside one real
`attributedBody` from this Mac: `NSMutableString`, `__kIMMessagePartAttributeName`,
`__kIMDataDetectedResult`, `__kIMLinkAttributeName`, `__kIMLinkPreviewAttributeName`, a
`__kIMDataDetectedLinkAttributeName` **URL**, a `com.apple.*` **bundle id**, and **a third party's
promotional payload carried as its own nested object with a nested string and a date range.**

So a row in a Messages thread is not a sentence. It is a sentence plus a link preview plus a list
of entities Apple detected plus, sometimes, somebody else's marketing with an expiry date. The
phase file's privacy section said the process *could* read every conversation; this measurement
says something sharper and closer to home:

> **A message you did not personally write can arrive in the paired conversation, and when one
> does, its row carries another party's payload.**

This is not exotic. **A Messages conversation with yourself is a thread addressed to your own
phone number**, so anything sent to that number lands in it — and a thread's rows are attributed
to whoever sent them, not to whoever the thread is with. IM-01 measured the same consequence from
the other side: a self-message arrives as **two** rows with opposite `is_from_me`. Nothing about
"the conversation where both sides are you" implies "every row in it was written by you".

Therefore the forbidden set is not "message bodies". It is: **a link preview's URL, a detected
entity, a bundle identifier, an expiry date, and any string inside a nested object the sender did
not type** — and none of it may reach a model, the knowledge index, memory, `usage.jsonl`, a log
line, a notification, a problem banner, or `--imessage-report`.

### 2.3 The enforcement point

> **The enforcement point is `MessagesDecoder.decode(_:)`'s return value — `MessageBody` — and the
> guarantee is structural: the type has exactly one string in it, and it is the one the sender
> typed.**

The decoder walks the streamer's object graph to the top-level `NSMutableString`, returns that one
string, and returns a refusal for everything else. It has never collected the attribute graph into
a bag, and **this task does not add one.** `IMessageEnvelope` (`:96`) is `Equatable, Sendable`,
**not `Codable`**, and has one `String?` — so a new field is cheap, but a *bag* is not proposed
anywhere.

Why this point and not another — five candidates, each rejected on evidence:

| Candidate | Why not |
|---|---|
| **the memory gate** (`AgentSession.recordUser(_:source:)`) | downstream of the bytes. By the time a gate runs, the URL and the third party's offer are already inside the process and inside a model prompt. A gate cannot un-send. |
| **the query seam** | a row is a `Data` blob. The application layer cannot tell the sender's string from the metadata without walking the graph, and the walk *is* the decoder's job. A second walk is a second parser and a second thing to get wrong. |
| **a scrubber on the way out** | a scrubber is a list of what somebody thought of. The measured graph held eight named attributes plus a nested object whose shape is unknown, and a macOS update adds a ninth. A denylist of names is a bet on the current release. |
| **`UsageLog.sanitise`** | it strips quoted content, addresses, URLs, paths and digit runs. **A third party's offer is none of those — it is prose, and it survives every rule in the function.** See §3.3. |
| **`AgentCapabilityManifest`** | it is AO's tool-authority answer, `P1-03`, `todo`, and it answers *which tool*, not *which bytes*. Nothing here may assume it exists. |

One sentence for why it is this one: **it is the only place in the app where the blob exists as
bytes, and it is upstream of the classifier, the adapter, the memory gate, the index, the model and
the usage log — so one narrow return type there is upstream of every consumer, where each of the
other points is a separate place to remember.**

The one thing this task *does* add to the decoder is a number, and it is the thing that makes the
assertion answerable against real bytes rather than synthetic ones:

```swift
// On IMessageEnvelope. One Int, never a String, never a list of names.
var discardedAttributeCount: Int
```

How many named attributes the walk passed over and did not read. It is not an allowlist of names —
a name would be exactly the bet the structural argument avoids. It is a *volume*, so a macOS
update that starts attaching twenty attributes per message is visible in `--imessage-report` and
nowhere else.

### 2.4 The testable shape

`--selftest-imessage-privacy`, **CORE**, `IMessagePrivacySelfTest.swift`. Case 3 is written so that
**adding a field which carries the third party's text makes it fail**, with no edit to the test:

```swift
// Case 3. Decode the real, sanitised body. The assertion is over the *whole* value, so a
// new field carrying the promotional payload is caught without anyone extending this.
XCTAssertEqual(envelope.text, "Hi Next")
XCTAssertFalse(String(describing: envelope).contains(promoURL))
XCTAssertFalse(String(describing: envelope).contains(thirdPartyOffer))
XCTAssertEqual(envelope.discardedAttributeCount, discardedInTheFixture)
```

| # | Case | Reddens when |
|---|---|---|
| 1 | query with a **non-paired** chat GUID → the result is empty | the guard is bypassable |
| 2 | **a remote origin** cannot drive any consent transition, cannot re-pair, cannot un-suspend | §1.3's origin check is dropped |
| 3 | the **real** body decodes to the sender's sentence and the promo URL and the offer appear in **no** field | any field carries them |
| 4 | **the consequence**: a turn built from a body carrying a foreign nested object writes **no** `MemoryEntry`, **no** knowledge chunk, and the model prompt contains the sender's sentence and none of the rest — asserted for a **local** and a **cloud** agent configuration | memory or a prompt is polluted |
| 5 | the real promo string fed through `IMessageUsage`'s row builder is absent from the encoded row | `errorMessage` is a free string (§3.3) |
| 6 | a **non-user row in the paired chat** is not `.user`, produces no memory, and produces no turn | the classifier trusts the chat |

Case 4 is the roadmap's own rule — *assert a negative over a consequence, not a positive over a
mechanism* — and case 6 is §2.5.

**Case 3 has a precondition and it is a hard one.** The 202-byte and 1140-byte bodies were
deliberately **not committed**: the real one carries a live promo URL and a third party's offer, so
it lives at `~/Library/Caches/NextNotesBuild/imessage/self-flow-case.sh`
(`TYPEDSTREAM-NOTES.md`, *Not committed, deliberately*). IM-17c's first commit is therefore a
**sanitised** 14th corpus case at `Tests/Fixtures/chatdb/cases/self-flow-real.REDACTED` — the
sender's sentence kept verbatim, the URL and the offer replaced with `REDACTED-*` sentinels, and
**the fixture's own expected-sentinel file listing them**, so the sanitisation is itself checkable.
Until that case exists, the flag prints

```
IMESSAGE_PRIVACY_ABSENT: the sanitised real body is not in Tests/Fixtures/chatdb
```

and **never `IMESSAGE_PRIVACY_OK`**. Not a skip, not a reduced denominator, not OK. IM-05's five
blocked assertions are printed as `IMESSAGE_DECODE_BLOCKED:` and deliberately excluded from its 22
for exactly this reason; the difference is that a *whole claim* is blocked here rather than five
cases of one, so `_ABSENT` is the honest marker and the flag is red until the fixture exists.

### 2.5 What this says to IM-08 (the classifier)

**Being in the paired chat is necessary and not sufficient for `.user`.** A row is `.user` only if
it was sent by this user. A row in the paired chat that somebody else sent — which §2.2 shows is
ordinary — is `.otherParticipant`, and `IMessageDirection.otherParticipant` already exists in
`00-README` §13's glossary. Two consequences for IM-08:

1. **The glossary is right and §11's sentence is wrong.** `00-README` §11 says *"everything else
   is a user command"*. That is the sentence to correct: it is true of a chat where the only
   participants are you, and this roadmap's chat is addressed to your phone number, which is not
   that. The glossary's three directions are the correct vocabulary and IM-08 should keep them.
2. **How direction is established is IM-08's decision, not this task's.** The ledger match decides
   *is this our echo*; direction decides *is this the user*. IM-01's answer (a self-message is two
   rows with opposite `is_from_me`) means `is_from_me` alone decides neither. IM-08 picks the rule
   from IM-01's evidence; **this task only asserts the outcome**, as case 6.

Case 6 is red until IM-08 lands and that is correct: `--selftest-imessage-privacy` is CORE and a
CORE gate is allowed to be red on a dependency, not allowed to be green by skipping the case.

### 2.6 The two other things that may not carry a remote turn onward

- **Not into `usage.jsonl`** — §3.2 and §3.3.
- **Not into the knowledge index.** `00-README` §5 already forbids a Messages knowledge index, and
  `Chunker.notes` skips the Related-context brief for the same reason this task exists: a fact
  that a promo payload asserted must not become a decision. Case 4 asserts it.

### 2.7 The locality claim, and where it is *not* restated

`MessagesAccessVerdict.purpose` — IM-03's verbatim sentence, which this task must not contradict —
ends *"Messages are processed on this Mac."* **That is a whole-app claim, and a remote turn's
locality is not this sheet's decision:** the turn goes to whichever provider the assistant's model
role resolves to, and that role may be a cloud model. So:

- Step 1's third row is **"Who answers"**, not "Where it runs". The sheet does not restate a
  locality claim it is not in a position to make.
- The locality sentence appears **once**, inside `purpose`, where IM-03 put it.
- **If the assistant's model role is a cloud provider, the consent that covers a remote turn
  leaving the Mac is the existing model-role consent, and this sheet does not re-ask for it.**
  A person who has already chosen a cloud model has already answered that question, in the place
  that asks it. Asking again in a second place is how a person stops reading.

This is recorded rather than fixed, because the alternative — the iMessage sheet asking about the
model — is a worse design and a bigger one, and it is not IM-17's to decide.

---

## 3. Observability

### 3.1 What a person is told, and where

| Event | Where | What |
|---|---|---|
| feature off | Settings → Agent → *Ask me from Messages* | the switch, the detail line, and `MessagesAccessSection` underneath |
| refused | under the switch, and at the foot of the sheet | the refusal sentence, §1.4 |
| a remote turn is **refused** by policy (IM-12's bands) | the island's proposal card, in the agent's own words | what was refused and what would be allowed instead. **The remote side already gets the honest refusal as the reply text**; there is no separate local notification, because a person who asked by phone does not need a second channel to tell them |
| a message **cannot be read** | the canary, §4 | |
| something is wrong with the connection | an island card, using `AgentActivityProjector`'s existing shapes | see §3.4 |
| detail, ever | `--imessage-report`, by hand | §3.5 |

**There is no local notification for a refused turn and none for a loop suppression.** Both are
normal operation, both have a natural home (the conversation, and the island), and a notification
for either is the app shouting at a person who is not in front of it.

### 3.2 The metrics rows, and every field they may carry

`usage.jsonl` is the one local record, it never leaves the Mac, and no row may hold a prompt, a
reply, a transcript, a dictated text, a tool argument, a file name, an address, a subject or a URL.
**Two new `UsageFeature` cases, not one and not eleven:**

```swift
case agentIMessage = "agent.imessage"   // a remote turn's model pass
case imessageEvent   = "imessage.event" // an iMessage transport event that ran no model
```

* **`agent.imessage`** is the pass row for a remote turn, and it is what the phase file's "jobs
  started from iMessage" wants. `provider`, `modelID` and `locality` are the real ones; the
  transport-specific facts ride in `counts`. A remote turn is neither `agent.typed` nor
  `agent.voice`, and putting it in either is a lie a reader can act on.
* **`imessage.event`** is the engine half of "which model **or engine** ran each pass"
  (`AGENTS.md`'s own phrasing). `UsageProvider.rules` already exists for a deterministic
  non-model path, so `provider` is `rules`, `modelID` is `none`, and `pass` is `inbound`,
  `outbound` or `consent`. `totalMs` is the event's own duration; there is no model and no token
  count, so every token field stays `nil`.

**`counts` is a closed vocabulary**, an enum rather than strings, so a typo is a compile error and
a new fact needs a new case on purpose:

| `pass` | permitted `counts` keys |
|---|---|
| `inbound` | `detected` · `accepted` · `refused` · `unreadable` · `notText` · `noBody` · `notPaired` · `echoMatched` · `loopSuppressed` · `discardedAttributes` |
| `outbound` | `sent` · `sendVerified` · `sendUnverified` · `sendingSuppressed` · `approvalGranted` · `approvalDenied` · `localConfirmationRequired` |
| `consent` | `granted` · `declined` · `dismissed` |

`stages` carries only durations, named from a second closed set: `syncToAgent` (row detected → the
agent was handed the turn), `dispatchToVerify` (Apple Event sent → the row appeared),
`verifyToReceipt` (row appeared → `ActionReceipt`). Those are the three numbers the phase file
means by "send verification latency" and "sync-to-agent latency", and naming them is the whole of
that line.

`turnID`, `conversationID` and `workID` are permitted: they are ids **this app generated**, they
are how a person in a terminal joins a row to a job, and they are the existing correlation
vocabulary. **`chatGUID` and `messageGUID` are not permitted, in any row, ever.** They are Apple's
identifiers for the user's conversations, `iMessage;-;+1…` contains the user's own number, and
`UsageLog.sanitise` would not save it — it only strips digit runs inside `errorMessage`, and a GUID
is not an error message. **App-generated ids yes, Apple's ids no** is the whole rule.

Also forbidden, with the reason, because each is a plausible-looking "harmless" number:

- **a character count of the sender's text.** The blob's size in bytes is about the *format* and is
  worth having; the length of somebody's sentence is the smallest possible piece of their message
  and buys a fingerprint.
- **a text hash.** IM-08 wants one to match the ledger, and the ledger is `imessage-outbound.sqlite`
  on this Mac. A hash is a stable identifier for a private sentence; it does not belong in a
  rotating log that is read by a report.
- **an attachment file name.** `sanitise` would not catch it, because `report.pdf` is not a path.

### 3.3 `errorMessage` is not a free string here

`UsageLog.sanitise` (`UsageLog.swift:115`) strips quoted content, addresses, URLs, paths, Windows
paths, runs of six or more digits, collapses whitespace and truncates at 160 characters. **A third
party's promotional offer survives all of it.** It is not quoted, it is not an address, it is not a
URL, it is not a path and it has no six-digit run. `sanitise` is excellent at *identifiers* and blind
to *prose*, and the content most likely to appear in this feature's failures is prose.

So: **`IMessageUsage` builds rows through one function whose only text parameter is a
`MessageDecodeFailure` case name and an `UsageErrorClass`, never a `String`.** `errorMessage` is
absent on every iMessage row; the reason is `errorClass` (`.parse` for an undecodable body, which
is exactly what `UsageErrorClass.parse` is for) and, when a human needs more, the decode-failure
case printed in `--imessage-report` — never `error.localizedDescription`, never SQLite's wording.
Enforcement is at construction, because at sanitisation it is already too late. Case 5 of
`--selftest-imessage-privacy` is the proof, and it is the one case in this design that must be
written with the *real* string in hand.

### 3.4 The consumer pane

`AgentActivityProjector` is a privacy seam: `isPublic(_:)` decides what may be rendered, and a raw
tool id appears nowhere. **The answer for iMessage is `iMessage · Connected` and
`Last request · 2 min ago`, and nothing else** — the phase file already says this and it is
correct. `IMessageStatusRow.swift` is a new file; the projector is not edited. Everything past those
two strings is behind `--imessage-report`, for the same reason AO puts job detail behind
`--jobs-report`.

### 3.5 `--imessage-report`

`IMessageReport.swift`, `--imessage-report [--imessage-days N] [--imessage-chat <guid>]`, ending
`IMESSAGE_REPORT_OK …` or `IMESSAGE_REPORT_EMPTY`. **Not a `--selftest-*` flag**: the harness swaps
in a temp store, so under it this reports a green answer about a question nobody asked — the trap
`--notes-context-live` documents, and `--imessage-report` is the same case twice over because it
reads `chat.db` as well.

It reads the real `imessage-outbound.sqlite` and the real `chat.db` and prints: bridge state ·
whether the database is readable · watcher state · **the paired chat, as `paired chat` and never
as a GUID** · watermark · counts by `IMessageCount` over the window · `discardedAttributes` total
and its per-window maximum · sync-to-agent p50/p90 · dispatch-to-verify p90 · the circuit breaker's
state · the remote policy version · the resolved model role and its locality · and the canary's
inputs from §4.

`--imessage-chat` **accepts** a GUID so a person can scope the report, and **never prints one
back** — the `--selftest-gws --live-mail` precedent is exact: this line lands in a log file, so it
carries counts, states and durations and nothing else.

---

## 4. The canary

`TYPEDSTREAM-NOTES.md` and the phase file both say a macOS update can make every inbound message
undecodable and *"the only signal is a count of undecodable messages."* **A count is a metric, and
a metric is not observability for a person.** The three things the phase file does not say are the
threshold, the destination, and the sentence.

### 4.1 What counts, and what does not

Only `MessageDecodeFailure` cases that mean *the format changed*:

| Case | Counts? | Why |
|---|---|---|
| `unsupportedStreamVersion` | **yes** | macOS wrote a shape the gate does not carry |
| `notATypedStream` | **yes** | the header moved |
| `structureUnreadable` | **yes** | the graph inside changed |
| `truncated` | no | our own bound, not a format change |
| `tooLarge` | no | our own bound |
| `.notText(bundleID:)` | no | **a photo, a tapback or an app payload is a successful classification.** Counting it fires the canary on ordinary use — IM-05's blocked case 4 is the effect bubble, which happens every time somebody reacts to a message |
| `.absent` | no | a row with no body column is an SMS. Ordinary |
| a body with no text column and a decoded stream | no | the ordinary path |

### 4.2 The rule

```swift
struct IMessageCanary: Equatable, Sendable {
    var windowHours = 24
    var seen = 0              // messages considered from the paired chat
    var unreadable = 0        // §4.1's three cases only
    var lastNotifiedAt: Date?

    var breakFraction = 0.20
    var breakMinimum = 10
    var notifyCooldownHours = 24

    var isBroken: Bool {
        unreadable >= breakMinimum && seen > 0
            && Double(unreadable) / Double(seen) >= breakFraction
    }
}
```

Both numbers are argued rather than guessed, and **both exist because of a specific false alarm**:

- **`breakMinimum = 10`** exists so the effect bubble and a handful of MMS rows can never trigger
  it. A canary that fires on ordinary use gets muted, and a muted canary is worse than none.
- **`breakFraction = 0.20`** exists so ten failures spread over a year do not. A decoder break is
  *nearly total*; a rate threshold is what tells the two apart.
- **`notifyCooldownHours = 24`** exists because a break produces one notification per message
  otherwise, which is a flood on the one day the person most needs to read it.

### 4.3 Where it is shown, and what a person is told

Two destinations, two audiences, because nobody opens Settings to find out a feature is dead.

**1 · A local notification, once per 24 hours, only while broken.**

> **Next Notes can't read your messages**
> Your messages are still in Messages and nothing was lost. This can happen after a macOS update —
> it isn't something you did, and the rest of Next Notes keeps working.

Every clause is load-bearing. *"Still in Messages and nothing was lost"* answers the fear the
notification raises before it is raised — and it is **true by construction**: the read path opens
read-only with `PRAGMA query_only` (`IMESSAGE_DB_OK: 26 cases`), and the send path is Apple Events,
so Next Notes has never written a message. *"This can happen after a macOS update"* is the honest
cause; *"it isn't something you did"* removes the blame; *"the rest keeps working"* bounds it.
**No button**, because there is no action that helps until the app is updated, and a button that
promises one is the "check this setting" lie the phase file forbids.

**2 · A row in the iMessage section, always present, so a person who missed it can find it.**

> **Messages it couldn't read** — `0`
> *(when non-zero)* Nothing was lost and nothing was deleted — Next Notes only reads. This usually
> follows a macOS update.

The count is over the same 24-hour window, so the row and the notification cannot disagree.

**3 · `--imessage-report`** carries the three `MessageDecodeFailure` case counts, the window, and
the versions, for whoever is fixing it.

**A silent breakage is the failure mode, and the reason this is §4 rather than a line in the
metrics list** is that the phase file's own words — *"the only signal is a count"* — describe a
signal nobody is looking at. A count plus a threshold plus a destination plus a sentence is
observability. A count alone is a field.

---

## 5. Tasks

Six, each small enough for one agent. **Ids are lettered subtasks** per `00-README` §8; each is its
own row in `STATUS.md`. `NextNotesApp.swift`, `Scripts/acceptance.sh` and `AGENTS.md` are
single-writer (`00-README` §7) — the registrations below are handed to the orchestrator, not edited
by the sub-agent.

The build lock (`~/Library/Caches/NextNotesBuild/work.lock`) is taken for build → install → one
test → release, and released in a `trap`. `make build` only. `make install OPEN=0`. Self-tests
through `Scripts/run-selftest.sh`, foreground, one at a time, never `&`.

### IM-17a — The consent decision, as a pure value

**Files** — `Sources/NextNotes/IMessage/Consent/IMessageConsentState.swift` (new),
`Sources/NextNotes/IMessage/Consent/IMessageConsentSelfTest.swift` (new,
`--selftest-imessage-consent`).

`IMessageConsentState`, `IMessageConsentEvent`, `IMessageConsentOrigin`, `IMessageDeclineReason`,
and `IMessageConsentCopy` — **every sentence in §1.2 and §1.4 as `static let` on one type**, so
the sheet, the pane and the test cannot drift. `transition(from:event:origin:)` returns
`IMessageConsentTransition?`, and `nil` is the refusal.

**Marker** `IMESSAGE_CONSENT_OK: <n> cases` / `IMESSAGE_CONSENT_FAILED: <case>: <reason>`.
**Tier** INTEGRATION.

**Red-first**, 11 cases: the four steps advance in order; `○ → ✓` needs no click; a `.granted`
verdict on entry skips step 2; **Not now / I'll do this later / dismissed** each reach `off` and
name their own reason; `declined → explaining` on a later switch-on, **with the same copy and no
variant**; a **remote origin** on any event returns `nil`; `connected → off` is immediate and takes
no event other than the two local ones; an unlisted event returns `nil` rather than defaulting;
and **no string on `IMessageConsentCopy` contains a literal agent name** (the persona case, here
too).

**Verify** `--selftest-imessage-consent`, `--selftest-persona`, `--selftest-ui-strings`,
`make acceptance TIER=integration`.

**Do not** — Do not put a `String` in the view. Do not add a fifth screen. Do not write a
`declinedAt` into any store; a refusal is a count in one usage row and nothing else (§1.5).

### IM-17b — The sheet, and the switch that opens it

**Files** — `UI/Settings/IMessageSettingsSection.swift` (new),
`UI/Onboarding/IMessageSetupSheet.swift` (new), `UI/Settings/AgentSettingsTab.swift` (**one line**,
the `IMessageSettingsSection()` at `:28` — five writers, name the owner first).

**Red-first** — the `--selftest-settings` pane case goes from `12 panes` to `13` and is red until
the section is registered, and a `--selftest-ui-strings` case asserts the two new files are inside
`UI/`. **No new flag**: the decision is held by IM-17a and the rendering by the two existing lints,
which is the split `MessagesAccessSection` already has. Mutation-check one thing by hand — write
`"chat.db"` into a `Text(` in the new section, confirm `UI_STRINGS_FAILED: …`, remove it.

The sheet is `OnboardingScreen` and nothing else is invented: no progress dots, no custom window,
`DS.Onboarding.*` for every number. It reuses `OnboardingDictationStep`'s poll and
`NSApplication.didBecomeActiveNotification`, `MessagesAccessSection`'s probe, `PermissionRow`'s
second-press relabel and the `hasOpenedPane` escalation.

**Do not** — Do not add a thirteenth `SettingsTab` case. Do not add a second `isGranted`. Do not
put a network fetch, a model load or a `sleep` on any of the four screens.

### IM-17c — The privacy assertion, and its fixture · **do this one first**

**Files** — `Tests/Fixtures/chatdb/cases/self-flow-real.REDACTED` (**new**, and the commit's
important half), `Tests/Fixtures/chatdb/README.md` and
`Tests/Fixtures/chatdb/make-chatdb-fixture.sh` if they enumerate cases,
`IMessage/Database/MessagesDecoder.swift` (**one field**, `discardedAttributeCount`, counted in the
existing walk — **the walk does not change**), `IMessage/Database/MessagesDecoderSelfTest.swift`
(**extended**, the discard case), `IMessage/IMessageSelfTest.swift` (new,
`--selftest-imessage-privacy`).

**Why first:** it is the only task in IM-17 that can be red against *real* bytes today, it needs no
grant and no PLANNED type, and every other task here exists to support the claim it makes. Cases
1–6 are §2.4's table. `--selftest-imessage-decode` gains the discard case and stays at one final
marker.

**Marker** `IMESSAGE_PRIVACY_OK: <n> cases` / `IMESSAGE_PRIVACY_FAILED: <what leaked>`.
`IMESSAGE_PRIVACY_ABSENT: the sanitised real body is not in Tests/Fixtures/chatdb` and **never OK**
(§2.4). **Tier CORE.**

**Verify** `--selftest-imessage-privacy`, `--selftest-imessage-decode`, `--selftest-imessage-db`,
`--selftest-memory`, `--selftest-store-isolation`, `make acceptance TIER=core`.

**Do not** — Do not commit the real blob or any fragment of the URL or the offer; the fixture is
`REDACTED-*` sentinels plus the sender's sentence. Do not add a bag, a dictionary or an array of
attribute names to `IMessageEnvelope`; the count is the only thing this task adds. Do not add a
second parser to strip anything — if case 3 is red, the walk is wrong, not the assertion. **Do not
make case 6 pass by skipping it**; red on IM-08 is the correct state.

### IM-17d — The metrics rows

**Files** — `Support/Usage/UsageRecord.swift` (**two** `UsageFeature` cases, §3.2),
`IMessage/Observability/IMessageCount.swift` (new, the closed vocabulary),
`IMessage/Observability/IMessageUsage.swift` (new, **the only writer** in the app),
`Support/Usage/UsageLogSelfTest.swift` (**extended**).

**Marker** `USAGE_LOG_OK` extended; `--selftest-imessage-privacy` case 5 lands here rather than in
17c, so 17c's red-first is the fixture and 17d's is the sanitiser hole.

**Red-first** — `--selftest-usage-log` cases: every `imessage.event` row round-trips and carries
only the whitelisted keys; `errorMessage` is absent on every iMessage row; **the real promo string
fed through `IMessageUsage` is absent from the encoded row**; a `chatGUID` cannot be written by any
call site because the builder's parameters do not include one; the two new features land in
`UsageSection.GroupKind.other` and **no raw feature id reaches a visible string** (the R3 case at
`UsageSummary.swift:283` is the gate, and it is why this task must run the report case).

**Do not** — Do not add a store, a second log or a metrics file; `usage.jsonl` is the one. Do not
set `errorMessage` to a localised description. Do not add a character count or a text hash
(§3.2). Leave `UsageSection` in `.other` and record the follow-up: a fifth group kind is a wider
change to everyone's history table than this task should make.

### IM-17e — The canary

**Files** — `IMessage/Observability/IMessageHealth.swift` (new: `IMessageCanary` and the pure
`decide` over counts and a clock), `IMessage/Observability/IMessageReportSelfTest.swift` (new,
`--selftest-imessage-observe`), `UI/Settings/IMessageSettingsSection.swift` (the row),
`Support/Notifications.swift`'s existing request path for the one notification.

**Marker** `IMESSAGE_OBSERVE_OK: <n> cases` / `IMESSAGE_OBSERVE_FAILED: <case>: <reason>`.
**Tier INTEGRATION.**

**Red-first** — `.notText`, `.absent`, `truncated` and `tooLarge` never count; the three format
cases do; 9 unreadable in 24 h does not fire; 10 of 50 does; 10 of 200 does not; a second call
inside the cooldown does not; a second call after 24 h does; and **every sentence in
`IMessageCanaryCopy` passes `UIStringsLint.forbiddenTokens` and spells no literal agent name**.

**Do not** — Do not notify per message, ever. Do not count a `notText` as unreadable. Do not put
the count in `usage.jsonl` as prose; it is a number in `counts`.

### IM-17f — The report, and the one visible status row

**Files** — `IMessage/IMessageReport.swift` (new), `UI/Agent/IMessageStatusRow.swift` (new).
**Registration, handed to the orchestrator:** `NextNotesApp.swift` for `--imessage-report`,
`--selftest-imessage-consent`, `--selftest-imessage-observe`; `Scripts/acceptance.sh` for the two
new tiers; `AGENTS.md` for the flag list and the two new rules (`--selftest-imessage-privacy`'s
`_ABSENT` marker, and the "Apple's ids, not ours" line in §3.2).

**Marker** `IMESSAGE_REPORT_OK …` or `IMESSAGE_REPORT_EMPTY` — a diagnostic, **never OK because it
found nothing**. **No self-test marker**, by design (§3.5).

**Red-first** — `--selftest-activity` gains a case that the consumer pane's iMessage strings are
exactly the two in §3.4; and a pure test of `IMessageReport.format(_:)` over a fixture that
**contains** a GUID, a promo URL and a message body, asserting **none of the three appears in the
output**. The formatter is separated from the reader for precisely that.

**Do not** — Do not make this a `--selftest-*` flag. Do not print a `chatGUID`, ever, in any
output, including a debug line. Do not let a report line be the only place a fact exists.

---

## 6. Verify the whole task

```bash
make build && make install OPEN=0
Scripts/run-selftest.sh --selftest-imessage-privacy     # CORE
Scripts/run-selftest.sh --selftest-imessage-consent
Scripts/run-selftest.sh --selftest-imessage-observe
Scripts/run-selftest.sh --selftest-imessage-decode
Scripts/run-selftest.sh --selftest-imessage-db
Scripts/run-selftest.sh --selftest-imessage-loop
Scripts/run-selftest.sh --selftest-usage-log
Scripts/run-selftest.sh --selftest-ui-strings
Scripts/run-selftest.sh --selftest-settings
Scripts/run-selftest.sh --selftest-persona
Scripts/run-selftest.sh --selftest-store-isolation
Scripts/run-selftest.sh --usage-report --usage-feature imessage.   # read-only, by hand
Scripts/run-selftest.sh --imessage-report                          # read-only, by hand, NOT via the harness
make acceptance TIER=core
```

`--imessage-report` and `--usage-report` are run **by hand, outside the harness**, for the reason
in §3.5. `--selftest-imessage-privacy` and `--selftest-imessage-loop` are CORE, so a CORE FAIL exits
non-zero and a known-red entry — case 6, waiting on IM-08 — is left red rather than special-cased
green.

---

## 7. What §7 of the phase file got wrong, missing or already contradicted

Recorded here rather than only in the diff, because each one would have shipped.

1. **§11's "everything else is a user command" is wrong for this feature, and §13's glossary is
   right.** A conversation with yourself is addressed to your own phone number, so a row in it can
   be from somebody else — and IM-01 measured the same fact from the other side (one self-message,
   two rows, opposite `is_from_me`). §13 already has `.otherParticipant`; §11's sentence contradicts
   it. **IM-08 must not treat "in the paired chat" as `.user`.**
2. **The privacy claim needed a second half and the file had one.** "Reads only the conversation
   you pair for" is true of the *query*. It says nothing about the 30 KB of somebody else's offer
   inside one row of that conversation, which the 2026-09-26 measurement put there. §7's
   `--selftest-imessage-privacy` cases (non-paired chat, `chatGUID` always passed, no second chat)
   would all have gone green with the promotional payload fully readable. **Claim B and its four
   cases are new.**
3. **"undecodable messages — the last is the canary" has no threshold, no destination and no
   sentence,** and `undecodable` is undefined. As written it counts `.notText` (every photo, every
   tapback — IM-05's blocked case 4) and so fires on ordinary use. §4.1 narrows it to three cases
   that mean *the format changed*, and §4.2/§4.3 add the threshold, the two destinations and the
   sentences.
4. **"Five screens" is four, and the fifth was the one that would have been skipped.** *Use Next
   from iMessage* is what the switch's own label already says (§1.1).
5. **The five screens were written as a wizard with no trigger and no refusal state.** "A person
   can set this up" is not an answer to *when the grant is asked*, which is the question §7 poses
   and does not answer. The switch, the sheet, the state machine and the refusal sentence are the
   answer (§1).
6. **"A repair row for each grant" is already built** — `fdaAddAdvice`, `fdaRepairAdvice` and the
   `hasOpenedPane` escalation, shipped in IM-04a. Re-authoring it here would have been a second
   spelling of a sentence a person reads in two places.
7. **The metrics list has eleven items and no field list.** `AGENTS.md` forbids a row holding a
   prompt, reply, transcript, address, subject or URL; it says nothing about a `chatGUID`, a text
   hash or a character count, and all three are things this feature would naturally write.
   §3.2 closes the list.
8. **`UsageLog.sanitise` is not the privacy control for this feature and the file implies it is.**
   §7 says "all through `UsageLog.sanitise`". `sanitise` strips identifiers; a third party's offer
   is prose and survives every rule in it. Enforcement at construction, §3.3, and case 5 proves it.
9. **Screen 3's `Waiting for message…` has no orb and screen 4's confirmation has no rule.** A
   wait with no state is the indefinite spinner `AGENTS.md` rules out; `.listening` is the right
   one and it is honest because the watcher is running.
10. **`chat.db` and a remote turn: the send path.** §7's Done-when says "every metric row is
    sanitised" and "the privacy case proves a non-paired chat returns nothing". Neither mentions
    that the *knowledge index* is a third onward path, and `Chunker` would file a promo's claims as
    facts. Case 4 asserts it.
11. **§8's exit list is missing a flag.** Phase 2's exit needs `--selftest-imessage-consent` and
    `--selftest-imessage-observe` registered and tiered; §8 lists only approval, recovery, privacy
    and (optionally) authority.
12. **`--selftest-ui-strings` bans nothing here.** The lint's list (`UIStringsLint.forbiddenTokens`)
    is `cron`, `artifact`, `agenttask`, `transcriptbus`, `task ·`, `tool call`,
    `allowed tools:`, a named schema-key list, and a raw dotted tool id. **None of the eleven words
    this feature must avoid — `TCC`, `grant`, `attributedBody`, `typedstream`, `payload_data`,
    `database`, `sqlite`, `watermark`, `probe`, `signature` — is on it.** The floor does not cover
    this feature's actual hazard, which is why §1.2's copy is written by hand and why IM-17a's
    `IMessageConsentCopy` cases hold the sentences. **Adding those words to `forbiddenTokens` is a
    follow-up for the orchestrator, and it would redden every existing string in the app that says
    "Full Disk Access settings" — so it must be added as an allowlist entry with its reason, per
    `UIStringsLint`'s own rule, never by dropping a rule.**
