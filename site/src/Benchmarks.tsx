import { useMemo, useState } from "react";
import data from "./generated/benchmarks.json";
import asrModels from "../../shared/asr-models.json";
import { REPO_URL } from "./lib/motion";

const areas = ["all", "asr", "dictation", "meetings", "agent", "voice", "tts", "workflows", "models"];
const labels: Record<string, string> = { all: "All areas", asr: "Speech recognition", tts: "Speech synthesis" };

export default function Benchmarks() {
  const [language, setLanguage] = useState<"en" | "fr">("en");
  const [area, setArea] = useState("all");
  const [query, setQuery] = useState("");
  const [status, setStatus] = useState("all");
  const runs = useMemo(() => data.runs.filter(run =>
    (area === "all" || run.category === area) &&
    (status === "all" || run.status === status) &&
    `${run.title} ${run.summary} ${run.scope}`.toLowerCase().includes(query.toLowerCase())
  ), [area, query, status]);

  return (
    <div className="min-h-screen bg-background text-foreground">
      <main className="benchmark-page">
        <nav aria-label="Benchmark navigation" className="benchmark-nav">
          <a href="?">Next Notes</a>
          <a href={`${REPO_URL}/tree/main/Benchmarks`}>Repository evidence</a>
        </nav>
        <header>
          <h1>Benchmarks</h1>
          <p>Model performance and workflow checks, with the conditions and limits that give each result meaning.</p>
          <p className="text-muted-foreground">These are dated observations. A measured component does not establish that the whole app passes. Targets and pending runs are kept separate.</p>
        </header>
        <section id="asr-comparison" aria-labelledby="asr-heading">
          <h2 id="asr-heading">Speech model comparison</h2>
          <p>Speed-first choices: Phonon for English, Voz for Multi. Multi supports 25 European languages; French is the second language measured here.</p>
          <label>Test language <select value={language} onChange={event => setLanguage(event.target.value as "en" | "fr")}><option value="en">English</option><option value="fr">French</option></select></label>
          <div className="benchmark-table-scroll"><table>
            <caption>M3 Mac · median of three warmed paced holds · sorted by time after release</caption>
            <thead><tr><th scope="col">Model</th><th scope="col">First words</th><th scope="col">After release</th><th scope="col">Size</th><th scope="col">Words correct in our test</th></tr></thead>
            <tbody>{[...asrModels].sort((a,b) => (a.languages[language]?.finalMs ?? Infinity) - (b.languages[language]?.finalMs ?? Infinity)).map(model => {
              const measured = model.languages[language];
              return <tr key={model.id}><th scope="row">{model.name}</th><td>{measured ? `${Math.round(measured.firstMs)} ms` : "English only"}</td><td>{measured ? `${Math.round(measured.finalMs)} ms` : "—"}</td><td>{(model.bytes/1000000).toLocaleString(undefined,{maximumFractionDigits:0})} MB</td><td>{measured ? `${measured.wordAccuracy.toFixed(1)}%` : "—"}</td></tr>;
            })}</tbody>
          </table></div>
          <p className="text-muted-foreground">22 October 2026. First words include a 400 ms initial audio feed, then one-second updates. Finalization starts at release and includes pending inference. These are runtime callbacks, excluding cold loading, microphone, display, cleanup and insertion. Accuracy is 100 × (1 − word error rate) on one separate authored recording: 136 English or 151 French words; number formatting can count as errors. It is not a general accuracy percentage.</p>
          <p className="text-muted-foreground">Whistle’s provisional French word arrives first, but Voz finishes sooner and made fewer content errors in the short excerpt. Qwen 1.7B scored highest on the French accuracy recording. Each candidate was downloaded, measured and removed before the next.</p>
        </section>
        <form className="benchmark-filters" onSubmit={event => event.preventDefault()}>
          <label>Search results<input type="search" value={query} onChange={event => setQuery(event.target.value)} placeholder="Model or workflow" /></label>
          <label>Area<select value={area} onChange={event => setArea(event.target.value)}>{areas.map(value => <option key={value} value={value}>{labels[value] ?? value}</option>)}</select></label>
          <label>Result status<select value={status} onChange={event => setStatus(event.target.value)}>{["all", "measured", "partial", "failed", "blocked", "unrun"].map(value => <option key={value} value={value}>{value === "all" ? "All statuses" : value}</option>)}</select></label>
        </form>
        <p aria-live="polite" className="text-muted-foreground">{runs.length} results. “Partial” means open acceptance or incomplete coverage; “unrun” has no accepted measurement.</p>
        <div className="benchmark-results">
          {runs.map(run => (
            <article key={run.id} id={run.id}>
              <div className="benchmark-run-meta"><time dateTime={run.date}>{run.date}</time><span>{labels[run.category] ?? run.category}</span><span>{run.status}</span></div>
              <h2><a href={`#${run.id}`}>{run.title}</a></h2>
              <p>{run.summary}</p>
              <p className="text-muted-foreground">Scope: {run.scope}</p>
              <details>
                <summary>Measurements, conditions and limitations</summary>
                <dl>{Object.entries(run.environment).map(([key, value]) => <div key={key}><dt>{key.replaceAll("_", " ")}</dt><dd>{value}</dd></div>)}</dl>
                {run.metrics.length > 0 && <div className="benchmark-table-scroll"><table>
                  <caption>Measurements for {run.title}</caption>
                  <thead><tr><th scope="col">Measurement</th><th scope="col">Value</th><th scope="col">Method</th><th scope="col">Boundary</th></tr></thead>
                  <tbody>{run.metrics.map(metric => <tr key={metric.name}><th scope="row">{metric.name}</th><td>{metric.value.toLocaleString(undefined, { maximumFractionDigits: 3 })} {metric.unit}</td><td>{metric.aggregation}; n={metric.samples ?? "unknown"}</td><td>{metric.boundary}</td></tr>)}</tbody>
                </table></div>}
                <ul>{run.limitations.map(limit => <li key={limit}>{limit}</li>)}</ul>
                <a href={`${REPO_URL}/blob/main/Benchmarks/runs/${run.id}.json`}>Result record and evidence references</a>
              </details>
            </article>
          ))}
          {runs.length === 0 && <p>No results match these filters. Try another area or search.</p>}
        </div>
        <footer><p>Public summaries are reviewed before inclusion. Original recordings, transcripts and private diagnostics are not loaded by this page.</p><a href={`${REPO_URL}/blob/main/Benchmarks/FORMAT.md`}>How results are recorded</a></footer>
      </main>
    </div>
  );
}
