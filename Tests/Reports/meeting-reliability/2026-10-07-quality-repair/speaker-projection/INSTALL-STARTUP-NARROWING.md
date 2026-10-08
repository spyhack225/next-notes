# Installed baseline startup/termination narrowing — 8 October 2026

No introduced normal-startup or termination blocker was found in this review. This narrows the release concern; it does not accept the entire current candidate or prove every changed subsystem safe.

The installed receipt pins executable ed67302fae3c246bbfc377be77e954a0070f17b3b4c5771cfe5e1a04e0d628ad, tested install30744, with normal owner data and original meeting files unchanged. The associated coverage-build source pins contain1159 files. The current seventh compiler4 manifest contains1176:1119 baseline files match,40 existing files differ,17 new meeting sources are present. A dirty comparison to Git HEAD is not the installed comparison. [Exact metadata/file list](INSTALL-STARTUP-NARROWING.json).

## Exact App comparison

A retained NextNotesApp-before-local-probe.swift cache file hashes to f0ef16e76b76b70397ecf89f40ba5811e20a3ed373f1f61e57da9444948c33c0, exactly the installed-associated source pin. Current App hashes4a34f4bb59b9cf690b8bcf006a29d17f3254ad5eb6ef814993c4bedfeeaa8ce8.

Four substantial ranges compare byte-identically, with independent range hashes retained: entry point/App construction before SelfTest; applicationDidFinishLaunching through the selftest runner boundary; applicationShouldTerminate through applicationWillTerminate; and applicationWillTerminate through the next HUD method. Thus the normal SwiftUI owners, startup task restoration, interrupted-meeting recovery/resumption, role repair, opt-in pruning, warmup, calendar/agent startup and recording-aware native shutdown are existing installed-associated behavior. No new user-task migration, deletion, startup replay or broader shutdown ownership is introduced by the current App delta.

Changed App hunks are explicit participant diagnostic preflight, meeting/selftest routes and private diagnostic logging. Normal launches supply none of those flags. The new optional bounded-audio/pause paths retain explicit SelfTest/modifier admission; their current acceptance remains root-owned. Existing non-selftest live diagnostic flags can read/write real owner state according to their contracts, but their entry/admission is unchanged in this exact comparison.

## Runtime and stored-history distinction

ActionRuntime, AgentTaskManager, AgentTaskStore, durable TaskStore/schema/authority fixture and ActionReceiptSourceObservation exactly match installed-associated pins. EmbeddingRuntime, ModelRuntimeManager, MetricsStore and LatencyTrace also match. No new task/receipt format or admission change is established by a dirty HEAD diff of these files.

NotesModelRuntime does differ: installed-associated b7242913… versus current9d872a3d…. The exact b724 source body was not found among the retained runtime files searched, so a complete installed-runtime diff is unresolved. Do not substitute Git HEAD or claim hash equality. The closest independently pinned retained210a4ae7… source matches the fourth/fifth candidate manifests; current differs from it only by35 added completion-phase instrumentation lines. They time context/prefill/first-token/no-token through the existing metric sink, add no awaited dependency/model pass, and contain no task/receipt persistence call. The metric sink can persist diagnostic metadata; absence of latency impact has not been measured by this source review. Existing native phase evidence records originalRED4/fixedPASS in a private S1 CPU fixture, not owner speed/quality acceptance.

Current ordinary model calls still use required completion; optional meeting refinement calls the existing local optional-completion seam and checks pressure/cancellation. That affects optional model work, not task-ledger authority. Runtime beginTermination/finishTermination operate on native loading/reservation handles and close no task store. Parent must retain its separate runtime/default-off/functional acceptance; this review identifies no concrete new ledger-migration failure.

## Release limits

Source hash/range parity is strong evidence about unchanged code, not a reproducible binary-to-source proof or a physical normal launch/shutdown test of the new candidate. The retained install record associates the source build and tested executable; it does not attest every foreign working-file author or provide an original runtime body. User-ledger files were not read, seeded or migrated in this review. No builds, launches, compiler/model calls, provider interaction, canonical writes or permission flow occurred. No all-agent acknowledgement is inferred from an unanswered relay request.

Concrete release work remains: complete the already coordinated coherent candidate build, verify unchanged source pins and required functional/isolation/default-off checks, retain rollback, and observe its normal owner launch/history. The existing startup/termination code and unchanged task/receipt source hashes are not themselves a new blocker. Neither an untested changed subsystem nor a missing runtime preimage is a pass; parent owns their narrower evidence and final install decision.
