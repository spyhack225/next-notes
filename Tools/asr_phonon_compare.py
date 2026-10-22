#!/usr/bin/env python3
"""Download/run/delete one pinned Phonon CoreML candidate; no package cache copies."""
import argparse
import fcntl
import hashlib
import io
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tarfile
import tempfile
import urllib.request
from asr_benchmark import ROOT, error_rate, download_files

REPO = "FermionResearch/Phonon-2-CoreML"
REVISION = "1143812fd4236522232a8c33e3115f0577e3cd7d"


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
        with urllib.request.urlopen(f"https://huggingface.co/api/models/{REPO}/revision/{REVISION}?blobs=true", timeout=30) as response:
            metadata = json.load(response)
        required = [s for s in metadata["siblings"] if s["rfilename"].startswith("Phonon-2.mlpackage/")
            or s["rfilename"] in ("decoder.bin", "manifest.json", "phonon-coreml-src.tgz")]
        total = sum(x["size"] for x in required)
        free = shutil.disk_usage(cache).free
        if free < 2 * 1024**3 + 3 * total:
            raise RuntimeError("insufficient disk headroom for download, compilation and swap reserve")
        report = {"engine": "Phonon-2 CoreML", "repo": REPO, "revision": REVISION,
            "download_bytes_including_source": total, "free_disk_before_bytes": free, "artifacts": []}
        args.output.parent.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(prefix="phonon-", dir=cache) as owned:
            folder = Path(owned)
            report["artifacts"] = download_files(REPO, REVISION, required, folder)
            with tarfile.open(folder / "phonon-coreml-src.tgz") as archive:
                archive.extractall(folder, filter="data")
            source = folder / "phonon-coreml"
            native = source / "Binaries/PhononTDT.xcframework/macos-arm64_x86_64"
            commands = [
                ["xcrun", "swiftc", "-O", "-emit-library", "-emit-module", "-module-name", "PhononCoreML",
                    "-I", str(native / "Headers"), *map(str, sorted((source / "Sources/PhononCoreML").glob("*.swift"))),
                    str(native / "libPhononTDT.a"), "-lc++", "-framework", "Accelerate",
                    "-emit-module-path", str(folder / "PhononCoreML.swiftmodule"), "-o", str(folder / "libPhononCoreML.dylib")],
                ["xcrun", "swiftc", "-O", "-parse-as-library", "-I", str(folder), "-I", str(native / "Headers"),
                    "-L", str(folder), "-lPhononCoreML", "-Xlinker", "-rpath", "-Xlinker", str(folder),
                    str(ROOT / "Tools/PhononASRRuntimeBenchmark.swift"), "-o", str(folder / "probe")]]
            report["compile_commands"] = commands
            for command in commands:
                completed = subprocess.run(command, capture_output=True, text=True, timeout=120)
                if completed.returncode:
                    report.update(compile_exit=completed.returncode, stderr=completed.stderr)
                    args.output.write_text(json.dumps(report, indent=2) + "\n")
                    raise RuntimeError(completed.stderr[-2000:])
            print("Phonon: native child starting (first-run model compilation included)", flush=True)
            child = subprocess.Popen([str(folder / "probe"), str(folder), str(folder / "result.json"),
                str(ROOT / "Tests/Fixtures/meetings/en-dialogue.wav")], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            try:
                if os.environ.get("ASR_LIVE") == "1":
                    from asr_live import rpc_driver
                    rpc_driver(child, folder / "result.json", languages=("en",))
                stdout, stderr = child.communicate(timeout=240)
            except BaseException:
                child.kill()
                child.wait()
                raise
            report.update(child_exit=child.returncode, child_joined=True,
                stdout=stdout.decode(errors="replace"), stderr=stderr.decode(errors="replace"))
            if (folder / "result.json").exists():
                result = json.loads((folder / "result.json").read_text())
                script = ROOT / "Tests/Fixtures/meetings/scripts/en-dialogue.txt"
                reference = re.sub(r"^[AB]:\s*", "", script.read_text(), flags=re.MULTILINE)
                for row in result["trials"] if os.environ.get("ASR_LIVE") != "1" else []:
                    row.update(error_rate(reference, row["text"]))
                report["benchmark"] = result
            args.output.write_text(json.dumps(report, indent=2, ensure_ascii=False) + "\n")
        report.update(temporary_assets_deleted=not folder.exists(), free_disk_after_bytes=shutil.disk_usage(cache).free)
        args.output.write_text(json.dumps(report, indent=2, ensure_ascii=False) + "\n")
        print(f"Saved {args.output}; model, compiled model and build deleted", flush=True)
        if child.returncode:
            raise SystemExit(child.returncode)


if __name__ == "__main__":
    main()
