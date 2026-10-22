import unittest
import json
from pathlib import Path
import subprocess
import sys
import os
import time
import tempfile
from types import SimpleNamespace
from unittest.mock import patch
import asr_live
import asr_voz_compare


class PaceTests(unittest.TestCase):
    def test_audio_clock_and_release_include_slow_inflight(self):
        clock = [10.0]
        calls = []
        def infer(audio, lang, final):
            calls.append((clock[0], len(audio), final))
            self.assertLessEqual(len(audio), int((clock[0]-10)*16000)+1)
            # A partial straddles release; its drain must count toward final.
            clock[0] += 2.0 if not final else .1
            return {"text": "hello"}
        def sleep(seconds):
            clock[0] += seconds
        # Warmup precedes the clock origin used by the assertions.
        warmed = [False]
        def warm_then_infer(audio, lang, final):
            if not warmed[0]:
                warmed[0] = final
                return {"text": "hello"}
            return infer(audio, lang, final)
        with patch.object(asr_live, "fixture", return_value=([0]*40000, "hello", {})), \
             patch.object(asr_live.time, "perf_counter", side_effect=lambda: clock[0]), \
             patch.object(asr_live.time, "sleep", side_effect=sleep):
            report = asr_live.measure(warm_then_infer, languages=("en",), trials=1)
        row = report["trials"][0]
        self.assertGreater(row["release_to_final_ms"], 1900)
        self.assertEqual(calls[-1][1], 40000)
        self.assertEqual(len(row["events"]), 3)
        self.assertAlmostEqual(row["events"][0]["dispatch_ms"], 400)
        self.assertTrue(row["events"][-1]["final"])

    def test_fixture_complete_two_sentences(self):
        for language, count in [("en",116000),("fr",106400)]:
            audio, reference, identity = asr_live.fixture(language)
            self.assertEqual(len(audio), count)
            self.assertEqual(identity["samples"], count)
            self.assertGreater(len(reference.split()), 15)

    def test_failed_rpc_retains_last_request_without_model(self):
        with tempfile.TemporaryDirectory() as folder:
            output = Path(folder)/"result.json"
            child = subprocess.Popen([sys.executable,"-c",
                'print(\'ASR_RPC {"ready": true}\', flush=True); input()'],
                stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE)
            try:
                with patch.object(asr_live.shutil,"disk_usage",return_value=SimpleNamespace(free=1024**3)), \
                     patch.object(asr_live,"measure",side_effect=lambda infer,languages: infer([0]*6400,"en",False)):
                    with self.assertRaisesRegex(RuntimeError,"exited before reply"):
                        asr_live.rpc_driver(child,output)
                retained = json.loads(Path(str(output)+".diagnostic.json").read_text())
                self.assertEqual(retained["requests"][0]["samples"],6400)
                self.assertTrue(retained["runtime_ready"]["ready"])
                self.assertNotIn("received_at",retained["requests"][0])
            finally:
                if child.poll() is None:
                    child.kill()
                child.communicate()

    def test_native_stderr_cannot_block_transcript_delivery(self):
        with tempfile.TemporaryDirectory() as folder:
            output = Path(folder)/"result.json"
            child = subprocess.Popen([sys.executable,"-c",
                'import sys; print(\'ASR_RPC {"ready":true}\',flush=True); input(); '
                'sys.stderr.write("x"*262144); sys.stderr.flush(); '
                'print(\'ASR_RPC {"text":"hello"}\',flush=True); sys.stdin.read()'],
                stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE)
            def measured(infer,languages):
                self.assertEqual(infer([0]*6400,"en",False)["text"],"hello")
                return {"trials":[],"peak_rss_bytes":0}
            try:
                with patch.object(asr_live.shutil,"disk_usage",return_value=SimpleNamespace(free=1024**3)), \
                     patch.object(asr_live,"measure",side_effect=measured):
                    asr_live.rpc_driver(child,output)
                self.assertEqual(len(json.loads(output.read_text())["native_stderr_tail"]),65536)
            finally:
                if child.poll() is None:
                    child.kill()
                child.communicate()

    def test_startup_failure_retains_native_error(self):
        with tempfile.TemporaryDirectory() as folder:
            output = Path(folder)/"result.json"
            child = subprocess.Popen([sys.executable,"-c",
                'import sys; sys.stderr.write("model compile failed\\n"); sys.stderr.flush()'],
                stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE)
            try:
                with patch.object(asr_live.shutil,"disk_usage",return_value=SimpleNamespace(free=1024**3)):
                    with self.assertRaisesRegex(RuntimeError,"exited before reply"):
                        asr_live.rpc_driver(child,output)
                retained = json.loads(Path(str(output)+".diagnostic.json").read_text())
                self.assertIsNone(retained["runtime_ready"])
                self.assertEqual(retained["requests"],[])
                self.assertIn("model compile failed",retained["native_stderr_tail"])
            finally:
                if child.poll() is None:
                    child.kill()
                child.communicate()

    def test_sdk_timeout_stops_owned_compiler_descendant(self):
        with tempfile.TemporaryDirectory() as folder:
            pidfile = Path(folder)/"child.pid"
            script = ('import subprocess,sys,time; '
                'p=subprocess.Popen([sys.executable,"-c","import time; time.sleep(30)"]); '
                'open(sys.argv[1],"w").write(str(p.pid)); time.sleep(30)')
            pid = None
            try:
                with self.assertRaises(subprocess.TimeoutExpired):
                    asr_voz_compare.run([sys.executable,"-c",script,str(pidfile)],dict(os.environ),timeout=.75)
                self.assertTrue(pidfile.exists(),"fake compiler never started")
                pid = int(pidfile.read_text())
                deadline = time.monotonic()+1
                while True:
                    state = subprocess.run(["ps","-p",str(pid),"-o","state="],capture_output=True,text=True).stdout.strip()
                    if not state or state.startswith("Z") or time.monotonic() >= deadline:
                        break
                    time.sleep(.02)
                self.assertTrue(not state or state.startswith("Z"),"timed-out native job left a compiler running")
            finally:
                # The recorded PID was created by this disposable test only.
                if pid is None and pidfile.exists():
                    pid = int(pidfile.read_text())
                if pid:
                    try:
                        os.kill(pid,9)
                    except ProcessLookupError:
                        pass


if __name__ == "__main__":
    unittest.main()
