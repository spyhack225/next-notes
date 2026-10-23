import { displayTitle, runs, statusLabels, type Run } from "./model.ts";

export const origin = "https://next-notes.com";
export const benchmarkPath = "/benchmarks/";
export const reportPath = (id: string) =>
  `${benchmarkPath}${encodeURIComponent(id)}/`;
export function reportId(url: URL) {
  if (
    url.pathname.startsWith(benchmarkPath) &&
    url.pathname !== benchmarkPath
  ) {
    try {
      return decodeURIComponent(
        url.pathname.slice(benchmarkPath.length).replace(/\/$/, ""),
      );
    } catch {
      return "__invalid__";
    }
  }
  return (
    url.searchParams.get("run") ??
    (runs.some((r) => r.id === url.hash.slice(1)) ? url.hash.slice(1) : null)
  );
}
export function metadata(run?: Run, missing = false) {
  const url = origin + (run ? reportPath(run.id) : benchmarkPath);
  const title = missing
    ? "Report unavailable | Next Notes Benchmarks"
    : run
      ? `${displayTitle(run)} | Next Notes Benchmarks`
      : "Model & Workflow Benchmarks | Next Notes";
  const description = missing
    ? "This benchmark report is unavailable. Browse the published Next Notes benchmarks."
    : run
      ? `${statusLabels[run.status]}. ${run.summary}`
      : "Explore Next Notes model and workflow benchmarks for speech, dictation, meetings, voice and agents. Read measurements, methods, limitations and original evidence.";
  const crumbs = [
    { name: "Next Notes", item: origin + "/" },
    { name: "Benchmarks", item: origin + benchmarkPath },
    ...(run ? [{ name: displayTitle(run), item: url }] : []),
  ];
  const graph: Record<string, unknown>[] = [
    {
      "@type": "WebSite",
      "@id": origin + "/#website",
      name: "Next Notes",
      url: origin + "/",
      inLanguage: "en",
    },
    {
      "@type": "Organization",
      "@id": origin + "/#organization",
      name: "Next Notes",
      url: origin + "/",
    },
    {
      "@type": "BreadcrumbList",
      "@id": url + "#breadcrumbs",
      itemListElement: crumbs.map((c, i) => ({
        "@type": "ListItem",
        position: i + 1,
        ...c,
      })),
    },
    {
      "@type": run ? "WebPage" : "CollectionPage",
      "@id": url + "#page",
      url,
      name: title,
      description,
      inLanguage: "en",
      isPartOf: { "@id": origin + "/#website" },
      breadcrumb: { "@id": url + "#breadcrumbs" },
      mainEntity: { "@id": url + (run ? "#report" : "#reports") },
    },
    run
      ? {
          "@type": "Report",
          "@id": url + "#report",
          url,
          headline: displayTitle(run),
          name: displayTitle(run),
          description: run.summary,
          abstract: run.scope,
          reportNumber: run.id,
          inLanguage: "en",
          articleSection: "Benchmarks",
          publisher: { "@id": origin + "/#organization" },
          mainEntityOfPage: { "@id": url + "#page" },
          about: { "@type": "Thing", name: run.category + " benchmarks" },
        }
      : {
          "@type": "ItemList",
          "@id": url + "#reports",
          name: "Published benchmark reports",
          numberOfItems: runs.length,
          itemListElement: runs.map((r, i) => ({
            "@type": "ListItem",
            position: i + 1,
            name: displayTitle(r),
            url: origin + reportPath(r.id),
          })),
        },
  ];
  return {
    title,
    description,
    url,
    robots: missing ? "noindex, follow" : "index, follow",
    schema: {
      "@context": "https://schema.org",
      "@graph": missing ? [] : graph,
    },
  };
}
export const jsonLD = (value: unknown) =>
  JSON.stringify(value)
    .replace(/</g, "\\u003c")
    .replace(/\u2028/g, "\\u2028")
    .replace(/\u2029/g, "\\u2029");
export function applyMetadata(run?: Run, missing = false) {
  const data = metadata(run, missing);
  document.title = data.title;
  for (const [attribute, key, value] of [
    ["name", "description", data.description],
    ["name", "robots", data.robots],
    ["property", "og:title", data.title],
    ["property", "og:description", data.description],
    ["property", "og:url", data.url],
    ["property", "og:type", run ? "article" : "website"],
    ["name", "twitter:title", data.title],
    ["name", "twitter:description", data.description],
  ]) {
    let tag = document.head.querySelector<HTMLMetaElement>(
      `meta[${attribute}="${key}"]`,
    );
    if (!tag) {
      tag = document.createElement("meta");
      tag.setAttribute(attribute, key);
      document.head.append(tag);
    }
    tag.content = value;
  }
  document
    .querySelector<HTMLLinkElement>('link[rel="canonical"]')
    ?.setAttribute("href", data.url);
  document
    .querySelectorAll('script[type="application/ld+json"]')
    .forEach((s) => s.remove());
  const script = document.createElement("script");
  script.type = "application/ld+json";
  script.textContent = jsonLD(data.schema);
  document.head.append(script);
}
