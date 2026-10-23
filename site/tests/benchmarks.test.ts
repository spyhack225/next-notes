import { test } from "node:test";
import assert from "node:assert/strict";
import {
  acceptedValue,
  comparison,
  filterRuns,
  runs,
  type Run,
} from "../src/benchmarks/model.ts";

test("speech comparison uses all eight actual app results and preserves English-only gaps", () => {
  const en = comparison("speech", "en", "final");
  assert.equal(en.entries.length, 8);
  assert.equal(en.entries.filter((e) => e.value !== null).length, 8);
  assert.equal(
    en.entries.find((e) => e.id === "phonon")?.value,
    5.254708288703114,
  );
  const fr = comparison("speech", "fr", "final");
  assert.equal(fr.entries.find((e) => e.id === "phonon")?.value, null);
  assert.equal(fr.entries.find((e) => e.id === "phonon")?.note, "English only");
});
test("physical speaker cohorts do not silently combine accepted values across volume/route", () => {
  const serial = comparison("voice", "en", "serial");
  assert.deepEqual(
    serial.entries
      .filter((e) => e.value !== null)
      .map((e) => e.id)
      .sort(),
    ["phonon", "pocket"],
  );
  const calibrated = comparison("voice", "en", "calibrated");
  assert.deepEqual(
    calibrated.entries.filter((e) => e.value !== null).map((e) => e.id),
    ["apple"],
  );
  assert.equal(calibrated.entries.find((e) => e.id === "qwen")?.value, null);
});
test("failure and survivor-only medians cannot enter a ranked comparison", () => {
  const run = {
    status: "measured",
    metrics: [
      { name: "timing", value: 10 },
      { name: "Attempted warm microphone trials", value: 30 },
      { name: "Qualified warm microphone trials", value: 27 },
    ],
  } as Run;
  assert.equal(acceptedValue(run, "timing", true), null);
  assert.equal(acceptedValue({ ...run, status: "failed" }, "timing"), null);
  assert.equal(acceptedValue({ ...run, status: "blocked" }, "timing"), null);
  assert.equal(acceptedValue(run, "missing"), null);
  assert.equal(acceptedValue(undefined, "timing"), null);
});
test("real zero is retained, and variable historical configurations remain unranked", () => {
  const c = comparison("cleanup", "en", "quality");
  assert.equal(c.entries.find((e) => e.id === "apple")?.value, 0);
  assert.equal(c.entries.find((e) => e.id === "gemma")?.value, null);
});
test("index filters combine and keep stable ordering and whitespace handling", () => {
  const result = filterRuns(runs, "asr", "measured", "  phonon  ", "newest");
  assert.ok(result.length > 0);
  assert.ok(
    result.every((r) => r.category === "asr" && r.status === "measured"),
  );
  assert.equal(
    filterRuns(runs, "all", "all", "no-such-fixture-928", "newest").length,
    0,
  );
  assert.deepEqual(
    filterRuns(runs, "all", "all", "", "name").map((r) => r.id),
    filterRuns([...runs].reverse(), "all", "all", "", "name").map((r) => r.id),
  );
});

test("unit mismatches and incomplete acoustic sample counts cannot be ranked", () => {
  const run = {
    status: "measured",
    metrics: [
      { name: "timing", value: 1, unit: "s", samples: 30 },
      { name: "Attempted warm microphone trials", value: 30 },
      { name: "Qualified warm microphone trials", value: 30 },
    ],
  } as Run;
  assert.equal(acceptedValue(run, "timing", false, "ms"), null);
  assert.equal(acceptedValue(run, "timing", true, "s"), 1);
  assert.equal(
    acceptedValue(
      {
        ...run,
        metrics: run.metrics.map((m) =>
          m.name === "timing" ? { ...m, samples: 29 } : m,
        ),
      },
      "timing",
      true,
      "s",
    ),
    null,
  );
});

test("earlier word-error charts use their own runtime records rather than app latency", () => {
  const c = comparison("speech", "fr", "errors");
  assert.equal(c.unit, "%");
  assert.ok(c.entries.every((e) => !e.run?.id.includes("signed-app")));
  assert.equal(c.entries.find((e) => e.id === "phonon")?.value, null);
  assert.ok(
    c.entries.filter((e) => e.value !== null).every((e) => e.value! > 0),
  );
});
test("historical tool-selection latency has four matching fixture records", () => {
  const c = comparison("decisions", "en", "time");
  assert.equal(c.entries.length, 4);
  assert.ok(c.entries.every((e) => e.value !== null));
  assert.equal(c.entries.find((e) => e.id === "needle-serve")?.value, 277);
});
