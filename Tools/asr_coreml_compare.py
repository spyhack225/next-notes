#!/usr/bin/env python3
"""One-at-a-time Redux/Ultra probe through the cached FluidAudio v3 decoder.

Reuses compiled dependencies; no package resolution or app installation. Model
files are pinned, isolated, and removed after the exact native child exits.
"""
import argparse
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import urllib.parse
import urllib.request

from asr_benchmark import ROOT, error_rate, download_files

CANDIDATES = {
    "redux": ("FluidInference/parakeet-redux-coreml", "8c5ef97a29cd120dc76b354b3f22b7fec3b486f9"),
    "ultra": ("FluidInference/parakeet-ultra-coreml", "95eaa59a39d4394f047a4dc5cce480388a60d1b6"),
}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--engine", choices=CANDIDATES, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    if args.output.exists():
        parser.error("report already exists")
    cache = Path.home() / "Library/Caches/NextNotesASRBench"
    cache.mkdir(parents=True, exist_ok=True)
    binary = cache / "runtime-probe"
    if not binary.is_file():
        parser.error("compile Tools/ASRRuntimeBenchmark.swift against the existing FluidAudio cache first")
    repo, revision = CANDIDATES[args.engine]
    with (cache / "serial.lock").open("a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        with urllib.request.urlopen(f"https://huggingface.co/api/models/{repo}/revision/{revision}?blobs=true", timeout=30) as response:
            metadata = json.load(response)
        needed = [s for s in metadata["siblings"] if s["rfilename"].startswith(
            ("Encoder.mlmodelc/", "Decoder.mlmodelc/", "JointDecisionv3.mlmodelc/", "Preprocessor.mlmodelc/"))
            or s["rfilename"] == "parakeet_v3_vocab.json"]
        total = sum(s["size"] for s in needed)
        free = shutil.disk_usage(cache).free
        # Account for temporary compiled ANE artifacts as well as the download.
        if free < 2 * 1024**3 + 3 * total:
            raise RuntimeError(f"insufficient headroom: {free} available; candidate {total} bytes")
        args.output.parent.mkdir(parents=True, exist_ok=True)
        report = {"engine": args.engine, "repo": repo, "revision": revision,
            "download_bytes": total, "free_disk_before_bytes": free,
            "runtime_probe_sha256": hashlib.sha256(binary.read_bytes()).hexdigest(),
            "scope": "same cached FluidAudio v3-family decoder; explicit alternative CoreML weights",
            "artifacts": []}
        with tempfile.TemporaryDirectory(prefix=args.engine + "-", dir=cache) as owned:
            folder = Path(owned)
            report["artifacts"] = download_files(repo, revision, needed, folder)
            cmd = [str(binary), str(folder), str(folder / "parakeet_v3_vocab.json"),
                str(folder / "result.json"), str(ROOT / "Tests/Fixtures/meetings/en-dialogue.wav"),
                str(ROOT / "Tests/Fixtures/meetings/fr-dialogue.wav")]
            print(f"{args.engine}: native child starting", flush=True)
            child = subprocess.Popen(cmd, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, start_new_session=True)
            try:
                if os.environ.get("ASR_LIVE") == "1":
                    from asr_live import rpc_driver
                    rpc_driver(child, folder / "result.json")
                stdout, stderr = child.communicate(timeout=180)
            except BaseException:
                child.kill()
                child.wait()
                raise
            report.update(child_exit=child.returncode, child_joined=True,
                stdout=stdout.decode(errors="replace"), stderr=stderr.decode(errors="replace"))
            if (folder / "result.json").exists():
                result = json.loads((folder / "result.json").read_text())
                for trial in result["trials"] if os.environ.get("ASR_LIVE") != "1" else []:
                    lang = "en" if "en-dialogue" in trial["fixture"] else "fr"
                    script = ROOT / f"Tests/Fixtures/meetings/scripts/{lang}-dialogue.txt"
                    reference = re.sub(r"^[AB]:\s*", "", script.read_text(), flags=re.MULTILINE)
                    trial.update(error_rate(reference, trial["text"]))
                    trial["fixture_sha256"] = hashlib.sha256(Path(trial["fixture"]).read_bytes()).hexdigest()
                report["benchmark"] = result
            args.output.write_text(json.dumps(report, indent=2, ensure_ascii=False) + "\n")
        report.update(temporary_assets_deleted=not folder.exists(), free_disk_after_bytes=shutil.disk_usage(cache).free)
        args.output.write_text(json.dumps(report, indent=2, ensure_ascii=False) + "\n")
        print(f"Saved {args.output}; owned model directory deleted", flush=True)
        if child.returncode:
            raise SystemExit(child.returncode)


if __name__ == "__main__":
    main()
