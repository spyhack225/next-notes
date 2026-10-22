#!/bin/bash
# Root serial native slot only. Every target is a newly created harmless temp fixture.
set -eu
if [ "$#" -ne 2 ]; then echo 'usage: negative-input-launcher.sh installed-executable case'; exit 2; fi
binary=$1
case_name=$2
case "$binary" in /*) ;; *) echo 'absolute installed executable required'; exit 2;; esac
case "$case_name" in directory|folders-directory|gws-directory|formatting|runs|mcp|pairing|library|usage|rotated) ;; *) echo 'known case required'; exit 2;; esac
base=${TMPDIR:?system temporary directory required}
system_base=$(getconf DARWIN_USER_TEMP_DIR) || { echo 'system temporary lookup failed'; exit 2; }
[ -d "$base" ] && [ -d "$system_base" ] || { echo 'existing system temporary directory required'; exit 2; }
[ "$(cd "$base" && pwd -P)" = "$(cd "$system_base" && pwd -P)" ] || { echo 'non-system temporary directory refused'; exit 2; }
fixture_root="${base%/}/NextNotesSelfTest-$$"
folder_root="${base%/}/NextNotesSelfTest-folders-$$"
[ ! -e "$fixture_root" ] && [ ! -L "$fixture_root" ] || { echo 'existing process root refused'; exit 2; }
[ ! -e "$folder_root" ] && [ ! -L "$folder_root" ] || { echo 'existing folders root refused'; exit 2; }
test_root=$(mktemp -d "${base%/}/NextNotesSettingsNegative.XXXXXX")
mkdir "$test_root/harmless-directory"
printf '%s\n' 'harmless visual fixture sentinel' > "$test_root/sentinel.txt"
output="$test_root/captures"
case "$case_name" in
 directory) ln -s "$test_root/harmless-directory" "$fixture_root" ;;
 folders-directory) mkdir "$fixture_root"; ln -s "$test_root/harmless-directory" "$folder_root" ;;
 gws-directory) mkdir "$fixture_root"; ln -s "$test_root/harmless-directory" "$fixture_root/gws" ;;
 *) mkdir "$fixture_root"
    case "$case_name" in
      formatting) input="$fixture_root/formatting.txt";;
      runs) input="$fixture_root/runs.jsonl";;
      mcp) input="$fixture_root/mcp-servers.json";;
      pairing) input="$fixture_root/imessage-settings.json";;
      library) mkdir "$fixture_root/Models"; input="$fixture_root/Models/library.json";;
      usage) input="$fixture_root/usage.jsonl";;
      rotated) input="$fixture_root/usage.1.jsonl";;
    esac
    ln -s "$test_root/sentinel.txt" "$input";;
esac
# All paths in this metadata are freshly made temporary fixtures. No owner values.
printf '%s\n' "$case_name" "$$" "$fixture_root" "$folder_root" "$test_root" "$output" > "$test_root/metadata.txt"
shasum -a 256 "$test_root/sentinel.txt" > "$test_root/target-before.sha256"
echo "NEGATIVE_FIXTURE_METADATA=$test_root/metadata.txt"
# exec preserves shell PID, binding the diagnostic's existing process root to the seed.
exec "$binary" --selftest-settings-sheet "$output" --settings-pane agent --width 320
