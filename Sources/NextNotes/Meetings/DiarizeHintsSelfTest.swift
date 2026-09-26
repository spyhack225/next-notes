import Foundation

/// `--selftest-diarize-hints`: speaker-count hints, the voice-print cluster merge,
/// and the measurement that fixed the merge threshold (M-03).
///
/// The diarizer used to cluster blind: `OfflineDiarizerManager(config: .default)` with
/// no speaker count and no post-merge, and a 1:1 WhatsApp call came back as three
/// speakers a person then renamed by hand — after the notes had already named
/// "Speaker 1" (I2 #3). The fix is three layers, all exercised here:
///
/// - **a. Pure hints.** `SpeakerCountHint.for` reads the meeting's own shape: a
///   messaging/FaceTime-class detected call gets `maxSpeakers = 2`; a calendar meeting
///   gets `max(2, attendees.count)`; a browser, an unknown app or a meeting with no
///   attendee list gets nothing.
/// - **b. Pure merge.** `MeetingDiarizer.mergeClusters` merges clusters whose centroids
///   are the same voice (cosine ≥ the measured threshold) and, with a `maxSpeakers`,
///   merges the closest pairs until the count fits.
/// - **c. Model-backed.** The `fr-1to1-system.wav` fixture (one far voice) with the
///   WhatsApp hint must never come back with more than 2 far-end clusters, and
///   `fr-call-system.wav` (two far voices) must come back as 2 clusters after the merge.
///   Without the diarizer models on disk this half prints `DIARIZE_HINTS_ABSENT` and the
///   pure halves still grade.
///
/// The **measurement mode** runs the diarizer without hints or merge over both fixtures
/// and prints every centroid pair's cosine similarity with whether the pair is the same
/// manifest speaker. `mergeThreshold` must sit strictly between the highest
/// different-speaker similarity and the lowest same-speaker similarity of that table; if
/// the ranges ever overlap, the merge is unset (hint only) and that decision is written
/// down rather than a guessed number shipped.
@MainActor
enum DiarizeHintsSelfTest {
    struct FixtureTurn {
        var speaker: String
        var start: TimeInterval
        var end: TimeInterval
    }

    static func run(write: (String) -> Void) async -> [String] {
        var failures: [String] = []
        func check(_ name: String, _ condition: Bool) {
            if !condition { failures.append(name) }
        }

        // MARK: a. Pure hints

        func meeting(
            title: String,
            providerID: String?,
            calendarEventID: String?,
            attendees: [String]
        ) -> Meeting {
            Meeting(
                title: title,
                start: Date(timeIntervalSince1970: 1_758_800_000),
                end: nil,
                calendarEventID: calendarEventID,
                providerID: providerID,
                attendees: attendees
            )
        }

        do {
            let whatsapp = meeting(
                title: "WhatsApp call",
                providerID: CalendarProviderID.detectedCall.rawValue,
                calendarEventID: "net.whatsapp.WhatsApp@1758800000",
                attendees: []
            )
            check(
                "WhatsApp detected call hint is not max 2 (\(String(describing: SpeakerCountHint.for(whatsapp)?.maxSpeakers)))",
                SpeakerCountHint.for(whatsapp)?.maxSpeakers == 2
            )

            let facetime = meeting(
                title: "FaceTime call",
                providerID: CalendarProviderID.detectedCall.rawValue,
                calendarEventID: "com.apple.FaceTime@1758800000",
                attendees: []
            )
            check(
                "FaceTime detected call hint is not max 2 (\(String(describing: SpeakerCountHint.for(facetime)?.maxSpeakers)))",
                SpeakerCountHint.for(facetime)?.maxSpeakers == 2
            )

            let chrome = meeting(
                title: "Chrome call",
                providerID: CalendarProviderID.detectedCall.rawValue,
                calendarEventID: "com.google.Chrome@1758800000",
                attendees: []
            )
            check(
                "a browser call got a hint (\(String(describing: SpeakerCountHint.for(chrome))))",
                SpeakerCountHint.for(chrome) == nil
            )

            let calendar = meeting(
                title: "Budget review",
                providerID: CalendarProviderID.eventKit.rawValue,
                calendarEventID: "eventkit-1",
                attendees: ["Ana", "Ben", "Chloé", "Dara"]
            )
            check(
                "a 4-attendee calendar meeting hint is not max 4 (\(String(describing: SpeakerCountHint.for(calendar)?.maxSpeakers)))",
                SpeakerCountHint.for(calendar)?.maxSpeakers == 4
            )

            let noAttendees = meeting(
                title: "Held by hand",
                providerID: CalendarProviderID.eventKit.rawValue,
                calendarEventID: nil,
                attendees: []
            )
            check(
                "a meeting with no attendee list got a hint (\(String(describing: SpeakerCountHint.for(noAttendees))))",
                SpeakerCountHint.for(noAttendees) == nil
            )
        }

        // MARK: b. Pure merge

        do {
            // Three clusters: two of them the same voice at cosine 0.95, the third
            // orthogonal to both. e1 = [1,0,0,0]; e2 at 0.95 of e1; e3 = [0,0,1,0].
            let same: Float = 0.95
            let e1: [Float] = [1, 0, 0, 0]
            let e2: [Float] = [same, (1 - same * same).squareRoot(), 0, 0]
            let e3: [Float] = [0, 0, 1, 0]
            func run(_ id: String, _ start: TimeInterval, _ end: TimeInterval, _ e: [Float]) -> MeetingDiarizer.SpeakerRun {
                MeetingDiarizer.SpeakerRun(speakerID: id, start: start, end: end, embedding: e)
            }
            let three = [
                run("c1", 0, 4, e1), run("c1", 20, 24, e1),
                run("c2", 5, 9, e2), run("c2", 25, 29, e2),
                run("c3", 10, 14, e3), run("c3", 30, 34, e3),
            ]
            let mergedTwo = MeetingDiarizer.mergeClusters(three, threshold: MeetingDiarizer.mergeThreshold)
            check(
                "cosine-\(same) pair did not merge (got \(Set(mergedTwo.map(\.speakerID)).count) clusters, want 2)",
                Set(mergedTwo.map(\.speakerID)).count == 2
            )
            let mergedOne = MeetingDiarizer.mergeClusters(three, maxSpeakers: 1, threshold: MeetingDiarizer.mergeThreshold)
            check(
                "maxSpeakers 1 did not squeeze to one cluster (got \(Set(mergedOne.map(\.speakerID)).count))",
                Set(mergedOne.map(\.speakerID)).count == 1
            )
            check(
                "merging dropped or moved runs (got \(mergedTwo.count), want \(three.count))",
                mergedTwo.count == three.count
            )
        }

        // MARK: c. Model-backed

        let fixtures = FixtureSource()
        guard fixtures.available else {
            write("DIARIZE_HINTS_ABSENT: \(fixtures.absentReason)")
            return failures
        }
        guard MeetingDiarizer.isDownloaded else {
            write("DIARIZE_HINTS_ABSENT: diarizer models not downloaded — model-backed half skipped")
            return failures
        }

        do {
            let call = try fixtures.samples("fr-call-system.wav")
            let one = try fixtures.samples("fr-1to1-system.wav")
            let callTurns = fixtures.turns("fr-call-system.wav")
            let oneTurns = fixtures.turns("fr-1to1-system.wav")

            // Raw, unhinted, unmerged: what the clustering finds before anything here
            // touches it. This is the measurement the threshold was fixed from.
            let callRaw = try await MeetingDiarizer.shared.speakerRuns(in: call, merged: false)
            let oneRaw = try await MeetingDiarizer.shared.speakerRuns(in: one, merged: false)
            write("DIARIZE_HINTS_RAW fr-call-system.wav clusters=\(Set(callRaw.map(\.speakerID)).count) runs=\(callRaw.count)")
            write("DIARIZE_HINTS_RAW fr-1to1-system.wav clusters=\(Set(oneRaw.map(\.speakerID)).count) runs=\(oneRaw.count)")

            var differentMax = -Double.infinity
            var sameMin = Double.infinity
            let collect: (_ similarity: Double, _ isSame: Bool) -> Void = { similarity, isSame in
                if isSame { sameMin = min(sameMin, similarity) } else { differentMax = max(differentMax, similarity) }
            }
            measure(callRaw, turns: callTurns, label: "fr-call-system.wav", write: write, collect: collect)
            measure(oneRaw, turns: oneTurns, label: "fr-1to1-system.wav", write: write, collect: collect)

            // The same-speaker pairs: each fixture alone is single-voice or cleanly
            // two-voice, so neither carries one. The manifest gives both files the same
            // B voice, so both concatenated — one clustering pass over 68 s — pairs
            // B-with-B across the files against B-with-C inside the call.
            let oneDuration = fixtures.duration("fr-1to1-system.wav")
            var combined = one
            combined.append(contentsOf: call)
            let combinedTurns = oneTurns + callTurns.map {
                FixtureTurn(speaker: $0.speaker, start: $0.start + oneDuration, end: $0.end + oneDuration)
            }
            let combinedRaw = try await MeetingDiarizer.shared.speakerRuns(in: combined, merged: false)
            write("DIARIZE_HINTS_RAW combined clusters=\(Set(combinedRaw.map(\.speakerID)).count) runs=\(combinedRaw.count)")
            measure(combinedRaw, turns: combinedTurns, label: "combined", write: write, collect: collect)

            let shipped = MeetingDiarizer.mergeThreshold
            if differentMax.isFinite, sameMin.isFinite {
                let midpoint = (differentMax + sameMin) / 2
                write(String(
                    format: "DIARIZE_HINTS_MEASURE differentMax=%.4f sameMin=%.4f midpoint=%.4f shipped=%@",
                    differentMax, sameMin, midpoint,
                    shipped.map { String(format: "%.4f", $0) } ?? "none"
                ))
                if let shipped {
                    check(
                        String(format: "shipped threshold %.4f is not between differentMax %.4f and sameMin %.4f", shipped, differentMax, sameMin),
                        shipped > differentMax && shipped < sameMin
                    )
                }
            } else {
                // A single-voice fixture measures no pairs, which is correct — but with
                // no different-speaker pair at all the threshold has nothing to sit
                // above, and the between-check cannot run. The merge then rests on the
                // synthetic cases alone; say so rather than assert nothing silently.
                if !differentMax.isFinite {
                    write("DIARIZE_HINTS_MEASURE incomplete: no different-speaker pair was measured")
                    check("no different-speaker pair was measured", false)
                } else {
                    write(
                        "DIARIZE_HINTS_MEASURE sameMin unmeasured (no same-speaker pair on any track) — "
                            + "the between-check is skipped, the merge rests on the synthetic cases"
                    )
                }
            }

            // The target: a 1:1 call never returns more than 2 far-end clusters. Full
            // production path — hint to config, clustering, then the merge.
            let hinted = try await MeetingDiarizer.shared.speakerRuns(
                in: one,
                hint: SpeakerCountHint(maxSpeakers: 2)
            )
            let hintedClusters = Set(hinted.map(\.speakerID)).count
            write("DIARIZE_HINTS_ONE_TO_ONE clusters=\(hintedClusters)")
            check(
                "the 1:1 fixture with the WhatsApp hint returned \(hintedClusters) far-end clusters (never more than 2)",
                hintedClusters >= 1 && hintedClusters <= 2
            )

            // Two far voices, no hint: the merge alone must land on 2 clusters. The
            // merge is the same pure call the production path applies to the raw runs.
            let callMerged = MeetingDiarizer.mergeClusters(
                callRaw, maxSpeakers: nil, threshold: MeetingDiarizer.mergeThreshold
            )
            let callClusters = Set(callMerged.map(\.speakerID)).count
            write("DIARIZE_HINTS_CALL_NO_HINT clusters=\(callClusters)")
            check(
                "the two-voice fixture with no hint came back as \(callClusters) clusters after merge (want 2)",
                callClusters == 2
            )
        } catch {
            failures.append("model-backed half failed: \(error.localizedDescription)")
        }

        return failures
    }

    // MARK: - Measurement

    /// Prints one line per pair of clusters: cosine similarity of their duration-weighted
    /// centroids, and whether the pair is the same manifest speaker. `collect` receives
    /// the same verdicts the lines carry.
    static func measure(
        _ runs: [MeetingDiarizer.SpeakerRun],
        turns: [FixtureTurn],
        label: String,
        write: (String) -> Void,
        collect: (_ similarity: Double, _ isSame: Bool) -> Void
    ) {
        let centroids = Self.centroids(of: runs)
        let owners = clusterOwners(runs, centroids: centroids, turns: turns)
        let ids = centroids.keys.sorted()
        for (index, first) in ids.enumerated() {
            for second in ids[(index + 1)...] {
                guard let firstCentroid = centroids[first], let secondCentroid = centroids[second],
                      let similarity = MeetingDiarizer.cosine(firstCentroid, secondCentroid) else { continue }
                let firstOwner = owners[first] ?? "unmapped"
                let secondOwner = owners[second] ?? "unmapped"
                let isSame = firstOwner == secondOwner && firstOwner != "unmapped"
                write(String(
                    format: "DIARIZE_HINTS_MEASURE %@ %@×%@ sim=%.4f %@", label, first, second,
                    similarity, isSame ? "same(\(firstOwner))" : "different(\(firstOwner)/\(secondOwner))"
                ))
                collect(similarity, isSame)
            }
        }
    }

    /// Duration-weighted mean embedding per cluster, exactly what
    /// `MeetingVoicePrints.centroids` averages (without its minimum-seconds gate — a
    /// cluster that talks for two seconds still gets measured).
    static func centroids(of runs: [MeetingDiarizer.SpeakerRun]) -> [String: [Double]] {
        var sums: [String: [Double]] = [:]
        var weights: [String: Double] = [:]
        for run in runs where !run.embedding.isEmpty {
            let weight = Double(max(0, run.end - run.start))
            guard weight > 0 else { continue }
            var sum = sums[run.speakerID] ?? [Double](repeating: 0, count: run.embedding.count)
            guard sum.count == run.embedding.count else { continue }
            for index in sum.indices { sum[index] += Double(run.embedding[index]) * weight }
            sums[run.speakerID] = sum
            weights[run.speakerID, default: 0] += weight
        }
        var result: [String: [Double]] = [:]
        for (id, sum) in sums {
            guard let weight = weights[id], weight > 0 else { continue }
            result[id] = sum.map { $0 / weight }
        }
        return result
    }

    /// Which manifest speaker each cluster mostly overlaps, by total shared time. A
    /// cluster can straddle turns, so its time is summed per speaker and the speaker with
    /// the most of it wins.
    static func clusterOwners(
        _ runs: [MeetingDiarizer.SpeakerRun],
        centroids: [String: [Double]],
        turns: [FixtureTurn]
    ) -> [String: String] {
        var totalsBySpeaker: [String: [String: Double]] = [:]
        for run in runs where centroids[run.speakerID] != nil {
            for turn in turns {
                let shared = min(run.end, turn.end) - max(run.start, turn.start)
                guard shared > 0 else { continue }
                totalsBySpeaker[run.speakerID, default: [:]][turn.speaker, default: 0] += shared
            }
        }
        var owners: [String: String] = [:]
        for (id, totals) in totalsBySpeaker {
            owners[id] = totals.max { $0.value < $1.value }?.key
        }
        return owners
    }

    static func cosine(_ a: [Double], _ b: [Double]) -> Double? {
        guard a.count == b.count, !a.isEmpty else { return nil }
        var dot = 0.0
        var normA = 0.0
        var normB = 0.0
        for index in a.indices {
            dot += a[index] * b[index]
            normA += a[index] * a[index]
            normB += b[index] * b[index]
        }
        let denominator = (normA * normB).squareRoot()
        guard denominator > 0, denominator.isFinite else { return nil }
        return dot / denominator
    }

    // MARK: - Fixtures

    /// `manifest.json` and the two far-end wavs, from `$NEXTNOTES_FIXTURES/meetings` or
    /// `./Tests/Fixtures/meetings` (the same search `DiarizeAssignSelfTest` makes).
    struct FixtureSource {
        let directory: URL?
        let manifest: [String: (duration: TimeInterval, turns: [FixtureTurn])]?

        var available: Bool { manifest != nil && directory != nil }
        var absentReason: String {
            if manifest == nil { return "meeting fixture manifest not found" }
            return "meeting fixtures not found at \(directory?.path ?? "nil")"
        }

        init() {
            func manifestURL() -> URL? {
                let manager = FileManager.default
                if let root = ProcessInfo.processInfo.environment["NEXTNOTES_FIXTURES"] {
                    let url = URL(fileURLWithPath: root).appendingPathComponent("meetings/manifest.json")
                    if manager.fileExists(atPath: url.path) { return url }
                }
                let local = URL(fileURLWithPath: manager.currentDirectoryPath)
                    .appendingPathComponent("Tests/Fixtures/meetings/manifest.json")
                if manager.fileExists(atPath: local.path) { return local }
                return nil
            }
            guard let url = manifestURL(),
                  let data = try? Data(contentsOf: url),
                  let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let files = root["files"] as? [String: Any]
            else {
                directory = nil
                manifest = nil
                return
            }
            directory = url.deletingLastPathComponent()
            var parsed: [String: (TimeInterval, [FixtureTurn])] = [:]
            for (name, rawEntry) in files {
                guard let entry = rawEntry as? [String: Any],
                      let duration = entry["duration"] as? Double,
                      let rawTurns = entry["turns"] as? [[String: Any]]
                else { continue }
                let turns: [FixtureTurn] = rawTurns.compactMap { raw in
                    guard let speaker = raw["speaker"] as? String,
                          let start = raw["start"] as? Double,
                          let end = raw["end"] as? Double
                    else { return nil }
                    return FixtureTurn(speaker: speaker, start: start, end: end)
                }
                guard !turns.isEmpty else { continue }
                parsed[name] = (duration, turns)
            }
            manifest = parsed
        }

        func turns(_ name: String) -> [FixtureTurn] {
            manifest?[name]?.turns ?? []
        }

        func duration(_ name: String) -> TimeInterval {
            manifest?[name]?.duration ?? 0
        }

        func samples(_ name: String) throws -> [Float] {
            try AudioConversion.monoSamples(
                fromFileAt: directory!.appendingPathComponent(name),
                sampleRate: ChunkedTranscriber.sampleRate
            )
        }
    }
}
