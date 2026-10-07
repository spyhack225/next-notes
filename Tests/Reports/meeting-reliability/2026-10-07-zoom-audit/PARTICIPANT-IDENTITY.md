# Participant identity integration contract

Status: researched and traced; no automatic voice-to-name producer is implemented or accepted yet. This is part of the owner-requested meeting quality work.

## Existing producer and display seam

Detected calls originate in CallDetector.event(for:), which emits attendees=[] and no conference URL. MeetingScheduler already enriches matched scheduled meetings with calendar titles/attendees. The finished Zoom call did not have a usable matched roster. Invitation names are candidates, not proof of attendance or speech.

Meeting.speakerNames is the existing display map. Transcripts retain stable diarization labels, and NotesGenerator uses the display map on regeneration. SpeakerNamesSheet already offers manual correction and invitation suggestions. Reuse this seam; do not rewrite every transcript segment, create a parallel identity store, or override confirmed user mappings.

## Provider evidence

[Meet participants](https://developers.google.com/workspace/meet/api/guides/participants) returns display names and participant/session identities with user authorization. Signed-in identity can be linked to People API data where accessible; guest/phone display names do not promise email. [Meet transcript entries](https://developers.google.com/workspace/meet/api/reference/rest/v2/conferenceRecords.transcripts.entries) link utterances and time intervals to participants when the artifact exists and is accessible. These are stronger binding evidence than a roster alone.

The [Zoom Meetings API](https://developers.zoom.us/docs/api/meetings/) exposes past participant records subject to the account, meeting identifier and grants. It does not establish that an arbitrary attendee’s desktop companion can universally retrieve every participant/email. An SDK running inside a separately integrated meeting app is not automatically an API into the owner’s already-running Zoom client.

Local Zoom accessibility and Meet browser surfaces are a possible live observation source. Their actual roster/active-speaker contract must be captured and verified in a future call before writing parsers. The completed call contains no such observations; a present UI snapshot cannot reconstruct earlier attendance.

## Smallest safe implementation

1. Enrich the existing meeting record with optional observed participant metadata only when a real provider/UI producer exists. Keep source, timestamp and optional provider identity/email; preserve backward decoding of old recordings. Invitation versus actual attendance must remain distinguishable.
2. Collect roster and active-speaker observations asynchronously through existing calendar/browser/accessibility seams, outside audio callbacks. No fixed gate, extra audio channel, compulsory account setup or new ledger.
3. Align participant-linked utterances or stable observed active-speaker intervals with the actual capture clock. Exclude overlaps, rooms/shared devices, changing accounts and ambiguous short turns from automatic binding. A one-word diarization cluster is insufficient evidence.
4. Apply proven display bindings through speakerNames; preserve user-confirmed names and expose one simple correction when evidence is ambiguous. Never map by roster order or fabricate email. Regenerated notes must consume the same mapping.

## Acceptance before release

Use provider-shaped fixtures plus an actual Zoom and Meet observation, covering late join/leave, duplicate names, guest/dial-in, shared rooms, overlapping speech, delayed metadata, absent grants and stale callbacks. Prove exact voice-to-name mapping at the notes consumer; prove zero guessed identity when evidence is insufficient. Record observation cost, capture continuity, bounded memory and main-thread/UI latency while both tracks and voice are active. Missing permissions/artifacts remain visible limitations rather than a passing mock test.
