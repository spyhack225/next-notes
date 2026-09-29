import Foundation

/// Resolves the meeting-fixture directory for the M-task self-tests (M-01 adds it;
/// M-03 and M-04 resolve their fixtures the same way).
///
/// The directory argument is optional: an explicit path wins, otherwise
/// `$NEXTNOTES_FIXTURES/meetings` (which `Scripts/acceptance.sh` exports). Missing
/// both, the caller reports `*_ABSENT` — never OK, never FAILED.
enum FixturePaths {
    static func meetings(argument: String?) -> URL? {
        if let argument, !argument.isEmpty {
            return directory(at: (argument as NSString).expandingTildeInPath)
        }
        guard let base = ProcessInfo.processInfo.environment["NEXTNOTES_FIXTURES"],
              !base.isEmpty
        else { return nil }
        return directory(
            at: URL(fileURLWithPath: (base as NSString).expandingTildeInPath)
                .appendingPathComponent("meetings", isDirectory: true).path
        )
    }

    private static func directory(at path: String) -> URL? {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir),
              isDir.boolValue
        else { return nil }
        return URL(fileURLWithPath: path)
    }
}

/// `--selftest-meeting-finals [<fixtures-dir>]` (M-01): the long-window final tier
/// transcribes the M-16a fixtures at least as faithfully as the 2–5 s live tier.
///
/// For each of `fr-dialogue.wav`, `fr-dialogue-phone.wav`, `en-dialogue.wav` it runs
/// the live tier (a `ChunkedTranscriber` fed 1 s at a time, as `transcribeFile` does)
/// and the final tier (`MeetingFinalPass.transcribeTrack` through
/// `TranscriptionQueue` on `.background`), then grades wrong-language share with
/// `TranscriptLanguageProbe`, word recall against `manifest.json`, window lengths
/// and the real-time factor. Pure `merge`/`accept`/decision cases need no model.
///
/// Marker `MEETING_FINALS_OK` / `MEETING_FINALS_FAILED: <reason>` /
/// `MEETING_FINALS_ABSENT: <fixtures not found at …|Parakeet not downloaded>`.
/// Uses no store (segments in memory).
@MainActor
enum MeetingFinalsSelfTest {
    private struct FileResult {
        var name: String
        var audioSeconds: Double
        var liveSegments: [TranscriptSegment]
        var liveElapsed: TimeInterval
        var finalSegments: [TranscriptSegment]
        var finalWindows: [ClosedRange<TimeInterval>]
        var finalElapsed: TimeInterval
    }

    static func run(dir: String?, log: (String) -> Void) async -> Bool {
        var failures: [String] = []
        func check(_ name: String, _ condition: Bool) {
            if !condition { failures.append(name) }
        }

        // f. Pure: no model, no audio.
        runPureCases(check: check)

        // The measurement modifier (M-01 step 1): `--finals-window <min>:<max>`
        // overrides the cut config for the window-length and language numbers only.
        let effective = effectiveFinalsConfig()

        // Preconditions: fixtures, then Parakeet.
        guard let fixtures = FixturePaths.meetings(argument: dir) else {
            return absent("fixtures not found at \(dir ?? "$NEXTNOTES_FIXTURES/meetings")",
                          failures: failures, log: log)
        }
        guard ParakeetModels.isDownloaded else {
            return absent("Parakeet not downloaded", failures: failures, log: log)
        }
        let manifest: MeetingFixtureManifest
        do {
            manifest = try MeetingFixtureManifest.load(in: fixtures)
        } catch {
            failures.append("manifest.json unreadable: \(error.localizedDescription)")
            return finish(failures: failures, log: log)
        }

        let names = ["fr-dialogue.wav", "fr-dialogue-phone.wav", "en-dialogue.wav"]
        var results: [FileResult] = []
        for name in names {
            let url = fixtures.appendingPathComponent(name)
            let samples: [Float]
            do {
                samples = try AudioConversion.monoSamples(
                    fromFileAt: url, sampleRate: ChunkedTranscriber.sampleRate
                )
            } catch {
                failures.append("\(name) unreadable: \(error.localizedDescription)")
                continue
            }
            guard !samples.isEmpty else {
                failures.append("\(name) decoded to no samples")
                continue
            }
            let audioSeconds = Double(samples.count) / ChunkedTranscriber.sampleRate

            // Live tier: the meeting path, a second at a time.
            let liveBegan = Date()
            let liveSegments = await transcribeLive(samples)
            let liveElapsed = Date().timeIntervalSince(liveBegan)

            // Final tier: long windows on `.background` (never `.realtimeASR`).
            let finalBegan = Date()
            let final: (segments: [TranscriptSegment], windows: [ClosedRange<TimeInterval>])
            do {
                final = try await MeetingFinalPass.transcribeTrack(
                    samples, source: .system, config: effective
                ) { window in
                    try await TranscriptionQueue.shared.transcribe(window, lane: .background)
                }
            } catch {
                failures.append("\(name) final tier threw: \(error.localizedDescription)")
                continue
            }
            let finalElapsed = Date().timeIntervalSince(finalBegan)

            results.append(FileResult(
                name: name, audioSeconds: audioSeconds,
                liveSegments: liveSegments, liveElapsed: liveElapsed,
                finalSegments: final.segments, finalWindows: final.windows,
                finalElapsed: finalElapsed
            ))
        }

        // a–e per file.
        var totalAudio: Double = 0
        var totalFinalElapsed: TimeInterval = 0
        for result in results {
            totalAudio += result.audioSeconds
            totalFinalElapsed += result.finalElapsed
            let expected: TranscriptLanguageProbe.Guess =
                result.name.hasPrefix("fr") ? .french : .english
            let liveWrong = wrongShare(result.liveSegments, expected: expected)
            let finalWrong = wrongShare(result.finalSegments, expected: expected)
            log(String(format: "MEETING_FINALS_LANG %@ live=%.1f%% final=%.1f%%",
                       result.name, liveWrong * 100, finalWrong * 100))

            // b. Every final window but the last reaches the effective minimum.
            let lengths = result.finalWindows.map { $0.upperBound - $0.lowerBound }
            log("MEETING_FINALS_WINDOWS \(result.name) " + lengths
                .map { String(format: "%.1f", $0) }.joined(separator: ","))
            for (index, length) in lengths.enumerated() where index < lengths.count - 1 {
                check("\(result.name) window \(index) is \(String(format: "%.1f", length))s,"
                      + " below final min \(effective.minWindowSeconds)s",
                      length >= effective.minWindowSeconds - 0.02)
            }

            // c. Word recall against the manifest: the long tier must not lose speech.
            if let turns = manifest.turns(for: result.name) {
                let liveRecall = recall(result.liveSegments, turns: turns)
                let finalRecall = recall(result.finalSegments, turns: turns)
                log(String(format: "MEETING_FINALS_RECALL %@ live=%.3f final=%.3f",
                           result.name, liveRecall, finalRecall))
                check("\(result.name) final recall \(finalRecall) below live \(liveRecall)",
                      finalRecall >= liveRecall - 0.02)
            } else {
                failures.append("\(result.name) missing from manifest.json")
            }

            // d. Wrong-language gates.
            if result.name == "fr-dialogue-phone.wav" {
                check("fr-dialogue-phone final wrong share \(finalWrong) above 2%",
                      finalWrong <= 0.02)
            }
            check("\(result.name) final wrong share \(finalWrong) above live \(liveWrong)",
                  finalWrong <= liveWrong)
            if result.name == "en-dialogue.wav" {
                let french = Double(result.finalSegments.filter {
                    TranscriptLanguageProbe.guess($0.text) == .french
                }.count) / Double(max(1, result.finalSegments.count))
                check("en-dialogue final French-guessed share \(french) above 2%",
                      french <= 0.02)
            }
            let ratio = finalWrong > 0 ? liveWrong / finalWrong : Double.infinity
            log("MEETING_FINALS_LIVE_TO_FINAL_RATIO=\(result.name) \(ratio.isInfinite ? "inf" : String(format: "%.2f", ratio))")
        }

        // e. Final-pass cost ≤ 5 % of meeting duration.
        if totalAudio > 0 {
            let rtf = totalFinalElapsed / totalAudio
            log(String(format: "MEETING_FINALS_RTF=%.4f", rtf))
            check("final-pass RTF \(rtf) above 0.05", rtf <= 0.05)
        } else if results.isEmpty {
            failures.append("no fixture transcribed")
        }

        return finish(failures: failures, log: log)
    }

    // MARK: - Pure cases (f)

    static func runPureCases(check: (String, Bool) -> Void) {
        let command = TranscriptSegment(
            start: 1.0, end: 2.0, text: "open calendar", source: .mic, kind: .agentCommand
        )
        let overlappingFinal = TranscriptSegment(
            start: 0.5, end: 2.5, text: "hello there meeting", source: .mic
        )
        let overlappingSystem = TranscriptSegment(
            start: 1.2, end: 1.8, text: "d'accord merci", source: .system
        )
        let merged = MeetingFinalPass.merge(
            final: [overlappingFinal, overlappingSystem], live: [command]
        )
        check("merge dropped the live agent command", merged.contains(command))
        check("merge kept a final mic segment overlapping the command",
              !merged.contains(overlappingFinal))
        check("merge dropped a system segment overlapping the command in time",
              merged.contains(overlappingSystem))

        let liveWords = (0..<2).map {
            TranscriptSegment(start: Double($0), end: Double($0) + 1,
                              text: "one two three four five", source: .system)
        }
        let halfWords = [TranscriptSegment(
            start: 0, end: 2, text: "one two three four five", source: .system
        )]
        check("accept kept a final track with half the live words",
              !MeetingFinalPass.accept(final: halfWords, live: liveWords, source: .system))
        check("accept refused a full final track",
              MeetingFinalPass.accept(final: liveWords, live: liveWords, source: .system))
        check("accept refused an empty live track",
              MeetingFinalPass.accept(final: [], live: [], source: .system))

        check("no-audio decision is not skip live-only:no-audio",
              MeetingPipeline.finalPassDecision(settingOn: true, hasAudio: false)
                == .skip("live-only:no-audio"))
        check("audio decision is not run",
              MeetingPipeline.finalPassDecision(settingOn: true, hasAudio: true) == .run)
        check("empty live transcript with saved audio did not get a recovery pass",
              MeetingPipeline.finalPassDecision(
                settingOn: false, hasAudio: true, hasTranscript: false) == .run)
        check("dropped live windows with saved audio did not get a recovery pass",
              MeetingPipeline.finalPassDecision(
                settingOn: false, hasAudio: true, droppedAudio: true) == .run)
        check("failed writer plus empty live transcript would look like a finished meeting",
              MeetingSession.hasUnrecoverableLoss(
                capturedDrop: false, skippedSeconds: 0, hasAudio: false,
                writerFailed: true, hasTranscript: false, audioProblem: true))
        check("an ordinary silent meeting was marked as failed",
              !MeetingSession.hasUnrecoverableLoss(
                capturedDrop: false, skippedSeconds: 0, hasAudio: false,
                writerFailed: false, hasTranscript: false, audioProblem: false))
    }

    // MARK: - Helpers

    /// `--finals-window <min>:<max>` overrides the cut config for measurement
    /// (M-01 step 1). Invalid or absent → `WindowConfig.finals`.
    static func effectiveFinalsConfig() -> ChunkedTranscriber.WindowConfig {
        guard let raw = SelfTest.value(after: "--finals-window") else {
            return .finals
        }
        let parts = raw.split(separator: ":").compactMap { Double($0) }
        guard parts.count == 2, parts[0] > 0, parts[1] > parts[0] else { return .finals }
        return ChunkedTranscriber.WindowConfig(
            minWindowSeconds: parts[0], maxWindowSeconds: parts[1],
            overlapSeconds: 0, emitsProvisionals: false
        )
    }

    private static func finish(failures: [String], log: (String) -> Void) -> Bool {
        for failure in failures { log("MEETING_FINALS_WRONG: \(failure)") }
        log(failures.isEmpty
            ? "MEETING_FINALS_OK: long-window finals hold against the live tier"
            : "MEETING_FINALS_FAILED: \(failures.count) check(s) wrong")
        return failures.isEmpty
    }

    /// A missing precondition is ABSENT, never OK — unless the pure cases already
    /// failed, in which case the failure is the last word.
    private static func absent(_ what: String, failures: [String], log: (String) -> Void) -> Bool {
        log("MEETING_FINALS_ABSENT: \(what)")
        guard !failures.isEmpty else { return true }
        for failure in failures { log("MEETING_FINALS_WRONG: \(failure)") }
        log("MEETING_FINALS_FAILED: \(failures.count) check(s) wrong")
        return false
    }

    /// The live tier exactly as `transcribeFile` drives it: 1 s at a time — paced at
    /// half realtime so the 8-window backlog never drops what production would keep.
    /// An instant feed queues every window before the model finishes the first and
    /// files half the transcript as dropped (M-07's subject, not this test's); paced,
    /// the queue drains as it does on a live meeting.
    private static func transcribeLive(_ samples: [Float]) async -> [TranscriptSegment] {
        let collector = FinalsCollector()
        let transcriber = ChunkedTranscriber(source: .system) { segment in
            await collector.add(segment)
        }
        let step = Int(ChunkedTranscriber.sampleRate)
        var index = 0
        while index < samples.count {
            let end = min(index + step, samples.count)
            await transcriber.append(Array(samples[index..<end]))
            index = end
            try? await Task.sleep(for: .milliseconds(500))
        }
        await transcriber.flush()
        return await collector.all()
    }

    /// Wrong-language share against the file's expected language (wrong = guessed
    /// and not expected; unknown guesses are neither), mirroring the probe.
    private static func wrongShare(
        _ segments: [TranscriptSegment],
        expected: TranscriptLanguageProbe.Guess
    ) -> Double {
        let guesses = segments.map { TranscriptLanguageProbe.guess($0.text) }
        let guessed = guesses.filter { $0 != .unknown }.count
        guard guessed > 0 else { return 0 }
        let wrong = guesses.filter { $0 != .unknown && $0 != expected }.count
        return Double(wrong) / Double(guessed)
    }

    /// Lower-cased token multiset overlap of the hypothesis against the manifest text.
    private static func recall(
        _ segments: [TranscriptSegment],
        turns: [String]
    ) -> Double {
        var ref: [String: Int] = [:]
        for token in tokens(turns.joined(separator: " ")) { ref[token, default: 0] += 1 }
        let total = ref.values.reduce(0, +)
        guard total > 0 else { return 0 }
        var hyp: [String: Int] = [:]
        for token in tokens(segments.map(\.text).joined(separator: " ")) {
            hyp[token, default: 0] += 1
        }
        var hit = 0
        for (token, count) in hyp { hit += min(count, ref[token] ?? 0) }
        return Double(hit) / Double(total)
    }

    private static func tokens(_ text: String) -> [String] {
        text.lowercased().split(separator: " ").map { word in
            word.trimmingCharacters(in: .punctuationCharacters)
        }.filter { !$0.isEmpty }
    }
}

/// The manifest ground truth (`Tests/Fixtures/meetings/manifest.json`): per file,
/// the turn texts. Duration and timings are informational here.
private struct MeetingFixtureManifest: Decodable {
    var files: [String: ManifestFile]

    struct ManifestFile: Decodable {
        var turns: [ManifestTurn]
    }

    struct ManifestTurn: Decodable {
        var text: String
    }

    static func load(in directory: URL) throws -> MeetingFixtureManifest {
        let data = try Data(contentsOf: directory.appendingPathComponent("manifest.json"))
        return try JSONDecoder().decode(MeetingFixtureManifest.self, from: data)
    }

    func turns(for file: String) -> [String]? {
        files[file]?.turns.map(\.text)
    }
}

private actor FinalsCollector {
    private var segments: [TranscriptSegment] = []
    func add(_ segment: TranscriptSegment) { segments.append(segment) }
    func all() -> [TranscriptSegment] { segments }
}
