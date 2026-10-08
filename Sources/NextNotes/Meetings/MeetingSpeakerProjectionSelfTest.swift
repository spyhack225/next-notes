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
        // The signed native app can compare the unchanged store/audio fixture
        // without another full build. Old logic exists only in this explicit SelfTest.
        write("MEETING_SPEAKER_PROJECTION_PRE_RENAME_\(failures.isEmpty ? "OK" : "FAILED") checks=\(checks)")
        let useOriginalRename = SelfTest.isRunning
            && SelfTest.requested == "--selftest-meeting-context"
            && CommandLine.arguments.contains("--speaker-rename-original")
        write("MEETING_SPEAKER_RENAME_MODE: " + (useOriginalRename ? "original-source-callback" : "production-view-method"))
        let commitRename: ([String: String], Meeting, MeetingStore, MeetingContextStore) -> String?
        if useOriginalRename {
            commitRename = { names, meeting, store, contextStore in
                var renamed = meeting
                renamed.speakerNames = names
                if store.save(renamed) {
                    MeetingContextStore.shared.refreshSpeakers(meetingID: renamed.id)
                }
                // Speakers confirmed (M-10): naming the clusters is the person saying the
                // pass was right, which was the last thing the temporary recording was
                // for. `releaseAudio` holds the three-line rule — a recording the user
                // asked to keep stays kept — and refuses while a diarization problem is
                // still offering another try.
                store.releaseAudio(for: renamed.id)
                return nil
            }
        } else {
            commitRename = { names, meeting, store, contextStore in
                MeetingDetailView.commitSpeakerNames(names, meeting: meeting,
                    store: store, contextStore: contextStore)
            }
        }
        // Exercise the exact View method called by the speaker naming sheet.
        // Fixture audio is inert bytes: this tests retention, never decoding/ASR.
        let fixtureAudio = Data("generic retained recording fixture".utf8)
        typealias RenameFixture = (meeting: Meeting, context: MeetingContextStore, audioURL: URL, contextURL: URL)
        func seedRename(_ suffix: String, temporary: Bool = true, withContext: Bool = true) -> RenameFixture? {
            var item = Meeting(title: "Rename UI fixture " + suffix, start: Date(), status: .done)
            item.speakerNames = ["Speaker 1": "Previous name"]
            item.audioFileName = MeetingStore.audioFile
            item.audioIsTemporary = temporary
            guard store.save(item) else { check("rename fixture metadata seed " + suffix, false); return nil }
            let directory = store.directory(for: item.id)
            let audioURL = directory.appendingPathComponent(MeetingStore.audioFile)
            do { try fixtureAudio.write(to: audioURL) }
            catch { check("rename fixture audio seed " + suffix, false); return nil }
            let injected = MeetingContextStore.isolatedForTesting(store: store,
                completer: MeetingContextReconciler.NoOpCompleter(), optionalAdmission: { false })
            store.saveLiveTranscript(live, for: item.id)
            guard store.saveTranscript(finals, for: item.id) else {
                check("rename fixture transcript seed " + suffix, false); return nil
            }
            if withContext {
                injected.ingest(live, meeting: item)
                guard injected.current?.meetingID == item.id, injected.load(meetingID: item.id) != nil else {
                    check("rename fixture context seed " + suffix, false); return nil
                }
            }
            return (item, injected, audioURL, directory.appendingPathComponent(MeetingContextStore.fileName))
        }
        if let fixture = seedRename("metadata-rejection") {
            let recordURL = store.directory(for: fixture.meeting.id).appendingPathComponent(MeetingStore.recordFile)
            let retainedRecordURL = recordURL.deletingLastPathComponent().appendingPathComponent("retained-meeting.json")
            let currentBefore = fixture.context.current
            let contextBytes = try? Data(contentsOf: fixture.contextURL)
            do {
                let recordBytes = try Data(contentsOf: recordURL)
                try FileManager.default.moveItem(at: recordURL, to: retainedRecordURL)
                try FileManager.default.createDirectory(at: recordURL, withIntermediateDirectories: false)
                let witness = recordURL.appendingPathComponent("witness.json")
                try recordBytes.write(to: witness)
                let problem = commitRename(["Speaker 1": "Accepted name"], fixture.meeting, store, fixture.context)
                check("rename rejected metadata reports plain failure",
                    problem == "The speaker names couldn’t be saved.")
                check("rename rejected metadata keeps current name",
                    store.meeting(id: fixture.meeting.id)?.speakerNames == fixture.meeting.speakerNames)
                check("rename rejected metadata keeps exact audio", (try? Data(contentsOf: fixture.audioURL)) == fixtureAudio)
                check("rename rejected metadata keeps current context", fixture.context.current == currentBefore)
                check("rename rejected metadata keeps exact context", (try? Data(contentsOf: fixture.contextURL)) == contextBytes)
                check("rename rejected metadata keeps hostile source and witness",
                    (try? Data(contentsOf: retainedRecordURL)) == recordBytes && (try? Data(contentsOf: witness)) == recordBytes)
                try FileManager.default.removeItem(at: recordURL)
                try FileManager.default.moveItem(at: retainedRecordURL, to: recordURL)
                check("rename rejected metadata keeps fresh-reader name",
                    store.freshReaderForTesting().meeting(id: fixture.meeting.id)?.speakerNames == fixture.meeting.speakerNames)
            } catch { check("rename metadata refusal fixture setup", false) }
        }
        if let fixture = seedRename("context-rejection") {
            let retainedContextURL = fixture.contextURL.deletingLastPathComponent().appendingPathComponent("retained-rename-context.json")
            let currentBefore = fixture.context.current
            do {
                let contextBytes = try Data(contentsOf: fixture.contextURL)
                try FileManager.default.moveItem(at: fixture.contextURL, to: retainedContextURL)
                try FileManager.default.createDirectory(at: fixture.contextURL, withIntermediateDirectories: false)
                let witness = fixture.contextURL.appendingPathComponent("witness.json")
                try contextBytes.write(to: witness)
                let names = ["Speaker 1": "Accepted name"]
                let problem = commitRename(names, fixture.meeting, store, fixture.context)
                check("rename accepted metadata rejected context reports partial save",
                    problem == "The speaker names were saved, but some meeting details couldn’t be updated.")
                check("rename rejected context keeps accepted names", store.meeting(id: fixture.meeting.id)?.speakerNames == names)
                check("rename rejected context retains accepted fresh-reader names",
                    store.freshReaderForTesting().meeting(id: fixture.meeting.id)?.speakerNames == names)
                check("rename rejected context keeps exact audio", (try? Data(contentsOf: fixture.audioURL)) == fixtureAudio)
                check("rename rejected context retains audio reference",
                    store.meeting(id: fixture.meeting.id)?.audioFileName == fixture.meeting.audioFileName
                    && store.freshReaderForTesting().meeting(id: fixture.meeting.id)?.audioFileName == fixture.meeting.audioFileName)
                check("rename rejected context keeps current context", fixture.context.current == currentBefore)
                check("rename rejected context keeps exact previous bytes",
                    (try? Data(contentsOf: retainedContextURL)) == contextBytes && (try? Data(contentsOf: witness)) == contextBytes)
                try FileManager.default.removeItem(at: fixture.contextURL)
                try FileManager.default.moveItem(at: retainedContextURL, to: fixture.contextURL)
                check("rename rejected context fresh consumer has previous name",
                    fixture.context.load(meetingID: fixture.meeting.id)?.questions.first?.speaker == currentBefore?.questions.first?.speaker)
            } catch { check("rename context refusal fixture setup", false) }
        }
        if let fixture = seedRename("accepted-temporary") {
            // A sheet snapshot must not undo metadata accepted while it was open.
            var newer = fixture.meeting
            newer.title = "Newer accepted title"
            check("rename concurrent metadata fixture save", store.save(newer))
            let names = ["Speaker 1": "Accepted name"]
            check("rename accepted save returns no problem", commitRename(names, fixture.meeting, store, fixture.context) == nil)
            check("rename accepted save retains newer metadata", store.meeting(id: fixture.meeting.id)?.title == newer.title)
            check("rename accepted save delivers current name", fixture.context.current?.questions.first?.speaker == "Accepted name")
            check("rename accepted save delivers durable name", fixture.context.load(meetingID: fixture.meeting.id)?.questions.first?.speaker == "Accepted name")
            check("rename accepted save preserves source authority", fixture.context.current?.questions.first?.source == .system)
            check("rename accepted save releases temporary recording", !FileManager.default.fileExists(atPath: fixture.audioURL.path)
                && store.meeting(id: fixture.meeting.id)?.audioFileName == nil)
            check("rename accepted save fresh reader uses exact map",
                store.freshReaderForTesting().meeting(id: fixture.meeting.id)?.speakerNames == names)
        }
        if let fixture = seedRename("accepted-kept", temporary: false) {
            check("rename kept recording accepted", commitRename(["Speaker 1": "Accepted name"], fixture.meeting, store, fixture.context) == nil)
            check("rename keeps explicitly retained audio", (try? Data(contentsOf: fixture.audioURL)) == fixtureAudio
                && store.meeting(id: fixture.meeting.id)?.audioFileName == fixture.meeting.audioFileName)
        }
        if let fixture = seedRename("no-context", withContext: false) {
            check("rename absent context accepted", commitRename(["Speaker 1": "Accepted name"], fixture.meeting, store, fixture.context) == nil)
            check("rename absent context creates none", !FileManager.default.fileExists(atPath: fixture.contextURL.path))
            check("rename absent context uses existing temporary release", !FileManager.default.fileExists(atPath: fixture.audioURL.path))
        }
        if let fixture = seedRename("deleted") {
            do {
                try FileManager.default.removeItem(at: store.directory(for: fixture.meeting.id))
                // A real fresh reader sees absence without initializing unrelated
                // shared cancellation/index services merely to arrange the fixture.
                let freshStore = store.freshReaderForTesting()
                check("rename deleted meeting reports plain failure", commitRename(["Speaker 1": "Accepted name"], fixture.meeting, freshStore, fixture.context)
                    == "This meeting is no longer available. The speaker names couldn’t be saved.")
                check("rename deleted meeting cannot be recreated", freshStore.meeting(id: fixture.meeting.id) == nil
                    && !FileManager.default.fileExists(atPath: store.directory(for: fixture.meeting.id).path))
            } catch { check("rename deleted fixture setup", false) }
        }
        for failure in failures { write("  MEETING_SPEAKER_PROJECTION_WRONG: \(failure)") }
        write("MEETING_SPEAKER_PROJECTION_\(failures.isEmpty ? "OK" : "FAILED") checks=\(checks)")
        return failures.isEmpty
    }
}
