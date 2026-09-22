import Foundation

/// `--selftest-wake-live`: the wake word made measurable (roadmap P0-1, demo D7).
///
/// Plays the committed fixture set through the real spotter — `SherpaKeywordSpotter.spot(wav:)`,
/// the same entry `--selftest-wake` uses to prove "loaded" — with scratch keywords at the
/// three shipped grid points (sensitivities 0, 0.6 and 1.0, the exact rows of the
/// `WakeWordTuning` header table) and prints hit / false-accept rates plus per-variant
/// attribution. The per-sensitivity grid it prints **replaces** the one-off synthesised
/// runs the tuning header was measured on: same question, committed corpus, re-runnable.
///
/// Fixture set (`Tests/Fixtures/wake/`, see its README for the recipe):
/// - `hits/`: ≥20 clips of the manifest phrase across voices and speech rates, half
///   with a request after the phrase. Optional local microphone captures in
///   `Application Support/Next Notes/WakeWord/LiveFixtures/*.wav` are spotted too and
///   reported as `WAKE_MIC` — rooms no synthesis can fake — but never committed.
/// - `near-miss/`: 32 adversarial negatives grown from the three seeds named in the
///   `WakeWordTuning` header ("hey Bill …", "I will send …", "hey we need …").
/// - `manifest.json`: the phrase, the file list, and what each file is.
///
/// Verdict (printed as `WAKE_HIT n/N`, `WAKE_FALSE n/N`, `WAKE_HIT_RATE x`, then
/// `WAKE_LIVE_OK` / `WAKE_LIVE_FAILED`, the last line being what
/// `Scripts/run-selftest.sh` greps for):
///
/// - The bar is evaluated at the **shipped default, sensitivity 0.6** — what the user
///   experiences. `WAKE_HIT_RATE` is the hit rate there; it fails under 0.8 (D7 needs
///   ≥16/20), and `WAKE_FALSE` fails over 2 — the measured cost of the default in the
///   tuning header, on the same 32 negatives.
/// - The 0.0 and 1.0 columns are diagnostics, not gates: they show the grid the
///   default was chosen from.
///
/// Per-variant attribution comes from `WakeWordKeywords.diagnosticFile` (one display
/// name per pronunciation, sensitivity 1.0): every hit is re-spotted through it and
/// counted under its rule (`WAKE_VARIANT "dropped the h …": 7`), so a red run says
/// *which pronunciations* miss rather than just how many.
///
/// Dual-listener design is kept: the configured listener decides (hit/miss), the
/// generous one only explains (`heardAs`). The test never touches the live
/// `keywords.txt` — every keywords file it writes goes to a temp scratch directory.
///
/// Dispatch lives in `NextNotesApp.runRequestedSelfTest` (that file is not owned by
/// this change; the snippet is returned with it):
///
/// ```swift
/// if arguments.contains("--selftest-wake-live") {
///     Task { @MainActor in
///         let result = WakeWordLiveSelfTest.run(
///             fixtureDirectory: SelfTest.value(after: "--selftest-wake-live").map { URL(fileURLWithPath: $0) }
///         )
///         for line in result.summary { writeSelfTest(line) }
///         writeSelfTest(result.passed ? "WAKE_LIVE_OK: \(result.headline)" : "WAKE_LIVE_FAILED: \(result.headline)")
///         NSApp.terminate(nil)
///     }
///     return true
/// }
/// ```
///
/// Run from the repo root so the default fixture directory resolves:
/// `Scripts/run-selftest.sh --selftest-wake-live [fixture-dir]`.
enum WakeWordLiveSelfTest {
    struct Clip: Decodable, Sendable {
        var file: String
        var text: String
        var voice: String
        var rate: Int
    }

    struct Manifest: Decodable, Sendable {
        var phrase: String
        var hits: [Clip]
        var nearMisses: [Clip]
    }

    struct Outcome: Sendable {
        /// Lines for `writeSelfTest` (stdout + `--selftest-out` + the failed flag).
        var summary: [String]
        var headline: String
        var passed: Bool
    }

    /// The shipped default: what the user experiences, and therefore what the bar
    /// is evaluated at.
    static let headlineSensitivity = 0.6
    /// The grid re-run against the committed set.
    static let gridSensitivities = [0.0, 0.6, 1.0]
    /// D7 needs ≥16/20.
    static let minimumHitRate = 0.8
    /// The tuning header's measured cost of the default on 32 negatives.
    static let maximumFalseAccepts = 2

    /// Optional local microphone captures. Same probe, uncommitted voices in real
    /// rooms. Informational only: a miss here names the file for the user to check
    /// (it may not even contain the phrase) rather than failing the run.
    static var liveFixturesDirectory: URL {
        AppIdentity.applicationSupportDirectory
            .appendingPathComponent("WakeWord/LiveFixtures", isDirectory: true)
    }

    @MainActor
    static func run(fixtureDirectory: URL?) -> Outcome {
        var failures: [String] = []
        func fail(_ line: String, _ reasons: inout [String]) {
            SelfTest.diagnostic(line)
            reasons.append(line)
        }

        guard let directory = resolveFixtureDirectory(explicit: fixtureDirectory) else {
            let hint = "WAKE_LIVE_FIXTURES_MISSING: no manifest.json under Tests/Fixtures/wake "
                + "(run from the repo root, or pass a fixture directory: --selftest-wake-live <dir>)"
            SelfTest.diagnostic(hint)
            return Outcome(
                summary: ["WAKE_HIT 0/0", "WAKE_FALSE 0/0", "WAKE_HIT_RATE 0.00"],
                headline: "no fixture set",
                passed: false
            )
        }

        let manifestURL = directory.appendingPathComponent("manifest.json")
        guard let manifestData = try? Data(contentsOf: manifestURL),
              let manifest = try? JSONDecoder().decode(Manifest.self, from: manifestData)
        else {
            SelfTest.diagnostic("WAKE_LIVE_FIXTURES_MISSING: cannot decode \(manifestURL.path)")
            return Outcome(
                summary: ["WAKE_HIT 0/0", "WAKE_FALSE 0/0", "WAKE_HIT_RATE 0.00"],
                headline: "manifest unreadable",
                passed: false
            )
        }

        guard WakeWordModelManager.isReadyToLoad else {
            SelfTest.diagnostic("WAKE_LIVE_MODEL_MISSING: \(WakeWordModelManager.unavailableReason)")
            return Outcome(
                summary: ["WAKE_HIT 0/\(manifest.hits.count)", "WAKE_FALSE 0/\(manifest.nearMisses.count)", "WAKE_HIT_RATE 0.00"],
                headline: "keyword model not downloaded",
                passed: false
            )
        }

        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("nextnotes-wake-live-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        do {
            try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        } catch {
            SelfTest.diagnostic("WAKE_LIVE_FAILED: cannot create scratch dir: \(error.localizedDescription)")
            return Outcome(summary: [], headline: "no scratch dir", passed: false)
        }

        // One listener per grid point, plus the generous explainer. Scratch paths only:
        // writing the manifest phrase into the live keywords.txt is how `--selftest-wake`
        // used to replace the user's configured phrase on disk.
        var spotters: [(sensitivity: Double, spotter: SherpaKeywordSpotter)] = []
        for sensitivity in gridSensitivities {
            let tuning = WakeWordTuning.forSensitivity(sensitivity)
            guard let text = WakeWordKeywords.file(for: manifest.phrase, tuning: tuning) else {
                SelfTest.diagnostic("WAKE_LIVE_FAILED: manifest phrase cannot be encoded for the keyword model")
                return Outcome(summary: [], headline: "phrase unusable", passed: false)
            }
            let url = scratch.appendingPathComponent("keywords-\(sensitivity).txt")
            do {
                try text.write(to: url, atomically: true, encoding: .utf8)
                spotters.append((sensitivity, try WakeWordModelManager.loadSpotter(keywords: url, tuning: tuning)))
            } catch {
                SelfTest.diagnostic("WAKE_LIVE_FAILED: spotter did not load at sensitivity \(sensitivity): \(error.localizedDescription)")
                return Outcome(summary: [], headline: "spotter failed to load", passed: false)
            }
        }
        var generousRules: [String: String] = [:]
        var generous: SherpaKeywordSpotter?
        if let diagnostic = WakeWordKeywords.diagnosticFile(for: manifest.phrase, tuning: .forSensitivity(1)) {
            let url = scratch.appendingPathComponent("keywords-diagnostic.txt")
            if (try? diagnostic.text.write(to: url, atomically: true, encoding: .utf8)) != nil,
               let loaded = try? WakeWordModelManager.loadSpotter(keywords: url, tuning: .forSensitivity(1)) {
                generous = loaded
                generousRules = diagnostic.rules
            }
        }

        SelfTest.diagnostic(
            "  WAKE_LIVE_PHRASE: \(manifest.phrase) "
                + "(\(manifest.hits.count) hits, \(manifest.nearMisses.count) near-misses from \(directory.path))"
        )

        // MARK: Hits
        var hitsPerSensitivity: [Double: Int] = [:]
        var variantCounts: [String: Int] = [:]
        var missing = 0
        for clip in manifest.hits {
            let url = directory.appendingPathComponent(clip.file)
            guard FileManager.default.fileExists(atPath: url.path) else {
                missing += 1
                fail("  WAKE_LIVE_FIXTURE_MISSING: \(clip.file)", &failures)
                continue
            }
            var fired: [Double] = []
            for (sensitivity, spotter) in spotters {
                spotter.reset()
                let hit = (try? spotter.spot(wav: url)) != nil
                if hit {
                    hitsPerSensitivity[sensitivity, default: 0] += 1
                    fired.append(sensitivity)
                }
            }
            var rule = generousRules.isEmpty ? "as written" : "unattributed"
            if let explainer = generous {
                explainer.reset()
                if let tag = try? explainer.spot(wav: url) {
                    rule = generousRules[tag] ?? "as written"
                    if fired.contains(1.0) { variantCounts[rule, default: 0] += 1 }
                }
            }
            let marks = gridSensitivities.map { fired.contains($0) ? "hit" : "miss" }.joined(separator: "/")
            SelfTest.diagnostic("  WAKE_LIVE_CLIP \(clip.file) [\(marks)] as \"\(rule)\"")
        }

        // MARK: Near-misses
        var falsePerSensitivity: [Double: Int] = [:]
        for clip in manifest.nearMisses {
            let url = directory.appendingPathComponent(clip.file)
            guard FileManager.default.fileExists(atPath: url.path) else {
                missing += 1
                fail("  WAKE_LIVE_FIXTURE_MISSING: \(clip.file)", &failures)
                continue
            }
            for (sensitivity, spotter) in spotters {
                spotter.reset()
                let fired = (try? spotter.spot(wav: url)) != nil
                if fired {
                    falsePerSensitivity[sensitivity, default: 0] += 1
                    var rule = ""
                    if let explainer = generous, sensitivity == headlineSensitivity {
                        explainer.reset()
                        if let tag = try? explainer.spot(wav: url) {
                            rule = " as \"\(generousRules[tag] ?? tag)\""
                        }
                    }
                    SelfTest.diagnostic("  WAKE_LIVE_FALSE_ACCEPT \(clip.file) @\(sensitivity)\(rule) — “\(clip.text)”")
                }
            }
        }

        // MARK: Grid (replaces the one-off synth runs in the tuning header)
        for sensitivity in gridSensitivities {
            let hits = hitsPerSensitivity[sensitivity] ?? 0
            let falses = falsePerSensitivity[sensitivity] ?? 0
            SelfTest.diagnostic(
                "  WAKE_LIVE_GRID sens=\(sensitivity) hits=\(hits)/\(manifest.hits.count) false=\(falses)/\(manifest.nearMisses.count)"
            )
        }
        for rule in variantCounts.keys.sorted() {
            SelfTest.diagnostic("  WAKE_VARIANT \"\(rule)\": \(variantCounts[rule] ?? 0)")
        }

        // MARK: Local microphone captures (informational)
        reportLiveCaptures(generous: generous, generousRules: generousRules)

        let headlineHits = hitsPerSensitivity[headlineSensitivity] ?? 0
        let headlineFalse = falsePerSensitivity[headlineSensitivity] ?? 0
        let hitRate = manifest.hits.isEmpty ? 0 : Double(headlineHits) / Double(manifest.hits.count)
        if missing > 0 { failures.append("\(missing) fixture file(s) missing") }
        if hitRate < minimumHitRate {
            failures.append("hit rate \(String(format: "%.2f", hitRate)) under \(minimumHitRate) at sensitivity \(headlineSensitivity)")
        }
        if headlineFalse > maximumFalseAccepts {
            failures.append("\(headlineFalse) false accepts over \(maximumFalseAccepts) at sensitivity \(headlineSensitivity)")
        }

        let summary = [
            "WAKE_HIT \(headlineHits)/\(manifest.hits.count)",
            "WAKE_FALSE \(headlineFalse)/\(manifest.nearMisses.count)",
            "WAKE_HIT_RATE \(String(format: "%.2f", hitRate))",
        ]
        let headline = "\(headlineHits)/\(manifest.hits.count) hits, "
            + "\(headlineFalse)/\(manifest.nearMisses.count) false at sens \(headlineSensitivity)"
            + (failures.isEmpty ? "" : " — \(failures.joined(separator: "; "))")
        return Outcome(summary: summary, headline: headline, passed: failures.isEmpty)
    }

    // MARK: - Fixture resolution

    /// Explicit path first, then `Tests/Fixtures/wake` under the working directory
    /// (true when launched via `Scripts/run-selftest.sh` from the repo root).
    static func resolveFixtureDirectory(explicit: URL?) -> URL? {
        if let explicit {
            let manifest = explicit.appendingPathComponent("manifest.json")
            if FileManager.default.fileExists(atPath: manifest.path) { return explicit }
            return nil
        }
        let relative = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Tests/Fixtures/wake", isDirectory: true)
        if FileManager.default.fileExists(atPath: relative.appendingPathComponent("manifest.json").path) {
            return relative
        }
        return nil
    }

    @MainActor
    private static func reportLiveCaptures(
        generous: SherpaKeywordSpotter?,
        generousRules: [String: String]
    ) {
        let directory = liveFixturesDirectory
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ).filter({ ["wav", "aiff", "caf"].contains($0.pathExtension.lowercased()) }).sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) else {
            SelfTest.diagnostic("  WAKE_MIC: no local captures (record into \(directory.path) to cover real rooms)")
            return
        }
        guard !files.isEmpty else {
            SelfTest.diagnostic("  WAKE_MIC: no local captures (record into \(directory.path) to cover real rooms)")
            return
        }
        // Reuse the wide-open grid listener for captures: the question is audibility,
        // not the shipped threshold.
        let tuning = WakeWordTuning.forSensitivity(1)
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("nextnotes-wake-live-captures-\(UUID().uuidString).txt")
        guard let phrase = currentManifestPhrase(),
              let text = WakeWordKeywords.file(for: phrase, tuning: tuning),
              (try? text.write(to: scratch, atomically: true, encoding: .utf8)) != nil,
              let spotter = try? WakeWordModelManager.loadSpotter(keywords: scratch, tuning: tuning)
        else {
            SelfTest.diagnostic("  WAKE_MIC: could not build a listener for local captures")
            return
        }
        defer { try? FileManager.default.removeItem(at: scratch) }
        var heard = 0
        for file in files {
            spotter.reset()
            let hit = (try? spotter.spot(wav: file)) != nil
            if hit { heard += 1 }
            var rule = ""
            if let explainer = generous {
                explainer.reset()
                if let tag = try? explainer.spot(wav: file) {
                    rule = " as \"\(generousRules[tag] ?? tag)\""
                }
            }
            SelfTest.diagnostic(hit
                ? "  WAKE_MIC_HIT \(file.lastPathComponent)\(rule)"
                : "  WAKE_MIC_MISS \(file.lastPathComponent)\(rule) — check it contains the phrase")
        }
        SelfTest.diagnostic("  WAKE_MIC: \(heard)/\(files.count) local captures heard (informational, not in the verdict)")
    }

    private static func currentManifestPhrase() -> String? {
        guard let directory = resolveFixtureDirectory(explicit: nil),
              let data = try? Data(contentsOf: directory.appendingPathComponent("manifest.json")),
              let manifest = try? JSONDecoder().decode(Manifest.self, from: data)
        else { return nil }
        return manifest.phrase
    }
}
