# Cached owner-metrics diagnostic — COMMON preparation

Original app99 reported two owner-guard failures. The unchanged worker rerun passed 1352 checks, as reported by root; the first anomaly remains open. No writer was attributed and no Metrics producer was changed.

Apply common-metadata-diagnostic.patch.txt only through the serial source owner. It adds one pure cached-signature formatter to the existing guard and names the two existing final snapshots in ACP post-Gate and outer worker. Both take() counts stay two, all watched files/defaults and exact failure/grant predicates remain unchanged, and no assertion is added or removed. Native/compile verification has not run for this proposal.

The emitted line uses only fixed scope labels and cached signature-component difference booleans. It never emits a path, size, timestamp, digest, owner content or grant data. unreadableOrAbsent preserves the guard’s ambiguous read failure; it is not an existence claim. Comparisons are unknown when either cached signature cannot be parsed. Neither a changed hash nor a repeat pass attributes a writer or resolves the initial failure.

Source inspection found the shared MetricsStore bound to a process temp directory through immutable SelfTest.requested; the only other constructors use the explicit latency fixture temp root. That is source evidence, not proof of the initial writer. The earlier metadata-only report samples only stat/canonical temp paths, never owner bytes. Do not exclude metrics, suppress failure, retry inside grading, change clocks, or patch MetricsStore based on a hypothesis.
