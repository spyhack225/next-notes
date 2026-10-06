# answer with Apple voice while Pocket prepares

prepareForStream selected Pocket solely from the saved choice even when its owner was still preparing. Pocket then rejected the spoken clause. The existing route now selects Pocket only when ready and otherwise selects the existing Apple backing immediately; saved engine/voice choices remain intact and the next ready reply uses Pocket.

Same actual synthesizer route/cancel/replacement cases: original2failures → fixed VOICE_SUSPEND_OK; related delivery passes. This is a host-availability mitigation. Native Pocket compiler/preparation errors and full selected-voice playback acceptance remain open; no compute-placement change or new model pass.

Built from canonical current source with foreign work preserved. Same regression cases: original `0b790009cefc`; fixed `2c16bf1c9871`. Deep code-sign verification passed; compiler inputs unchanged per arm; every launcher/fixture joined and removed its owned temporary directory.

Related checks passed once: Messages loop25, consent11, task repair58, recovery56, voice delivery and owner-store isolation21files/32defaults. The nested inherited A02 browser production failures remain open; outer isolation success does not qualify that tool loop. Raw build/test logs and manifests: `~/Library/Caches/NextNotesBuild/integration/owner-freeze-20261006/{original,fixed}/`. No owner messages, recordings or task rows were seeded or rewritten.
