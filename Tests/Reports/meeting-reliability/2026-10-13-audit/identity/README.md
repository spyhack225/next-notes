# Latest three meetings: identity and timing audit — 13 October 2026

Read-only structural audit. M1/M2/M3 follow the root request order. Real titles, names, IDs, quotes, transcript/context copies and the alias map stay outside the repository in private0700/0600 diagnostics. No ASR, diarization, model, build, UI or owner-data mutation occurred. [Exact redacted counts/pins](structural-summary.json).

## Confirmed saved facts

| Meeting | Duration | Live → saved rows, mic / system | Saved explicit speaker rows / name bindings | Pass |
| --- | --- | --- | --- | --- |
| M1 |2405s |575→411 /195→118 |108 system rows /2 bindings |long-window |
| M2 |2860s |641→468 /227→227 |0 /0 |live-only:rejected |
| M3 |2288s |465→355 /146→146 |0 /0 |live-only:rejected |

All three metadata records identify detectedCall, user title, zero attendees, no conference URL and no covering-call link. calendarEventID is present alongside the detected-call provider: it is not evidence of an EventKit/Google invitation or actual roster. The title itself supplies no authoritative voice binding. Current CallDetector emits no attendees/URL; CalendarMatch can enrich a genuinely matched event through the existing scheduler, but these records have no attendee evidence. Root separately audits retained calendar errors.

M1 has two generated final labels, both with saved name mappings: one spans107 segments totaling476s, the other exactly one5.84s segment at504.32–510.16s. This does not prove there were two real remote people or that either name belongs to a voice. Its final system has10 unlabelled rows, including the last two; the final system ends2242.720s versus live2331.358s, an88.638s earlier endpoint. Mic ends2384.860s versus live2391s. This demonstrates endpoint/segmentation differences; missing audible speech and wrong-person attribution remain unverified without independent audio truth.

M1 saved context contains names from its mapping in2 questions and1 commitment;38 other questions,13 commitments,3 candidates and both participant strings remain source defaults. Neither exact wording differences nor absent/ambiguous timing evidence may be repaired by guessing names. The existing projection deliberately accepts only exact same-source quote/clock evidence and preserves unsupported labels.

M2/M3 retained system rows are **entirely unchanged**, including IDs/text/times, between live and saved final:227/146 rows. System last ends1426.918s/1135.817s, only0.498923/0.496424 of their2860s/2288s durations. Mic final endpoints are2851.240s/2270.860s. Both contexts use source defaults for40 questions and5 commitments; no provider/person binding or generated final label exists. The saved system-loss counters are22,782,827/18,220,683 frames. Those facts fit the final-pass fallback protection, not a successful system final/diarization/name inference.

A source label such as You marks microphone-track provenance; it is not independent proof of who spoke. A compressed/misplaced system timeline can leave a transcript's apparent ending populated only by the mic track. No claim that the remaining words truly came from the local user or that a specific person was misidentified follows from these files alone.

## First producer seam to verify

Current MeetingSession.audioPacket derives startFrame from capture host time (or wall fallback). The writer receives startFrame on every packet; systemDrain advances the transcriber's origin only for the first nonempty packet, then appends sample arrays. ChunkedTranscriber subsequently assigns queued starts from bufferOrigin, incrementing by received sample count. Later host-time discontinuities/gaps are not represented in that ordinary append path. This is a concrete current clock-contract seam worth reproducing; it is **not** proof that it caused the approximately half-duration saved-system timelines or that installed503e contains identical code.

The existing final producer checks known saved loss per source, retains that track's live rows and labels the mixed outcome live-only:rejected. Current pipeline also refuses diarization on known system saved loss. This avoids replacing retained speech with incomplete audio, but cannot restore clocks, audio, speaker labels or names. Do not relax the protection, rescale saved times by2, attribute names from invitation order or add a naming model pass.

## Titles and installed provenance

All three stored titles exactly equal the full root-requested strings (44/30/39 characters); context titles match. No saved-title truncation is shown. Current list titles have lineLimit1 and the detail heading lineLimit2; physical display clipping is unobserved. A rendered ellipsis would be a separate UI presentation issue, not evidence that storage cut a title.

The actual installed executable hashes503e0e401409d05077cfe205c8b8312c1d3b13ec0d27146dfaef3ab2e9b3cbbe (106,415,344bytes,v0.2.24). It differs from historical installeded67302f. No exact503e source/build pin was found in the Reports searched. Current producer hashes and comparisons to the older associated source are retained for review only; they do not establish what503e executes. Root owns deeper source/build provenance and installation decisions.

## Smallest next acceptance sequence

1. Pin503e's actual source or preserve the provenance gap. Reproduce the packet host-time/sample-count divergence through the existing Session/ChunkedTranscriber seam with authored adjacent, delayed, gap and overlap packets; verify same source/time/order into actual saved/fresh-reader rows. Keep independent saved PCM/conversion truth and microphone coverage checks. Parent owns implementation and native/model work.
2. Correct the timing/audio producer when proven, then rerun the original input and real consumer. Verify final fallback and system-loss protections remain intact. Current metadata alone proves no clock repair or acoustic quality.
3. For names, reuse saved speakerNames and the verified manual-name save producer. The staged invitation chooser adds nothing for these zero-attendee calls. Obtain a real roster/participant-linked utterance or explicit user selection before naming voices; independent voice truth, room microphones, overlap and provider/email limits remain acceptance gates.
4. Verify title presentation through a real current-window observation before claiming UI truncation fixed. Preserve full stored titles. No speculative title-to-person parser is justified.

Public structural report delivered through agent-relay to37 other registered peers, cursor1215. [Receipt](relay-receipt.json) proves delivery, not reading or acknowledgement. No private title/name/ID/content/voiceprint was shared.
