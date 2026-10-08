# Next participant identity chunk

Status: plan grounded in existing sources and primary provider documentation. No participant API grant, provider lookup, live AX/CDP observation or automatic acoustic identity binding has been exercised. The finished recording cannot supply missing past roster observations.

## First acceptance slice: observe, without guessing

Use one short physical Zoom call and one Google Meet call to capture a private, bounded observation of the actual current meeting identifier, visible attendee names and available active-speaker identity/timestamps. Include two known participants taking turns, a late join and a deliberate overlap. Root coordinates the native window; no compiler/model run competes with capture. Read the existing accessibility/browser seams; do not write a speculative parser against an unseen screen. Fail this slice if the platform surface cannot distinguish active speaker from a pinned tile, shared screen, or room name.

Keep observer snapshots private. Public evidence contains source shape, timing/cost, exact original/fixed fixture verdicts and count metadata only. Record meeting and process identity so a stale observation from a different call cannot update the recording. Run collection outside audio callbacks and reuse existing context observation cadence; no new capture channel, polling store, transcript model or conversation gate.

## Second slice: actual roster on the existing meeting record

Implement only the observed producer, with a backward-compatible optional participant field on Meeting when the concrete observation warrants it. An invitation and an observed attendee must remain distinguishable; do not overload attendees and turn the current “On the invite” suggestions into an asserted live roster. Retain provider/UI participant identity when available, display name, observation source/time and optional supplied email. Use the existing record/storage seam; do not create an identity ledger. Absent identity/email remains absent.

Verify late join/leave, duplicate names, anonymous/dial-in users, rejoin, renamed accounts and stale call callbacks. Confirm that existing manual speaker-name correction and calendar enrichment still work. A successful roster slice still supplies no voice binding.

## Third slice: stronger provider-linked utterances where accessible

Meet participant records can be accessed by authorized meeting owners/participants, and transcript entries expose participant plus start/end interval. That artifact can ground voice-to-person mapping if accessible and clock-aligned. The current GoogleOAuthClient requests calendar.readonly only; calendar sign-in is not a Meet grant. Reuse the responsible auth seam if a genuinely needed optional Meet grant is added, with one plain authorization action. Do not require account/key setup to record normally. [Participants](https://developers.google.com/workspace/meet/api/guides/participants), [transcript entries](https://developers.google.com/workspace/meet/api/reference/rest/v2/conferenceRecords.transcripts.entries).

Zoom past participant data requires a paid Pro-or-higher account, proper scope and real provider meeting ID. External-user email may be blank. This route can enrich a known accessible meeting, but it cannot be promised for an arbitrary attendee's desktop companion. A roster endpoint provides no acoustic binding by itself. [Zoom Meetings API](https://developers.zoom.us/docs/api/meetings/).

Prefer this verified provider-linked utterance evidence over roster ordering. For local active-speaker observations, prove the observation actually follows audio, align its clock with captured system speech, and refuse shared rooms, simultaneous voices, pinned screens and ambiguous/tiny turns. Determine thresholds from the actual fixtures rather than introducing arbitrary product gates.

## Fourth slice: existing speakerNames consumer acceptance

Apply only a proven label-to-person relation through Meeting.speakerNames. Preserve confirmed user mappings; show uncertain labels and the existing simple correction sheet when evidence is insufficient. Verify that transcript display, regenerated notes and saved agent context consume the same mapping. The bounded final-context repair in this report does not discover names; it only carries supported existing diarization/name evidence into context.

Re-identification needs its own identity-continuity contract: a surviving label key does not prove the cluster still represents the same voice. Until verified, do not reuse provider or prior-call names as a guessed biometric identity.

## Fifth slice: physical performance and quality

Run the actual observer and binding path during responsive short calls, then a long call with both audio sources, ASR and voice active. Measure observer cost, peak/trend footprint, main-thread delay, source-clock coverage and capture integrity. Validate names independently against the known participants. Test denied grants, absent artifacts and observer loss: recording and unknown speaker labels must continue promptly. No synthetic helper pass substitutes for those live platform contracts.
