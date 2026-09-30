# cases.sh — the fixture corpus, one shell function per case.
#
# Sourced by make-chatdb-fixture.sh, which provides the row writers (msg,
# handle_row, chat_row, attach_row, chat_message, msg_attachment, chat_handle),
# `emit`, and the deterministic date base. Every function below is a pure
# sequence of row writes with fixed ROWIDs and fixed values: no clock, no
# randomness, no I/O. Two runs of the same function produce the same bytes.
#
# ---------------------------------------------------------------- values ---
#
# Addresses are +1555000NNNN. +15550000000 is the user's own placeholder, and
# +15550000001 / 2 / 3 are three other people. No case contains a real number,
# a name or an address, and make-chatdb-fixture.sh refuses to emit one.
#
# Bodies are FIXTURE-* strings rather than sentences, so a fixture that leaks
# into a transcript is recognisable as a fixture.
#
# BLOBBODY is the synthetic stand-in for a typedstream. X'0001' is two bytes
# whose leading byte is a version header the decoder will not recognise, which
# is exactly what IM-05's `.undecodable` case needs and nothing more. It is NOT
# a typedstream and must never be treated as one. Real bytes arrive with IM-01
# (Tests/Reports/imessage-self-flow.md, question Q2) and replace it; the
# roadmap calls these fixtures provisional for that reason.

BLOBBODY="blob:0001"

ALL_CASES="basic-text self-message direct-message group-message sms voice-note \
voice-note-unlabelled reply reaction edit unsend delayed-attachment-join \
empty-attributed-body both-paths send-verify"

case_purpose() {
    case $1 in
        basic-text)
            printf 'IM-04: a DM with text populated and a second row with text NULL' ;;
        self-message)
            printf 'IM-04/IM-07: the self-chat, one is_from_me=1 and one =0' ;;
        direct-message)
            printf 'IM-04/IM-09: a DM chat joined to two handles' ;;
        group-message)
            printf 'IM-04/IM-09: a group guid shaped iMessage;+;<opaque>, three handles' ;;
        sms)
            printf 'IM-05: service SMS, text present, attributedBody genuinely NULL' ;;
        voice-note)
            printf 'IM-05/IM-15: an audio attachment joined to its message, is_audio_message=1' ;;
        voice-note-unlabelled)
            printf 'IM-05: the same voice note on a database that cannot label it (--no-audio)' ;;
        reply)
            printf 'IM-05: a thread_originator_guid pointing at the earlier row' ;;
        reaction)
            printf 'IM-05: a tapback row carrying payload_data + balloon_bundle_id' ;;
        edit)
            printf 'IM-05: an edited row with date_edited + associated_message_guid' ;;
        unsend)
            printf 'IM-05/IM-08: a retracted row' ;;
        delayed-attachment-join)
            printf 'IM-06: cache_has_attachments=1 with zero message_attachment_join rows' ;;
        empty-attributed-body)
            printf 'IM-05: text NULL, attributedBody a non-typedstream sentinel' ;;
        both-paths)
            printf 'IM-05: one sentence twice in one chat, text on one row, attributedBody on the other' ;;
        send-verify)
            printf 'IM-10: two from-me rows in the self-chat, one sent-but-undelivered, one delivered' ;;
        *) printf '' ;;
    esac
}

# ------------------------------------------------------------------ cases ---

# IM-04's query methods have to return rows, and IM-05 needs both halves of the
# "text present" / "text absent" split. The NULL-text row here carries no
# attributedBody at all, which makes it IM-05's `.absent` state (an SMS, or a
# very old row) rather than its `.undecodable` state — that is
# empty-attributed-body's job. Nothing optional is set, so this case is also
# the one --degraded is built from.
case_basic_text() {
    handle_row ROWID=1 id=+15550000001 uncanonicalized_id=+15550000001 \
        person_centric_id=REDACTED-PERSON-1
    chat_row ROWID=1 guid='iMessage;-;+15550000001' \
        chat_identifier=+15550000001 display_name=REDACTED-PERSON-1
    chat_handle 1 1

    msg ROWID=1 guid=FIXTURE-MSG-0001 handle_id=1 text='FIXTURE-BODY-1' is_from_me=0
    msg ROWID=2 guid=FIXTURE-MSG-0002 handle_id=1 is_from_me=0

    chat_message 1 1
    chat_message 1 2
}

# The canonical self-chat, and the case IM-01 exists to answer: a self-message
# arrives as is_from_me 1 on some accounts and 0 on others. The fixture carries
# both so IM-07's filter can be written against whichever answer comes back —
# and so a filter that only works for one of them is caught.
case_self_message() {
    handle_row ROWID=1 id=+15550000000 uncanonicalized_id=+15550000000 \
        person_centric_id=REDACTED-SELF
    chat_row ROWID=1 guid='iMessage;-;+15550000000' \
        chat_identifier=+15550000000 display_name=REDACTED-SELF
    chat_handle 1 1

    msg ROWID=1 guid=FIXTURE-SELF-0001 handle_id=1 text='FIXTURE-SELF-BODY-1' is_from_me=1
    msg ROWID=2 guid=FIXTURE-SELF-0002 handle_id=1 text='FIXTURE-SELF-BODY-2' is_from_me=0

    chat_message 1 1
    chat_message 1 2
}

# IM-10's verification rows: two from-me sends in the self-chat with different
# delivery states. Row 1 was accepted but never delivered (is_sent=0,
# is_delivered=0) — it must verify as landed, never delivered. Row 2 carries
# is_delivered=1 — the only shape that verifies as delivered. Bodies are
# FIXTURE-* strings, never sentences, like every other case in this file.
case_send_verify() {
    handle_row ROWID=1 id=+15550000000 uncanonicalized_id=+15550000000 \
        person_centric_id=REDACTED-SELF
    chat_row ROWID=1 guid='iMessage;-;+15550000000' \
        chat_identifier=+15550000000 display_name=REDACTED-SELF
    chat_handle 1 1

    msg ROWID=1 guid=FIXTURE-SEND-0001 handle_id=1 text='FIXTURE-SEND-UNDELIVERED' is_from_me=1 is_sent=0 is_delivered=0
    msg ROWID=2 guid=FIXTURE-SEND-0002 handle_id=1 text='FIXTURE-SEND-DELIVERED' is_from_me=1 is_sent=1 is_delivered=1

    chat_message 1 1
    chat_message 1 2
}

# A DM joined to two handles: the user and the other person. IM-09's send
# target resolution walks chat_handle_join to handle.uncanonicalized_id, so a
# chat with only one handle would not exercise the walk.
case_direct_message() {
    handle_row ROWID=1 id=+15550000000 uncanonicalized_id=+15550000000 \
        person_centric_id=REDACTED-SELF
    handle_row ROWID=2 id=+15550000001 uncanonicalized_id=+15550000001 \
        person_centric_id=REDACTED-PERSON-1
    chat_row ROWID=1 guid='iMessage;-;+15550000001' \
        chat_identifier=+15550000001 display_name=REDACTED-PERSON-1
    chat_handle 1 1
    chat_handle 1 2

    msg ROWID=1 guid=FIXTURE-DM-0001 handle_id=2 text='FIXTURE-DM-BODY-1' is_from_me=0
    msg ROWID=2 guid=FIXTURE-DM-0002 handle_id=1 text='FIXTURE-DM-BODY-2' is_from_me=1

    chat_message 1 1
    chat_message 1 2
}

# A group. The guid is opaque, which is the point: iMessage;+;<opaque> says
# nothing addressable, so the only route to a send target is
# chat_handle_join -> handle.uncanonicalized_id. Three handles so a resolver
# that returns the first one is distinguishable from one that returns all three.
case_group_message() {
    handle_row ROWID=1 id=+15550000000 uncanonicalized_id=+15550000000 \
        person_centric_id=REDACTED-SELF
    handle_row ROWID=2 id=+15550000001 uncanonicalized_id=+15550000001 \
        person_centric_id=REDACTED-PERSON-1
    handle_row ROWID=3 id=+15550000002 uncanonicalized_id=+15550000002 \
        person_centric_id=REDACTED-PERSON-2
    chat_row ROWID=1 guid='iMessage;+;REDACTED-GROUP-1' \
        chat_identifier=REDACTED-GROUP-1 display_name=REDACTED-GROUP-1 style=43
    chat_handle 1 1
    chat_handle 1 2
    chat_handle 1 3

    msg ROWID=1 guid=FIXTURE-GRP-0001 handle_id=2 text='FIXTURE-GRP-BODY-1' is_from_me=0
    msg ROWID=2 guid=FIXTURE-GRP-0002 handle_id=3 text='FIXTURE-GRP-BODY-2' is_from_me=0
    msg ROWID=3 guid=FIXTURE-GRP-0003 handle_id=1 text='FIXTURE-GRP-BODY-3' is_from_me=1

    chat_message 1 1
    chat_message 1 2
    chat_message 1 3
}

# An SMS. The distinction that matters is that text is populated AND
# attributedBody is genuinely NULL — the row a developer writes by hand and the
# only kind most fixtures of this shape ever contain. IM-05's `.absent` state is
# this row, and a decoder that only reads text passes here and fails everywhere
# else.
case_sms() {
    handle_row ROWID=1 id=+15550000001 uncanonicalized_id=+15550000001 \
        person_centric_id=REDACTED-PERSON-1 service=SMS
    chat_row ROWID=1 guid=+15550000001 chat_identifier=+15550000001 \
        display_name=REDACTED-PERSON-1 service_name=SMS style=45
    chat_handle 1 1

    msg ROWID=1 guid=FIXTURE-SMS-0001 handle_id=1 service=SMS \
        text='FIXTURE-SMS-BODY-1' is_from_me=0

    chat_message 1 1
}

# A voice note. IM-05 classifies it as .notText rather than as an empty string
# or a refusal, and IM-15 later copies the file out — so the attachment row needs
# a voice UTI, a filename, a mime type and a settled transfer_state.
# cache_has_attachments=1 plus a real join row is the settled half of the shape
# IM-06's race case inverts.
#
# **The `is_audio_message=1` on this row is the whole of the classification, and
# that is the measurement IM-05d recorded on 2026-09-26.** The `attributedBody`
# below is the `X'0001'` sentinel, so there is no class chain to read at all: the
# walk refuses, and a column is the only thing on this row that says what it is.
# `voice-note-unlabelled` is the other half of the pair, and the reason the
# classification needs no third signal.
case_voice_note() {
    handle_row ROWID=1 id=+15550000001 uncanonicalized_id=+15550000001 \
        person_centric_id=REDACTED-PERSON-1
    chat_row ROWID=1 guid='iMessage;-;+15550000001' \
        chat_identifier=+15550000001 display_name=REDACTED-PERSON-1
    chat_handle 1 1

    msg ROWID=1 guid=FIXTURE-VOICE-0001 handle_id=1 is_from_me=0 \
        is_audio_message=1 cache_has_attachments=1 \
        attributedBody="$BLOBBODY"
    attach_row ROWID=1 guid=FIXTURE-ATT-VOICE-0001 \
        filename=FIXTURE-VOICE-0001.caf uti=com.apple.coreaudio-format \
        mime_type=audio/x-caf transfer_state=5 total_bytes=2048

    chat_message 1 1
    msg_attachment 1 1
}

# The same voice note on a database that cannot say it is one.
#
# **It is the same conversation, the same attachment and the same unreadable body,
# and it is a different kind of object**, because the one column that named it is
# not written. This case is what the *absence* of `is_audio_message` looks like
# from inside a Messages database, and it is why `--no-audio` exists: with the
# column present but the row not setting it (this case, built plainly) a reader
# can tell "not audio" from "this Mac cannot tell", and with the column gone
# (`--no-audio`) it can only say the second. A test that used a row holding a
# NULL where the column *should* be would prove the reader's nil-handling and
# nothing about the probe.
#
# The `msg` writer refuses a case that writes `is_audio_message` in this mode, so
# this case cannot quietly grow into a voice note nobody can see.
case_voice_note_unlabelled() {
    handle_row ROWID=1 id=+15550000001 uncanonicalized_id=+15550000001 \
        person_centric_id=REDACTED-PERSON-1
    chat_row ROWID=1 guid='iMessage;-;+15550000001' \
        chat_identifier=+15550000001 display_name=REDACTED-PERSON-1
    chat_handle 1 1

    msg ROWID=1 guid=FIXTURE-VOICE-UNLABELLED-0001 handle_id=1 is_from_me=0 \
        cache_has_attachments=1 \
        attributedBody="$BLOBBODY"
    attach_row ROWID=1 guid=FIXTURE-ATT-VOICE-UNLABELLED-0001 \
        filename=FIXTURE-VOICE-UNLABELLED-0001.caf uti=com.apple.coreaudio-format \
        mime_type=audio/x-caf transfer_state=5 total_bytes=2048

    chat_message 1 1
    msg_attachment 1 1
}

# A threaded reply. The roadmap's experiment 6. thread_originator_part is set to
# the same guid as the originator, which is what a simple text message does and
# is what a decoder grouping on the pair would have to agree with.
case_reply() {
    handle_row ROWID=1 id=+15550000001 uncanonicalized_id=+15550000001 \
        person_centric_id=REDACTED-PERSON-1
    chat_row ROWID=1 guid='iMessage;-;+15550000001' \
        chat_identifier=+15550000001 display_name=REDACTED-PERSON-1
    chat_handle 1 1

    msg ROWID=1 guid=FIXTURE-THREAD-0001 handle_id=1 \
        text='FIXTURE-THREAD-PARENT' is_from_me=0
    msg ROWID=2 guid=FIXTURE-THREAD-0002 handle_id=1 \
        text='FIXTURE-THREAD-REPLY' is_from_me=0 \
        thread_originator_guid=FIXTURE-THREAD-0001 \
        thread_originator_part=FIXTURE-THREAD-0001

    chat_message 1 1
    chat_message 1 2
}

# A tapback, experiment 7. type 2000 with associated_message_guid is how a
# reaction names its target; balloon_bundle_id plus payload_data is the pair
# IM-05 returns .notText(bundleID:) from. The blob is the X'0001' sentinel, so
# this case proves the classifier refuses rather than that the decoder reads.
case_reaction() {
    handle_row ROWID=1 id=+15550000001 uncanonicalized_id=+15550000001 \
        person_centric_id=REDACTED-PERSON-1
    chat_row ROWID=1 guid='iMessage;-;+15550000001' \
        chat_identifier=+15550000001 display_name=REDACTED-PERSON-1
    chat_handle 1 1

    msg ROWID=1 guid=FIXTURE-REACTEE-0001 handle_id=1 \
        text='FIXTURE-REACTEE-BODY' is_from_me=0
    msg ROWID=2 guid=FIXTURE-REACTION-0001 handle_id=1 type=2000 is_from_me=1 \
        associated_message_guid=FIXTURE-REACTEE-0001 associated_message_type=2000 \
        balloon_bundle_id=com.apple.messages.Emoji.TapbackEffect \
        payload_data="$BLOBBODY"

    chat_message 1 1
    chat_message 1 2
}

# An edited message, experiment 8. date_edited is what makes the row an edit
# rather than an original, and associated_message_guid names the row it
# replaced. IM-05 must not decode the edited row as if the edit never happened.
case_edit() {
    handle_row ROWID=1 id=+15550000001 uncanonicalized_id=+15550000001 \
        person_centric_id=REDACTED-PERSON-1
    chat_row ROWID=1 guid='iMessage;-;+15550000001' \
        chat_identifier=+15550000001 display_name=REDACTED-PERSON-1
    chat_handle 1 1

    msg ROWID=1 guid=FIXTURE-EDIT-ORIGINAL-0001 handle_id=1 \
        text='FIXTURE-EDIT-BEFORE' is_from_me=0
    msg ROWID=2 guid=FIXTURE-EDIT-0002 handle_id=1 \
        text='FIXTURE-EDIT-AFTER' is_from_me=0 date_edited=1700001200000000000 \
        associated_message_guid=FIXTURE-EDIT-ORIGINAL-0001

    chat_message 1 1
    chat_message 1 2
}

# A retracted message, experiment 9. text is NULL and is_retracted is 1, so the
# two states this could decode into — an empty body and a refusal — are both
# reachable from the row and neither is the default.
case_unsend() {
    handle_row ROWID=1 id=+15550000000 uncanonicalized_id=+15550000000 \
        person_centric_id=REDACTED-SELF
    chat_row ROWID=1 guid='iMessage;-;+15550000000' \
        chat_identifier=+15550000000 display_name=REDACTED-SELF
    chat_handle 1 1

    msg ROWID=1 guid=FIXTURE-UNSEND-0001 handle_id=1 is_from_me=1 \
        is_retracted=1 attributedBody="$BLOBBODY"
    msg ROWID=2 guid=FIXTURE-AFTER-UNSEND-0002 handle_id=1 is_from_me=0 \
        text='FIXTURE-AFTER-UNSEND-BODY'

    chat_message 1 1
    chat_message 1 2
}

# IM-06's settling race, and the only case whose assertion is a count. The
# message row says it has an attachment and the attachment row is already in
# the table, but the join row is not — which is the state Messages leaves the
# database in between the two writes. The test adds the join row itself on the
# third refetch; a fixture that shipped the join already would assert nothing.
# So: zero rows in message_attachment_join, deliberately.
case_delayed_attachment_join() {
    handle_row ROWID=1 id=+15550000001 uncanonicalized_id=+15550000001 \
        person_centric_id=REDACTED-PERSON-1
    chat_row ROWID=1 guid='iMessage;-;+15550000001' \
        chat_identifier=+15550000001 display_name=REDACTED-PERSON-1
    chat_handle 1 1

    msg ROWID=1 guid=FIXTURE-SETTLE-0001 handle_id=1 is_from_me=0 \
        cache_has_attachments=1 attributedBody="$BLOBBODY"
    attach_row ROWID=1 guid=FIXTURE-ATT-SETTLE-0001 \
        filename=FIXTURE-SETTLE-0001.jpeg uti=public.jpeg \
        mime_type=image/jpeg transfer_state=5 total_bytes=4096

    chat_message 1 1
}

# The refusal path. text is NULL and attributedBody is present but holds the
# X'0001' sentinel — a version header the decoder will not recognise. IM-05's
# fourth case is .undecodable and its Done-when is that the value is proven not
# to be the empty string, so the row has to exist in a shape where a decoder
# that returned "" would be returning it rather than reporting nothing.
case_empty_attributed_body() {
    handle_row ROWID=1 id=+15550000001 uncanonicalized_id=+15550000001 \
        person_centric_id=REDACTED-PERSON-1
    chat_row ROWID=1 guid='iMessage;-;+15550000001' \
        chat_identifier=+15550000001 display_name=REDACTED-PERSON-1
    chat_handle 1 1

    msg ROWID=1 guid=FIXTURE-UNREADABLE-0001 handle_id=1 is_from_me=0 \
        attributedBody="$BLOBBODY"

    chat_message 1 1
}

# The one case whose assertion the corpus could not previously express, and the
# one IM-05's second assertion is written in terms of: the same sentence, read
# out of `text` on one row and out of `attributedBody` on another. Two rows, one
# chat, and they differ in nothing else that could stand in for the answer —
# same handle, same direction, same service — so a test comparing them is
# comparing the two decode paths and not two different messages. That is why
# both rows are is_from_me 0 here: the variable under test is the column, and a
# second variable would make the comparison unfalsifiable.
#
# The body is a FIXTURE-SENTENCE rather than a FIXTURE-BODY token, because an
# equality assertion over a multi-word value is the one that catches a parser
# which stops one character early. It is still unmistakably a fixture, and it
# carries no person, place, number or address.
#
# attributedBody is the same X'0001' placeholder every other case carries, and
# that is the point rather than a shortcut. There is no placeholder that decodes
# to this sentence, so "both rows decode identically" is *structurally
# impossible* to pass today: the only two ways to make it green are to invent a
# typedstream (which asserts an encoding nobody has observed) or to widen the
# equality until a refusal equals a string. What the case proves today is the
# half that needs no real bytes — the two rows exist, share a chat, and are equal
# in every column but the two that carry the body — plus the refusal half: row B
# must come back .undecodable and must not come back "". IM-01 replaces the
# placeholder and nothing else about the case changes.
case_both_paths() {
    handle_row ROWID=1 id=+15550000001 uncanonicalized_id=+15550000001 \
        person_centric_id=REDACTED-PERSON-1
    chat_row ROWID=1 guid='iMessage;-;+15550000001' \
        chat_identifier=+15550000001 display_name=REDACTED-PERSON-1
    chat_handle 1 1

    msg ROWID=1 guid=FIXTURE-BOTH-0001 handle_id=1 is_from_me=0 \
        text='FIXTURE-SENTENCE the same words in both rows of this chat'
    msg ROWID=2 guid=FIXTURE-BOTH-0002 handle_id=1 is_from_me=0 \
        attributedBody="$BLOBBODY"

    chat_message 1 1
    chat_message 1 2
}
