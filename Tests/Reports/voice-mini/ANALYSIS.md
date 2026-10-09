# Resident Mini voice investigation

The producer mismatch is confirmed in source and retained native output: listen2's
resident check covers optional partial preparation, while the committed native
stream still calls `loadIfNeeded`. First counted final Mini answer is cold, has
no final token counts, and reaches the unchanged 25-second response deadline.

The exact per-turn endpoint-to-routeDone median is 4.343 seconds in final Mini,
versus 1.125 seconds in the route-only Apple arm (the approximate difference of
headline medians is not a median of per-turn stage differences). Before Mini
prefill, five warm Mini answers already have a 4.175-second route median. The
first final slow route collects while Mini is absent and prefill is skipped;
only after its validated route does required answer loading begin. Concurrent
prefill cannot be the sole explanation of all slow routing.

Routing is a separate Apple Foundation Models typed `LocalVoiceRoute` session.
Its complete `collect()` precedes the canonical payload validator, which is
synchronous and cannot wait for Mini answering. Split routing acquires no llama
compute ticket. Mini preparation and sampling use the existing native context
reservation and realtime compute ticket; physical memory/CPU/GPU/service
contention is possible, but neither a retained machine load snapshot nor a
resident-weights label establishes the CPU/GPU/ANE cause.

Retained authored counted answer rows: Mini-before warm5/cold0, final Mini
warm4/cold1, with one unavailable final count. These are two n5 diagnostic
sequences, not normal-use residency probabilities. No retained model.unload
rows are available in these stdout archives; this is unavailable eviction
coverage, not zero observed owner evictions. Owner stores are excluded by the
shared rules. The exact metadata-only source hashes and per-generation traces
are in retained-analysis.json.

The rejected single-decision experiment is read: variant schema fixed a flat
schema defect, yet native routing remained single12/15 versus split13/15 and
history replay failed; no latency pair justified adoption. A cheap rule gate
cannot independently preserve task/approval/address/history semantics. Moving
the route to Mini requires a separate native corpus and history acceptance;
unchanged validation alone proves shape, not correct intent. This experiment
keeps the complete validated Apple split route and existing partial reuse. No
new route model pass, rule bypass, shortened prompt or sampler is justified by
the current evidence.

Planned bounded repair: diagnostic resident-only committed stream admission,
checked before and after the existing native reservation/lane wait. Absence or
inadequate already-created context falls back before any native text to Apple
Foundation Models. Decode, protocol and cancellation errors must propagate,
never repeat a partially delivered answer through a different model. Exact
answer identity must reach the existing usage summary.

Owner TTS rule is separate from the Apple language model. The native harness
must install prepared Pocket with a silent failure backing, never the existing
Apple synthesizer. The approved pipeline harness exception is relay message
40d1dd82-c3a7-461e-8fc7-c62cf13c5fdc. A recording Apple spy exercises the original
fallback consumer for RED without rendering or playing Apple audio.
