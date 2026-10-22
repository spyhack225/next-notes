# First displayed feedback acceptance records

Preparation only. [records.csv](records.csv) contains eight **UNMEASURED** original/current sample slots at the existing900×600 main-window floor. Nothing in this directory is a timing, interaction, build or release pass. This is an acceptance artifact, not a product store, diagnostic implementation or new clock.

## Recording a real sample

Pin the installed binary and its actual compiler Source manifest. Record the accepted hold ID, work revision or review identity at the producer, then the first displayed frame showing that same transition. Preserve the original and current event/frame artifacts. Use sanitized fixture content; store app-generated correlation IDs, never an owner's message, address or task text.

The existing timing clock is `CLOCK_UPTIME_RAW` nanoseconds. A capture or compositor timestamp from another clock needs its actual mapping and uncertainty recorded before subtraction. Leave the result unavailable when the producer timestamp, matching identity, displayed frame or mapping is missing. Record the display geometry, requested OS appearance and independent accessibility settings actually used. Do not fill an unchecked setting from a default assumption.

For each matched sample, compute `duration_ms` from the mapped frame timestamp minus the accepted producer timestamp. Link the current sample to its comparable original row. UX-00 specifies no new numeric budget for these three display transitions: compare like-for-like against the measured baseline, preserving uncertainty. A coarse capture that cannot distinguish a regression supplies visual evidence only. Add rows for the larger actual shell, notched/floating display, and required settings cases as observed; the initial eight rows do not cover the full matrix.

## Endpoint contracts

| Gate | Start | End |
| --- | --- | --- |
| Dictation key-down → listening | Accepted key event for the same real hold; include work before capture admission | First displayed HUD/island listening feedback for that hold |
| Work revision → island text | Producer emits the accepted activity revision | First displayed corresponding stage text; a later unrelated revision does not qualify |
| Review choice → acknowledgement | The single real choice enters the existing review gate | First displayed acknowledgement for that review/task |

`HUDPanel.present`, `IslandPanel.present/apply`, `orderFrontRegardless`, alpha changes, `.onAppear`, offscreen `cacheDisplay` and capture-generation elapsed time are not the displayed-frame endpoint. `dictation.keyDown_to_capture` is capture admission, not listening display. Screenshots without joined events are not timing measurements. Video without a mapped producer clock is visual evidence only.

Playback timing stays in the existing Phase2 voice diagnostic and usage/playback joins; do not add it to this display record as an inferred audible event. Five current warm turns, onset→duck, actual inter-clause silence and worst actor stall remain separate gates in [the remaining acceptance audit](../ux10-remaining-acceptance-app34.md).

## Access and ownership

Next Notes Computer Use access was rejected by automatic approval review and its per-app approval remains pending. The owner's unlocked-Mac reply resolves the lock condition only. No app-access retry, native action or bypass was performed to create these records. Runtime root holds Sources/build/install/native/model/staging; these files prepare the eventual authorized measurement slot.

See [manifest.json](manifest.json) for the six read-only Source inputs and records hash. No Source changed and no test ran in this preparation.
