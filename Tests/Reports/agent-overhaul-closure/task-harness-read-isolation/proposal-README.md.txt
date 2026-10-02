# Actual task harness read isolation — off-source regression, 2026-10-02

Priority producer privacy fix; optional live-tool metadata remains deferred.
No Sources, AGENTS, roadmap/index, native app, model or process changed/run by
this delegation. Root owns native verification and default-branch source proof.
Transport child's serial original44/fixed45 slot remains untouched.

## Confirmed cause and consumer

AgentTaskStore.load lines 122–133 checks SelfTest AND denied harness persistence,
then nonetheless calls compatibilityData and decodes owner/default JSON as either
legacy task array or tagged export. The gate prevented SQL migration/writes, but
did NOT prevent reading or returning private task contents.

Fresh AgentTaskManager.init calls that actual load and assigns returned tasks.
Its restart loop leaves completed rows unchanged. AgentView uses the shared
manager, includes task history, and renders objective/result as Text. Thus the
same denied source supplies displayable private fields; a correct no-write result
does not establish read privacy. UI rendering has not been driven in this review.

## Smallest source correction, unapplied

denied-harness-producer.patch replaces decoding inside the EXISTING denied branch
with its existing failedLoad=false followed by return []. It changes no production
reader, admitted temporary migration/SQL/export, writer policy or persistence schema.
No new Data override/mock/I/O helper, store, gate, async hop or timer is introduced.
No reset of expectedAuthority/expectedIdentity is proposed; none is required to
keep this denied path from reading.

For DEFAULT construction, injectedFileURL is nil. allowsHarnessPersistence returns
false at its first guard, before evaluating storageURL or lazy mirror. The new
early return therefore precedes compatibilityData AND default owner path resolution.
TaskStore constructor itself only assigns fileURL; database open/create occurs
in later methods. Root must verify this order against final integrated source.

## Actual unchanged-source regression

TaskHarnessReadIsolationSelfTest.swift.txt is proposed NEW
Sources/NextNotes/Agent/Tasks/Durable/TaskHarnessReadIsolationSelfTest.swift.
fixture-registration.patch adds ONE synchronous call to existing worker-attempt
run; no new app registry/API scaffold is needed. SAME fixture compiles against
original and corrected producer.

The fixture requires SelfTest and an explicit resolved temporary root before
any write. It creates one uniquely named child, writes SYNTHETIC confidential
objective/result/argument canaries, and deletes only that child. It never obtains
owner storageURL, reads/snapshots owner files, seeds an owner path or constructs
shared/default Manager/TaskStore. Failure strings contain generic labels only,
never task payloads.

Denied branch injection uses an actual TaskStore constructed with a unique
non-file URL (nextnotes-denied-fixture scheme). Constructor source confirms no
open/create/read/write. The fixture asserts non-file mirror URL and denied harness
eligibility BEFORE invoking actual store/Manager. It NEVER calls an opening method
on that mirror. Its JSON file is a real safe temporary file; there is no fake Data
producer or read override. Injected URL never falls back to owner's file.

Cases:

- Real legacy array canary through actual Store.load then fresh Manager. Original
  exposes private fields; fixed expects empty source and empty actual consumer.
  This is the original privacy failure, not a nil getter/missing-feature scaffold.
- Corrupt, missing and directory-instead-of-file safe paths must bypass decoding,
  preserve bytes/location and provide no history-read failure or repair eligibility.
  Denied existing save remains refused. No SQL mirror method is invoked.
- Admitted control uses BOTH real injected safe-temp JSON and SQLite. Actual import,
  primary authority, save/export and fresh Manager preserve the terminal control
  row and exact synthetic result, with no worker dispatch.
- Tagged denied canary copies that REAL versioned export. Original branch exposes
  its row too; fixed returns empty, preserving tagged bytes and allowed SQL history.
  No private envelope schema is duplicated in a test helper.

Assertions include actual raw fields reachable by the real Manager consumer.
No native/red/fixed verdict has run here; root must capture safe original failure
and unchanged corrected evidence. DO NOT launch the original ordinary app/default
UI to get RED: its unrelated startup could read the owner's actual task file before
this isolated fixture starts. Root must choose an isolated original execution that
constructs ONLY these supplied stores/managers, then validate fixed default order
before any normal installed harness run.

## Evidence and limits

source-inputs.json pins six actual producers/consumer/registration files.
static-validation.json records exact in-process reconstruction/hash checks only;
no shell/git apply/compiler/native execution occurred. proposal-hashes.json freezes
artifacts. Root must recheck ownership and ordinary apply/compile checks in its slot.

This closes only the harness task reader bug once verified. No encryption, general
store sandbox, external effects, recovery/retry, remote host, model quality or whole
Agent readiness claim follows. Existing admitted read/write quality and fixed
quick/full/owner/privacy/permission/latency gates remain required. Existing owner
isolation checks watch mutations; they alone cannot prove an owner READ never
happened. The actual canary consumer test plus default source-order proof are the
relevant missing evidence. Parent phases and IM-16 remain open.
