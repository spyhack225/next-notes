# keep Messages AppleScript execution off the main thread

The real sender awaited blocking NSAppleScript on MainActor, matching the incident's main-thread unresponsiveness warning around the send. The same in-process sender now uses one serial blocking executor and a private thread-safe OSAKit AppleScript language instance. Exact by-name address, escaped body, 30second native timeout, TCC identity and outbound ledger remain unchanged. Cancellation before native entry sends nothing; after entry it awaits the actual outcome and never retries an uncertain send.

Unchanged MessagesSender→ledger→sender case and harmless native scripts: original6of12failures → fixed12checks PASS. Main queue heartbeat occurs while execution is held; actual OSA runs off-main with its private instance, native compile errors fail, already-cancelled work does not execute, and pending uncertain delivery is retained. Full loop25/consent11 pass. These tests send no real message and do not prove owner TCC/delivery or the still-absent production incoming-message host.

Apple threading guidance: https://developer.apple.com/forums/thread/759287 . Modern OSAKit's supplied private instance and selected language isThreadSafe contract are used; no legacy generic-component flags are claimed checked.

Built from canonical current source with foreign work preserved. Same regression cases: original `0b790009cefc`; fixed `2c16bf1c9871`. Deep code-sign verification passed; compiler inputs unchanged per arm; every launcher/fixture joined and removed its owned temporary directory.

Related checks passed once: Messages loop25, consent11, task repair58, recovery56, voice delivery and owner-store isolation21files/32defaults. The nested inherited A02 browser production failures remain open; outer isolation success does not qualify that tool loop. Raw build/test logs and manifests: `~/Library/Caches/NextNotesBuild/integration/owner-freeze-20261006/{original,fixed}/`. No owner messages, recordings or task rows were seeded or rewritten.
