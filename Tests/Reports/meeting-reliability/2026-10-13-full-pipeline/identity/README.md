# Participant identity, preparation and confirmation roadmap

Planning only, 13 October 2026. Root owns the overall meeting roadmap and implementation order. This report reads current source and official provider documentation; it changes no Sources, accounts, grants, owner meetings, UI, models, builds or installed app. [Provider capabilities and dated claims](PROVIDERS.md). No private names, speech, IDs or vectors belong in this plan or relay.

## Intended experience

Before a calendar meeting, show a concise preparation card: event title/time, people on the invite, the agenda/link, and relevant prior decisions, unresolved follow-ups and source links from data already available. A missing source is omitted. During recording, show the transcript immediately with neutral labels until person attribution has evidence. After speakers settle, offer one optional “Who was speaking?” panel with a suggested person when justified, a short original audio sample and a name field/choice. “Save names” confirms the selected rows; “Not sure” or dismissal preserves unknowns. Recording, Stop, live ASR and notes progress never wait for this panel.

The aim is dependable names and corrections, not guessed names everywhere. Unknown is a valid successful outcome when identity, timing, audio or permission is missing.

## Current seams and concrete gaps

- Calendar providers preserve invitees as strings (display name, else email). Separate email is lost when displayName exists. MeetingEvent/Meeting already carry title, provider/event ID, attendees and conferenceURL. CallPolicy.calendarMatch currently chooses by covering time/nearest event; that is weak when concurrent invitations exist. CallDetector contributes no roster/link. A synthetic detected-call event ID must not be treated as real invitation/session identity.
- MeetingNotesContextAssembler.brief(forEvent:attendees:excluding:reader:contextTokens:) already assembles bounded memory, decisions, connections, knowledge passages and files, respecting the existing graph/file cloud-consent rules. Reuse it for preparation; do not create another knowledge store or schedule/model loop. No completed dedicated premeeting card was found.
- MeetingParticipantObservationProbe is an explicit one-shot diagnostic: raw AX/CDP evidence, PID/launch or tab/URL and wall intervals, clipping metadata; callState remains unverified, participantNames empty and activeSpeakerName nil. AX deadline/CDP reply caps and lobby/joined-state proof remain open. It must not silently become a recording-path observer.
- SpeakerNamesSheet shows passive “On the invite” chips, editable fields and reidentify. An explicit per-row chooser is cache-staged, uncompiled/uninstalled. There is no short-sample player or automatic end panel in this sheet. It dismisses after Save even if the callback reports a partial failure in the parent; a future confirmation should make the outcome visible without an extra approval.
- MeetingDiarizer.labels(in:) includes only non-nil explicit labels. Current Rename speakers is disabled when that list is empty, so the latest two label-free calls do not have an accessible default-source confirmation path. The roadmap must support an honest unknown/incomplete-audio state; it cannot present one sample as proof that the whole generic remote source is one person.
- MeetingDetailView.commitSpeakerNames reads the current meeting, admits metadata/context saves, then releases temporary audio. It does not regenerate notes. MeetingContextStore refreshes only exact same-source, unambiguous quote/timing evidence; unsupported fields retain their existing labels. MeetingStore triggers knowledge reindexing on a finished metadata save. Transcript rendering/indexing already use speakerNames.
- NotesGenerator consumes the passed meeting's names. NotesService.summarize refuses while the existing task is active; completion currently checks deletion/cancellation, not a changed speaker-map fingerprint. Simply calling summarize after name Save can do nothing while old-name notes are running, or let an old snapshot publish afterward. This is a responsible producer dependency, not a reason to add a retry queue or globally replace names in generated prose.
- Per-meeting speakers.json and the existing PersonResolutionStore/EntityResolver already support graph-scoped local voiceprints and cross-meeting similarity. The graph switch controls collection/use; it is not a calibrated identity guarantee or clearly separate explicit “remember this voice” interaction. This consumer must be included in correction/consent review.

## Evidence levels and fallback

| Evidence | What the UI may say/do | What it must not do |
| --- | --- | --- |
| Invitation/contact/title only | “On the invite”; optional manual choices/preparation | Claim attendance or assign a voice; parse title names into confirmed mappings |
| Verified joined-call roster | “Seen in this meeting”; optional choices with actual source | Bind by order/count/tile position; make email mandatory |
| Observed active-speaker intervals | Suggest a candidate only after session/source/clock/overlap validation | Treat a single badge or delayed dominant-speaker event as complete acoustic truth |
| Provider participant-linked utterance or per-person audio | Strong suggestion after exact local evidence alignment | Apply to mixed local PCM without a join; identify individuals behind one room microphone |
| User heard a valid sample and confirmed | Commit that meeting/cluster's mapping through the existing save seam | Reuse for a re-clustered voice or another meeting without continuity/consent evidence |
| Optional remembered-voice similarity | Clearly marked local suggestion, reviewed uncertainty | Auto-assert person/email from an uncalibrated cosine score |

These are product evidence categories, not a new store or a numerical confidence score presented as certainty. Suggestions remain separate from confirmed mappings. If durable provenance is needed for later corrections, add only bounded typed fields to the existing Meeting/context record after a real source has demonstrated the need; do not conflate observed people with invitation strings or introduce a second identity ledger.

## Premeeting preparation

Use the event occurrence/provider/link and current calendar data as preparation identity. Preserve the difference between invited and previously observed people. Prefer an exact conference link/occurrence match over a time-only match; concurrent invitations, recurring links, rescheduling, forwarded invites, account calendars and room changes must be explicit refusal/choice cases. A call starting outside the schedule must still record immediately.

Call the existing bounded brief assembler in background preparation and display retrieved facts with source/date. Respect memory/graph/file switches and cloud-reader grants. Existing sources can provide useful preparation without a model; any selected summarization must stream its progress and preserve citations, with no mandatory new pass on capture startup. Refresh only from an actual event/input change through existing ownership; do not poll or debounce the microphone path. Preparation must not overwrite scratchpad text, user notes or final notes. Missing calendar/auth/retrieval data yields a smaller card; connecting a chosen provider is one plain app-managed action, never key setup.

## During the meeting

First prove and repair the local host-clock/sample-count/saved-audio contract from the latest audit. A misleading time axis invalidates sample selection, active-speaker alignment and provider joins. A mic/system source is not a person, and echo or screen-share playback can put another person's voice on either track.

For provider evidence, start with an actual joined-call diagnostic and retained private platform-shaped fixture. Then implement only its bounded parser/refusals. An observed roster can assist choices immediately; an interval needs start/end/clock uncertainty, source, conference occurrence and endpoint/session identity. Capture callbacks never await an AX/browser/network read. Production collection needs bounded reads/deadlines, source-change/cancellation handling and measured observer cost before adoption. Do not introduce continuous polling merely because the diagnostic exists.

The first optional provider artifact routes are Meet structured entries and Teams attributed transcripts after a call, subject to the actual grant/account/artifact. Zoom RTMS transcript-only is a larger optional product integration because it requires Marketplace/credits/host access. Default recording works without these routes. No bot, duplicated ASR/PCM pipeline or hosted-client architecture is authorized by this plan.

## End panel and original audio sample

Offer the panel after stable final labels exist; do not steal focus from a live call or turn Stop into a modal wait. If notes are still writing, show that state and let the person continue. Unknown rows can be left alone, the panel can be reopened, and dismissal saves no inferred mapping. Strongly supported suggestion may be prefilled as an unconfirmed proposal; weak invitation/roster evidence is a choice list, not a selected person. Existing manually confirmed names win over new guesses.

Select an original, intelligible, non-overlapping few-second segment for each cluster, from the correct saved channel and valid clock span. Start with one roughly 5–8-second sample, allow another if the person cannot recognize it, and label missing/mixed/unavailable audio plainly. Never synthesize a person's voice, silently mix mic/system channels or create a reusable biometric sample by default. Read/play only the bounded span; whole-hour Float-array loading is unnecessary. There is no verified existing meeting preview player to claim reused; a minimal view-local playback owner is an actual required feature, with cancellation, output routing and memory tests.

Play before the existing name-confirmation release rule can delete temporary audio. Respect explicit keep/temporary policy, expiry, deleted meetings and saved-loss markers. “Sample unavailable” cannot become evidence. Shared-room/mixed clusters need “Different people are mixed here” or existing reidentify/manual correction; a confident suggestion cannot repair them.

The draft binds to a particular meeting, transcript/diarization input and cluster version. A late reidentify, deletion, provider-room change or revised transcript must invalidate the stale proposal before Save even when the string Speaker1 survives. Retain prior confirmed choices as historical evidence; do not silently attach them to a new voice. Existing confirmation does not prove key continuity across reclustering.

## Confirmed change through context and notes

Batch the person's row edits into one Save. The same responsible producer must admit current-row metadata first, report context partial failure truthfully, update supported context attribution, and refresh transcript/index rendering. Names saving does not authorize an external action, recipient change, profile lookup or voice enrollment.

For automatic notes correction, use the existing NotesService/task ownership with the newly admitted speaker map. No concurrent duplicate job, debounce, confirmation or appended “repair” model pass. If an old-name pass is active, replace/cancel through its existing handle off the UI/capture path and fence its completion against changed inputs. Join that handle safely; request the latest canonical input once. A rejected name save starts no notes work. A later notes failure preserves accepted names and previous notes, with a plain partial outcome. The new correction flow must also defer the existing temporary-audio release until selected sample playback and its admitted correction ownership have finished; otherwise the current Save rule would delete that recovery source first. Existing expiry/disk/explicit-keep policies remain independent limits, so unavailable audio must be stated rather than guaranteed retained forever.

Transcript display and supported context labels can update immediately. Legacy notes are free-form text and unkeyed owner strings: global string replacement can alter quotations or unrelated mentions. Until the notes producer retains speaker/source references for deterministic rendering, an ordinary regeneration may be required and takes model time. Show “Names saved. Updating notes…” rather than promise an instantaneous rewritten document. Coordinate any structured speaker-reference schema with the root's factual-notes roadmap and its original/fixed recall gates; no silent schema/prompt/default promotion.

## Optional voice memory

Provide a separate plain opt-in such as “Remember this voice on this Mac” only for a person the user explicitly confirmed, using the existing per-meeting voiceprint/graph seams. It is not implied by Save names or a provider's email. Explain local use and deletion; respect graph-off cleanup, meeting deletion, cloud-consent rules and revocation. Audit existing graph automatic merges before allowing remembered suggestions. Current 0.82 match/0.45 mismatch thresholds are implementation choices, not a false-match calibration on this machine. Require independent multi-device/noise/language/room/voice-change negatives; store no new global biometric ledger. Similarity suggests, it does not prove identity.

## Edge cases that must remain visible

- Duplicate display names: keep provider/session distinctions when supplied; do not merge emails or people. If only a string exists, one display choice is ambiguous and requires manual knowledge.
- Multiple devices/rejoins/breakouts: one person may have multiple endpoint IDs; one endpoint may change. Bound conference occurrence and room/session; do not carry a badge across transitions.
- Rooms, speakerphones, shared accounts and bots: an endpoint label may represent many people or synthetic speech. Room attendance is not individual attribution. Keep group/unknown labels when voices cannot be separated.
- Guests/phone/anonymous users: optional names/emails, masked or unavailable identity; never directory-enrich a guessed name or treat a UPN as a verified email address.
- Screen-share media, played recordings, interpreter channels and echo: voice may not belong to the endpoint operator; preserve playback/unknown possibility and separate audio sources.
- Overlap, short turns and tail loss: reject mixed/ambiguous timing joins, cough-only samples and clipped final phrases. The newest calls' incomplete system PCM/timing cannot support a trusted audio sample or automatic speaker claim.
- Correction/late artifacts: new provider output cannot override a user's confirmed name. Re-identification and changed clock evidence need review; downstream task approvals keep their exact original payload/authority.

## Acceptance slices before implementation/promotion

1. **Clock/audio foundation:** original host-time-gap/compressed-sample input must fail; corrected actual Session/ASR/writer/store/fresh-reader times, source and end/tail coverage must pass, with adjacent/gap/overlap/drop/saved-loss controls. Native independent words and audible source truth remain separate.
2. **Preparation:** existing brief/event producer → displayed sourced card; missing grants/empty inputs, concurrent/recurring calendar identities, cloud consent and no scratchpad overwrite. Actual recording start/full-duplex latency unaffected.
3. **Observed evidence:** real platform capture → parser → separate choice source, with joined/lobby/wrong meeting/clipping/deadline/cancellation/rejoin/breakout/privacy tests. Provider 403/no artifact/expiry/unattributed format stays unknown. No owner payload in public fixtures.
4. **Confirmation/sample:** actual row selection → correct bounded channel excerpt → one current-map save/context/fresh-reader result. No change before Save, Cancel/dismiss, missing/mixed audio, stale same-name cluster, deleted meeting, duplicate names, release ordering, failed metadata/context and focus behavior. Existing native 81 save checks retained; staged 95 invite checks remain unrun and do not prove playback/popup.
5. **Notes propagation:** scripted real NotesService provider/task → changed map while generation suspended → stale output refusal, exactly one newest completion, old notes preserved on rejection/deletion/cancel, scratchpad retained, rendered/index names consistent. Native factual accuracy/coverage and actual user flow are mandatory afterward.
6. **Optional voice memory:** exact consent/current confirmed mapping → existing local voiceprint consumer → graph-off/delete/revoke cleanup and false-match negatives. No automatic enrollment or asserted email/person binding.

Current native speaker/save regressions verify narrower owned consumers, not this complete workflow. The roadmap remains unimplemented. Root must review the feature/dependency order before any Source changes or native/account/UI work.
