import { useEffect, useState } from "react";
import {
  ArrowLeft,
  ArrowUpRight,
  Download,
  Link as LinkIcon,
} from "lucide-react";
import {
  areas,
  date,
  displayTitle,
  comparisonHref,
  number,
  runHref,
  runs,
  statusLabels,
  statusMeaning,
  type Report as ReportData,
  type Run,
} from "./model";
import { download } from "./Comparison";
import { REPO_URL } from "../lib/motion";
const loaders = import.meta.glob<ReportData>(
  "../generated/benchmark-reports/*.json",
  { import: "default" },
);
function sourceURL(path: string) {
  return `${REPO_URL}/blob/main/${path.split("/").map(encodeURIComponent).join("/")}`;
}
export default function Report({ run, back }: { run: Run; back: string }) {
  const [report, setReport] = useState<ReportData | null>(null);
  const [error, setError] = useState(false);
  const [copied, setCopied] = useState("");
  useEffect(() => {
    let cancelled = false;
    const loader = loaders[`../generated/benchmark-reports/${run.id}.json`];
    Promise.resolve()
      .then(() => {
        if (!loader) throw new Error("Unavailable report");
        return loader();
      })
      .then((value) => {
        if (value.id !== run.id) throw new Error("Report identity mismatch");
        if (!cancelled) {
          setReport(value);
          setError(false);
        }
      })
      .catch(() => {
        if (!cancelled) setError(true);
      });
    return () => {
      cancelled = true;
    };
  }, [run.id]);
  useEffect(() => {
    const id = window.location.hash.slice(1);
    if (
      report &&
      ["findings", "measurements", "method", "limits", "evidence"].includes(id)
    ) {
      document.getElementById(id)?.scrollIntoView({ behavior: "instant" });
    }
  }, [report]);
  async function copyLink() {
    try {
      await navigator.clipboard.writeText(window.location.href);
      setCopied("Link copied.");
    } catch {
      setCopied("Copy the address from your browser to share this report.");
    }
  }
  const related = runs
    .filter((r) => r.category === run.category && r.id !== run.id)
    .slice(0, 3);
  return (
    <>
      <a className="bench-back" href={back} data-bench="">
        <ArrowLeft size={16} /> All benchmarks
      </a>
      <header className="bench-report-header">
        <div className="bench-meta">
          <span>{areas[run.category]}</span>
          <span> / </span>
          <time dateTime={run.date}>{date(run.date)}</time>
          <span className="bench-status" title={statusMeaning[run.status]}>
            {statusLabels[run.status]}
          </span>
        </div>
        <h1 id="benchmark-title" tabIndex={-1}>
          {displayTitle(run)}
        </h1>
        <p>{run.summary}</p>
        <div className="bench-report-actions">
          <button onClick={copyLink}>
            <LinkIcon size={15} /> Copy report link
          </button>
          <button
            onClick={() => download({ ...run, report }, `${run.id}.json`)}
          >
            <Download size={15} /> Download reviewed result
          </button>
          <span role="status">{copied}</span>
        </div>
      </header>
      <nav className="bench-report-nav" aria-label="Report sections">
        <a href="#findings">Findings</a>
        <a href="#measurements">Measurements</a>
        <a href="#method">Method & conditions</a>
        <a href="#limits">Limitations</a>
        <a href="#evidence">Evidence</a>
      </nav>
      <div className="bench-report-layout">
        <article className="bench-report-body">
          {!report && (
            <div className="bench-load-message" role="status">
              {error ? (
                <>
                  <p>
                    The report narrative could not load. Its registered
                    measurements and conditions are still available below.
                  </p>
                  <button onClick={() => window.location.reload()}>
                    Reload this report
                  </button>
                </>
              ) : (
                <p>Loading report narrative…</p>
              )}
            </div>
          )}
          <section id="findings">
            <h2>What we learned</h2>
            {(report?.findings ?? [run.summary]).map((p, i) => (
              <p key={i}>{p}</p>
            ))}
            <p className="bench-scope-note">
              <strong>Evidence status: {statusLabels[run.status]}.</strong>{" "}
              {statusMeaning[run.status]}
            </p>
          </section>
          <section id="measurements">
            <h2>The measurements</h2>
            {run.metrics.length === 0 ? (
              <div className="bench-empty">
                <h3>No accepted measurements</h3>
                <p>
                  This {statusLabels[run.status].toLowerCase()} result records a
                  limit or an unavailable test. It is not a score of zero.
                </p>
              </div>
            ) : (
              <div>
                {run.metrics.map((m, i) => (
                  <div className="bench-measurement" key={`${m.name}-${i}`}>
                    <div>
                      <span className="bench-metric-value">
                        {number(m.value)} <span>{m.unit}</span>
                      </span>
                      <span className="bench-muted">
                        {m.samples === null
                          ? "Sample count unknown"
                          : `${m.samples} ${m.samples === 1 ? "sample" : "samples"}`}{" "}
                        · {m.aggregation}
                      </span>
                    </div>
                    <div>
                      <h3>{m.name}</h3>
                      <p>{m.boundary}</p>
                    </div>
                  </div>
                ))}
              </div>
            )}
          </section>
          <section id="method">
            <h2>Why measure this?</h2>
            <p>{report?.purpose ?? run.scope}</p>
            <h3>How we tested</h3>
            {(report?.method ?? [run.scope]).map((p, i) => (
              <p key={i}>{p}</p>
            ))}
            <h3>Test conditions</h3>
            <dl className="bench-facts">
              {Object.entries(run.environment).map(([key, value]) => (
                <div key={key}>
                  <dt>{key.replaceAll("_", " ")}</dt>
                  <dd>{value}</dd>
                </div>
              ))}
            </dl>
            {report && report.reproduction.length > 0 && (
              <>
                <h3>Reproducibility</h3>
                <dl className="bench-facts">
                  {report.reproduction.map((x) => (
                    <div key={x.label}>
                      <dt>{x.label}</dt>
                      <dd>{x.value}</dd>
                    </div>
                  ))}
                </dl>
              </>
            )}
          </section>
          <section id="limits">
            <h2>What this does not establish</h2>
            {run.limitations.length > 0 ? (
              <ul>
                {run.limitations.map((p, i) => (
                  <li key={i}>{p}</li>
                ))}
              </ul>
            ) : (
              <p>
                No additional limitations were registered. Read the stated scope
                and test conditions before generalizing this result.
              </p>
            )}
            {report && report.next_steps.length > 0 && (
              <>
                <h3>What comes next</h3>
                <ul>
                  {report.next_steps.map((p, i) => (
                    <li key={i}>{p}</li>
                  ))}
                </ul>
              </>
            )}
          </section>
          <section id="evidence">
            <h2>Follow the evidence</h2>
            <p>
              This is the reviewed public report. Measurements, method,
              conditions and limits are presented here; original recordings and
              private diagnostics are not loaded.
            </p>
            {report && report.source_links.length > 0 ? (
              <ul className="bench-evidence-links">
                {report.source_links.map((x) => (
                  <li key={x.path}>
                    <a
                      href={sourceURL(x.path)}
                      target="_blank"
                      rel="noreferrer"
                    >
                      {x.label} <ArrowUpRight size={14} />
                      <span className="bench-muted">
                        {" "}
                        GitHub · original source
                      </span>
                    </a>
                  </li>
                ))}
              </ul>
            ) : (
              <p>
                The original evidence is indexed in the repository. No raw
                report has been imported automatically.
              </p>
            )}
            <a
              className="bench-secondary-link"
              href={`${REPO_URL}/blob/main/Benchmarks/runs/${run.id}.json`}
              target="_blank"
              rel="noreferrer"
            >
              View the registered source record on GitHub{" "}
              <ArrowUpRight size={14} />
            </a>
          </section>
        </article>
        <aside className="bench-report-aside">
          {comparisonHref(run) && (
            <>
              <h2>Compare this result</h2>
              <a href={comparisonHref(run)!} data-bench="">
                Open its matching comparison <ArrowUpRight size={14} />
              </a>
            </>
          )}
          <h2>Reading this result</h2>
          <p>{run.scope}</p>
          <a href="?page=benchmarks#methodology" data-bench="">
            How we interpret benchmarks <ArrowUpRight size={14} />
          </a>
          {related.length > 0 && (
            <>
              <h2>More in {areas[run.category]?.toLowerCase()}</h2>
              {related.map((r) => (
                <a
                  className="bench-related"
                  key={r.id}
                  href={runHref(r.id)}
                  data-bench=""
                >
                  <span>{displayTitle(r)}</span>
                  <span className="bench-muted">
                    {date(r.date)} · {statusLabels[r.status]}
                  </span>
                </a>
              ))}
            </>
          )}
        </aside>
      </div>
    </>
  );
}
