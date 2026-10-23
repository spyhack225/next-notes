import { test } from "node:test";
import assert from "node:assert/strict";
import {
  metadata,
  reportId,
  reportPath,
  jsonLD,
} from "../src/benchmarks/seo.ts";
import { runs } from "../src/benchmarks/model.ts";
test("index schema lists exactly the reviewed public reports with canonical URLs", () => {
  const data = metadata();
  assert.equal(data.url, "https://next-notes.com/benchmarks/");
  const list = data.schema["@graph"].find((n) => n["@type"] === "ItemList")!;
  assert.equal(list.numberOfItems, runs.length);
  assert.equal(
    new Set((list.itemListElement as { url: string }[]).map((n) => n.url)).size,
    runs.length,
  );
  assert.ok(!jsonLD(data.schema).includes("voice-turn-smartturn"));
});
test("each report has unique metadata, scoped Report schema and breadcrumbs", () => {
  for (const run of runs) {
    const data = metadata(run);
    assert.equal(data.url, "https://next-notes.com" + reportPath(run.id));
    assert.ok(data.description.includes(run.summary));
    const report = data.schema["@graph"].find((n) => n["@type"] === "Report")!;
    assert.equal(report.reportNumber, run.id);
    assert.equal(report.abstract, run.scope);
    assert.ok(!("aggregateRating" in report));
    assert.ok(!("datePublished" in report));
    const crumbs = data.schema["@graph"].find(
      (n) => n["@type"] === "BreadcrumbList",
    )!;
    assert.equal((crumbs.itemListElement as unknown[]).length, 3);
  }
});
test("canonical paths, legacy query/hash and unavailable report routing", () => {
  const run = runs[0];
  for (const path of [
    reportPath(run.id),
    "/?page=benchmarks&run=" + run.id,
    "/?page=benchmarks#" + run.id,
  ])
    assert.equal(reportId(new URL(path, "https://next-notes.com")), run.id);
  assert.equal(
    reportId(new URL("/benchmarks/", "https://next-notes.com")),
    null,
  );
  assert.equal(
    reportId(new URL("/benchmarks/%xx/", "https://next-notes.com")),
    "__invalid__",
  );
  assert.equal(metadata(undefined, true).robots, "noindex, follow");
  assert.deepEqual(metadata(undefined, true).schema["@graph"], []);
});
test("JSON-LD cannot terminate its script container", () => {
  const payload = { text: "</script><script>alert(1)</script>\u2028\u2029" };
  const serialized = jsonLD(payload);
  assert.ok(!serialized.includes("<"));
  assert.deepEqual(JSON.parse(serialized), payload);
});
