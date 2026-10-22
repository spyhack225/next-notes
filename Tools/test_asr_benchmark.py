"""External download-boundary and serial diagnostic lock regressions; no models."""
import fcntl
import hashlib
import io
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch
from asr_benchmark import download_files, error_rate


class ASRBenchmarkBoundaryTests(unittest.TestCase):
    def download(self, data, size, digest=None, name="weights.bin"):
        with tempfile.TemporaryDirectory() as directory:
            item = {"rfilename": name, "size": size}
            if digest:
                item["lfs"] = {"sha256": digest}
            with patch("urllib.request.urlopen", return_value=io.BytesIO(data)):
                result = download_files("test/model", "pinned", [item], Path(directory))
            self.assertEqual((Path(directory) / name).read_bytes(), data)
            return result

    def test_verified_download(self):
        digest = hashlib.sha256(b"fixture").hexdigest()
        self.assertEqual(self.download(b"fixture", 7, digest)[0]["sha256"], digest)

    def test_digest_mismatch_refused(self):
        with self.assertRaisesRegex(ValueError, "mismatch"):
            self.download(b"fixture", 7, "0" * 64)

    def test_truncation_refused(self):
        with self.assertRaisesRegex(ValueError, "mismatch"):
            self.download(b"fixture", 8)

    def test_oversize_refused(self):
        with self.assertRaisesRegex(ValueError, "exceeded"):
            self.download(b"fixture", 6)

    def test_path_escape_refused_before_network(self):
        with tempfile.TemporaryDirectory() as directory:
            with patch("urllib.request.urlopen") as network:
                with self.assertRaisesRegex(ValueError, "unsafe"):
                    download_files("test/model", "pinned", [{"rfilename": "../outside", "size": 7}], Path(directory))
                network.assert_not_called()

    def test_serial_lock_refuses_second_process(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "serial.lock"
            with path.open("a") as lock:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                code = """import fcntl,sys
with open(sys.argv[1], 'a') as f:
    try: fcntl.flock(f, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError: sys.exit(0)
    sys.exit(1)
"""
                child = subprocess.run([sys.executable, "-c", code, str(path)], timeout=5)
                self.assertEqual(child.returncode, 0)

    def test_score_is_word_edit_distance(self):
        score = error_rate("Keep three copies, not two.", "Keep two copies not two")
        self.assertEqual((score["edits"], score["reference_words"]), (1, 5))


if __name__ == "__main__":
    unittest.main()
