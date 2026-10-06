# Browser video-target instrument — 2026-10-06

Confirmed cause: browserFollowThrough documented a named video click/direct video URL, but accepted any navigation URL containing Cortech, including YouTube search pages. The same grounding predicate now requires a parsed HTTP(S) YouTube watch/shorts or youtu.be target with a video ID; named-video click handling is preserved. No product tool policy, model pass, reply or grader threshold was changed.

Identical original controls fail seven assertions (three exact retained native search-only answers/calls and four malformed-target boundaries); fixed full grader passes. Correct named clicks and direct-target classifier controls remain green; A01’s separate search contract is preserved. These controls do not prove real video identity, recency or physical playback. The model’s failure to select/play the requested video stays open.

Full production tool loop, capability and store-isolation passed once in the immediately preceding shared grader/report comparison; unchanged product paths were not rerun for this accounting-only slice. Current flag includes all verdict classes, actual fixture/permission/date/Unicode report controls. Child temporary root removed.

Raw evidence: ~/Library/Caches/NextNotesBuild/integration/a02-video-followthrough/{original-result.json,fixed-result.json,original-A02.json}. Original quick reports stay untouched. With only verified M03 and A02 rule deltas, prior installed8b3a34bb Mini quick becomes bounded8/10,9/10,9/10 (min/median/max8/9/9); elapsed95.6/99.3/101.8 seconds. Not a fresh complete regrade or model/phase promotion; full/owner/browser/voice/latency/floor gates remain open.
