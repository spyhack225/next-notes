import { useMemo, useState } from "react";
import data from "./generated/benchmarks.json";
import asrModels from "../../shared/asr-models.json";
import asrAppLatency from "../../shared/asr-app-latency.json";
import { REPO_URL } from "./lib/motion";

const areas = ["all", "asr", "dictation", "meetings", "agent", "voice", "tts", "workflows", "models"];
const labels: Record<string, string> = { all: "All areas", asr: "Speech recognition", tts: "Speech synthesis" };
const asrAppRows = asrModels.map(model => ({ ...model, name: model.name.replace(/\s*\([^)]*\)/g, ""), live: asrAppLatency.find(run => run.id === model.id)?.languages }));


// The same reviewed registry supplies the cards and the voice comparison.
const ttsRows = [
  { id: "apple", name: "macOS", bytes: 0 },
  { id: "pocket", name: "Pocket", bytes: 454246490 },
  { id: "kokoro", name: "Kokoro", bytes: 107370410 },
  { id: "phonon", name: "Phonon", bytes: 323569035 },
  { id: "qwen", name: "Qwen3-TTS", bytes: 1698367268 },
].map(voice => {
  const generated = data.runs.find(run => run.id === `2026-10-22-tts-${voice.id}-native`);
  const speaker = data.runs.find(run => run.id === `2026-10-23-tts-${voice.id}-speaker-serial`)
    ?? data.runs.find(run => run.id === `2026-10-23-tts-${voice.id}-speaker-calibrated`)
    ?? data.runs.find(run => run.id === `2026-10-22-tts-${voice.id}-speaker-quiet`)
    ?? data.runs.find(run => run.id === `2026-10-22-tts-${voice.id}-speaker-output`);
  return { ...voice,
    speakerId: speaker?.id,
    status: speaker?.status,
    pcm: generated?.metrics.find(metric => metric.name === "Warm first generated PCM")?.value,
    sound: speaker?.metrics.find(metric => metric.name === "Warm microphone pickup median")?.value,
    confirmed: speaker?.metrics.find(metric => metric.name === "Qualified warm microphone trials")?.value,
    attempted: speaker?.metrics.find(metric => metric.name === "Attempted warm microphone trials")?.value,
  };
});

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
          <p>App defaults: Phonon for English, Voz for Multi. Voz supports 25 European languages; English and French were tested here. You can choose any compatible model in Settings.</p>
          <label>Test language <select value={language} onChange={event => setLanguage(event.target.value as "en" | "fr")}><option value="en">English</option><option value="fr">French</option></select></label>
          <div className="benchmark-table-scroll"><table>
            <caption>Signed app on M3 Mac · median of three warmed paced holds · sorted by time after release</caption>
            <thead><tr><th scope="col">Model</th><th scope="col">First words</th><th scope="col">After release</th><th scope="col">Size</th><th scope="col">Longer test: words correct</th></tr></thead>
            <tbody>{[...asrAppRows].sort((a,b) => (a.live?.[language]?.finalMs ?? Infinity) - (b.live?.[language]?.finalMs ?? Infinity)).map(model => {
              const measured = model.live?.[language];
              const accuracy = model.languages[language]?.wordAccuracy;
              return <tr key={model.id}><th scope="row">{model.name}</th><td>{measured ? `${Math.round(measured.firstMs)} ms` : "English only"}</td><td>{measured ? `${Math.round(measured.finalMs)} ms` : "—"}</td><td>{(model.bytes/1000000).toLocaleString(undefined,{maximumFractionDigits:0})} MB</td><td>{accuracy !== undefined ? `${accuracy.toFixed(1)}%` : "—"}</td></tr>;
            })}</tbody>
          </table></div>
          <p className="text-muted-foreground">22 October 2026, signed app build 800. Audio was fed in real time in 20 ms pieces; first words include the app’s 400 ms initial window. Finalization starts at release and includes pending inference. Timings end at the app’s transcript consumer and exclude cold loading, physical microphone, display, cleanup, insertion and concurrent voice. Three trials used one 7.25-second English or 6.65-second French excerpt.</p>
          <p className="text-muted-foreground">The percentage is from an earlier, separate runtime test on one longer authored recording: 136 English or 151 French words, calculated as 100 × (1 − word error rate). It is not current full-app or general accuracy; number formatting can count as errors. Model size is downloaded artifacts, excluding compilation caches and temporary setup space.</p>
          <p className="text-muted-foreground">Phonon was fastest for English. Whistle was fastest for French in the app’s short test, where its final wording matched Voz; Voz scored higher in the earlier longer French test. Qwen 1.7B scored highest on that longer French recording. Each candidate was tested and its temporary files removed before the next. Phonon’s first preparation took about 223 seconds; warm speed excludes that setup.</p>
        </section>
        <section id="tts-comparison" aria-labelledby="tts-heading">
          <h2 id="tts-heading">Voice speed and space</h2>
          <p>All five voices are available in Settings. Audio preparation and sound from the speakers are different waits.</p>
          <div className="benchmark-table-scroll"><table>
            <caption>M3 MacBook Air · 16 GB · preparation: 22 October · speaker test: 23 October 2026</caption>
            <thead><tr><th scope="col">Voice</th><th scope="col">Audio prepared</th><th scope="col">Preparation wait vs Qwen</th><th scope="col">Sound at microphone</th><th scope="col">Extra model space</th><th scope="col">Size vs largest</th></tr></thead>
            <tbody>{ttsRows.map(voice => <tr key={voice.id}>
              <th scope="row"><a href={`#${voice.speakerId ?? `2026-10-22-tts-${voice.id}-native`}`}>{voice.name}</a></th>
              <td>{voice.pcm !== undefined ? `${voice.pcm.toLocaleString(undefined, { maximumFractionDigits: 1 })} ms` : "Not measured"}</td>
              <td>{voice.pcm !== undefined ? `${(voice.pcm / 2709.3025 * 100).toFixed(1)}%` : "—"}</td>
              <td>{voice.sound !== undefined ? `${Math.round(voice.sound)} ms` : voice.attempted !== undefined && voice.attempted > 0 ? `Incomplete (${voice.confirmed ?? 0}/${voice.attempted} confirmed)` : voice.status === "failed" ? "Stopped: low disk space" : "Not run: low disk space"}</td>
              <td>{voice.bytes === 0 ? "Built in" : `≈${Math.round(voice.bytes / 1000000)} MB`}</td>
              <td>{`${Math.round(voice.bytes / 1698367268 * 100)}%`}</td>
            </tr>)}</tbody>
          </table></div>
          <p className="text-muted-foreground">Preparation: median of five warm same-text requests to first generated audio, before playback. The percentage is that wait divided by Qwen’s 2,709 ms; lower means less waiting. It does not rank speaker output. Model space uses prepared files, including shared Kokoro assets once; Apple’s existing system assets are excluded. Downloads and runtime memory are separate.</p>
          <p className="text-muted-foreground">Speaker tests use the actual playback backings, laptop speakers and native-format microphone, with concurrent speech-decoder load. Pickup requires matching audio and two consecutive 10 ms windows above the room threshold. This includes the acoustic and input paths; it is not human perceptual onset or full conversation latency. An incomplete result has no accepted speaker median. Each temporary model is removed before the next starts.</p>
          <p className="text-muted-foreground">The speaker column shows the latest serial attempt at 60% speaker volume, with ASR decoding during each measured request. Phonon completed all 30 warm pickups (264 ms median, 322 ms p95), then Pocket (293 ms median, 369 ms p95). Disk pressure prevented the remaining three from completing. Earlier results remain below, including macOS at 160 ms in the separate 38% volume test. The owner approved continuing on the MacBook speakers. Qwen prepared but stopped at the disk guard before timed synthesis; Kokoro stopped during reference warmup and macOS was refused. All temporary models were removed. Free space then fell below 1 GiB, so further testing is blocked. These attempts do not establish the fastest of all five. Phonon is the owner’s temporary saved choice because it was fastest in the completed 60% volume comparison. macOS was faster in the separate 38% test. Phonon playback activation remains unverified while disk space prevents reinstalling its model. All five choices remain available in Settings.</p>
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
