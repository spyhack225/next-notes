# UX-03 / P6-04a-3: typed folder input UI review

Current status: two static reviewers accept conditional scoped AgentView integration.
Native before/after execution and physical picker acceptance remain open. This UI
tree performed no Source/build/native/model/index mutation.

Packet: memory worktree's
`.agent-overhaul-memory/p6-04a-3-directory-input-preparation`.
Manifest `567f38b0e64421c13cbd7cf624c62f6a8f390522931f288c9030e90a3388cc10`
matches all27 retained artifact pins, independently verified with zero mismatches.
No active AgentView writer remains in our UI subtree; historical UX02/03/04
ownership is this root, currently held. Runtime root owns serial integration.

| Artifact | SHA256 |
| --- | --- |
| Original/current AgentView | `d93f1d799a39e9e292849cec3628d29213d9f13a288535ac6d9e1004c153eb02` |
| COMMON AgentView | `c16893fbcc14e549420f4b4ba6af9aed2422f6cac97cd9bce3b244c4e2ab189c` |
| Fixed AgentView | `e16690c46235dfe28d69d03351928e4f4b3f2746472bb35815e9976b3c63fc85` |
| COMMON patch | `58dbaa0a006a3866bfd2c7b6c15fde72f2aeadf2bd1ba181b0a32c40064b9c3c` |
| Producer patch | `1f22afce9206abcd2b679b4a8cb430d617753af1f3f2363bb19398a13565fd15` |
| COMMON/fixed directory fixture | `75ecce81f47e2767c3e93ad8ece9b4c81aee346d7cf541edd277c0fa6ede811e` |

## Producer and UI contract

The original Builder treats the missing `filesystem.tree/path` as a file question,
and the existing picker permits only files. Fixed Builder emits a factual folder
kind and “Which folder?” for that exact tool/parameter; `filesystem.read/path`
remains a file. Manager binds the retained question and validates an existing
directory before its existing answer admission. Enum compatibility remains strict:
old raw values are unchanged, unknown values refuse decoding, and no second task
store or pending-question schema is introduced. These producer hunks remain owned
by runtime root and the worker.

COMMON AgentView extracts the exact existing panel configuration into
configureInputPanel, called by the existing chooseInputFile route. Fixed inputCard
and picker consume the actual Manager.inputField kind; UI infers no tool or role
from text. Folder requests say “Choose folder”/“Choose another folder,” with prompt
“List,” directories true, files false and multiple false. File requests retain
“Read,” files true, directories false and multiple false.

The existing begin callback passes url.path to submitInputAnswer, which retains
taskID/requestID and Manager.respondInput revalidation. Cancel, retry, selected-name
copy and error handling remain. Header, model caption, composer, real stream,
source chips, task identity and DS layout are unchanged. No new confirmation,
turn-path await, timer, queue, store or UI approval authority is introduced.

## Exact scoped release and verification limits

Release only the AgentView portions of COMMON and producer patches, after runtime
root rechecks the exact current UI preimage and accepted storage/query dependencies.
The packet's Manager snapshot predates root215's storage repair; apply its bounded
relative hunks through that owner, never a whole snapshot replacement. This review
grants no Core/App/native UI/install/CUA/model/index action.

The identical fixture configures unshown NSOpenPanels through the actual helper,
and the actual restoration path supplies the retained typed field to that helper.
It never opens a panel or constructs AgentView. InputCard button rendering,
selection/cancel callbacks, TCC, focus, VoiceOver and physical picker actions remain
unverified. Prepared original26/new-feature3 and fixed60 checks are predictions
with conditional continuation counts; the real original cannot seed a fabricated
question to reach the successor. Root must retain the original producer failure
and unchanged actual missing-input/restoration/answer/executor flow.

Broader recovery/retry, remote/voice/scheduled authority, owner-positive scope,
effect reconciliation, UI accessibility/latency and UX-03/P6-04a-3 acceptance remain
open. Source admission does not complete this roadmap task.

## Root application / original222 checkpoint

Root applied the exact scoped COMMON UI and subsequently the relative producer
hunks after its storage/query proof, preserving current Manager/Bridge work.
Canonical AgentView independently matches the reviewed fixed postimage
`e16690c46235dfe28d69d03351928e4f4b3f2746472bb35815e9976b3c63fc85`.
Root's retained original222 restoration run reproduces the three target failures
across26 directory checks with original controls qualified. No continuation was
seeded into the original to bypass its absent question. Fixed223 is compiling;
this checkpoint supplies no fixed verdict or physical picker/card/TCC/focus/VoiceOver
acceptance. Runtime root retains serial Source/native/model/index ownership and
performed no installation.

## Fixed223 production verification

[Retained paired proof](../agent-overhaul-closure/p6-directory-input-production/verification.md)
now records fixed223 passing all60 reachable directory checks and full
restoration188. Original222's same fixture fails exactly three targets across26
reachable checks; no absent original question was fabricated. Only ReviewBuilder,
Manager and AgentView differ across1085 compiler inputs. The producer classifies
filesystem.tree/path as a folder and retains its exact question; the actual
Manager→SQL/receipt→FileToolExecutor continuation reads the confined indexed
directory once. Rejected tool-start admission reads zero times; rejected question
persistence creates no card or receipt and performs no read.

Twelve related flags pass. Worker223 retains a separate100ms scheduling failure:
small-history1927.571458ms, including one1834ms callback;512-row history97.773209ms.
That outlier's cause remains unconfirmed. Later225 bounded cost-repair passes do
not attribute or erase it. Owner stores/defaults remain unchanged; no installation
or owner migration occurred.

This resolves the bounded typed-field/picker-configuration/production-continuation
regression. The panel was never presented. Physical inputCard and picker rendering,
selection/cancel, grants, focus/VoiceOver, general clarification, crash/restart/retry,
latency and broader UX-03/P6-04a-3/IM-16 acceptance remain open.
