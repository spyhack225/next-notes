#!/usr/bin/env python3
"""Exercise the real read-only diagnostic CLI against temporary owner-store shapes."""
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


SCRIPT = Path(__file__).with_name("dictation-stats.py")
WHEN = "2026-09-29T12:00:00Z"
D14 = "D-14 per-pass ASR lane"


def row(feature, **extra):
    return {"feature": feature, "ts": WHEN, **extra}


class DictationGateCLITests(unittest.TestCase):
    def run_reader(self, records, *arguments, meetings=()):
        with tempfile.TemporaryDirectory(prefix="nextnotes-gates-") as directory:
            home = Path(directory)
            store = home / "Library/Application Support/Next Notes"
            store.mkdir(parents=True)
            usage = store / "usage.jsonl"
            usage.write_text("".join(json.dumps(r) + "\n" for r in records))
            for meeting in meetings:
                folder = store / "Meetings" / meeting["id"]
                folder.mkdir(parents=True)
                (folder / "meeting.json").write_text(json.dumps(meeting))
            def snapshot():
                return {str(p.relative_to(store)): hashlib.sha256(p.read_bytes()).hexdigest()
                        for p in store.rglob("*") if p.is_file()}
            before = snapshot()
            env = {**os.environ, "HOME": str(home), "PYTHONDONTWRITEBYTECODE": "1"}
            result = subprocess.run(
                [sys.executable, str(SCRIPT), *arguments, "--json"],
                env=env, capture_output=True, text=True, timeout=5,
            )
            self.assertEqual(snapshot(), before, "reader changed fixture store")
            self.assertEqual(result.returncode, 0, result.stderr)
            return json.loads(result.stdout)

    def test_gates_cli_with_hold_reproduces_original_crash(self):
        report = self.run_reader([row("dictation.hold", totalMs=800)], "--gates")
        self.assertEqual(report["gates"][D14]["verdict"], "not enough data")

    def test_three_measured_asr_waits_proceed_without_meeting_rows(self):
        records = [row("dictation.hold", totalMs=800)]
        records += [row("dictation.asr", stages={"laneWait": wait}) for wait in (1, 1.1, 3)]
        # Full mode already ran before the fix; this catches the omitted gate condition
        # independently of the early --gates crash.
        gate = self.run_reader(records)["gates"][D14]
        self.assertEqual(gate["verdict"], "proceed")
        self.assertEqual(gate["dictation_starts_with_lane_wait_ge_1s"], 3)

    def test_two_waits_do_not_lower_three_occurrence_threshold(self):
        records = [row("dictation.hold", totalMs=800)]
        records += [row("dictation.asr", stages={"laneWait": 1.2}) for _ in range(2)]
        gate = self.run_reader(records, "--gates")["gates"][D14]
        self.assertEqual(gate["dictation_starts_with_lane_wait_ge_1s"], 2)
        self.assertNotEqual(gate["verdict"], "proceed")

    def test_other_features_and_unmeasured_asr_do_not_count(self):
        records = [row("dictation.hold", totalMs=800)]
        records += [row(feature, stages={"laneWait": 20}) for feature in
                    ("dictation.hold", "dictation.cleanup", "meeting.transcribe")]
        records += [row("dictation.asr"), row("dictation.asr", stages={"laneWait": None})]
        gate = self.run_reader(records, "--gates")["gates"][D14]
        self.assertFalse(gate["dictation_side_lane_wait_recorded"])
        self.assertEqual(gate["dictation_starts_with_lane_wait_ge_1s"], 0)
        self.assertEqual(gate["verdict"], "not enough data")

    def test_threshold_and_invalid_measurements(self):
        records = [row("dictation.hold", totalMs=800)]
        records += [row("dictation.asr", stages={"laneWait": wait})
                    for wait in (0, 0.999, 1, -1, "10", True, float("nan"), float("inf"))]
        gate = self.run_reader(records, "--gates")["gates"][D14]
        self.assertTrue(gate["dictation_side_lane_wait_recorded"])
        self.assertEqual(gate["dictation_starts_with_lane_wait_ge_1s"], 1)
        self.assertEqual(gate["worst_dictation_start_lane_wait_s"], 1)
        self.assertNotEqual(gate["verdict"], "proceed")

    def test_since_filters_asr_waits_and_legacy_stamp_still_reads(self):
        records = [row("dictation.hold", totalMs=800)]
        records += [row("dictation.asr", ts="2026-09-20T12:00:00Z",
                        stages={"laneWait": 9}) for _ in range(3)]
        records += [{"feature": "dictation.asr", "startedAt": WHEN,
                     "stages": {"laneWait": 1.2}}]
        records += [{"feature": "dictation.asr", "date": WHEN,
                     "stages": {"laneWait": 1.3}}]
        records += [row("dictation.asr", ts="invalid", stages={"laneWait": 9})]
        gate = self.run_reader(records, "--gates", "--since", "2026-09-25")["gates"][D14]
        self.assertEqual(gate["dictation_starts_with_lane_wait_ge_1s"], 2)
        self.assertNotEqual(gate["verdict"], "proceed")

    def test_full_and_gates_modes_agree(self):
        records = [row("dictation.hold", totalMs=800)]
        records += [row("dictation.asr", stages={"laneWait": 1}) for _ in range(3)]
        self.assertEqual(self.run_reader(records)["gates"],
                         self.run_reader(records, "--gates")["gates"])

    def test_empty_store_is_not_a_pass(self):
        report = self.run_reader([], "--gates")
        self.assertTrue(all(gate["verdict"] == "not enough data"
                            for gate in report["gates"].values()))

    def test_original_d13_minimum_hold_gate_unchanged(self):
        records = [row("dictation.hold", totalMs=800)] * 99
        report = self.run_reader(records, "--gates", "--since", "2026-09-01")
        gate = report["gates"]["D-13 pipelined holds"]
        self.assertEqual(gate["holds"], 99)
        self.assertEqual(gate["verdict"], "not enough data")
        self.assertEqual(gate["threshold_per_100"], 3.0)

    def test_original_meeting_overlap_proceed_condition_unchanged(self):
        records = [row("dictation.hold", totalMs=800) for _ in range(3)]
        records += [row("meeting.transcribe", meetingID="fixture-meeting",
                        stages={"laneWait": 5})]
        meetings = [{"id": "fixture-meeting", "start": "2026-09-29T11:59:00Z",
                     "end": "2026-09-29T12:01:00Z"}]
        gate = self.run_reader(records, "--gates", meetings=meetings)["gates"][D14]
        self.assertEqual(gate["overlaps_with_window_wait_ge_5s"], 3)
        self.assertEqual(gate["verdict"], "proceed")

    def test_known_zero_waits_preserve_negative_evidence_verdict(self):
        records = [row("dictation.hold", totalMs=800)]
        records += [row("meeting.transcribe", meetingID="fixture-meeting",
                        stages={"laneWait": 0}),
                    row("dictation.asr", stages={"laneWait": 0})]
        gate = self.run_reader(records, "--gates")["gates"][D14]
        self.assertTrue(gate["dictation_side_lane_wait_recorded"])
        self.assertEqual(gate["verdict"], "won't do (evidence)")


if __name__ == "__main__":
    unittest.main()
