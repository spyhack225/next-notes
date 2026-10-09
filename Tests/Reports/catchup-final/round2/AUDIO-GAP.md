# Saved-file output decision

Saved-file playback is **not accepted for the one-channel rule**. This round uses
BRIEF-ROUND2.md's explicitly permitted gap/report route. No scheduler token wrapper,
new output owner, speech synthesizer change or file transport was added. Existing
Play/Pause/Resume and activity/wake mitigations remain; they do not supply an echo
reference or prove acoustic safety. The no-apple branch remains a separate dependency.

## Existing producer contracts at 233b5dd8

- `CatchUpLibrary.swift`, CatchUpPlayer.play/resume: the production makePlayer constructs
  AVAudioPlayer, then calls prepareToPlay/play directly. Playing ID is held across pause;
  stop releases it. Island and Library buttons use this same player. This is still a
  separate physical audio start from the shared speech owner.
- `OutputScheduler.swift`, beginAnswer/speakFixed/speakSessionless/speakEntries: tokens
  enter RealtimeAudioSession's spoken-text API. OutputHandle only appends/finalizes/cancels
  spoken text. Scheduler entries hold text/delivery/questions, with no file or PCM source.
  A token alone supplies neither physical rendering nor a saved position.
- `RealtimeAudioSession.swift`, begin/append/finalizeSpokenReply: StreamingSpeechBuffer
  feeds the speech synthesizer. Output identity, lifecycle and interruption are bound
  to that synthesizer's outputGeneration. noteUserSpeech/stopOutput cancels its speech
  buffer and speech backing. Listening hold/duck admission also requires that synth
  generation and synth.isSpeaking. None owns the AVAudioPlayer or a file cursor.
- `AgentSpeechSynthesizer.swift`, AgentSpeechBacking/AgentReplySpeechBacking: the admitted
  source is String; there is no production file/PCM entry. preparePersistentPocketPlayback
  explicitly guards SelfTest and a source probe flag; its fixed WAV override is also a
  probe contract, not a production file playback API.
- `AgentPCMRenderer.swift`, enqueue/pause/resume/finish/stop: there IS a reusable bounded
  PCM transport, with gain applied before the actual source-node render callback feeds
  AcousticEchoProcessor's reverse reference. It uses its own UInt64 renderer generation,
  singleton receipt callbacks, and session lifecycle. It offers no file decoder, logical
  file identity, rendered-position receipt or scheduler admission. Calling it directly
  from CatchUpPlayer would bypass the current session/synth interruption owner.
- `PocketSourceSpeechBacking.swift`, prepare/endSession/speak: this existing backing owns
  the renderer's onFirstSample/onDrained/onFailure callbacks and renderer generations.
  Its Task streams synthesized PCM, reports clause receipts and pauses/resumes the same
  generation. Letting a second file caller replace these callbacks/session would break
  ownership rather than share it.

- `PCMProbeSpeechBacking.swift`, init/prepare/speak: an existing self-test WAV adapter
  does feed the real renderer. It admits only 3–25 seconds, reads/converts/copies the
  complete waveform, ignores requested utterance text, and rejects prepare outside
  SelfTest. Its callbacks take the same singleton renderer slot. It has no saved-file
  rendered cursor, arbitrary-length bounded decode or production scheduler admission.
  This is useful implementation precedent, not a production transport to enable.

The pinned seven source hashes are in audio-seam-pins.json; audio-entry-points.txt records the source entry locations. These are source-contract
findings, not a physical audio experiment. No account, owner recording or model was read.
The missing seam spans scheduler admission, session/synth lifecycle, file decoding and
rendered-position receipts; it cannot be repaired with a small CatchUpPlayer-only change.
Speech producer edits are explicitly outside this round's assigned scope. Wrapping the
same AVAudioPlayer play call in OutputScheduler would leave the original P1 failure.

## Recommended owner decision and design

Authorize a bounded extension of the existing output/speech producer to accept a saved
file source alongside spoken text. OutputScheduler must mint the same capability and
admit it against existing live activity before any file open/start/resume. The existing
RealtimeAudioSession/AgentSpeechSynthesizer must own its generation, renderer callbacks,
start/drain/failure receipts and user-speech interruption, including sessionless playback.
One backing should pump bounded AVAudioFile chunks through AgentPCMRenderer's existing
ring/reference path, with no second player, ring, queue, store or model pass. File decode
belongs off the interactive turn path. Do not enable the probe-only route as a shortcut.

Keep CatchUpPlayer as the observable UI facade: retain playingID and a rendered file
cursor across explicit Pause and preemption, and release identity at replacement/end/stop.
Library and island should continue to call that facade; neither starts audio. Resume must
require a fresh admission and an explicit tap, never replay automatically after speech.
Position must follow actual rendered frames, including buffered PCM, rather than decoder
read-ahead; the current renderer has only first/drain receipts, so this is an explicit
missing contract. An old callback must never advance or finish a newer output.

Acceptance needs actual scheduler/session/file backing tests for admission, preemption,
paused identity/position, stale callbacks, reply overlap refusal, first/drain receipts and
graph/device failure, plus actual rendered-reference evidence. Reuse the existing 45
Catch-up admission checks and synchronous speech-preemption checks unchanged as related
regressions; their scripted AVAudioPlayer recorder does not prove the new channel.
Physical near/far speech, echo tail, device changes and uninterrupted capture require
separate coordinated native acceptance. No default, release or acoustic-safety claim
follows from this report or the current green scripted checks.
