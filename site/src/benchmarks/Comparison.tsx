import { useState, type CSSProperties } from "react";
import {
  ArrowDown,
  ArrowUp,
  ArrowUpRight,
  BarChart3,
  Download,
  ScatterChart,
} from "lucide-react";
import { comparison, number, runHref, type Entry } from "./model";

type Props = {
  group: string;
  language: string;
  measure: string;
  chart: string;
  omitted: string;
  update: (values: Record<string, string>) => void;
};
function download(value: unknown, name: string) {
  const url = URL.createObjectURL(
    new Blob([JSON.stringify(value, null, 2)], { type: "application/json" }),
  );
  const a = document.createElement("a");
  a.href = url;
  a.download = name;
  a.click();
  setTimeout(() => URL.revokeObjectURL(url), 1000);
}
export default function Comparison({
  group,
  language,
  measure,
  chart,
  omitted,
  update,
}: Props) {
  const c = comparison(group, language, measure);
  const hidden = omitted
    .split(",")
    .filter((id) => c.entries.some((e) => e.id === id));
  const setHidden = (ids: string[]) => update({ omit: ids.join(",") });
  const [sort, setSort] = useState("value");
  const [ascending, setAscending] = useState(true);
  const [highlight, setHighlight] = useState<string | null>(null);
  const entries = c.entries
    .filter((e) => !hidden.includes(e.id))
    .sort((a, b) => {
      if (sort === "name")
        return a.name.localeCompare(b.name) * (ascending ? 1 : -1);
      const x = sort === "size" ? a.size : a.value,
        y = sort === "size" ? b.size : b.value;
      if (x == null) return y == null ? a.name.localeCompare(b.name) : 1;
      if (y == null) return -1;
      return (x - y) * (ascending ? 1 : -1) || a.name.localeCompare(b.name);
    });
  const measured = entries.filter(
    (e): e is Entry & { value: number } => e.value !== null,
  );
  const scaleMax = (value: number) => {
    const step = 10 ** Math.floor(Math.log10(Math.max(value, 1)));
    return Math.ceil((value * 1.05) / step) * step;
  };
  const max =
    c.unit === "of 42"
      ? 42
      : scaleMax(Math.max(...measured.map((e) => e.value), 1));
  const maxSize = scaleMax(Math.max(...measured.map((e) => e.size ?? 0), 1));
  const changeGroup = (value: string) => {
    setHighlight(null);
    update({
      compare: value,
      omit: "",
      chart: "bars",
      measure:
        value === "speech" ? "final" : value === "voice" ? "generated" : "time",
    });
  };
  const sorting = (value: string) => {
    setAscending(sort === value ? !ascending : true);
    setSort(value);
  };
  const sortLabel = (value: string) =>
    sort === value ? (ascending ? "ascending" : "descending") : "none";
  const selection = measured.find((e) => e.id === highlight);
  return (
    <section
      className="bench-comparison"
      id="compare"
      aria-labelledby="comparison-title"
    >
      <div className="bench-tabs" aria-label="Comparison area">
        {[
          ["speech", "Speech recognition"],
          ["voice", "Voice synthesis"],
          ["cleanup", "Text cleanup"],
          ["decisions", "Tool selection"],
        ].map(([id, label]) => (
          <button
            key={id}
            aria-pressed={group === id}
            onClick={() => changeGroup(id)}
          >
            {label}
          </button>
        ))}
      </div>
      <div className="bench-comparison-heading">
        <div>
          <h2 id="comparison-title">{c.title}</h2>
          <p>{c.context}</p>
        </div>
        <div className="bench-chart-controls">
          {group === "speech" && (
            <label>
              Language
              <select
                value={language}
                onChange={(e) => update({ language: e.target.value })}
              >
                <option value="en">English</option>
                <option value="fr">French</option>
              </select>
            </label>
          )}
          <label>
            Measurement
            <select
              value={measure}
              onChange={(e) => update({ measure: e.target.value })}
            >
              {group === "speech" ? (
                <>
                  <option value="final">After release</option>
                  <option value="first">First words</option>
                  <option value="errors">Word errors · longer test</option>
                </>
              ) : group === "voice" ? (
                <>
                  <option value="generated">Generated audio</option>
                  <option value="serial">Speaker pickup · 60% volume</option>
                  <option value="calibrated">
                    Speaker pickup · 38% volume
                  </option>
                </>
              ) : group === "decisions" ? (
                <option value="time">Decision time</option>
              ) : (
                <>
                  <option value="time">Cleanup time</option>
                  <option value="quality">Failed assertions</option>
                </>
              )}
            </select>
          </label>
        </div>
      </div>
      <div className="bench-plot-toolbar">
        <span>
          <ArrowDown size={14} aria-hidden="true" /> Lower is better{" "}
          <span className="bench-muted">
            · {measured.length} accepted values
          </span>
        </span>
        <div className="bench-view-controls">
          <button
            aria-label="Bar chart"
            aria-pressed={chart !== "scatter"}
            onClick={() => update({ chart: "bars" })}
          >
            <BarChart3 size={17} />
            <span>Bars</span>
          </button>
          {!["cleanup", "decisions"].includes(group) && (
            <button
              aria-label={`Plot ${c.title.toLowerCase()} against model size`}
              aria-pressed={chart === "scatter"}
              onClick={() => update({ chart: "scatter" })}
            >
              <ScatterChart size={17} />
              <span>
                {measure === "errors" ? "Size vs errors" : "Size vs speed"}
              </span>
            </button>
          )}
          <button
            aria-label="Download comparison data"
            onClick={() =>
              download(
                {
                  title: c.title,
                  conditions: c.context,
                  method: c.method,
                  unit: c.unit,
                  metric: c.metricName,
                  rows: entries.map(({ name, value, size, run, note }) => ({
                    name,
                    value,
                    sizeMB: size ?? null,
                    reportId: run?.id ?? null,
                    status: note,
                  })),
                },
                `next-notes-${group}-${measure}-${language}.json`,
              )
            }
          >
            <Download size={16} />
          </button>
        </div>
      </div>
      <div className="bench-chart" aria-label={`${c.title}; lower is better`}>
        {measured.length === 0 ? (
          <div className="bench-empty">
            <h3>No accepted values in this selection.</h3>
            <p>Missing or incomplete measurements are not zero.</p>
            <button onClick={() => setHidden([])}>Show all models</button>
          </div>
        ) : chart === "scatter" && !["cleanup", "decisions"].includes(group) ? (
          <>
            <svg
              className="bench-scatter"
              viewBox="0 0 900 350"
              role="img"
              aria-labelledby="scatter-title scatter-desc"
            >
              <title id="scatter-title">{c.title} against model space</title>
              <desc id="scatter-desc">
                Each point is one model in this cohort. Lower and further left
                means less waiting and less model space. The table below
                contains the exact values.
              </desc>
              {[0, 0.25, 0.5, 0.75, 1].map((t) => (
                <g key={t}>
                  <line
                    x1="70"
                    x2="870"
                    y1={290 - t * 240}
                    y2={290 - t * 240}
                  />
                  <text x="58" y={294 - t * 240} textAnchor="end">
                    {number(t * max)}
                  </text>
                  <text x={70 + t * 800} y="314" textAnchor="middle">
                    {number(t * maxSize)}
                  </text>
                </g>
              ))}
              <text x="70" y="20">
                {c.title} ({c.unit})
              </text>
              <text x="470" y="344" textAnchor="middle">
                Additional model files (MB) · not runtime memory
              </text>
              {measured
                .filter((e) => e.size !== undefined)
                .map((e) => (
                  <a
                    key={e.id}
                    href={runHref(e.run!.id)}
                    data-bench=""
                    aria-label={`${e.name}: ${number(e.value)} ${c.unit}, ${number(e.size!)} MB. Read report`}
                    onFocus={() => setHighlight(e.id)}
                    onBlur={() => setHighlight(null)}
                    onMouseEnter={() => setHighlight(e.id)}
                    onMouseLeave={() => setHighlight(null)}
                  >
                    <circle
                      className="bench-point-hit"
                      cx={70 + ((e.size ?? 0) / maxSize) * 800}
                      cy={290 - (e.value / max) * 240}
                      r="15"
                    />
                    <circle
                      cx={70 + ((e.size ?? 0) / maxSize) * 800}
                      cy={290 - (e.value / max) * 240}
                      r={highlight === e.id ? 9 : 6}
                      className={highlight === e.id ? "is-selected" : ""}
                    />
                    <title>
                      {e.name}: {number(e.value)} {c.unit}, {number(e.size!)} MB
                    </title>
                  </a>
                ))}
            </svg>
            <p className="bench-plot-hint" aria-live="polite">
              {selection
                ? `${selection.name} · ${number(selection.value)} ${c.unit} · ${number(selection.size ?? 0)} MB`
                : "Focus or hover a point for its value. Select it to read the report."}
            </p>
          </>
        ) : (
          <div className="bench-bars">
            <div className="bench-bar-scale">
              <span>{c.unit}</span>
              <span>0</span>
              <span>{number(max / 2)}</span>
              <span>{number(max)}</span>
            </div>
            {entries.map((e) => (
              <a
                className={`bench-bar-row${e.value === null ? " is-unmeasured" : ""}`}
                key={e.id}
                href={e.run ? runHref(e.run.id) : "#reports"}
                data-bench=""
                aria-label={`${e.name}: ${e.value === null ? e.note : `${number(e.value)} ${c.unit}`}. Read report`}
              >
                <span className="bench-bar-name">{e.name}</span>
                <span className="bench-bar-track">
                  {e.value !== null && (
                    <span
                      className="bench-bar-fill"
                      style={
                        {
                          "--bar-width": `${(e.value / max) * 100}%`,
                        } as CSSProperties
                      }
                    />
                  )}
                </span>
                <span className="bench-bar-value">
                  {e.value === null ? (
                    e.note
                  ) : (
                    <>
                      {number(e.value)} <span>{c.unit}</span>
                    </>
                  )}
                </span>
              </a>
            ))}
          </div>
        )}
      </div>
      <details className="bench-model-picker">
        <summary>
          Models in this comparison ({entries.length}/{c.entries.length})
        </summary>
        <div>
          {c.entries.map((e) => (
            <label key={e.id}>
              <input
                type="checkbox"
                checked={!hidden.includes(e.id)}
                onChange={() =>
                  setHidden(
                    hidden.includes(e.id)
                      ? hidden.filter((id) => id !== e.id)
                      : [...hidden, e.id],
                  )
                }
              />
              {e.name}
            </label>
          ))}
        </div>
      </details>
      <div
        className="bench-table-scroll"
        role="region"
        aria-label="Comparison values"
        tabIndex={0}
      >
        <table className="bench-data-table">
          <caption className="sr-only">
            Exact values and links to each model’s report
          </caption>
          <thead>
            <tr>
              <th scope="col" aria-sort={sortLabel("name")}>
                <button onClick={() => sorting("name")}>
                  Model{" "}
                  {sort === "name" &&
                    (ascending ? (
                      <ArrowDown size={13} />
                    ) : (
                      <ArrowUp size={13} />
                    ))}
                </button>
              </th>
              <th scope="col" aria-sort={sortLabel("value")}>
                <button onClick={() => sorting("value")}>
                  {c.title}{" "}
                  {sort === "value" &&
                    (ascending ? (
                      <ArrowDown size={13} />
                    ) : (
                      <ArrowUp size={13} />
                    ))}
                </button>
              </th>
              {!["cleanup", "decisions"].includes(group) && (
                <th scope="col" aria-sort={sortLabel("size")}>
                  <button onClick={() => sorting("size")}>Model space</button>
                </th>
              )}
              <th scope="col">Evidence</th>
            </tr>
          </thead>
          <tbody>
            {entries.map((e) => (
              <tr key={e.id}>
                <th scope="row">{e.name}</th>
                <td className="bench-numeric">
                  {e.value === null ? (
                    <span className="bench-muted">{e.note}</span>
                  ) : (
                    <>
                      {number(e.value)}{" "}
                      <span className="bench-muted">{c.unit}</span>
                    </>
                  )}
                </td>
                {!["cleanup", "decisions"].includes(group) && (
                  <td className="bench-numeric">
                    {e.size === 0
                      ? "Built in"
                      : e.size === undefined
                        ? "Unknown"
                        : `${number(e.size)} MB`}
                  </td>
                )}
                <td>
                  {e.run ? (
                    <a href={runHref(e.run.id)} data-bench="">
                      Read report <ArrowUpRight size={14} />
                    </a>
                  ) : (
                    "No published report"
                  )}
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
      <div className="bench-reading-note">
        <strong>What this tells us</strong>
        <p>{c.takeaway}</p>
        <details>
          <summary>How this comparison was measured</summary>
          <p>{c.method}</p>
        </details>
      </div>
    </section>
  );
}
export { download };
