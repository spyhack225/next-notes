# Reconstructed production-window semantic acceptance

Scope: replay the existing producer flow on copied meeting data, **not the original
historical inference snapshots**. Saved candidate evidence identifies bad outcomes but
not when inference ran, its complete previous context, or the model's raw response.
Do not label this fixture exact original replay or infer a repaired model from target tests.

## Input and production seam

1. Keep copied `meeting.json` and `transcript.live.json` in a canonical physical temporary
   UUID fixture. A private human-reviewed manifest identifies three descriptive examples,
   the actual future customer follow-up, and the nearby already-completed activity.
   Retain expected ownership, no stated deadline and temporal relationships privately.
2. Walk the actual live segments in meeting-time order. Before each selected pass cutoff,
   populate the preceding context with **the actual MeetingContextExtractor.apply** over
   prior speech, preserving sources, labels, and command exclusion. Apply accepted prior
   refinements into that same context rather than seed it from the final saved context.
3. Populate `Snapshot` with that context and the actual evidence buffer. Run
   **ModelCompleter.refine**, which calls the production window/prompt/character cap and
   same recorded provider pass. Do not add target indices, target instructions, expected
   categories, reference answers or manual semantic labels to the model input.
4. Retain actual constructed prompt hashes/visible segment indices, completion shape,
   truncation, usage, and parsed action evidence privately. An expected segment can be
   omitted by the real character cap; score that as input coverage loss, not semantic
   classifier success. Never admit references to unseen segment text.
5. Exercise the isolated MeetingContextStore `runReconcileForTesting` application and
   persisted context readback on the selected failing windows. The deterministic feeder
   needs either admitted cadence or the existing safe test seam; do not seed or overwrite
   the owner's meeting/context/task stores. Exact speaker source survives application.

## Windows and assessment

Use actual segment end times for the three recorded false-candidate evidence anchors
(approximately 1553.42, 1765.22, 1775.22s) and the follow-up neighborhood ending near
1940s. Add the actual cadence-selected pass immediately before/after each anchor if
available; otherwise disclose that cutoff placement was reconstructed. Preserve the
three-minute window, newest-speech character cap and original buffer contracts.

The human manifest checks all proposals in each complete window, not only a chosen
sentence: no descriptive pricing/workflow utterance becomes a request; the future visit
and questions survive as a real follow-up; the earlier lunch stays completed; owner and
deadline remain unspecified where the transcript supplies neither. Preserve genuine
requests and implicit commitments, hypothetical/conditional discussion, denials, changes
of mind, completed work and segmented sentence continuations. Positive recall must pass;
blank or malformed outputs cannot satisfy the semantic bar.

Semantic and structural results are separate: wire JSON, real production payload decode,
no-refinements versus produced suggestion, valid cited segments, inferred confidence,
source/owner attribution, past/future correctness, actionable coverage and factual action
text. Grammar or index-owned quotation can improve structure without improving intent.
Also verify system speech cannot authorize user actions and a saved proposal is not an
accepted task. Existing approval/receipt contracts remain unchanged.

Use the same installed local model and one existing pass per window initially. No model
promotion, additional verifier pass, retry, queue or new ledger. Expand to the existing
public generic corpus for discussion/past/request/future, mixed tense, multiple speakers,
identical mic/system speech and corrections only after this real-flow baseline is visible.
Record all red verdicts, latency/prefill/generation/pass count and memory together before
comparing a proposed semantic contract. A bounded window fixture cannot prove a live
long-call soak, acoustic identity or final note completeness.
