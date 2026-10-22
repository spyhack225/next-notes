"""Paced cached Parakeet v3; never modifies or downloads owner models."""
import argparse
import fcntl
import hashlib
import json
import os
from pathlib import Path
import subprocess
from asr_live import rpc_driver


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--output", required=True, type=Path)
    options = p.parse_args()
    if options.output.exists():
        p.error("new report required")
    cache = Path.home()/"Library/Caches/NextNotesASRBench"
    root = Path.home()/"Library/Application Support/FluidAudio/Models/parakeet-tdt-0.6b-v3"
    def assets():
        return {str(p.relative_to(root)): hashlib.sha256(p.read_bytes()).hexdigest()
            for p in root.rglob("*") if p.is_file()}
    with (cache/"serial.lock").open("a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        before = assets()
        if not before:
            raise RuntimeError("owner v3 cache unavailable; no implicit download")
        child = subprocess.Popen([str(cache/"runtime-probe"), str(root), str(root/"parakeet_v3_vocab.json"),
            str(options.output), "unused.wav"], env={**os.environ,"ASR_LIVE":"1"},
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        try:
            rpc_driver(child, options.output)
            stdout, stderr = child.communicate(timeout=30)
        except BaseException:
            child.kill()
            child.wait()
            raise
        report = {"engine":"Parakeet v3 cached CoreML", "child_exit":child.returncode,
            "child_joined":True, "stderr":stderr.decode(errors="replace"),
            "owner_artifacts_unchanged": before == assets(), "artifacts_sha256": before,
            "runtime_probe_sha256": hashlib.sha256((cache/"runtime-probe").read_bytes()).hexdigest(),
            "benchmark":json.loads(options.output.read_text())}
        options.output.write_text(json.dumps(report, indent=2, ensure_ascii=False)+"\n")


if __name__ == "__main__":
    main()
