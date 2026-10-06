# P2-02 preparation measurement scope — 2026-10-06

Confirmed validator cause: L1 is voice onset to speculative preparation. After
b6a3a22 made --voice-no-speculation effective, both actual five-turn native arms
failed only `L1: expected 5 measurements, got 0`. Zero preparation measurements is
the required result in this explicit mode, not missing endpoint/answer/playback data.

The existing aggregation now requires L1 count0 only for disabled speculation;
configured L1 and L2/L3 still require every requested run. No zero timestamps are
invented. Unexpected preparation in disabled mode fails the same count check.

Original five-turn rows fail the old L1 expectation. The unchanged WAV/five-turn
fixed experiment has L1 n0 and L2/L3 n5 with no L1 failure; its whole native flag
still FAILS a separately observed 200ms main-actor stall against100ms. Four of
five final flags PASS (overlap lifecycle, instrumentation, metrics, isolation;
21 owner files/32 defaults unchanged). No broad latency pass is claimed.

The overlap experiment is WITHHELD and its three Sources restored to committed
production. Earlier complete observations had median transcript-to-first-text
3.663s sequential /3.528s overlap, but first audio4.876s /5.628s; both whole flags
were L1-rejected. This is not an adopted speed improvement. Native routing retains
the same two calendar failures; production remains sequential.

Final delivery retains only this two-line aggregation correction. Its staged
binary passes --selftest-voice-latency --voice-latency-instrumentation; earlier
native/metrics/isolation results are retained with actual limits. All child
processes and owned temp roots joined/removed; model/index claims are released.

Raw/source/withheld provenance: ~/Library/Caches/NextNotesBuild/integration/
p2-split-overlapped-current/. Delivery verification: ../p2-listen-scope/.
Next: single streamed full decision and strict cached Pocket preparation.
P2 latency, full duplex acceptance, model/default and parent-roadmap gates remain open.
