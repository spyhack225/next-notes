#!/usr/bin/env python3
"""Isolated Whistle native benchmark. Standard library only; never installs packages.

One temporary candidate at a time: pinned download -> child -> saved report ->
joined child -> delete owned assets. Existing app/models/preferences are untouched.
This is a runtime probe, not an application integration or full-duplex acceptance.
"""
import argparse
import array
import ctypes
import fcntl
import hashlib
import io
import json
import os
from pathlib import Path
import platform
import re
import resource
import shutil
import subprocess
import sys
import tempfile
import time
import urllib.request
import urllib.parse
import wave
import zipfile

ROOT = Path(__file__).resolve().parents[1]
ENGINE_REV = "d6c7d6a2e9655505e0f8e23339356dd1705900eb"
MODEL_REV = "741118687e1f008f06d1351a402a731274789790"
MODEL_SHA = "b6e02f048568ac5d01a2042556c658061e699acbc0aa2a1439f52f3d461dffeb"


def words(text):
    return re.findall(r"[^\W_]+", text.casefold(), flags=re.UNICODE)


def error_rate(reference, hypothesis):
    ref, hyp = words(reference), words(hypothesis)
    row = list(range(len(hyp) + 1))
    for i, word in enumerate(ref, 1):
        nxt = [i]
        for j, other in enumerate(hyp, 1):
            nxt.append(min(nxt[-1] + 1, row[j] + 1, row[j-1] + (word != other)))
        row = nxt
    return {"edits": row[-1], "reference_words": len(ref),
            "wer": row[-1] / len(ref) if ref else None}


def read_pcm(path):
    with wave.open(str(path)) as wav:
        if (wav.getnchannels(), wav.getsampwidth(), wav.getframerate()) != (1, 2, 16000):
            raise ValueError("fixture must be mono PCM16 at 16 kHz")
        pcm = array.array("h", wav.readframes(wav.getnframes()))
    if sys.byteorder != "little":
        pcm.byteswap()
    return (ctypes.c_float * len(pcm))(*(x / 32768 for x in pcm))


def worker(library, model, destination, trials):
    native = ctypes.CDLL(library)
    native.needle_load.argtypes = [ctypes.c_char_p, ctypes.c_ulonglong]
    native.needle_load.restype = ctypes.c_int
    native.needle_last_error.restype = ctypes.c_char_p
    args = [ctypes.POINTER(ctypes.c_float), ctypes.c_int, ctypes.c_char_p,
            ctypes.c_char_p, ctypes.c_int, ctypes.c_void_p, ctypes.c_int]
    native.needle_transcribe.argtypes = args
    native.needle_transcribe.restype = ctypes.c_int
    data = Path(model).read_bytes()
    start = time.perf_counter()
    if native.needle_load(data, len(data)) < 0:
        raise RuntimeError(native.needle_last_error())
    load_ms = (time.perf_counter() - start) * 1000
    if os.environ.get("ASR_LIVE") == "1":
        from asr_live import whistle_worker
        whistle_worker(native, destination)
        return
    results = []
    for language in ("en", "fr"):
        audio = ROOT / f"Tests/Fixtures/meetings/{language}-dialogue.wav"
        script = ROOT / f"Tests/Fixtures/meetings/scripts/{language}-dialogue.txt"
        reference = re.sub(r"^[AB]:\s*", "", script.read_text(), flags=re.MULTILINE)
        pcm = read_pcm(audio)
        seconds = len(pcm) / 16000
        for trial in range(trials):
            output = ctypes.create_string_buffer(256 * 1024)
            start = time.perf_counter()
            count = native.needle_transcribe(pcm, len(pcm), language.encode(), None, 1,
                                             output, len(output))
            elapsed = time.perf_counter() - start
            if count < 0:
                raise RuntimeError(native.needle_last_error())
            decoded = json.loads(output.value)
            results.append({"fixture": str(audio.relative_to(ROOT)),
                "sha256": hashlib.sha256(audio.read_bytes()).hexdigest(),
                "language": language, "trial": trial,
                "first_inference_after_load": language == "en" and trial == 0,
                "audio_seconds": seconds, "wall_seconds": elapsed,
                "rtfx": seconds / elapsed, "result": decoded,
                **error_rate(reference, decoded["text"])})
    output = ctypes.create_string_buffer(256 * 1024)
    silence = (ctypes.c_float * 16000)()
    status = native.needle_transcribe(silence, len(silence), b"en", None, 1,
                                      output, len(output))
    if status < 0:
        raise RuntimeError(native.needle_last_error())
    silence_result = json.loads(output.value)
    report = {"engine": "Whistle", "model_revision": MODEL_REV,
        "model_sha256": MODEL_SHA, "load_ms": load_ms,
        "trials": results, "silence": silence_result,
        "silence_pass": not silence_result["text"].strip(),
        "peak_rss_bytes": resource.getrusage(resource.RUSAGE_SELF).ru_maxrss,
        "memory_note": "macOS process lifetime peak RSS, not Mach physical footprint",
        "measurement_scope": "whole-file native runtime, not paced microphone or app",
        "wer_normalizer": "Unicode alphanumeric tokens, casefold; no number rewriting"}
    Path(destination).write_text(json.dumps(report, indent=2, ensure_ascii=False) + "\n")


def fetch(url, expected_bytes, expected_sha=None):
    with urllib.request.urlopen(url, timeout=60) as response:
        data = response.read(expected_bytes + 1)
    if len(data) != expected_bytes:
        raise ValueError(f"download size mismatch: {len(data)} != {expected_bytes}")
    if expected_sha and hashlib.sha256(data).hexdigest() != expected_sha:
        raise ValueError("download SHA256 mismatch")
    return data


def download_files(repo, revision, files, folder):
    """Only the selected snapshot files; verify external paths, sizes and LFS hashes."""
    artifacts = []
    for item in files:
        name = item["rfilename"]
        path = folder / name
        if not path.resolve().is_relative_to(folder.resolve()):
            raise ValueError("unsafe artifact path")
        path.parent.mkdir(parents=True, exist_ok=True)
        print(f"{repo}: {name} ({item['size']} bytes)", flush=True)
        digest, count = hashlib.sha256(), 0
        url = f"https://huggingface.co/{repo}/resolve/{revision}/{urllib.parse.quote(name)}"
        with urllib.request.urlopen(url, timeout=60) as response, path.open("wb") as output:
            while chunk := response.read(1024 * 1024):
                count += len(chunk)
                if count > item["size"]:
                    raise ValueError("artifact exceeded pinned size")
                output.write(chunk)
                digest.update(chunk)
        expected = item.get("lfs", {}).get("sha256")
        if count != item["size"] or (expected and digest.hexdigest() != expected):
            raise ValueError("artifact size/digest mismatch")
        artifacts.append({"path": name, "bytes": count, "sha256": digest.hexdigest()})
    return artifacts


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path)
    parser.add_argument("--trials", type=int, default=3)
    parser.add_argument("--worker", nargs=3, metavar=("LIBRARY", "MODEL", "RESULT"))
    options = parser.parse_args()
    if options.worker:
        worker(*options.worker, options.trials)
        return
    if not options.output or options.output.exists():
        parser.error("--output must name a new report file")
    if not 1 <= options.trials <= 10:
        parser.error("--trials must be 1 through 10")
    if platform.system() != "Darwin" or platform.machine() != "arm64":
        parser.error("this probe pins the macOS arm64 runtime")
    cache = Path.home() / "Library/Caches/NextNotesASRBench"
    cache.mkdir(parents=True, exist_ok=True)
    # Diagnostic exclusivity only; never gates the product microphone or speaker.
    with (cache / "serial.lock").open("a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        before = shutil.disk_usage(cache).free
        # Known 17 MB weights + <2 MB runtime plus working room and swap reserve.
        small_cpu = os.environ.get("ASR_SMALL_CPU") == "1" and os.environ.get("ASR_LIVE") == "1"
        reserve = 256 * 1024**2 if small_cpu else 2 * 1024**3
        if before < reserve + 64 * 1024**2:
            raise RuntimeError("insufficient disk headroom for this candidate")
        options.output.parent.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(prefix="whistle-", dir=cache) as owned:
            folder = Path(owned)
            print("Downloading pinned Whistle (16.9 MB) and native runtime", flush=True)
            model = fetch(f"https://huggingface.co/Cactus-Compute/whistle/resolve/{MODEL_REV}/whistle.cact",
                          16919407, MODEL_SHA)
            (folder / "whistle.cact").write_bytes(model)
            del model
            wheel = fetch(f"https://huggingface.co/Cactus-Compute/needle3/resolve/{ENGINE_REV}/python/"
                          "cactus_needle-3.3.3-py3-none-macosx_11_0_arm64.whl", 544605)
            with zipfile.ZipFile(io.BytesIO(wheel)) as archive:
                (folder / "libneedle3.dylib").write_bytes(archive.read("needle/libneedle3.dylib"))
            del wheel
            runtime_sha = hashlib.sha256((folder / "libneedle3.dylib").read_bytes()).hexdigest()
            print("Running one isolated native child on existing EN/FR fixtures", flush=True)
            process = subprocess.Popen([sys.executable, str(Path(__file__).resolve()),
                "--worker", str(folder / "libneedle3.dylib"), str(folder / "whistle.cact"),
                str(folder / "result.json"), "--trials", str(options.trials)],
                stdout=subprocess.PIPE, stderr=subprocess.PIPE, start_new_session=True)
            try:
                if small_cpu:
                    deadline = time.monotonic() + 180
                    while True:
                        if shutil.disk_usage(cache).free < reserve or time.monotonic() > deadline:
                            process.kill()
                            stdout, stderr = process.communicate()
                            raise RuntimeError("Whistle CPU diagnostic stopped at its disk/time boundary")
                        try:
                            stdout, stderr = process.communicate(timeout=1)
                            break
                        except subprocess.TimeoutExpired:
                            continue
                else:
                    stdout, stderr = process.communicate(timeout=180)
            except BaseException:
                process.kill()
                process.wait()
                raise
            report = {"schema": "asr-runtime-probe.v1", "machine": platform.platform(),
                "chip": subprocess.check_output(["sysctl", "-n", "machdep.cpu.brand_string"], text=True).strip(),
                "engine_revision": ENGINE_REV, "runtime_sha256": runtime_sha,
                "temporary_model_bytes": 16919407, "free_disk_before_bytes": before,
                "small_cpu_pressure_diagnostic": small_cpu, "disk_reserve_bytes": reserve,
                "child_exit": process.returncode, "stderr": stderr.decode(errors="replace"),
                "stdout": stdout.decode(errors="replace")}
            if (folder / "result.json").exists():
                report["benchmark"] = json.loads((folder / "result.json").read_text())
            # Save before deleting the exact owned directory. No next download on failure.
            options.output.write_text(json.dumps(report, indent=2, ensure_ascii=False) + "\n")
        report["temporary_assets_deleted"] = not folder.exists()
        report["child_joined"] = True
        report["free_disk_after_bytes"] = shutil.disk_usage(cache).free
        options.output.write_text(json.dumps(report, indent=2, ensure_ascii=False) + "\n")
        print(f"Saved {options.output}; owned model/runtime deleted", flush=True)
        if process.returncode:
            raise SystemExit(process.returncode)


if __name__ == "__main__":
    main()
