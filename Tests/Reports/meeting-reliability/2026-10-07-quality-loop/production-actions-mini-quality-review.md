# Six actual production windows: Mini

FAIL: five of six actual production calls return malformed JSON without the last object
brace despite finishByLimit=false. The remaining valid object repeats schema placeholders
as topics/unresolved items. All six action lists are empty, including the genuine future
follow-up whose three references are present in the actual prompt. A malformed empty
action list cannot count as a successful negative classification.

Actual isolated ingestion, extractor-only preceding state, production refinement,
application/save/fresh readback ran. Original inference snapshots were not saved, so
these reproduce real source windows rather than exact original model state. No expected
labels or target instructions enter the model prompt. Cutoff uses actual retained
segment-end clock; reference visibility is explicitly recorded in native markers.

Wall 23.81 s, six calls and six captured completions. Canonical sources/model roles/owner
files unchanged during these tests. Source/citation/schema and meaning are separate gates.
