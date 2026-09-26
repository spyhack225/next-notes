#!/usr/bin/env python3
"""Dictation baseline numbers from this Mac's own history. Read-only; stdlib only.

Usage:
  python3 Scripts/dictation-stats.py                 # everything on disk
  python3 Scripts/dictation-stats.py --since 2026-09-20
  python3 Scripts/dictation-stats.py --since 2026-09-24T09:00 --json   # machine-readable

Reads (never writes):
  ~/Library/Application Support/Next Notes/runs.jsonl     one row per *filed* dictation
  ~/Library/Application Support/Next Notes/metrics.jsonl  dictation.* latency spans (ring, ~512 rows)
  ~/Library/Application Support/Next Notes/usage.jsonl    hold outcomes (AGENT-OVERHAUL P0-20a + D-01b)
  ~/Library/Application Support/Next Notes/dictionary.txt duplicate rules (D-10)

Field names follow the landed P0-20a schema: a usage row is stamped `ts`, its outcome
is `errorClass`, its duration `totalMs`, and its counters live in `counts`. The three
lines marked `# usage` are the only places to change if that schema moves.
"""
import argparse, collections, json, os, statistics, sys
from datetime import datetime, timezone

HOME = os.path.expanduser("~/Library/Application Support/Next Notes")


def parse_date(text):
    if text is None:
        return None
    text = text.replace("Z", "+00:00")
    try:
        value = datetime.fromisoformat(text)
    except ValueError:
        return None
    return value if value.tzinfo else value.replace(tzinfo=timezone.utc)


def rows(name):
    path = os.path.join(HOME, name)
    if not os.path.exists(path):
        return
    with open(path, encoding="utf-8") as handle:
        for line in handle:
            line = line.strip()
            if not line:
                continue
            try:
                yield json.loads(line)
            except json.JSONDecodeError:
                continue


def pct(values, q):
    if not values:
        return None
    ordered = sorted(values)
    index = min(len(ordered) - 1, max(0, round(q * (len(ordered) - 1))))
    return ordered[index]


def summary(values):
    if not values:
        return {"n": 0}
    return {
        "n": len(values),
        "p50": round(statistics.median(values), 3),
        "p90": round(pct(values, 0.9), 3),
        "max": round(max(values), 3),
    }


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--since", help="ISO date or datetime, UTC (e.g. 2026-09-20)")
    parser.add_argument("--json", action="store_true")
    args = parser.parse_args()
    since = parse_date(args.since) if args.since else None

    def keep(stamp):
        when = parse_date(stamp)
        return when is not None and (since is None or when >= since)

    out = collections.OrderedDict()

    # 1. runs.jsonl: filed dictations and their cleanup records.
    runs = [r for r in rows("runs.jsonl") if keep(r.get("date"))]
    cleanup = [r["cleanup"] for r in runs if r.get("cleanup")]
    attempted, timed_out, rejected, salvaged, accepted = [], [], [], [], []
    for c in cleanup:
        reason = c.get("fallbackReason") or ""
        verdict = c.get("guardVerdict")
        if "timed out" in reason or "took too long" in reason:
            timed_out.append(c)
            attempted.append(c)
        elif c.get("modelRan"):
            attempted.append(c)
            if verdict == "rejected":
                rejected.append(c)
            elif verdict == "partly accepted":
                salvaged.append(c)
            elif verdict == "accepted":
                accepted.append(c)
    seconds_all = [c.get("seconds") or 0.0 for c in attempted]
    wasted = sum((c.get("seconds") or 0.0) for c in timed_out + rejected)
    plans = [c for c in cleanup if c.get("structurePlanModel")]
    plan_timeouts = [c for c in plans if "ran out of time" in (c.get("structurePlanRejected") or "")]
    plan_used = [c for c in plans if not c.get("structurePlanRejected") and c.get("structureSource") == "model plan"]
    prewarm = collections.Counter(str(c.get("sessionPrewarmed")) for c in attempted)
    timeout_prewarm = collections.Counter(str(c.get("sessionPrewarmed")) for c in timed_out)
    warmth = collections.Counter(str(c.get("assumedWarmth")) for c in attempted)  # D-07
    cleaned_runs = [r for r in runs if r.get("cleanup") and (
        r["cleanup"].get("modelRan") or "timed out" in (r["cleanup"].get("fallbackReason") or ""))]
    out["runs"] = {
        "filed": len(runs),
        "with_cleanup_record": len(cleanup),
        "engines": dict(collections.Counter(r.get("engine") for r in runs)),
        "process_seconds_all": summary([r.get("processSeconds") or 0.0 for r in runs]),
        "process_seconds_model_cleaned": summary([r.get("processSeconds") or 0.0 for r in cleaned_runs]),
        "words_model_cleaned": summary([float(len((r.get("text") or "").split())) for r in cleaned_runs]),
    }
    out["cleanup"] = {
        "model_attempts": len(attempted),
        "accepted": len(accepted),
        "salvaged": len(salvaged),
        "rejected": len(rejected),
        "timed_out": len(timed_out),
        "timeout_rate": round(len(timed_out) / len(attempted), 3) if attempted else None,
        "seconds_total": round(sum(seconds_all), 1),
        "seconds_wasted_timeout_or_rejected": round(wasted, 1),
        "wasted_share": round(wasted / sum(seconds_all), 3) if sum(seconds_all) else None,
        "seconds": summary(seconds_all),
        "sessionPrewarmed_all": dict(prewarm),
        "sessionPrewarmed_on_timeouts": dict(timeout_prewarm),
        "assumedWarmth_all": dict(warmth),
        "chunked_runs": sum(1 for c in cleanup if (c.get("chunks") or 1) > 1),
        "precleaned_runs": sum(1 for c in cleanup if c.get("precleanedGroups")),
        "layout_asked": len(plans),
        "layout_timed_out": len(plan_timeouts),
        "layout_plan_used": len(plan_used),
    }

    # 2. metrics.jsonl: the dictation.* spans.
    spans = collections.defaultdict(list)
    span_notes = collections.defaultdict(collections.Counter)
    for s in rows("metrics.jsonl"):
        name = s.get("name", "")
        if not name.startswith("dictation.") or not keep(s.get("startedAt")):
            continue
        spans[name].append(s.get("durationSeconds") or 0.0)
        if s.get("note"):
            span_notes[name][s["note"]] += 1
    out["spans"] = {name: summary(values) for name, values in sorted(spans.items())}
    out["span_notes"] = {name: dict(c) for name, c in span_notes.items()}

    # 3. usage.jsonl: hold outcomes (D-01b on top of AGENT-OVERHAUL P0-20a/c).
    def stamp(u):  # usage
        return u.get("ts") or u.get("startedAt") or u.get("date")
    holds = [u for u in rows("usage.jsonl")
             if u.get("feature") == "dictation.hold" and keep(stamp(u))]  # usage
    if holds:
        outcomes = collections.Counter(u.get("errorClass") or "inserted" for u in holds)  # usage
        lost = sum(n for kind, n in outcomes.items()
                   if kind in ("lostAtStartup", "emptySpeech") or kind.startswith("failed:"))
        inserted = outcomes.get("inserted", 0) + outcomes.get("copied", 0)
        out["holds"] = {
            "total": len(holds),
            "outcomes": dict(outcomes),
            "lost_share": round(lost / len(holds), 3),
            "silent_loss_share": round(1 - (inserted / len(holds)), 3) if holds else None,
            "keyUp_to_text_ms": summary([u.get("totalMs") for u in holds
                                         if u.get("totalMs") is not None and not u.get("errorClass")]),
            "keyDown_to_capture_ms": summary([(u.get("counts") or {}).get("keyDownToCaptureMs") for u in holds
                                              if (u.get("counts") or {}).get("keyDownToCaptureMs") is not None]),
            "dropped_buffers": sum((u.get("counts") or {}).get("droppedHubBuffers", 0)
                                   + (u.get("counts") or {}).get("droppedStreamBuffers", 0) for u in holds),
            "preclean_fallback": sum(1 for u in holds if (u.get("counts") or {}).get("precleanFallback")),
        }
        refused = [u for u in rows("usage.jsonl") if u.get("feature") == "dictation.press_refused"
                   and keep(stamp(u))]  # usage
        by_state = collections.Counter(u.get("errorClass") for u in refused)  # usage
        finishing = by_state.get("finishing", 0)
        out["holds"]["press_refused"] = dict(by_state)
        # D-13's evidence gate: refused presses in `finishing`, per 100 holds.
        out["holds"]["press_refused_finishing_per_100"] = (
            round(100 * finishing / len(holds), 1) if holds else None)
    else:
        out["holds"] = "usage.jsonl has no dictation.hold rows yet (needs AGENT-OVERHAUL P0-20a and D-01b)"

    # 4. dictionary.txt: duplicate correction rules (D-10).
    path = os.path.join(HOME, "dictionary.txt")
    if os.path.exists(path):
        seen = collections.Counter()
        for line in open(path, encoding="utf-8"):
            line = line.strip()
            if not line or line.startswith("#") or "->" not in line:
                continue
            hear, write = (p.strip().lower() for p in line.split("->", 1))
            seen[(hear, write)] += 1
        out["dictionary"] = {
            "correction_rules": sum(seen.values()),
            "duplicate_rules": sum(n - 1 for n in seen.values() if n > 1),
            "duplicated": [f"{h} -> {w} x{n}" for (h, w), n in seen.items() if n > 1],
        }

    if args.json:
        json.dump(out, sys.stdout, indent=1, default=str)
        print()
        return
    for section, body in out.items():
        print(f"== {section}")
        if isinstance(body, dict):
            for key, value in body.items():
                print(f"  {key}: {value}")
        else:
            print(f"  {body}")


if __name__ == "__main__":
    main()
