import assert from "node:assert/strict";
import { readFileSync, readdirSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { resolve } from "node:path";
import { runs } from "../src/benchmarks/model.ts";
import { metadata, reportPath } from "../src/benchmarks/seo.ts";
const root = fileURLToPath(new URL("../../docs/", import.meta.url));
for (const run of [undefined, ...runs]) {
  const data = metadata(run);
  const path = run ? reportPath(run.id) : "/benchmarks/";
  const html = readFileSync(resolve(root, "." + path, "index.html"), "utf8");
  assert.ok(html.includes(`<link rel="canonical" href="${data.url}"`), path);
  assert.equal((html.match(/rel="canonical"/g) || []).length, 1, path);
  assert.equal((html.match(/name="description"/g) || []).length, 1, path);
  assert.ok(html.includes('name="robots" content="index, follow"'), path);
  const schemas = [
    ...html.matchAll(
      /<script type="application\/ld\+json">([\s\S]*?)<\/script>/g,
    ),
  ];
  assert.equal(schemas.length, 1, path);
  assert.deepEqual(JSON.parse(schemas[0][1]), data.schema, path);
  assert.ok(!html.includes('"@type": "SoftwareApplication"'), path);
  assert.ok(html.includes('<main class="static-fallback"><nav>'), path);
  assert.ok(!html.includes('src="./assets/'), path);
  for (const asset of html.matchAll(/(?:src|href)="(\/assets\/[^"]+)"/g))
    readFileSync(resolve(root, "." + asset[1]));
  if (run)
    assert.ok(
      html.includes(run.id) ||
        html.includes(
          run.summary
            .replace(/&/g, "&amp;")
            .replace(/</g, "&lt;")
            .replace(/>/g, "&gt;")
            .replace(/"/g, "&quot;")
            .replace(/'/g, "&#39;"),
        ),
      path,
    );
}
assert.deepEqual(
  readdirSync(resolve(root, "benchmarks"))
    .filter((p) => p !== "index.html")
    .sort(),
  runs.map((r) => r.id).sort(),
);
const sitemap = readFileSync(resolve(root, "sitemap.xml"), "utf8");
assert.equal((sitemap.match(/<loc>/g) || []).length, runs.length + 2);
for (const run of runs) assert.ok(sitemap.includes(metadata(run).url));
assert.ok(!/<loc>[^<]*[?#]/.test(sitemap));
assert.ok(!sitemap.includes("#"));
console.log(
  `SEO_OUTPUT_OK: ${runs.length + 1} static pages, unique metadata/schema, matching fallback, assets and sitemap`,
);
