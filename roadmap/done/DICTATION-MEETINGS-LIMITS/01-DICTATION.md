# Dictation: D-01 … D-16

> **Historical model assumptions — revised 2026-09-30:** this completed plan/audit
> preserves its dated measurements and implementation history. For new work, follow
> the [independent-role/shared-file contract](../../in-progress/SHARED-BRAIN/00-README.md): Meetings, Agent and cleanup
> may use different appropriate models; exact verified artifacts are reused, with
> workload-specific consent and request ownership. Agent-only file selection,
> universal model defaults and deletion based only on the Agent are superseded.
> MiniCPM cleanup + Apple guard/fallback is concurrent work, not evidence that this
> historical build used it. Re-measure quality/latency on the actual current engine.

Read `00-README.md` first (workflow, rules, kept limits, how this interleaves with
AGENT-OVERHAUL). Evidence for every task is
`roadmap/done/agent-analysis-2026-09-23/I1-caps-dictation.md` (cited as **I1-NN**). Paths are relative to
`Sources/NextNotes/` unless they start with a repo-root folder (`Scripts/`, `Tests/`, `shared/`,
`roadmap/`). Line numbers were verified against the working tree on 2026-09-24; each anchor also
names its symbol so you can `grep -n` for it when lines move.

---

## 0. Overview

### 0.1 Goal

**Dictation feels instant and never loses words.** Concretely: the wait after the key comes up is
the time to type the words, not the time for a model to wake up or to be waited out and thrown
away; and every hold either types something, or says in plain words what went wrong and offers to
try again with the audio it already has.

### 0.2 What the evidence says (I1, this Mac, 09-10 → 09-24)

| Stage | Median | p90 | Max | Source |
|---|---|---|---|---|
| key-down → microphone capturing (`dictation.keyDown_to_capture`) | 0.066 s | 0.392 s | **4.398 s** | `metrics.jsonl`, 19 holds |
| key-up → ASR final (`dictation.keyUp_to_asr_final`) | 0.378 s | 1.459 s | 2.344 s | 17 holds |
| ASR final → cleanup done (`dictation.asr_final_to_cleanup`) | **5.186 s** | 9.815 s | 11.518 s | 15 holds |
| cleanup → injected (`dictation.cleanup_to_injection`) | 0.150 s | 0.219 s | 0.251 s | 15 holds |
| key-up → run filed (`processSeconds`, model-cleaned runs only) | 4.46 s | 9.74 s | — | `runs.jsonl`, 50 runs |
| cleanup model attempts: accepted / salvaged / rejected / **timed out** | 35 / 3 / 3 / **9** (18 %) | | | `runs.jsonl` |
| cleanup seconds wasted on timeouts + rejections | **81.8 of 242.6 s** (34 %) | | | `runs.jsonl` |
| layout pass asked / cut by its deadline / plan used | 6 / 5 / 1 | | | `runs.jsonl` |
| words per model-cleaned dictation | 36.5 | 118 | 238 | `runs.jsonl` (the longest filed run overall is 335 words, I1-20) |

These numbers are reproduced exactly by the stats script in §0.4 (run on 2026-09-24).

### 0.3 Targets

"Measured" = today's value from §0.2. "Target" values are **derived** from I1's evidence as
stated, not measured; where a number is an estimate, it says so. The deterministic self-test in
each task is that task's gate. The real-use targets are checked against the owner's own holds with
the stats script and recorded in `STATUS.md` → *Owner-use measurements*.

| # | Metric (how measured) | Measured | Target | Derivation |
|---|---|---|---|---|
| T1 | key-up → text, dictations that ran the cleanup model (`processSeconds`, or `dictation.hold` `totalMs` once D-01b exists), p50 / p90 | 4.46 s / 9.74 s | **after Phase C: ≤ 3.0 s / ≤ 6.5 s; after D-12: ≤ 2.0 s / ≤ 4.5 s** | Phase C removes the timeouts (each costs its full budget) and the cold start: a prewarmed 40-word cleanup measured 2.87 s (I1-01, 09-22 21:52). D-12 removes the cleanup of already-stable sentences from the tail; I1-11 proposes "tail p50 ≤ 2 s". |
| T2 | cleanup timeout rate (`timed_out / model_attempts`) | 18 % (9/50) | **≤ 2 %** | A timeout should only mean a true stall. The observed ones were cold starts (I1-01) and serialised groups (I1-02). |
| T3 | share of cleanup seconds wasted (timeout + whole-answer rejection) | 34 % | **≤ 10 %** (estimate) | D-07/D-08 remove timeouts; D-11 turns most rejections into salvages. |
| T4 | key-down → capturing, p90, including a cold model (`dictation.keyDown_to_capture`) | 0.392 s (max 4.40 s) | **≤ 0.150 s p90, whatever the model state** | D-02 opens the microphone at key-down, before the model load; what is left is the permission check and the hub subscribe. |
| T5 | holds with speech that end with nothing typed and no message (`dictation.hold` rows) | not countable (≥ 2 on 09-23) | **0**; every hold has exactly one outcome row | D-01b makes it countable; D-02/D-03 remove the paths. |
| T6 | raw engine or framework strings shown to the user | 1 in 24 h (FluidAudio) | **0** | D-04. |
| T7 | layout passes cut by the deadline while cleanup was still running | 5 of 6 | **≤ 1 in 10 asked** (estimate) | D-09 anchors the deadline to the cleanup. |
| T8 | a press in the 3 s after an error | refused silently | **starts a hold** | D-05. |
| T9 | learner: bad or duplicate rules added | 1 bad, 5 duplicates on disk | **0 new**; the bad one offered for review | D-10. |

### 0.4 The stats script (baseline and every comparison)

Save this as `Scripts/dictation-stats.py` during the baseline (`STATUS.md` → *Baseline*) and commit
it with the baseline report. It only reads files. It was run against this Mac's data on
2026-09-24 and printed the §0.2 numbers (`model_attempts: 50`, `timed_out: 9`,
`seconds_wasted_timeout_or_rejected: 81.8`, `layout_asked: 6`, `layout_timed_out: 5`,
`duplicate_rules: 5`). The `holds` section fills in once D-01b writes `dictation.hold` rows to
`usage.jsonl`; if P0-20a lands with different field names than `feature` / `errorClass` /
`totalMs` / `startedAt`, adjust the three lines marked `# usage` and note it in `STATUS.md`.

```python
#!/usr/bin/env python3
"""Dictation baseline numbers from this Mac's own history. Read-only; stdlib only.

Usage:
  python3 Scripts/dictation-stats.py                 # everything on disk
  python3 Scripts/dictation-stats.py --since 2026-09-20
  python3 Scripts/dictation-stats.py --since 2026-09-24T09:00 --json   # machine-readable

Reads (never writes):
  ~/Library/Application Support/Next Notes/runs.jsonl     one row per *filed* dictation
  ~/Library/Application Support/Next Notes/metrics.jsonl  dictation.* latency spans (ring, ~512 rows)
  ~/Library/Application Support/Next Notes/usage.jsonl    hold outcomes, once AGENT-OVERHAUL P0-20c + D-01b land
  ~/Library/Application Support/Next Notes/dictionary.txt duplicate rules (D-10)
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
        "chunked_runs": sum(1 for c in cleanup if (c.get("chunks") or 1) > 1),
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

    # 3. usage.jsonl: hold outcomes (D-01b on top of AGENT-OVERHAUL P0-20a/c). Absent before then.
    def stamp(u):  # usage
        return u.get("startedAt") or u.get("date") or u.get("timestamp")
    holds = [u for u in rows("usage.jsonl")
             if u.get("feature") == "dictation.hold" and keep(stamp(u))]  # usage
    if holds:
        outcomes = collections.Counter(u.get("errorClass") or "inserted" for u in holds)  # usage
        lost = sum(n for kind, n in outcomes.items()
                   if kind in ("lostAtStartup", "emptySpeech") or kind.startswith("failed:"))
        out["holds"] = {
            "total": len(holds),
            "outcomes": dict(outcomes),
            "lost_share": round(lost / len(holds), 3),
            "keyUp_to_text_ms": summary([u.get("totalMs") for u in holds
                                         if u.get("totalMs") is not None and not u.get("errorClass")]),
            "keyDown_to_capture_ms": summary([(u.get("counts") or {}).get("keyDownToCaptureMs") for u in holds
                                              if (u.get("counts") or {}).get("keyDownToCaptureMs") is not None]),
            "dropped_buffers": sum((u.get("counts") or {}).get("droppedHubBuffers", 0)
                                   + (u.get("counts") or {}).get("droppedStreamBuffers", 0) for u in holds),
        }
        refused = [u for u in rows("usage.jsonl") if u.get("feature") == "dictation.press_refused"
                   and keep(stamp(u))]
        out["holds"]["press_refused"] = dict(collections.Counter(u.get("errorClass") for u in refused))
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
```

Compare before/after with the same `--since` window length, never across a change of
`cleanupEngine` or `cleanupFixesGrammar` (the script prints the engine mix; check it).

### 0.5 Order

D-01a → D-01b (Phase A) → D-04 → D-05 → D-10 → D-02 → D-03 (Phase B) → D-06 → D-07 → D-08 →
D-09 → D-11 (Phase C) → D-12 → D-15a → D-15b → D-15c → D-16 → D-13 (evidence) → D-14 (evidence)
(Phase D). Each task's **Depends on** line is authoritative.

### 0.6 Exit gate for the dictation half

All of these, in addition to the phase gates in `00-README.md` §8:
- every D row in `STATUS.md` is `done`, `blocked` with a note, or `won't do (evidence)` with the
  numbers;
- `Scripts/run-selftest.sh --via-open --selftest-dictation` → `DICTATION_OK…` with every case
  added by D-01b, D-02, D-03, D-04, D-05 (and D-12, D-13 if done);
- `Scripts/run-selftest.sh --selftest-cleanup-router` → `CLEANUP_ROUTER_OK`;
- `Scripts/run-selftest.sh --selftest-learn` → `LEARN_OK…`;
- `Scripts/run-selftest.sh --selftest-dictation-hygiene` → `DICTATION_HYGIENE_OK`;
- `Scripts/run-selftest.sh --selftest-cleanup apple-grammar` → `CLEANUP_OK`, and its
  `CLEANUP_SUMMARY apple-grammar` line shows `cold` below the D-07 cold budget for the first case;
- `make test` green;
- `make acceptance TIER=core` no regression against the baseline;
- the stats script shows T2, T5, T6 met on at least 30 owner holds after the Phase C gate, or the
  shortfall recorded in *Owner-use measurements* with the reason.

### 0.7 Shared seams (added once, used by several tasks)

Introduce each seam in the first task that needs it and reuse it after. Production code always
passes the default; only self-tests pass anything else.

| Seam | Added by | Used by | Shape |
|---|---|---|---|
| `FoundationModelFormatter.modelCall` | D-01a | D-07, D-08, D-11 | `var modelCall: CleanupModelCall? = nil`; when set, replaces `CleanupSessionWarmer.take` + `session.respond` and bypasses `isAvailable` |
| `FoundationModelFormatter.timeScale` | D-07 | D-08 | `var timeScale: Double = 1` multiplies the computed timeout (tests use 0.05) |
| `SelfTestEngine.Shape` new cases | D-01b … D-05, D-12 | | `.failsStart(String)`, `.emptyTranscript`, `.throwsOnFinish(String)`, `.countsFrames(startDelay:)`, `.partials([String], every:)` in `NextNotesApp.swift` next to `SelfTestEngine` (:5989) |
| `DictationController` `outcome:` sink | D-01b | D-02 … D-05 | `outcome: @MainActor (DictationHoldOutcome) -> Void`, default writes a `UsageRecord` through `UsageLog.shared` |
| `DictationController` `speechDetector:` | D-03 | | `@Sendable (AVAudioPCMBuffer) -> Bool`, default RMS-based |

```swift
// Formatting/FoundationModelFormatter.swift (D-01a)
/// What one model call needs to report, in the order it happens: whether a staged session was
/// used (known *before* the call), then the answer.
struct CleanupModelCall: Sendable {
    var takeSession: @Sendable (_ instructions: String) async -> Bool      // true = a staged session was taken
    var respond: @Sendable (_ user: String) async throws -> String
}
```

---

## Phase A — measure

### D-01a — `sessionPrewarmed` recorded before `respond`, on every exit including timeout
**Finding(s):** I1-13  **Effort:** 2 h  **Depends on:** none  **Unblocks:** D-06, D-07 (their effect is measured per run through this field)

**Why (what the user experiences today):** Nothing visible; this is the measurement the next four
tasks are judged by. All 9 cleanup timeouts in `runs.jsonl` have `sessionPrewarmed: null`
(stats script: `sessionPrewarmed_on_timeouts: {'None': 8, 'True': 1}`), because the field is
written only after the model answers. So I1-01's claim, "the timeouts are cold starts", cannot be
proven per run.

**Files you will change:**
- `Formatting/FoundationModelFormatter.swift` (`format`, `cleanReporting`, new `CleanupModelCall`)
- `Formatting/StructurePlanner.swift` (`AppleStructurePlanner.plan`: record the layout session's prewarm too)
- `Formatting/CleanupTrace.swift` (`CleanupRecord.structurePlanPrewarmed: Bool?`, `CleanupTrace.noteStructurePlanPrewarmed(_:)`)
- `Formatting/CleanupRouter.swift` (`runSelfTest`: new `prewarmTraceFailures()`)

**Read for context (do not change):** `CleanupSessionWarmer` (`FoundationModelFormatter.swift:313-351`);
`CleanupTrace.noteSessionPrewarmed` (`CleanupTrace.swift:166`); `CleanupRecord` (`CleanupTrace.swift:186-245`).

**Current behaviour:** `FoundationModelFormatter.format` (`FoundationModelFormatter.swift:92-169`)
races `cleanReporting` against `Task.sleep(for: budget)` in a task group, and only after the group
returns a result does it call:
```swift
            trace?.noteSessionPrewarmed(prewarmed)      // :127 — never reached on timeout or throw
```
`cleanReporting` (`:216-248`) calls `CleanupSessionWarmer.shared.take(instructions:)` (`:232`) and
returns `staged != nil` together with the text. `AppleStructurePlanner.plan` takes its staged
session the same way (`StructurePlanner.swift:136-139`) and records nothing about it.

**Target behaviour:**
1. Every `FoundationModelFormatter.format` call that reaches the model records
   `sessionPrewarmed = true|false` on its trace **before** `respond` is awaited, so timed-out,
   thrown and rejected runs carry it.
2. A layout pass records `structurePlanPrewarmed = true|false` the same way.
3. The per-call value is still last-writer-wins for chunked runs (D-08 adds per-group values).

**Steps:**
1. Add `CleanupModelCall` (§0.7) and `var modelCall: CleanupModelCall? = nil` on
   `FoundationModelFormatter` (it is a struct; add the property with a default so every existing
   initialiser call still compiles).
2. Change `cleanReporting` to take the trace and report the prewarm as soon as it is known:
   ```swift
   static func cleanReporting(_ text: String, preferences: CleanupPreferences, fixesGrammar: Bool,
                              target: OutputProfile = …, context: ScreenContext = .empty,
                              trace: CleanupTrace?, modelCall: CleanupModelCall?) async throws -> String {
       let instructions = CleanupInstructions.system(for: preferences, fixesGrammar: fixesGrammar,
                                                     target: target, context: context)
       let user = CleanupInstructions.user(text, fixesGrammar: fixesGrammar)
       if let modelCall {
           trace?.noteSessionPrewarmed(await modelCall.takeSession(instructions))
           return try await modelCall.respond(user).trimmingCharacters(in: .whitespacesAndNewlines)
       }
       let staged = await CleanupSessionWarmer.shared.take(instructions: instructions)
       trace?.noteSessionPrewarmed(staged != nil)          // before the call, always
       let session = staged ?? LanguageModelSession(instructions: instructions)
       let response = try await session.respond(to: user, options: GenerationOptions(
           temperature: 0.1, maximumResponseTokens: 1_200))
       return response.content.trimmingCharacters(in: .whitespacesAndNewlines)
   }
   ```
   Grep for every caller of `cleanReporting` (`grep -rn "cleanReporting" Sources/`) and update them;
   remove the `trace?.noteSessionPrewarmed(prewarmed)` line at `:127`.
3. In `format`, when `modelCall != nil`, skip the `Self.isAvailable` guard (the seam stands in for
   the model).
4. `AppleStructurePlanner.plan`: after the `take(instructions: StructurePlanPrompt.system)` line,
   hand the result out through the outcome: add `var prewarmed: Bool?` to `StructurePlanOutcome`
   (`StructurePlan.swift:605`) and have `CleanupRouter` call
   `trace?.noteStructurePlanPrewarmed(outcome.prewarmed)` where it already records the plan
   (`noteStructurePlan`). A timed-out plan must still carry it: capture the value in a local
   `let prewarmedBox = LockedBox<Bool?>(nil)` set inside the child task before `respond`, and read
   it in the `catch` path.
5. `CleanupRecord` gains `var structurePlanPrewarmed: Bool?` (optional: the synthesized `Codable`
   decodes old rows as nil).

**Do not:**
- Change the timeout formula here (that is D-07).
- Add `sessionPrewarmed` to anything the user sees; `CleanupRecord.plainSummary` stays as it is.
- Let a self-test reach Apple's model: the new fixture uses `modelCall`.

**Red-first self-test:** extend `--selftest-cleanup-router` (`CleanupRouter.runSelfTest`,
`Formatting/CleanupRouter.swift:556`; final marker `CLEANUP_ROUTER_OK` /
`CLEANUP_ROUTER_FAILED: <n> case(s)`) with `prewarmTraceFailures()`:
- **a.** A `FoundationModelFormatter` with `modelCall = CleanupModelCall(takeSession: { _ in false },
  respond: { _ in try await Task.sleep(for: .seconds(30)); return "" })` and the text
  "okay so this is a short test", calling `format` directly. To keep the suite fast, pin the
  budget with a test-only `var timeoutOverride: Duration? = nil` on the formatter (300 ms here);
  D-07 later replaces `timeoutOverride` with `timeScale` and updates this case. Assert
  `trace.snapshot.sessionPrewarmed == false` (not nil) and that `trace.snapshot.fallbackReason`
  contains "timed out".
- **b.** Same with `takeSession: { _ in true }` and a `respond` that throws → `sessionPrewarmed == true`.
- **c.** `respond` returns the input unchanged → `sessionPrewarmed == false`, verdict accepted.
- Failure lines: `  prewarm: <case> recorded <value>`.

Confirm RED: with the seam added but step 2 not applied (the old `:127` line still in place), case
a and b record `nil` → `CLEANUP_ROUTER_FAILED`.

**Verify:**
```bash
make build && make install OPEN=0
Scripts/run-selftest.sh --selftest-cleanup-router 2>&1 | tee ~/Library/Caches/NextNotesBuild/dictation-meetings/D-01a-green.txt | tail -5
Scripts/run-selftest.sh --selftest-cleanup-structure
Scripts/run-selftest.sh --selftest-cleanup guard      # guard vectors only; no model
```

**Success threshold:** `CLEANUP_ROUTER_OK` with cases a–c (red first). After the owner's next
timed-out dictation, `python3 Scripts/dictation-stats.py --since <commit date>` shows no `None` in
`sessionPrewarmed_on_timeouts`.

**Risks & rollback:** The only behavioural change is when a trace field is written. Revert the
commit to roll back.

**Done when:**
- [ ] `sessionPrewarmed` written before `respond`; `grep -n "noteSessionPrewarmed" Sources/NextNotes/Formatting/FoundationModelFormatter.swift` shows no call after the task group.
- [ ] `structurePlanPrewarmed` recorded, including on timeouts.
- [ ] `--selftest-cleanup-router` green with cases a–c (red first).
- [ ] `STATUS.md` updated; committed as `D-01a: record the cleanup prewarm state before the call`.

---

### D-01b — One `dictation.hold` usage row per hold, `dictation.press_refused`, dropped buffers
**Finding(s):** I1-05 (proposal 3), I1-12, I1-16  **Effort:** 1 day  **Depends on:** AGENT-OVERHAUL P0-20a (the `UsageLog` writer). Soft: P0-20c (if it has landed, share its correlation id and extend its rows instead of duplicating). **Unblocks:** D-02, D-03, D-05 (their outcome assertions), D-12, D-13 and D-14 (evidence gates), T1/T4/T5 measurement; AGENT-OVERHAUL P2-08 reads the dropped-buffer counts.

**Why (what the user experiences today):** `runs.jsonl` files only holds that typed something
(`recordRun` @ `Core/DictationController.swift:1303`, called just before injection at `:1099`).
On 09-23, three real holds left only metric spans: 03:06:49Z (4.40 s key-down → capture after a
52 s model load; the user spoke ~6 s; nothing filed), 22:03:10Z (1.5 s hold, empty transcript,
nothing filed; the user held again two seconds later), 22:07:03Z (a 0.18 s tap that showed a raw
FluidAudio error). A press during the 5–12 s tail is dropped with no trace at all (I1-12), and
buffers dropped by the controller's own stream are invisible (I1-16). None of this is countable,
so no later task could prove it fixed anything.

**Files you will change:**
- `Core/DictationController.swift` (new `outcome:` init seam, `holdID`, `reportOutcome`, press-refused reporting, drop counters)
- new `Core/DictationHoldOutcome.swift` (`DictationHoldOutcome`, mapping to `UsageRecord`)
- the P0-20a usage file that declares `feature` values (`Support/Usage/UsageLog.swift` or wherever P0-20a put the enum/constants): add `dictation.hold`, `dictation.press_refused`
- `NextNotesApp.swift` (`runDictationSelfTest` @ :2807: new cases; `SelfTestEngine` @ :5989: new shapes)

**Read for context (do not change):** AGENT-OVERHAUL `01-PHASE-0-MAKE-IT-ANSWER.md` P0-20 (as it
stands when you start; the names below follow the plan announced for P0-20a–e); `AudioCaptureHub.subscribe(_:outputFormat:onBuffer:onLevel:onOverflow:)`
(`Core/AudioCaptureHub.swift:194-230`); `AudioCaptureDeliveryWorker.maxPending` (`:387`);
`DictationController.fail` (`:1334-1383`), `finishIdle` (`:1134`), `cancelDictation` (`:1190`),
`runComparison` (`:1225`), `applyCommand`.

**Current behaviour:**
- One `State` machine (`DictationController.State` @ `:107-122`). Exits: `finishIdle()` after an
  insert (`:1115`, `:1122`), after an empty transcript that "finished" (`:1010`), after Command Mode
  (`:1176`); `fail(message)` for a missing permission, a start failure or start timeout
  (`:750-770`), a subscribe failure, an engine stream error (`:884`, `:889`), no audio (`:1004`), a
  transcribe timeout, a release in `.starting` (`:914-918`) and `couldNotReturn` (`:1128`);
  `cancelDictation()` for a Command Mode chord.
- `beginDictation` returns silently when the state is not `.idle` (`guard case .idle = state else { return }` @ `:622`);
  so do `startButtonRecording` (`:526`) and `beginCommandMode` (`:575`).
- The feed stream drops silently: `AsyncStream<AudioChunk>.makeStream(bufferingPolicy: .bufferingNewest(64))` (`:811-813`);
  `audioContinuation.yield(chunk)` (`:840`) ignores its `YieldResult`. The hub's worker drops at
  `maxPending = 8` and logs "capture delivery backlog full — dropped audio buffer" (default
  `onOverflow` @ `AudioCaptureHub.swift:206-208`), per process, not per hold.

**Target behaviour:**
1. Every hold writes **exactly one** `UsageRecord` with `feature = "dictation.hold"`, whatever
   happened, with:
   - the correlation id = a per-hold `holdID: UUID` created in `beginDictation` (if P0-20c has
     landed, the same id is on its `dictation.asr` / `dictation.cleanup` rows for this hold);
   - `errorClass`: `nil` for text typed or copied, else one of `empty` (no speech and no words),
     `emptySpeech` (speech energy but no words; filled by D-03, until then `empty`), `tap`
     (released < 0.3 s after key-down, or fewer than 4,800 samples captured), `lostAtStartup`
     (released in `.starting`), `cancelled`, `failed:<cause>` with cause ∈ `micPermission`,
     `startup`, `startupTimeout`, `subscribe`, `noAudio`, `engine`, `transcribeTimeout`,
     `couldNotReturn`; and `command` / `compare` for those modes' normal ends;
   - `totalMs`: key-up → outcome (nil for `lostAtStartup` and `cancelled`);
   - `counts`: `holdMs`, `keyDownToCaptureMs` (absent if capture never started), `words`,
     `capturedFrames`, `droppedHubBuffers`, `droppedStreamBuffers`, `cleanupTimedOut` (0/1),
     `sessionPrewarmed` (1/0, absent when no model ran).
   - No transcript text, no app name, no clipboard content.
2. Every refused press writes one `UsageRecord` with `feature = "dictation.press_refused"` and
   `errorClass` = the state it hit (`starting` | `listening` | `finishing` | `error`) and
   `counts["sinceKeyUpMs"]` when the state is `.finishing`.
3. Dropped buffers are counted per hold: the hub's `onOverflow` for the `.dictation` subscription,
   and every `YieldResult.dropped` from the feed stream.
4. Self-tests write through the injected sink (or into `UsageLog.shared`, which is a temp directory
   under the harness); never into the user's `usage.jsonl`.

**Steps:**
1. `Core/DictationHoldOutcome.swift`:
   ```swift
   enum DictationHoldResult: Equatable, Sendable {
       case inserted, copied, command, compare, cancelled, empty, emptySpeech, tap, lostAtStartup
       case failed(Cause)
       enum Cause: String, Sendable { case micPermission, startup, startupTimeout, subscribe, noAudio,
                                             engine, transcribeTimeout, couldNotReturn }
       var errorClass: String? { … }   // nil for .inserted / .copied; "failed:<cause>" etc.
   }
   struct DictationHoldOutcome: Sendable, Equatable {
       var holdID: UUID
       var result: DictationHoldResult
       var keyUpToOutcome: Duration?
       var counts: [String: Int]
   }
   extension DictationHoldOutcome {
       /// The one mapping onto P0-20a's row. Field names follow P0-20a; adapt here only.
       func usageRecord(startedAt: Date) -> UsageRecord
   }
   ```
2. Controller seam: add `outcome: @escaping @MainActor (DictationHoldOutcome) -> Void = { UsageLog.shared.append($0.usageRecord(startedAt: …)) }`
   to `init` next to `record:` (`:447`). Use whatever append API P0-20a exposes.
3. State for one hold: `private var holdID = UUID()`, `private var outcomeReported = true`,
   `private var droppedHub = 0`, `private var droppedStream = 0` (the hub callback is off the main
   actor: count into a lock-protected box like `DictationAudioCounter` @ `:49-65`, extend that class
   with `hubDrops` and `streamDrops`).
   In `beginDictation` after the idle guard: `holdID = UUID(); outcomeReported = false`.
4. `private func reportOutcome(_ result: DictationHoldResult)`: `guard !outcomeReported`, set it,
   build counts from `holdStarted`, `releasedAt`, the counter, the key-down→capture duration (store
   it when `keyDownToCaptureTrace?.end()` runs at `:867`), `transcript` word count, and the cleanup
   record if any; call `outcome(…)`. Call it:
   - `fail(_:)` gains a parameter: `fail(_ message: String, result: DictationHoldResult)`. Update
     every call site with the explicit cause from the list above — never derive the cause by
     parsing the message. `reportOutcome` runs **before** `session &+= 1`.
   - `finishIdle()` gains `result:`; the three call sites pass `.inserted` / `.copied` / `.empty`
     (or `.tap` when `holdMs < 300` or `capturedFrames < 4_800`) / `.command`.
   - `cancelDictation()` → `.cancelled`; `runComparison` end → `.compare`.
5. Refused presses: at the top of `beginDictation`, `startButtonRecording` and `beginCommandMode`,
   replace the bare `guard case .idle = state else { return }` with a guard that calls
   `reportRefusedPress(state)` before returning. (D-05 later lets `.error` through; keep the
   reporting for the states that remain refused.)
6. Drops: pass `onOverflow: { n in counter?.addHubDrops(n) }` to the `.dictation` subscribe
   (`:835`), and replace `audioContinuation.yield(chunk)` with
   `if case .dropped = audioContinuation.yield(chunk) { counter?.addStreamDrop() }`.
7. If P0-20c has landed and records `dictation.asr` / `dictation.cleanup` rows, pass `holdID` into
   its correlation field (read P0-20c to find where its recorder is created in the tail). If P0-20c
   has not landed, leave a one-line comment at the tail naming `holdID` as the id P0-20c must use,
   and add that to P0-20c's row in AGENT-OVERHAUL `STATUS.md` → *Decisions and deviations*.
8. Self-test engine shapes (next to `SelfTestEngine` @ `NextNotesApp.swift:5989`):
   `.failsStart(String)` (start throws), `.emptyTranscript` (finish yields `""` and closes).

**Do not:**
- Write transcript text, app names or clipboard content into the usage row.
- Call `RunLog.record` or the real `UsageLog` file from a self-test (AGENTS.md "A self-test must
  never call `RunLog.record`"); the test passes its own `outcome:` sink.
- Add a second report on any path; `outcomeReported` makes the call idempotent, and the self-test
  asserts exactly one row per hold.
- Touch `DictationController.Limits` or any `withBoundedWait` (kept limits).
- Invent a parallel log file. If P0-20a has not landed, this task is `blocked` on it.

**Red-first self-test:** extend `--selftest-dictation` (`runDictationSelfTest` @
`NextNotesApp.swift:2807`; final marker `DICTATION_OK: every hold came back to idle` /
`DICTATION_FAILED: <n> problem(s)`; runs via `--via-open` because it opens the real microphone).
`makeController` passes `outcome: { sink.append($0) }` where `sink` is a new `@MainActor final class
SelfTestOutcomeSink` next to `SelfTestInbox` (:5977). New assertions, one line each as
`  DICTATION_WRONG: …`:
- **a.** Case 1 (ordinary hold) → exactly one outcome, `result == .inserted`, `counts["holdMs"] ≥ 500`,
  `keyUpToOutcome != nil`.
- **b.** Case 2 (`.hangsOnFinish`) → exactly one outcome, `.failed(.transcribeTimeout)`.
- **c.** Case 4 (released during start-up) → `.lostAtStartup` (D-02 later changes this case).
- **d.** New case: `.emptyTranscript`, held 600 ms → exactly one outcome, `.empty`.
- **e.** New case: `.failsStart("boom")` → `.failed(.startup)`; the state still returns to idle.
- **f.** New case: a press while `.finishing` (use `.prompt(delay: .zero)` with a formatter that
  sleeps 1 s: add `SlowSelfTestFormatter`) → one extra `press_refused` report with state
  `finishing`, and the first hold still ends with exactly one `.inserted`.
- **g.** Across the whole run, `sink.count == number of holds started` (no path reports twice or
  never).
The `UsageRecord` mapping itself is asserted in `--selftest-usage-log` (P0-20e's flag): add one
case that maps a `DictationHoldOutcome` with every count set and checks the field names and that no
string field contains the fixture transcript. If P0-20e does not exist yet, put that case in
`--selftest-dictation` instead and move it later.

Confirm RED: with the seam in place and `reportOutcome` a no-op, a–g fail with "0 outcome(s)".

**Verify:**
```bash
make build && make install OPEN=0
Scripts/run-selftest.sh --via-open --selftest-dictation 2>&1 | tee ~/Library/Caches/NextNotesBuild/dictation-meetings/D-01b-green.txt | tail -12
Scripts/run-selftest.sh --selftest-usage-log          # P0-20e; skip with a note if it does not exist yet
Scripts/run-selftest.sh --selftest-commandkey         # drives the controller through Command Mode
Scripts/run-selftest.sh --selftest-metrics
```
Owner smoke (after install, by the owner or at the next real use): hold the key, say a sentence,
release; then `python3 Scripts/dictation-stats.py --since <today>` shows a `holds` section with
`outcomes: {'inserted': 1}`.

**Success threshold:** `DICTATION_OK` with a–g (red first); `--selftest-commandkey` unchanged
from baseline; the owner smoke row exists.

**Risks & rollback:** A missed call site means a hold with no row; case g catches it. A doubled
call is prevented by `outcomeReported`. Roll back by reverting; `usage.jsonl` rows already written
are harmless.

**Done when:**
- [ ] `grep -n "fail(\"" Sources/NextNotes/Core/DictationController.swift` shows every call with a `result:`.
- [ ] Refused presses and both kinds of drops are counted.
- [ ] `--selftest-dictation` green with a–g (red first); mapping case green.
- [ ] Owner smoke row pasted into `STATUS.md`.
- [ ] Committed as `D-01b: file one usage row per dictation hold`.

---

## Phase B — nothing lost

### D-04 — Parakeet short-audio padding to 300 ms; plain-language errors only
**Finding(s):** I1-06  **Effort:** 3 h  **Depends on:** none  **Unblocks:** T6

**Why (what the user experiences today):** On 09-23 22:07:03Z a 0.18 s tap put
`Invalid audio data provided. Must be at least 300ms of 16kHz audio.` on the island, via
`Parakeet failed: …` in the log. A clipped "yes" (0.1–0.3 s) is real speech, and a developer
string is never an acceptable message.

**Files you will change:** new `Transcription/ParakeetInput.swift` (the shared minimum-input
helper; `02-MEETINGS.md` §1.6 names D-04 its owner, and M-01/M-07 call it from the meeting path);
`Transcription/ParakeetEngine.swift` (`finish`, `maybeEmitPartial`); `Core/DictationController.swift` (the two
`fail(error.localizedDescription)` sites in the start Task, `:884` and `:889`, and the start
`.failed(error.localizedDescription)` at `:742`); new `Core/DictationErrorText.swift`;
`NextNotesApp.swift` (`runDictationSelfTest`, `SelfTestEngine`, and the `--selftest-parakeet`
block near `:1636`).

**Read for context (do not change):** FluidAudio's minimum (`ASRConstants.minimumAudioDurationSeconds = 0.3` in the checkout, and the error string above); `ParakeetEngine.runPartial` (`:300-320`), which already catches and logs; `ChunkedTranscriber.minTranscribableSamples` (meetings; M-01/M-07 own that file and switch it to the helper, not this task).

**Current behaviour:** `ParakeetEngine.finish` (`ParakeetEngine.swift:158-252`):
```swift
        guard samples.count >= 1_600 else {                          // :203 — 0.1 s
            Log.speech.info("Parakeet: skipped — only \(self.samples.count) samples captured")
            …
```
Between 1,600 and 4,800 samples, `manager.transcribe(samples, …)` throws, the stream finishes
with that error, and the controller's `consumeTask` catch calls `self.fail(error.localizedDescription)`
(`DictationController.swift:884`). The partial path has the same 1,600 threshold (`:266`).

**Target behaviour:**
1. `1_600 ≤ samples < 4_800` → zero-padded to 4,800 and transcribed; an empty result goes idle
   quietly (outcome `tap`).
2. Below 1,600 → skipped, as today.
3. No error text reaching `DictationController.fail` or the island is a raw `localizedDescription`
   from an engine, FluidAudio, AVFoundation or CoreML. Every such error is mapped to one of a small
   set of plain sentences; the raw text goes to the log only.

**Steps:**
1. `Transcription/ParakeetInput.swift`:
   ```swift
   enum ParakeetInput {
       /// Below this there is nothing worth transcribing (0.1 s at 16 kHz). Unchanged value.
       static let minimumCapturedSamples = 1_600
       /// FluidAudio refuses anything shorter (0.3 s at 16 kHz, `ASRConstants.minimumAudioDurationSeconds`).
       static let minimumModelSamples = 4_800
       /// Zero-padded up to `minimumModelSamples`; unchanged when already long enough.
       /// Callers check `minimumCapturedSamples` themselves (the name and signature are the ones
       /// `02-MEETINGS.md` §1.6 expects).
       static func padded(_ samples: [Float]) -> [Float]
   }
   ```
2. In `ParakeetEngine`: replace both literal `1_600`s (`:203`, `:266`) with
   `ParakeetInput.minimumCapturedSamples` in `finish` and `ParakeetInput.minimumModelSamples` in
   the partial path (a partial below 0.3 s is pointless and would throw). In `finish`, transcribe
   `ParakeetInput.padded(samples)`. The `reusable` partial check (`lastCompletedPartialAt >= 1_600`)
   uses `minimumModelSamples`.
3. `enum DictationErrorText { static func plain(_ error: Error) -> String }`: `CancellationError` →
   "That recording was stopped."; anything else → "Speech recognition didn't work that time. Try
   again." Log the raw `error.localizedDescription` with `Log.speech.error` in the same place. Use
   it at the three controller call sites listed above (with D-01b's `result: .failed(.engine)` /
   `.failed(.startup)`).
4. `SelfTestEngine.Shape.throwsOnFinish(String)`: `finish()` finishes the stream by throwing an
   `NSError` whose `localizedDescription` is the given string.

**Do not:** lower FluidAudio's floor by any other means; pad partials; change the partial cadence
(kept limit); put the raw string in any `.error(...)` state.

**Red-first self-test:**
- `--selftest-dictation`: new case `.throwsOnFinish("Invalid audio data provided. Must be at least 300ms of 16kHz audio.")`,
  held 400 ms → the controller's `.error` message (read it while it is shown) contains neither
  "Invalid audio", "16kHz" nor "ms of"; `DICTATION_WRONG: engine error shown raw: <message>` otherwise.
  Pure checks in the same run: `ParakeetInput.padded` of 3,200 samples → 4,800 samples with the
  last 1,600 zero; of 6,000 → unchanged; of 0 → 4,800 zeros (callers gate on
  `minimumCapturedSamples`, asserted separately against `ParakeetEngine`'s use).
- `--selftest-parakeet` (marker `PARAKEET_OK: …` / `PARAKEET_FAILED: …`): after its existing
  inference, feed a `ParakeetEngine` 3,200 samples (0.2 s) of the fixture WAV's first 0.2 s
  (`say -v Samantha -o "$F/yes.aiff" "yes"; afconvert -f WAVE -d LEI16@16000 "$F/yes.aiff" "$F/yes16k.wav"`,
  read with `AVAudioFile`), call `start`, `feed`, `finish`; the stream must end **without
  throwing**. Print `PARAKEET_SHORT: <text or empty>`. Needs the Parakeet model on disk; if absent
  the flag already reports its own failure — do not convert that into OK.
Confirm RED: before the fix, the dictation case shows the raw string, and the short-audio
`finish` throws.

**Verify:**
```bash
make build && make install OPEN=0
Scripts/run-selftest.sh --via-open --selftest-dictation | tail -8
F=~/Library/Caches/NextNotesBuild/dictation-meetings/fixtures
say -v Samantha -o "$F/yes.aiff" "yes"; afconvert -f WAVE -d LEI16@16000 "$F/yes.aiff" "$F/yes16k.wav"
Scripts/run-selftest.sh --selftest-parakeet | tail -3
Scripts/run-selftest.sh --selftest-transcribe "$F/en16k.wav" | tail -3     # regression: normal audio unchanged
Scripts/run-selftest.sh --selftest-ui-strings
```

**Success threshold:** both flags green (red first); `PARAKEET_SHORT` printed without a throw.
Owner-use: T6 = 0 raw strings (grep the island's dictation errors: `/usr/bin/log show --last 1d --predicate 'subsystem == "ai.pivotstudio.nextnotes" AND category == "app"' | grep -c "16kHz"` → 0).

**Risks & rollback:** Padding silence could make Parakeet hallucinate a word on a pure-noise tap;
the empty/short result is then typed. Mitigation: if the padded result has more than 2 words from
fewer than 3,200 real samples, treat it as empty. Revert to roll back.

**Done when:**
- [ ] No literal `1_600` left in `ParakeetEngine.swift`; `ParakeetInput` is the one place the two thresholds live (M-01/M-07 reuse it).
- [ ] Engine errors reach the user only through `DictationErrorText.plain`.
- [ ] Both flags green (red first); `STATUS.md` updated; committed as `D-04: pad short Parakeet audio and never show raw engine errors`.

---

### D-05 — A press during `.error` starts a new hold
**Finding(s):** I1-07  **Effort:** 2 h  **Depends on:** none (soft: D-01b, so refused presses in `.error` disappear from the rows)  **Unblocks:** T8

**Why (what the user experiences today):** `fail` shows its message for 3 s and every press in
those 3 s does nothing: no HUD, no sound, no log. The two failures most likely to be retried at
once are exactly the ones that say to retry: "Next Notes was still starting up, so that recording
was lost. Hold the key again." and "Couldn't switch back to … ".

**Files you will change:** `Core/DictationController.swift` (`beginDictation` guard :622,
`startButtonRecording` :526, `beginCommandMode` :575, the clear task in `fail` :1379-1382);
`NextNotesApp.swift` (`runDictationSelfTest`).

**Read for context (do not change):** `State.isActive` / `shouldShowHUD` (`:114-122`);
`IslandState.card(for:transcript:level:)` (`UI/Island/IslandState.swift:491-494`); `HUDView` (:72, :84).

**Current behaviour:**
```swift
    private func beginDictation(intent: RecordingIntent) {
        guard case .idle = state else { return }                   // :622
…
        Task { @MainActor in                                        // in fail(), :1379
            try? await Task.sleep(for: .seconds(3))
            if case .error = state { state = .idle }
        }
```

**Target behaviour:** a press (push-to-talk, the Record button, or Command Mode) while the state
is `.error` clears the message and starts a new hold immediately. The 3 s clear task cannot clear
the new hold (it only clears `.error`, and a stale timer must not clear a *newer* error either).
Presses in `.starting`, `.listening` and `.finishing` are still refused (and reported by D-01b).

**Steps:**
1. `private var canStartHold: Bool { if case .idle = state { return true }; if case .error = state { return true }; return false }`.
   Use it in the three guards.
2. In `fail`, capture an `errorToken` (increment a counter) and clear only if the state is still
   `.error` **and** the token matches, so a new failure within 3 s keeps its own 3 s.
3. When a hold starts from `.error`, nothing else needs resetting: `fail` already cleared the
   slots. Assert that in the test rather than assuming it.

**Do not:** start a hold from `.finishing` (that is D-13, evidence-gated); shorten the 3 s display;
change `State.isActive` (menu indicators and the island rely on `.error` not being active).

**Red-first self-test:** `--selftest-dictation` new case: a controller with `.failsStart("boom")`
fails; 500 ms later `startButtonRecording()` on a controller whose next engine is
`.prompt(delay: .zero)` (let `makeEngine` read from a mutable box so the second hold gets the good
engine) → within 1 s the state is `.listening`, and after release the inbox holds the transcript.
A second sub-case: two failures 1 s apart → the second message is still shown 2.5 s after it was
raised (token check).
Confirm RED: today the press is ignored and the state stays `.error` then `.idle`.

**Verify:**
```bash
make build && make install OPEN=0
Scripts/run-selftest.sh --via-open --selftest-dictation | tail -8
Scripts/run-selftest.sh --selftest-commandkey
Scripts/run-selftest.sh --selftest-island
```

**Success threshold:** `DICTATION_OK` with both sub-cases (red first); `--selftest-commandkey` and
`--selftest-island` unchanged.

**Risks & rollback:** A user holding the key through an error card might start a hold they did not
intend: acceptable, it is what they pressed. Revert to roll back.

**Done when:**
- [ ] The three guards use `canStartHold`; the clear task is token-checked.
- [ ] `--selftest-dictation` green with the new cases (red first).
- [ ] Committed as `D-05: a press during the error card starts a new dictation`.

---

### D-10 — Learner safety: per-token alignment, auto-add only single-token or case-only, idempotent add, diff against the last edit, offer to review the bad rule
**Finding(s):** I1-08  **Effort:** 1 day  **Depends on:** none  **Unblocks:** T9

**Why (what the user experiences today):** `dictionary.txt` holds `of a product -> for ProductFlo`
(line 15), learned from the 09-18 13:07Z edit "a nice jump plugin of a product" → "an Altium
plugin for ProductFlo". Its whole-span similarity is 0.57, above the 0.45 threshold, so from now
on every "of a product" in any app is typed as "for ProductFlo". By the same arithmetic
`of the -> for the` (0.71) would be learned. The file also carries 5 duplicate rules
(`OLAMA -> Ollama` ×3, `Quentin 2.5 -> Qwen3.5` ×2, `quen 2.54b -> Qwen 3.5 4b` ×2,
`chatgpd cloud -> ChatGPT Claude` ×2; stats script `duplicate_rules: 5`), because
`DictionaryStore.add` appends without checking and a re-saved edit re-learns the same rules.

**Files you will change:**
- `Dictionary/CorrectionLearner.swift` (`candidates`, new `isAutoAddable`, new `newCandidates(original:previousEdit:edited:)`, new `wouldLearn(hear:write:)`)
- `Dictionary/DictionaryStore.swift` (`add` becomes idempotent; new pure `static func isDuplicate(_:in:)`; new `static func suspiciousRules(in:)`)
- `UI/Dictation/TranscriptionRow.swift` (`TranscriptCorrection.save` @ :116-138)
- `UI/Dictionary/DictionaryPanel.swift` (a review notice for suspicious and duplicate rules)
- `NextNotesApp.swift` (`runLearnSelfTest`, the `cases` table near :1700-1760)

**Read for context (do not change):** `DictionaryEntry` (`Sources/NextNotesDictionary/DictionaryEntry.swift`:
`id` is a fresh `UUID` per entry, :17/:31); `DictionaryCorrector` (how a rule applies — not
changed here); `shared/dictionary-test-vectors.json`; AGENTS.md "The dictionary learns from
history, not from the app the text went to" (unchanged by this task).

**Current behaviour:** `CorrectionLearner.candidates(from:to:)` (`CorrectionLearner.swift:55-80`)
takes each LCS replacement block of 1–3 words a side and accepts it when
`similarity(hear.lowercased(), write.lowercased()) >= minimumSimilarity` (0.45, `:42`), refusing
only a *single* word in `tooCommon` (`:71`). `TranscriptCorrection.save` diffs `run.text` (the
original) against the new edit and, in `.automatic` mode, calls `DictionaryStore.shared.add` for
every candidate (`TranscriptionRow.swift:132-134`). `DictionaryStore.add` (`DictionaryStore.swift:49-52`)
is `entries.append(entry); save()`.

**Target behaviour:**
1. A multi-word block is accepted only if, aligned token by token, **every changed token pair**
   is either a case-only change or has similarity ≥ 0.5 on its own, **and** at least one changed
   token (either side) is outside `tooCommon`. When the two sides have different lengths, a common
   word may not be substituted or dropped: every `tooCommon` token on one side must also appear on
   the other. `of a product → for ProductFlo` and `of the → for the` are refused;
   `cloud code → Claude Code`, `quen 2.54b → Qwen 3.5 4b`, `OLAMA → Ollama`, and all existing
   `--selftest-learn` cases keep their current answers.
2. In `.automatic` mode only single-token changes and multi-token case-only changes are added
   without asking. Every other accepted candidate goes to the existing "Learn this correction?"
   sheet (`LearnedCorrectionsSheet`), even in automatic mode.
3. `DictionaryStore.add` does nothing when a correction with the same (hear, write), compared
   case-insensitively after trimming, already exists — enabled or disabled (a rule the user
   switched off must not come back).
4. Re-saving an edited run learns only what is new: the candidates of (original → new edit) minus
   the candidates of (original → previous edit). The diff base stays the original transcript,
   because that is what a rule has to fire on (the comment at `TranscriptionRow.swift:124-125`).
5. The Dictionary screen offers, once and never silently, to remove rules the new learner would
   refuse (`wouldLearn == false`) and duplicate rules. The user decides per rule; nothing is
   deleted automatically. The file is the user's.

**Steps:**
1. `CorrectionLearner`: split the acceptance test into
   `static func accepts(removed: [String], added: [String]) -> Bool` implementing Target 1:
   - equal lengths: pair positionally; for each pair with `a != b`: ok if `a.lowercased() == b.lowercased()`
     or `similarity(a.lowercased(), b.lowercased()) >= 0.5`; require at least one changed pair
     whose tokens are not both in `tooCommon`;
   - unequal lengths: require `Set(removed ∩ tooCommon) == Set(added ∩ tooCommon)` (lowercased),
     at least one non-common token on each side, and today's whole-span
     `similarity >= minimumSimilarity`.
   `candidates` calls it in place of the whole-span check. Keep `maxCandidates`, the 1–3 span
   limit and the single-common-word rule.
2. `static func isAutoAddable(_ c: LearnedCorrection) -> Bool`: one token each side, or
   `c.hear.lowercased() == c.write.lowercased()`.
3. `static func newCandidates(original: String, previousEdit: String?, edited: String) -> [LearnedCorrection]`:
   `candidates(original, edited)` minus (by `id`) `candidates(original, previousEdit)` when
   `previousEdit` is non-nil.
4. `static func wouldLearn(hear: String, write: String) -> Bool`: tokenise both and run `accepts`.
5. `DictionaryStore`: `static func isDuplicate(_ entry: DictionaryEntry, in entries: [DictionaryEntry]) -> Bool`
   (same `kind`, and for corrections the same trimmed lowercased `hear` and `write`; for terms the
   same `write`). `add` returns early when it is true. `static func suspiciousRules(in:) -> [DictionaryEntry]`:
   corrections for which `wouldLearn` is false, plus every duplicate after the first.
6. `TranscriptCorrection.save`: use `newCandidates(original: run.text, previousEdit: run.editedText, edited: edited)`;
   in `.automatic`, add the auto-addable ones and **return** the rest (so `DictationView.save`,
   `UI/Dictation/DictationView.swift:221-232`, shows the sheet for them); `.ask` returns all; `.off`
   returns none.
7. `DictionaryPanel`: when `suspiciousRules` is non-empty and the user has not dismissed it
   (`Settings` key `dictionaryReviewDismissedFingerprint` = a hash of the listed rules, so a new
   suspicious rule shows the notice again), show a notice above the list: title "Some rules may
   change words you didn't mean to change", one row per rule with "Keep" and "Remove", and
   "Remove duplicates" when there are duplicates. Strings plain; no "regex", "token", "rule id".
   Only `DS` tokens.

**Do not:**
- Change `DictionaryCorrector` or how an existing rule applies. This task changes what is
  **learned**. If you find you need to change how corrections apply, stop: that starts with
  `shared/dictionary-test-vectors.json`, its copy in `Tests/NextNotesDictionaryTests/`, and both
  `make test` and `cd windows && dotnet test NextNotes.CrossPlatform.slnf` (AGENTS.md "The one rule
  that matters"). There is no learner on Windows (`grep -ri CorrectionLearner windows/` finds
  nothing), so there is no parity to keep for this task.
- Delete or rewrite any line of the user's `dictionary.txt` without a click.
- Write to `DictionaryStore.shared` from a self-test (it is the user's file): test the pure
  functions.
- Raise `maxCandidates` (kept limit I1-29).

**Red-first self-test:** extend `--selftest-learn` (`runLearnSelfTest`; final marker
`LEARN_OK: <n> case(s), corrections learned and rejections held` / `LEARN_FAILED: <n> of <m>`):
- must-refuse (`expect: nil`): `of-a-product` — before "a nice jump plugin of a product", after
  "an Altium plugin for ProductFlo"; `of-the` — before "send the file of the day", after "send the
  file for the day";
- must-learn (unchanged answers): `cloud code → Claude Code`, `quen 2.54b → Qwen 3.5 4b`, and every
  existing case in the table;
- auto-add split: `isAutoAddable` true for `OLAMA → Ollama` and `claude code → Claude Code`, false
  for `quen 2.54b → Qwen 3.5 4b`;
- re-edit: `newCandidates(original: "we use olama here", previousEdit: "we use Ollama here", edited: "we use Ollama here today")`
  is empty;
- duplicates: `isDuplicate(.correction(hear: "OLAMA", write: "Ollama"), in: [.correction(hear: "olama ", write: "ollama")])`
  is true; a disabled existing entry also counts;
- `suspiciousRules` over a fixture list containing `of a product -> for ProductFlo` and two
  `OLAMA -> Ollama` returns exactly those two extra entries.
Confirm RED: the two must-refuse cases learn a rule today, and the new functions (added as seams
returning today's behaviour) fail their cases.

**Verify:**
```bash
make build && make install OPEN=0
Scripts/run-selftest.sh --selftest-learn 2>&1 | tee ~/Library/Caches/NextNotesBuild/dictation-meetings/D-10-green.txt | tail -5
make test                                            # correction vectors unchanged, still green
Scripts/run-selftest.sh --selftest-ui-strings
Scripts/run-selftest.sh --selftest-settings
```

**Success threshold:** `LEARN_OK` with every new case (red first); `make test` unchanged;
`UI_STRINGS_OK`. Owner-use: after a week, the stats script's `duplicate_rules` is not above the
number left by the owner's review choices.

**Risks & rollback:** Some real multi-word proper-noun fixes will now ask instead of being added
silently: intended. A too-strict alignment could stop learning a real correction; the must-learn
cases pin the known ones. Revert to roll back; the notice writes nothing unless clicked.

**Done when:**
- [ ] The two bad pairs are refused; the known good ones still learn.
- [ ] Automatic mode adds only single-token or case-only changes; the rest reach the sheet.
- [ ] `add` is idempotent by (hear, write); re-saves learn only what is new.
- [ ] The review notice exists and deletes only on a click.
- [ ] `--selftest-learn` green (red first); `make test` green. Committed as `D-10: learn only corrections that are safe to apply everywhere`.

---

### D-02 — Key-down pre-roll: capture from key-down, replay after start, transcribe instead of failing on a release in `.starting`
**Finding(s):** I1-04  **Effort:** 1.5 days  **Depends on:** D-04, D-05 (same file, smaller first); soft D-01b (outcome assertions)  **Unblocks:** D-03 (shares the kept audio), D-13, T4, T5

**Why (what the user experiences today):** The microphone opens only after `engine.start()` has
returned. At 09-23 03:06:49Z, after a 52.3 s model load under memory pressure, key-down → capture
took **4.40 s**; the user spoke for about 6 s, the first partial never arrived, and nothing was
filed. A release during start-up fails with "Next Notes was still starting up, so that recording
was lost. Hold the key again." Parakeet is "~11 s cold" (`DictationController.swift:302`) and
"~20 s from disk" (`NextNotesApp.swift:275`). The `ParakeetEngine.start()` comment assumes "the
user waits before speaking" (`ParakeetEngine.swift:99-100`); nothing on screen tells them to.

**This task changes behaviour AGENTS.md documents as deliberate.** The paragraph, verbatim:

> **`DictationController.session` is not a counter, it is what keeps two holds apart.**
> `engine`, `consumeTask`, `feedTask` and `audioContinuation` are one slot each, and starting
> a recording is slow — Parakeet is eleven seconds cold. Release the key during that and hold
> again, and two start-up tasks are in flight against one set of slots. Unguarded, the late
> one writes its engine over the live one's, and `endDictation` then finishes engine B while
> awaiting engine A's stream — a stream nobody will ever close. Every continuation that writes
> back into those slots re-checks `session` first, and a superseded start-up finishes its own
> engine and touches nothing else. It is also why capture is started *after* that check rather
> than before it.

What overrides the last sentence: the measured 4.40 s capture delay and the lost hold above, and
the fact that its reason — "a superseded start-up opens the microphone on behalf of a recording
nobody asked for" — does not apply to a capture opened **by the current session at key-down**,
while the key is actually held. The session guard itself stays: a superseded start-up still
touches nothing, and additionally it never touches the hub (only the session that owns the slots
unsubscribes). Update the paragraph's last sentence in the same commit (Done-when).

**Files you will change:**
- `Core/DictationController.swift` (`beginDictation` @ :621-892, `endDictation` @ :900-1131, `fail`, `cancelDictation`; new `PreRoll` bookkeeping)
- `UI/Island/IslandState.swift` (`card(for:…)` @ :491: "capturing" while the pre-roll runs) and `UI/HUDView.swift` if it reads `state == .listening` for the capture indicator
- `NextNotesApp.swift` (`runDictationSelfTest` @ :2807, `SelfTestEngine` @ :5989)
- `AGENTS.md` (the paragraph above)

**Read for context (do not change):** `AudioCaptureHub.subscribe` (a second subscribe of the same
consumer replaces the slot: `slots[consumer]?.worker.stop()` @ `Core/AudioCaptureHub.swift:217`);
`TranscriptionEngine` (`Transcription/TranscriptionEngine.swift:32-44`);
`ParakeetEngine.preferredInputFormat` (:58-60, static: 16 kHz mono Float32, callable before
`start`); `AppleSpeechEngine.preferredInputFormat` (:28-31, needs only the module, not a started
analyzer) and `AppleSpeechEngine.start` (contextual strings must be set before the first buffer
— replay after `start` satisfies that).

**Current behaviour (the start Task in `beginDictation`, :725-891):** permission →
`makeEngine()` → `withBoundedWait(limits.startup) { try await engine.start() }` (:740-743) →
session guard (:748) → Apple lane → `formatOwner.preferredInputFormat()` (:788-789) → session
guard (:794) → `AsyncStream(bufferingPolicy: .bufferingNewest(64))` (:811-813) → feed task
(:820-827) → `AudioCaptureHub.shared.subscribe(.dictation, …)` (:835) → `state = .listening`
(:866), `keyDownToCaptureTrace?.end()` (:867). `endDictation` in `.starting` bumps the session and
fails (:914-918).

**Target behaviour:**
1. The microphone is subscribed as soon as permission is known and the input format is known —
   before `engine.start()`. Audio captured before the engine is ready is held in memory, in order,
   and fed to the engine first once `start()` returns; live audio follows without a gap or a
   reorder.
2. `dictation.keyDown_to_capture` ends at that subscribe, so it no longer includes the model load
   (T4).
3. The pre-roll is bounded: at most 30 s of audio waiting for the engine (16 kHz mono Float32 ≈
   1.9 MB; estimate from the format). Beyond that, newer buffers are dropped and counted
   (`droppedStreamBuffers`), and the hold still transcribes what it kept.
4. A release while `.starting` no longer fails. The hub is unsubscribed (the microphone closes),
   the state becomes `.finishing`, and when `start()` returns the kept audio is fed, `finish()` is
   called, and the normal tail runs (cleanup, dictionary, injection into the key-down origin).
   `Limits.startup` still bounds the wait; if start fails or times out, the hold fails with a
   plain message and (after D-03) its audio is kept for "Try again".
5. A superseded start-up (the session changed because the hold failed or was cancelled) finishes
   only its own engine and its own continuation; it never calls
   `AudioCaptureHub.shared.unsubscribe(.dictation)`.
6. The island/HUD show the hold as capturing from the moment the pre-roll runs.

**Steps:**
1. In the start Task, reorder to: permission → `makeEngine()` → `let format = await formatOwner.preferredInputFormat()`
   (compute `formatOwner` as today) → session guard → create the audio stream with
   `bufferingPolicy: .unbounded` → subscribe the hub (same `onBuffer`, plus a frames-pending
   counter: increment on yield, decrement in the feed loop; when pending exceeds
   `Self.preRollFrameCap = 30 * Int(format.sampleRate)`, do not yield, count a stream drop) →
   end `keyDownToCaptureTrace` → `self.audioContinuation = audioContinuation` (so a release can
   close it) → set `isCapturingAudio = true` (new `private(set) var` the island reads).
2. Then `withBoundedWait(limits.startup) { try await engine.start() }` as today, then the Apple
   lane, then start the feed task (which drains the stream in order: the pre-roll first,
   because it was yielded first). Only now `state = .listening` if the key is still held.
3. `endDictation` in `.starting`: instead of failing, set `private var releasedDuringStartup = session`,
   unsubscribe the hub, `audioContinuation?.finish()` (the stream then ends after the kept
   buffers), set `releasedAt`, `state = .finishing`. Return.
4. Refactor the body of the `endDictation` tail Task (:938-1130) into
   `private func runTail(session: Int, capturedFrames: Int) async` so it can be called from both
   places. In the start Task, after the feed task starts: if `releasedDuringStartup == session`,
   call `runTail` directly (the stream is already finished, so the drain returns as soon as the
   kept audio is fed).
5. All failure exits in the start Task (permission, start failure, start timeout, subscribe
   failure) unsubscribe the hub only when `self.session == session`, and always finish their own
   continuation.
6. `SelfTestEngine`: new shape `.countsFrames(startDelay: Duration)` — `start()` sleeps
   `startDelay`, `feed` adds `buffer.frameLength` to a counter, `finish()` yields
   `"\(Self.transcript) \(frames)"` and closes. Expose `func framesFed() -> Int`.
7. `IslandState.card(for:…)`: pass `isCapturing: state == .listening || controller.isCapturingAudio`.
8. AGENTS.md: replace the last sentence of the quoted paragraph with: "Capture starts at key-down,
   into an in-memory pre-roll owned by that session, and is replayed into the engine once it has
   started; a superseded start-up never touches the hub — only the session that owns the slots
   unsubscribes. Measured reason: on 2026-09-23 a cold start after a 52 s model load put 4.40 s
   between key-down and capture, and the hold was lost." Keep the rest of the paragraph.

**Do not:**
- Remove or weaken any `withBoundedWait` or `Limits` value (kept limit; AGENTS.md "Every await in
  the dictation tail has a deadline").
- Feed the engine before `start()` returns (Apple needs its context first; Parakeet's partial
  state is reset in `start()`).
- Create a `Task` per buffer (ordering; the comment at :815-818).
- Let a superseded start-up unsubscribe `.dictation` (it would cut the next hold's microphone).
- Start a second hold while `.finishing` (D-13, evidence-gated).
- Use `MainActor.assumeIsolated`.

**Red-first self-test:** extend `--selftest-dictation` (via-open):
- **a. Pre-roll kept.** A controller whose engine is `.countsFrames(startDelay: .milliseconds(1500))`
  held for 2.5 s: `framesFed() ≥ 0.8 × 2.5 × 16_000 = 32_000`. Today only audio after the start is
  fed (about 1.0 s → ~16,000) → `DICTATION_WRONG: pre-roll lost: fed <n> frames of ~40000`.
- **b. Release during start-up transcribes.** Same engine, released at 1.0 s: the state goes to
  `.finishing` (not `.error`), and within 5 s the inbox holds one text containing
  "self test transcript"; D-01b outcome `.inserted`. **This inverts existing case 4** ("a hold
  released during start-up went quiet … instead of saying the recording was lost"): rewrite case 4
  to expect a transcript, and keep its second half (the next hold still works).
- **c. Capture latency.** For case a, the recorded key-down → capture (D-01b's
  `counts["keyDownToCaptureMs"]`) is ≤ 150 ms although start took 1.5 s. Today it is ≥ 1,500 ms.
- **d. Supersede safety.** Hold 1 with `.countsFrames(startDelay: 2 s)` is cancelled through
  `cancelDictation` (drive it with Command Mode's cancel path or add an internal test hook) at
  0.5 s; hold 2 starts at 0.7 s with `.prompt(delay: .zero)` and is held 1 s → hold 2's inbox gets
  its transcript (its microphone was not cut by hold 1's late unwind).
Confirm RED: a, b, c fail on the current code (b fails as today's case 4 passes).

**Verify:**
```bash
make build && make install OPEN=0
Scripts/run-selftest.sh --via-open --selftest-dictation 2>&1 | tee ~/Library/Caches/NextNotesBuild/dictation-meetings/D-02-green.txt | tail -12
Scripts/run-selftest.sh --selftest-commandkey
Scripts/run-selftest.sh --selftest-island
Scripts/run-selftest.sh --selftest-contention
make acceptance TIER=core            # dictation is CORE; run once here, not per edit
```

**Success threshold:** `DICTATION_OK` with a–d (red first) and every older case; `--selftest-commandkey`,
`--selftest-island`, `--selftest-contention` as in the baseline; no CORE regression. Owner-use: T4
(`keyDownToCaptureMs` p90 ≤ 150 ms over ≥ 30 holds) and no `lostAtStartup` rows.

**Risks & rollback:**
- The microphone opens up to a few seconds earlier than before on a cold start. It opens only
  while the key is held, which is what the user asked for.
- Memory: bounded at ~1.9 MB per hold (estimate).
- A stuck `start()` now holds captured audio until `Limits.startup` (45 s); the bound is unchanged.
- Roll back by reverting the commit; the AGENTS.md sentence reverts with it.

**Done when:**
- [ ] Capture starts before `engine.start()`; the pre-roll is fed first, in order, bounded.
- [ ] A release in `.starting` transcribes; case 4 inverted on purpose, with a comment saying why.
- [ ] A superseded start-up never unsubscribes the hub.
- [ ] AGENTS.md paragraph updated in the same commit.
- [ ] `--selftest-dictation` green with a–d (red first); CORE acceptance no regression.
- [ ] Committed as `D-02: capture from key-down and replay into the engine once it starts`.

---

### D-03 — Never lose a hold silently: speech-energy check on empty transcripts, keep the last failed hold's audio, "Try again"
**Finding(s):** I1-05 (proposals 1–2)  **Effort:** 1 day  **Depends on:** D-01b. Soft: D-02 (a release during start-up that later fails keeps its pre-roll through this task).  **Unblocks:** T5

**Why (what the user experiences today):** At 09-23 22:03:10Z a 1.5 s hold produced an empty
transcript; the controller went idle with no message (`finishIdle()` @ `DictationController.swift:1010`),
and the user held again two seconds later. Only zero captured frames gets a message (`:1003-1005`).
Every failure path disowns the audio (`fail` @ `:1334-1383` cancels the feed task and clears the
slots), so nothing can be retried: the words are gone.

**Files you will change:**
- `Core/DictationController.swift` (`DictationAudioCounter` @ :49-65 gains voiced-frame counting; the empty-transcript branch @ :1002-1014; `fail`; new `lastFailedHold`, `canRetryLastHold`, `retryLastFailedHold()`; the feed task keeps chunks)
- `UI/Island/IslandState.swift` and the island card view that draws `.problem` (add an optional "Try again" action)
- `NextNotesApp.swift` (`MenuContent` @ :5855: a "Try the last recording again" item; `runDictationSelfTest`; `SelfTestEngine`)

**Read for context (do not change):** `IslandState.card(for:transcript:level:)` (:491); the
island's hit-testing rule (AGENTS.md "The island panel is always the size of its expanded card");
the meeting silence gate RMS 0.01 ≈ −40 dBFS per 20 ms frame (`ChunkedTranscriber.swift:66-70`,
a kept limit reused here as the speech threshold).

**Current behaviour:**
```swift
            guard !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                if capturedFrames == 0 {
                    fail("No microphone audio reached dictation. Check the selected input device, then try again.")
                    return
                }
                if transcribed {
                    finishIdle()                                   // :1010 — silent
                } else {
                    fail("Transcription didn't finish in time; that recording was lost.")
                }
                return
            }
```
The feed task keeps chunks only in compare mode (`if comparing { recording.append(chunk) }` @ :823).

**Target behaviour:**
1. An empty transcript over audio that contained speech (≥ 15 voiced 20 ms frames, i.e. ≥ 0.3 s
   above RMS 0.01; estimate reusing the meeting gate) shows: "I heard you but couldn't make out the
   words. Try again, or hold a little longer." (outcome `emptySpeech`). An empty transcript over
   silence still goes idle quietly (outcome `empty`).
2. Every hold keeps its captured chunks in memory until its outcome is known (cap 180 s ≈ 11.5 MB
   Float32 at 16 kHz; estimate; beyond the cap, stop appending and mark the hold `truncated`).
   On success they are dropped. On `emptySpeech`, `failed:transcribeTimeout`, `failed:engine`,
   `failed:startup`/`startupTimeout` with a pre-roll (D-02), they move into one slot
   `lastFailedHold` (replacing any older one). The next successful hold clears the slot.
3. "Try again" (island problem card action while the card shows; and a status-menu item
   "Try the last recording again" whenever the slot is full) re-runs the kept audio through a
   fresh engine and the normal tail, and types into whatever app is frontmost when it is pressed
   (the island and the status menu do not take focus). It is a new hold with its own `holdID` and
   outcome row, with `counts["retry"] = 1`.
4. The slot is memory only: never written to disk, cleared at quit.

**Steps:**
1. `DictationAudioCounter.add(_ buffer: AVAudioPCMBuffer, isVoiced: Bool)`; `voicedFrames`
   counts buffers whose 20 ms sub-frames exceed the threshold. Put the detection in an injectable
   `speechDetector: @Sendable (AVAudioPCMBuffer) -> Int` (returns voiced 20 ms frames in the
   buffer; default computes RMS per 320-sample window). Inject through `init` next to `record:`.
2. The feed task appends every chunk to `recording` (not only in compare mode) until the 180 s cap;
   `endDictation`/`runTail` already receives it as `recorded`.
3. `struct FailedHold { let chunks: [AudioChunk]; let format: AVAudioFormat; let intent: RecordingIntent }`,
   `private(set) var lastFailedHold: FailedHold?`, `var canRetryLastHold: Bool { lastFailedHold != nil && canStartHold }`.
   Fill it on the paths in Target 2 **before** `fail` clears the slots; clear it in the success
   branch of the tail.
4. `func retryLastFailedHold()`: guard `canRetryLastHold`; take the slot; run the same start Task
   path as a hold with the kept chunks pre-yielded into the stream and the stream finished, and
   `releasedDuringStartup = session` so the tail runs as soon as the engine has started (D-02's
   path; if D-02 is not done yet, implement the minimal version: start engine, feed chunks,
   `runTail`). Origin: `TextInjector.captureOrigin()` at the moment of the click.
5. Island: the `.problem` card gets an optional action (label "Try again") shown when
   `controller.canRetryLastHold`; the button calls `retryLastFailedHold()`. Use existing card
   components and `DS` tokens. Status menu (`MenuContent`): a `Button("Try the last recording again")`
   shown only when the slot is full.
6. `SelfTestEngine.Shape.emptyTranscript` exists from D-01b; retry uses a `makeEngine` box that
   returns `.prompt(delay: .zero)` for the second engine.

**Do not:**
- Write the audio anywhere (no file, no `runs.jsonl`, no usage row content).
- Keep more than one failed hold.
- Retry automatically; a retry is always the user's click.
- Change the silence threshold of meetings (kept limit I2 #33); this task only reuses the number.
- Put "RMS", "frames" or "buffer" in any user-visible string.

**Red-first self-test:** extend `--selftest-dictation` (via-open):
- **a.** `.emptyTranscript` engine, `speechDetector: { _ in 100 }` (every buffer voiced), held
  800 ms → state `.error` with a message containing "couldn't make out"; `canRetryLastHold == true`;
  outcome `emptySpeech`.
- **b.** Same with `speechDetector: { _ in 0 }` → back to idle with no `.error`; outcome `empty`;
  `canRetryLastHold == false`.
- **c.** After a, swap the engine box to `.prompt(delay: .zero)` and call `retryLastFailedHold()`
  → the inbox receives "self test transcript"; a second outcome row with `counts["retry"] == 1`;
  `canRetryLastHold == false` afterwards.
- **d.** `.hangsOnFinish` (transcribe timeout) → `canRetryLastHold == true`.
Confirm RED: a and d fail (silent idle; nothing kept), c cannot run.

**Verify:**
```bash
make build && make install OPEN=0
Scripts/run-selftest.sh --via-open --selftest-dictation 2>&1 | tee ~/Library/Caches/NextNotesBuild/dictation-meetings/D-03-green.txt | tail -12
Scripts/run-selftest.sh --selftest-island
Scripts/run-selftest.sh --selftest-ui-strings
Scripts/run-selftest.sh --selftest-commandkey
```

**Success threshold:** `DICTATION_OK` with a–d (red first); `ISLAND_OK`, `UI_STRINGS_OK`,
`--selftest-commandkey` as in the baseline. Owner-use: T5 — no hold with speech ends with neither
text nor a message (usage rows: every `emptySpeech` / `failed:*` row is followed by either a retry
or a new hold; no silent `empty` row whose `holdMs` > 1,000 and whose speech count is high — add
`counts["voicedFrames"]` to the row for this check).

**Risks & rollback:** A noisy room can make an empty transcript read as "speech" and show the
message; the message is honest and offers a retry. Memory for a long failed hold is bounded at
~11.5 MB (estimate). Revert to roll back.

**Done when:**
- [ ] Empty-with-speech says so; silence stays quiet.
- [ ] The last failed hold's audio is kept in memory, one slot, and "Try again" works from the island and the status menu.
- [ ] `--selftest-dictation` green with a–d (red first).
- [ ] Committed as `D-03: never lose a dictation silently, and let it be tried again`.

---

## Phase C — faster and better

The four latency tasks D-06 → D-09 are one series. After each, run the stats script on the owner's
holds since the previous task's commit and record the row in *Owner-use measurements*; compare
only neighbouring rows with the same engine settings.

### D-06 — Warm Apple's model at launch and after wake; gate the S1-mini launch load on the engine that will actually run
**Finding(s):** I1-01 (proposal 1), I1-09  **Effort:** 0.5 day  **Depends on:** D-01a  **Unblocks:** D-07

**Why (what the user experiences today):** The `CleanupSessionWarmer` table
(`FoundationModelFormatter.swift:279-283`) measured Apple's model at **4.69 s** for the first call
in a fresh process, 1.42–1.58 s for later fresh sessions and 0.94 s prewarmed. Every launch — and
agents reinstall this app several times a day — makes the next dictation a first call, and the
cleanup timeout floor is 4.0 s, so a short first dictation is guaranteed to time out. Meanwhile
the launch loads **S1-mini** (484 MB) whenever `cleanupEngine == .s1Mini`, although with grammar
repair on (this Mac: `cleanupFixesGrammar = 1`) `CleanupRouter.preferredEngine` sends every
cleanup to Apple. That is half a gigabyte resident for nothing on a 16 GB machine that spent 52 s
loading a model under memory pressure on 09-23 03:04Z.

**Files you will change:**
- `NextNotesApp.swift` (`applicationDidFinishLaunching` @ :202; the S1-mini gate @ :283-287)
- new `Formatting/AppleModelWarmth.swift` (`AppleModelWarmth`, `LaunchWarmup`)
- `Formatting/FoundationModelFormatter.swift` and `Formatting/StructurePlanner.swift` (report activity: one call each after a successful `respond`)
- `Formatting/CleanupRouter.swift` (`runSelfTest`: the decision table; `StructurePlanProbe`-style probe hook)
- new `Formatting/CleanupWarmthProbe.swift` (`--probe-cleanup-warmth`, asserts nothing)

**Read for context (do not change):** `CleanupRouter.preferredEngine(choice:fixesGrammar:)`
(`CleanupRouter.swift:328-338`); `LocalModelStore.prepareS1Mini` (`Support/LocalModelStore.swift:68`);
the key-down staging block in `DictationController.beginDictation` (:688-704), which already stages
the cleanup and layout sessions for the captured target; the `NSWorkspace.didWakeNotification`
observer pattern in `Calendar/CalendarService.swift:66`; AGENT-OVERHAUL P0-06 (warmups must not
take a voice lane — the same principle applies here: never warm while a dictation or a voice turn
is running).

**Current behaviour:**
```swift
        if Settings.shared.cleanupEnabled,
           Settings.shared.cleanupEngine == .s1Mini,           // :284 — ignores fixesGrammar
           S1MiniModels.isDownloaded {
            LocalModelStore.shared.prepareS1Mini()
        }
```
Nothing touches Apple's model until the first key-down.

**Target behaviour:**
1. `LaunchWarmup.plan(cleanupEnabled:choice:fixesGrammar:s1Downloaded:appleAvailable:) -> Set<LaunchWarmup.Action>`
   (`.loadS1Mini`, `.warmApple`) is the single decision, and `applicationDidFinishLaunching` does
   exactly what it returns:
   | cleanup | choice | grammar | result |
   |---|---|---|---|
   | off | any | any | `[]` |
   | on | `.s1Mini` | off | `[.loadS1Mini]` (if downloaded) |
   | on | `.s1Mini` | on | `[.warmApple]` (if available) |
   | on | `.apple` | any | `[.warmApple]` (if available) |
2. `.warmApple` runs `AppleModelWarmth.warmProcess()` on a `.utility` task a few seconds after
   launch (after the Parakeet prepare has been kicked off), and again on
   `NSWorkspace.didWakeNotification`. It skips itself when a dictation is active or an Agent voice
   session is live.
3. `AppleModelWarmth` records the last successful Apple model activity (cleanup, layout, or warm)
   and answers `current(now:) -> Warmth` (`.cold` / `.warmProcess`); D-07 reads it.
4. Which warm-up actually removes the cold start is **measured, not assumed**: the probe compares
   the first cleanup call after (a) nothing, (b) `session.prewarm()` only, (c) a one-token
   `respond`. `warmProcess()` uses the cheapest mode that brings the first cleanup call within
   0.3 s of the "later fresh session" figure (1.42–1.58 s). Record the three numbers in `STATUS.md`.

**Steps:**
1. `Formatting/AppleModelWarmth.swift`:
   ```swift
   enum Warmth: String, Sendable { case staged, warmProcess, cold }
   @MainActor enum AppleModelWarmth {
       static var warmWindow: Duration = .seconds(600)   // estimate; tune from D-01a rows (cleanup seconds vs minutes since the last Apple call)
       static private(set) var lastActivity: Date?
       static func noteActivity(_ date: Date = Date())
       static func current(now: Date = Date()) -> Warmth   // .warmProcess within warmWindow, else .cold
       enum Mode: String { case prewarm, respond }
       static var mode: Mode = .respond                     // set from the probe result
       static func warmProcess() async                      // plain-target cleanup instructions; prewarm or a 1-token respond; noteActivity on success; stages the session when mode == .prewarm
   }
   enum LaunchWarmup { enum Action: Hashable { case loadS1Mini, warmApple }
       static func plan(cleanupEnabled: Bool, choice: CleanupEngineChoice, fixesGrammar: Bool,
                        s1Downloaded: Bool, appleAvailable: Bool) -> Set<Action> }
   ```
   `FoundationModelFormatter.format` and `AppleStructurePlanner.plan` call
   `await MainActor.run { AppleModelWarmth.noteActivity() }` after a successful model answer (not
   `MainActor.assumeIsolated`).
2. `applicationDidFinishLaunching`: replace the S1-mini block with
   `let actions = LaunchWarmup.plan(...)`; `if actions.contains(.loadS1Mini) { prepareS1Mini() }`;
   `if actions.contains(.warmApple) { Task(priority: .utility) { try? await Task.sleep(for: .seconds(5)); await AppleModelWarmth.warmProcess() } }`.
   Register the wake observer (store the token; same pattern as `CalendarService`).
   Skip conditions inside `warmProcess`: `controller.state.isActive`, or the voice session is live
   (read the existing flag the island uses for the agent-listening state; do not add a new global).
   Never run the warm-up from a self-test (`SelfTest.isRunning` short-circuits the *launch hook*,
   not production logic).
3. `Formatting/CleanupWarmthProbe.swift` (`--probe-cleanup-warmth <none|prewarm|respond>` beside
   `--selftest-cleanup-router`, same shape as `StructurePlanProbe`): in a fresh process, apply the
   mode, then time one real cleanup of the fixed 10-word fixture "okay so um I think we should
   ship it on friday"; print `CLEANUP_WARMTH mode=<m> first_call=<s>`. Asserts nothing.
4. Settings changes (engine, grammar) after launch: when the user switches to a combination whose
   plan contains `.warmApple`, call `warmProcess()` once (observe the two settings where the
   Settings tab already writes them).

**Do not:**
- Warm while a dictation or a voice turn runs (it would compete for the same model).
- Raise `CleanupSessionWarmer.capacity` (kept limit).
- Unload S1-mini if the user later switches grammar off: loading on demand is the existing
  behaviour of the first S1-mini call.
- Change the timeout here (D-07).

**Red-first self-test:** extend `--selftest-cleanup-router` with `launchWarmupFailures()`: the
four table rows above plus "not downloaded" and "Apple unavailable" variants; failure line
`  launch warm-up: <row> gave <set>`. Confirm RED by first adding `LaunchWarmup.plan` as a seam that
reproduces today's rule (`.loadS1Mini` whenever choice == `.s1Mini`, never `.warmApple`): rows 3–4
fail. Also assert `AppleModelWarmth.current` flips from `.warmProcess` to `.cold` after
`warmWindow` using injected dates.

**Verify:**
```bash
make build && make install OPEN=0
Scripts/run-selftest.sh --selftest-cleanup-router | tail -5
# Measurement, three fresh processes, one at a time:
for m in none prewarm respond; do Scripts/run-selftest.sh --selftest-cleanup-router --probe-cleanup-warmth $m | grep CLEANUP_WARMTH; done
Scripts/run-selftest.sh --selftest-residency
Scripts/run-selftest.sh --selftest-cleanup apple-grammar | grep CLEANUP_SUMMARY
```
Owner check after install: `ps -o rss= -p $(pgrep -x NextNotes)` a minute after launch is lower
than before by about the S1-mini size when grammar is on (estimate ~0.5 GB).

**Success threshold:** `CLEANUP_ROUTER_OK` (red first); the probe's chosen mode brings
`first_call` to ≤ 1.9 s (1.58 s + 0.3 s) against the `none` run; the three numbers are recorded in
`STATUS.md`. Owner-use: the first dictation after a launch does not time out (D-01a rows:
`sessionPrewarmed` and `fallbackReason` on the first run after each install).

**Risks & rollback:** A warm-up call costs model time at launch; it runs at `.utility` after a
5 s delay and skips when anything is active. If Apple's model turns out not to keep a process-level
warm state, the probe shows `none ≈ respond` — then set `warmProcess` to stage only (prewarm) and
say so in *Decisions and deviations*. Revert to roll back.

**Done when:**
- [ ] `LaunchWarmup.plan` is the only launch decision; S1-mini no longer loads when Apple runs the cleanup.
- [ ] Apple's model is warmed at launch and after wake, never during a dictation or voice turn.
- [ ] Probe numbers in `STATUS.md`; `--selftest-cleanup-router` green (red first).
- [ ] Committed as `D-06: warm Apple's model at launch and stop loading S1-mini when Apple runs the cleanup`.

---

### D-07 — Warmth-aware Apple cleanup timeout
**Finding(s):** I1-01 (proposal 2)  **Effort:** 0.5 day  **Depends on:** D-01a, D-06  **Unblocks:** D-08, D-11, D-12, T2

**Why (what the user experiences today):** `FoundationModelFormatter.timeout(for:)` is
`min(14, 4.0 + 0.07 × words)` s. A cold first call measured 4.69 s, so any dictation of ≤ 10 words
that lands on a cold model is guaranteed to time out, and about 20 words usually does. Of the 9
timeouts in `runs.jsonl`, 6 are single-call runs waited out at 4.7–12.3 s (I1-01 table: 09-20
18:01, 10 words, waited 4.71 s; 09-22 21:38, 16 words, 5.15 s; 09-22 21:50, 36 words, 6.53 s). The
next dictation after 21:50 was prewarmed and cleaned 40 words in 2.87 s. Each timeout discards the
answer and types the rules output, after the user waited the whole budget.

**Files you will change:** `Formatting/FoundationModelFormatter.swift` (`timeout(for:)` @ :260-264,
`format` @ :92-169); `Formatting/CleanupRouter.swift` (`perCallTimeout(for:)` @ :343-354;
`runSelfTest`).

**Read for context (do not change):** `ChunkedFormatter.budget` / `perCallTimeout` / the wave check
(`SentenceChunker.swift:128-181`: a wave starts only if its ceiling fits in what is left of 26 s);
`DictationController.Limits.cleanup` (30 s, kept); `S1MiniFormatter.timeout(for:)` (`S1MiniFormatter.swift:27`).

**Current behaviour:**
```swift
    static func timeout(for text: String) -> Duration {
        let words = text.split { $0.isWhitespace || $0.isNewline }.count
        let seconds = min(14.0, 4.0 + Double(words) * 0.07)        // :262
        return .seconds(seconds)
    }
```
The budget is computed at `:107` before the session is taken, so it cannot know whether a staged
session will be used.

**Target behaviour:**
1. `static func timeout(for text: String, warmth: Warmth) -> Duration`:
   `.staged`, `.warmProcess` → today's formula `min(14, 4.0 + 0.07·w)`;
   `.cold` → `min(16, 8.5 + 0.07·w)` (I1-01: the 4.69 s cold penalty on top of the warm floor,
   rounded up; a true stall still ends).
2. `format` decides warmth **after** taking the session: `.staged` if a staged session was taken,
   else `AppleModelWarmth.current()`, and only then starts the timer.
3. `ChunkedFormatter`'s budget check for Apple uses the same function with
   `AppleModelWarmth.current()` for the first wave and `.warmProcess` for later waves (the first
   wave has woken the model). The 26 s whole-pass budget and the 30 s outer limit are unchanged.
4. The trace records which warmth was assumed: `CleanupRecord.assumedWarmth: String?`.

**Steps:**
1. Restructure `format`: move session-taking out of the racing child task. Take the session (or
   call `modelCall.takeSession`) first, record `sessionPrewarmed` (D-01a), compute
   `let warmth: Warmth = staged ? .staged : await MainActor.run { AppleModelWarmth.current() }`,
   `let budget = scaled(Self.timeout(for: trimmed, warmth: warmth))`, then race `respond` against
   `Task.sleep(for: budget)`. `scaled` multiplies by `timeScale` (§0.7; default 1; replaces
   D-01a's `timeoutOverride`).
2. Keep `timeout(for:)` as `timeout(for: text, warmth: .warmProcess)` for callers that do not know
   (grep them; `perCallTimeout` should call the new function explicitly).
3. `CleanupRouter.perCallTimeout(for: .apple)` returns
   `{ FoundationModelFormatter.timeout(for: $0, warmth: AppleModelWarmth.currentNonisolated()) }`
   — provide a lock-protected nonisolated read of `lastActivity` so the `@Sendable` closure need
   not hop actors. For "later waves are warm", give `ChunkedFormatter` an optional
   `perCallTimeoutAfterFirstWave` closure used from wave 2 on (nil = same as the first).
4. `CleanupTrace.noteAssumedWarmth(_:)` and the record field.

**Do not:** raise the 26 s chunk budget or the 30 s `Limits.cleanup` (kept limits); make the cold
budget unbounded; change S1-mini's timeout.

**Red-first self-test:** extend `--selftest-cleanup-router` with `warmthTimeoutFailures()`:
- pure: `timeout(for: 10 words, warmth: .cold) ≥ 9.2 s`; `.staged` = 4.7 s; `.cold` for 200 words
  = 16 s (cap); `.warmProcess` = `.staged`;
- integration (fast, `timeScale = 0.05`): a formatter with `modelCall` whose `takeSession`
  returns false, `AppleModelWarmth` forced cold (inject `lastActivity = nil`), and `respond` that
  sleeps 4.8 s × 0.05 = 240 ms on a 10-word input → **accepted** (cold budget 9.2 × 0.05 = 460 ms);
  a `respond` that sleeps 20 s × 0.05 = 1 s → **timed out**; with `takeSession` true and a
  300 ms respond → **timed out**, because the staged budget is 4.7 × 0.05 = 235 ms (this pins
  that the staged budget stays the tight one);
- chunk budget: a 3-group input with `.cold` first wave still starts wave 2 inside 26 s (use
  `ChunkedFormatter(budget: .seconds(26) * 0.05 …)` with scaled ceilings).
Confirm RED: add the `warmth:` parameter as a seam that ignores warmth; the 240 ms cold case times
out → `CLEANUP_ROUTER_FAILED`.

**Verify:**
```bash
make build && make install OPEN=0
Scripts/run-selftest.sh --selftest-cleanup-router 2>&1 | tee ~/Library/Caches/NextNotesBuild/dictation-meetings/D-07-green.txt | tail -5
Scripts/run-selftest.sh --selftest-cleanup apple-grammar | grep -E "CLEANUP_SUMMARY|CLEANUP_(OK|FAILED)"
```
In the `--selftest-cleanup apple-grammar` output, the first (cold) case must no longer fall back
to the rules output because of time (compare its `out:` line with the baseline run).

**Success threshold:** `CLEANUP_ROUTER_OK` (red first); `CLEANUP_OK` with `cold=` below the cold
budget of the first fixture. Owner-use (≥ 30 model cleanups after D-06 + D-07): timeout rate
≤ 5 % (interim; T2's 2 % needs D-08 too).

**Risks & rollback:** A genuinely stalled cold call now costs up to 16 s instead of 14 s before
falling back (bounded; still under the 30 s outer limit). Revert to roll back.

**Done when:**
- [ ] Warmth decided after the session is taken; cold budget in place; chunk budget reads the same function.
- [ ] `assumedWarmth` recorded.
- [ ] `--selftest-cleanup-router` green (red first); `--selftest-cleanup apple-grammar` green.
- [ ] Committed as `D-07: give a cold cleanup model the time it measurably needs`.

---

### D-08 — Chunked Apple cleanup: width chosen by measurement, wave-aware ceilings, staged sessions per group, per-group verdicts
**Finding(s):** I1-02  **Effort:** 1 day  **Depends on:** D-07  **Unblocks:** D-09, D-12, T2

**Why (what the user experiences today):** `ChunkedFormatter.width = 2` (`SentenceChunker.swift:150`)
sends two sentence groups to Apple's model at once, and each is timed as if it ran alone. The model
serialises them: 09-23 00:00 (186 words) Σ model 18.79 s, wall 9.77 s, timed out; 09-23 03:10
(175 words) Σ 19.46 s, wall 11.51 s, timed out; 09-23 03:12 (133 words) accepted. Two of the three
two-group runs since 09-23 lost their cleanup; the 26 s whole-pass budget was nowhere near
exhausted. Only group 1 gets the key-down prewarm, and the trace keeps the last writer's verdict,
so a run's record cannot say which group failed.

**Files you will change:** `Formatting/SentenceChunker.swift` (`ChunkedFormatter`: `width`,
the wave ceiling, next-group staging, group context); `Formatting/FoundationModelFormatter.swift`
(`format` reads the group context; `CleanupSessionWarmer.stage` may hold two sessions for one
prompt); `Formatting/CleanupRouter.swift` (`production` passes the per-engine width; self-test);
`Formatting/CleanupTrace.swift` (`groupVerdicts`, `groupSeconds`, `groupPrewarmed`); new
`--probe-chunk-width` in `Formatting/CleanupWarmthProbe.swift`.

**Read for context (do not change):** the mid-pass budget fixture in
`structureThroughRouterFailures` (`CleanupRouter.swift:866-915`); the `width` doc comment
(`SentenceChunker.swift:138-150`: width 2 was measured on S1-mini-era timings, "a forty-one second
dictation is two groups … 9.3 s").

**Current behaviour:** waves of `width` groups run in a task group; the wave's ceiling is the
**max** of the per-call ceilings (`let ceiling = wave.map { perCallTimeout(groups[$0]) }.max()` @
`SentenceChunker.swift:173`); each FMF call races its own solo timeout.

**Target behaviour:**
1. The Apple width is decided by a measurement, recorded in `STATUS.md`:
   `--probe-chunk-width` runs the same two ~90-word groups at width 1 and width 2 on the real
   model (fresh process, warmed first) and prints `CHUNK_WIDTH w1_wall=<s> w2_wall=<s>`. Rule: if
   `w2_wall ≤ 0.85 × w1_wall`, keep width 2 for Apple; otherwise width 1. S1-mini and `.appLLM`
   keep 2.
2. Whatever the width, a call in a wave of `n` on a serialising engine gets a ceiling of
   `timeout(for: group, warmth:) × n`, and the wave's budget check uses the **sum** of its calls'
   ceilings. The 26 s budget still caps the pass.
3. Before group `i` starts, a cleanup session for group `i + 1` is staged
   (`CleanupSessionWarmer.stage` allows up to 2 staged sessions per prompt, total capacity still 3),
   so every group after the first also runs prewarmed.
4. The trace records one verdict, seconds and prewarm flag per group (`groupVerdicts: ["accepted",
   "timed out", …]`); the run-level `guardVerdict` is the worst group verdict, and
   `fallbackReason` names the failed group count ("1 of 2 parts was used as spoken").

**Steps:**
1. `ChunkedFormatter`: add `var serialisesCalls = false`. In the wave loop, when true:
   `let ceiling = wave.reduce(.zero) { $0 + perCallTimeout(groups[$1]) }`, and run each group
   inside `CleanupGroupContext.$current.withValue(CleanupGroupContext(index: i, callsInWave: wave.count))`.
   `@TaskLocal static var current: CleanupGroupContext?` lives in `SentenceChunker.swift`.
2. `FoundationModelFormatter.format`: multiply its budget by `CleanupGroupContext.current?.callsInWave ?? 1`,
   and report per-group results through `trace?.noteGroup(index:verdict:seconds:prewarmed:)` when
   the context is set.
3. Staging: `ChunkedFormatter` gets `var stageNext: (@Sendable (String) async -> Void)?`; production
   (`CleanupRouter.production`, `.apple`) passes a closure that stages the cleanup instructions for
   that target. Call it for group `i + 1` right before awaiting wave `i`. `CleanupSessionWarmer.stage`:
   allow a second session for the same instructions (`staged.filter { $0.instructions == instructions }.count < 2`);
   capacity 3 unchanged.
4. `CleanupRouter.production`: `ChunkedFormatter(…, width: Self.chunkWidth(for: engine), serialisesCalls: engine == .apple)`;
   `chunkWidth(.apple)` = the measured value (a named constant with a comment quoting the probe
   numbers and date).
5. `CleanupRecord`: `groupVerdicts: [String]?`, `groupSeconds: [Double]?`, `groupPrewarmed: [Bool]?`
   (optional; old rows decode). Update the stats script's `timed_out` logic only if the
   run-level fields change meaning (they should not).

**Do not:** change the 26 s budget, `maxWords` 120 or `CleanupSessionWarmer.capacity` (kept
limits); run more than 2 groups at once; stage sessions for Command Mode.

**Red-first self-test:** extend `structureThroughRouterFailures` (`--selftest-cleanup-router`):
- **a. Serialised wave.** `ChunkedFormatter(inner: FoundationModelFormatter(modelCall: serialised 200 ms respond, timeScale: …), width: 2, serialisesCalls: true)`
  where the two calls share an actor lock (so the second finishes at ~400 ms) and each call's own
  budget is pinned at 250 ms (`timeScale` chosen so the 2-group text's `timeout × 0.xx ≈ 250 ms`):
  both groups accepted; `groupVerdicts == ["accepted", "accepted"]`. On today's code the second
  group times out at 250 ms.
- **b. Budget sums.** With `serialisesCalls: true` and per-call ceiling 200 ms, a wave of 2 is not
  started when 300 ms of budget remain (sum 400 ms), and its groups are left as spoken with a reason.
- **c. Staging.** A recording `stageNext` closure is called once per group after the first.
- **d. Verdicts.** One group times out, one accepted → `guardVerdict` is the worse one and
  `groupVerdicts` has both.
Keep the existing mid-pass fixture unchanged (it uses a non-serialising fake).
Confirm RED: a, c, d fail on the current code.

**Verify:**
```bash
make build && make install OPEN=0
Scripts/run-selftest.sh --selftest-cleanup-router 2>&1 | tee ~/Library/Caches/NextNotesBuild/dictation-meetings/D-08-green.txt | tail -5
Scripts/run-selftest.sh --selftest-cleanup-router --probe-chunk-width | grep CHUNK_WIDTH
Scripts/run-selftest.sh --selftest-cleanup apple-grammar | grep -E "CLEANUP_SUMMARY|CLEANUP_(OK|FAILED)"
```

**Success threshold:** `CLEANUP_ROUTER_OK` (red first); probe numbers and the chosen width in
`STATUS.md`. Owner-use: no chunked run times out while the 26 s budget has more than 10 s left
(`chunked_runs` with `timed out` → 0 over ≥ 5 chunked runs); T2 ≤ 2 % over ≥ 50 model cleanups
after D-06–D-08.

**Risks & rollback:** Width 1 makes very long dictations take the sum of their groups; that is
what the model does anyway when it serialises (I1-02 evidence). Revert to roll back.

**Done when:**
- [ ] Width measured and set; ceilings wave-aware; next group staged; per-group verdicts recorded.
- [ ] `--selftest-cleanup-router` green (red first).
- [ ] Committed as `D-08: time chunked Apple cleanup the way the model actually runs it`.

---

### D-09 — Anchor the layout-pass deadline to the cleanup pass it runs beside
**Finding(s):** I1-03  **Effort:** 0.5 day  **Depends on:** D-08  **Unblocks:** T7

**Why (what the user experiences today):** The layout pass (Stage D) is started beside the cleanup
pass and cut at `AppleStructurePlanner.budget(forSentences:)` = `min(6, max(3.5, 0.3 × sentences))`
s (`StructurePlanner.swift:110-111`). It was asked 6 times; only 1 plan was used; 4 answers were
"the layout pass ran out of time after 3.5s" while the user kept waiting another 3.4–8 s for the
cleanup (09-23 00:00: plan 3.53 s, cleanup wall 9.77 s; 03:10: 3.52 / 11.51; 03:12: 3.51 / 7.16;
22:02: 3.50 / 6.87). The deadline saved nothing. The owner dictated about this exact failure on
09-20 20:48 ("The list never get triggered, the formatting doesn't go through").

**Files you will change:** `Formatting/StructurePlan.swift` (`StructurePlanning` @ :599: add
`plan(for:deadline:)` with a default); `Formatting/StructurePlanner.swift` (`AppleStructurePlanner.plan`,
`LLMStructurePlanner`, `ScriptedStructurePlanner` @ :290); `Formatting/CleanupRouter.swift`
(`format`: the plan start @ :139-153 and the await @ :216-217; init seams `layoutWait`,
`layoutGrace`; `runSelfTest`).

**Read for context (do not change):** the overlap test in `structurePlanFailures`
(`CleanupRouter.swift:1440-1470`, asserts the two passes overlap); the budget-growth assertions
(`:1366-1386`, stay valid: they are about the rules-route budget).

**Current behaviour:** `planTask = Task { await planner.plan(for: planSentences) }` (`:152`); after
Stage B, `let outcome = await planTask.value` (`:217`). The only deadline is inside
`AppleStructurePlanner.plan`: `let deadline = budget ?? Self.budget(forSentences: sentences.count)`.

**Target behaviour:**
1. On the **model route** (`decision.stage == .semantic`), the planner gets a hard ceiling of
   `layoutCeiling = 12 s` (estimate; well inside the 26 s chunk budget and the 30 s outer limit)
   instead of `budget(forSentences:)`. After Stage B returns, the router waits for the plan at most
   `max(nominal − elapsedSincePlanStart, layoutGrace)` where `nominal = budget(forSentences:)` and
   `layoutGrace = 0.5 s`, then cancels it and records "the layout pass ran out of time after <x>s".
   So a plan that finishes while the cleanup is still running is always used, and the user never
   waits more than 0.5 s past the cleanup for a plan that was already over its nominal budget.
2. On the **rules route**, today's behaviour: the planner's own `budget(forSentences:)`.
3. Measured risk (I1-03): two requests on one on-device model slow each other. Measure the cleanup
   wall time with the plan running beside it and with the plan started after Stage B, using
   `--probe-layout`. If running beside makes cleanup slower by more than the plan saves, start the
   plan after Stage B (with its own staged layout session) instead, and record the numbers.

**Steps:**
1. `protocol StructurePlanning { …; func plan(for sentences: [String], deadline: Duration?) async -> StructurePlanOutcome }`
   with `extension StructurePlanning { func plan(for s: [String]) async -> StructurePlanOutcome { await plan(for: s, deadline: nil) } }`.
   `AppleStructurePlanner`: `let deadline = deadline ?? budget ?? Self.budget(forSentences:)`.
   `ScriptedStructurePlanner` records the deadline it was given (`lastDeadline` in a lock box) so
   the test can read it. Update `LLMStructurePlanner` to accept and honour it.
2. `CleanupRouter`: init params `layoutWait: @Sendable (Int) -> Duration = AppleStructurePlanner.budget(forSentences:)`,
   `layoutGrace: Duration = .milliseconds(500)`, `layoutCeiling: Duration = .seconds(12)`. At plan
   start record `planStart = ContinuousClock.now` and pass `deadline: decision.stage == .semantic ? layoutCeiling : nil`.
   After Stage B: `let wait = max(layoutWait(n) - (now - planStart), layoutGrace)`;
   `let outcome = await withBoundedWait(wait) { await planTask.value }`; on nil,
   `planTask.cancel()` and use `.failed("the layout pass ran out of time after …s")`.
3. `--probe-layout` (`StructurePlanProbe`): add `measureOverlapCost()` printing
   `LAYOUT_OVERLAP cleanup_alone=<s> cleanup_beside_plan=<s> plan=<s>` for the 12-sentence fixture.

**Do not:** let the plan extend the user's wait by more than `layoutGrace` past the cleanup; touch
the rules-route budget or its assertions; remove the overlap (unless step 3's measurement says so,
recorded).

**Red-first self-test:** extend `structurePlanFailures` (`--selftest-cleanup-router`), with
`layoutWait: { _ in .milliseconds(300) }`, `layoutGrace: .milliseconds(100)`:
- **a.** `ScriptedStructurePlanner` that answers a valid plan at 500 ms, Stage B `SlowFormatter(delay: 700 ms)`
  → the plan is used (`structurePlanModel == "scripted"`, `structurePlanRejected == nil`, the
  planned layout rendered); the planner was given `deadline == layoutCeiling`.
- **b.** Planner answers at 1,500 ms, Stage B 700 ms → the router returns by ~800 ms (< 1,100 ms
  with slack) with `structurePlanRejected` containing "ran out of time".
- **c.** Planner at 500 ms, Stage B 100 ms → dropped at ~300 ms (nominal), as today.
- **d.** Rules route → planner given `deadline == nil`.
Confirm RED: with the protocol seam added but the router unchanged, a's recorded deadline is nil
and b waits the full 1,500 ms.

**Verify:**
```bash
make build && make install OPEN=0
Scripts/run-selftest.sh --selftest-cleanup-router 2>&1 | tee ~/Library/Caches/NextNotesBuild/dictation-meetings/D-09-green.txt | tail -5
Scripts/run-selftest.sh --selftest-cleanup-router --probe-layout | grep -E "LAYOUT_OVERLAP|layout probe"
Scripts/run-selftest.sh --selftest-cleanup-structure
```

**Success threshold:** `CLEANUP_ROUTER_OK` (red first); overlap numbers in `STATUS.md`.
Owner-use: T7 — of ≥ 10 layout passes asked after D-09, ≤ 1 ends "ran out of time" while the
cleanup was still running.

**Risks & rollback:** More plans reach the renderer; the plan is already validated
(`plan.rejection(sentenceCount:)`) and mapped with `remapped`, so a bad plan is still dropped.
Revert to roll back.

**Done when:**
- [ ] The model-route deadline is anchored to the cleanup; the rules route unchanged.
- [ ] Overlap cost measured and recorded; decision noted.
- [ ] `--selftest-cleanup-router` green (red first).
- [ ] Committed as `D-09: let the layout pass finish while the cleanup is still running`.

---

### D-11 — Clause-level salvage for long single-sentence answers
**Finding(s):** I1-10  **Effort:** 1 day  **Depends on:** D-07  **Unblocks:** D-12, T3

**Why (what the user experiences today):** `CleanupGuard.salvage` re-judges a rejected answer
sentence by sentence, and gives up when the input is one sentence (`guard sources.count > 1 else { return nil }`
@ `CleanupGuard.swift:217`). Parakeet often returns a long run-on with no internal full stops. At
09-22 03:42Z a 110-word single-sentence dictation was rejected for "invented word: interface"
(almost certainly "ui ux" expanded to "user interface"); every filler removal and repair in the
other ~108 words was lost after 5.2 s of waiting. The guard is right to reject the invention; the
granularity is what hurts.

**Files you will change:** `Formatting/CleanupGuard.swift` (`salvage` @ :214-250; new
`clauses(in:)`); `Formatting/CleanupRouter.swift` (`salvageFailures()` cases);
`Formatting/CleanupEvalCases.swift` (one constructed case, so `--selftest-cleanup` exercises it on
the real model).

**Read for context (do not change):** `CleanupGuard.rejection` (:40-175, thresholds are a kept
limit); `CleanupGuard.aligned(sources:candidates:)` (:262-280); `SentenceChunker.sentences(in:)`;
AGENTS.md "A new engine in `--selftest-cleanup` scores 28/28 until you give it a `rawCleanup` case"
(the eval case must go through the raw path to mean anything).

**Current behaviour:** see the quote above; for `sources.count > 1` the pairs are aligned and each
pair judged by `rejection(original:cleaned:mode:)`.

**Target behaviour:**
1. When a source sentence (or the whole input) is longer than 30 words, it is split into clauses
   on `,` `;` `:` and before the conjunctions "and", "but", "so", "because", "then" (only where both
   resulting pieces have ≥ 4 words); the model's corresponding text is split the same way; the
   clauses are aligned with the existing `aligned(sources:candidates:)`; each clause pair is judged
   with the unchanged `rejection`; failed clauses are put back as spoken.
2. If clause alignment fails (counts differ more than `aligned` tolerates), the result is as today
   (nil → whole-answer fallback).
3. Guard thresholds are unchanged. The record's `plainReason` says "parts" instead of "sentences"
   when clause salvage was used.

**Steps:**
1. `static func clauses(in sentence: String) -> [String]` (pure, deterministic; keeps
   punctuation with the preceding clause).
2. In `salvage`: build `sourceUnits` = sentences, each sentence > 30 words replaced by its clauses;
   same for candidates; if `sourceUnits.count > 1`, proceed with the existing pair loop over
   `aligned(sources: sourceUnits, candidates: candidateUnits)`. Keep the `rejected > 0,
   rejected < pairs.count` rule.
3. `Salvage` gains `usedClauses: Bool`; `plainReason` uses "parts" when true.
4. `CleanupEvalCases`: a constructed case with the 110-word run-on pattern (fillers "um", "you
   know", and "the ui ux of the app"), expectation "keeps the filler removals; does not invent
   'user interface'".

**Do not:** change any `rejection` threshold, `phoneticBudget`, or the length ratio (kept limit
I1-21); splice at word level (I1's alternative) unless the fixture below cannot be recovered at
clause level — if you need it, record why in *Decisions and deviations*.

**Red-first self-test:** extend `salvageFailures()` (`--selftest-cleanup-router`), pure, no model:
- input: a 110-word single sentence built from the fixture pattern (write it in the test; include
  "um" ×3, "you know" ×2, and "the ui ux of the app is confusing");
- scripted model answer: the same sentence with fillers removed and "the ui ux of the app" →
  "the user interface and user experience of the app";
- assert `rejection(original:cleaned:)` is non-nil (the guard still catches the invention);
- assert `salvage(...)` is non-nil, contains no " um " and no "you know", **does** contain
  "ui ux", and does not contain "interface";
- a second input of 20 words (below the clause threshold) behaves exactly as today (nil).
Confirm RED: today `salvage` returns nil for the 110-word case.

**Verify:**
```bash
make build && make install OPEN=0
Scripts/run-selftest.sh --selftest-cleanup-router 2>&1 | tee ~/Library/Caches/NextNotesBuild/dictation-meetings/D-11-green.txt | tail -5
Scripts/run-selftest.sh --selftest-cleanup guard                 # guard vectors unchanged
Scripts/run-selftest.sh --selftest-cleanup apple-grammar | grep -E "CLEANUP_SUMMARY|CLEANUP_(OK|FAILED)|REJECTED"
```

**Success threshold:** `CLEANUP_ROUTER_OK` (red first); `--selftest-cleanup guard` unchanged;
`CLEANUP_OK` on apple-grammar including the new case. Owner-use: T3 wasted share ≤ 10 % after
D-06–D-11.

**Risks & rollback:** A clause split in the wrong place pairs unrelated text; `aligned` then fails
and the old behaviour applies. Revert to roll back.

**Done when:**
- [ ] Long single sentences salvage at clause level; thresholds untouched.
- [ ] Pure fixture and eval case added; `--selftest-cleanup-router` green (red first).
- [ ] Committed as `D-11: salvage long run-on dictations clause by clause`.

---

## Phase D — deeper changes and hygiene

### D-12 — Incremental cleanup of stable sentences during the hold
**Finding(s):** I1-11  **Effort:** 2–3 days  **Depends on:** D-07, D-08, D-11, D-01b  **Unblocks:** T1 (final target)

**Why (what the user experiences today):** The whole transcript goes to the cleanup model after
release (`DictationController` tail, `withBoundedWait(limits.cleanup, { await formatter.format(raw) })`
@ `Core/DictationController.swift:1042`). Cleanup is 93 % of the release → text tail (median
5.19 s against 0.38 s ASR and 0.15 s injection). Parakeet already produces a partial transcript
every second while the key is held (`ParakeetEngine.maybeEmitPartial`), and cleanup is local to a
sentence (the premise of `ChunkedFormatter`), so most of that work could be done before the key
comes up.

**Files you will change:**
- new `Formatting/IncrementalCleanup.swift` (`IncrementalCleanupSession`)
- `Formatting/SentenceChunker.swift` (`ChunkedFormatter` accepts precleaned groups)
- `Formatting/CleanupRouter.swift` (`format` accepts a `CleanupHead` hint; `runSelfTest`)
- `Core/DictationController.swift` (create the session at `.listening` when cleanup is on and the engine is Apple; feed it from `consumeTask`; hand it to the tail)
- `Formatting/CleanupTrace.swift` (`precleanedGroups: Int?`, `precleanFallback: String?`)
- `NextNotesApp.swift` (`SelfTestEngine.Shape.partials`, a dictation case)

**Read for context (do not change):** `CleanupRouter.format` Stage A → B → C → D (`CleanupRouter.swift:90-300`);
`SentenceChunker.chunks(_:maxWords:)` (greedy from the start: a group is final once the next
sentence would overflow it); AGENTS.md "A prompt rule is only a rule for the engines that read
prompts" (Stage C runs before and after the model — must still run on the **whole** final text).

**Current behaviour:** no cleanup work happens before key-up.

**Target behaviour:**
1. While the key is held, a sentence of the partial transcript is **stable** when it is not the
   last sentence and it is identical in two consecutive partials. Stable sentences are run through
   Stage A (the same rules pass the router uses) and grouped greedily at `maxWords` 120 exactly as
   `SentenceChunker.chunks` would; a group is **closed** when the next stable sentence would
   overflow it, or when it holds ≥ 15 words and ends a stable sentence (so a 37-word median
   dictation gets one closed group, not zero; the 15 is an estimate to tune from the rows).
2. Each closed group is cleaned in the background at width 1 (never more than one pre-clean in
   flight), through the same Stage B formatter the router would use (Apple, with the guard and
   D-11 salvage). Results are cached keyed by the group's Stage-A text.
3. At key-up the router runs Stage A on the final transcript. If its output begins with the
   concatenation of the closed groups' Stage-A texts (whitespace-normalised), Stage B runs only on
   the remainder, the cached cleaned groups are awaited (bounded by the remaining cleanup budget)
   and joined in order, and Stages C and D run on the **whole** joined text as today. If the prefix
   does not match (a later partial revised an earlier sentence), the whole text is cleaned as today
   and the trace records `precleanFallback`.
4. Only for the Apple engine at first (the production engine here). S1-mini and `.appLLM` are
   unchanged.
5. Release with pre-cleans still in flight: they are awaited (bounded) — never cancelled if their
   group is in the final text.

**Steps:**
1. `actor IncrementalCleanupSession` with `init(semantic: any TextFormatter, rules: @Sendable (String) -> String, maxWords: Int = 120, minClose: Int = 15)`;
   `func notePartial(_ text: String)`; `func head() -> CleanupHead` where
   `struct CleanupHead: Sendable { let rawPrefix: String; let cleaned: [Task<String, Never>] }`.
2. `CleanupRouter.format(_ raw: String, head: CleanupHead?)`; the existing `format(_:)` calls it
   with nil. Inside, after Stage A: prefix check → Stage B on the remainder via the existing
   `semantic` (still a `ChunkedFormatter`) → join → Stage C/D unchanged. `ChunkedFormatter` does
   not need to know about the head.
3. Controller: create the session when `.listening` is reached and `Settings.shared.cleanupEnabled`
   and `preferredEngine == .apple`; in `consumeTask`, `await session.notePartial(chunk.text)` for
   non-final chunks; in the tail, pass `await session.head()` into the formatter through a new
   `activeFormatter(context:trace:head:)` path. Cancel the session on `fail`/`cancelDictation`.
4. Measure: `dictation.speech_to_first_partial` must not get slower (the pre-clean shares the
   machine with Parakeet's partials); check it in the owner rows.

**Do not:**
- Skip Stage C/D on the joined text, or run Stage C only on parts.
- Run more than one pre-clean at a time, or pre-clean during Command Mode or compare mode.
- Inject anything before key-up.
- Loosen the guard for pre-cleaned groups.

**Red-first self-test:**
- `--selftest-cleanup-router`: `incrementalFailures()` — feed an `IncrementalCleanupSession`
  (Stage B = a counting fake that upper-cases) the partial sequence "A one. B two." → "A one. B two.
  C three." → "A one. B two. C three. D four" (with sentences long enough to close groups at
  `minClose: 3`), then `format(final, head:)`: assert the key-up pass called the fake only for the
  tail, and the output equals `format(final, head: nil)` for the same fake. A revised partial
  ("A one. B too. C three.") → `precleanFallback` set and the output equals the full pass.
- `--selftest-dictation` (via-open): `SelfTestEngine.Shape.partials(["…", "…"], every: .milliseconds(300))`
  with a Stage-B fake counted through an injected formatter factory → after release, only the tail
  group is cleaned; the inbox text equals the one-pass result.
Confirm RED: with the `head:` parameter added but ignored, the key-up pass cleans every group.

**Verify:**
```bash
make build && make install OPEN=0
Scripts/run-selftest.sh --selftest-cleanup-router | tail -5
Scripts/run-selftest.sh --via-open --selftest-dictation | tail -8
Scripts/run-selftest.sh --selftest-cleanup apple-grammar | grep -E "CLEANUP_SUMMARY|CLEANUP_(OK|FAILED)"
Scripts/run-selftest.sh --selftest-contention
```

**Success threshold:** both self-tests green (red first). Owner-use (≥ 30 model cleanups after
D-12): key-up → text p50 ≤ 2.0 s and p90 ≤ 4.5 s (T1); `speech_to_first_partial` p50 not more
than 10 % above the Phase C row; `precleanFallback` on ≤ 20 % of eligible holds (estimate; if
higher, raise the stability requirement to three partials).

**Risks & rollback:** Model work during the hold costs power and may slow partials; the owner row
checks it. A revised early sentence wastes one pre-clean (fallback is the old path). Revert to
roll back; add a `Settings` flag only if the owner asks for one.

**Done when:**
- [ ] Stable groups pre-cleaned at width 1; key-up cleans only the tail; Stage C/D on the whole text.
- [ ] Fallback on revision recorded.
- [ ] Both self-tests green (red first); owner-use row recorded.
- [ ] Committed as `D-12: clean finished sentences while the key is still held`.

---

### D-15a — `runs.jsonl`: in-memory append, reload only on edit/delete, opt-in retention
**Finding(s):** I1-17  **Effort:** 3 h  **Depends on:** none  **Unblocks:** none

**Why (what the user experiences today):** Nothing yet; it grows. `RunLog.record` appends a line and
then calls `RunStore.shared.reload()`, which re-parses the whole file on the main actor after every
dictation (`Support/RunLog.swift:115-118`, `Support/RunStore.swift:18-20`). Today 226 rows / 177 KB;
with cleanup records a row is ~1.5 KB, so at 15–40 holds a day this is roughly 10–20 MB a year
(estimate, I1-17), re-read after every hold. `rawText` is kept forever.

**Files you will change:** `Support/RunLog.swift`, `Support/RunStore.swift`, `Support/Settings.swift`
(`dictationHistoryRetention`: `.forever` default, `.days90`, `.rows5000`),
`UI/Settings/DictationSettingsTab.swift` (one picker), new `Support/DictationHygieneSelfTest.swift`,
`NextNotesApp.swift` (register `--selftest-dictation-hygiene`), `AGENTS.md` (flag list),
`Scripts/acceptance.sh` (INTEGRATION).

**Read for context (do not change):** `KnowledgeIndexer.shared.removeDictations` (deletes must
still reach the index); AGENTS.md "A self-test must never call `RunLog.record`".

**Current behaviour:** `record` → `append` → `RunStore.shared.reload()`; `update`/`delete` → `rewrite` → reload.

**Target behaviour:**
1. `record` appends to the file and appends the run to `RunStore.shared.runs` in memory; no file
   re-read. `update`/`delete`/`clear` still rewrite and reload.
2. Retention (off by default): when set, pruning runs at launch and at most once a day, removes
   runs older than 90 days or beyond the newest 5,000, and removes them from the knowledge index
   too.
3. `RunLog` can be pointed at a directory for tests (`@TaskLocal static var directoryOverride: URL?`),
   and the self-test never touches the user's file.

**Steps:** add `RunStore.append(_:)`; change `RunLog.record` to call it; add `directoryOverride`
to `RunLog.directory`; add `RunLog.prune(policy:now:)` (pure selection `static func toPrune(_ runs:, policy:, now:) -> Set<UUID>`
plus the rewrite); call it from `applicationDidFinishLaunching` when the policy is not `.forever`.
The settings picker: "Keep dictation history" — "Forever" / "90 days" / "Last 5,000".

**Do not:** change the default (forever); delete without the setting; write the user's file from
the self-test.

**Red-first self-test:** new `--selftest-dictation-hygiene` (`DictationHygieneSelfTest.run()`;
final marker `DICTATION_HYGIENE_OK` / `DICTATION_HYGIENE_FAILED: <n> problem(s)`), in a temp
directory via `directoryOverride`:
- record 3 runs → `RunStore` holds 3 without a reload (count reloads with a test counter on
  `RunStore`; expect 0 reloads for `record`, 1 for `update`);
- `toPrune` for `.days90` with runs at −100 d, −10 d → the first only; `.rows5000` with 5,002 runs →
  the oldest 2;
- the user's real `runs.jsonl` modification date is unchanged after the run (read it before and
  after; if the file does not exist, skip that check).
Confirm RED: `record` triggers a reload; `toPrune` seam returns empty.

**Verify:**
```bash
make build && make install OPEN=0
Scripts/run-selftest.sh --selftest-dictation-hygiene | tail -3
Scripts/run-selftest.sh --via-open --selftest-dictation | tail -3
Scripts/run-selftest.sh --selftest-settings
Scripts/run-selftest.sh --selftest-ui-strings
```

**Success threshold:** `DICTATION_HYGIENE_OK` (red first); others as in the baseline.

**Risks & rollback:** An in-memory list that diverges from the file if an external edit happens;
the existing file watcher (if any) or the next edit/delete reload corrects it. Revert to roll back.

**Done when:**
- [ ] No full reload on `record`; retention opt-in; deletes reach the index.
- [ ] New flag registered in `NextNotesApp.runRequestedSelfTest`, AGENTS.md flag list, `Scripts/acceptance.sh` (INTEGRATION).
- [ ] Committed as `D-15a: append dictation history in memory and offer a retention limit`.

---

### D-15b — Clipboard restore skipped when the user copied something meanwhile
**Finding(s):** I1-18  **Effort:** 2 h  **Depends on:** D-15a (the self-test flag)  **Unblocks:** none

**Why (what the user experiences today):** The pasteboard path restores the saved clipboard 500 ms
after writing, unconditionally (`TextInjector.insertViaPasteboard` @ `Core/TextInjector.swift:337-364`:
40 ms, ⌘V, 80 ms, then a detached 420 ms and `restore(saved, to: pasteboard)`). If the user copies
something inside that window, their copy is overwritten. The timing is fine (I1-18); the check is
missing.

**Files you will change:** `Core/TextInjector.swift` (`insertViaPasteboard`, `restore` @ :396);
`Support/DictationHygieneSelfTest.swift`.

**Read for context (do not change):** AGENTS.md "Where a dictation goes is decided at key-down"
(the 500 ms restore is part of that story; keep the timing).

**Current behaviour:** quoted above; no `changeCount` check.

**Target behaviour:** remember `pasteboard.changeCount` right after `setString(text, …)`; in the
restore task, restore only if `pasteboard.changeCount` still equals it. Timing unchanged.

**Steps:** make the function testable: `static func insertViaPasteboard(_ text: String, pasteboard: NSPasteboard = .general, postPaste: () -> Void = postCommandV, restoreDelay: Duration = .milliseconds(420)) async`
and return the restore `Task` (discardable) so the test can await it.

**Do not:** change the 40/80/420 ms timings; post ⌘V from a self-test (pass `postPaste: {}`); touch
`NSPasteboard.general` from the self-test (use `NSPasteboard(name: .init("ai.pivotstudio.nextnotes.selftest"))`
and `releaseGlobally()` it at the end).

**Red-first self-test:** in `--selftest-dictation-hygiene`: on a private pasteboard holding "A",
insert "B" with `restoreDelay: 50 ms`; (1) do nothing → after the restore task, the pasteboard reads "A";
(2) repeat, and 10 ms after insertion `setString("C")` → after the restore task it still reads "C".
Confirm RED: case 2 reads "A" today.

**Verify:**
```bash
make build && make install OPEN=0
Scripts/run-selftest.sh --selftest-dictation-hygiene | tail -3
Scripts/run-selftest.sh --via-open --selftest-dictation | tail -3
```

**Success threshold:** `DICTATION_HYGIENE_OK` with both cases (red first).

**Risks & rollback:** None beyond a restore that is now sometimes skipped on purpose. Revert to roll back.

**Done when:**
- [ ] Restore checks `changeCount`; timings unchanged; test green (red first).
- [ ] Committed as `D-15b: never restore the clipboard over something the user just copied`.

---

### D-15c — `--selftest-dictation`'s injected failures stop writing error-level lines into the user's log
**Finding(s):** I1-19 (side note)  **Effort:** 2 h  **Depends on:** D-01b (same seam style)  **Unblocks:** later audits

**Why (what the user experiences today):** Every "transcription did not finish within 2.0 seconds",
"Transcription didn't finish in time" and "still starting up" error line in the 09-23 unified log
(8 + 4 + 4) came from `--selftest-dictation` and its injected 2 s limits
(`DictationController.Limits(...)` @ `NextNotesApp.swift:2812`). They look exactly like production
failures, which made the I1 audit slower and could hide a real one. (AGENT-OVERHAUL P0-11 covers
stores, not logs.)

**Files you will change:** `Core/DictationController.swift` (a `log:` seam used by `fail` and the
tail's error lines); `NextNotesApp.swift` (`runDictationSelfTest` passes a self-test logger).

**Target behaviour:** under `--selftest-dictation`, the controller's error lines are written at
`.info` level in a separate category `selftest` (subsystem unchanged), prefixed `[selftest]`.
Production logging is unchanged.

**Steps:** `struct DictationLogger: Sendable { var error: @Sendable (String) -> Void }` with
`.production` (today's `Log.app.error` / `Log.speech.error`) and `.selfTest` (a `Logger(subsystem: "ai.pivotstudio.nextnotes", category: "selftest")`
at info with the prefix). Inject through `init` next to `record:`. Replace the direct
`Log.app.error` in `fail` (:1335) and the three `Log.speech.error` lines in the tail with it.
This is a seam passed by the test, not a `SelfTest.isRunning` branch in production logic.

**Do not:** silence production errors; branch on `SelfTest.isRunning` inside the controller.

**Red-first self-test:** after `--selftest-dictation` completes, the check is a shell assertion
(the flag cannot read the unified log reliably from inside itself):
```bash
Scripts/run-selftest.sh --via-open --selftest-dictation | tail -2
/usr/bin/log show --last 3m --predicate 'subsystem == "ai.pivotstudio.nextnotes" AND messageType == error' \
  | grep -cE "did not finish within|didn.t finish in time|still starting up"      # must print 0
/usr/bin/log show --last 3m --info --predicate 'subsystem == "ai.pivotstudio.nextnotes" AND category == "selftest"' \
  | grep -c "\[selftest\]"                                                          # must be > 0
```
Confirm RED: before the change, the first count is > 0 and the second 0. Record both counts in
`STATUS.md`.

**Verify:** the commands above, then `Scripts/run-selftest.sh --selftest-commandkey`.

**Success threshold:** first count 0, second > 0; `DICTATION_OK`.

**Risks & rollback:** None for production. Revert to roll back.

**Done when:**
- [ ] Self-test failures log under `selftest` at info; production unchanged.
- [ ] Counts recorded; committed as `D-15c: keep dictation self-test failures out of the error log`.

---

### D-16 — Spike: vocabulary boosting for Parakeet (FluidAudio), and title-derived context for Terminal
**Finding(s):** I1-26 (note), I1-14  **Effort:** 1 day (spike, no product code)  **Depends on:** none  **Unblocks:** a later task, if the spike says so

**Why (what the user experiences today):** On this Mac the engine is Parakeet, which takes no
contextual strings, so dictionary **terms** ("ProductFlo.io") do nothing; only `X -> Y`
corrections apply after the fact (I1-26). And the screen-name harvest has adapters only for Cursor,
Windsurf and VS Code (`Context/AXAppAdapters.swift:44-75`), while this Mac's targets were Terminal
19×, Claude 19×, Muse 4×, Chrome 3× (zero Cursor runs since 09-20): `dictation.names` is 0.00 s on
all 15 metric holds.

**Files you will change:** none in `Sources/`. Write
`Tests/Reports/DICTATION-VOCAB-SPIKE-<YYYY-MM-DD>.md`. A throwaway measurement harness, if you need
one, goes under `~/Library/Caches/NextNotesBuild/dictation-meetings/spike/` and is not committed.

**Read for context:** the FluidAudio checkout (`~/Library/Caches/NextNotesBuild/scratch/checkouts/FluidAudio/Sources/FluidAudio/`):
`ASR/Parakeet/SlidingWindow/SlidingWindowAsrManager.swift:92` `configureVocabularyBoosting(vocabulary: CustomVocabularyContext, …)`,
`ASR/Parakeet/Unified/StreamingUnifiedAsrManager.swift:223` (same API; its doc mentions
`CustomVocabularyContext.loadWithCtcTokens`), `ContextBiasingConstants.largeVocabThreshold`.
The app uses the batch `AsrManager.transcribe(samples, decoderState:)` (`ParakeetEngine.finish`).
AGENTS.md screen-name entry and `--selftest-axreadback` (Terminal exposes no text to AX).

**The spike answers, in the report:**
1. Does vocabulary boosting apply to the TDT batch path the app uses, or only to the sliding-window /
   unified streaming managers? What extra model (CTC head?) and download size does it need, and
   under what licence?
2. With a 10-term list from `dictionary.txt` terms, on 5 generated fixtures that say those terms
   (`say -v Samantha -o …` + `afconvert -f WAVE -d LEI16@16000 …`), what are the term hit rates
   with and without boosting, and the latency cost per 10 s of audio?
3. Terminal: does `AXTitle` of the front Terminal window carry the working directory on this Mac
   (read it once with a throwaway script; Terminal's default title includes the directory)? How
   many dictations into Terminal in `runs.jsonl` mention a file name (grep the `text` field for
   common extensions)?
4. Recommendation: build, or not, with the numbers.

**Do not:** add a dependency or change `Package.swift`; download models larger than the free disk
allows (≈ 3–4 GB free on this Mac; check `df -h /` first).

**Red-first self-test:** none (spike). The report is the deliverable.

**Verify:** the report exists and states the four answers with numbers.

**Success threshold:** a decision backed by measured hit rates, or a `BLOCKED` note saying what
was missing (for example, the CTC model is too large for the disk).

**Risks & rollback:** none; no product code.

**Done when:**
- [ ] `Tests/Reports/DICTATION-VOCAB-SPIKE-<date>.md` committed as `D-16: vocabulary boosting and Terminal context spike`.

---

### D-13 — Pipelined holds (only if D-01b shows refused presses)
**Finding(s):** I1-12  **Effort:** 2 days  **Depends on:** D-01b (evidence), D-02  **Unblocks:** none

**Evidence gate — check before writing any code.** Run
`python3 Scripts/dictation-stats.py --since <D-01b commit date>` after at least 7 days and 100
owner holds. Proceed only if `press_refused` in state `finishing` is **≥ 3 per 100 holds**
(estimate of "material"). Otherwise set the row to `won't do (evidence)` with the numbers and stop.

**Why (what the user experiences today):** `.finishing` is active, and `beginDictation` returns
silently for a press during the 5–12 s tail (`guard case .idle` @ `DictationController.swift:622`;
`endDictation`'s `guard state.isActive, state != .finishing` @ :905). A user who starts the next
thought at once loses it. The AGENTS.md paragraph "Every await in the dictation tail has a
deadline" describes why `.finishing` must stay bounded; it does not require it to refuse presses.

**Files you will change:** `Core/DictationController.swift` (a second slot set, or a queue of one
pending hold); `NextNotesApp.swift` (`runDictationSelfTest`).

**Target behaviour:** a press during `.finishing` starts capturing at once into D-02's pre-roll
for a **queued** hold; its engine starts once the previous tail has released the engine; its text
is injected after the previous hold's text, in order, into its own key-down origin. At most one
queued hold. Every `withBoundedWait` still applies to both.

**Steps:** make the per-hold slots a struct (`HoldSlots`: engine, consumeTask, feedTask,
audioContinuation, session, origin, holdID) and keep `current` and `queued`; `session` guards
remain per slot; the tail's last step promotes `queued` to `current`. Injection order via a
serial `injectionQueue` actor.

**Do not:** allow more than one queued hold; remove any deadline; share an engine instance
between two holds; weaken the session guard (AGENTS.md "`DictationController.session` is not a
counter").

**Red-first self-test:** `--selftest-dictation`: two holds 1 s apart with a Stage-B fake that takes
1.5 s → the inbox holds both transcripts, in order; D-01b shows two `.inserted` rows and no
`press_refused`. Confirm RED: today the second press is refused.

**Verify:**
```bash
make build && make install OPEN=0
Scripts/run-selftest.sh --via-open --selftest-dictation | tail -8
Scripts/run-selftest.sh --selftest-commandkey
make acceptance TIER=core
```

**Success threshold:** `DICTATION_OK` with the new case (red first); no CORE regression;
owner-use: `press_refused` in `finishing` drops to 0.

**Risks & rollback:** This is the most invasive controller change; if any existing
`--selftest-dictation` case flakes, revert. Update the AGENTS.md "session" paragraph to describe
two slot sets.

**Done when:**
- [ ] Evidence recorded; if built: one queued hold, ordered injection, all deadlines kept, AGENTS.md updated.
- [ ] Committed as `D-13: let the next dictation start while the last one is still being tidied`.

---

### D-14 — Per-pass `.realtimeASR` acquisition for dictation (only if the rows show contention)
**Finding(s):** I1-15  **Effort:** 0.5 day  **Depends on:** AGENT-OVERHAUL P0-06 (done: `ComputeScheduler.acquireCancellable` @ `Core/Compute/ComputeScheduler.swift:167`), D-01b, AGENT-OVERHAUL P0-20b (`meeting.transcribe` rows). Coordinate: AGENT-OVERHAUL P3-07a (capacity lanes) — if it has landed, re-read the lane model first.  **Unblocks:** none

**Evidence gate — check before writing any code.** Proceed only if the usage rows show a dictation
hold overlapping a recorded meeting's transcription with the meeting's window wait ≥ 5 s, or a
dictation start waiting ≥ 1 s on the lane (from P0-20b/P0-20c timing fields), at least 3 times.
Otherwise `won't do (evidence)`. I1 found "dropped window" ×0 in the retained log.

**Why:** `ParakeetEngine.start()` acquires `.realtimeASR` and releases it in `finish()`
(`ParakeetEngine.swift:87`, `:251`) — the whole hold, including a 98 s one. Meeting windows take
the same class (`Meetings/ChunkedTranscriber.swift:402`), equal priority does not preempt, so a
dictation during a recorded meeting delays that meeting's windows by the length of the hold.

**Files you will change:** `Transcription/ParakeetEngine.swift` (acquire around each partial and
final `transcribe`, not around the hold); `Support/ContentionSelfTests.swift`.

**Target behaviour:** the lane is held only while Parakeet is actually running a pass; between
passes a meeting window can run. A `.background` job (notes) still parks at its next checkpoint
whenever a dictation pass acquires.

**Do not:** change the lane priorities or `ComputeScheduler` semantics (P3-07a owns that); drop
the lane for Apple's engine path (controller-owned, unchanged).

**Red-first self-test:** `--selftest-contention` (final marker `CONTENTION_OK` /
`CONTENTION_FAILED`): a fake dictation hold of 3 s with passes at 0, 1, 2 s (100 ms each) and a
meeting window requested at 0.5 s → the window acquires within 0.7 s, not after 3 s. Confirm RED on
the current hold-long acquisition.

**Verify:**
```bash
make build && make install OPEN=0
Scripts/run-selftest.sh --selftest-contention | tail -3
Scripts/run-selftest.sh --via-open --selftest-dictation | tail -3
Scripts/run-selftest.sh --selftest-parakeet | tail -2
```

**Success threshold:** `CONTENTION_OK` with the new case (red first); dictation and Parakeet
unchanged.

**Risks & rollback:** More lane churn; partial latency could rise if a meeting window is mid-pass.
Revert to roll back.

**Done when:**
- [ ] Evidence recorded; if built: per-pass acquisition, test green (red first).
- [ ] Committed as `D-14: hold the speech lane only while a dictation pass runs`.
