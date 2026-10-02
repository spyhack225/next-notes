# Common repeat-resume control — preparation only

Root's provisional-pause concern was rechecked against the current Source and exact proposed
VoiceContracts snapshots. Both already use output.status != .paused. That predicate includes
awaitingResume, so no missing guard or introduced bug was found and no producer revision is
justified. The outdated playing-or-queued-only condition is not present in these inputs.

The new off-source fixture is a COMMON positive control, never an original bug reproduction.
It uses only actual VoiceSessionReducer events and local value state, no new status reference,
mock callback, native/player owner, store, model or singleton. Queued/not-heard and played/heard
modes each traverse provisional pause → discard/resume → second provisional with no intervening
playback receipt → repeated paused input → stale old discard → current discard/resume → finish,
quiet-window delivery eligibility and close. It checks exact same output pause/resume commands,
current floor/hold, preserved historical heard, stale-input refusal and eventual cleanup.

20 checks (10 per heard mode) are predicted to pass on BOTH current original and pending proposal.
It leaves existing10 pure traces and actual original94 common28 unchanged. Root may register this
separate common control before both native runs if useful; no Source was mounted/edited here.
This does not supply positive post-resume receipt/epoch authority or physical two-cycle playback.
The pure finish event checks reducer consumption only; native callback/stop/drain must be proved
separately through the existing actual backing fixture and related gates.

Current native tap-deadlock work is root's priority and this preparation does not authorize a
Source/native/build/index operation. The three existing pending negative-contract producer patches
remain byte-identical. A truthful unknown/awaiting shadow must not become indefinite live UI waiting.
