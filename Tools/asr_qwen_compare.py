#!/usr/bin/env python3
"""Serial MLX Qwen ASR probe. Explicit local snapshots, offline inference, disposable venv."""
import argparse
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import resource
import shutil
import subprocess
import sys
import tempfile
import time
import urllib.request
from asr_benchmark import ROOT, error_rate, download_files

CANDIDATES = {
    "0.6b": ("mlx-community/Qwen3-ASR-0.6B-4bit", "313d850181767edf09f00a9c289becca70e58cd0"),
    "1.7b": ("mlx-community/Qwen3-ASR-1.7B-4bit", "78a389c776a5483b2d0d4ea5494e11012e0d6159"),
}


def worker(folder):
    import numpy as np
    import mlx.core as mx
    from mlx_audio.stt.utils import load_model
    import wave
    folder = Path(folder)
    start = time.perf_counter()
    model = load_model(folder / "model")
    load_ms = (time.perf_counter() - start) * 1000
    if os.environ.get("ASR_LIVE") == "1":
        from asr_live import qwen_worker
        qwen_worker(model, folder)
        return
    rows = []
    for lang, language in [("en", "English"), ("fr", "French")]:
        fixture = ROOT / f"Tests/Fixtures/meetings/{lang}-dialogue.wav"
        with wave.open(str(fixture)) as wav:
            audio = np.frombuffer(wav.readframes(wav.getnframes()), dtype="<i2").astype(np.float32) / 32768
        script = ROOT / f"Tests/Fixtures/meetings/scripts/{lang}-dialogue.txt"
        reference = re.sub(r"^[AB]:\s*", "", script.read_text(), flags=re.MULTILINE)
        for trial in range(3):
            start = time.perf_counter()
            result = model.generate(audio, language=language, max_tokens=1024, verbose=False)
            mx.synchronize()
            elapsed = time.perf_counter() - start
            rows.append({"language": lang, "trial": trial, "fixture": str(fixture.relative_to(ROOT)),
                "fixture_sha256": hashlib.sha256(fixture.read_bytes()).hexdigest(),
                "text": result.text, "audio_seconds": len(audio)/16000,
                "wall_seconds": elapsed, "rtfx": len(audio)/16000/elapsed,
                **error_rate(reference, result.text)})
            print(f"Qwen {lang} trial {trial}: {elapsed:.3f}s", flush=True)
    report = {"load_ms": load_ms, "trials": rows,
        "peak_rss_bytes": resource.getrusage(resource.RUSAGE_SELF).ru_maxrss,
        "mlx_peak_memory_bytes": mx.get_peak_memory(),
        "scope": "MLX GPU, quantized local snapshot; whole-file, offline inference"}
    (folder / "result.json").write_text(json.dumps(report, indent=2, ensure_ascii=False) + "\n")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--size", choices=CANDIDATES)
    parser.add_argument("--output", type=Path)
    parser.add_argument("--worker", type=Path)
    options = parser.parse_args()
    if options.worker:
        worker(options.worker)
        return
    if not options.size or not options.output or options.output.exists():
        parser.error("--size and a new --output file required")
    cache = Path.home() / "Library/Caches/NextNotesASRBench"
    cache.mkdir(parents=True, exist_ok=True)
    repo, revision = CANDIDATES[options.size]
    with (cache / "serial.lock").open("a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        with urllib.request.urlopen(f"https://huggingface.co/api/models/{repo}/revision/{revision}?blobs=true", timeout=30) as response:
            metadata = json.load(response)
        files = [s for s in metadata["siblings"] if s["rfilename"].endswith((".safetensors", ".json", ".txt", ".model"))]
        total = sum(s["size"] for s in files)
        free = shutil.disk_usage(cache).free
        # Weights + disposable interpreter packages/installation working room + swap reserve.
        if free < total + 3 * 1024**3:
            raise RuntimeError(f"insufficient disk headroom: {free} available, {total} weights plus 3 GiB required")
        report = {"engine": f"Qwen3-ASR-{options.size}-4bit", "repo": repo, "revision": revision,
            "download_bytes": total, "free_disk_before_bytes": free, "artifacts": []}
        options.output.parent.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(prefix="qwen-", dir=cache) as owned:
            folder = Path(owned)
            report["artifacts"] = download_files(repo, revision, files, folder / "model")
            interpreter = Path.home() / ".cache/codex-runtimes/codex-primary-runtime/dependencies/python/bin/python3"
            env = {**os.environ, "UV_CACHE_DIR": str(folder / "uv-cache"), "HF_HOME": str(folder / "hf"),
                "HF_HUB_OFFLINE": "1", "TRANSFORMERS_OFFLINE": "1", "HF_HUB_DISABLE_TELEMETRY": "1",
                "DO_NOT_TRACK": "1", "PYTHONPATH": str(ROOT / "Tools"), "PYTHONDONTWRITEBYTECODE": "1"}
            commands = [["uv", "venv", "--python", str(interpreter), str(folder / "venv")],
                ["uv", "pip", "install", "--python", str(folder / "venv/bin/python"), "--only-binary", ":all:", "mlx-audio==0.6.1"]]
            for command in commands:
                done = subprocess.run(command, env=env, capture_output=True, text=True, timeout=180)
                if done.returncode:
                    report.update(install_exit=done.returncode, stderr=done.stderr)
                    options.output.write_text(json.dumps(report, indent=2) + "\n")
                    raise RuntimeError(done.stderr[-2000:])
            report["runtime_packages"] = subprocess.check_output(["uv", "pip", "freeze", "--python", str(folder / "venv/bin/python")], env=env, text=True)
            print("Qwen: native MLX child starting; inference network disabled", flush=True)
            child = subprocess.Popen([str(folder / "venv/bin/python"), str(Path(__file__).resolve()), "--worker", str(folder)],
                env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            try:
                stdout, stderr = child.communicate(timeout=240)
            except BaseException:
                child.kill()
                child.wait()
                raise
            report.update(child_exit=child.returncode, child_joined=True,
                stdout=stdout.decode(errors="replace"), stderr=stderr.decode(errors="replace"))
            if (folder / "result.json").exists():
                report["benchmark"] = json.loads((folder / "result.json").read_text())
            options.output.write_text(json.dumps(report, indent=2, ensure_ascii=False) + "\n")
        report.update(temporary_assets_deleted=not folder.exists(), free_disk_after_bytes=shutil.disk_usage(cache).free)
        options.output.write_text(json.dumps(report, indent=2, ensure_ascii=False) + "\n")
        print(f"Saved {options.output}; model, environment and download cache deleted", flush=True)
        if child.returncode:
            raise SystemExit(child.returncode)


if __name__ == "__main__":
    main()
