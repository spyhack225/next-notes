# Meeting quality and performance: next verified increments

The owner’s 40m05 Zoom recording remained responsive. Whole-meeting factual coverage, action intent and correct speaker identity remain open. The original memory crash and subsequent note-inference resource stops are separate failures. No new candidate is installed by this report.

| Increment | Evidence available | Remaining acceptance |
|---|---|---|
| Bounded saved audio | Original/fixed 40m05 ordered PCM and saved source-time projections agree; held incremental footprint 156,254,352 versus 2,261,016 bytes | Native ASR, global diarizer, real store/Session, IO amplification and reference ASR/voice workload |
| Quiet pause boundaries | Same 174 component assertions: original fails 30, fixed passes all | Native words, analog noise, independent clips and full workload; exact SelfTest opt-in only |
| Participant observations | Exact walker/selector component original fails 6 of 11; fixed passes 11 | Actual AX capture/private writer, call association and physical Zoom/Meet observation; a roster cannot establish voice identity |
| Live context arrival order | Session inserts by speech time while context uses an append-only suffix; bus later appends older speech | Unchanged original/fixed actual producer regression, exactly-once context/reader behavior and native integration |
| Notes memory and semantic coverage | Two reviewed inference attempts stop at guards without a completed reply; historical complete whole/mapped replies lose material facts | Attribute native allocation at context/batch boundary before further inference; then unchanged factual/tense/owner criteria and independent controls |

## Native memory observations

The reviewed 55/50 reported-free profile joins after 14.814 seconds without a result. A separately reviewed 55/40 profile joins after 11.390 seconds, also without a result. Neither proves semantic improvement or a native allocation cause. Do not lower another percentage threshold or automatically repeat these runs.

During the attributed attempt, sampled wired memory rises about 2.414 GB and compressor occupation about 1.216 GB while the app’s sampled physical footprint stays around 854 MB and RSS reaches 2.416 GB. Swap used remains 7,822.94 MB and swapouts remain unchanged in the retained frames. These are different accounting measures; concurrent machine growth is not causal app/Metal attribution. The reported free percentage is not a byte allowance.

The actual runtime sets n_batch to 512 while every scheduled prompt decode is at most 128 tokens; n_ubatch is left at the linked library default. Explicit matching capacity is a diagnostic hypothesis. Effective native defaults, allocated buffers, numerical/output parity and voice throughput must be measured before changing shared defaults.

## Execution and integration

Keep each source owner disjoint and use the existing single heavy-test window. All pause2 original/fixed compiler/run children are joined and root heavy is released. The short Source7 gap admits only reviewed source hunks; component evidence does not enable unproved recording, model or prompt defaults. Preserve exact original failures, corrected fixture glue and native refusals. Raw owner speech stays private. Share metadata and findings through agent-relay and preserve foreign staged changes.
