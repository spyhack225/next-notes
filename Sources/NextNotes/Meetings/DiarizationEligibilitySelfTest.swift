import FluidAudio
import Foundation

/// `--selftest-diarize-eligibility`: one eligibility decision, three states,
/// shared by the automatic pipeline path and both manual ones (MR-06).
///
/// Known lost remote audio is refused in plain words before the diarizer loads;
/// a clustering pass that found nothing on an intact track says so instead of
/// leaking "No speech detected in audio"; confirmed speaker names survive an
/// over-split relabelling; and the projection resolves every committed segment
/// — the last one included — through the saved name map. Pure: no model, no
/// store, nothing written.
@MainActor
enum DiarizationEligibilitySelfTest {
    static func run() -> Bool { run { _ in }.isEmpty }

    static func run(write: (String) -> Void) -> [String] {
        var failures: [String] = []
        var checks = 0
        func check(_ name: String, _ condition: Bool) {
            checks += 1
            if !condition { failures.append(name) }
        }
        let lostIntegrity = MeetingCaptureIntegrity(missingSavedSystemFrames: 51_000)

        // a. Known system loss + a manual request: refused before the diarizer,
        // in plain words, and the spy proves nothing was loaded.
        do {
            var diarizerLoaded = false
            let refused = DiarizationEligibility.admit(
                captureIntegrity: lostIntegrity, hasAudio: true
            ) { diarizerLoaded = true }
            check("known system loss refused", refused == .refuseIncompleteRemoteAudio)
            check("refused meeting never reached the diarizer", !diarizerLoaded)
            check("refusal message is plain words",
                refused.problem == DiarizationEligibility.refuseIncompleteRemoteAudioMessage
                    && refused.problem?.contains("not fully saved") == true)
            check("refusal is not the engine's no-speech sentence",
                refused.problem?.localizedCaseInsensitiveContains("No speech detected") != true
                    && refused.problem?.contains("NoSpeech") != true)
        }

        // b. The other two states stay distinct from the incomplete one.
        do {
            check("meeting without audio refused",
                DiarizationEligibility.decision(captureIntegrity: nil, hasAudio: false) == .refuseNoAudio)
            check("no-audio message reuses the banner sentence",
                DiarizationEligibility.decision(captureIntegrity: nil, hasAudio: false).problem
                    == DiarizationError.noAudio.localizedDescription)
            check("intact saved audio runs",
                DiarizationEligibility.decision(captureIntegrity: nil, hasAudio: true) == .run)
            check("write failure on the mic track does not block the system track",
                DiarizationEligibility.decision(
                    captureIntegrity: MeetingCaptureIntegrity(missingSavedMicFrames: 900),
                    hasAudio: true) == .run)
            check("system write failure blocks the system track",
                DiarizationEligibility.decision(
                    captureIntegrity: MeetingCaptureIntegrity(audioWriteFailed: true),
                    hasAudio: true) == .refuseIncompleteRemoteAudio)
        }

        // c. A pass that found nothing: intact and empty say one thing, a lost
        // track another, and neither is the engine's raw sentence.
        do {
            let emptyIntact = DiarizationEligibility.noRunsMessage(captureIntegrity: nil)
            check("empty intact track says no speech was found",
                emptyIntact == DiarizationEligibility.noChannelSpeechMessage)
            check("empty-but-lost track stays the incomplete sentence",
                DiarizationEligibility.noRunsMessage(captureIntegrity: lostIntegrity)
                    == DiarizationEligibility.refuseIncompleteRemoteAudioMessage)
            check("no-speech sentence is not the engine's",
                emptyIntact != "No speech detected in audio"
                    && !emptyIntact.contains("not fully saved"))
            check("FluidAudio no-speech maps to the plain sentence",
                DiarizationEligibility.problemMessage(for: OfflineDiarizationError.noSpeechDetected)
                    == DiarizationEligibility.noChannelSpeechMessage)
            check("a different error maps to nothing (generic path)",
                DiarizationEligibility.problemMessage(for: CocoaError(.fileReadNoSuchFile)) == nil)
        }

        // d. An over-split relabelling keeps every surviving name and prunes
        // only what the pass retired; a new label gains no entry.
        do {
            let prior = ["Speaker 1": "Alex", "Speaker 2": "Sam", "Retired": "Old"]
            let overSplit = DiarizationService.mergedSpeakerNames(
                prior, labels: ["Speaker 1", "Speaker 2", "Speaker 3"])
            check("over-split keeps every surviving name",
                overSplit == ["Speaker 1": "Alex", "Speaker 2": "Sam"])
            check("vanished label's name pruned",
                DiarizationService.mergedSpeakerNames(prior, labels: ["Speaker 1"])
                    == ["Speaker 1": "Alex"])
            check("no labels clears the map",
                DiarizationService.mergedSpeakerNames(prior, labels: []) == [:])
            check("new label gains no entry",
                DiarizationService.mergedSpeakerNames(prior, labels: ["Speaker 1", "Speaker 3"])["Speaker 3"] == nil)
        }

        // e. The projection resolves every committed segment — the last one
        // included — through the saved map, and cannot drift on a second pass.
        do {
            let names = ["Speaker 1": "Confirmed Alex"]
            let segments = [
                TranscriptSegment(start: 0.5, end: 4, text: "Can you send the reviewed drawing?",
                                  source: .system, speaker: "Speaker 1"),
                TranscriptSegment(start: 5, end: 8, text: "Oui, je vois.",
                                  source: .system, speaker: "Speaker 2"),
                TranscriptSegment(start: 10, end: 13, text: "I will review it tomorrow.",
                                  source: .mic),
                TranscriptSegment(start: 30, end: 33, text: "Last words from the call.",
                                  source: .system, speaker: "Speaker 1"),
            ]
            let projected = MeetingSpeakerProjection.project(segments: segments, names: names)
            check("named label resolved", projected[0].speaker == "Confirmed Alex")
            check("unmapped label untouched", projected[1].speaker == "Speaker 2")
            check("microphone untouched", projected[2].speaker == nil && projected[2].source == .mic)
            check("last segment resolved", projected.last?.speaker == "Confirmed Alex")
            check("projection is idempotent",
                MeetingSpeakerProjection.project(segments: projected, names: names) == projected)
            check("projection leaves text and clock alone",
                projected.map(\.text) == segments.map(\.text)
                    && projected.map(\.start) == segments.map(\.start)
                    && projected.map(\.end) == segments.map(\.end))
        }

        // f. The automatic path and the manual path decide the same cases, from
        // one shared table, with the setting injected — a comparison of outcomes
        // rather than a restatement of one side's own body.
        do {
            // A small, measured loss: the recording is long, the loss is a
            // short tail, and the pass may still run.
            var smallLoss = MeetingCaptureIntegrity()
            smallLoss.savedCoverageMeasured = true
            smallLoss.recordedSeconds = 3_600
            smallLoss.systemSilentAfterSample = 3_400 * 16_000
            let rows: [(name: String, integrity: MeetingCaptureIntegrity?, hasAudio: Bool)] = [
                ("lost remote audio", lostIntegrity, true),
                ("no audio", nil, false),
                ("intact", nil, true),
                ("a small measured loss", smallLoss, true),
            ]
            for enabled in [true, false] {
                for row in rows {
                    let meeting = Meeting(
                        title: "Eligibility fixture", start: Date(), status: .diarizing,
                        captureIntegrity: row.integrity)
                    let manual = DiarizationEligibility.decision(
                        for: .system,
                        captureIntegrity: row.integrity,
                        hasAudio: row.hasAudio,
                        recordingSeconds: row.integrity?.recordedSeconds) == .run
                    let automatic = MeetingPipeline.shouldDiarize(
                        meeting, hasAudio: row.hasAudio, enabled: enabled)
                    check("the automatic path disagrees with the manual one "
                        + "(\(row.name), enabled=\(enabled))",
                          automatic == (manual && enabled))
                }
            }
            // The small measured loss is the case the extent rule exists for:
            // the pass still runs, and the loss is still a fact.
            let small = DiarizationEligibility.decision(
                for: .system, captureIntegrity: smallLoss, hasAudio: true,
                recordingSeconds: smallLoss.recordedSeconds)
            check("a small measured loss refused the whole meeting", small == .run)
        }

        // g. A refusal is not a failure: it must not hold the recording, and it
        // must not offer a retry that would refuse again.
        do {
            let store = MeetingStore.isolated()
            let root = store.directory(for: UUID()).deletingLastPathComponent()
            defer { try? FileManager.default.removeItem(at: root) }
            let contextStore = MeetingContextStore.isolatedForTesting(
                store: store,
                completer: MeetingContextReconciler.NoOpCompleter(),
                optionalAdmission: { false })
            let service = DiarizationService(store: store, contextStore: contextStore)
            let id = UUID()
            let meeting = Meeting(
                id: id, title: "Refusal fixture", start: Date(), status: .done,
                captureIntegrity: lostIntegrity)
            store.save(meeting)
            service.noteRefusal(id, decision: .refuseIncompleteRemoteAudio)
            check("a refusal was written into the failure slot",
                  service.problem(for: id) == nil)
            check("the refusal is not readable at all",
                  service.refusal(for: id) != nil)
            service.clearRefusal(for: id)
            check("dismissing a refusal did not clear it", service.refusal(for: id) == nil)
        }

        write("DIARIZE_ELIGIBILITY checks=\(checks)")
        return failures
    }
}
