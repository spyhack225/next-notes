#!/usr/bin/env python3
"""Compare native TTS first PCM, with one disposable model/process at a time.

Never launches builds. Requires a release binary containing --selftest-tts-benchmark.
No model files are retained by this runner. Existing owner models are untouched.
"""
import argparse
import hashlib
import json
import math
import os
from pathlib import Path
import platform
import shutil
import signal
import statistics
import subprocess
import tempfile
import time

ENGINES = ("apple", "pocket", "kokoro", "phonon", "qwen")
# Conservative transient storage estimates, in addition to the diagnostic reserve.
SPACE = {"apple": 0, "pocket": 1_500_000_000, "kokoro": 1_500_000_000,
         "phonon": 1_500_000_000, "qwen": 1_800_000_000}
RESERVE = 2 * 1024**3  # Diagnostic-only; production ModelDownloader retains 4 GiB.


def save(path, value):
    """Durably save before retiring the only model copy for this engine."""
    temporary = path.with_suffix(path.suffix + ".partial")
    with temporary.open("w") as stream:
        json.dump(value, stream, indent=2, sort_keys=True, allow_nan=False)
        stream.write("\n")
        stream.flush()
        os.fsync(stream.fileno())
    temporary.replace(path)


def stop_process_group(process):
    # Includes ditto/model helper descendants before their directory is removed.
    try:
        os.killpg(process.pid, signal.SIGTERM)
    except ProcessLookupError:
        pass
    try:
        process.wait(timeout=5)
    except subprocess.TimeoutExpired:
        pass
    try:
        os.killpg(process.pid, signal.SIGKILL)
    except ProcessLookupError:
        pass
    process.wait()


def run_one(app, engine, output, trials, text, timeout):
    """Return only after result persistence, process exit and verified cleanup."""
    root = Path(tempfile.mkdtemp(prefix="nextnotes-tts-"))
    (root / ".benchmark-owned").write_text(engine)
    result_path = output / (engine + ".json")
    child_path = root / "result.json"
    process = None
    result = {"engine": engine, "status": "failed", "cleanupVerified": False}
    started = time.monotonic()
    try:
        free = shutil.disk_usage(root).free
        result["freeBytesBefore"] = free
        if free < RESERVE + SPACE[engine]:
            result.update(status="not-run", reason="Insufficient disk headroom for this one model.")
        else:
            args = [str(app), "--selftest-tts-benchmark", "--tts-engine", engine,
                    "--tts-model-root", str(root), "--tts-trials", str(trials),
                    "--tts-text", text, "--tts-report", str(child_path)]
            if engine in ("phonon", "qwen"):
                args.append("--tts-playback-check")
            print(f"{engine}: preparing one model, then measuring; log: {output / (engine + '.log')}", flush=True)
            with (output / (engine + ".log")).open("w") as log:
                environment = os.environ.copy()
                # URLSession and native helpers must place transient downloads
                # inside the same owned lifetime, including interrupted files.
                environment["TMPDIR"] = str(root) + os.sep
                process = subprocess.Popen(args, stdout=log, stderr=log, start_new_session=True,
                                           env=environment)
                deadline = time.monotonic() + timeout
                while process.poll() is None:
                    if shutil.disk_usage(root).free < int(1.5 * 1024**3):
                        result["reason"] = "Disk guard stopped the owned process group before cleanup."
                        stop_process_group(process)
                        break
                    if time.monotonic() >= deadline:
                        result["reason"] = "Timed out; owned process group stopped before cleanup."
                        stop_process_group(process)
                        break
                    try:
                        process.wait(timeout=min(.5, max(.001, deadline - time.monotonic())))
                    except subprocess.TimeoutExpired:
                        pass
                code = process.returncode
            result["exitCode"] = code
            if code == 0 and child_path.exists():
                measurement = json.loads(child_path.read_text())
                if measurement.get("schema") != "nextnotes.tts-first-pcm.v1" or measurement.get("engine") != engine:
                    raise ValueError("Wrong measurement schema or engine")
                values = [row["firstPCMms"] for row in measurement["trials"] if row["phase"] == "warm"]
                if len(values) != trials or not all(isinstance(v, (int, float)) and math.isfinite(v) and v >= 0 for v in values):
                    raise ValueError("Missing or invalid warm samples")
                ordered = sorted(values)
                result.update(status="measured", measurement=measurement,
                              warmMedianMs=statistics.median(values),
                              warmP95Ms=ordered[max(0, math.ceil(.95 * len(ordered)) - 1)])
            elif "reason" not in result:
                result["reason"] = "Engine failed; see its log. No timing result was accepted."
        result["elapsedSeconds"] = time.monotonic() - started
        result["temporaryLogicalBytesBeforeCleanup"] = sum(
            path.stat().st_size for path in root.rglob("*") if path.is_file())
        # Save even failures/refusals before deleting anything; a save failure
        # retains the model directory for recovery and halts the whole comparison.
        save(result_path, result)
    except BaseException:
        if process is not None:
            stop_process_group(process)
        print(f"Result not safely saved; retained owned files at {root}", flush=True)
        raise
    if process is not None:
        stop_process_group(process)
    shutil.rmtree(root)
    if root.exists():
        raise RuntimeError(f"Cleanup failed: {root}; refusing to start the next engine")
    result["cleanupVerified"] = True
    result["freeBytesAfterCleanup"] = shutil.disk_usage(output).free
    save(result_path, result)
    print(f"{engine}: {result['status']}; temporary model removed", flush=True)
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", required=True, type=Path, help="Release NextNotes executable (does not install or build)")
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--engines", default=",".join(ENGINES))
    parser.add_argument("--trials", type=int, default=5, help="Warm samples, plus a separately labelled first synthesis")
    parser.add_argument("--text", default="I found three matching files. The latest is enclosure version seventeen.")
    parser.add_argument("--timeout", type=float, default=600, help="Per-engine preparation and measurement deadline")
    parser.add_argument("--workload", default="Standalone; ASR-plus-voice reference workload is unqualified")
    parser.add_argument("--preflight-only", action="store_true", help="Save resource/claim state without loading or downloading anything")
    parser.add_argument("--relay-owner", help="Reuse this agent's existing heavy claim; never release another owner's claim")
    parser.add_argument("--max-swap-gb", type=float, default=8,
                        help="Record an explicit diagnostic admission limit; actual free disk is still monitored")
    options = parser.parse_args()
    engines = options.engines.split(",")
    if not set(engines) <= set(ENGINES) or len(set(engines)) != len(engines):
        parser.error("Choose distinct engines from " + ",".join(ENGINES))
    if not 1 <= options.trials <= 100 or not 0 < options.timeout <= 3600:
        parser.error("Trials must be 1–100 and timeout must be 0–3600 seconds")
    if not math.isfinite(options.max_swap_gb) or options.max_swap_gb <= 0:
        parser.error("Swap admission limit must be positive and finite")
    options.app = options.app.resolve(strict=True)
    options.output.mkdir(parents=True, exist_ok=True)
    if any((options.output / (engine + ".json")).exists() for engine in engines):
        parser.error("Use a fresh output folder to preserve previous results")
    gate = subprocess.run(["agent-relay", "gate", "--min-free-gb", "2", "--max-swap-gb",
                           str(options.max_swap_gb), "--path", str(options.output)], text=True, capture_output=True, check=False)
    assessment = json.loads(gate.stdout)
    peers = subprocess.run(["agent-relay", "agents", "--active"], text=True, capture_output=True, check=False)
    claims = json.loads(peers.stdout).get("claims", [])
    active = [row for row in claims if row.get("scope") == "machine" and not row.get("stale", False)]
    if options.relay_owner and not any(row.get("agentId") == options.relay_owner and row.get("resource") == "heavy" for row in active):
        parser.error("The supplied relay owner does not hold an active heavy claim")
    competing = [row for row in active if row.get("agentId") != options.relay_owner]
    assessment["activeMachineClaims"] = competing
    if competing:
        assessment["ok"] = False
        assessment.setdefault("reasons", []).append("Another agent owns the machine benchmark window.")
    save(options.output / "preflight.json", assessment)
    if options.preflight_only:
        print("Preflight saved; no model download or inference started.")
        return 0
    if not assessment.get("ok"):
        print("No models downloaded: machine preflight refused. " + "; ".join(assessment.get("reasons", [])))
        return 2
    identity = options.relay_owner or f"codex-tts-bench-{os.getpid()}"
    if not options.relay_owner:
        subprocess.run(["agent-relay", "join", "--as", identity, "--runner", "codex"], check=True, capture_output=True)
    claimed = False
    results = []
    try:
        # The preflight above uses a per-model disk budget rather than the
        # relay's unrelated default 10 GB compiler allowance.
        if not options.relay_owner:
            subprocess.run(["agent-relay", "claim", "--as", identity, "--scope", "machine", "heavy"], check=True, capture_output=True)
            claimed = True
        with options.app.open("rb") as binary:
            digest = hashlib.file_digest(binary, "sha256").hexdigest()
        for engine in engines:
            # Sequential by construction: run_one saves, joins and deletes before returning.
            results.append(run_one(options.app, engine, options.output, options.trials, options.text, options.timeout))
            save(options.output / "summary.json", {"appSHA256": digest, "machine": platform.platform(),
                 "workload": options.workload, "results": results})
    finally:
        if claimed:
            subprocess.run(["agent-relay", "release", "--as", identity, "--scope", "machine", "heavy"], check=False, capture_output=True)
        if not options.relay_owner:
            subprocess.run(["agent-relay", "leave", "--as", identity], check=False, capture_output=True)
    return 0 if all(row["status"] == "measured" for row in results) else 1


if __name__ == "__main__":
    raise SystemExit(main())
