# exclude Wispr dictation from automatic meeting detection

Actual incident logs show Wispr Flow microphone/output ownership becoming a settled call and starting meeting recording. Its dictation process was absent from CallPolicy's existing denylist. Add its exact bundle ID to that list; preserve conferencing and per-app controls.

Same candidate→policy→debounce cases: original4failures → fixed CALLS_OK, including Wispr alone never arming and Wispr not displacing Zoom. This repairs the false meeting producer; the subsequent large native memory spike is still unconfirmed and not declared fixed.

Built from canonical current source with foreign work preserved. Same regression cases: original `0b790009cefc`; fixed `2c16bf1c9871`. Deep code-sign verification passed; compiler inputs unchanged per arm; every launcher/fixture joined and removed its owned temporary directory.

Related checks passed once: Messages loop25, consent11, task repair58, recovery56, voice delivery and owner-store isolation21files/32defaults. The nested inherited A02 browser production failures remain open; outer isolation success does not qualify that tool loop. Raw build/test logs and manifests: `~/Library/Caches/NextNotesBuild/integration/owner-freeze-20261006/{original,fixed}/`. No owner messages, recordings or task rows were seeded or rewritten.
