# Sixth meeting pipeline loop — 8 October 2026 UTC

The signed candidate `8d079a72` is uninstalled. Its 1,173 Sources/Resources pins are
unchanged across the 810.30 s release compilation and 819.16 s complete build.
The compiler and all diagnostic children have joined. No owner recording or model
selection was changed. The current installed executable remains `ed67302f`.

## Confirmed speaker-name save repair

The same actual original sheet callback passes the prior 51 checks but fails ten
of the extended 81 checks. It ignores rejected metadata/context saves, releases
audio after refusal, and writes a stale captured meeting, including recreating a
deleted row. The sheet now calls `MeetingDetailView.commitSpeakerNames`: read the
current row, save names, refresh context, then use the existing audio release rule
only after both saves succeed. Partial success retains accepted names and audio;
a missing meeting yields a plain failure. The same actual method, temporary stores,
context and audio, and fresh readers pass all 81 checks. Physical sheet/banner clicks
have not been observed. This is not a claimed owner incident of lost audio.

See [native regression verdict](sixth-speaker-rename-native-review.json).

## Quiet speech: producer failure reproduced, native repair pending

The independently aligned 52,566-sample input contains seven recognizable words.
The previous direct native ASR recovered all seven, whereas the actual meeting RMS
admission predicate skipped it. A new isolated Session diagnostic exercises actual
start, both capture sources, CAF writer, Stop, the same final-task handle, persisted
live/final transcripts and fresh readers. It changes no permission authority.

Original scripted mode passes 134 transport/omission checks: all four live/final x
mic/system transcript stages have zero words, with zero ASR calls. Explicit
conservative-admission scripted mode passes 138 transport checks: quiet/mixed/DC/noise
have six substituted calls each, loud four, digital zero none. These are scripted
consumer facts, not native word/noise acceptance or measured ASR cost. Every admitted
call must complete successfully and record its existing lane/compute/wall costs, so a
caught model error cannot pass a negative noise case. Both sources receive the same
short input in one burst; paced recording, source identity, ambient noise and ASR/voice
workload remain open. Ordinary production admission and pause cuts are unchanged.

See [scripted scope](sixth-quiet-session-scripted-review.json) and the predeclared
[native acceptance plan](sixth-native-acceptance-plan.json).

## Notes: first-loss evidence guides two explicit hypotheses

The previous whole copied replay loses the ten material criteria in its first reply.
The correctly mapped replay preserves every one of 519 input lines and all raw
intermediate replies, yet nine criteria first fail in map and one in reduce; final
complete coverage remains zero of ten. First maps consume their 600-token limits
copying opening speech and filler. The earlier unsupported window modifier is retained
as a whole observation and excluded from mapped acceptance.

Two process-local opt-in arms now test preserving material explanations/constraints/
answers/ownership/tense in the whole prompt and condensing filler in the map prompt.
The native executable passes its scripted contract: exact legacy prompt hashes, strict
arm admission, actual generator tokenizer/call parity and unchanged budgets/topology.
Neither arm has yet run against the native Mini model. Production prompts/roles remain
unchanged. Ten anchored criteria, attribution, tense and negative controls stay frozen;
no gold is added to model inputs. All retained copied owner replays use an empty brief,
so production Known-context behavior needs a separate actual-seam test.

## Larger memory producer under review

The saved-audio conversion currently reads in chunks but appends a whole selected
channel to a retained Float array. Forty minutes and five seconds represent 146.79 MiB
per channel; an hour 219.73 MiB. Final ASR processes the channels sequentially: this is
not evidence of simultaneous two-channel retention or attribution of the observed
2.132 GB post-stop footprint. The diarizer separately reads the complete system channel.

A cache-only candidate uses FluidAudio's existing `AudioSampleSource`, selected-channel
CAF range reads and the existing global diarization entry. It preserves sample cuts,
tails, padding and clustering; it adds no model pass, queue, store or audio mixing.
Eighteen authored component cases and original/fixed allocation/native consumer checks
are prepared, but compilation, measured savings, IO cost and native word/speaker parity
remain pending. This candidate is not applied to frozen Source.

## Resource coordination and retained limits

The normal development gate is max 8 GB swap/min 6.5 GB free storage. After compilation
it refuses inference; a recent reading is 8.218 GB swap/7.319 GB storage free. Three
specific nonmodel flags ran under a separately reviewed max9/min6/at least60% reported
free memory exception, with 120 s/3 GB sampled footprint and exact AppKit drain/join.
They do not establish that the normal gate passed. The peer separately joins its exact
bounded CPU-only phase comparison, original RED4 to fixed PASS, under its own exception;
that establishes no ASR/physical meeting performance. All ASR/model comparisons wait
their explicit safe launch admission. Two-second samples are not continuous peaks;
several sub-two-second checks have no process samples.

The obsolete third comparison bundle was removed only after exact executable/process,
pin and peer ownership checks, reclaiming 125,661,184 allocated bytes. Fourth cleanup
previously reclaimed 125,845,504 bytes. Fifth remains required by the dictation peer as
its original ASR/cadence/duty baseline. Sixth, installed useful build, repaired rollback
and original crash reproduction remain. Unrelated caches, models, worktrees and owner
recordings are untouched. See [cleanup receipt](sixth-obsolete-third-cleanup.json).

Embedded browser 18 failures, physical participant-to-voice binding, complete factual
notes/action recall, long paced ASR+voice soak and the 20 tok/s decode floor remain open.
Provider roster data is not voice identity. See the [official-provider identity plan](../2026-10-07-quality-repair/speaker-projection/PROVIDER-IDENTITY-2026-10-08.md).


## Native quiet Session: final recovery, live fragmentation remains failed

The exact scoped native Session experiment joins in23.351s with six successful calls,
23 checks and two word-equality failures. Final mic/system each recover all seven
independent words. Live mic/system instead end with `sub- Yeah.`: the existing RMS
pause rule divides the same voiced input into32,000 and20,566samples. Final uses the
complete52,566sample clause. Seven output words do not establish seven correct words.

The first existing queue compute span is21.681s including cold model preparation;
its native processing reports0.093s. Subsequent warm native processing is0.060–0.069s.
Eleven process samples peak at197,412,352bytes footprint and659,636,224bytes RSS, with
no guard. These are short controlled observations, not a latency percentile, continuous
peak or hardware ASR/voice soak. A separately reviewed one-case max8.5GBswap/min7GB
disk/reported60%free/180s/1GBsampled-footprint profile is used; the normalmax8 gate
remains refused. Source1,173pins and originaleightfiles stay unchanged; all16meetings
are done before launch. No product quiet rule is promoted. The next responsible source
is the live pause detector, with the same word/noise/cost acceptance still required.
See [native word review](sixth-quiet-session-native-word-review.json).
