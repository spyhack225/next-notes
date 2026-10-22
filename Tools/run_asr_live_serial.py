"""Resumeable serial diagnostics. Coordinate the machine window before invoking.

No model/runtime installation survives its candidate command. A failed command
stops the suite; do not silently skip a missing result when choosing a default.
"""
import datetime
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import statistics
import subprocess
import sys
from asr_benchmark import ROOT

REPORTS = ROOT/"Tests/Reports/asr-live-latency-2026-10-22"


def context():
    result = {"at": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "disk_free_bytes": shutil.disk_usage(ROOT).free}
    for name, cmd in [("thermal",["pmset","-g","therm"]),
        ("swap",["sysctl","vm.swapusage"]), ("power",["pmset","-g","batt"]),
        ("load",["sysctl","vm.loadavg"]), ("processes",["ps","-axo","pid,pcpu,rss,comm"])]:
        p = subprocess.run(cmd, capture_output=True, text=True)
        result[name] = p.stdout
    return result


def main():
    global REPORTS
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output-dir", type=Path, default=REPORTS)
    options = parser.parse_args()
    REPORTS = options.output_dir
    REPORTS.mkdir(exist_ok=True, parents=True)
    old_whistle = REPORTS/"whistle.json"
    if old_whistle.exists() and json.loads(old_whistle.read_text()).get("small_cpu_pressure_diagnostic"):
        raise RuntimeError("Keep the pressure diagnostic separate; choose a fresh --output-dir for the comparable suite")
    env = {**os.environ,"ASR_LIVE":"1","PYTHONDONTWRITEBYTECODE":"1"}
    cache = Path.home()/"Library/Caches/NextNotesASRBench"
    commands = [
        ("parakeet-v3", "asr_cached_live.py", []),
        ("whistle", "asr_benchmark.py", []),
        ("redux", "asr_coreml_compare.py", ["--engine","redux"]),
        ("ultra", "asr_coreml_compare.py", ["--engine","ultra"]),
        ("phonon", "asr_phonon_compare.py", []),
        ("qwen-06b", "asr_qwen_compare.py", ["--size","0.6b"]),
        ("qwen-17b", "asr_qwen_compare.py", ["--size","1.7b"]),
        ("voz", "asr_voz_live.py", []),
    ]
    if not (cache/"runtime-probe").exists():
        record = REPORTS/"probe-build.json"
        if record.exists():
            record = REPORTS/('probe-build-'+datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%dT%H%M%S%fZ')+'.json')
        subprocess.run([sys.executable,"-B",str(ROOT/"Tools/build_asr_probe.py"),
            "--record",str(record)],check=True)
    for name, script, extra in commands:
        output = REPORTS/f"{name}.json"
        if output.exists():
            existing = json.loads(output.read_text())
            if existing.get("benchmark",{}).get("trials") and existing.get("child_exit",0)==0:
                print(f"Already saved: {name}",flush=True)
                continue
            raise RuntimeError(f"Unaccepted existing report {output}; inspect before resuming")
        before = context()
        print(f"START {name} disk={before['disk_free_bytes']/1024**3:.2f}GiB",flush=True)
        completed = subprocess.run([sys.executable,"-B",str(ROOT/"Tools"/script),
            *extra,"--output",str(output)],env=env)
        after = context()
        context_path = REPORTS/f"{name}-context.json"
        if context_path.exists():
            context_path = REPORTS/(name+'-context-'+datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%dT%H%M%S%fZ')+'.json')
        context_path.write_text(json.dumps({"before":before,"after":after,
            "command_exit":completed.returncode},indent=2)+"\n")
        if completed.returncode:
            raise SystemExit(completed.returncode)
        print(f"FINISHED {name}; serial child joined and temporary assets removed",flush=True)
    old = json.loads((ROOT/"Tests/Reports/asr-candidates-2026-10-22/comparison.json").read_text())
    identities = {"parakeet-v3":"parakeet-v3-runtime"}
    summary = {"scope":"Paced native runtime delivery, warmed prefix shapes; not physical microphone/UI/polish/duplex acceptance", "rows":[]}
    for name, _, _ in commands:
        raw = json.loads((REPORTS/f"{name}.json").read_text())["benchmark"]
        previous = next(r for r in old["rows"] if r["id"] == identities.get(name,name))
        row = {"id":name,"model":previous["model"],"model_bytes":previous["model_bytes"],
            "source":f"{name}.json", "languages":{}}
        for language in ("en","fr"):
            samples = [r for r in raw["trials"] if r["language"] == language]
            if not samples:
                continue
            metrics = {"samples":len(samples),"first_texts":[r["first_text"] for r in samples],
                "short_hold_wer":[r["wer"] for r in samples],
                "previous_full_fixture_wer":previous["languages"][language]["wer"]}
            for key in ("first_text_ms","first_correct_reference_word_ms", "first_final_consistent_word_ms",
                "first_committed_ms","release_to_final_ms"):
                values = [r[key] for r in samples if r[key] is not None]
                metrics[key] = {"values":values,"median":statistics.median(values) if values else None,
                    "min":min(values) if values else None,"max":max(values) if values else None}
            row["languages"][language] = metrics
        summary["rows"].append(row)
    (REPORTS/"comparison.json").write_text(json.dumps(summary,indent=2,ensure_ascii=False)+"\n")
    # This probe was created for this suite, is no longer executing, and is
    # reproducible from the retained source/build receipt. Owner model caches stay.
    binary = cache/"runtime-probe"
    receipt = {"path":str(binary),"bytes":binary.stat().st_size,
        "sha256":hashlib.sha256(binary.read_bytes()).hexdigest()}
    binary.unlink()
    receipt["deleted"] = not binary.exists()
    (REPORTS/"probe-cleanup.json").write_text(json.dumps(receipt,indent=2)+"\n")


if __name__ == "__main__":
    main()
