"""Lifecycle regressions; fake child processes never download or load a model."""
import json
import os
from pathlib import Path
import tempfile
import unittest
import subprocess
import sys
from unittest.mock import patch

import tts_compare as bench


class SerialModelsTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="tts-runner-test-")
        self.root = Path(self.temporary.name)
        self.output = self.root / "reports"
        self.output.mkdir()
        self.app = self.root / "fake-app"
        self.app.write_text('''#!/usr/bin/env python3
import json, pathlib, sys, time, tempfile
a = sys.argv
def arg(k): return a[a.index(k) + 1]
root = pathlib.Path(arg("--tts-model-root"))
assert pathlib.Path(tempfile.gettempdir()).resolve() == root.resolve()
(root / "fake-weight").write_bytes(b"test-only")
engine = arg("--tts-engine")
if arg("--tts-text") == "timeout": time.sleep(30)
if arg("--tts-text") == "failure": sys.exit(1)
speaker = "--tts-speaker-output" in a
trial = {"phase": "warm", "firstPCMms": 12.0}
if speaker:
 trial = {"phase": "warm", "output": {"qualified": arg("--tts-text") != "unqualified",
          "acousticOnsetMs": None if arg("--tts-text") == "unqualified" else 34.0}}
pathlib.Path(arg("--tts-report")).write_text(json.dumps({
 "schema": "nextnotes.tts-speaker-output.v1" if speaker else "nextnotes.tts-first-pcm.v1", "engine": engine,
 "trials": [trial] * int(arg("--tts-trials"))}))
''')
        self.app.chmod(0o700)
        self.created = []
        self.original_mkdtemp = tempfile.mkdtemp
        def create(**kwargs):
            # A new engine cannot start while its predecessor's model still exists.
            self.assertTrue(all(not path.exists() for path in self.created))
            path = Path(self.original_mkdtemp(dir=self.root, **kwargs))
            self.created.append(path)
            return str(path)
        self.patches = [
            patch.object(bench.tempfile, "mkdtemp", side_effect=create),
            patch.object(bench.shutil, "disk_usage", return_value=type("Disk", (), {"free": 10**12})()),
        ]
        for item in self.patches: item.start()

    def tearDown(self):
        for item in reversed(self.patches): item.stop()
        self.temporary.cleanup()

    def run_engine(self, engine="phonon", text="fixture", timeout=5):
        return bench.run_one(self.app, engine, self.output, 3, text, timeout)

    def test_next_model_starts_only_after_previous_result_and_cleanup(self):
        for engine in ("phonon", "qwen"):
            result = self.run_engine(engine)
            self.assertEqual(result["status"], "measured")
            self.assertTrue(result["cleanupVerified"])
            self.assertTrue((self.output / (engine + ".json")).exists())
        self.assertEqual(len(self.created), 2)

    def test_speaker_mode_preserves_qualified_pickup_boundary(self):
        result = bench.run_one(self.app, "phonon", self.output, 3, "fixture", 5, speaker_output=True)
        self.assertEqual(result["timingBoundary"], "microphone-pickup")
        self.assertEqual(result["warmMedianMs"], 34)
        self.assertTrue(result["cleanupVerified"])

    def test_unqualified_acoustic_samples_never_become_a_zero_or_generated_pcm_result(self):
        result = bench.run_one(self.app, "phonon", self.output, 3, "unqualified", 5, speaker_output=True)
        self.assertEqual(result["status"], "partial")
        self.assertNotIn("warmMedianMs", result)
        self.assertIsNone(result["measurement"]["trials"][0]["output"]["acousticOnsetMs"])
        self.assertTrue(result["cleanupVerified"])

    def test_result_is_on_disk_before_model_deletion(self):
        original = bench.shutil.rmtree
        def remove(path, *args, **kwargs):
            self.assertEqual(json.loads((self.output / "phonon.json").read_text())["status"], "measured")
            self.assertTrue((Path(path) / "fake-weight").exists())
            return original(path, *args, **kwargs)
        with patch.object(bench.shutil, "rmtree", side_effect=remove):
            self.run_engine()

    def test_failed_child_saves_failure_and_deletes_only_its_model(self):
        owner_model = self.root / "installed-owner-model"
        owner_model.write_bytes(b"preserve")
        result = self.run_engine(text="failure")
        self.assertEqual(result["status"], "failed")
        self.assertTrue(result["cleanupVerified"])
        self.assertEqual(owner_model.read_bytes(), b"preserve")

    def test_timeout_joins_child_before_cleanup(self):
        result = self.run_engine(text="timeout", timeout=.1)
        self.assertIn("Timed out", result["reason"])
        self.assertTrue(result["cleanupVerified"])

    def test_disk_pressure_after_start_stops_and_cleans_model(self):
        initial = type("Disk", (), {"free": 10**12})()
        pressured = type("Disk", (), {"free": 100})()
        with patch.object(bench.shutil, "disk_usage", side_effect=[initial, pressured, initial]):
            result = self.run_engine(text="timeout", timeout=5)
        self.assertIn("Disk guard", result["reason"])
        self.assertTrue(result["cleanupVerified"])
        self.assertEqual(result["freeBytesAfterCleanup"], initial.free)

    def test_no_disk_means_no_child_or_download(self):
        with patch.object(bench.shutil, "disk_usage", return_value=type("Disk", (), {"free": 100})()), \
             patch.object(bench.subprocess, "Popen") as start:
            result = self.run_engine()
            start.assert_not_called()
        self.assertEqual(result["status"], "not-run")
        self.assertTrue(result["cleanupVerified"])

    def test_save_failure_retains_only_model_and_halts(self):
        with patch.object(bench, "save", side_effect=OSError("disk full")):
            with self.assertRaises(OSError): self.run_engine()
        self.assertTrue((self.created[0] / "fake-weight").exists())

    @unittest.skipUnless(sys.platform == "darwin", "APFS clone command is macOS-specific")
    def test_cow_command_keeps_owner_bytes_and_resolves_links(self):
        source = self.root / "installed-cache"
        source.mkdir()
        (source / "weight").write_bytes(b"original")
        (source / "alias").symlink_to(source / "weight")
        clone = self.root / "disposable-clone"
        subprocess.run(["/bin/cp", "-cRL", str(source), str(clone)], check=True)
        self.assertFalse((clone / "alias").is_symlink())
        (clone / "alias").write_bytes(b"updated")
        self.assertEqual((source / "weight").read_bytes(), b"original")
        bench.shutil.rmtree(clone)
        self.assertEqual((source / "weight").read_bytes(), b"original")


if __name__ == "__main__":
    unittest.main()
