#!/usr/bin/env python3
"""One-off cleanup for self-test rows earlier builds wrote into the owner's stores.

P0-11. The app now keeps a self-test out of the real files, but rows written before
those guards existed are still in `agent-tasks.json` and `agent-audit.jsonl`. This
removes them, and nothing else:

  * tasks whose `objective` starts with "Self-test ";
  * audit rows from 2026-09-13 whose JSON contains "mcp.fixture" or
    "Send the deck to Sam".

Dry run by default. `--apply` writes; every file it changes is backed up first as
`<name>.bak-YYYYMMDDHHMMSS` beside the original. Memory is never touched —
`next-memory.json` is not opened at all.
"""

from __future__ import annotations

import argparse
import datetime
import json
import os
import shutil
import sys

DEFAULT_SUPPORT = os.path.expanduser("~/Library/Application Support/Next Notes")
TASKS_NAME = "agent-tasks.json"
AUDIT_NAME = "agent-audit.jsonl"
AUDIT_DAY = "2026-09-13"
AUDIT_NEEDLES = ("mcp.fixture", "Send the deck to Sam")
TASK_PREFIX = "Self-test "


def parse_args(argv):
    parser = argparse.ArgumentParser(
        description="Remove pre-P0-11 self-test rows from the owner's task and audit files."
    )
    parser.add_argument(
        "--support-dir",
        default=DEFAULT_SUPPORT,
        help=f"where {TASKS_NAME} and {AUDIT_NAME} live (default: %(default)s)",
    )
    parser.add_argument(
        "--apply",
        action="store_true",
        help="write the changes; without it this is a dry run",
    )
    return parser.parse_args(argv)


def is_self_test_task(row):
    """True for a task a self-test wrote: `objective` starts with "Self-test "."""
    if not isinstance(row, dict):
        return False
    objective = row.get("objective")
    return isinstance(objective, str) and objective.startswith(TASK_PREFIX)


def is_on_audit_day(value):
    """The row's `at` falls on 2026-09-13, in UTC.

    The prefix test is the one that matters — the app writes ISO-8601 UTC — and the
    parse is there for an offset or fractional-seconds form Python's `fromisoformat`
    can still read.
    """
    if not isinstance(value, str) or not value:
        return False
    if value.startswith(AUDIT_DAY):
        return True
    try:
        moment = datetime.datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        return False
    if moment.tzinfo is None:
        moment = moment.replace(tzinfo=datetime.timezone.utc)
    return moment.astimezone(datetime.timezone.utc).date().isoformat() == AUDIT_DAY


def is_fixture_audit_row(raw):
    """True for a pre-guard fixture row: 2026-09-13 and one of the two markers."""
    try:
        row = json.loads(raw)
    except ValueError:
        return False
    if not isinstance(row, dict) or not is_on_audit_day(row.get("at")):
        return False
    return any(needle in raw for needle in AUDIT_NEEDLES)


def backup(path, stamp):
    destination = f"{path}.bak-{stamp}"
    shutil.copy2(path, destination)
    return destination


def clean_tasks(path, stamp, apply_changes):
    """Returns (removed, total, backup_path_or_none)."""
    with open(path, "r", encoding="utf-8") as handle:
        rows = json.load(handle)
    if not isinstance(rows, list):
        raise ValueError(f"{path} does not hold a JSON array")
    kept = [row for row in rows if not is_self_test_task(row)]
    removed = len(rows) - len(kept)
    written = None
    if removed and apply_changes:
        written = backup(path, stamp)
        with open(path, "w", encoding="utf-8") as handle:
            json.dump(kept, handle, indent=2, sort_keys=True)
            handle.write("\n")
    return removed, len(rows), written


def clean_audit(path, stamp, apply_changes):
    """Returns (removed, total, backup_path_or_none). Blank lines are never removed."""
    with open(path, "r", encoding="utf-8") as handle:
        lines = handle.readlines()
    kept = [line for line in lines if not is_fixture_audit_row(line)]
    removed = len(lines) - len(kept)
    written = None
    if removed and apply_changes:
        written = backup(path, stamp)
        with open(path, "w", encoding="utf-8") as handle:
            handle.writelines(kept)
    return removed, len(lines), written


def report(label, path, result, apply_changes):
    if result is None:
        print(f"{label}: not found at {path}")
        return
    removed, total, written = result
    verb = "removed" if apply_changes else "to remove"
    print(f"{label}: {removed} {verb} of {total}")
    if written:
        print(f"  backup: {written}")


def main(argv):
    args = parse_args(argv)
    support = os.path.abspath(os.path.expanduser(args.support_dir))
    stamp = datetime.datetime.now().strftime("%Y%m%d%H%M%S")
    mode = "APPLY" if args.apply else "DRY RUN (nothing written)"

    print(f"self-test row cleanup — {mode}")
    print(f"support dir: {support}")

    tasks_path = os.path.join(support, TASKS_NAME)
    audit_path = os.path.join(support, AUDIT_NAME)

    tasks = None
    if os.path.isfile(tasks_path):
        try:
            tasks = clean_tasks(tasks_path, stamp, args.apply)
        except (OSError, ValueError) as error:
            print(f"{TASKS_NAME}: could not be read: {error}", file=sys.stderr)
            return 2

    audit = None
    if os.path.isfile(audit_path):
        try:
            audit = clean_audit(audit_path, stamp, args.apply)
        except OSError as error:
            print(f"{AUDIT_NAME}: could not be read: {error}", file=sys.stderr)
            return 2

    report(TASKS_NAME, tasks_path, tasks, args.apply)
    report(AUDIT_NAME, audit_path, audit, args.apply)
    # The line the success threshold reads. The script has no memory path at all.
    print("memory rows touched: 0 (next-memory.json is never opened)")

    if not args.apply:
        print("rerun with --apply to write; each changed file is backed up first")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
