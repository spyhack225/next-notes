#!/usr/bin/env python3
"""Voz release CLI in a verified disposable cache; offline audio inference.

The download-only step may use the SDK's license service (metadata, no audio).
All audio processing runs with network denied by the macOS sandbox.
"""
import argparse
import fcntl
import hashlib
import io
import json
import os
from pathlib import Path
import re
import shutil
import signal
import subprocess
import tarfile
import tempfile
import time
import urllib.request
from asr_benchmark import ROOT, error_rate

RELEASE = "v0.5.0"
URL = f"https://github.com/Desert-Ant-Labs/desert-ant-cli/releases/download/{RELEASE}/desertant-darwin-arm64.tar.gz"


def run(command, env, timeout=180):
    child = subprocess.Popen(command, env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, start_new_session=True)
    try:
        stdout, stderr = child.communicate(timeout=timeout)
    except BaseException:
        try:
            os.killpg(child.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        child.communicate()
        raise
    return {"exit": child.returncode, "stdout": stdout.decode(errors="replace"),
            "stderr": stderr.decode(errors="replace")}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    if args.output.exists():
        parser.error("report already exists")
    cache = Path.home() / "Library/Caches/NextNotesASRBench"
    cache.mkdir(parents=True, exist_ok=True)
    with (cache / "serial.lock").open("a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        if shutil.disk_usage(cache).free < 3 * 1024**3:
            raise RuntimeError("insufficient headroom for this candidate")
        report = {"engine": "Voz", "cli_release": RELEASE, "cli_url": URL,
            "free_disk_before_bytes": shutil.disk_usage(cache).free,
            "scope": "vendor CoreML CLI, same authored EN/FR WAVs; offline audio inference"}
        args.output.parent.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(prefix="voz-", dir=cache) as owned:
            folder = Path(owned)
            print("Voz: fetching 14 MB release CLI", flush=True)
            with urllib.request.urlopen(URL, timeout=60) as response:
                archive_bytes = response.read(15 * 1024**2)
            report["cli_archive_sha256"] = hashlib.sha256(archive_bytes).hexdigest()
            with tarfile.open(fileobj=io.BytesIO(archive_bytes)) as archive:
                archive.extractall(folder / "cli", filter="data")
            binary = next(p for p in (folder / "cli").rglob("desertant") if p.is_file())
            env = {**os.environ, "CFFIXED_USER_HOME": str(folder / "home"),
                "TMPDIR": str(folder / "tmp"), "XDG_CACHE_HOME": str(folder / "xdg"),
                "XDG_CONFIG_HOME": str(folder / "config")}
            for p in ("home", "tmp", "xdg", "config"):
                (folder / p).mkdir()
            location = run([str(binary), "cache", "--path"], env)
            report["cache_probe"] = location
            path = Path(location["stdout"].strip())
            if location["exit"] or not path.is_absolute() or not path.resolve().is_relative_to(folder.resolve()):
                raise RuntimeError(f"CLI cache is not isolated: {location}")
            report["cli_version"] = run([str(binary), "--version"], env)
            print("Voz: downloading this candidate into the verified isolated cache", flush=True)
            began = time.perf_counter()
            pull = run([str(binary), "pull", "voz", "--json"], env, timeout=240)
            report["prepare_seconds_including_download"] = time.perf_counter() - began
            report["prepare"] = pull
            if pull["exit"]:
                args.output.write_text(json.dumps(report, indent=2) + "\n")
                raise RuntimeError(pull["stderr"][-2000:])
            paths = []
            for language in ("en", "fr"):
                for trial in range(3):
                    path = folder / f"{language}-{trial}.wav"
                    shutil.copyfile(ROOT / f"Tests/Fixtures/meetings/{language}-dialogue.wav", path)
                    paths.append(str(path))
            # No model input/output can leave the process over the network.
            command = ["/usr/bin/sandbox-exec", "-p", "(version 1)(allow default)(deny network*)",
                str(binary), "voz", *paths, "--json", "--quiet"]
            print("Voz: one native child, six files, network denied", flush=True)
            result = run(command, env, timeout=180)
            report["native"] = result
            artifacts = []
            for path in (folder / "home").rglob("*"):
                if path.is_file() and any(x in path.parts for x in ("desert-ant-models",)):
                    artifacts.append({"path": str(path.relative_to(folder)), "bytes": path.stat().st_size,
                        "sha256": hashlib.sha256(path.read_bytes()).hexdigest()})
            report["artifacts"] = artifacts
            if result["exit"] == 0:
                rows = json.loads(result["stdout"])
                for row in rows:
                    name = Path(row["input"]).stem
                    lang, trial = name.split("-")
                    script = ROOT / f"Tests/Fixtures/meetings/scripts/{lang}-dialogue.txt"
                    reference = re.sub(r"^[AB]:\s*", "", script.read_text(), flags=re.MULTILINE)
                    row.update(language=lang, trial=int(trial), **error_rate(reference, row["text"]))
                    row["rtfx"] = row["durationSec"] / row["processingSec"]
                report["trials"] = rows
            args.output.write_text(json.dumps(report, indent=2, ensure_ascii=False) + "\n")
        report.update(temporary_assets_deleted=not folder.exists(), children_joined=True,
            free_disk_after_bytes=shutil.disk_usage(cache).free)
        args.output.write_text(json.dumps(report, indent=2, ensure_ascii=False) + "\n")
        print(f"Saved {args.output}; isolated CLI, model and cache deleted", flush=True)
        if result["exit"]:
            raise SystemExit(result["exit"])


if __name__ == "__main__":
    main()
