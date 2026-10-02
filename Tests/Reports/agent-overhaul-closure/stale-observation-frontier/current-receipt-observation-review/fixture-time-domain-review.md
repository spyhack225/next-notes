# Original88 extra functional failure: fixture time domains

Read-only follow-up. Original88 common fixture SHA
`e9bbd67e8fc04f8908e56c1dc932454a9f0681035e77fe20befa4f5f94e3bf3a`
and all producer/original snapshots remain unchanged. Root runs unchanged fixed89
before mounting the corrected common fixture into authoritative original90/fixed91.
No Source edit, native execution or producer fix was performed by this worker.

The actual original88 raw worker report shows150 failed assertions, including
`current receipt: source refusal/probes erased exact changed bytes or real fired evidence`
outside the predicted metadata-feature failures. Receipt diagnostics show actual
accepted completion and changed-source failed task with existing write mismatch;
that compound assertion does not identify which term failed. Original88 is not a
clean authoritative feature RED and must remain archived with this limitation.

Confirmed source/data contract: the fixture assigns `fired` from a newly constructed
reader decoding the real saved receipt. `ActionReceiptStore.save` uses
`JSONEncoder.dateEncodingStrategy = .iso8601`; `load` uses the corresponding decoder.
The writer's existing receipt cache keeps its runtime `Date` values and events
created with `Date()`. Existing rejected record rollback restores the exact prior
cached array. Consequently, whole-cache receipt equality against the decoded
snapshot spans two representations. The same mistake occurs in the CURRENT
metadata `startedAt == fired.startedAt` predicate in both accepted and changed
modes. These are three evaluated comparisons; original nil masks the latter two
inside missing-feature assertions. Unchanged fixed89 may expose all three.

The precise extra-failure attribution remains subject to the requested actual
scalar measurement; no original88 receipt timestamp values were logged. The
corrected fixture proposal adds that measurement at the SAME real fired backing
entry before its later assertions: cached and decoded startedAt scalar values,
event-time mismatch count, direct memory-vs-decoded equality and canonical existing
ISO8601 roundtrip equality. It logs no payload, arguments, result, UUID or owner data.
Canonical roundtrip equality true alongside direct equality false confirms the
representation mismatch rather than a hidden non-date difference. The retained
source trace also exposes the three original compound terms independently.

`proposed-corrected-common-fixture.swift.txt` captures BOTH the actual cached
`memoryFired` and actual decoded `fired`. It checks cached metadata timestamps
against captured memory and rollback whole receipt against captured memory;
fresh persisted receipt remains compared exactly against captured decoded receipt.
Exact changed bytes, actual source mutation, prepared UUID/binding/status/other
metadata predicates, original read/effects, task delivery/refusal, all50 assertion
sites/loops and inputs remain unchanged. No tolerance, sanitization, removal of a
field or altered producer encoding is used. The only extra operations are fixture
in-memory canonical encoding/decoding and diagnostic metadata.

The frozen corrected common fixture SHA is
`eea50f769637d7aa841aa508f9f38d47262f6e5b67d16b11da052681e4dbdae1`.
`fixture-time-domain-correction.patch` and `fixture-time-domain-manifest.json`
pin the exact change. Root must use this identical corrected fixture for BOTH new
original/fixed runs and preserve unchanged88/89 reports. Predicted corrected
normal50 and missing-feature35 remain predictions until those actual runs. If
canonical roundtrip differs, bytes change, cached rollback differs or persisted
receipt differs, investigate that independently; do not classify it as time-only.

No current receipt producer bug follows from an invalid cross-representation
fixture comparison. The current getter original/fixed snapshots remain exact;
the observation's partial/missing/effect-completeness limits remain unchanged.
