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
        session.speak("First fact. Second fact.")
        let messageID = AgentSession.shared.recordAssistant(
            "First fact. Second fact.", source: .voice)
        VoicePlaybackDelivery.shared.bind(
            messageID: messageID, turn: RealtimeAgent.shared.currentGeneration)
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

        failures += streamingCases()

        if failures.isEmpty {
            print("VOICE_DELIVERY_OK")
            return true
        }
        for failure in failures { print("VOICE_DELIVERY_FAILED: \(failure)") }
        print("VOICE_DELIVERY_FAILED")
        return false
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
        check(recorder.spoken == [meetingReply],
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
