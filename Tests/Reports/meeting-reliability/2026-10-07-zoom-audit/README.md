# Zoom meeting audit, 7 October 2026

## Recording and evidence

The owner’s detected Zoom call lasted 40 m 05 (14:06:22–14:46:27 EDT), with 39 m 58.5 s of retained stereo audio,529 final segments and 7,393 transcript words. The owner reports that the Mac and Next Notes stayed responsive. Saved capture integrity reports no writer failure, no gap and zero missing capture frames. The audio/recording clock difference alone does not prove lost audio.

The first 7 m 43 of externally sampled app footprint peaked at 1.007 GB;117 retained resource samples from the final approximately 10 minutes peaked at 1.168 GB. The middle interval is unobserved because the bounded global metrics ring aged it out. No claim of a continuous 40-minute memory trace is made. Retained meeting counters show zero queued bytes, zero missed frames/buffers and zero resource pauses; active work reached 448 KB. System swap reached 8.084 GB in these samples, but swap is machine-wide and is not proof of renewed app growth. Post-stop sampled footprint reached 2.132 GB during notes generation.

| Stage | Elapsed |
|---|---:|
| Drain capture |0.127 s|
| Final transcription |34.155 s|
| Speaker processing |9.958 s|
| Notes |123.881 s|
| Stop to saved notes |about 169 s|

Retained partial/final timeline lag medians are 6.679/7.207 s and p 95 s 9.162/9.968 s. These include timeline alignment; actual live ASR compute totals 53.341 s microphone and 20.422 s system over many minutes of accepted windows, with no reported failed windows. Investigate clock origins before claiming all lag is model inference. Context propagation median 0.753 ms and transcript writes median 3.242 ms are not the dominant bottlenecks.

## Notes and transcript quality

The original notes contain 99 words (137 generated tokens) from a full 14,062-token prompt. The pass stopped naturally and did not report truncation. Audit against the saved transcript confirms an attribution error and a missing planned follow-up, plus weak coverage of several substantive distinctions. Private evidence and an explicitly human-authored audit reference are saved separately in the owner’s Diagnostics/MeetingQualityReview directory; owner speech, participant identities and generated note payloads are not included here or in agent-relay.

This is a transcript-to-notes audit, not independently labeled audio truth. Awkward ASR fragments and uncertain names remain; no WER/DER quality score is claimed. Two far-track clusters include one single-word acknowledgement; oversplitting is a hypothesis, not confirmed speaker truth.

## Confirmed wake producer defect

The configured address is Hey Will. The literal detector matched the characters within ordinary They will; its broad phonetic fallback also accepted Well and I will. Ten saved segments totaling 92 words were labeled agent commands and therefore omitted from note input. The final merge also prioritizes live commands over overlapping final speech. The unretained pre-merge candidates prevent quantifying additional lost speech.

The producer now requires complete literal words and an independently matching phonetic onset. Existing intentional/accented positive cases and microphone authority are retained. Exact actual-source probes with the installed native phone lexicon fail 8 unchanged ordinary-speech cases on the original producers and fail 0 on repaired producers. The maintained MeetingWakeSelfTest adds these cases to the existing full-app wake flag. This establishes the text producer regression; acoustic wake recall and physical next-call acceptance remain separate gates.

## Controlled notes replay

The new --selftest-meeting-notes-replay flag accepts only an explicit UUID-named copied fixture under the physical OS temporary directory. It reads copied meeting/transcript JSON, resolves an explicitly selected model and calls the actual NotesGenerator. An optional read-window proxy exercises the existing whole/map-reduce selection without changing production policy or stored choices. Generation success is not a factuality verdict. Private replay output must be audited against the same coverage/attribution/action reference before adopting a strategy.

Native results and installed build evidence are recorded below. The owner’s original recording and saved notes remain unchanged.

## Participant identity

This detected call has no calendar roster, provider participant observations or speaker-name map. CallDetector deliberately emits an empty roster; scheduled calendar meetings have a separate existing enrichment path. The existing speakerNames dictionary and speaker naming UI are the display seam to reuse.

A roster can suggest names but cannot alone identify a voice. Automatic mappings need provider transcript participant IDs or bounded, observed active-speaker intervals aligned to the captured audio. Never map by roster order, infer email from a name, or overwrite user-confirmed mappings.

Primary feasibility sources: [Meet participants](https://developers.google.com/workspace/meet/api/guides/participants), [Meet transcript entries](https://developers.google.com/workspace/meet/api/reference/rest/v2/conferenceRecords.transcripts.entries), [Zoom Meetings API](https://developers.zoom.us/docs/api/meetings/). Availability depends on authorization, account capabilities and provider artifacts. No retroactive identity recovery or general attendee/email access is established for this recording.

## Retained metadata and cleanup

summary.json binds original owner file hashes. meeting-metrics.json and usage-metadata.json retain bounded stage/resource and per-pass metadata; no transcript or voiceprint vectors are included. wake-original.log/wake-fixed.log and wake-source-pins.json retain original/fixed proof. The 215.9 MB private raw OS log was reduced to bounded app diagnostics, hashed and removed; no owner recordings, models, foreign build caches or active processes were swept.

## First optimized native verification and model comparisons

Candidate install-28775 SHA256 06037e443e60833b0063cfd3d3bc67dbc7c04fe4fd50acde4ac809491dfba33e was signed and source-invariant across 1159 files. Build 671s. Actual wake, cleanup-router/structure, meeting-context, longform/truncation, health 90 and integrity 67 pass. Store isolation: 21 files and 33 defaults passes; its embedded browser tool-loop has 18 failures byte-for-byte matching the prior installed log. This inherited gate remains open.

Same copied transcript, explicitly selected provider, empty brief and fresh processes:

| Provider/path | Notes generation | Tokens across passes | Quality |
|---|---:|---:|---|
| MiniCPM whole |63.192s|175|Follow-up missing, weak coverage|
| MiniCPM window8192 |159.558s|1860|Follow-up missing; attribution worsened|
| Apple |161.897s|4396|Descriptive facts misclassified as actions/decisions|
| Qwen3-4B whole |260.708s|603|Fuller but past discussion/lunch became future actions|
| Qwen3.5-4B whole |98.249s|340|Finds follow-up but invents a deadline and misstates completed lunch|

These are writer comparisons, not original-background-load reproduction or ASR+voice decode-floor proof. The explicit empty brief also makes the prompt different from any original known-context input. No provider or strategy passed factual quality; no default or stored model choice changed.

Retained production usage reveals a separate confirmed contract defect: MiniCPM’s first two maps each stopped at600-token length; its reduce completed, and the final notes did not disclose incomplete extraction. Apple’s three maps also cut and its first reduce retried once. Existing NotesGenerator ignores map/collapse finishedByLimit, unlike its answer retry contract. The original native partial-coverage assertion isRED. Repair carries the producer’s incompleteFacts through the existing result and a plain coverage notice, without another model pass or retry. This is disclosure of partial coverage, not recovery of the missed facts or resolution of the broader quality failure. The final actual native replay passes the original partial-coverage assertion: typed incompleteFacts is true and the reader notice appears. It retains the same three maps, one reduce and 1860 tokens; after removing the notice the generated body is byte-identical. Four original and four fixed model passes establish no added generation. The different elapsed times are not causal speed proof. Broader factual quality still fails.

Saved live context also contains three high-confidence action candidates from ordinary explanatory speech, while the structured notes arrays are empty. Quote matching proves text provenance, not action intent; the actual reconciler already instructs the model to omit generic discussion. Semantic intent/confidence and final-speaker propagation into live context remain open. Owner payload and evidence quotes stay in the private review.

## Integrated and installed release

Producer commits d729747 (wake and read-only replay) and 8df94cb (partial-fact coverage) are integrated into canonical main. The final optimized build is invariant across 1159 source/resource files and signed. One initial compile attempt failed on a new fixture helper name; it was corrected before the final successful 598.61s build. Original/fixed failures and the repair are retained, not replaced with an easier fixture.

Final optimized wake, cleanup-router, cleanup-structure, meeting-context, notes-longform, notes-truncation, meeting-health 90, meeting-integrity 67 and store isolation 21 files / 33 defaults pass. The isolation flag's embedded 18 browser tool-loop failures reproduce the inherited verdict and remain open. Passing functional checks does not establish semantic notes/action quality, live wake recall or the reference-machine decode floor. Nonstreaming notes lack separate first-token/prefill timing, so wall time cannot all be attributed to decode.

The owner app at /Applications/Next Notes.app is now the exact verified candidate: SHA256 ed67302fae3c246bbfc377be77e954a0070f17b3b4c5771cfe5e1a04e0d628ad, UUID 38CA5417-54F2-30D4-B03C-C78A282BB2C6. Installation used the existing install lock and normal owner startup, with no fixture/provider/preference override. The exact prior idle app process exited gracefully. Native accessibility inspection confirms the owner's real meeting history and this 40:05 Zoom recording. All eight original meeting files remain byte-identical. Twenty passive startup footprint samples span 889–894MB; this is startup evidence, not a new meeting soak. A repaired rollback and the shared final candidate remain available.

All five writer comparisons fail the factual acceptance bar. The next quality work must establish a real producer contract for source-linked coverage, attribution and future commitment intent, with these original failing inputs and no invented deadline. Quote matching alone cannot assign high semantic confidence. Participant binding requires a real authorized provider artifact or next live Zoom/Meet observation. No automatic names, provider promotion, whole-session trace or perfect/instant meeting-quality claim is made.

Final cleanup removes the owned intermediate bundle, completed replay fixture, probe executables/private indexes and six finished replay sandboxes: 125,984,768 allocated bytes reclaimed, in addition to the earlier 215,909,031-byte raw-log reduction. The current shared candidate, repaired rollback and explicit original incident reproduction build remain. No owner recording/model or foreign cache is removed. See final-cleanup.json.
