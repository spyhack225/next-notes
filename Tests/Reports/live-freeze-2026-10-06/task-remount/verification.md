# keep task history readable across volume remounts

The saved export compared a mount-specific `st_dev` against the current mounted file. The incident retained the same inode/database identity but a changed mount device, so valid history was rejected. TaskStore now records stable volume UUID metadata; marked-history witness reconciliation uses it, with bounded legacy compatibility under the existing database UUID/generation and inode checks. Live file replacement and prepared-import checks retain exact device/inode semantics.

Unchanged installed authority regression: original3 failures (two remount refusals, one wrong-volume acceptance) → fixed63cases PASS. Wrong inode/volume remain refused without changing bytes; normal save records the stable witness. This establishes isolated store/consumer behavior, not owner-store migration or remote-task hosting.

Built from canonical current source with foreign work preserved. Same regression cases: original `0b790009cefc`; fixed `2c16bf1c9871`. Deep code-sign verification passed; compiler inputs unchanged per arm; every launcher/fixture joined and removed its owned temporary directory.

Related checks passed once: Messages loop25, consent11, task repair58, recovery56, voice delivery and owner-store isolation21files/32defaults. The nested inherited A02 browser production failures remain open; outer isolation success does not qualify that tool loop. Raw build/test logs and manifests: `~/Library/Caches/NextNotesBuild/integration/owner-freeze-20261006/{original,fixed}/`. No owner messages, recordings or task rows were seeded or rewritten.
