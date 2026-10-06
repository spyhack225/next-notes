# release Messages settings lock after write failures

RemoteIdentityStore kept its lock when encoding or filesystem operations threw; replacing a directory destination could also incorrectly publish changed in-memory settings. The same writer now unlocks in defer and writes directly with Foundation atomic replacement; memory publishes only after success.

Same isolated persistence cases: original8failures → fixed30cases PASS, including exact memory/disk preservation, released lock, suspend/resume recovery and fresh-reader consumers. First-save already passed on this OS; it is a retained control, not an original failure. No new writer/store or changed remote authority.

Built from canonical current source with foreign work preserved. Same regression cases: original `0b790009cefc`; fixed `2c16bf1c9871`. Deep code-sign verification passed; compiler inputs unchanged per arm; every launcher/fixture joined and removed its owned temporary directory.

Related checks passed once: Messages loop25, consent11, task repair58, recovery56, voice delivery and owner-store isolation21files/32defaults. The nested inherited A02 browser production failures remain open; outer isolation success does not qualify that tool loop. Raw build/test logs and manifests: `~/Library/Caches/NextNotesBuild/integration/owner-freeze-20261006/{original,fixed}/`. No owner messages, recordings or task rows were seeded or rewritten.
