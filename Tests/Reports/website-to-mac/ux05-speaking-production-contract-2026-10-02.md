# UX-05 speaking state: production dependency audit (2026-10-02)

## Verdict

**Open.** No production island `speaking` kind or owned voice projection exists. The smallest sound path is to use the existing playback output identity and first playback acknowledgement in `RealtimeAudioSession`, then let P3-09's `VoiceSession` own the island projection. This is a contract proposal, not implementation or a pass claim. Source was read only; no app build or native visual check was run in this slice.

## Current event path and evidence

1. `RealtimeAudioSession.beginSpokenReply` mints `OutputID`, retains `OutputKind` (including answer `TurnID`), and records the synthesizer's output generation. `appendSpokenReply` may enqueue a clause; `noteEnqueueIfNeeded` already sets legacy `isSpeaking = true` at **enqueue**, so that Boolean cannot certify playback (`RealtimeAudioSession.swift:180–207, 582–594`).
2. `AgentSpeechSynthesizer` emits `.enqueued`, `.began`, `.startAcknowledged`, `.completed` and `.interrupted`; a clause has a playback token. `didBeginAudio` rejects a stale token and emits `.startAcknowledged` once for the clause (`Speech/AgentSpeechSynthesizer.swift:23–29, 344–356`). The acknowledgement strength is backend specific and does not prove a human heard sound (`:58–68`). The Apple PCM, Pocket, and Kokoro playback paths call their start callbacks after a positive length buffer's `.dataPlayedBack` completion (`AgentSpeechSynthesizer.swift:816–849`, `PocketAgentVoice.swift:267–285`, `KokoroAgentVoice.swift:174–185`). The prepared Pocket source path calls it after `AgentPCMRenderer` has copied `>0` samples and its receipt has passed output latency (`AgentPCMRenderer.swift:42–59, 425–439`; `PocketSourceSpeechBacking.swift:215–218`). These observations are stronger than model text or `player.play()`, but still not proof of audibility at a person's ears.
3. `RealtimeAudioSession.receivePlaybackEvent` checks its output generation against the synthesizer, sends `.playback(output.id, .firstAudio)` on `.startAcknowledged`, and sends `.finished` or `.interrupted` from `voiceShadowPlaybackSettled` (`RealtimeAudioSession.swift:409–455`). The reducer checks the exact output ID before changing `heard/status` and projecting `.speaking` (`Duplex/VoiceContracts.swift:277–300`). The scripted production-entry test checks queued before fake backend acknowledgement, then heard and final release (`Duplex/VoiceSessionReducerSelfTest.swift:176–207`). It does not check the island or physical playback.
4. `VoiceSession` remains `Mode.shadow`: it records commands but executes none (`Duplex/VoiceSession.swift:3–10, 78–94`). `IslandState.Kind` has `agentListening`, `agentWorking`, `agentReply` and approval states, with no `agentSpeaking`; `agentReply` is an eight-second text notice with avatar `.done` (`UI/Island/IslandState.swift:113–121, 256–276, 477–479`). The live island prioritizes `ActivationController` listening/working and pending approval; it does not consume `VoiceSession.state.island` (`IslandState.swift:603–651`). Thus a reducer trace saying `publishIsland(.speaking)` is not a live UI signal.
5. `VoicePlaybackDelivery` uses clause completion to persist message delivery and deliberately ignores `.startAcknowledged` (`VoicePlaybackDelivery.swift:26–59`). It is a result/delivery record, not a source for a live speaking animation.

## Proposed owned contract for P3-09 + UX-05

- Keep a single `VoiceSession` output owner and the existing `OutputID`/`TurnID`/synthesizer generation checks. P3-09 executes its existing `publishIsland` command only for the current open session; workers may not write the conversation island. UX-05 maps `.speaking` to one `agentSpeaking` presentation with the agent portrait, short label **“Speaking”**, and current answer snippet only if that snippet is already recorded. Do not render a transcript as if typed or heard before playback acknowledgement. The proposal card remains the actionable priority; never obscure pending approval.
- Enqueue, `.began`, model busy, legacy `RealtimeAudioSession.isSpeaking`, and stream-open do **not** enter `speaking`. Enter only after the current output's first positive playback receipt (`.startAcknowledged` backed by the selected real backend). If a backend cannot supply that receipt for a run, retain listening/working and leave speaking unclaimed. Use “playback acknowledged” in diagnostics, not “heard by user.” No new audio channel, ledger, queue, timer, polling loop, or await belongs on the turn path.
- Clear speaking on the matched output's actual `.finished`, hard stop, barge-in, session close or replacement. A stale completion for A must never clear B. Provisional listening pause must stop the visible motion/claim while output is paused; resume may restore it only while the same output is still active and the producer confirms resumed playback. The current reducer does not visibly project a paused state, so that contract needs production work, not a view-only conditional. Mic capture may remain live throughout: full duplex must survive.
- Keep the eight-second `agentReply` card as a readable result/notice after speech, not as evidence that speech is occurring. The collapsed island has one animated mark; a background worker can be represented by a still secondary chip when expanded, per P3-09.

## Required before implementation can be called done

Coordinate source ownership with the P3-09/runtime owner before changing `VoiceSession`, `RealtimeAudioSession`, `IslandState` or `IslandView`. Reproduce the original live defect: a real production-path output renders a positive playback receipt while the island remains listening/working. Then add one installed production-entry regression that checks the matching output ID and island state through queued → first receipt → finish, with counterexamples: zero-playback enqueue, stale token/generation, old-output finish after replacement, provisional pause/resume, barge/cancel, session close, and pending approval. Verify the live island consumes the producer projection, not only the pure reducer. Preserve `--selftest-island`, `--selftest-avatar`, voice duplex/reducer/latency checks and the full-duplex timing bar; obtain native visual and VoiceOver evidence when the app surface is available. Without those gates, UX-05 speaking remains open.

## Updated prerequisite frontier — staged219 / staged220, 2026-10-03

Two off-source reviewers reconcile the [bounded TaskBridge proof](../agent-overhaul-closure/p3-task-bridge-production/verification.md)
with this consumer proposal. Original219 fails14 qualified feature assertions;
fixed220 passes the identical47checks across five actual modes, plus prior
cancellation14/C1 controls. Common fixture SHA
`5d101cd7970e1a061ec73b0db852f93c6722a50a182c0407f7a13c906b7b92c5`
is unchanged. Only Manager, TaskBridge and Coordinator differ across1084 compiler
inputs; twelve related staged flags exit0 with Source/full-bundle invariance.
Original218's frontend answered instead of delegating and reached no bridge
checks; its retained INVALID result supplies no feature verdict.

TaskBridge is now a stateless adapter to the existing Manager/SQL row. Intake
commits before worker creation and acknowledgement. The terminal commit gates
success delivery. Cached status/result use the admitted row without a model call.
Explicit cancellation stops the same Task and fences its generation immediately,
even if persistence fails; the saved row and failure reply remain truthful about
that refusal. Accepted SQL with a failed export remains admitted. This establishes
bounded canonical voice-task row admission and reporting, with no second ledger.

It does not establish the full P3-03a/b origin/session/revision/worker migration or
output delivery contract. Coordinator still owns its jobs worker list. Legacy
activity and guarded background Island work publication remain; VoiceSession is
still Mode.shadow and the live Island has no speaking Kind. Task status therefore
supplies no playback OutputID, receipt or speaking authority.

The next bounded UI proposal should prepare the existing IslandState/IslandView
semantic Kind, portrait/label and foreground guard for **future** session-owned
output publication. The ActionRuntime hasForegroundVoiceActivity/background-work
guard must recognize that future Kind to prevent background overwrite. Keep a
stable output identity, truthful capture meter, real pending-approval routing,
matched pause/resume/finish and output-specific Stop effect. A taskID cancellation
route cannot substitute for stopping a playback OutputID. Activate nothing before
P3-09 owns and verifies its publishIsland command and the real consumer flow above.

The TaskBridge proof promotes no UX-05 completion, live UI switch, physical
interaction, accessibility or latency gate. P6 responsiveness217 remains failed
at318.892ms against100ms. This update changes only the off-source contract;
Source/build/native/model/index ownership remains with runtime root.
