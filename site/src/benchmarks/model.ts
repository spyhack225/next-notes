import catalog from "../generated/benchmarks.json" with { type: "json" };
import speechModels from "../../../shared/asr-models.json" with { type: "json" };

export type Metric = {
  name: string;
  value: number;
  unit: string;
  boundary: string;
  samples: number | null;
  aggregation: string;
};
export type Run = {
  id: string;
  title: string;
  date: string;
  category: string;
  status: string;
  scope: string;
  summary: string;
  environment: Record<string, string>;
  metrics: Metric[];
  limitations: string[];
};
export type Report = {
  id: string;
  purpose: string;
  method: string[];
  findings: string[];
  next_steps: string[];
  source_links: { label: string; path: string }[];
  reproduction: { label: string; value: string }[];
};
export const runs = catalog.runs as unknown as Run[];
export const areas: Record<string, string> = {
  all: "All areas",
  asr: "Speech recognition",
  tts: "Voice synthesis",
  dictation: "Dictation",
  meetings: "Meetings",
  agent: "Agent",
  voice: "Conversation",
  workflows: "Workflows",
  models: "Local models",
  other: "Other checks",
};
export const statusLabels: Record<string, string> = {
  measured: "Measured",
  partial: "Partial",
  failed: "Failed",
  blocked: "Blocked",
  unrun: "Not run",
};
export const statusMeaning: Record<string, string> = {
  measured:
    "The stated scope was measured. This does not qualify the whole app.",
  partial:
    "Useful evidence exists, with incomplete coverage or open acceptance.",
  failed:
    "The stated check ran and failed. Read the report for the exact failure.",
  blocked: "Conditions prevented an accepted measurement.",
  unrun: "No accepted measurement has been recorded.",
};
export function displayTitle(run: Run) {
  return run.title.replace(/@[a-f0-9]{40}/g, "");
}
export function primaryMetric(run: Run) {
  const names = [
    "EN Release to ASR final",
    "Warm microphone pickup median",
    "Warm first generated PCM",
    "Median cleanup",
    "EN word error rate",
    "Exact-tool accuracy",
  ];
  return (
    names
      .map((name) =>
        name === "Warm microphone pickup median" &&
        acceptedValue(run, name, true, "ms") === null
          ? undefined
          : run.metrics.find((m) => m.name === name),
      )
      .find(Boolean) ?? run.metrics[0]
  );
}
export function number(value: number) {
  return value.toLocaleString("en-US", {
    maximumFractionDigits: value !== 0 && Math.abs(value) < 10 ? 2 : 1,
  });
}
export function date(value: string) {
  return new Date(`${value}T12:00:00Z`).toLocaleDateString("en-US", {
    month: "short",
    day: "numeric",
    year: "numeric",
    timeZone: "UTC",
  });
}
export function runHref(id: string) {
  const url = new URL(window.location.href);
  url.pathname = `/benchmarks/${encodeURIComponent(id)}/`;
  url.searchParams.delete("page");
  url.searchParams.delete("run");
  url.hash = "";
  return `${url.pathname}${url.search}`;
}
export function metric(run: Run | undefined, name: string) {
  return run?.metrics.find((m) => m.name === name);
}
export function acceptedValue(
  run: Run | undefined,
  name: string,
  acoustic = false,
  expectedUnit?: string,
): number | null {
  if (!run || !["measured", "partial"].includes(run.status)) return null;
  const m = metric(run, name);
  if (
    !m ||
    !Number.isFinite(m.value) ||
    m.value < 0 ||
    (expectedUnit && m.unit !== expectedUnit)
  )
    return null;
  if (acoustic) {
    const attempted = metric(run, "Attempted warm microphone trials")?.value;
    const qualified = metric(run, "Qualified warm microphone trials")?.value;
    if (!attempted || attempted !== qualified || m.samples !== attempted)
      return null;
  }
  return m.value;
}
export type Entry = {
  id: string;
  name: string;
  run?: Run;
  value: number | null;
  size?: number;
  note: string;
};
export type Comparison = {
  title: string;
  context: string;
  method: string;
  takeaway: string;
  unit: string;
  metricName: string;
  entries: Entry[];
};
const voices = [
  { id: "apple", name: "macOS", size: 0 },
  { id: "pocket", name: "Pocket", size: 454.25 },
  { id: "kokoro", name: "Kokoro", size: 107.37 },
  { id: "phonon", name: "Phonon", size: 323.57 },
  { id: "qwen", name: "Qwen3-TTS", size: 1698.37 },
];
export function comparison(
  group: string,
  language: string,
  measure: string,
  source: Run[] = runs,
): Comparison {
  const find = (id: string) => source.find((r) => r.id === id);
  if (group === "speech" && measure === "errors") {
    const metricName = `${language === "fr" ? "FR" : "EN"} word error rate`;
    return {
      title: "Word error rate",
      unit: "%",
      metricName,
      context: `22 Oct 2026 · isolated runtime · one ${language === "fr" ? "151-word French" : "136-word English"} authored recording`,
      method:
        "This is the earlier longer-fixture runtime accuracy experiment, separate from the paced signed-app latency comparison. Word error rate counts substitutions, insertions and deletions against the authored reference; number formatting can count as errors. Model space is downloaded artifact size. These are not general or current whole-app accuracy scores.",
      takeaway:
        language === "fr"
          ? "Qwen 1.7B scored best on this longer French recording. Voz scored better than Whistle here, although Whistle finalized faster on the separate short app excerpt."
          : "Phonon and Qwen 0.6B had the lowest word error on this one English fixture. A single recording is not a broad quality evaluation.",
      entries: speechModels.map((m) => {
        const run = find(
          `2026-10-22-asr-${m.id === "parakeet-v3" ? "parakeet-v3-runtime" : m.id}`,
        );
        return {
          id: m.id,
          name: m.name.replace(/\s*\([^)]*\)/g, ""),
          run,
          value: acceptedValue(run, metricName, false, "percent"),
          size: m.bytes / 1e6,
          note:
            language === "fr" && m.id === "phonon"
              ? "English only"
              : "Not measured",
        };
      }),
    };
  }
  if (group === "speech") {
    const metricName = `${language === "fr" ? "FR" : "EN"} ${measure === "first" ? "First provisional text" : "Release to ASR final"}`;
    return {
      title: measure === "first" ? "Time to first words" : "Time after release",
      context: `22 Oct 2026 · M3 Mac · 16 GB · ${language === "fr" ? "French" : "English"} · 3 warm trials per model`,
      unit: "ms",
      metricName,
      method:
        "Real-time authored audio, fed in 20 ms pieces through the signed app. First words include the initial 400 ms audio window. Finalization runs from release to the app transcript consumer. Cold load, physical mic, display, cleanup, insertion and concurrent voice are excluded.",
      takeaway:
        language === "fr"
          ? "Whistle finalized fastest on this short French excerpt. This does not establish general recognition quality; the earlier longer accuracy test favored Voz over Whistle."
          : "Phonon finalized fastest on this short English excerpt. Warm speed excludes its roughly 223-second first preparation. The app keeps existing manual model choices.",
      entries: speechModels.map((m) => {
        const id = m.id === "parakeet-v3" ? "parakeet" : m.id;
        const run = find(`2026-10-22-asr-signed-app-${id}`);
        return {
          id: m.id,
          name: m.name.replace(/\s*\([^)]*\)/g, ""),
          run,
          value: acceptedValue(run, metricName, false, "ms"),
          size: m.bytes / 1e6,
          note:
            language === "fr" && m.id === "phonon"
              ? "English only"
              : run
                ? statusLabels[run.status]
                : "No published result",
        };
      }),
    };
  }
  if (group === "voice") {
    const acoustic = measure !== "generated";
    const suffix = measure === "calibrated" ? "calibrated" : "serial";
    const metricName = acoustic
      ? "Warm microphone pickup median"
      : "Warm first generated PCM";
    return {
      title: acoustic
        ? "Sound arriving at the microphone"
        : "Time to generated audio",
      unit: "ms",
      metricName,
      context: !acoustic
        ? "22 Oct 2026 · M3 Mac · 5 warm same-text requests · before playback"
        : `23 Oct 2026 · M3 Mac · 30 varied warm requests · ${suffix === "serial" ? "60%" : "38%"} speaker volume · ASR decoder load`,
      method: acoustic
        ? "Actual playback and native-format microphone observation with progressing Parakeet-v3 reference decoding. A median is accepted only when all warm trials qualify. This includes the acoustic/input paths; it is not human perceptual onset or full-conversation latency. Speaker-volume cohorts are kept separate."
        : "Known English text to the first nonempty generated audio through the native adapter. This measures preparation for playback, not audible speech. Five same-text warm requests per model; download and initial preparation are separate.",
      takeaway: !acoustic
        ? "Small generation times do not mean sound starts just as quickly. Use the speaker cohorts to inspect actual pickup, including failures and unavailable results."
        : suffix === "serial"
          ? "Phonon and Pocket completed this 60% volume cohort. Disk pressure stopped the other three; there is no accepted five-model winner."
          : "macOS completed this separate 38% volume cohort. Qwen qualified only 27 of 30 pickups, so its acoustic median is withheld. Other voices did not complete.",
      entries: voices.map((v) => {
        const run = find(
          acoustic
            ? `2026-10-23-tts-${v.id}-speaker-${suffix}`
            : `2026-10-22-tts-${v.id}-native`,
        );
        const value = acceptedValue(run, metricName, acoustic, "ms");
        const count = metric(run, "Qualified warm microphone trials")?.value;
        const attempted = metric(
          run,
          "Attempted warm microphone trials",
        )?.value;
        return {
          ...v,
          run,
          value,
          note:
            acoustic && attempted && attempted !== count
              ? `Incomplete: ${count ?? 0}/${attempted} qualified`
              : run
                ? statusLabels[run.status]
                : "No published result",
        };
      }),
    };
  }
  if (group === "decisions") {
    const metricName = "Decision latency median";
    return {
      title: "Time to choose a tool",
      unit: "ms",
      metricName,
      context:
        "23 Sep 2026 · historical offline harness · 112 decision fixtures",
      method:
        "The same offline decision-classification fixture suite compares a resident Needle server, a per-proposal Needle process and two Laya configurations. Timing stops at the classification result, not at execution of the tool or completion of a user task.",
      takeaway:
        "Faster classification is not automatically a better decision. Exact-tool accuracy ranges from 69.6% to 74.1% in these reports; neither this speed nor that fixture score qualifies the full agent.",
      entries: [
        ["needle-serve", "Needle · resident server"],
        ["needle", "Needle · per proposal"],
        ["laya-typed-decisions", "Laya · typed decisions"],
        ["laya-multilingual", "Laya · multilingual"],
      ].map(([id, name]) => {
        const run = find(`2026-09-23-decision-${id}`);
        return {
          id,
          name,
          run,
          value: acceptedValue(run, metricName, false, "ms"),
          note: run ? statusLabels[run.status] : "No published result",
        };
      }),
    };
  }
  const metricName =
    measure === "quality" ? "Failed assertions" : "Median cleanup";
  return {
    title:
      measure === "quality"
        ? "Cleanup checks that failed"
        : "Time to cleaned-up text",
    unit: measure === "quality" ? "of 42" : "s",
    metricName,
    context:
      "30 Sep 2026 · historical cleanup harness · matching assertion suite",
    method:
      "Historical comparison of the same cleanup evaluation. Speed and failed assertions are separate dimensions; a fast configuration may still fail quality checks. Gemma showed variability across retained conditions and is not assigned a single value.",
    takeaway:
      "Apple passed all 42 assertions in this retained suite; MiniCPM was faster but failed 3. These historical configurations do not qualify current whole-app dictation.",
    entries: [
      ["apple", "Apple"],
      ["minicpm5", "MiniCPM5-2B"],
      ["qwen3", "Qwen3-4B"],
      ["qwen35", "Qwen3.5-4B"],
      ["gemma", "Gemma 4 E4B"],
    ].map(([id, name]) => {
      const run = find(`2026-09-30-cleanup-${id}`);
      return {
        id,
        name,
        run,
        value: acceptedValue(
          run,
          metricName,
          false,
          measure === "quality" ? "of 42" : "s",
        ),
        note:
          id === "gemma"
            ? "Variable; see report"
            : run
              ? statusLabels[run.status]
              : "No published result",
      };
    }),
  };
}
export function filterRuns(
  source: Run[],
  area: string,
  status: string,
  query: string,
  order: string,
) {
  const q = query.trim().toLowerCase();
  return source
    .filter(
      (r) =>
        (area === "all" || r.category === area) &&
        (status === "all" || r.status === status) &&
        `${r.title} ${r.summary} ${r.scope}`.toLowerCase().includes(q),
    )
    .sort((a, b) =>
      order === "name"
        ? a.title.localeCompare(b.title) || a.id.localeCompare(b.id)
        : (order === "oldest"
            ? a.date.localeCompare(b.date)
            : b.date.localeCompare(a.date)) || a.id.localeCompare(b.id),
    );
}

export function comparisonHref(run: Run) {
  if (run.id.includes("asr-signed-app-"))
    return "/benchmarks/?compare=speech&measure=final#compare";
  if (
    /^2026-10-22-asr-(phonon|voz|whistle|redux|ultra|qwen-06b|qwen-17b|parakeet-v3-runtime)$/.test(
      run.id,
    )
  )
    return "/benchmarks/?compare=speech&measure=errors#compare";
  if (/^2026-10-22-tts-.*-native$/.test(run.id))
    return "/benchmarks/?compare=voice&measure=generated#compare";
  if (/^2026-10-23-tts-.*-speaker-(serial|calibrated)$/.test(run.id))
    return `/benchmarks/?compare=voice&measure=${run.id.endsWith("serial") ? "serial" : "calibrated"}#compare`;
  if (run.id.startsWith("2026-09-30-cleanup-"))
    return "/benchmarks/?compare=cleanup#compare";
  if (
    /^2026-09-23-decision-(needle|needle-serve|laya-multilingual|laya-typed-decisions)$/.test(
      run.id,
    )
  )
    return "/benchmarks/?compare=decisions#compare";
  return null;
}
