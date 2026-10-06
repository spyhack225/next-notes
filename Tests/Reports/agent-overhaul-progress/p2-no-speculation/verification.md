# P2-02 no-speculation instrument — 2026-10-06

Confirmed cause: `VoiceLatencySelfTest` printed `speculation=disabled`, but the real
coordinator partial-preparation producer still started speculative inference. The
first native split/overlap pair was unqualified; its raw records retain speculation
hits and multiple route passes. It was stopped, its exact child joined and claim
released. No timing gain or P2 acceptance is inferred from that pair.

Fix: the existing `prepareResponseIfUseful` entry refuses preparation only when
SelfTest and `--voice-no-speculation` both hold. Production behavior is unchanged.
The existing partial test exercises that entry and the actual committed answer and
speech consumer: no pre-commit model call, history write or speech; exactly one
fresh committed answer still runs. External generation/speech alone are scripted.

Original staged34663 (`a37159df11dddbe10e3bb309b9a2757dc443fc4c88311552d329fe727e8f15d8`) fails that
unchanged producer assertion. Fixed staged34860 (`77ddf96414ce24a379fb8187803f891c340e40738ab4237c11ad2705f8f66769`)
passes it, ordinary partial/dictionary preparation, frontend staging and owner-store
isolation (21 files/32 defaults unchanged). All four flags exit0 and owned TMPDIRs
are removed after joining. The nested inherited A02 production-fixture failures
remain open; the isolation marker does not claim those pass.

Raw build/result/logs: `~/Library/Caches/NextNotesBuild/integration/p2-no-speculation/`.
Invalid pair: `../p2-split-overlapped-current/native-pair/`. Repeat native timing with
the corrected producer before selecting any frontend mode; all latency targets remain open.
