# Safe metadata root and actual first Settings initialization

**SOURCE-ONLY REVIEW CONTRACT / NO EXECUTABLE COMMON / NOT QUALIFIED.** This adds the previously missing original-run isolation prerequisites to the Notes and one-line Settings proposals. No source modification, compilation, model metadata/weight/default access, app/native run, install or owner quit occurred. Root retains those sole slots. Existing 5 ms lifecycle failure, original full-process crash and parent readiness gates remain open.

## Concrete existing seams

- `Settings.init` owns the unnecessary eager availability evaluation. Its proposed sole FIXED change remains `meetingsDiarize = diarizeChoice ?? MeetingDiarizer.isDownloaded` (settings-producer-remedy-review manifest ba902be8…). No new producer helper or constructor bypass is needed.
- `MeetingDiarizer.isDownloaded` already selects a copied temporary filesystem root for its exact diarization diagnostic, then uses actual required-file checks and partial-file enumeration. A SAME COMMON Notes-only root-selection branch at that existing seam is a feasible place to confine the original eager evaluation. This is metadata routing for an unused diarizer, not a new diarizer/native owner.
- Actual Settings construction already uses the existing `SelfTestHarnessDefaults.suite` per-process domain. Seed it before touching Settings.shared. Calling chooseDiarization to seed is too late, as it requires singleton construction.
- The standalone native entry occurs before NextNotesApp.main, and runStandalone dispatches validation before NSApplication.shared/AppDelegate. Extend that existing dispatch rather than constructing extra app/controller owners.

## Exact proposed admission and filesystem contract

Proposed additive SAME COMMON selector: `--native-notes-settings-case` with exactly one of `stored-on`, `stored-off`, `automatic-missing`, `notes-active-off`, paired with the already supplied `--native-termination-model` copied public artifact. These are proposed grammar values, not implemented flags. SelfTest.requested's allowlist and exclusive-mode validation must be updated identically before both producers. Reject missing/duplicate/extra flags, mixed startup/recording/other-llama/background cases, wrong values and unbound output/timeouts before owners. Settings-only cases do not require loading weights; model-source identity/pinned-input preparation remains the serial owner's contract and is not inferred from file size.

Use a pure immutable Sendable admission value containing mode, canonical copied model URL/direct temporary UUID root, output URL and its existing empty `settings-availability` child directory. It holds only values, no Tasks, stores or native owners. A `nonisolated static let Result<Admission, Error>` on the diagnostic can provide the same already validated value to the nonisolated availability getter, forced by standalone validation before AppKit. Its initialization must not recurse through SelfTest.requested validation; SelfTest's flag parser only reads grammar, while admission evaluates after requested is settled. Exact Swift 6 type/isolation compilation is UNRUN.

Require raw/standardized/resolved model and directory paths to agree; direct canonical temp parent and exact UUID prefix/filename; no symlink/nonregular parent or file; the metadata child is a real empty directory created only by the serial fixture preparation. No mock CoreML binaries, placeholders, invented downloaded model or owner asset copy is justified. Validate directory metadata/emptiness and its parent binding before creating any Settings/AppKit/private Notes owner. Keep known input/output paths within that copied fixture root and refuse conflicting/mixed fields. No supplied path is logged on refusal. Revalidation checks passive fixture identity; it is not atomic cross-process filesystem CAS. Concurrent mutation invalidates the qualification and must not be treated as a valid input.

At `MeetingDiarizer.isDownloaded` root selection, preserve the existing real diarization case first; reject mode mixing in pre-owner bootstrap. If the raw Notes settings selector is present, use only the admitted child directory. Invalid requested-mode admission returns refusal/INVALID through the fixture and can NEVER fall through to ordinary modelsRoot. Outside this exact Notes settings selector, keep the existing ordinary/diarization routes byte-identical. The getter's existing actual `fileExists` checks now see real absent required paths inside the admitted empty directory and return false. This is a genuine empty-filesystem availability result; it proves no native diarizer or model load. The candidate's explicit stored-on must nevertheless remain true, while stored-off remains false.

## Actual initializer observation and fresh processes

Install a nil-default, bounded scalar observer only at the actual Settings.init availability RHS evaluation before first singleton access. Settings is MainActor-isolated; callback configuration and the inline observed RHS execute on that same actor. No MainActor.assumeIsolated, nonisolated unsafe mutable global or actor hop is justified. The nonisolated MeetingDiarizer getter reads only the immutable admission value; it does not reach mutable MainActor trace state. This avoids changing its cross-executor production signature. The callback must not return a availability Bool, fake a filesystem result, save preferences, await, sleep, enqueue work or own a model. It records RHS entry count only. Default nil leaves ordinary production work unchanged.

The same observed RHS must be present in ORIGINAL eager call and FIXED lazy nil-coalescing expression; only evaluation placement under the existing producer varies. A direct helper expression passing or observer without production-call-site entry is insufficient. The actual `Settings.shared` singleton must be initialized once per fresh owned subprocess, not reset/reconstructed and not replaced by an injected Settings clone. Use the actual isolated suite's stored key and assert actual settings properties/domain ownership after construction.

| Fresh case | Existing suite preparation before actual init | ORIGINAL RHS count | FIXED RHS count | Actual resolved value |
| --- | --- | --- | --- | --- |
| stored-on | true | 1 | 0 | true |
| stored-off | false | 1 | 0 | false |
| automatic-missing | key absent | 1 | 1 | false from actual confined empty-root checks |
| notes-active-off | false | 1 | 0 | false, then real Notes native/Cocoa flow |

These counts are **required assertions**, not executed results. Settings-only modes may produce their dedicated verdict and exit before explicit NSApplication/AppDelegate or any model/Notes operation is admitted. Actual Settings initialization itself calls existing AppKit-derived geometry readers, so it is not a headless/pure-helper proof and that environment must be suitable. notes-active-off continues through the actual private Notes fixture after the scalar/property checks. No fixed sleep, sequential model pass or turn-path change belongs in this diagnostic.

A mistyped stored value can be an additional fresh-process boundary control if required, with the actual UserDefaults `as? Bool` conversion exercised. The existing onboarding cases already cover nil/model-present answer semantics; their helper-only assertions do not prove constructor laziness or first-touch ordering. Copied public diarization assets are needed for a true-filesystem availability case; this contract intentionally supplies no such fake or model load and claims only actual absent-filesystem routing.

## Retained Notes operation and actual exit

Continue using a previously empty private NotesService, exactly one admitted synthetic meeting UUID/summarize call, explicit nonnil real provider bound to private NotesRuntime and the existing disabled retrieval assembler. Configure the existing confined native model override before countTokens/generation. Do not call LlamaLLMProvider.unavailableReason as a readiness substitute; its ModelSpec.fileURL-based availability is a separate unconfined route. Saved selection remains refused under the exact selftest.

At actual Cocoa entry require one service-owned Task and prior successful actual decode plus outstanding actual decode bracket. The existing synchronous beginTermination captures that sole Task and closes admission; App's existing captured-array Task.value loop joins it before runtime.finishTermination and the final vote. No new getter/map/repeated await is justified. Natural RunLoop handoff may miss decode overlap; that is INVALID and cannot be repaired with a parked native call, sleep, simulated event or timing-based pass.

The readonly proposed didVote callback observes actual realDrained/actualAllowExit immediately before the existing sender.reply; real `drained &&` short-circuit must not erase false-drain evidence. Preserve true-drain AND every veto, one-shot same terminationTask recheck and a second actual Cocoa proposal/receipt when testing deliberate veto. No diagnostic promotes false real drain. No second captured-task await or replacement Notes pass is added by safetyDrain. An original lacking the existing join still requires a separately qualified safe cleanup; this Settings isolation contract does not grant that run or repair broader native ownership.

## Readiness and remaining prerequisites

**Ready for root design review:** one-line producer patch; existing preference domain and initialization seam; real temporary metadata root route; exact fresh-singleton cases; retained sole Notes operation contract; existing copied-GGUF native override; real Cocoa vote observations.

**Still required before execution or readiness claims:**

1. Root approval of exact COMMON grammar/admission/root-selection/observer patch and responsible producer preimages. No concrete COMMON Swift patch or compile verdict is supplied here.
2. Swift 6 compilation/isolation proof for immutable admission, MainActor observer and unchanged getter signatures; preserve existing native parser/other-mode behavior.
3. Root-created confined empty metadata directory/public copied model/output, actual artifact identity and passive no-mutation controls. This thread creates/reads no fixture/model/defaults assets.
4. Actual fresh subprocess ORIGINAL/FIXED initializer evidence with identical COMMON and the original stored-off Notes bootstrap route, no owner metadata fallback. Invalid input refusal must be tested before owners; a missing confinement check is not a pass.
5. Actual one-task Notes native overlap, native return, first/final Cocoa votes, resumable private files and ordinary related settings/onboarding/isolation/native checks. Preserve logs/crashes; source review cannot predict producer RED/PASS.
6. Separate Manager-native, Capture entered-ASR/physical cessation, speech preparation/output, all-owner original-crash and fast-quit gates remain open. No installed app or owner quit is included.
