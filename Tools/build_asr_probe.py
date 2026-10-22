#!/usr/bin/env python3
"""Link the ASR probe against existing compiled FluidAudio objects; no resolution/build of dependencies."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--cache", type=Path, default=Path.home() / "Library/Caches/NextNotesBuild/scratch")
    parser.add_argument("--output", type=Path, default=Path.home() / "Library/Caches/NextNotesASRBench/runtime-probe")
    parser.add_argument("--record", type=Path, required=True)
    args = parser.parse_args()
    build = args.cache / "arm64-apple-macosx/release"
    source = Path(__file__).with_name("ASRRuntimeBenchmark.swift")
    command = ["xcrun", "swiftc", "-O", "-parse-as-library", "-I", str(build / "Modules")]
    for name in ("FastClusterWrapper", "MachTaskSelfWrapper"):
        command += ["-I", str(args.cache / "checkouts/FluidAudio/Sources" / name / "include")]
    command += ["-I", str(args.cache / "artifacts/fluidaudio/NemoTextProcessing/NemoTextProcessing.xcframework/macos-arm64_x86_64/Headers"), str(source)]
    objects = []
    for name in ("FluidAudio.build", "FastClusterWrapper.build", "MachTaskSelfWrapper.build"):
        files = sorted((build / name).rglob("*.o"))
        if not files:
            parser.error(f"no cached objects for {name}; use the repo's coordinated make build first")
        objects += files
    command += [*map(str, objects), str(build / "libtext_processing_rs.a"), "-lc++", "-framework", "Accelerate", "-o", str(args.output)]
    args.output.parent.mkdir(parents=True, exist_ok=True)
    completed = subprocess.run(command, capture_output=True, text=True, timeout=90)
    report = {"command": command, "exit": completed.returncode,
        "stdout": completed.stdout, "stderr": completed.stderr,
        "source_sha256": hashlib.sha256(source.read_bytes()).hexdigest(),
        "note": "Cached object/module linking is a runtime probe, not an app rebuild or source parity proof."}
    report["linked_input_sha256"] = {str(path): hashlib.sha256(path.read_bytes()).hexdigest()
        for path in [*objects, build / "libtext_processing_rs.a", build / "Modules/FluidAudio.swiftmodule"]
        if path.is_file()}
    if args.output.exists():
        report["binary_sha256"] = hashlib.sha256(args.output.read_bytes()).hexdigest()
    args.record.parent.mkdir(parents=True, exist_ok=True)
    args.record.write_text(json.dumps(report, indent=2) + "\n")
    if completed.returncode:
        raise SystemExit(completed.stderr)
    print(args.output)


if __name__ == "__main__":
    main()
