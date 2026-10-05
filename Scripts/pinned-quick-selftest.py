#!/usr/bin/env python3
"""Exercise scoring and machine admission without launching a model or native app."""
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('pinned_quick', Path(__file__).with_name('pinned-quick.py'))
quick = importlib.util.module_from_spec(spec)
spec.loader.exec_module(quick)
PIN = 'installed-fixture-model'
NOW = '2026-10-04T12:00:00-04:00'


class QuickInstrumentTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='nextnotes-quick-contract-')
        self.addCleanup(self.temp.cleanup)
        self.report = Path(self.temp.name) / 'run1.md'
        self.rows = [{'id': f'case{index}', 'verdict': 'PASS' if index < 7 else 'FAIL',
                      'modelPin': PIN, 'fixtureNow': NOW,
                      'rawRounds': [{'index': 1, 'raw': 'é🙂' * 401}, {'index': 2, 'raw': 'next'}]}
                     for index in range(10)]
        self.output = f'TOOLLOOP_LIVE_CLOCK: {NOW} timezone=America/New_York\n' \
                      'TOOLLOOP_LIVE_MODEL: appLLM "fixture" ctx=8192\nTOOLLOOP_LIVE_FAILED: 7/10\n'

    def score(self, output=None, code=1):
        Path(str(self.report) + '.jsonl').write_text('\n'.join(json.dumps(row) for row in self.rows))
        return quick.read_score(self.report, self.output if output is None else output, code, PIN, NOW)

    def test_below_bar_is_a_valid_result_with_actual_app_report_filename(self):
        self.assertEqual(self.score(), (7, 'appLLM "fixture" ctx=8192', 'America/New_York'))
        stored = json.loads(Path(str(self.report) + '.jsonl').read_text().splitlines()[0])
        self.assertEqual(stored['rawRounds'][0]['raw'], 'é🙂' * 401)
        self.assertEqual(len(stored['rawRounds']), 2)

    def test_final_score_must_match_rows(self):
        with self.assertRaises(RuntimeError): self.score(self.output.replace('7/10', '8/10'))

    def test_exit_status_must_match_score(self):
        with self.assertRaises(RuntimeError): self.score(code=0)

    def test_missing_rows_cannot_be_scored(self):
        self.rows.pop()
        with self.assertRaises(RuntimeError): self.score()

    def test_duplicate_rows_cannot_be_scored(self):
        self.rows[-1]['id'] = self.rows[0]['id']
        with self.assertRaises(RuntimeError): self.score()

    def test_fallback_cannot_be_scored(self):
        with self.assertRaises(RuntimeError): self.score(self.output.replace('ctx=8192', 'ctx=8192 FALLBACK'))

    def test_legacy_truncated_report_is_refused(self):
        del self.rows[0]['rawRounds']
        with self.assertRaises(RuntimeError): self.score()

    def test_row_model_and_clock_are_checked(self):
        for field in ('modelPin', 'fixtureNow'):
            original = self.rows[0][field]
            self.rows[0][field] = 'changed'
            with self.assertRaises(RuntimeError): self.score()
            self.rows[0][field] = original

    def test_clock_receipt_is_required(self):
        with self.assertRaises(RuntimeError): self.score(self.output.replace(NOW, 'changed'))

    def test_binary_replacement_is_detected(self):
        binary = Path(self.temp.name) / 'NextNotes'
        binary.write_bytes(b'first')
        identity = quick.binary_identity(binary)
        replacement = binary.with_suffix('.new')
        replacement.write_bytes(b'first')
        replacement.replace(binary)
        self.assertNotEqual(quick.binary_identity(binary), identity)

    def test_resource_limits_fail_before_model_launch(self):
        for load, swap, free in ((41, 0, 20), (3, 8193, 20), (3, 0, 9)):
            with patch.object(quick.os, 'getloadavg', return_value=(load, 0, 0)), \
                 patch.object(quick.subprocess, 'check_output', return_value=f'used = {swap}M'), \
                 patch.object(quick.shutil, 'disk_usage', return_value=type('Disk', (), {'free': free * 1024**3})()):
                with self.assertRaises(RuntimeError): quick.machine_state(self.temp.name)


if __name__ == '__main__':
    unittest.main()
