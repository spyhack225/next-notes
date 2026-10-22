# MR-03a: model-verification transient memory

## Confirmed producer and fix

`ModelDownloader.sha256(of:)` streams a model in 4 MiB chunks, but Foundation's
`FileHandle.read(upToCount:)` can leave autoreleased backing objects alive until the
caller's surrounding pool drains. A chunk-sized Swift `Data` variable therefore
did not guarantee chunk-sized retained memory. The actual prior producer, called
inside one surrounding pool on a detached utility task, retained approximately the
entire 1,561,318,368-byte selected model during verification.

The producer now drains an autorelease pool around each existing read/hash chunk.
The 4 MiB read size, incremental CryptoKit state, entry/per-chunk/EOF cancellation
checks, thrown open/read errors and deferred file close remain unchanged. No new
queue, model pass, owner preference or stored model selection was added.

## Focused before/after evidence

Same read-only MiniCPM5-2B-Q4_K_M model, separate fresh optimized standalone
processes, Mach task RSS and physical-footprint sampling every 5 ms. The standalone
extracts the current function from the production source; its before function is
the exact prior producer. Native models were not loaded by this probe.

Expected and observed digest in both arms:
`ec2d5801640099e97d8d7e8003ad4d81f336e757811f03a26173dddf386602fd`.

| Measurement | Prior producer | Current producer |
| --- | ---: | ---: |
| Baseline physical footprint | 2,015,640 B | 2,015,640 B |
| Sampled peak physical footprint | 1,570,473,448 B | 7,586,224 B |
| Physical footprint at hash completion, before caller pool drains | 1,570,473,448 B | 7,569,840 B |
| Sampled peak RSS | 739,557,376 B | 12,206,080 B |
| Physical footprint after caller pool drains | 273,040,008 B | 7,586,224 B |
| Wall time | 10.486 s | 0.622 s |
| Process CPU | 1.188 s | 0.624 s |
| Samples | 2,100 | 128 |

Peak footprint fell by 1,562,887,224 bytes (99.5%). Physical footprint includes
compressed process allocation accounting and differs from resident memory. The
first fixed candidate run independently measured a 7,602,608-byte peak and the
same digest. Timing is descriptive: the before run warmed filesystem pages and
system resource conditions differed, so these runs do not establish a controlled
speed improvement.

The exact old/current source probes also passed 12 contract checks: independently
pinned empty/`abc` SHA-256 values, missing-file and directory-read errors, cancellation
before hashing and cancellation during a large-file hash, for both arms.
Compilation of the probe also passed in Swift 6 mode.

## Scope and production-consumer verification

This establishes a transient verification allocation, rather than a persistent
native-model allocation. Normal comparison configuration hashing uses this
producer before native model loading; that comparison's large pre-load footprint
must therefore be remeasured after the fix. Its ASR-stage footprint decrease must
not be interpreted as native ASR releasing that entire allocation.

This does **not** attribute the owner's earlier meeting's approximately 1.9 GiB
lifetime RSS peak to verification: the historical log contains no allocation trace
or overlapping hash span that proves that connection. It also does not prove lower
steady capture RSS, native model memory, whole audio-chain capacity, or a physical
long-meeting envelope.

The existing installed `--selftest-model-library` exercises the actual
`ModelDownloader` → `VerifiedModelArtifact` consumers, mismatching and matching
existing artifacts, partial promotion and cancellation preserving resumable bytes.
The rebuilt signed app (`install-22324`) passed that actual consumer flag with
`MODEL_LIBRARY_OK`; its isolated matching, mismatch and cancellation flows therefore
remain intact. The signed normal comparison rerun remains open and is not credited
by this standalone result.

## Reproduction artifact

`sha256-memory-probe/run.py <read-only model path>` compiles the exact old and
current producer, runs each in its own process, then runs the contract checks.
It writes generated compiler files only into a temporary directory and does not
read owner model-library/preferences data or modify the supplied model. The old
arm intentionally reproduces model-sized transient allocation; use suitable
headroom before running it.
