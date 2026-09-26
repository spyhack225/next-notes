#!/bin/sh
#
# make-chatdb-fixture.sh — schema-complete, sanitised Apple Messages chat.db
# fixtures for IM-04, IM-05 and IM-06.
#
# Reads no real Messages data and needs no build. Every case is a pure function
# of cases.sh: fixed ROWIDs, fixed nanosecond timestamps, no random(), no
# date('now'). Two runs of the same case produce a byte-identical file, which
# is how "a fixture is deterministic" is checked rather than asserted in prose.
#
#   make-chatdb-fixture.sh <case> [--degraded] [--outdir DIR] [--sql]
#   make-chatdb-fixture.sh --list
#   make-chatdb-fixture.sh --all [--degraded]
#
# --degraded emits a database whose `message` table genuinely has no
# `attributedBody` and no `payload_data` column, for IM-04's capability probe
# and for proving that messages(after:) degrades rather than throwing. A case
# that writes either column is refused rather than silently half-built.
#
# SQLite is pinned to Apple's build by absolute path: an older anaconda sqlite3
# sits earlier on PATH on the development machine and the two do not agree on
# file bytes. Override with SQLITE=/path/to/sqlite3 if you need to.

set -eu

SQLITE=${SQLITE:-/usr/bin/sqlite3}
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# Overridable so a test can point the generator at its own corpus — which is the
# only honest way to prove the sanitisation guard fires, since a guard that is
# only reachable by editing the corpus is a guard nothing checks.
SCHEMA=${SCHEMA:-$HERE/schema.sql}
CASES=${CASES:-$HERE/cases.sh}

# chat.db stores `date` as nanoseconds since 2001-01-01. Fixed, so two runs agree.
EPOCH_BASE=1700000000000000000
ROWID_STRIDE=60000000000

# Columns the roadmap §2.2 flags as often-missed, plus the ones
# MessagesCapabilities probes. The summary line reports which are present.
OPTIONAL_MESSAGE_COLUMNS="attributedBody payload_data balloon_bundle_id is_sent error \
date_edited is_retracted associated_message_guid thread_originator_guid cache_has_attachments"
OPTIONAL_HANDLE_COLUMNS="uncanonicalized_id"

FIXTURE_TABLES="message chat handle attachment chat_message_join message_attachment_join chat_handle_join"

die() { printf 'CHATDB_FIXTURE_FAILED: %s\n' "$*" >&2; exit 1; }

TMPDIR_FX=
SQL_FILE=
cleanup() { [ -n "$TMPDIR_FX" ] && rm -rf "$TMPDIR_FX" || :; }
trap cleanup EXIT INT TERM

# ------------------------------------------------------------------ values --

# sql_lit <value>  ->  a SQL literal. Two prefixes, both meaning "this is not a
# string": `blob:XXXX` is emitted verbatim as X'XXXX' so a fixture can carry a
# blob without this script escaping binary, and `sql:XXXX` is emitted verbatim
# as SQL, which is how a default says NULL.
#
# The distinction is load-bearing. An earlier version had msg_default return the
# bare word NULL and let sql_lit quote it, so every defaulted column held the
# four-character string 'NULL' instead of SQL NULL — and a fixture asserting
# `attributedBody IS NULL` passed for an SMS row whose attributedBody was the
# text "NULL". No fork either: this runs once per column per row, and a version
# that piped through sed was a hundred processes per fixture.
sql_lit() {
    case $1 in
        blob:*) printf "X'%s'" "${1#blob:}" ;;
        sql:*)  printf '%s' "${1#sql:}" ;;
        *\'*)
            # Doubling ' is a '' escape. Rare — no fixture value contains one —
            # but a generator that silently produced broken SQL on an apostrophe
            # would be a trap for whoever adds the first case that has one.
            _sl=$1
            while :; do
                case $_sl in
                    *"'"*) _sl="${_sl%%\'*}'${_sl#*\'}" ;;
                    *) break ;;
                esac
            done
            printf "'%s'" "$_sl" ;;
        *) printf "'%s'" "$1" ;;
    esac
}

# kv_get <key> <k=v>...  ->  the value for <key>, or failure.
kv_get() {
    _kg=$1; shift
    for _ka in "$@"; do
        case $_ka in
            "$_kg="*) printf '%s' "${_ka#*=}"; return 0 ;;
        esac
    done
    return 1
}

kv_key() { printf '%s' "${1%%=*}"; }

# in_list <needle> <space-separated haystack>
in_list() {
    for _il in $2; do [ "$_il" = "$1" ] && return 0; done
    return 1
}

emit() { printf '%s\n' "$1" >> "$SQL_FILE"; }

# Refuse to emit a fixture carrying a real address. Two shapes are rejected: an
# email address, and any +digits run that is not a +1555000NNNN placeholder. A
# fixture with someone's number in it is a privacy incident in a tracked
# directory, and it is cheaper to fail here than to notice it in a diff.
#
# Takes the assembled SQL file rather than its contents, so the caller does not
# have to fork a cat to hand it over.
sanitise_guard() {
    _phones=$(grep -Eo '\+[0-9][0-9]{6,}' "$1" | grep -vE '^\+1555000[0-9]{4}$' || true)
    if [ -n "$_phones" ]; then
        die "refusing to emit a fixture containing a non-placeholder address: $(printf '%s' "$_phones" | sort -u | tr '\n' ' ')"
    fi
    # A bare run of exactly 11 digits is a NANP number written without its +.
    # Eleven is safe to name precisely: no other literal in this corpus is 11
    # digits long (the date base and ROWID stride are 19), so nothing that
    # belongs here can be caught by it. The placeholders are removed first,
    # because +15550000001 has 11 digits after its + and would otherwise trip
    # the rule it exists to enforce.
    _bare=$(sed 's/+1555000[0-9][0-9][0-9][0-9]//g' "$1" \
        | grep -Eo '(^|[^0-9])[0-9]{11}([^0-9]|$)' \
        | grep -Eo '[0-9]{11}' | sort -u || true)
    if [ -n "$_bare" ]; then
        die "refusing to emit a fixture containing a bare 11-digit number: $(printf '%s' "$_bare" | tr '\n' ' ')"
    fi
    _mails=$(grep -Eo '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}' "$1" || true)
    if [ -n "$_mails" ]; then
        die "refusing to emit a fixture containing an email address: $(printf '%s' "$_mails" | sort -u | tr '\n' ' ')"
    fi
}

# ------------------------------------------------------------- row writers --

MSG_COLUMNS="ROWID guid text attributedBody version type service handle_id account \
account_guid destination_caller_id subject date date_read date_delivered \
is_delivered is_finished is_from_me is_empty is_sent is_audio_message \
cache_has_attachments balloon_bundle_id payload_data associated_message_guid \
associated_message_type thread_originator_guid thread_originator_part date_edited \
is_retracted error is_system_message"

# Defaults that mean "no value" are sql:NULL, never the bare word NULL — see
# sql_lit. A bare NULL here becomes the four-character text 'NULL'.
MSG_DEFAULTS="text:sql:NULL attributedBody:sql:NULL payload_data:sql:NULL \
balloon_bundle_id:sql:NULL associated_message_guid:sql:NULL associated_message_type:sql:NULL \
thread_originator_guid:sql:NULL thread_originator_part:sql:NULL \
destination_caller_id:sql:NULL subject:sql:NULL account_guid:sql:NULL handle_id:sql:NULL \
version:0 type:0 date_read:0 date_delivered:0 date_edited:0 error:0 \
is_delivered:1 is_finished:1 is_sent:1 is_from_me:0 is_empty:0 is_audio_message:0 \
cache_has_attachments:0 is_retracted:0 is_system_message:0 service:iMessage \
account:REDACTED-ACCOUNT"

msg_default() {
    for _d in $MSG_DEFAULTS; do
        case $_d in
            "$1":*) printf '%s' "${_d#*:}"; return 0 ;;
        esac
    done
    return 1
}

# msg <rowid=N> <guid=G> [column=value ...]
#
# The canonical message row writer, and the reason --degraded is two lines
# rather than thirteen: the removed columns live in schema.sql only, and a case
# that tries to set one is an error rather than a quietly wrong database.
msg() {
    kv_get ROWID "$@" >/dev/null || die "msg: ROWID is required"
    kv_get guid "$@" >/dev/null || die "msg: guid is required"
    _mrowid=$(kv_get ROWID "$@")

    for _ma in "$@"; do
        _mk=$(kv_key "$_ma")
        if [ "$DEGRADED" = 1 ] && { [ "$_mk" = attributedBody ] || [ "$_mk" = payload_data ]; }; then
            die "case writes $_mk, which --degraded removes; run this case without --degraded"
        fi
        in_list "$_mk" "$MSG_COLUMNS" || die "msg: unknown message column '$_mk'"
    done

    _mcols=''
    _mvals=''
    for _mc in $MSG_COLUMNS; do
        # In --degraded these two are not in the table, so they are not in the
        # INSERT either. A default of NULL is not enough: the column list is
        # positional and naming a column that is not there is an error.
        if [ "$DEGRADED" = 1 ] \
            && { [ "$_mc" = attributedBody ] || [ "$_mc" = payload_data ]; }
        then
            continue
        fi
        if _mv=$(kv_get "$_mc" "$@"); then
            :
        elif [ "$_mc" = date ]; then
            _mv=$((EPOCH_BASE + _mrowid * ROWID_STRIDE))
        else
            _mv=$(msg_default "$_mc") || die "msg: no value or default for column '$_mc'"
        fi
        if [ -z "$_mcols" ]; then
            _mcols=$_mc
            _mvals=$(sql_lit "$_mv")
        else
            _mcols="$_mcols, $_mc"
            _mvals="$_mvals, $(sql_lit "$_mv")"
        fi
    done
    emit "INSERT INTO message ($_mcols) VALUES ($_mvals);"
}

# generic_row <label> <columns> <defaults> <k=v>...
generic_row() {
    _glabel=$1; _gcols=$2; _gdefaults=$3; shift 3
    _gc=''
    _gv=''
    for _gk in $_gcols; do
        if _gx=$(kv_get "$_gk" "$@"); then
            :
        else
            _gx=''
            for _gd in $_gdefaults; do
                case $_gd in
                    "$_gk":*) _gx=${_gd#*:}; break ;;
                esac
            done
            [ -n "$_gx" ] || [ "$_gk" = ROWID ] || [ "$_gk" = guid ] || [ "$_gk" = id ] \
                || die "$_glabel: no value or default for column '$_gk'"
        fi
        if [ -z "$_gc" ]; then
            _gc=$_gk; _gv=$(sql_lit "$_gx")
        else
            _gc="$_gc, $_gk"
            _gv="$_gv, $(sql_lit "$_gx")"
        fi
    done
    for _ga in "$@"; do
        in_list "$(kv_key "$_ga")" "$_gcols" || die "$_glabel: unknown column '$(kv_key "$_ga")'"
    done
    emit "INSERT INTO $_gtable ($_gc) VALUES ($_gv);"
}

handle_row() {
    _gtable=handle
    _hid=$(kv_get id "$@") || die "handle_row: id is required"
    generic_row handle_row \
        'ROWID id country service uncanonicalized_id person_centric_id' \
        "country:us service:iMessage uncanonicalized_id:$_hid person_centric_id:REDACTED-PERSON" \
        "$@"
}

chat_row() {
    _gtable=chat
    kv_get guid "$@" >/dev/null || die "chat_row: guid is required"
    generic_row chat_row \
        'ROWID guid chat_identifier service_name display_name style state' \
        'chat_identifier:REDACTED-CHAT service_name:iMessage display_name:REDACTED-CHAT style:45 state:3' \
        "$@"
}

attach_row() {
    _gtable=attachment
    kv_get guid "$@" >/dev/null || die "attach_row: guid is required"
    generic_row attach_row \
        'ROWID guid filename uti mime_type transfer_state total_bytes is_sticker hide_attachment' \
        'filename:FIXTURE-ATTACHMENT uti:public.data mime_type:application/octet-stream transfer_state:5 total_bytes:0 is_sticker:0 hide_attachment:0' \
        "$@"
}

chat_message()  { emit "INSERT INTO chat_message_join (chat_rowid, message_rowid) VALUES ($(sql_lit "$1"), $(sql_lit "$2"));"; }
msg_attachment(){ emit "INSERT INTO message_attachment_join (message_rowid, attachment_rowid) VALUES ($(sql_lit "$1"), $(sql_lit "$2"));"; }
chat_handle()   { emit "INSERT INTO chat_handle_join (chat_rowid, handle_rowid) VALUES ($(sql_lit "$1"), $(sql_lit "$2"));"; }

# ---------------------------------------------------------------- assembly --

build_sql() {
    SQL_FILE=$TMPDIR_FX/body.sql
    : > "$SQL_FILE"

    # One source of truth for both modes: a line ending `--optional:<name>` is
    # the whole of the degraded filter, and the marker shares the line with the
    # column so the match is exact and the two schemas cannot drift.
    if [ "$DEGRADED" = 1 ]; then
        grep -v -- '--optional:' "$SCHEMA" > "$SQL_FILE"
    else
        cat "$SCHEMA" > "$SQL_FILE"
    fi

    printf '\n' >> "$SQL_FILE"
    _func="case_$(printf '%s' "$CASE" | tr '-' '_')"
    command -v "$_func" >/dev/null 2>&1 || die "no such case function: $_func"
    "$_func" >> "$SQL_FILE"
    sanitise_guard "$SQL_FILE"
}

# ----------------------------------------------------------------- summary --

optional_report() {
    _mcols=$1
    _hcols=$2
    _have=''
    _miss=''
    for _oc in $OPTIONAL_MESSAGE_COLUMNS; do
        if in_list "$_oc" "$_mcols"; then _have="$_have $_oc"; else _miss="$_miss $_oc"; fi
    done
    for _oc in $OPTIONAL_HANDLE_COLUMNS; do
        if in_list "$_oc" "$_hcols"; then _have="$_have handle.$_oc"; else _miss="$_miss handle.$_oc"; fi
    done
    printf 'present:%s' "${_have# }"
    if [ -n "$_miss" ]; then printf ' absent:%s' "${_miss# }"; fi
}

# The summary is one sqlite3 process, not twenty. It used to be twenty, and the
# cost was not the twenty itself — it was that building a fixture and reading
# its own summary line forked twenty times, which is slow enough to be noticed
# and fragile enough to have lost a temp directory under load.
summary_line() {
    _db=$1
    _out=$2
    _tag="$CASE"
    [ "$DEGRADED" = 1 ] && _tag="$CASE-degraded"

    _sel=''
    for _t in $FIXTURE_TABLES; do
        if [ -z "$_sel" ]; then
            _sel="SELECT '$_t' AS tbl, count(*) AS n FROM \"$_t\""
        else
            _sel="$_sel UNION ALL SELECT '$_t', count(*) FROM \"$_t\""
        fi
    done

    _facts=$("$SQLITE" -separator '|' "$_db" "
SELECT 'tables', count(*) FROM sqlite_master WHERE type='table' AND name NOT GLOB 'sqlite_*'
UNION ALL SELECT 'total',   (SELECT sum(n) FROM ($_sel))
UNION ALL SELECT 'detail',  (SELECT group_concat(tbl || ' ' || n, ', ') FROM ($_sel))
UNION ALL SELECT 'msgcols', (SELECT group_concat(name, ' ') FROM pragma_table_info('message'))
UNION ALL SELECT 'hdcols',  (SELECT group_concat(name, ' ') FROM pragma_table_info('handle'));
") || die "could not read the summary facts back out of $_db"

    _tables=$(printf '%s' "$_facts" | awk -F'|' '$1 == "tables"  { print $2 }')
    _total=$(printf '%s' "$_facts"  | awk -F'|' '$1 == "total"   { print $2 }')
    _detail=$(printf '%s' "$_facts" | awk -F'|' '$1 == "detail"  { print $2 }')
    _mcols=$(printf '%s' "$_facts"   | awk -F'|' '$1 == "msgcols" { print $2 }')
    _hcols=$(printf '%s' "$_facts"   | awk -F'|' '$1 == "hdcols"  { print $2 }')

    printf 'CHATDB_FIXTURE %s -> %s | tables %s | rows %s [%s] | optional columns %s\n' \
        "$_tag" "$_out" "$_tables" "$_total" "$_detail" \
        "$(optional_report "$_mcols" "$_hcols")"
}

list_cases() {
    for _c in $ALL_CASES; do
        printf '%-26s %s\n' "$_c" "$(case_purpose "$_c")"
    done
}

# -------------------------------------------------------------------- main --

DEGRADED=0
DEGRADED_FLAG=
WANT_SQL=0
WANT_ALL=0
OUTDIR=$HERE
CASE=

# Sourced before the arguments are read: --list and --all both need
# ALL_CASES and case_purpose, and neither needs a database.
[ -f "$SCHEMA" ] || die "schema not found at $SCHEMA"
[ -f "$CASES" ]  || die "case file not found at $CASES"
command -v "$SQLITE" >/dev/null 2>&1 || die "sqlite3 not found at '$SQLITE'; override with SQLITE="
. "$CASES"

while [ $# -gt 0 ]; do
    case $1 in
        --degraded) DEGRADED=1; DEGRADED_FLAG=--degraded ;;
        --sql)      WANT_SQL=1 ;;
        --outdir)   shift; [ $# -gt 0 ] || die "--outdir needs a directory"; OUTDIR=$1 ;;
        --list)     list_cases; exit 0 ;;
        --all)      WANT_ALL=1 ;;
        -h|--help)  sed -n '3,20p' "$0" | sed 's/^#\{1,\} \{0,1\}//'; exit 0 ;;
        -*)         die "unknown option '$1' (try --help)" ;;
        *)          if [ -n "$CASE" ]; then die "more than one case named ('$CASE' and '$1')"; fi
                    CASE=$1 ;;
    esac
    shift
done

# Every flag is read before anything is built, so `--all --outdir DIR` writes
# where it says rather than where the order of the words happened to put it.
if [ "$WANT_ALL" = 1 ]; then
    if [ -n "$CASE" ]; then
        "$0" "$CASE" ${DEGRADED_FLAG:+"$DEGRADED_FLAG"} --outdir "$OUTDIR"
    else
        for _c in $ALL_CASES; do
            "$0" "$_c" ${DEGRADED_FLAG:+"$DEGRADED_FLAG"} --outdir "$OUTDIR" || exit 1
        done
    fi
    exit 0
fi

[ -n "$CASE" ] || die "no case named; try --list"
in_list "$CASE" "$ALL_CASES" || die "unknown case '$CASE'; try --list"

TMPDIR_FX=$(mktemp -d "${TMPDIR:-/tmp}/chatdb-fixture.XXXXXX")
build_sql

if [ "$WANT_SQL" = 1 ]; then
    cat "$SQL_FILE"
    exit 0
fi

mkdir -p "$OUTDIR"
OUT=$OUTDIR/$CASE.sqlite
[ "$DEGRADED" = 1 ] && OUT=$OUTDIR/$CASE-degraded.sqlite
rm -f "$OUT"

# One write transaction, PRAGMAs outside it (page_size is a no-op inside one).
{
    grep -E '^PRAGMA ' "$SQL_FILE"
    printf 'BEGIN;\n'
    grep -v -E '^PRAGMA ' "$SQL_FILE"
    printf 'COMMIT;\n'
} > "$TMPDIR_FX/run.sql"

"$SQLITE" "$OUT" < "$TMPDIR_FX/run.sql" || die "sqlite3 failed building $OUT"
summary_line "$OUT" "$OUT"
