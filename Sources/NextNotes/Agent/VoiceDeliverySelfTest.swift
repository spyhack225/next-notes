import Foundation

/// Exercises the production delivery listener and announcement queue with a
/// recording output backend. It cannot establish physical audibility.
enum VoiceDeliverySelfTest {
    @MainActor
    static func run() async -> Bool {
        guard SelfTest.isRunning else {
            print("VOICE_DELIVERY_FAILED: self-test harness required")
            return false
        }
        var failures: [String] = []
        func check(_ condition: Bool, _ message: String) {
            if !condition { failures.append(message) }
        }

        let capture = AgentCaptureController.shared
        let session = RealtimeAudioSession.shared
        let synth = AgentSpeechSynthesizer.shared
        let recorder = RecordingSpeechBacking()
        synth.useTestingBacking(recorder)
        defer { synth.restoreSystemBacking() }

        let summaryOnly = AgentSession.Message(role: "assistant", text: "Full written result with additional details.",
            source: "voice", speechDelivery: VoiceSpeechDelivery(completedText: "The task finished.", status: "completed"))
        check(summaryOnly.modelContextText.contains("Completed spoken clauses: The task finished.")
              && summaryOnly.modelContextText.contains("do not assume the user heard it"),
              "a completed short summary marked the full written answer as spoken")
        await capture.beginSession(captureAudio: false)
        session.speak(OutputScheduler.tokenForTesting(), "First fact. Second fact.")
        let messageID = AgentSession.shared.recordAssistant(
            "First fact. Second fact.", source: .voice)
        VoicePlaybackDelivery.shared.bind(
            messageID: messageID, output: session.retainedOutputID!, turn: RealtimeAgent.shared.currentGeneration)
        let firstToken = synth.currentPlaybackToken
        synth.notifyTestingFirstAudio(token: firstToken)
        synth.notifyTestingAudioFinished(token: firstToken)
        let secondToken = synth.currentPlaybackToken
        synth.notifyTestingAudioFinished(token: firstToken)
        check(firstToken != secondToken && synth.currentPlaybackToken == secondToken,
              "old clause callback advanced the current clause")
        let pending = AgentSession.shared.messages.first { $0.id == messageID }
        check(pending?.speechDelivery?.completedText == "First fact."
              && pending?.speechDelivery?.status == "pending",
              "history did not retain completed and pending clauses")
        check(pending?.modelContextText.contains("No complete spoken clause") == false
              && pending?.modelContextText.contains("do not assume the user heard it") == true,
              "model context did not distinguish generated from acknowledged speech")

        session.noteUserSpeech()
        let interrupted = AgentSession.shared.messages.first { $0.id == messageID }
        check(interrupted?.speechDelivery?.completedText == "First fact."
              && interrupted?.speechDelivery?.status == "interrupted",
              "interruption marked the unplayed second clause as delivered")

        RealtimeAgent.shared.userSpeechEnded()
        recorder.reset()
        VoiceAnnouncementQueue.shared.enqueue("One update. Two updates.")
        check(VoiceAnnouncementQueue.shared.flush(userHasFloor: false),
              "announcement did not enter playback")
        check(recorder.spoken == ["One update."],
              "announcement did not begin with one clause")
        let announcementFirst = synth.currentPlaybackToken
        synth.notifyTestingFirstAudio(token: announcementFirst)
        synth.notifyTestingAudioFinished(token: announcementFirst)
        check(recorder.spoken == ["One update.", "Two updates."],
              "announcement did not advance to second clause")
        session.noteUserSpeech()
        RealtimeAgent.shared.userSpeechEnded()
        recorder.reset()
        check(VoiceAnnouncementQueue.shared.flush(userHasFloor: false),
              "interrupted announcement was not retried")
        check(recorder.spoken == ["Two updates."],
              "retry did not contain exactly the remaining clause")
        synth.notifyTestingAudioFinished(token: synth.currentPlaybackToken)
        check(!VoiceAnnouncementQueue.shared.flush(userHasFloor: false),
              "completed announcement replayed twice")

        VoiceAnnouncementQueue.shared.enqueue("Old session result.")
        await capture.endSession(source: .done)
        await capture.beginSession(captureAudio: false)
        recorder.reset()
        check(!VoiceAnnouncementQueue.shared.flush(userHasFloor: false)
              && recorder.spoken.isEmpty,
              "old session announcement leaked into new session")
        await capture.endSession(source: .done)

        let scheduler = await OutputSchedulerSelfTest.run()
        failures += scheduler.failures

        failures += streamingCases()
        failures += await replySubmissionCases()
        failures += await OutputTokenSelfTest.run()

        if failures.isEmpty {
            print("VOICE_DELIVERY_OK")
            return true
        }
        for failure in failures { print("VOICE_DELIVERY_FAILED: \(failure)") }
        print("VOICE_DELIVERY_FAILED")
        return false
    }

    /// Original and fixed share the actual reply/text/synth/ledger consumers.
    /// Held callbacks expose synthesis submission, never pretend audio was heard.
    @MainActor
    private static func replySubmissionCases() async -> [String] {
        var failures: [String] = []
        func check(_ ok: Bool, _ name: String) { if !ok { failures.append("reply pipeline: " + name) } }
        let capture = AgentCaptureController.shared
        let session = RealtimeAudioSession.shared
        let synth = AgentSpeechSynthesizer.shared
        await capture.beginSession(captureAudio: false)
        let backing = RecordingReplySpeechBacking()
        synth.useTestingBacking(backing)
        var events: [AgentSpeechSynthesizer.PlaybackEvent] = []
        let prior = synth.onPlaybackEvent
        synth.onPlaybackEvent = { event in prior?(event); events.append(event) }
        defer { synth.stop(); synth.onPlaybackEvent = prior; synth.restoreSystemBacking() }
        let clauses = ["The first note is ready.", "I will keep working while we talk.", "You can interrupt me at any time."]
        let full = clauses.joined(separator: " ")
        let output = OutputScheduler.tokenForTesting()
        check(session.beginSpokenReply(output), "authored reply was not admitted")
        for clause in clauses { session.appendSpokenReply(output, clause + " ") }
        let message = AgentSession.shared.recordAssistant(full, source: .voice)
        if let id = session.retainedOutputID {
            VoicePlaybackDelivery.shared.bind(messageID: message, output: id, turn: RealtimeAgent.shared.currentGeneration)
        } else { failures.append("reply pipeline: missing actual output identity") }
        check(backing.submitted.map(\.text) == clauses, "later clauses waited for first playback completion")
        check(backing.beginCount == 1 && backing.finishCount == 0, "reply began repeatedly or finished before text closed")
        synth.pauseForListening()
        let held = backing.submitted.map(\.token)
        session.finalizeSpokenReply(output)
        session.finalizeSpokenReply(output)
        check(backing.finishCount == 1 && synth.isPausedForListening,
              "text finalization did not finish the same paused reply exactly once")
        synth.resumeAfterListening()
        check(backing.pauseCount == 1 && backing.resumeCount == 1 && backing.submitted.map(\.token) == held,
              "pause/resume restarted synthesis or lost submitted tokens")
        var expected: [AgentSpeechSynthesizer.PlaybackEvent] = []
        let originalToken = synth.currentPlaybackToken
        for clause in clauses {
            let token = synth.currentPlaybackToken
            backing.onUtteranceStarted?(token)
            backing.complete(token)
            expected += [.startAcknowledged(clause), .completed(clause)]
            if clause == clauses[0] {
                let next = synth.currentPlaybackToken
                let n = events.count
                backing.onUtteranceFinished?(token)
                check(synth.currentPlaybackToken == next && events.count == n, "stale completion advanced a successor")
                let row = AgentSession.shared.messages.first { $0.id == message }
                check(row?.speechDelivery?.completedText == clauses[0] && row?.speechDelivery?.status == "pending",
                      "one completed clause marked unplayed text delivered")
            }
        }
        check(events.filter { if case .startAcknowledged = $0 { return true }; if case .completed = $0 { return true }; return false } == expected,
              "clause acknowledgements changed text, order or identity")
        check(AgentSession.shared.messages.first { $0.id == message }?.speechDelivery ==
              VoiceSpeechDelivery(completedText: full, status: "completed"), "completed reply did not reach actual delivery history")

        events = []
        session.speak(OutputScheduler.tokenForTesting(), full)
        let cancelMessage = AgentSession.shared.recordAssistant(full, source: .voice)
        if let id = session.retainedOutputID {
            VoicePlaybackDelivery.shared.bind(messageID: cancelMessage, output: id, turn: RealtimeAgent.shared.currentGeneration)
        }
        let stoppedToken = synth.currentPlaybackToken
        backing.onUtteranceStarted?(stoppedToken)
        session.noteUserSpeech()
        let interrupted: [AgentSpeechSynthesizer.PlaybackEvent] = [
            .interrupted(clauses[0], wasRendered: true), .interrupted(clauses[1], wasRendered: false),
            .interrupted(clauses[2], wasRendered: false)]
        check(events.filter { if case .interrupted = $0 { return true }; return false } == interrupted,
              "stop failed to retire every submitted or queued clause")
        let cancelled = AgentSession.shared.messages.first { $0.id == cancelMessage }?.speechDelivery
        check(cancelled?.completedText == "" && cancelled?.status == "interrupted",
              "started-only speech was marked completely heard")
        let begins = backing.beginCount, finishes = backing.finishCount
        synth.speak("Only one short reply.")
        let successor = synth.currentPlaybackToken
        let eventCount = events.count
        backing.onUtteranceStarted?(originalToken)
        backing.onUtteranceFinished?(stoppedToken)
        check(synth.currentPlaybackToken == successor && events.count == eventCount,
              "old reply callback changed a new one-shot reply")
        check(backing.beginCount == begins + 1 && backing.finishCount == finishes + 1
              && backing.submitted.last?.text == "Only one short reply.", "one-shot omitted reply begin/enqueue/finish")
        backing.onUtteranceStarted?(successor)
        backing.complete(successor)
        check(!backing.isSpeaking && synth.pendingClauseCount == 0, "one-shot did not drain")

        // Actual reply failure names the existing head token, not a second text copy.
        // Retire only a partially played head; untouched successors remain eligible.
        let safe = RecordingSpeechBacking()
        synth.useTestingBacking(backing, fallback: safe)
        synth.speak(full)
        events = []
        let first = synth.currentPlaybackToken
        backing.onUtteranceStarted?(first)
        backing.complete(first)
        let partial = synth.currentPlaybackToken
        backing.onUtteranceStarted?(partial)
        synth.pauseForListening()
        let beforeFailure = events
        backing.onFailure?("", 0, partial &+ 1)
        backing.onFailure?("", 0, first)
        check(events == beforeFailure && safe.spoken.isEmpty && synth.currentPlaybackToken == partial,
              "future or completed-head failure changed the current reply")
        backing.stop() // Production failure stops native playback before delivering this receipt.
        backing.onFailure?("", 0, partial)
        backing.onFailure?("", 0, partial)
        check(synth.isPausedForListening && safe.spoken.isEmpty,
              "partial failure spoke through pause or duplicate receipt")
        check(events.filter { if case .interrupted = $0 { return true }; return false }
              == [.interrupted(clauses[1], wasRendered: true)],
              "partial failure interrupted untouched successors or failed to retire only its head")
        synth.resumeAfterListening()
        check(safe.spoken == [clauses[2]] && synth.currentPlaybackToken != partial,
              "partial fallback replayed completed/started text or lost untouched successor")
        let fallbackToken = synth.currentPlaybackToken
        let fallbackEvents = events
        backing.onUtteranceStarted?(partial)
        backing.onUtteranceFinished?(partial)
        check(events == fallbackEvents && synth.currentPlaybackToken == fallbackToken,
              "late native callback retired fallback successor")
        synth.notifyTestingFirstAudio(token: fallbackToken)
        synth.notifyTestingAudioFinished(token: fallbackToken)
        check(events.filter { if case .completed = $0 { return true }; return false }
              == [.completed(clauses[0]), .completed(clauses[2])],
              "fallback completion blessed partially played text or changed exact completed ledger")
        // A late completion promotes an already submitted native head even while
        // its player remains paused, so a failure cannot strand that successor.
        synth.useTestingBacking(backing, fallback: safe)
        let startIndex = backing.submitted.count
        synth.prepareForStream()
        synth.enqueueClause(clauses[0])
        synth.enqueueClause(clauses[1])
        let heldHead = synth.currentPlaybackToken
        synth.pauseForListening()
        backing.complete(heldHead)
        synth.enqueueClause(clauses[2])
        if let queued = backing.submitted.dropFirst(startIndex).dropFirst().first {
            check(synth.isPausedForListening && synth.currentPlaybackToken == queued.token,
                  "paused completion lost the already submitted successor identity")
            let spokenBefore = safe.spoken.count
            backing.stop()
            backing.onFailure?("", 0, queued.token)
            check(synth.isPausedForListening && safe.spoken.count == spokenBefore,
                  "unrendered queued failure played through pause")
            synth.resumeAfterListening()
            check(Array(safe.spoken.dropFirst(spokenBefore)) == [clauses[1]],
                  "queued failure was lost or resumed the wrong clause")
            synth.notifyTestingFirstAudio(token: synth.currentPlaybackToken)
            synth.notifyTestingAudioFinished(token: synth.currentPlaybackToken)
            check(Array(safe.spoken.dropFirst(spokenBefore)) == Array(clauses.dropFirst()),
                  "paused append displaced or replayed an older successor")
            synth.notifyTestingFirstAudio(token: synth.currentPlaybackToken)
            synth.notifyTestingAudioFinished(token: synth.currentPlaybackToken)
        } else {
            failures.append("reply pipeline: missing actual submitted successor for paused failure")
        }
        synth.stop()

        // After a rendered final head fails, late text still cannot play through pause.
        synth.useTestingBacking(backing, fallback: safe)
        synth.prepareForStream()
        synth.enqueueClause(clauses[0])
        let finalHead = synth.currentPlaybackToken
        backing.onUtteranceStarted?(finalHead)
        synth.pauseForListening()
        backing.stop()
        backing.onFailure?("", 0, finalHead)
        let spokenBeforeAppend = safe.spoken.count
        let nativeBeforeAppend = backing.submitted.count
        synth.enqueueClause(clauses[1])
        check(safe.spoken.count == spokenBeforeAppend && backing.submitted.count == nativeBeforeAppend
              && synth.isPausedForListening,
              "late fallback text played through pause")
        synth.resumeAfterListening()
        check(Array(safe.spoken.dropFirst(spokenBeforeAppend)) == [clauses[1]],
              "late fallback text was lost or replayed the rendered head")
        synth.stop()
        await capture.endSession(source: .done)
        return failures
    }

    @MainActor
    private final class RecordingReplySpeechBacking: AgentReplySpeechBacking {
        struct Submission { let text: String; let token: UInt64 }
        var onUtteranceStarted: ((UInt64) -> Void)?
        var onUtteranceFinished: ((UInt64) -> Void)?
        var onFailure: ((String, Float, UInt64) -> Void)?
        private(set) var submitted: [Submission] = []
        private(set) var beginCount = 0, finishCount = 0, pauseCount = 0, resumeCount = 0
        private var active: Set<UInt64> = []
        var isSpeaking: Bool { !active.isEmpty }
        func beginReply(volume: Float) { beginCount += 1 }
        func enqueue(_ text: String, token: UInt64) { submitted.append(.init(text: text, token: token)); active.insert(token) }
        func finishReply() { finishCount += 1 }
        // Original synth still calls speak; both paths record real backing entry.
        func speak(_ text: String, volume: Float, token: UInt64) { enqueue(text, token: token) }
        func pauseForListening() { pauseCount += 1 }
        func resumeAfterListening() { resumeCount += 1 }
        func stop() { active.removeAll() }
        func complete(_ token: UInt64) { active.remove(token); onUtteranceFinished?(token) }
    }

    // MARK: - P0-09 streaming cases

    /// Drives the real `StreamingSpeechBuffer` with the recording backing and
    /// asserts on what the recorder was asked to speak. Kept in its own
    /// function, apart from the announcement cases above, so a later rewrite of
    /// those cannot disturb these.
    @MainActor
    private static func streamingCases() -> [String] {
        var failures: [String] = []
        func check(_ condition: Bool, _ message: String) {
            if !condition { failures.append(message) }
        }

        // P0-09: the speech cap is 280 characters per clause.
        let clauseLimit = 280

        let synth = AgentSpeechSynthesizer.shared
        let recorder = RecordingSpeechBacking()
        synth.useTestingBacking(recorder)
        defer { synth.restoreSystemBacking() }

        // 600 characters, five sentences, one paragraph, no URL, list or tool
        // id. The second sentence is longer than the 280-character clause cap
        // on purpose, so it must be split before it is spoken.
        let longReply = [
            "The planning session covered three main topics, and the notes are ready to read.",
            "First, the design review confirmed that the new onboarding flow is ready for a limited rollout next month, provided that the support team has enough time to prepare its training materials and update the help centre articles before the launch date arrives, and the training schedule still needs one more review.",
            "Second, engineering reported that the migration finished ahead of schedule and under budget.",
            "Third, marketing asked for two more weeks before committing to a launch date.",
            "That is the fifth and final sentence.",
        ].joined(separator: " ")

        // a. A 600-character reply is spoken in full: length is judged per
        //    clause, and length never stops a clause that is already playing.
        check(longReply.count == 600,
              "long reply fixture is \(longReply.count) characters, not 600")
        recorder.reset()
        let longBuffer = StreamingSpeechBuffer(synthesizer: synth)
        longBuffer.begin()
        for chunk in chunks(of: longReply, size: 20) { longBuffer.append(chunk) }
        longBuffer.finalize()
        drain(synth)
        let spokenLength = recorder.spoken.reduce(0) { $0 + $1.count }
        check(recorder.spoken.contains("That is the fifth and final sentence."),
              "600-character reply did not speak its last sentence: \(recorder.spoken)")
        check(spokenLength >= 580,
              "600-character reply spoke only \(spokenLength) characters")
        check(recorder.spoken.allSatisfy { $0.count <= clauseLimit },
              "a clause over \(clauseLimit) characters was enqueued: \(recorder.spoken)")
        check(recorder.stopCount == 0,
              "length stopped the playing clause (stopCount=\(recorder.stopCount))")

        // b1. A URL anywhere in the reply keeps the whole reply silent.
        recorder.reset()
        let urlReply = "The report is ready at https://example.com/report for your review."
        let urlBuffer = StreamingSpeechBuffer(synthesizer: synth)
        urlBuffer.begin()
        for chunk in chunks(of: urlReply, size: 20) { urlBuffer.append(chunk) }
        urlBuffer.finalize()
        drain(synth)
        check(recorder.spoken.isEmpty, "URL reply spoke clauses: \(recorder.spoken)")

        // b2. A URL after one spoken clause stops the clause that is playing.
        recorder.reset()
        let urlAfter = StreamingSpeechBuffer(synthesizer: synth)
        urlAfter.begin()
        urlAfter.append("Here is the first sentence. ")
        urlAfter.append("See https://example.com/doc for the details.")
        urlAfter.finalize()
        drain(synth)
        check(recorder.stopCount == 1,
              "a URL after a spoken clause should stop playback exactly once, got \(recorder.stopCount)")
        check(recorder.spoken == ["Here is the first sentence."],
              "URL clause was enqueued or the spoken clause was lost: \(recorder.spoken)")

        // c. A sentence ending in “meeting.” is ordinary prose, not a tool id.
        let meetingReply = "The rest of your afternoon looks completely clear, and the next open window in the calendar runs straight through all the way until your 3 PM meeting."
        check(meetingReply.count == 150,
              "meeting reply fixture is \(meetingReply.count) characters, not 150")
        recorder.reset()
        let meetingBuffer = StreamingSpeechBuffer(synthesizer: synth)
        meetingBuffer.begin()
        for chunk in chunks(of: meetingReply, size: 20) { meetingBuffer.append(chunk) }
        meetingBuffer.finalize()
        drain(synth)
        // P2-06 may deliver the first comma chunk before the sentence ends.
        // Preserve every word/punctuation through the actual drained consumer.
        check(recorder.spoken.joined(separator: " ") == meetingReply,
              "prose ending in “meeting.” was cut: \(recorder.spoken)")
        check(recorder.stopCount == 0,
              "prose ending in “meeting.” stopped playback (stopCount=\(recorder.stopCount))")

        // d. A long listing after a spoken sentence: no listing line is read,
        //    and the clause already playing is not stopped.
        recorder.reset()
        let listingBuffer = StreamingSpeechBuffer(synthesizer: synth)
        listingBuffer.begin()
        listingBuffer.append("Here is the summary of the folder contents. ")
        listingBuffer.append("1. Report draft\n2. Budget sheet\n3. Meeting notes\n"
            + "4. Travel plan\n5. Archive folder\n")
        listingBuffer.finalize()
        drain(synth)
        check(recorder.spoken == ["Here is the summary of the folder contents."],
              "long listing was read or cut the first sentence: \(recorder.spoken)")
        check(recorder.stopCount == 0,
              "long listing stopped the playing clause (stopCount=\(recorder.stopCount))")

        return failures
    }

    /// Split a fixture into fixed-size character chunks, the way a token stream
    /// arrives. Twenty characters is roughly a few words.
    private static func chunks(of text: String, size: Int) -> [String] {
        var result: [String] = []
        var start = text.startIndex
        while start < text.endIndex {
            let end = text.index(start, offsetBy: size, limitedBy: text.endIndex)
                ?? text.endIndex
            result.append(String(text[start..<end]))
            start = end
        }
        return result
    }

    /// Move every queued clause through the recording backing so `spoken` holds
    /// the whole reply. The recording backing never finishes a clause by itself,
    /// so a reply with several clauses would otherwise sit in pending.
    @MainActor
    private static func drain(_ synth: AgentSpeechSynthesizer) {
        var guardCount = 0
        while synth.pendingClauseCount > 0, guardCount < 200 {
            synth.notifyTestingAudioFinished(token: synth.currentPlaybackToken)
            guardCount += 1
        }
    }
}
