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

        if failures.isEmpty {
            print("VOICE_DELIVERY_OK")
            return true
        }
        for failure in failures { print("VOICE_DELIVERY_FAILED: \(failure)") }
        print("VOICE_DELIVERY_FAILED")
        return false
    }
}
