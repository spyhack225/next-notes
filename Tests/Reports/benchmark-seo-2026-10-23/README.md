# Benchmark SEO — 23 October 2026

## Confirmed cause and repair

The original production request `/?page=benchmarks&run=2026-09-13-tts-apple` returned title `Next Notes | Already on it, before you even ask`, canonical `https://next-notes.com/`, homepage SoftwareApplication schema and homepage fallback content before JavaScript. A client title effect alone could not correct that initial response.

The existing Vite build now emits `/benchmarks/` and one HTML document per explicitly approved report, using the existing public catalog/detail JSON only. Every document includes unique title/description, canonical, Open Graph/Twitter metadata, readable reviewed report content, and JSON-LD. Index: CollectionPage + ItemList; individual pages: WebPage + Report; both include linked WebSite/Organization and BreadcrumbList. No ratings, invented authors, publication dates, modification dates or aggregate acceptance are inferred. Evaluation dates remain visible evaluation dates. Original evidence stays in place. Existing UI/CSS, fonts, logo, colors, orb and animation are unchanged.

The shared metadata producer also updates in-app browser navigation. Internal links use canonical paths. Legacy query/hash links still render correctly and declare the new canonical after JavaScript runs; the static host cannot return query-specific head content at `/`. Search/filter variants canonicalize to their unfiltered page. Missing reports show noindex and no report schema after client routing. Unknown paths remain subject to the static host's fallback/status behavior; they are not generated or included in the sitemap.

Build generation replaces only its owned `docs/benchmarks/` directory, so revoked publications disappear from new output. Sitemap has 73 canonical URLs (home, index, 71 reports). No speculative last-modified dates are emitted. Relative template asset/icon paths are rewritten for nested documents. Original/private report contents are never read by the page generator.

## Verification

- Original live HTML reproduced the homepage metadata defect (above).
- 15 Python catalog/privacy tests pass; 12 Node comparison/SEO tests pass.
- TypeScript, lint and production build pass. Existing Vite main-chunk size advisory remains.
- Build-time validator checks all 72 HTML documents: unique canonical and description, exact parsed JSON-LD, fallback content, real asset paths, sitemap membership and generated directory membership. Tests include legacy/path routing, unavailable reports and script-termination escaping.
- Schema.org Validator code-snippet tests on generated index and representative Apple report: zero errors, zero warnings. Screenshots retained alongside this report.
- Browser checks: nested report loads original UI, back navigation updates metadata/schema to the index, legacy query opens the correct report and canonical, missing report is excluded from indexing.
- Production verification recorded separately after deployment.

References: [Google structured-data policies](https://developers.google.com/search/docs/appearance/structured-data/sd-policies), [Google breadcrumbs](https://developers.google.com/search/docs/appearance/structured-data/breadcrumb), [Schema.org Report](https://schema.org/Report). Valid markup does not guarantee indexing or rich-result appearance. Search Console submission/account inspection was not performed.
