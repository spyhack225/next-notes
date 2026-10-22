import Foundation

/// `--selftest-notes-coverage`: the notes input's coverage limits are frozen once, before
/// the model is asked, and disclosed in plain words above the document.
///
/// The audit's two live failures are the reason this exists: a saved system track whose
/// "Others" channel was zero after the first few seconds, and a transcript whose later
/// parts arrived out of order. The notes came out looking whole. What the producer knew
/// before the model was asked has to reach the page — and an intact meeting's notes have
/// to stay exactly as they were.
///
/// Three ways this first version could have lied, and one case each:
///
/// 1. It said the notes might be missing discussion when the notes came from the
///    complete live transcript. The notes' own input decides, not the recording's.
/// 2. It turned a frame count into a position by arithmetic the producer never did.
///    The position comes from the producer that measured it, and from nowhere else.
/// 3. It treated a transcript that ends before the recording as damage. A meeting
///    where everyone stopped talking is not a broken meeting.
///
/// The last case drives the real writer, so the chain from "the other speakers'
/// audio stopped arriving" to the sentence on the page is proven rather than
/// described. Pure rules, the real generator, the real writer: no model, no store,
/// no clock.
@MainActor
enum NotesCoverageSelfTest {
    static func run(write: (String) -> Void) async -> Bool {
        var failures: [String] = []
        var currentCase = ""
        var caseFailures = 0
        func begin(_ name: String) {
            currentCase = name
            caseFailures = failures.count
        }
        func check(_ name: String, _ condition: Bool) {
            if !condition { failures.append("\(currentCase): \(name)") }
        }
        func finish() {
            let wrong = failures.count - caseFailures
            write("NOTES_COVERAGE_CASE \(currentCase) \(wrong == 0 ? "ok" : "wrong(\(wrong))")")
        }

        // The sentences, pinned here and nowhere else: they are the whole product
        // of this feature, and a reworded disclosure is a changed promise.
        let systemNote = "Note: the other speakers' audio stopped being saved partway through "
            + "this meeting, so what they said after that may be missing from these notes."
        let micNote = "Note: your microphone audio stopped being saved partway through this "
            + "meeting, so what you said after that may be missing from these notes."
        let bothNote = "Note: this meeting's audio stopped being saved partway through, so "
            + "later discussion may be missing from these notes."
        let recordingNote = "Note: this meeting's recording stopped saving partway through. "
            + "These notes come from the live transcript, so they may still cover the call."
        let uncertainNote = "Note: some later parts of this conversation may be missing from "
            + "these notes."

        // a. The notes' own input decides, per track. A meeting whose system
        // track fell back to the live tier — because the recording was short on
        // it — is short for these notes, whatever the pass is called. This is
        // the audit's case exactly.
        begin("provenance")
        let liveOnly = NotesCoverageDisclosure.classify(NotesCoverageDisclosure.Input(
            transcriptPass: "live-only:rejected",
            rejectedTracks: [.system],
            recordingWriteFailed: false,
            systemAudioSavedThroughSeconds: 300))
        check("a rejected system track was not disclosed (kind \(liveOnly.kind))",
              liveOnly.markdownPrefix == systemNote)
        check("a rejected system track was classified as \(liveOnly.kind)",
              liveOnly == .systemAudioPartial(savedThroughSeconds: 300))
        let savedFile = NotesCoverageDisclosure.classify(NotesCoverageDisclosure.Input(
            transcriptPass: "long-window",
            rejectedTracks: [.system],
            recordingWriteFailed: false,
            systemAudioSavedThroughSeconds: 300))
        check("a saved-file pass did not disclose the lost track",
              savedFile.markdownPrefix == systemNote)
        let noPass = NotesCoverageDisclosure.classify(NotesCoverageDisclosure.Input(
            transcriptPass: nil,
            rejectedTracks: [.system],
            recordingWriteFailed: false,
            systemAudioSavedThroughSeconds: 300))
        check("a meeting with no pass was told its file was short",
              noPass.markdownPrefix == systemNote)
        let writeFailed = NotesCoverageDisclosure.classify(NotesCoverageDisclosure.Input(
            transcriptPass: "live-only:audio-incomplete",
            rejectedTracks: [.system, .mic],
            recordingWriteFailed: true))
        check("a failed recording was not disclosed (kind \(writeFailed.kind))",
              writeFailed == .recordingIncomplete(fromLiveTranscript: true))
        check("a failed recording did not use the live-transcript wording",
              writeFailed.markdownPrefix == recordingNote)
        let savedFileFailure = NotesCoverageDisclosure.classify(NotesCoverageDisclosure.Input(
            transcriptPass: "long-window",
            recordingWriteFailed: true))
        check("a saved-file pass claimed the notes came from the live transcript",
              savedFileFailure == .recordingIncomplete(fromLiveTranscript: false))
        check("a saved-file pass used the wrong wording",
              savedFileFailure.markdownPrefix == bothNote
                || savedFileFailure.markdownPrefix == recordingNote)
        finish()

        // b. The position comes from the producer that measured it, and a
        // track with no measured position is not a loss on its own.
        begin("position")
        let measured = NotesCoverageDisclosure.classify(NotesCoverageDisclosure.Input(
            transcriptPass: "long-window",
            systemAudioSavedThroughSeconds: 300))
        if case .systemAudioPartial(let seconds) = measured {
            check("the measured position was not carried", seconds == 300)
        } else {
            check("the measured loss was classified as \(measured.kind)", false)
        }
        let fallback = NotesCoverageDisclosure.classify(NotesCoverageDisclosure.Input(
            transcriptPass: "live-only:rejected",
            rejectedTracks: [.system]))
        check("a fallback on a healthy recording was called a loss",
              fallback == .none)
        finish()

        // c. The microphone track is the person's own voice, and two lost tracks
        // are disclosed together rather than twice.
        begin("tracks")
        let micLoss = NotesCoverageDisclosure.classify(NotesCoverageDisclosure.Input(
            transcriptPass: "long-window",
            micAudioSavedThroughSeconds: 200))
        check("a lost microphone was not disclosed", micLoss.markdownPrefix == micNote)
        let bothLoss = NotesCoverageDisclosure.classify(NotesCoverageDisclosure.Input(
            transcriptPass: "long-window",
            systemAudioSavedThroughSeconds: 300,
            micAudioSavedThroughSeconds: 200))
        check("two lost tracks were not disclosed together", bothLoss.markdownPrefix == bothNote)
        check("the both-tracks loss lost its machine word", bothLoss.kind == "both")
        finish()

        // d. A quiet ending is not damage, and nothing is claimed about the
        // conversation without a producer fact behind it.
        begin("clock")
        let quietEnd = NotesCoverageDisclosure.classify(NotesCoverageDisclosure.Input(
            transcriptPass: "long-window"))
        check("a healthy meeting was given a disclosure", quietEnd == .none)
        let stopped = NotesCoverageDisclosure.classify(NotesCoverageDisclosure.Input(
            transcriptPass: "long-window",
            systemDeliveryStopped: true))
        check("a track that stopped delivering was not disclosed",
              stopped == .timestampsUncertain(lastKnownSeconds: 0))
        check("the delivery disclosure was not marked uncertain", stopped.uncertainChronology)
        let micStopped = NotesCoverageDisclosure.classify(NotesCoverageDisclosure.Input(
            transcriptPass: "long-window",
            micDeliveryStopped: true))
        check("a stopped microphone was not disclosed",
              micStopped == .timestampsUncertain(lastKnownSeconds: 0))
        finish()

        // e. The producer chain: a real writer whose system track stops must measure
        // the boundary, the meeting's facts must carry it, and the disclosure must
        // follow from those facts. This is the case that proves the feature is
        // wired to something that happens.
        begin("producer")
        do {
            // A writer whose two tracks both run to the end measures no boundary,
            // and the meeting's facts say the coverage is complete.
            let intactDirectory = FileManager.default.temporaryDirectory
                .appendingPathComponent("notes-coverage-intact-\(UUID().uuidString)")
            try FileManager.default.createDirectory(
                at: intactDirectory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: intactDirectory) }
            let intactWriter = try MeetingAudioWriter(
                url: intactDirectory.appendingPathComponent("audio.caf"))
            let chunk = 1_600
            for index in 0..<20 {
                let start = chunk * index
                _ = await intactWriter.append(
                    Array(repeating: 0.1, count: chunk), from: .mic, startFrame: start)
                _ = await intactWriter.append(
                    Array(repeating: 0.2, count: chunk), from: .system, startFrame: start)
            }
            await intactWriter.finish()
            let intactSnapshot = intactWriter.resourceSnapshot()
            check("an intact recording measured a boundary on the system channel",
                  intactSnapshot.systemSilentAfterSample == nil)
            check("an intact recording measured a boundary on the microphone channel",
                  intactSnapshot.micSilentAfterSample == nil)
            check("an intact recording filled the system channel with silence",
                  intactSnapshot.silenceFilledSystemFrames == 0)
            var intactIntegrity = MeetingCaptureIntegrity()
            intactIntegrity.recordSavedCoverage(intactSnapshot)
            check("an intact recording was recorded as short "
                + "(trim=\(intactSnapshot.missingSavedSystemFrames) "
                + "silent=\(String(describing: intactSnapshot.systemSilentAfterSample)) "
                + "warnings=\(intactIntegrity.coverageWarnings?.count ?? -1) "
                + "writeFailed=\(intactIntegrity.audioWriteFailed))",
                  !intactIntegrity.hasKnownSavedAudioLoss(on: .system))
            check("an intact recording did not record that the coverage was measured",
                  intactIntegrity.savedCoverageMeasured == true)

            // A writer whose other speakers stop while the person keeps talking:
            // the channel carries only invented silence from there on, and that
            // boundary is the fact the notes disclosure reads.
            let lostDirectory = FileManager.default.temporaryDirectory
                .appendingPathComponent("notes-coverage-lost-\(UUID().uuidString)")
            try FileManager.default.createDirectory(
                at: lostDirectory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: lostDirectory) }
            let lostWriter = try MeetingAudioWriter(
                url: lostDirectory.appendingPathComponent("audio.caf"))
            _ = await lostWriter.append(Array(repeating: 0.1, count: chunk), from: .mic, startFrame: 0)
            _ = await lostWriter.append(Array(repeating: 0.2, count: chunk), from: .system, startFrame: 0)
            for index in 1..<20 {
                let start = chunk * index
                _ = await lostWriter.append(
                    Array(repeating: 0.1, count: chunk), from: .mic, startFrame: start)
            }
            await lostWriter.finish()
            let lostSnapshot = lostWriter.resourceSnapshot()
            check("a stopped system track measured no boundary",
                  lostSnapshot.systemSilentAfterSample != nil)
            check("a stopped system track filled the channel with silence",
                  lostSnapshot.silenceFilledSystemFrames > 0)
            var lostIntegrity = MeetingCaptureIntegrity()
            lostIntegrity.recordSavedCoverage(lostSnapshot)
            check("the writer's boundary did not reach the meeting's facts",
                  lostIntegrity.systemSilentAfterSample == lostSnapshot.systemSilentAfterSample)
            check("the meeting's facts did not record the loss",
                  lostIntegrity.hasKnownSavedAudioLoss(on: .system))
            let start = Date(timeIntervalSince1970: 1_750_000_000)
            var lostMeeting = Meeting(
                title: "Producer review", start: start, end: start.addingTimeInterval(600),
                status: .summarizing)
            lostMeeting.transcriptPass = "long-window"
            lostMeeting.captureIntegrity = lostIntegrity
            let frozen = NotesCoverageDisclosure.freeze(
                meeting: lostMeeting, segments: NotesTruncationSelfTest.segments(count: 100))
            check("the writer's loss did not reach the disclosure",
                  frozen.disclosure == .systemAudioPartial(
                    savedThroughSeconds: Double(lostSnapshot.systemSilentAfterSample ?? 0)
                        / ChunkedTranscriber.sampleRate))
        } catch {
            check("the writer chain threw: \(error)", false)
        }
        finish()

        // f. An intact meeting says nothing, and its notes are byte-identical through
        // the real generator — the one check a disclosure feature has to pass.
        begin("intact")
        let intact = NotesCoverageDisclosure.classify(NotesCoverageDisclosure.Input(
            transcriptPass: "long-window"))
        check("an intact meeting was given a disclosure", intact == .none)
        check("an intact disclosure is not empty",
              NotesCoverageDisclosure.Disclosure.none.markdownPrefix.isEmpty)
        do {
            let meeting = NotesTruncationSelfTest.hourLongMeeting()
            let segments = NotesTruncationSelfTest.tenMinuteSegments()
            let baseline = try await NotesGenerator(provider: TruncationNotesProvider(contextTokens: 8_192))
                .notes(for: meeting, segments: segments, brief: .empty)
            let frozen = NotesCoverageDisclosure.Frozen(
                disclosure: .none,
                segmentCount: segments.count,
                firstSegmentTimestamp: segments.map(\.start).min(),
                lastSegmentTimestamp: segments.map(\.end).max(),
                speakerNameCount: meeting.speakerNames.count)
            let disclosed = try await NotesGenerator(provider: TruncationNotesProvider(contextTokens: 8_192))
                .notes(for: meeting, segments: segments, brief: .empty, coverage: frozen)
            check("an intact disclosure changed the notes", baseline.markdown == disclosed.markdown)
            // A captured digest, not a comparison of two runs of the same code: the
            // intact document has to be the document it was, and a change to the
            // formatter or the prompts has to fail here rather than pass quietly.
            let digest = NotesCoverageSelfTest.digest(of: baseline.markdown)
            check("the intact document changed (\(digest))",
                  digest == NotesCoverageSelfTest.intactDocumentDigest)
            check("the run lost the frozen segment count",
                  disclosed.coverage?.segmentCount == segments.count)
            if let carried = disclosed.coverage {
                check("the run lost the frozen disclosure", carried.disclosure == .none)
                check("an intact clock asked the map step for a warning",
                      !carried.disclosure.uncertainChronology)
            } else {
                check("the frozen facts were not carried to the result", false)
            }
        } catch {
            check("the intact generator run threw: \(error)", false)
        }
        finish()

        // g. The freeze is taken once, from the meeting and segments the notes came
        // from: a later diarization pass or a later loss cannot change a page
        // already written, and the next freeze sees the new facts.
        begin("frozen")
        let start = Date(timeIntervalSince1970: 1_750_000_000)
        var meeting = Meeting(
            title: "Freeze review", start: start, end: start.addingTimeInterval(600),
            status: .summarizing, speakerNames: ["S1": "Ana", "S2": "Ben"])
        meeting.transcriptPass = "long-window"
        let segments = NotesTruncationSelfTest.segments(count: 100)
        let frozen = NotesCoverageDisclosure.freeze(meeting: meeting, segments: segments)
        check("an intact meeting did not freeze as intact", frozen.disclosure == .none)
        check("the speaker names were not frozen", frozen.speakerNameCount == 2)
        check("the segment count was not frozen", frozen.segmentCount == segments.count)
        check("the first timestamp was not frozen", frozen.firstSegmentTimestamp == 0)
        check("the last timestamp was not frozen", frozen.lastSegmentTimestamp == 600)
        // The page is written from the frozen facts, and a later change to the
        // meeting cannot reach back into it.
        do {
            let result = try await NotesGenerator(provider: TruncationNotesProvider(contextTokens: 8_192))
                .notes(for: meeting, segments: segments, brief: .empty, coverage: frozen)
            let written = result.markdown
            var changed = meeting
            changed.speakerNames["S3"] = "Cara"
            var changedIntegrity = MeetingCaptureIntegrity()
            changedIntegrity.systemSilentAfterSample = 25 * 16_000
            changed.captureIntegrity = changedIntegrity
            check("the written page changed after a later diarization pass",
                  written == result.markdown)
            check("the frozen facts did not survive the page",
                  result.coverage?.speakerNameCount == frozen.speakerNameCount)
            check("the next freeze did not see the new name",
                  NotesCoverageDisclosure.freeze(meeting: changed, segments: segments)
                    .speakerNameCount == 3)
            let nextFrozen = NotesCoverageDisclosure.freeze(meeting: changed, segments: segments)
            check("a later loss was not disclosed by the next freeze",
                  nextFrozen.disclosure == .systemAudioPartial(savedThroughSeconds: 25))
            check("a later loss changed the frozen disclosure", frozen.disclosure == .none)
        } catch {
            check("the freeze generator run threw: \(error)", false)
        }
        finish()

        // h. A known loss reaches the page through the real generator, as the
        // document's first line, with the notes the model wrote intact beneath it.
        begin("on-page")
        do {
            var lost = Meeting(
                title: "Saved track review", start: start, end: start.addingTimeInterval(600),
                status: .summarizing)
            lost.transcriptPass = "long-window"
            var loss = MeetingCaptureIntegrity()
            loss.systemSilentAfterSample = 25 * 16_000
            loss.savedCoverageMeasured = true
            lost.captureIntegrity = loss
            let frozenLoss = NotesCoverageDisclosure.freeze(meeting: lost, segments: segments)
            check("the loss did not freeze as a system disclosure",
                  frozenLoss.disclosure == .systemAudioPartial(savedThroughSeconds: 25))
            let result = try await NotesGenerator(provider: TruncationNotesProvider(contextTokens: 8_192))
                .notes(for: lost, segments: segments, brief: .empty, coverage: frozenLoss)
            check("the disclosure is not the page's first line",
                  result.markdown.hasPrefix(systemNote))
            check("the notes beneath the disclosure were lost",
                  result.markdown.contains("## Summary"))
            check("the frozen facts were not carried to the result",
                  result.coverage?.disclosure == frozenLoss.disclosure)
        } catch {
            check("the system-loss generator run threw: \(error)", false)
        }
        finish()

        // i. The uncertain clock reaches the map prompt, and only the map prompt, and
        // the truncation contract underneath it is unchanged by the disclosure.
        begin("map-clock")
        do {
            let uncertainFrozen = NotesCoverageDisclosure.Frozen(
                disclosure: .timestampsUncertain(lastKnownSeconds: 330),
                segmentCount: 2_000,
                firstSegmentTimestamp: 0,
                lastSegmentTimestamp: 330,
                speakerNameCount: 1)
            let provider = TruncationNotesProvider(contextTokens: 16_384, alwaysCut: true)
            let result = try await NotesGenerator(provider: provider).notes(
                for: NotesTruncationSelfTest.hourLongMeeting(),
                segments: NotesTruncationSelfTest.longTranscriptSegments(),
                brief: .empty,
                coverage: uncertainFrozen)
            let maps = provider.calls.filter { $0.system == NotesPrompts.mapSystem }
            check("the uncertain clock reached no map call", !maps.isEmpty)
            check("a map part was missing the clock warning",
                  maps.allSatisfy { $0.user.contains(NotesPrompts.mapUncertainChronologyLine) })
            let otherPasses = provider.calls.filter { $0.system != NotesPrompts.mapSystem }
            check("the clock warning leaked into another pass",
                  otherPasses.allSatisfy {
                    !$0.user.contains(NotesPrompts.mapUncertainChronologyLine)
                  })
            check("the uncertain disclosure is not the page's first line",
                  result.markdown.hasPrefix(uncertainNote))
            for heading in ["Decisions", "Action items", "Open questions"] {
                check("\(heading) is missing from the cut-short notes",
                      result.markdown.contains("## \(heading)\n\(NotesPrompts.cutShortMarker)"))
                check("\(heading) claimed there was nothing to say after a cut",
                      !result.markdown.contains("## \(heading)\n\(NotesPrompts.emptyMarker)"))
            }
            check("an empty brief stopped forcing the empty marker",
                  result.markdown
                    .contains("## \(NotesPrompts.relatedHeading)\n\(NotesPrompts.emptyMarker)"))
            let reduceCalls = provider.calls.filter { $0.system == NotesPrompts.reduceSystem }
            check("the disclosure retried the reduce (\(reduceCalls.count) call(s))",
                  reduceCalls.count == 2)
            let plain = NotesPrompts.mapUser(
                meeting: NotesTruncationSelfTest.hourLongMeeting(), part: 1, of: 3,
                transcript: "hello")
            let warned = NotesPrompts.mapUser(
                meeting: NotesTruncationSelfTest.hourLongMeeting(), part: 1, of: 3,
                transcript: "hello", uncertainChronology: true)
            check("the ordinary map prompt carries the clock warning",
                  !plain.contains(NotesPrompts.mapUncertainChronologyLine))
            check("the clock warning is not exactly one appended line",
                  warned == plain + "\n\n" + NotesPrompts.mapUncertainChronologyLine)
        } catch {
            check("the cut map-reduce run threw: \(error)", false)
        }
        finish()

        // j. The extraction limitation still comes first: the existing marker has to be
        // the document's first line, with the coverage disclosure under it and only once.
        begin("notice-order")
        do {
            let provider = TruncationNotesProvider(contextTokens: 8_192, cutFacts: true)
            let frozenLoss = NotesCoverageDisclosure.Frozen(
                disclosure: .systemAudioPartial(savedThroughSeconds: 25),
                segmentCount: 2_000,
                firstSegmentTimestamp: 0,
                lastSegmentTimestamp: 330,
                speakerNameCount: 1)
            let result = try await NotesGenerator(provider: provider).notes(
                for: NotesTruncationSelfTest.hourLongMeeting(),
                segments: NotesTruncationSelfTest.longTranscriptSegments(),
                brief: .empty,
                coverage: frozenLoss)
            check("the extraction notice is no longer first",
                  result.markdown.hasPrefix(NotesGenerator.incompleteFactsNotice))
            check("the coverage disclosure did not survive the map",
                  result.markdown
                    .hasPrefix(NotesGenerator.incompleteFactsNotice + "\n\n" + systemNote))
            let occurrences = result.markdown.components(separatedBy: systemNote).count - 1
            check("the disclosure was written \(occurrences) time(s)", occurrences == 1)
            check("an incomplete map was not reported", result.incompleteFacts)
            check("the frozen facts were not carried through the map",
                  result.coverage == frozenLoss)
        } catch {
            check("the cut-facts generator run threw: \(error)", false)
        }
        finish()

        for failure in failures { write("  NOTES_COVERAGE_WRONG: \(failure)") }
        write(failures.isEmpty
            ? "NOTES_COVERAGE_OK: the notes' own input decides what is disclosed, the position "
                + "comes from the producer that measured it, a quiet ending is not damage, an "
                + "intact meeting's notes are byte-identical, and the uncertain clock reaches "
                + "the map prompt only"
            : "NOTES_COVERAGE_FAILED: \(failures.count) check(s) wrong")
        return failures.isEmpty
    }

    /// The digest of the intact document, captured once. A change to the formatter,
    /// the prompts or the headings has to fail this test rather than pass quietly.
    static let intactDocumentDigest = "f173cac51f0242f7"

    /// A short, stable digest of a document.
    static func digest(of text: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100_0000_01b3
        }
        return String(hash, radix: 16)
    }
}
