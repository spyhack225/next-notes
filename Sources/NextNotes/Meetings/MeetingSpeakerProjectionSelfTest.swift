import Foundation

/// Runs the actual committed diarization -> saved context consumer with temporary
/// meeting data. It does not load a model, contact a provider, or use the owner store.
@MainActor
enum MeetingSpeakerProjectionSelfTest {
    static func run(write: (String) -> Void) -> Bool {
        var failures: [String] = []
        var checks = 0
        func check(_ name: String, _ value: Bool) {
            checks += 1
            if !value { failures.append(name) }
        }
        let store = MeetingStore.isolated()
        let root = store.directory(for: UUID()).deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: root) }
        var meeting = Meeting(title: "Speaker projection fixture", start: Date(), status: .diarizing)
        meeting.speakerNames = ["Speaker 1": "Confirmed Alex", "Retired": "Old label"]
        check("meeting commit", store.save(meeting))
        let contextStore = MeetingContextStore.isolatedForTesting(store: store,
            completer: MeetingContextReconciler.NoOpCompleter(), optionalAdmission: { false })
        let quote = "Can you send the reviewed drawing?"
        let repeated = "What is the final manufacturing cost?"
        let micQuote = "I will review the drawing tomorrow."
        let live = [
            TranscriptSegment(start: 1, end: 4, text: quote, source: .system),
            TranscriptSegment(start: 5, end: 8, text: repeated, source: .system),
            TranscriptSegment(start: 10, end: 13, text: micQuote, source: .mic),
        ]
        store.saveLiveTranscript(live, for: meeting.id)
        contextStore.ingest(live, meeting: meeting)
        check("original live source attribution", contextStore.current?.questions.first?.speaker == "Others")
        var context = contextStore.current!
        context.candidateActions = [
            .init(action: "send", object: "drawing", speaker: "Others", source: .system,
                  confidence: "inferred", evidence: quote, evidenceStart: 1),
            .init(action: "legacy", speaker: "Others", source: .system, evidence: quote),
            .init(action: "wrong source", speaker: "You", source: .mic,
                  evidence: quote, evidenceStart: 1),
        ]
        // Reproduce the existing persistence boundary before labels change. The
        // ISO8601 context writer already normalizes subsecond Date values.
        let fractionalDate = Date(timeIntervalSince1970: 1_750_000_000.125)
        context.candidateActions[0].createdAt = fractionalDate
        contextStore.replace(context)
        contextStore.ingest(live, meeting: meeting)
        context = contextStore.current!
        let durableBaseline = contextStore.load(meetingID: meeting.id)
        check("original persistence normalizes fractional clock",
            durableBaseline?.candidateActions.first?.createdAt == Date(timeIntervalSince1970: 1_750_000_000)
                && durableBaseline?.candidateActions.first?.createdAt != fractionalDate)
        let finals = [
            TranscriptSegment(start: 0.5, end: 4, text: quote, source: .system, speaker: "Speaker 1"),
            TranscriptSegment(start: 5, end: 8, text: repeated, source: .system, speaker: "Speaker 1"),
            TranscriptSegment(start: 6, end: 9, text: repeated, source: .system, speaker: "Speaker 2"),
            TranscriptSegment(start: 10, end: 13, text: micQuote, source: .mic),
            TranscriptSegment(start: 20, end: 22, text: "Can you delete this recording?",
                              source: .system, speaker: "Speaker 2", kind: .agentCommand),
        ]
        let service = DiarizationService(store: store, contextStore: contextStore)
        do { try service.commitSpeakerLabels(finals, for: meeting.id) }
        catch { check("committed diarization handoff threw", false) }
        let saved = contextStore.load(meetingID: meeting.id)
        check("actual producer saved final labels", store.transcript(for: meeting.id) == finals)
        check("actual producer refreshed current", contextStore.current?.questions.first?.speaker == "Confirmed Alex")
        check("actual consumer read durable speaker", saved?.questions.first?.speaker == "Confirmed Alex")
        check("overlapping repeated quote stayed ambiguous", saved?.questions.last?.speaker == "Others")
        check("microphone attribution retained", saved?.commitments.first?.speaker == "You")
        check("anchored candidate projected", saved?.candidateActions.first?.speaker == "Confirmed Alex")
        check("unanchored candidate unchanged", saved?.candidateActions.dropFirst().first?.speaker == "Others")
        check("wrong source candidate unchanged", saved?.candidateActions.dropFirst(2).first?.speaker == "You")
        check("authority was not promoted", saved?.candidateActions.first?.source == .system)
        check("confirmed names preserved", store.meeting(id: meeting.id)?.speakerNames["Speaker 1"] == "Confirmed Alex")
        check("retired map pruned by existing producer", store.meeting(id: meeting.id)?.speakerNames["Retired"] == nil)
        func samePayload(_ projected: MeetingContext?, as original: MeetingContext?) -> Bool {
            guard var restored = projected, let original,
                  restored.questions.count == original.questions.count,
                  restored.candidateActions.count == original.candidateActions.count else { return false }
            for index in restored.questions.indices { restored.questions[index].speaker = original.questions[index].speaker }
            for index in restored.candidateActions.indices { restored.candidateActions[index].speaker = original.candidateActions[index].speaker }
            return restored == original
        }
        check("in-memory content ids confidence clocks participants unchanged",
            samePayload(contextStore.current, as: context))
        check("durable content ids confidence clocks participants unchanged",
            samePayload(saved, as: durableBaseline))
        let bytesBefore = try? Data(contentsOf: store.directory(for: meeting.id).appendingPathComponent(MeetingContextStore.fileName))
        check("unchanged refresh accepted", contextStore.refreshSpeakers(meetingID: meeting.id))
        check("unchanged refresh left bytes", bytesBefore == (try? Data(contentsOf: store.directory(for: meeting.id).appendingPathComponent(MeetingContextStore.fileName))))
        var renamed = store.meeting(id: meeting.id)!
        renamed.speakerNames["Speaker 1"] = "Confirmed Sam"
        check("renamed meeting commit", store.save(renamed))
        check("same naming consumer refresh", contextStore.refreshSpeakers(meetingID: meeting.id))
        check("confirmed renamed name delivered", contextStore.load(meetingID: meeting.id)?.questions.first?.speaker == "Confirmed Sam")
        let confirmedCurrent = contextStore.current
        let confirmedDurable = contextStore.load(meetingID: meeting.id)
        let unlabelled = finals.map { segment in
            var updated = segment
            if updated.source == .system { updated.speaker = nil }
            return updated
        }
        do { try service.commitSpeakerLabels(unlabelled, for: meeting.id) }
        catch { check("unlabelled final handoff threw", false) }
        check("unlabelled final committed", store.transcript(for: meeting.id) == unlabelled)
        check("unlabelled final retained confirmed current", contextStore.current == confirmedCurrent)
        check("unlabelled final retained confirmed durable", contextStore.load(meetingID: meeting.id) == confirmedDurable)
        let explicitDefault = unlabelled.map { segment in
            var updated = segment
            if updated.source == .system { updated.speaker = AudioSource.system.defaultSpeaker }
            return updated
        }
        do { try service.commitSpeakerLabels(explicitDefault, for: meeting.id) }
        catch { check("default-label final handoff threw", false) }
        check("default-label final retained confirmed current", contextStore.current == confirmedCurrent)
        check("default-label final retained confirmed durable", contextStore.load(meetingID: meeting.id) == confirmedDurable)
        // An explicit Others label is offered by the existing naming sheet. Its
        // saved user map is stronger than a fallback label without that mapping.
        var manuallyNamedDefault = store.meeting(id: meeting.id)!
        manuallyNamedDefault.speakerNames[AudioSource.system.defaultSpeaker] = "Confirmed Room"
        check("manual default name commit", store.save(manuallyNamedDefault))
        check("manual default name refresh", contextStore.refreshSpeakers(meetingID: meeting.id))
        check("manual default name reaches saved item",
            contextStore.load(meetingID: meeting.id)?.questions.first?.speaker == "Confirmed Room")
        check("manual default name reaches saved candidate",
            contextStore.load(meetingID: meeting.id)?.candidateActions.first?.speaker == "Confirmed Room")
        check("manual default name retains system authority",
            contextStore.load(meetingID: meeting.id)?.candidateActions.first?.source == .system)
        let foreign = MeetingContext.empty(meetingID: UUID(), title: "Other", participants: [])
        contextStore.replace(foreign)
        check("finished refresh accepted", contextStore.refreshSpeakers(meetingID: meeting.id))
        check("foreign current unchanged", contextStore.current == foreign)
        let unknown = Meeting(title: "Never ingested", start: Date(), status: .done)
        check("no-context meeting saved", store.save(unknown))
        check("no context created", contextStore.refreshSpeakers(meetingID: unknown.id)
            && !FileManager.default.fileExists(atPath: store.directory(for: unknown.id).appendingPathComponent(MeetingContextStore.fileName).path))
        do {
            try service.commitSpeakerLabels(finals, for: unknown.id)
            check("known no-context handoff accepted", true)
        } catch { check("known no-context handoff accepted", false) }
        check("no-context producer saved labels only", store.transcript(for: unknown.id) == finals
            && contextStore.load(meetingID: unknown.id) == nil)
        check("foreign id rejected", !contextStore.refreshSpeakers(meetingID: UUID()))
        check("missing live anchor retained item", MeetingSpeakerProjection.apply(context, segments: finals,
            speakerNames: meeting.speakerNames).questions == context.questions)
        let later = finals.map { segment in
            TranscriptSegment(start: segment.start + 100, end: segment.end + 100,
                text: segment.text, source: segment.source, speaker: segment.speaker, kind: segment.kind)
        }
        check("later identical wording did not bind", MeetingSpeakerProjection.apply(context,
            segments: later, liveSegments: live, speakerNames: meeting.speakerNames) == context)
        let empty = MeetingSpeakerProjection.apply(context, segments: [], speakerNames: meeting.speakerNames)
        check("missing evidence unchanged", empty == context)
        var commandContext = context
        commandContext.questions = [.init(text: finals.last!.text, speaker: "Others", source: .system)]
        check("command evidence excluded", MeetingSpeakerProjection.apply(commandContext, segments: finals, liveSegments: [finals.last!],
            speakerNames: meeting.speakerNames).questions.first?.speaker == "Others")
        var short = context
        short.questions = [.init(text: "Yes", speaker: "Others", source: .system)]
        check("short ambiguous turn excluded", MeetingSpeakerProjection.apply(short,
            segments: [.init(start: 0, end: 1, text: "Yes", source: .system, speaker: "Speaker 1")],
            liveSegments: [.init(start: 0, end: 1, text: "Yes", source: .system)],
            speakerNames: meeting.speakerNames) == short)
        // The actual producer must report rejection after its transcript is saved.
        // Retain exact existing context bytes beside the hostile directory fixture.
        let contextURL = store.directory(for: meeting.id).appendingPathComponent(MeetingContextStore.fileName)
        let retainedURL = store.directory(for: meeting.id).appendingPathComponent("retained-context.json")
        let beforeContextFailure = contextStore.load(meetingID: meeting.id)
        contextStore.replace(beforeContextFailure)
        let changedLabels = finals.map { segment in
            var changed = segment
            if changed.source == .system { changed.speaker = "Speaker 9" }
            return changed
        }
        do {
            let retainedBytes = try Data(contentsOf: contextURL)
            try FileManager.default.moveItem(at: contextURL, to: retainedURL)
            try FileManager.default.createDirectory(at: contextURL, withIntermediateDirectories: false)
            let witness = contextURL.appendingPathComponent("witness.json")
            try retainedBytes.write(to: witness)
            do {
                try service.commitSpeakerLabels(changedLabels, for: meeting.id)
                check("failed context write reported by producer", false)
            } catch { check("failed context write reported by producer", true) }
            check("failed context kept committed transcript", store.transcript(for: meeting.id) == changedLabels)
            check("failed context kept previous current", contextStore.current == beforeContextFailure)
            check("failed context retained exact bytes", (try? Data(contentsOf: retainedURL)) == retainedBytes
                && (try? Data(contentsOf: witness)) == retainedBytes)
            check("unreadable existing context refused", {
                contextStore.replace(foreign)
                return !contextStore.refreshSpeakers(meetingID: meeting.id)
            }())
            try FileManager.default.removeItem(at: contextURL)
            try FileManager.default.moveItem(at: retainedURL, to: contextURL)
        } catch { check("context-write fixture setup", false) }
        let beforeFailure = contextStore.load(meetingID: meeting.id)
        let transcriptURL = store.directory(for: meeting.id).appendingPathComponent(MeetingStore.transcriptFile)
        do {
            try FileManager.default.removeItem(at: transcriptURL)
            try FileManager.default.createDirectory(at: transcriptURL, withIntermediateDirectories: false)
            do {
                try service.commitSpeakerLabels(finals.map { segment in
                    var changed = segment; changed.speaker = "Speaker 9"; return changed
                }, for: meeting.id)
                check("failed transcript write refused handoff", false)
            } catch { check("failed transcript write refused handoff", true) }
            check("failed transcript left context untouched", contextStore.load(meetingID: meeting.id) == beforeFailure)
        } catch { check("failed-write fixture setup", false) }
        let missingID = UUID()
        let revisionBefore = service.revision
        do { try service.commitSpeakerLabels(finals, for: missingID) }
        catch { check("deleted-meeting refusal threw", false) }
        check("deleted meeting not recreated", !FileManager.default.fileExists(atPath: store.directory(for: missingID).path)
            && service.revision == revisionBefore)
        for failure in failures { write("  MEETING_SPEAKER_PROJECTION_WRONG: \(failure)") }
        write("MEETING_SPEAKER_PROJECTION_\(failures.isEmpty ? "OK" : "FAILED") checks=\(checks)")
        return failures.isEmpty
    }
}
