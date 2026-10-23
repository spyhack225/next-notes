import { applyMetadata, reportId } from "./benchmarks/seo";
import { useEffect, useState, type MouseEvent } from "react";
import {
  ArrowDown,
  ArrowLeft,
  ArrowRight,
  ArrowUpRight,
  Search,
} from "lucide-react";
import { MotionConfig, motion } from "framer-motion";
import Orb from "./components/Orb";
import { DOWNLOAD_URL, REPO_URL } from "./lib/motion";
import Comparison from "./benchmarks/Comparison";
import Report from "./benchmarks/Report";
import {
  areas,
  date,
  displayTitle,
  primaryMetric,
  filterRuns,
  number,
  runs,
  runHref,
  statusLabels,
  statusMeaning,
} from "./benchmarks/model";

const valid = (value: string | null, options: string[], fallback: string) =>
  value && options.includes(value) ? value : fallback;
function readURL() {
  return new URL(window.location.href);
}
export default function Benchmarks() {
  const [location, setLocation] = useState(readURL);
  useEffect(() => {
    const refresh = () => setLocation(readURL());
    window.addEventListener("popstate", refresh);
    window.addEventListener("hashchange", refresh);
    return () => {
      window.removeEventListener("popstate", refresh);
      window.removeEventListener("hashchange", refresh);
    };
  }, []);
  const params = location.searchParams;
  const group = valid(
    params.get("compare"),
    ["speech", "voice", "cleanup", "decisions"],
    "speech",
  );
  const measure = valid(
    params.get("measure"),
    group === "speech"
      ? ["final", "first", "errors"]
      : group === "voice"
        ? ["generated", "serial", "calibrated"]
        : group === "decisions"
          ? ["time"]
          : ["time", "quality"],
    group === "speech" ? "final" : group === "voice" ? "generated" : "time",
  );
  const language = valid(params.get("language"), ["en", "fr"], "en");
  const chart = ["cleanup", "decisions"].includes(group)
    ? "bars"
    : valid(params.get("chart"), ["bars", "scatter"], "bars");
  const area = valid(params.get("area"), Object.keys(areas), "all");
  const status = valid(
    params.get("status"),
    ["all", ...Object.keys(statusLabels)],
    "all",
  );
  const order = valid(
    params.get("order"),
    ["newest", "oldest", "name"],
    "newest",
  );
  const query = (params.get("q") ?? "").slice(0, 200);
  const runId = reportId(location);
  const run = runs.find((r) => r.id === runId);
  const filtered = filterRuns(runs, area, status, query, order);
  const pages = Math.max(1, Math.ceil(filtered.length / 12));
  const page = Math.min(
    pages,
    Math.max(1, Number.parseInt(params.get("p") ?? "1", 10) || 1),
  );
  const back = new URL(location);
  back.pathname = "/benchmarks/";
  back.searchParams.delete("page");
  back.searchParams.delete("run");
  back.hash = "";
  function update(values: Record<string, string>) {
    const next = readURL();
    for (const [key, value] of Object.entries(values)) {
      if (value && value !== "all") next.searchParams.set(key, value);
      else next.searchParams.delete(key);
    }
    if (!("p" in values)) next.searchParams.delete("p");
    window.history.replaceState(null, "", next);
    setLocation(next);
  }
  function navigate(event: MouseEvent<HTMLDivElement>) {
    if (
      event.button !== 0 ||
      event.metaKey ||
      event.ctrlKey ||
      event.shiftKey ||
      event.altKey
    )
      return;
    const anchor = (event.target as Element).closest<HTMLAnchorElement>(
      "a[data-bench]",
    );
    if (!anchor || anchor.target === "_blank") return;
    const next = new URL(anchor.href);
    if (next.origin !== location.origin) return;
    event.preventDefault();
    window.history.pushState(null, "", next);
    setLocation(next);
  }
  useEffect(() => {
    applyMetadata(run, Boolean(runId && !run));
    if (location.hash && location.hash.slice(1) !== runId) {
      document.getElementById(location.hash.slice(1))?.scrollIntoView();
    } else {
      window.scrollTo({ top: 0, behavior: "instant" });
      if (runId)
        document
          .getElementById("benchmark-title")
          ?.focus({ preventScroll: true });
    }
  }, [runId, run, location.hash]);
  return (
    <MotionConfig reducedMotion="user">
      <div className="bench-site" onClick={navigate}>
        <a className="bench-skip" href="#benchmark-main">
          Skip to results
        </a>
        <div className="bench-topbar">
          <nav aria-label="Main navigation">
            <a className="bench-brand" href="/">
              <Orb size={28} />
              <span>Next Notes</span>
            </a>
            <div>
              <a href="/benchmarks/" data-bench="" aria-current="page">
                Benchmarks
              </a>
              <a href="/benchmarks/#methodology" data-bench="">
                Our method
              </a>
              <a href={DOWNLOAD_URL}>
                Get the app <ArrowUpRight size={14} />
              </a>
            </div>
          </nav>
        </div>
        <main id="benchmark-main" className="bench-main">
          {runId ? (
            run ? (
              <Report
                key={run.id}
                run={run}
                back={`${back.pathname}${back.search}#reports`}
              />
            ) : (
              <section className="bench-empty bench-missing">
                <h1 id="benchmark-title" tabIndex={-1}>
                  This report isn’t available.
                </h1>
                <p>
                  The link may be out of date, or the result has not been
                  approved for publication.
                </p>
                <a href="/benchmarks/" data-bench="">
                  <ArrowLeft size={16} /> Browse published benchmarks
                </a>
              </section>
            )
          ) : (
            <>
              <motion.header
                className="bench-intro"
                initial={{ opacity: 0 }}
                animate={{ opacity: 1 }}
                transition={{ duration: 0.45 }}
              >
                <div>
                  <h1 id="benchmark-title">
                    Benchmarks. <em>The whole story.</em>
                  </h1>
                  <p>
                    How our models perform, and how the whole workflow holds up.
                    Explore the numbers, the tests behind them, and what we
                    still need to prove.
                  </p>
                  <a href="#reports">
                    Explore all {runs.length} reports <ArrowDown size={16} />
                  </a>
                </div>
                <div className="bench-intro-note">
                  <span>Next Notes benchmarks</span>
                  <p>
                    Real measurements.
                    <br />
                    Clear conditions.
                    <br />
                    No single score for everything.
                  </p>
                  <span>
                    Latest evidence · {date(runs[0]?.date ?? "2026-10-22")}
                  </span>
                </div>
              </motion.header>
              <Comparison
                key={group}
                group={group}
                measure={measure}
                language={language}
                chart={chart}
                omitted={params.get("omit") ?? ""}
                update={update}
              />
              <section
                className="bench-directory"
                id="reports"
                aria-labelledby="reports-title"
              >
                <div className="bench-section-heading">
                  <div>
                    <h2 id="reports-title">Every test has a story.</h2>
                    <p>Read the result, how we got it, and where it stops.</p>
                  </div>
                  <span className="bench-muted">
                    Models, meetings, agents & workflows
                  </span>
                </div>
                <form
                  className="bench-filters"
                  onSubmit={(e) => e.preventDefault()}
                >
                  <label className="bench-search">
                    Search reports
                    <span>
                      <Search size={17} aria-hidden="true" />
                      <input
                        type="search"
                        value={query}
                        maxLength={200}
                        placeholder="Find a model, workflow or result"
                        onChange={(e) => update({ q: e.target.value })}
                      />
                    </span>
                  </label>
                  <label>
                    Area
                    <select
                      value={area}
                      onChange={(e) => update({ area: e.target.value })}
                    >
                      {Object.entries(areas)
                        .filter(
                          ([id]) =>
                            id === "all" || runs.some((r) => r.category === id),
                        )
                        .map(([id, label]) => (
                          <option key={id} value={id}>
                            {label}
                          </option>
                        ))}
                    </select>
                  </label>
                  <label>
                    Status
                    <select
                      value={status}
                      onChange={(e) => update({ status: e.target.value })}
                    >
                      <option value="all">All results</option>
                      {Object.entries(statusLabels).map(([id, label]) => (
                        <option key={id} value={id}>
                          {label}
                        </option>
                      ))}
                    </select>
                  </label>
                  <label>
                    Sort by
                    <select
                      value={order}
                      onChange={(e) => update({ order: e.target.value })}
                    >
                      <option value="newest">Newest first</option>
                      <option value="oldest">Oldest first</option>
                      <option value="name">Name</option>
                    </select>
                  </label>
                </form>
                <div className="bench-result-count" role="status">
                  <span>
                    {filtered.length}{" "}
                    {filtered.length === 1 ? "report" : "reports"}
                    {query.trim() ? ` matching “${query.trim()}”` : ""}
                  </span>
                  {(area !== "all" || status !== "all" || query) && (
                    <button
                      onClick={() =>
                        update({ area: "all", status: "all", q: "" })
                      }
                    >
                      Clear filters
                    </button>
                  )}
                </div>
                {filtered.length === 0 ? (
                  <div className="bench-empty">
                    <h3>No reports match these filters.</h3>
                    <p>
                      Try a different model name or include all result statuses.
                    </p>
                    <button
                      onClick={() =>
                        update({ area: "all", status: "all", q: "" })
                      }
                    >
                      Show all reports
                    </button>
                  </div>
                ) : (
                  <>
                    <div className="bench-report-list" role="list">
                      {filtered.slice((page - 1) * 12, page * 12).map((r) => (
                        <article role="listitem" key={r.id}>
                          <div className="bench-list-meta">
                            <span>{areas[r.category]}</span>
                            <time dateTime={r.date}>{date(r.date)}</time>
                          </div>
                          <div>
                            <a
                              className="bench-report-title"
                              href={runHref(r.id)}
                              data-bench=""
                            >
                              {displayTitle(r)}
                              <ArrowUpRight size={17} />
                            </a>
                            <p>{r.summary}</p>
                          </div>
                          <div className="bench-list-result">
                            <span
                              className="bench-status"
                              title={statusMeaning[r.status]}
                            >
                              {statusLabels[r.status]}
                            </span>
                            <span>
                              {primaryMetric(r)
                                ? `${primaryMetric(r)!.name}: ${number(primaryMetric(r)!.value)} ${primaryMetric(r)!.unit}`
                                : "No accepted metrics"}
                            </span>
                            <a href={runHref(r.id)} data-bench="">
                              Read full report <ArrowRight size={14} />
                            </a>
                          </div>
                        </article>
                      ))}
                    </div>
                    {pages > 1 && (
                      <nav
                        className="bench-pagination"
                        aria-label="Report pages"
                      >
                        <button
                          disabled={page === 1}
                          onClick={() => {
                            update({ p: String(page - 1) });
                            document
                              .getElementById("reports")
                              ?.scrollIntoView();
                          }}
                        >
                          <ArrowLeft size={15} /> Previous
                        </button>
                        <span>
                          Page {page} of {pages}
                        </span>
                        <button
                          disabled={page === pages}
                          onClick={() => {
                            update({ p: String(page + 1) });
                            document
                              .getElementById("reports")
                              ?.scrollIntoView();
                          }}
                        >
                          Next <ArrowRight size={15} />
                        </button>
                      </nav>
                    )}
                  </>
                )}
              </section>
              <section className="bench-methodology" id="methodology">
                <div>
                  <h2>
                    Good comparisons
                    <br />
                    start with <em>context.</em>
                  </h2>
                  <p>
                    A fast model is useful only when it does the work well. We
                    publish the conditions and the unfinished checks alongside
                    the numbers.
                  </p>
                </div>
                <div>
                  <article>
                    <span>01</span>
                    <div>
                      <h3>Compare the same thing</h3>
                      <p>
                        Charts keep fixtures, hardware, language and measurement
                        clocks together. Generating audio, hearing it, and
                        finishing a conversation are different waits.
                      </p>
                    </div>
                  </article>
                  <article>
                    <span>02</span>
                    <div>
                      <h3>Keep the limits visible</h3>
                      <p>
                        A component passing is not the whole app passing.
                        Partial, failed, blocked and unrun results stay in the
                        catalog. Missing values are never plotted as zero.
                      </p>
                    </div>
                  </article>
                  <article>
                    <span>03</span>
                    <div>
                      <h3>Follow the result to its source</h3>
                      <p>
                        Each report explains its measurements and conditions
                        here. Reviewed source links and the registered record
                        are available for deeper inspection on GitHub. Private
                        recordings and diagnostics are not fetched.
                      </p>
                    </div>
                  </article>
                </div>
              </section>
            </>
          )}
        </main>
        <footer className="bench-footer">
          <span>Next Notes · Measured with care.</span>
          <a href="/benchmarks/#methodology" data-bench="">
            How we measure
          </a>
          <a
            href={`${REPO_URL}/tree/main/Benchmarks`}
            target="_blank"
            rel="noreferrer"
          >
            Benchmark source <ArrowUpRight size={14} />
          </a>
        </footer>
      </div>
    </MotionConfig>
  );
}
