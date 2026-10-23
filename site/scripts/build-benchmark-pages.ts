/** Emit only reviewed public catalog data, never read original/private reports. */
import { readFileSync, writeFileSync, mkdirSync, rmSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { resolve } from "node:path";
import {
  runs,
  displayTitle,
  statusLabels,
  type Report,
} from "../src/benchmarks/model.ts";
import {
  metadata,
  jsonLD,
  origin,
  benchmarkPath,
  reportPath,
} from "../src/benchmarks/seo.ts";
const root = fileURLToPath(new URL("../../", import.meta.url));
const output = resolve(root, "docs");
// Root-absolute entry assets also let the host's SPA fallback load at an unknown nested URL.
const template = readFileSync(resolve(output, "index.html"), "utf8").replace(/((?:src|href)=")\.\//g, '$1/');
writeFileSync(resolve(output, "index.html"), template);
const escape = (s: unknown) =>
  String(s).replace(
    /[&<>"']/g,
    (c) =>
      ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[
        c
      ]!,
  );
const paragraphs = (items: string[]) =>
  items.map((t) => `<p>${escape(t)}</p>`).join("");
function render(run?: (typeof runs)[number]) {
  const data = metadata(run);
  let html = template
    .replace(/<title>[\s\S]*?<\/title>/, `<title>${escape(data.title)}</title>`)
    .replace(
      /<meta\s+(?:name="(?:description|robots|twitter:title|twitter:description)"|property="(?:og:title|og:description|og:url|og:type)")[^>]*>/g,
      "",
    )
    .replace(/<link rel="canonical"[^>]*>/g, "")
    .replace(/<script type="application\/ld\+json">[\s\S]*?<\/script>/g, "")
    .replace(/((?:src|href)=")\.\//g, "$1/");
  html = html.replace(
    "</head>",
    `<link rel="canonical" href="${data.url}" />
<meta name="description" content="${escape(data.description)}" />
<meta name="robots" content="${data.robots}" />
<meta property="og:title" content="${escape(data.title)}" />
<meta property="og:description" content="${escape(data.description)}" />
<meta property="og:url" content="${data.url}" />
<meta property="og:type" content="${run ? "article" : "website"}" />
<meta name="twitter:title" content="${escape(data.title)}" />
<meta name="twitter:description" content="${escape(data.description)}" />
<script type="application/ld+json">${jsonLD(data.schema)}</script></head>`,
  );
  let content =
    '<nav><a href="/">Next Notes</a> / <a href="/benchmarks/">Benchmarks</a></nav>';
  if (run) {
    const report: Report = JSON.parse(
      readFileSync(
        resolve(root, `site/src/generated/benchmark-reports/${run.id}.json`),
        "utf8",
      ),
    );
    content += `<h1>${escape(displayTitle(run))}</h1><p>${escape(run.date)} · ${escape(statusLabels[run.status])}</p><p>${escape(run.summary)}</p><h2>Findings</h2>${paragraphs(report.findings)}<h2>Measurements</h2><ul>${run.metrics.map((m) => `<li>${escape(m.name)}: ${escape(m.value)} ${escape(m.unit)}. ${escape(m.boundary)}; samples: ${escape(m.samples ?? "not recorded")}; ${escape(m.aggregation)}.</li>`).join("")}</ul><h2>Why and how we tested</h2><p>${escape(report.purpose)}</p><p>${escape(run.scope)}</p>${paragraphs(report.method)}<ul>${Object.entries(
      run.environment,
    )
      .map(([k, v]) => `<li>${escape(k)}: ${escape(v)}</li>`)
      .join(
        "",
      )}</ul>${report.reproduction.map((r) => `<p>${escape(r.label)}: ${escape(r.value)}</p>`).join("")}<h2>Limitations</h2>${paragraphs(run.limitations)}${paragraphs(report.next_steps)}<h2>Original evidence</h2><ul>${report.source_links.map((s) => `<li><a href="https://github.com/spyhack225/next-notes/blob/main/${s.path.split("/").map(encodeURIComponent).join("/")}">${escape(s.label)}</a></li>`).join("")}</ul>`;
  } else {
    content += `<h1>Benchmarks. The whole story.</h1><p>${escape(data.description)}</p><p>Measured results apply to the stated scope, not whole-app acceptance. Partial, failed, blocked and unrun results retain their actual verdicts.</p><h2>Published reports</h2><ul>${runs.map((r) => `<li><a href="${reportPath(r.id)}">${escape(displayTitle(r))}</a> — ${escape(r.date)} · ${escape(statusLabels[r.status])}<p>${escape(r.summary)}</p></li>`).join("")}</ul><h2 id="methodology">Our method</h2><p>Each report records its measurement boundary, environment, sample counts, method, limitations and reviewed evidence. Compare results only within compatible workflows and measurement boundaries.</p>`;
  }
  html = html.replace(
    /<div id="root">[\s\S]*?<\/div>\s*(?=<\/body>)/,
    `<div id="root"><main class="static-fallback">${content}</main></div>\n`,
  );
  // Vite puts its module script in the head; assert fallback replacement was effective.
  if (!html.includes(content))
    throw new Error("Root template changed; refusing homepage fallback");
  const directory = resolve(
    output,
    run ? reportPath(run.id).slice(1) : benchmarkPath.slice(1),
  );
  mkdirSync(directory, { recursive: true });
  writeFileSync(resolve(directory, "index.html"), html.replace(/[ \t]+$/gm, ""));
}
// This directory is exclusively generated. Revoked publications must disappear.
rmSync(resolve(output, "benchmarks"), { recursive: true, force: true });
render();
for (const run of runs) render(run);
const urls = [
  origin + "/",
  origin + benchmarkPath,
  ...runs.map((r) => origin + reportPath(r.id)),
];
writeFileSync(
  resolve(output, "sitemap.xml"),
  `<?xml version="1.0" encoding="UTF-8"?>\n<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">\n${urls.map((url) => `  <url><loc>${escape(url)}</loc></url>`).join("\n")}\n</urlset>\n`,
);
console.log(
  `SEO: emitted benchmark index, ${runs.length} reports and ${urls.length} sitemap URLs`,
);
