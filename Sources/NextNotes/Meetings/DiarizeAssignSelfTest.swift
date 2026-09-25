import Foundation

/// `--selftest-diarize-assign`: short far-end segments inherit the nearest
/// speaker run or agreeing neighbours (M-04).
///
/// `MeetingDiarizer.assign` used to label only segments overlapping a speaker
/// run, so short finals falling between runs stayed "Others" (I2 #4: 29–50 %
/// of far-end lines in three meetings). The fallback is two pure,
/// deterministic rules: the nearest run within 1.0 s (ties go to the earlier
/// run), else the labelled system neighbours on both sides when they agree.
///
/// Cases a–e are hand-built runs and segments. Case f derives runs and
/// segments from the `fr-call-system.wav` fixture manifest (M-16a): runs are
/// the B/C turns shrunk 0.4 s at each end, the way real runs miss low-energy
/// edges, and segments are 0.9 s short finals on a uniform grid — Parakeet
/// windows tile time without regard to turn boundaries (I2 #1's hard cuts
/// mid-word), and 0.9 s is the middle of the measured unlabelled medians
/// (0.72–1.36 s). Only pieces covering B/C speech are kept: a transcript has
/// no segments over silence, and labelling silence would be a lie.
///
/// No model, no store, nothing written. Reads `manifest.json` from
/// `$NEXTNOTES_FIXTURES/meetings` or `./Tests/Fixtures/meetings` when present
/// and falls back to the embedded turns (byte-identical to the manifest)
/// otherwise, saying which source it used.
enum DiarizeAssignSelfTest {
    /// Length of one modelled short final, in seconds (I2 #4 medians).
    static let fixtureFinalSeconds = 0.9
    /// M-04 target: unattributed far-end lines on the fixture.
    static let unattributedLimit = 0.10

    struct ManifestTurn {
        var speaker: String
        var start: TimeInterval
        var end: TimeInterval
    }

    static func run(write: (String) -> Void) -> [String] {
        var failures: [String] = []
        func check(_ name: String, _ condition: Bool) {
            if !condition { failures.append(name) }
        }

        // a. A short segment just past a run takes that run's speaker.
        do {
            let runs = [MeetingDiarizer.SpeakerRun(speakerID: "c1", start: 10, end: 12)]
            let segments = [TranscriptSegment(
                start: 12.4, end: 13.2, text: "D'accord.", source: .system
            )]
            let labelled = MeetingDiarizer.assign(segments, to: runs)
            check(
                "nearest run did not label the segment (want Speaker 1, got \(labelled.first?.speaker ?? "nil"))",
                labelled.first?.speaker == "Speaker 1"
            )
        }

        // a2. Equidistant runs: the earlier run wins.
        do {
            let runs = [
                MeetingDiarizer.SpeakerRun(speakerID: "c1", start: 0, end: 10),
                MeetingDiarizer.SpeakerRun(speakerID: "c2", start: 12, end: 22),
            ]
            let segments = [TranscriptSegment(
                start: 10.5, end: 11.5, text: "Oui.", source: .system
            )]
            let labelled = MeetingDiarizer.assign(segments, to: runs)
            check(
                "tied runs did not prefer the earlier one (want Speaker 1, got \(labelled.first?.speaker ?? "nil"))",
                labelled.first?.speaker == "Speaker 1"
            )
        }

        // b. Far from every run, disagreeing neighbours: stays unlabelled.
        do {
            let runs = [
                MeetingDiarizer.SpeakerRun(speakerID: "c1", start: 0, end: 1),
                MeetingDiarizer.SpeakerRun(speakerID: "c2", start: 100, end: 101),
            ]
            let segments = [
                TranscriptSegment(start: 10, end: 11, text: "Oui.", source: .system, speaker: "Speaker 1"),
                TranscriptSegment(start: 20, end: 21, text: "Alors.", source: .system),
                TranscriptSegment(start: 30, end: 31, text: "Non.", source: .system, speaker: "Speaker 2"),
            ]
            let labelled = MeetingDiarizer.assign(segments, to: runs)
            check(
                "disagreeing neighbours labelled the middle segment (got \(labelled[1].speaker ?? "nil"))",
                labelled[1].speaker == nil
            )
            check("the preset neighbours lost their labels", labelled[0].speaker == "Speaker 1" && labelled[2].speaker == "Speaker 2")
        }

        // c. Far from every run, agreeing neighbours: takes their speaker.
        do {
            let runs = [
                MeetingDiarizer.SpeakerRun(speakerID: "c1", start: 0, end: 1),
                MeetingDiarizer.SpeakerRun(speakerID: "c2", start: 100, end: 101),
            ]
            let segments = [
                TranscriptSegment(start: 10, end: 11, text: "Oui.", source: .system, speaker: "Speaker 2"),
                TranscriptSegment(start: 20, end: 21, text: "Alors.", source: .system),
                TranscriptSegment(start: 30, end: 31, text: "Voilà.", source: .system, speaker: "Speaker 2"),
            ]
            let labelled = MeetingDiarizer.assign(segments, to: runs)
            check(
                "agreeing neighbours did not label the middle segment (got \(labelled[1].speaker ?? "nil"))",
                labelled[1].speaker == "Speaker 2"
            )
        }

        // d. Overlap wins over proximity: a segment inside c2's run keeps c2's
        // label even though c1 starts nearer to the segment's far edge.
        do {
            let runs = [
                MeetingDiarizer.SpeakerRun(speakerID: "c1", start: 0, end: 10),
                MeetingDiarizer.SpeakerRun(speakerID: "c2", start: 20, end: 30),
            ]
            let segments = [TranscriptSegment(
                start: 29.9, end: 30.4, text: "À lundi.", source: .system
            )]
            let labelled = MeetingDiarizer.assign(segments, to: runs)
            check(
                "overlap did not win (want Speaker 2, got \(labelled.first?.speaker ?? "nil"))",
                labelled.first?.speaker == "Speaker 2"
            )
        }

        // e. Mic segments are never touched, with or without an overlapping run.
        do {
            let runs = [MeetingDiarizer.SpeakerRun(speakerID: "c1", start: 0, end: 10)]
            let segments = [
                TranscriptSegment(start: 0.5, end: 1.5, text: "Allô.", source: .mic),
                TranscriptSegment(start: 50, end: 51, text: "Tu m'entends.", source: .mic),
            ]
            let labelled = MeetingDiarizer.assign(segments, to: runs)
            check(
                "a mic segment was labelled (\(labelled.map { $0.speaker ?? "nil" }))",
                labelled.allSatisfy { $0.speaker == nil }
            )
        }

        // f. Fixture-derived: short finals over the real 3-person call.
        do {
            let fixture = loadFixture(write: write)
            guard !fixture.runs.isEmpty, !fixture.segments.isEmpty else {
                failures.append("fixture \(fixture.source) yielded no runs or segments")
                return failures
            }
            let labelled = MeetingDiarizer.assign(fixture.segments, to: fixture.runs)
            let unlabelled = labelled.filter { $0.speaker == nil }.count
            let share = Double(unlabelled) / Double(labelled.count)
            write(String(format:
                "DIARIZE_ASSIGN fixture=%@ segments=%d unattributed=%d (%.1f%%, limit %.0f%%)",
                fixture.source, labelled.count, unlabelled, share * 100, unattributedLimit * 100))
            check(
                String(format: "fixture unattributed share %.1f%% exceeds %.0f%%", share * 100, unattributedLimit * 100),
                share <= unattributedLimit
            )
        }

        return failures
    }

    // MARK: - Fixture

    struct FixtureCall {
        var source: String
        var runs: [MeetingDiarizer.SpeakerRun]
        var segments: [TranscriptSegment]
    }

    /// Real runs miss low-energy turn edges; shrink each audible turn 0.4 s at
    /// each end. Only B/C turns carry audio on the system track — A's turns
    /// are silence there, and a diarizer emits no runs over silence.
    static func buildFixture(turns: [ManifestTurn], duration: TimeInterval) -> FixtureCall {
        let audible = turns.filter { $0.speaker == "B" || $0.speaker == "C" }
        let runs = audible.map {
            MeetingDiarizer.SpeakerRun(speakerID: $0.speaker, start: $0.start + 0.4, end: $0.end - 0.4)
        }
        var segments: [TranscriptSegment] = []
        var start = 0.0
        while start < duration {
            let end = min(start + fixtureFinalSeconds, duration)
            let coversSpeech = audible.contains {
                min(end, $0.end) - max(start, $0.start) > 0
            }
            if coversSpeech {
                segments.append(TranscriptSegment(
                    start: start, end: end, text: "…", source: .system
                ))
            }
            start = end
        }
        return FixtureCall(source: "built", runs: runs, segments: segments)
    }

    static func loadFixture(write: (String) -> Void) -> FixtureCall {
        if let url = manifestURL(),
           let data = try? Data(contentsOf: url),
           let parsed = parseManifest(data) {
            var fixture = buildFixture(turns: parsed.turns, duration: parsed.duration)
            fixture.source = url.path
            return fixture
        }
        write("DIARIZE_ASSIGN fixture=embedded (manifest.json not found)")
        var fixture = buildFixture(turns: embeddedTurns, duration: embeddedDuration)
        fixture.source = "embedded"
        return fixture
    }

    static func manifestURL() -> URL? {
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

    static func parseManifest(_ data: Data) -> (turns: [ManifestTurn], duration: TimeInterval)? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let files = root["files"] as? [String: Any],
              let entry = files["fr-call-system.wav"] as? [String: Any],
              let duration = entry["duration"] as? Double,
              let rawTurns = entry["turns"] as? [[String: Any]]
        else { return nil }
        let turns: [ManifestTurn] = rawTurns.compactMap { raw in
            guard let speaker = raw["speaker"] as? String,
                  let start = raw["start"] as? Double,
                  let end = raw["end"] as? Double
            else { return nil }
            return ManifestTurn(speaker: speaker, start: start, end: end)
        }
        guard !turns.isEmpty else { return nil }
        return (turns, duration)
    }

    /// The B/C turns of `fr-call-system.wav`'s manifest entry, byte-identical
    /// values, used only when `manifest.json` cannot be found on disk.
    static let embeddedDuration: TimeInterval = 42.074
    static let embeddedTurns: [ManifestTurn] = [
        ManifestTurn(speaker: "B", start: 3.166, end: 6.009),
        ManifestTurn(speaker: "C", start: 6.809, end: 9.421),
        ManifestTurn(speaker: "B", start: 14.007, end: 17.012),
        ManifestTurn(speaker: "C", start: 17.812, end: 21.048),
        ManifestTurn(speaker: "B", start: 25.548, end: 28.102),
        ManifestTurn(speaker: "C", start: 28.901, end: 31.744),
        ManifestTurn(speaker: "B", start: 35.582, end: 38.743),
        ManifestTurn(speaker: "C", start: 39.543, end: 42.074),
    ]
}
