#!/bin/sh
# Native batch; invoke ONLY through ../heavy.sh. No real account or managed download.
set -u
mode=$1
binary=$2
evidence=$3
mkdir -p "$evidence"
fixture=$(mktemp -d "${TMPDIR:-/tmp/}google-c-gws.XXXXXX")
trap 'rm -rf "$fixture"' EXIT HUP INT TERM
cat > "$fixture/gws" <<'FIXTURE'
#!/bin/sh
if [ "$1" = --version ]; then echo 'gws 0.22.5'; exit 0; fi
if [ "$1" = auth ] && [ "$2" = status ]; then
  echo '{"auth_method":"oauth","client_config_exists":true,"encrypted_credentials_exists":true,"plain_credentials_exists":false,"token_cache_exists":false,"storage":"isolated fixture"}'
  exit 0
fi
echo '{}'
FIXTURE
chmod 755 "$fixture/gws"
failed=0
run() {
    name=$1; expected=$2; shift 2
    : > "$evidence/$name.log"
    "$binary" "$@" --selftest-out "$evidence/$name.log" > "$evidence/$name.stdout.log" 2>&1
    code=$?
    printf '%s exit=%s\n' "$name" "$code" | tee -a "$evidence/exits.txt"
    if ! rg -q "^$expected([: ]|$)" "$evidence/$name.log" "$evidence/$name.stdout.log"; then
        printf '%s MISSING_EXPECTED_MARKER %s\n' "$name" "$expected"
        failed=1
    fi
    case "$mode" in
    green|restored) if [ "$code" != 0 ]; then failed=1; fi;;
    *)
        if [ "$expected" = GOOGLE_CONNECT_FAILED ] || [ "$expected" = MAC_ACCOUNTS_FAILED ]; then
            if [ "$code" != 1 ]; then echo "$name RED_REQUIRES_NATIVE_EXIT_1"; failed=1; fi
            case "$mode" in
                review-red)
                    while IFS= read -r target; do
                        if ! rg -q -F -x "  FAIL $target" "$evidence/$name.log"; then
                            echo "$name MISSING_NAMED_BEHAVIORAL_ASSERTION: $target"; failed=1
                        fi
                    done <<'TARGETS'
R1 denied read never runs the runnable alternate login
R2 after-token cancelled send has zero backing entries
R3 outstanding old invalid_grant cannot delete a real successful reconnect
R4 delayed 401 invalidates only rejected A and never cancels refresh B
R5 probing planner excludes known missing Mail permission from allowed and selected tools
R6 actual connect flow enables and lists Calendar only when granted (false)
TARGETS
                    ;;
                remaining-red)
                    while IFS= read -r target; do
                        if ! rg -q -F -x "  FAIL $target" "$evidence/$name.log"; then
                            echo "$name MISSING_NAMED_BEHAVIORAL_ASSERTION: $target"; failed=1
                        fi
                    done <<'TARGETS'
R3 completed successful refresh refuses old token delivery to creator after reconnect
R3 completed successful refresh refuses old token delivery to joining waiter after reconnect
R3 successful creator delivery checks exact replaced record without actor invalidation
R3 successful joining waiter delivery checks exact replaced record without actor invalidation
R3 before-token grant replacement has zero executable backing entries
R3 after-token grant replacement has zero executable backing entries
R3 inside-spawn grant replacement has zero executable backing entries
R6 connection controller withdrawal clears populated Calendar list while switching Calendar off
R6 connection controller disconnect clears populated Calendar list even when already off
TARGETS
                    ;;
                withdrawal-red) target='^  FAIL R6 withdrawn Calendar permission immediately clears actual cached calendars and upcoming events' ;;
                revocation) target='^  FAIL a rejected client must not read as a revoked grant' ;;
                unpinned) target='^  FAIL an unpinned alternate executable cannot receive the app token' ;;
                mailbox) target='^  FAIL mail from another account is never reachable by any query' ;;
                draft-red) target='^  FAIL the cancelled shared-refresh caller never enters executable backing' ;;
                original) target='^  FAIL the sign-in asks for the full Workspace set and nothing else' ;;
            esac
            if [ "$mode" != review-red ] && [ "$mode" != remaining-red ] && ! rg -q "$target" "$evidence/$name.log"; then
                echo "$name MISSING_TARGETED_FAILING_ASSERTION"; failed=1
            fi
        fi ;;
    esac
    rg "^[A-Z_]+_(OK|FAILED)" "$evidence/$name.stdout.log" | tail -3
}
case "$mode" in
original)
    run task-authority TASK_AUTHORITY_OK --selftest-task-authority
    run google-connect GOOGLE_CONNECT_FAILED --selftest-google-connect
    ;;
green|restored)
    run google-connect GOOGLE_CONNECT_OK --selftest-google-connect
    run gws GWS_OK --selftest-gws --gws-fixture-root "$fixture"
    run calendar CALENDAR_OK --selftest-calendar --calendar-google-errors
    run mac-accounts MAC_ACCOUNTS_OK --selftest-mac-accounts
    run capability-manifest CAPABILITY_MANIFEST_OK --selftest-capability-manifest
    run ui-strings UI_STRINGS_OK --selftest-ui-strings
    run store-isolation STORE_ISOLATION_OK --selftest-store-isolation
    ;;
revocation|unpinned|draft-red|review-red|withdrawal-red|remaining-red)
    run google-connect GOOGLE_CONNECT_FAILED --selftest-google-connect
    ;;
mailbox)
    run mac-accounts MAC_ACCOUNTS_FAILED --selftest-mac-accounts
    ;;
*) echo 'unknown batch' >&2; exit 64;;
esac
if [ "$mode" = green ] && [ "$failed" = 0 ]; then
    # The queued guarded command enters here only after every GREEN flag passed.
    # Keep the necessary mutation builds in this same machine claim, then recheck.
    shasum -a 256 "$binary" > "$(dirname "$evidence")/green-binary-sha256.txt"
    python3 Tests/GoogleOptionCReplay.py capture .google-replay-snapshot
    sh Tests/GoogleOptionCMutations.sh "$(dirname "$(dirname "$binary")")" "$(dirname "$evidence")"
    failed=$?
fi
exit "$failed"
