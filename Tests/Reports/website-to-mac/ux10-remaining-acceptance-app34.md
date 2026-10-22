# UX-10 remaining acceptance — runtime34 freeze, 2026-10-02

Read-only contract/source/evidence audit. This new report is the only file written by this pass. Sources, build, native capture, model execution, owner inputs, existing reports/STATUS and staging are untouched. Per-app Computer Use approval remains pending; no Next Notes access retry was attempted. This report adds no timing measurement or passing gate.

## What still lacks its actual endpoint

The website roadmap requires no regression against UX-00's measured baseline for the first three rows. It specifies no replacement numeric budget. `LatencyBudget` suggestions and capture-generation elapsed times cannot establish these display gates.

| Gate | Existing producer/consumer endpoint actually present | Missing acceptance evidence |
| --- | --- | --- |
| Dictation key-down → visible listening | Core/DictationController.swift begins state/hold identity; keyDown_to_capture ends at successful audio subscription/isCapturingAudio. The trace starts after earlier beginning work. NextNotesApp.observeState schedules HUD presentation; IslandPanel observes card identity | Accepted input event timestamp, first displayed listening frame, correlated same hold and clock; baseline/current at main-window floor and larger size; both supported HUD placements |
| Work update → island text | Existing activity/state observer tasks consume current state, and IslandPanel.apply places/presents it | Same activity revision at producer and first displayed correct text, not an unrelated later update or present() return |
| Approval choice → acknowledgement | Actual gate/card callback and resumed task/result consumer exist; focused self-tests prove state/payload contracts | Real single choice and first displayed acknowledgement joined to the same review/task; keyboard focus/announcement/one effect remain separate checks |
| Voice speech end → first audio | VoiceLatencyTimeline lastVoice → firstAudible (playback acknowledgement); existing five-counted-run diagnostic | Current packaged five-run warm result with explicit0.9s budget, unchanged fixture/model/warm-up and required joins; this endpoint is not acoustic first syllable |
| Worst main-actor stall | Existing calibrated MainActorStallProbe during actual voice turns | Current changed UI under real load, worst counted stall ≤100ms, plus attribution when a failure occurs |
| Voice onset → duck; three-sentence inter-clause silence | Span names exist | Actual duck emission/measurement ≤200ms; actual clause-boundary playback silence ≤50ms. Pause/stop or clause queue success is not these endpoints |

HUDPanel.present and IslandPanel.present order an offscreen/nonactivating panel then animate alpha. Return, isVisible, alpha assignment, animation completion and compositor presentation differ. No current offscreen leaf image or `.onAppear` establishes the first displayed label. Existing DictationController.observeHoldBeginnings is the one mounted practice-surface observer; do not replace that observer to create a competing measurement owner.

## Evidence that can be retained without spending runtime34's slot

- Historical valid warm voice run: median2.894s, worst counted stall35ms, five single commits with usage/playback joins. It passes that historical stall bound and **misses0.9s**. `VOICE_LATENCY_OK` without explicit headline budget is not phase exit. See [original timing audit](ux10-latency-acceptance-audit.md).
- App29 six Settings cases/24 isolated images verify capture inheritance/isolation. App33 proves the original Formatting viewport failure numerically:15 actual profiles/native rows,380pt table content,0pt inner viewport and0 visible/materialized rows at320/560. Neither supplies user feedback timing. See [app29](settings-app29/README.md) and [app33 original geometry](settings-app33-profile/README.md). Runtime34 owns the producer correction; this audit supplies no fixed/current claim.
- Source recheck found a concrete Phase2 harness gap: the roadmap's `--selftest-tts-pipeline` is **not dispatched** by current NextNotesApp. Registered `--selftest-tts-stream` calls policy/queue/token helpers. No production `voice.inter_clause_gap` emission or `.bargeDuck` stamp was found; ordinary voice-latency required spans exclude barge spans. Do not replace the three-sentence gap gate with a stream helper or infer zero from absent rows. This remains Agent Phase2 owner work.

## Smallest next work, in order

**Available now, independent of the freeze:** prepare the acceptance record from the endpoint table, using one row per actual transition: binary/source identity, journey/window dimensions, event identity/revision, producer monotonic timestamp, first matching frame timestamp, clock mapping/uncertainty and resulting delta. Leave unmeasured fields explicitly unavailable. Preserve original/current artifacts and the missing endpoints above. Existing static/geometry evidence may be reviewed, but it cannot promote display, interaction or motion-performance gates. No new diagnostic implementation or test run is needed for this preparation.

**After root releases a pinned binary and appropriate slot:** replay the four UX-00 journeys with sanitized production inputs at900×600 and a larger shell, fixed light including OS-dark launch, independent Reduce Motion/Transparency settings, and actual island/HUD. Start with one accepted dictation hold and its first visible listening frame; then work-revision → island and one real review choice → acknowledgement. Use the same event/frame definitions for baseline/current. A video lacking a mapped event clock is visual evidence only. Actual practice insertion, edited approval/effect receipt, keyboard/VoiceOver/focus/scroll and selected-native-row contrast remain additional original-flow checks; static no-op capture callbacks cannot supply them. No app-access retry occurs while approval is pending.

**Runtime owner only:** use the existing voice-latency flag with five counted runs, explicit0.9s headline and0.100s stall limits. Preserve required spans/single commits/usage joins and original cold-duplicate evidence. The ordinary five-run diagnostic does not close duck/gap/physical duplex gates. Profile changed live surfaces and collapsed/offscreen drawing using existing Instruments/signposts/probe after a slot release; static TimelineView guards are not a measured CPU/frame budget. Island-on/off pairing is justified only for an actual attribution question, with identical fixture/model/binary conventions.

**No additional runtime layers are proposed.** Source-only observer/geometry checks can isolate a slow or collapsed producer, but are not first-visible acceptance. No UX status, model/default or Agent phase is promoted.
