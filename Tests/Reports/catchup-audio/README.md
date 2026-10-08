# Catch-up offer context and saved-audio admission

Native matching-fixture producer evidence, 2026-10-08. Base is pinned in `base.txt`; all work is on `claude2/catchup-audio`. No installation, push, merge, GUI, microphone or model load.

The accepted scheduled entry originally submitted a bare user turn. `CatchUpLibrary.acceptOffer` now passes the entry to `LiveCatchUpOfferActing`, which records its text with the existing background-task tag before submitting the normal turn. Optional identity on the existing conversation row suppresses repeated recording in the retained current session, including JSON/fresh-reader replay. Distinct entries with identical words remain distinct. An idle/new session receives its own antecedent. Existing storage, prompt clipping and compaction bounds remain unchanged.

The file player originally started without checking activity and checked only activation on its later tick. The shared synchronous predicate now refuses Play and Resume before file opening/start and pauses on the existing tick during dictation, meeting recording, output speech, calls or non-idle activation. Paused position/identity remain; another tap is required to resume. See [DESIGN.md](../../../DESIGN.md) for why a production saved-file entry on the existing text audio owner is larger than this repair. The conservative fallback retains the existing file transport and 250 ms tick; it does not supply PCM echo reference or immediate interruption.

## Matching native proof

`fixture.sha256` pins the corrected fixture to `f919a8858de89bccd24e63d1c2dbb6954506e1a71fe7cfa6679ea3acd03d3a9a`; the slot verified it unchanged after the fixed build. `red-scaffold.patch` applied to the base retains the original bare-turn and unconditional Play/Resume producers, while adding only dependency injection and the callable existing tick seam. The new test file supplies the same fixture for both. `red-sources.sha256`, `fixed-sources.sha256` and binary hashes pin the exact native sources/binaries.

| Case | Original | Fixed |
| --- | --- | --- |
| Actual scheduled Library → Live → isolated Session | 12 checks, 8 failed; `roles=user background_rows=0 turns=1` | 12 checks, 0 failed; `roles=assistant,user background_rows=1 turns=1` |
| Actual planner/chat prompt consumers, retained identity, fresh JSON reader, idle boundary | `CATCH_UP_HANDOFF_FAILED` | `CATCH_UP_HANDOFF_OK` |
| Actual executor/orchestrator/normal approval card | `CATCH_UP_APPROVAL_OK`; denial 0 / approval 1 effects | Same; unconfirmed recipient approval refused, normal row confirmation required |
| Actual player Play/Resume/tick, five busy states | 45 checks, 17 failed; every busy Play opened and started the transport | 45 checks, 0 failed; every busy Play opened/started 0 times |
| Catch-up aggregate | `CATCH_UP_FAILED`, exit 1 | `CATCH_UP_OK`, exit 0 |

Only the ordinary turn/model choice, final mail effect, file transport and activity snapshot are scripted. Actual Library admission, handoff, session persistence, prompt builders, tool registry/executor, action orchestrator and approval broker/card are native product code. The test asserts no effect before a decision, no effect after denial and exactly one after approval. It does not send mail or prove a model selected the right action. Playback substitutes a recorder instead of starting a physical device.

`verify-slot.sh` is the one-time RED-to-fixed orchestration used here, not a command to run on an already fixed tree. `apply-fix.py` records the repair applied only after both original regressions report FAILED. Both debug builds and the six requested flags run serially under one normal `heavy.sh` FIFO/resource slot with `swift build -j 2`. Environment: macOS 27.2 / 26B5091g, arm64 Mac15,12, 16 GiB. Original build 363.94 s; fixed 109.13 s. These are build durations, not product speed evidence.

## Retained failed first fixture

`initial-fixture/` contains all first-slot logs, source/binary pins and the exact earlier fixture (`c8d5188d…`). Its Library task omitted the required schedule ID, so the offer never reached Live (`turns=0`). Its positive send correctly stayed blocked at an unconfirmed recipient. Both original and fixed aggregate FAILED; this is not full handoff proof. Playback alone reproduced 17 failures and passed all 45 fixed checks. The corrected fixture adds the real schedule identity and normal recipient row confirmation, asserts actual Library admission and reruns both original/fixed sides. No production permission contract or expected outcome was weakened.

Requested flag results and remaining contracts are in [RESULT.md](../../../RESULT.md). Raw stdout and `--selftest-out` mirror logs are both retained: some final root markers are emitted only to the mirror. Store isolation's known inherited nested browser `TOOLLOOP_PRODUCTION_FAILED` must not be treated as a production-tool-loop pass; duplex diagnostics remain visible.
