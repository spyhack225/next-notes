# Next Notes Phone Calls — status ledger

This is the only progress record. Update it after every task, following `00-README.md` §8.

States: `todo` · `red` · `green` · `done` · `blocked` · `won't do (evidence)`.

Dates are `YYYY-MM-DD`. Evidence is the final marker line plus measured numbers with units. The
commit is a short hash.

## Baseline

```bash
B=~/Library/Caches/NextNotesBuild/phone/baseline; mkdir -p "$B"
make build && make install OPEN=0
# Only flags that exist today. The 2026-09-25 draft listed `permissions`,
# `capabilities` and `actions`, none of which is a flag; and the six `CALL_*` and
# five `PHONE_*` flags of this roadmap are not registered until their tasks run.
for f in calls island settings tool-review persona tasks activity; do
  Scripts/run-selftest.sh --selftest-$f > "$B/$f.txt" 2>&1; tail -1 "$B/$f.txt"
done
make acceptance TIER=core
sw_vers -productVersion
```

| Item | Value |
|---|---|
| Commit (`git rev-parse --short HEAD`) | `78cebc9` (tree dirty — two other workstreams in flight) |
| Date | 2026-09-25 |
| macOS version | **fill in — PH-01's report needs it and PH-18's telephone-band work depends on it** |
| Apple silicon | **fill in** |
| Calls on Other Devices (same Apple Account) | **fill in — cannot be verified programmatically, PH-05 renders "Check this setting"** |
| Contacts authorisation state | **fill in** |
| `codesign -d -r-` designated requirement | **fill in — a stable `identifier … and certificate leaf = H"…"` means G3 is done; `cdhash H"…"` means it changes every build** |
| Developer ID in CI | **fill in — G3** |
| DriverKit entitlement | **fill in — G2** |
| `make acceptance TIER=core` summary | **fill in** |
| DICTATION-MEETINGS-LIMITS M-11 state | **fill in — PH-12 is sequenced with it** |
| AGENT-OVERHAUL P1-03 state | **fill in — PH-07 is blocked without the manifest** |

## Gates

| Gate | Task | Question | Needs | Report | State | Date |
|---|---|---|---|---|---|---|
| **G1** capability | PH-01 | Does `tel:` reach a call from a **background** app, and which states are honestly observable? | a human, an iPhone nearby, Contacts | `Tests/Reports/phone-capability-spike.md` | todo | |
| **G2** DriverKit | PH-02 | Will Apple grant the entitlement a `.dext` needs? | Apple, by email | `Tests/Reports/phone-drivkit-entitlement.md` | todo | |
| **G3** distribution | PH-03 | Can a `.dext` be signed, notarised and installed on a user's Mac? | an Apple Developer account | `Tests/Reports/phone-distribution.md` | todo | |
| **G4** legal (V2) | PH-04 | Calling, recording and disclosure rules per supported market | a lawyer | `Tests/Reports/phone-legal-review.md` | todo | |

**Any one of G1–G4 failing ends V2.** G4 is a gate nobody can close with code.

## Ledger

| ID | Title | Phase | Depends on | State | Date | Evidence | Commit |
|---|---|---|---|---|---|---|---|
| PH-01 | Capability spike: `tel:` from a background app, and which call states are observable | 0 | none | todo | | | |
| PH-02 | DriverKit entitlement request (V2 only) | 0 | none | todo | | | |
| PH-03 | Developer ID in CI and a notarization path (V2 only; shared with the app's release) | 0 | none | todo | | | |
| PH-04 | The gate ledger: the honest state of G1–G4, re-checkable | 0 | none | todo | | | |
| PH-05 | Readiness snapshot and the Contacts permission — one framework, one prompt, shared with iMessage | 1 | PH-01 | todo | | | |
| PH-06 | Contact resolution, number normalization, disambiguation, and the emergency block | 1 | PH-05 | todo | | | |
| PH-07 | The action model: `phone.prepare_call` / `place_call` / `cancel_call` in the manifest | 1 | PH-06; **AO P1-03** | todo | | | |
| PH-08 | Approval, local and remote — the remote half is IM-13, not a second matcher | 1 | PH-07; soft IM-13 | todo | | | |
| PH-09 | The launcher: `tel:`, the two-mechanism raise, the agent-launched marker | 1 | PH-08, PH-01 | todo | | | |
| PH-10 | Verification levels and the `ActionReceipt` payload | 1 | PH-09 | todo | | | |
| PH-11 | Call activity: the island's existing `callQuestion` state, and the Activity row | 1 | PH-10 | todo | | | |
| PH-12 | An agent-launched call does not arm a meeting | 1 | PH-09; **DM M-11** | todo | | | |
| PH-13 | V1 recovery, and a second call is never launched twice | 1 | PH-12 | todo | | | |
| PH-14 | The audio feasibility gate | 2 | PH-13, PH-02, PH-03 | todo | | | |
| PH-15 | The DriverKit driver: a new target, a new bundle, the build and the install | 2 | PH-14 | todo | | | |
| PH-16 | Install UX: four states, not a boolean | 2 | PH-15 | todo | | | |
| PH-17 | `CallAudioBridge`: a second low-latency path that does not touch the voice session | 2 | PH-15 | todo | | | |
| PH-18 | Phone ASR and TTS on the existing engines, telephone-band | 2 | PH-17 | todo | | | |
| PH-19 | The dialogue loop, disclosure, barge-in, hold, IVR | 2 | PH-18 | todo | | | |
| PH-20 | User intervention, preauthorization, and consequential actions | 2 | PH-19 | todo | | | |
| PH-21 | Transcript, structured outcome, durable job, the no-blind-redial policy | 2 | PH-20; soft AO P6 | todo | | | |

**Shared with the iMessage folder:** PH-05 uses IM-03's grants report and shares the Contacts
permission; PH-08's remote half is IM-13's `RemotePreparedAction`. If you change either, say so
here — `Phone-Calls` does not have its own copy.

## Phase gates

| Phase | `make test` | `make acceptance TIER=core` vs baseline | Exit | Report | Date | Commit |
|---|---|---|---|---|---|---|
| 0 | — | — | G1–G4 answers written down; the folder moves to `in-progress/` if G1 closed | `Tests/Reports/phone-gate-____.md` | | |
| 1 | | | `PHONE_READINESS_OK`, `PHONE_CONTACT_OK`, `PHONE_PREPARE_OK` (CORE), `PHONE_POLICY_OK` (CORE), `PHONE_RECEIPT_OK` (CORE), `PHONE_MEETING_OK` (CORE), and `--selftest-phone-spike` run by hand | `Tests/Reports/Phone-Calls-P1-____.md` | | |
| 2 | | | every flag above plus the six `CALL_*` flags, **and** the release gates in `00-README` §12 and `03-PHASE-2-V2-AUDIO.md` §7 | `Tests/Reports/Phone-Calls-P2-____.md` | | |

## Progress — 2026-09-25

| What | State | Evidence |
|---|---|---|
| Audit of this folder against the tree | **done** | ~115 checks by a sub-agent. Fixed: 3 wrong section pointers, 5 nonexistent baseline flags, 1 wrong gate reference, 3 prose/number errors, and **6 drifted anchors plus 4 wrong names** — see below |
| `Sources/NextNotes/Speech/` → `Agent/Speech/` | **done** | there is no `Sources/NextNotes/Speech/`; `StreamingSpeechBuffer`, `PocketAgentVoice` and `KokoroAgentVoice` are under `Agent/Speech/` |
| `hasSystemAudioEverDeliveredSound` → `hasHeardSystemAudio` | **done** | the cited name does not exist. The real one is `Support/Permissions.swift:42`, and it is the precedent the readiness row copies |
| `AgentResultFact` → `AgentTaskOutcome` | **done** | **`AgentResultFact` has 0 hits in `Sources/`** — the earlier draft invented it. PH-21's `facts` is now `[String]`, the shape `AgentTaskOutcome` (`Agent/Tasks/AgentTaskManager.swift:336`) already uses |
| Cross-roadmap file collision matrix | **done** | `roadmap/BUILD-ORDER.md`. **PH-12 vs DM M-11 is already coordinated in writing on both sides → `SERIALISE`, not a collision.** The same file flags **C8: `IslandState.swift` is being restructured by AO's P3-09 while PH-11 writes to it** — decide before P3-09 starts |
| Phase 0 and Phase 1 implementation | **not started** | PH-05…PH-13 additionally need a build slot and, for PH-07, AO's P1-03 |

### The one decision the collision matrix surfaced for this folder

**C8 — `UI/Island/IslandState.swift`.** AO's `P3-09` ("island state owned by VoiceSession, workers
never drive it") restructures that file, and `P1-16` and `P4-04`/`P4-13` also write it. **PH-11 says
"do not add a call state" while writing the same file** — which is the right instinct and the wrong
moment. The existing `IslandState.Kind.callQuestion(MeetingEvent)` at `:82` is what PH-11 should
reuse, so PH-11's scope is a title and a duration, not a new case. **Sequence PH-11 after P3-09**, and
give P3-09 the note that a call card will arrive from a second roadmap.

## Decisions and deviations

- 2026-09-25 (roadmap authoring): the predecessor
  `roadmap/todo/NextNotes_Phone_Call_V1_V2_Roadmap.md` (1,796 lines) was **deleted** and replaced by
  this folder. `REVIEW-LOG.md` §1 records the six substantive changes.
- 2026-09-25 (roadmap authoring): PH-03 exists because the predecessor's §21 named the DriverKit
  entitlement as the V2 program risk and did not notice that **notarization and a Developer ID are
  not built** (AGENTS.md, "What isn't built" §1). A `.dext` cannot be signed stably or distributed
  without them, so G3 is a second gate and the entitlement request is not the whole of it.
- 2026-09-25 (roadmap authoring): PH-12 exists because the predecessor's V1.8 said "a phone call is
  not a meeting recording by default" and did not notice that `Meetings/CallPolicy.isCall` **will arm
  a meeting for a call Next placed itself**. That is a code change, not a setting. Sequenced with DM
  M-11.
- 2026-09-25 (roadmap authoring): the folder is in `roadmap/todo/`, because PH-01 needs a human and
  V1 cannot start before it closes. Moving it up is a one-line change once G1 closes.

## BLOCKED notes

```
### PH-NN — blocked <YYYY-MM-DD>
Tried: …
Failing line: `<NAME>_FAILED: …` (output at ~/Library/Caches/NextNotesBuild/phone/PH-NN-….txt)
Missing: <grant | paired device | Apple entitlement | Developer ID | owner decision | other agent's uncommitted work>
Next step when unblocked: …
```

Expected first entries, so they are written before they happen: PH-07 blocked on AO P1-03; PH-12
blocked on DM M-11; PH-14 blocked on G2 and G3; PH-21 blocked on AO P6.
