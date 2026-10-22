# Phase 0 — the four gates

Tasks `PH-01`…`PH-04`. **None of these places a call and none is call code.** They exist because
V1 has an unmeasured platform assumption and V2 has three hard blockers, and because the difference
between shipping V2 in six months and never is entirely in what happens in this phase.

**This phase exits by writing down answers, not by passing a self-test.** PH-01 adds one physical
flag; PH-02…PH-04 add none.

---

## 1. PH-01 — Capability spike

**Finding(s):** `tel:` from a background app has a measured precedent for failing  **Effort:** 1 day
**Depends on:** none  **Unblocks:** all of V1

**Goal:** answer, with measurements:

> Does `NSWorkspace.shared.open(URL(string: "tel:…"))` place a call from a **background** app on this
> Mac, and which call states are honestly observable from outside Phone.app?

**Why this is a gate.** `tel:` is public API and the predecessor was right that it is the right
mechanism. What it did not anticipate: **Next Notes is, by design, a background app during an agent
turn** — the HUD is a non-activating panel and focus never leaves the user's field. This repo has
already measured that macOS's cooperative activation resists exactly that:

> `NSRunningApplication.activate()` is refused often enough to be useless alone, because macOS's
> cooperative activation resists a *background* app raising another — and Next Notes is always
> background during a dictation, by design.

The mitigation that shipped for dictation is **two mechanisms plus polling** — `activate()` **and**
`kAXFrontmostAttribute` through the Accessibility grant, both followed by polling, because a `⌘V`
arriving mid-raise lands somewhere else. **A `tel:` launch is the same shape.** If the spike finds
the URL open does not raise Phone.app, V1 needs the dictation treatment and that is a real design
input, not a detail.

**What you need:** the owner, an iPhone nearby and paired to the same Apple Account, Contacts
authorised, and `make signing-cert` done **or** its absence recorded (PH-04's job).

### Steps

1. Build a small diagnostic target — `--selftest-phone-spike` — that runs the matrix in §1.1 and
   prints one row per case with a measured duration. It is a **human-in-the-loop** flag: it prompts,
   waits, and records. `Scripts/run-selftest.sh --selftest-phone-spike --via-open`, run by hand.
2. Measure, for each case: `request → system UI`, `request → dialing`, `dialing → remote ring`,
   `hangup → UI updates`. **Record the numbers**; they become the V1 performance baseline.
3. Investigate call-state signals and **record which exist on this macOS**: system UI state · public
   notifications · the accessibility tree as a fallback · process state · system audio state.
   `/usr/bin/log` is for diagnostics only and must never become a production dependency — and note
   that info-level unified-log entries age out within minutes, so a slow run reported an hour later
   has already lost its evidence.
4. Answer §1.3's four questions explicitly.

### 1.1 The matrix

```text
tel: URL launch                     Phone.app activation
known contact                       raw E.164 number
FaceTime fallback behaviour         system confirmation behaviour
same Apple Account                  Calls on Other Devices on/off
Wi-Fi Calling on/off                iPhone nearby / not nearby
Mac locked / unlocked               Mac sleep / wake
```

**Plus the five the predecessor omitted, and §0.5 of `00-README` explains each:**

```text
launched from a BACKGROUND app, another app frontmost     ← the normal Next Notes case
launched while a meeting recording is already running
launched while another call is already active
launched twice in quick succession                       ← does anything deduplicate?
launched from a Mac that has never placed a call before
```

### 1.2 `PhoneCallVerification` levels, decided by evidence

The enum is the same one V1 ships (`02-PHASE-1-V1.md`, PH-10):

```swift
enum PhoneCallVerification: Sendable, Equatable {
    case requestDispatched
    case systemCallUIVisible
    case dialingObserved
    case connectedObserved
    case endedObserved
    case unverifiable
}
```

**Mark each level `available` or `unavailable` in the report.** V1 ships even if only
`requestDispatched` and `systemCallUIVisible` work; it must then never claim "Call connected".

### 1.3 The four questions

**Q1 — the raise.** From a background app, does Phone.app come forward? If not, what does? Record
the exact sequence that works, because PH-09 implements it.

**Q2 — the confirmation.** Does the OS show a confirmation dialog? **If it does, PH-09 must not
automate it away.** The predecessor was right about this and the rule is absolute: do not
automate away an Apple confirmation dialog if the OS intentionally requires user confirmation.

**Q3 — the states.** Which of the six levels are available? For each, name the signal.

**Q4 — the failure modes.** What happens when Continuity is off, the iPhone is away, the Mac is
locked, or the user declines the confirmation? These are PH-13's cases and the spike is the only
place they can be observed.

### 1.4 Deliverable

```text
Tests/Reports/phone-capability-spike.md
```

macOS version and build · the matrix with measured durations · the available verification levels with
their signals · the four answers · **which audio device Phone.app exposes while a call is up**, which
is the first half of V2's feasibility question and costs nothing to record here.

**Do not** put a real contact's number in a committed report. Use a name and a masked last four.

### 1.5 Done when

- [ ] The report exists, is committed, and is sanitised.
- [ ] Q1–Q4 are answered, not implied.
- [ ] Every level in §1.2 is marked available or unavailable.
- [ ] The background-app case was actually run — it is the case that matters and the one a
      frontmost-only test would miss.

---

## 2. PH-02 — The DriverKit entitlement request

**Finding(s):** AGENTS.md's "What isn't built" §1: notarization and signing are not built.
**Effort:** hours of writing, then waiting  **Depends on:** none  **Unblocks:** V2 only

**Goal:** ask Apple for what a `.dext` needs, and record the answer.

**This task is nearly free and has the longest latency in the entire roadmap.** It costs a few
hours and the answer may take weeks or months, and the answer may be no. **Start it before PH-01
closes, not after.** The predecessor's §21 said "start this early" without saying how early, and
"early" means *now*, because the only thing that can happen during V1's development is waiting.

**What to request:** the AudioDriverKit entitlement for a user-space audio driver, for an app
distributed outside the Mac App Store. Ask precisely, and say what the driver is: a virtual duplex
audio device so a voice assistant can hear a call and speak into it. Be explicit that the app is
AGPL-3.0-or-later and not sandboxed.

**What to record, either way:**
- the request date, Apple's reference number, and who is the contact
- the decision and its date
- if granted: what the provisioning profile looks like and how long it takes
- if refused or stalled: **the date, and the fallback evaluated** (`00-README` §13 and
  `03-PHASE-2-V2-AUDIO.md` §6)

**Do not** block on this. V1 does not need it. Do not treat a refusal as a failure of this task —
a recorded, dated "no" is a complete answer and it unblocks PH-04's honesty.

**Done when:** [ ] the request is sent and the date recorded in `STATUS.md`; [ ] the fallback is
named in advance; [ ] no V1 task waits on it.

---

## 3. PH-03 — Developer ID in CI and a notarization path

**Finding(s):** AGENTS.md §1: the release image is ad-hoc or locally signed  **Effort:** 2–5 days,
and it is shared work  **Depends on:** none  **Unblocks:** V2 only

**Goal:** make it possible to sign a second binary and have a user run it.

**This is the gate the predecessor did not know existed, and it is not phone work.** It is the
app's release problem, and it is worth doing even if V2 is abandoned:

1. **A Developer ID in CI.** `Makefile:37` already auto-detects one via `security find-identity`;
   the missing half is the certificate existing at all. `make signing-cert` creates it, and AGENTS.md
   documents the two OpenSSL traps (`-certbe/-keypbe PBE-SHA1-3DES -macalg sha1`, and
   `security add-trusted-cert -p codeSign` before the identity count is non-zero).
2. **Notarization.** `make dmg` and the tag-triggered release exist; the image is ad-hoc or locally
   signed, so **Gatekeeper refuses a downloaded copy**. Stapling, the notary credentials, and the
   `codesign` order for a bundle containing a `.systemextension` are the work.
3. **Verify the requirement is stable.** `codesign -d -r-` before and after a rebuild. It must read
   `identifier "ai.pivotstudio.nextnotes" and certificate leaf = H"…"` and be **identical across
   builds**. If it reads `cdhash H"…"`, it changes every compile, and **every TCC grant in the app is
   invalidated by every `make install`** — which is IM-03's finding, and it is the same fact.

**Do not** replace `--sign -` with anything, and do not remove
`cs.disable-library-validation` — it is there for the bundled llama.cpp XCFramework.

**Done when:** [ ] a stable requirement is proven across two builds; [ ] a notarized build installs
and launches on a clean Mac; [ ] `STATUS.md` records it, and the iMessage folder is told, because
IM-03's Automation grant depends on it too.

---

## 4. PH-04 — The gate ledger

**Finding(s):** G1–G4  **Effort:** 1 hour, then 15 minutes whenever something changes  **Depends on:**
none  **Unblocks:** honest scheduling

**Goal:** one place that says what is true about the four gates, dated, so nobody plans V2 against a
guess.

```text
Tests/Reports/phone-gates.md
```

| Gate | Question | State | Date | Owner | Re-check by |
|---|---|---|---|---|---|
| G1 capability | `tel:` from a background app | open | | | |
| G2 DriverKit | will Apple grant it | requested | | | |
| G3 distribution | can a second binary be signed and shipped | open | | | |
| G4 legal | calling/recording/disclosure per market | not started | | | |

**The rule this task exists to enforce: a gate with no date is not a gate, it is a hope.** Every row
carries a date and an owner. A row whose "re-check by" has passed is escalated, not quietly carried.

**G4 is not closable by an agent.** Calling, recording and automated-disclosure rules are
jurisdiction-specific and a legal review is a release gate on V2. Record it with an owner and a
target, and do not let a green flag elsewhere stand in for it.

**Do not** add a self-test here. There is no code, and a probe that reports green about a question
nobody asked is the failure mode this roadmap is most exposed to.

**Done when:** [ ] the table exists with a date and an owner per row; [ ] G4 has a named owner;
[ ] it is in `STATUS.md`'s gate table; [ ] whoever picks up V2 reads it before planning.

---

## 5. Phase 0 exit

All four gates have a dated answer. `STATUS.md`'s gate table is filled. **If G1 closed, the folder
moves to `roadmap/in-progress/`** — one line, and `00-README` §2 says so.

The single most useful sentence this phase can produce is the one that stops V2:

> On <date>, a `.dext` could not be signed, installed, or routed, because <reason>. V2 is
> re-planned as <the §6 fallback> or not at all.

Write it if it is true. It is more valuable than a V2 that never ships.
