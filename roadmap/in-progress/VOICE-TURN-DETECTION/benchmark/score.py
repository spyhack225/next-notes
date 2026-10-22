#!/usr/bin/env python3
"""Score supplied voice-turn traces. No audio/model/app execution or promotion claim."""
import argparse
import copy
import json
import math
import sys
from collections import defaultdict
from pathlib import Path


def number(value, name):
    if isinstance(value, bool) or not isinstance(value, (int, float)) or not math.isfinite(value):
        raise ValueError(f"{name} must be a finite number")
    return float(value)


def distribution(values):
    values = sorted(values)
    if not values:
        return {"n": 0, "median_ms": None, "p90_ms": None, "p95_ms": None, "max_ms": None}
    def percentile(q):
        position = (len(values) - 1) * q
        low, high = math.floor(position), math.ceil(position)
        return values[low] + (values[high] - values[low]) * (position - low)
    return {"n": len(values), "median_ms": percentile(.5), "p90_ms": percentile(.9),
            "p95_ms": percentile(.95), "max_ms": values[-1]}


def score(manifest, run):
    if manifest.get("schema") != "nextnotes.turn-cases.v1" or run.get("schema") != "nextnotes.turn-trace.v1":
        raise ValueError("unsupported manifest/trace schema")
    cases = {case["id"]: case for case in manifest["cases"]}
    if len(cases) != len(manifest["cases"]) or not cases:
        raise ValueError("case IDs must be unique and nonempty")
    if run.get("evidence") not in ("authored", "native_replay", "physical"):
        raise ValueError("evidence must be authored, native_replay or physical")
    if run.get("clock") not in ("monotonic", "sample"):
        raise ValueError("clock must be monotonic or sample")
    if not isinstance(run.get("trials"), list):
        raise ValueError("trials must be an array")
    groups, rows, identities = defaultdict(list), [], set()
    for trial in run["trials"]:
        case_id, trial_id = trial.get("case_id"), trial.get("trial_id")
        if case_id not in cases or not isinstance(trial_id, str) or not trial_id or trial_id in identities:
            raise ValueError("unknown case or missing/duplicate trial_id")
        identities.add(trial_id)
        case = cases[case_id]
        phase = trial.get("phase")
        if phase not in manifest["minimum_trials_by_phase"]:
            raise ValueError(f"{trial_id}: unknown phase")
        for field in ("asr", "tts", "condition", "language"):
            if not isinstance(trial.get(field), str) or not trial[field]:
                raise ValueError(f"{trial_id}: missing {field}")
        key = (case_id, phase, trial["asr"], trial["tts"], trial["condition"], trial["language"])
        status = trial.get("status")
        if status not in ("measured", "failed", "absent", "unsupported"):
            raise ValueError(f"{trial_id}: invalid status")
        row = {"trial_id": trial_id, "case_id": case_id, "status": status,
               "failures": [], "metrics_ms": {}}
        groups[key].append(row)
        rows.append(row)
        if status != "measured":
            row["failures"].append("trial_" + status)
            continue
        gt = trial.get("ground_truth", {})
        intervals = gt.get("protected_intervals_ms")
        if not isinstance(intervals, list):
            raise ValueError(f"{trial_id}: reviewed protected_intervals_ms required (may be empty)")
        checked_intervals = []
        for interval in intervals:
            if not isinstance(interval, list) or len(interval) != 2:
                raise ValueError("protected interval must contain start,end")
            start, end = [number(value, "protected interval") for value in interval]
            if start < 0 or end <= start:
                raise ValueError("invalid protected interval bounds")
            checked_intervals.append((start, end))
        if case.get("protected_pause") and not checked_intervals:
            raise ValueError(f"{trial_id}: protected-pause case requires a protected interval")
        events = trial.get("events")
        if not isinstance(events, list):
            raise ValueError(f"{trial_id}: events must be an array")
        named = defaultdict(list)
        for event in events:
            name = event.get("name")
            if name not in ("commit", "first_audible", "duck", "pause", "stop", "effect"):
                raise ValueError(f"{trial_id}: unknown scored event {name!r}")
            at = number(event.get("at_ms"), "event.at_ms")
            if at < 0:
                raise ValueError("event.at_ms must be relative to capture origin and nonnegative")
            named[name].append(at)
            if name in ("commit", "first_audible", "effect") and any(a <= at < b for a, b in checked_intervals):
                row["failures"].append("protected_" + name)
        if len(named["commit"]) != case["expected_commits"]:
            row["failures"].append("commit_count")
        if case.get("no_output"):
            for name in ("first_audible", "effect", "duck", "pause", "stop"):
                if named[name]:
                    row["failures"].append("unexpected_" + name)
        if case.get("tail_required") and trial.get("tail_retained") is not True:
            row["failures"].append("final_words_missing_or_unverified")
        if case["expected_commits"] == 1:
            speech_end = number(gt.get("speech_end_ms"), "ground_truth.speech_end_ms")
            if speech_end < 0:
                raise ValueError("speech_end_ms cannot be negative")
            for name, metric in (("commit", "endpoint"), ("first_audible", "audible")):
                if named[name]:
                    latency = min(named[name]) - speech_end
                    row["metrics_ms"][metric] = latency
                    if latency < 0:
                        row["failures"].append("premature_" + name)
                elif name == "commit" or case.get("require_audible"):
                    row["failures"].append("missing_" + name)
            if named["commit"] and named["first_audible"] and min(named["first_audible"]) < min(named["commit"]):
                row["failures"].append("audible_before_commit")
            if any(at < speech_end or (named["commit"] and at < min(named["commit"])) for at in named["effect"]):
                row["failures"].append("effect_before_commit")
            if not named["commit"] or min(named["commit"]) - speech_end > manifest["targets_ms"]["endpoint_timeout"]:
                row["failures"].append("endpoint_timeout")
        if case.get("require_duck"):
            onset = number(gt.get("near_onset_ms"), "ground_truth.near_onset_ms")
            if not named["duck"]:
                row["failures"].append("missing_duck")
            else:
                latency = min(named["duck"]) - onset
                row["metrics_ms"]["duck"] = latency
                if latency < 0:
                    row["failures"].append("duck_before_near_speech")
        if run["clock"] == "monotonic" and run["evidence"] != "physical":
            pacing = trial.get("pacing_p95_error_ms")
            if pacing is None:
                row["failures"].append("unverified_pacing")
            elif number(pacing, "pacing error") < 0 or pacing > manifest["targets_ms"]["pacing_p95_error"]:
                row["failures"].append("pacing_invalid")
        if run["evidence"] != "authored":
            digest = trial.get("audio_sha256", "")
            if len(digest) != 64 or any(c not in "0123456789abcdef" for c in digest):
                row["failures"].append("missing_audio_identity")
        row["failures"] = sorted(set(row["failures"]))
    summaries = []
    for key, members in sorted(groups.items()):
        case_id, phase, asr, tts, condition, language = key
        metrics = {name: distribution([r["metrics_ms"][name] for r in members if name in r["metrics_ms"]])
                   for name in ("endpoint", "audible", "duck")}
        failures = sorted({reason for r in members for reason in r["failures"]})
        measured = sum(row["status"] == "measured" for row in members)
        minimum = manifest["minimum_trials_by_phase"][phase]
        if measured < minimum:
            failures.append("insufficient_measured_trials")
        case = cases[case_id]
        gates = {"endpoint": case["expected_commits"] == 1,
                 "audible": case.get("require_audible", False), "duck": case.get("require_duck", False)}
        for metric, required in gates.items():
            if not required:
                continue
            dist = metrics[metric]
            if dist["n"] != measured or dist["n"] == 0:
                failures.append("incomplete_" + metric + "_samples")
            # Cold audible has no newly invented warm-latency gate.
            if metric == "audible" and phase != "warm":
                continue
            limit = manifest["targets_ms"][metric + "_p95"]
            if dist["p95_ms"] is not None and dist["p95_ms"] > limit:
                failures.append(metric + "_p95_exceeded")
        summaries.append({"case_id": case_id, "phase": phase, "asr": asr, "tts": tts,
                          "condition": condition, "language": language, "attempts": len(members),
                          "measured": measured, "minimum_measured": minimum, "metrics_ms": metrics,
                          "passed": not failures, "failures": sorted(set(failures))})
    seen = {trial["case_id"] for trial in run["trials"]}
    missing = sorted(case_id for case_id, case in cases.items() if case.get("required") and case_id not in seen)
    subset_passed = bool(summaries) and all(item["passed"] for item in summaries)
    wall_eligible = run["clock"] == "monotonic" and run["evidence"] != "authored"
    return {"schema": "nextnotes.turn-score.v1", "run_id": run.get("run_id"),
            "evidence": run["evidence"], "clock": run["clock"], "trace_subset_passed": subset_passed,
            "required_cases_missing": missing, "required_case_ids_present": not missing,
            "wall_latency_evidence_eligible": wall_eligible,
            "product_promotion": "not_evaluated",
            "remaining_gates": ["native provenance and generation identity review", "held-out statistics G6",
                                "provider/phase/route coverage", "physical audible evidence",
                                "resources and current acceptance G8"],
            "groups": summaries, "trials": rows}


def self_test():
    manifest = {"schema": "nextnotes.turn-cases.v1", "minimum_trials_by_phase": {"warm": 2, "cold_capture": 2},
                "targets_ms": {"endpoint_p95": 450, "audible_p95": 900, "duck_p95": 200,
                               "endpoint_timeout": 2500, "pacing_p95_error": 20},
                "cases": [{"id": "pause", "required": True, "protected_pause": True,
                           "expected_commits": 1, "tail_required": True, "require_audible": True}]}
    trial = {"case_id": "pause", "trial_id": "a", "phase": "warm", "asr": "scripted",
             "tts": "scripted", "condition": "clean", "language": "en", "status": "measured",
             "tail_retained": True, "pacing_p95_error_ms": 0,
             "ground_truth": {"speech_end_ms": 2000, "protected_intervals_ms": [[500, 2000]]},
             "events": [{"name": "commit", "at_ms": 2300}, {"name": "first_audible", "at_ms": 2600}]}
    second = copy.deepcopy(trial)
    second["trial_id"] = "b"
    good = {"schema": "nextnotes.turn-trace.v1", "run_id": "authored-self-test",
            "evidence": "authored", "clock": "monotonic", "trials": [trial, second]}
    checks = 0
    def check(condition):
        nonlocal checks
        checks += 1
        if not condition:
            raise AssertionError(f"scorer check {checks} failed")
    report = score(manifest, good)
    check(report["trace_subset_passed"])
    check(not report["wall_latency_evidence_eligible"] and report["product_promotion"] == "not_evaluated")
    check(distribution([])["p95_ms"] is None)
    for mutation in ("early", "missing", "tail", "duplicate", "late", "absent", "pacing", "effect"):
        bad = copy.deepcopy(good)
        item = bad["trials"][0]
        if mutation == "early": item["events"][0]["at_ms"] = 1200
        elif mutation == "missing": item["events"].pop()
        elif mutation == "tail": item["tail_retained"] = False
        elif mutation == "duplicate": item["events"].append({"name": "commit", "at_ms": 2400})
        elif mutation == "late": item["events"][1]["at_ms"] = 5000
        elif mutation == "absent": item["status"] = "absent"
        elif mutation == "pacing": item["pacing_p95_error_ms"] = 90
        else: item["events"].append({"name": "effect", "at_ms": 2200})
        check(not score(manifest, bad)["trace_subset_passed"])
    bad = copy.deepcopy(good)
    bad["trials"][0]["events"][0]["at_ms"] = float("nan")
    try:
        score(manifest, bad)
    except ValueError:
        check(True)
    else:
        check(False)
    check(not score(manifest, {**good, "trials": []})["trace_subset_passed"])
    check(score(manifest, {**good, "trials": []})["required_cases_missing"] == ["pause"])
    check(not score(manifest, {**good, "trials": [trial]})["trace_subset_passed"])
    check(not score(manifest, {**good, "clock": "sample"})["wall_latency_evidence_eligible"])
    native = copy.deepcopy(good)
    native["evidence"] = "native_replay"
    check(not score(manifest, native)["trace_subset_passed"])
    for item in native["trials"]:
        item["audio_sha256"] = "a" * 64
    check(score(manifest, native)["trace_subset_passed"])
    physical = copy.deepcopy(native)
    physical["evidence"] = "physical"
    for item in physical["trials"]:
        item.pop("pacing_p95_error_ms")
    check(score(manifest, physical)["trace_subset_passed"])
    duck_manifest = copy.deepcopy(manifest)
    duck_manifest["cases"][0]["require_duck"] = True
    duck_run = copy.deepcopy(good)
    for item in duck_run["trials"]:
        item["ground_truth"]["near_onset_ms"] = 1000
        item["events"].append({"name": "duck", "at_ms": 1150})
    check(score(duck_manifest, duck_run)["trace_subset_passed"])
    duck_run["trials"][0]["events"][-1]["at_ms"] = 1600
    check(not score(duck_manifest, duck_run)["trace_subset_passed"])
    print(f"TURN_SCORER_OK authored_checks={checks}; no model/audio/native latency measured")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--manifest", type=Path, default=Path(__file__).with_name("cases.json"))
    parser.add_argument("--trace", type=Path)
    parser.add_argument("--out", type=Path)
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args()
    try:
        if args.self_test:
            self_test()
            return 0
        if args.trace is None:
            parser.error("--trace is required unless --self-test is used")
        result = score(json.loads(args.manifest.read_text()), json.loads(args.trace.read_text()))
        rendered = json.dumps(result, indent=2, allow_nan=False) + "\n"
        if args.out:
            if args.out.resolve() in (args.trace.resolve(), args.manifest.resolve()):
                raise ValueError("output cannot overwrite input trace or manifest")
            args.out.write_text(rendered)
        else:
            print(rendered, end="")
        return 0 if result["trace_subset_passed"] and not result["required_cases_missing"] else 1
    except (ValueError, KeyError, TypeError, OSError, AssertionError) as error:
        print(f"TURN_SCORER_INPUT_OR_CHECK_FAILED: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
