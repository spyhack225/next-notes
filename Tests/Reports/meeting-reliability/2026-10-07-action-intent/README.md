# Live meeting action citation and confidence producer

The 7 October Zoom audit saved three explanatory discussion candidates with `high`
confidence. Actual `ModelCompleter.parse` and `MeetingContextReconciler.apply` replay
reproduces that value: each hard-coded high confidence after matching transcript text.
Quote provenance is not semantic classification confidence. The selected model already
receives instructions not to treat discussion/speculation/generic notes as actions.

The same producer also allowed a missing or invalid segment index to select the first
matching quote. Identical microphone and system speech could therefore borrow the first
track's source. The shared evidence matcher permits content-token LCS; that is not this
producer's promised verbatim contiguous citation contract.

The bounded repair uses existing `inferredConfidence` for model-written candidate meaning
and copied action items (including model wording rewrites), requires the valid cited segment, keeps the original spoken span,
and rejects ambiguous clock-free application. Paired outer quotation notation is accepted;
spoken words are never rewritten. Existing microphone/system metadata, explicit user
approval, and inferred implicit commitments remain intact. There is no additional model
pass, queue, store, timer or delay.

An unchanged lightweight Swift probe extracts actual parse/apply/rewrite functions and
uses the production context/transcript types and evidence matcher. Thirteen checks fail eight
before repair and zero afterward. It reads the three actual saved candidates privately;
none of their speech appears in this report. The candidates remain present with inferred
confidence: **semantic false-positive detection is not fixed by this change**. A real
implicit budget commitment stays present and remains system-source, not authorization.

The probe isolates pure production functions; its unrelated topic merge is stubbed and
it does not prove native model classification, real context-store persistence, live cards,
or acoustic behavior. Focused generic assertions were added to the existing reconcile
selftest for coordinated optimized native verification. Native verdict is pending.

The task patch is relative to the initial working file and excludes previously present
foreign resource-admission changes. Root must integrate only these owned hunks. The
original/current pins and logs are retained here; private fixtures and probe source stay
in temporary diagnostics until root preserves needed evidence and coordinates cleanup.

The disjoint native replay compares the unchanged existing system prompt with an
experimental typed temporal/intent schema on three private false-candidate neighborhoods
and the real future follow-up neighborhood. It runs one existing provider call per
variant/case, records duration/finish/citation and category, and retains raw outputs only
in private diagnostics. These are post-hoc copied neighborhoods, not exact original
reconcile snapshots: the original live snapshot/context was not saved. No new production
semantic schema or model default is promoted. Actual native model verdict is pending.

## Native targeted classifier result and diagnostic correction

The coordinated optimized native targeted replay fails three typed fixture checks.
Raw first-object inspection additionally confirms that the real future follow-up is
classified as discussion: this semantic miss survives separately from quote/format
failures. Three typed responses copy the evidence placeholder, and all four append
input text. Existing responses abstain for every target, so this experiment reproduces
neither the original descriptive false positives nor positive follow-up recall.

Historical `parsedValid` in the existing variant meant JSON object decoding only.
Two outputs have string-valued topics and fail the actual production array schema;
valid empty suggestions also return nil from `parse`, so that nil cannot distinguish
malformed payload from no refinements. Historical metadata now carries this exact scope.
The diagnostic adds a SelfTest-only helper reusing the actual ModelPayload decoder and
separates wireValid, productionParsed, producedSuggestion, typedParsed, target-row counts
and citation counts. It changes no production classification, storage or provider path.
This diagnostic follow-up awaits root's coordinated build; no compiler/model ran here.

See [the real-window acceptance plan](REAL-WINDOW-ACCEPTANCE.md) for reconstructed
production-flow evidence. Grammar/index-owned evidence is a proposed structural repair,
not a semantic fix or production classifier promotion.

The subsequent [input/output source-contract proof](source-contract/README.md) records unchanged actual-source RED11/PASS27, copied-source limitations, native pending gates and probe cleanup. This structural repair does not establish native semantic correctness.

The pre-existing shared topic/unresolved merger now has [RED58/PASS185 actual-source preservation proof](topic-merge/README.md). Native full-app acceptance remains pending; this repair does not establish model meaning quality or recover facts already erased.
