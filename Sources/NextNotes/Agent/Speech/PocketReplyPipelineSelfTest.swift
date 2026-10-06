import Foundation
import Darwin
import Synchronization

/// Actual production player probe. Native callbacks are retained before their
/// MainActor hop; muted output proves software timing, not physical audibility.
@MainActor
enum PocketReplyPipelineSelfTest {
    static func run() async -> Bool {
        guard SelfTest.isRunning,
              CommandLine.arguments.contains("--selftest-tts-pocket"),
              CommandLine.arguments.contains("--tts-pocket-pipeline") else { return false }
        let lifetimeFailures = await cancellationOwnershipCases()
        let voice = PocketAgentVoice.shared
        await voice.prepare()
        guard voice.isReady else {
            print("POCKET_TTS_FAILED: pipeline model unavailable")
            return false
        }
        let clauses = ["The first note is ready.",
                       "I will keep working while we talk.",
                       "You can interrupt me at any time."]
        let playback = PocketSpeechBacking(voiceForTesting: "alba")
        let synth = AgentSpeechSynthesizer(backing: playback)
        synth.useTestingBacking(playback)
        synth.utteranceVolume = 0
        let notices = Mutex<[PocketPlayedBufferObservation]>([])
        playback.playedBufferObserverForTesting = { notice in
            notices.withLock { $0.append(notice) }
        }
        var events: [AgentSpeechSynthesizer.PlaybackEvent] = []
        var finished = false
        var failures: [String] = lifetimeFailures
        playback.onUtteranceStarted = { token in synth.notifyTestingFirstAudio(token: token) }
        playback.onUtteranceFinished = { token in synth.notifyTestingAudioFinished(token: token) }
        var nativeFailure = false
        playback.onFailure = { _, _, _ in
            nativeFailure = true
            failures.append("native Pocket synthesis failed")
        }
        synth.onPlaybackEvent = { event in
            events.append(event)
            if event == .completed(clauses[2]) { finished = true }
        }
        let gapIdentity = LatencyCorrelation(sessionID: UUID(), turnID: UUID())
        let buffer = StreamingSpeechBuffer(synthesizer: synth)
        buffer.begin()
        for clause in clauses {
            LatencyCorrelation.$current.withValue(gapIdentity) { buffer.append(clause + " ") }
            // Authored token cadence only; never used by the product path.
            try? await Task.sleep(for: .milliseconds(50))
        }
        buffer.finalize()
        let deadline = ContinuousClock.now.advanced(by: .seconds(90))
        while !finished && !nativeFailure && ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
        let engineStarts = playback.engineStartsForTesting
        let drained = !playback.isPlaybackEngineRunning
        let recorded = notices.withLock { $0 }
        synth.stop()
        await playback.finishStoppedPlayback()
        playback.playedBufferObserverForTesting = nil
        synth.restoreSystemBacking()

        func check(_ value: Bool, _ message: String) {
            if !value { failures.append(message) }
        }
        check(finished && drained, "reply did not drain and stop its engine")
        check(engineStarts == 1, "reply restarted output engine \(engineStarts) times")
        let started = events.compactMap { event -> String? in
            if case .startAcknowledged(let text) = event { return text }; return nil
        }
        let completed = events.compactMap { event -> String? in
            if case .completed(let text) = event { return text }; return nil
        }
        check(started == clauses && completed == clauses, "exact ordered clause receipts changed")
        var order: [UInt64] = []
        for notice in recorded where !order.contains(notice.token) { order.append(notice.token) }
        check(order.count == 3, "not all three clauses produced native played buffers")
        MetricsStore.shared.flushForTesting()
        let gapSpans = MetricsStore.shared.spans(named: .voiceInterClauseGap)
            .filter { $0.correlation == gapIdentity }
        check(gapSpans.count == 2, "same reply did not persist exactly two correlated production gap spans")
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        func seconds(_ ticks: UInt64) -> Double {
            Double(ticks) * Double(timebase.numer) / Double(timebase.denom) / 1e9
        }
        for (index, token) in order.enumerated() {
            let rows = recorded.filter { $0.token == token }
            for row in rows {
                print("POCKET_PIPELINE_BUFFER clause=\(index) ordinal=\(row.ordinal) samples=\(row.samples) nonzero=\(row.nonzero) scheduled=\(row.scheduledHostTime) played=\(row.playedHostTime)")
            }
            check(rows.contains { $0.nonzero }, "clause \(index) had no nonzero PCM")
            if let head = rows.first, head.playedHostTime >= head.scheduledHostTime {
                let acknowledgement = seconds(head.playedHostTime - head.scheduledHostTime)
                print(String(format: "POCKET_PIPELINE_ACK clause=%d seconds=%.6f headSamples=%d", index, acknowledgement, head.samples))
                check(head.samples <= 720 && (index != 0 || acknowledgement <= 0.050),
                      "clause \(index) first played acknowledgement exceeded 50ms")
            } else { check(false, "clause \(index) missing native head callback") }
            if index > 0, let head = rows.first,
               let tail = recorded.last(where: { $0.token == order[index - 1] }),
               head.playedHostTime >= tail.playedHostTime {
                let gap = seconds(head.playedHostTime - tail.playedHostTime) - Double(head.samples) / 24_000
                print(String(format: "POCKET_PIPELINE_GAP boundary=%d seconds=%.6f", index, gap))
                check(gap <= 0.050, "boundary \(index) software playback gap exceeded 50ms")
                let spans = gapSpans.filter { $0.note == "boundary=\(index) software_playback_estimate" }
                check(spans.count == 1 && spans.allSatisfy {
                    $0.source == "voice" && abs($0.durationSeconds - gap) <= 1e-9
                }, "boundary \(index) production span differs from same raw native software gap")
            } else if index > 0 {
                check(false, "boundary \(index) missing ordered native callbacks")
            }
        }
        print("POCKET_PIPELINE_ENGINE_STARTS \(engineStarts)")
        if failures.isEmpty { print("POCKET_TTS_PIPELINE_OK"); print("POCKET_TTS_OK") }
        else { for failure in failures { print("POCKET_TTS_PIPELINE_FAILED: \(failure)") }; print("POCKET_TTS_FAILED: pipeline") }
        return failures.isEmpty
    }

    /// Held external work uses the actual backing/owner task slots. Cancellation
    /// deliberately cannot release the hold: native cancellation also has to join.
    private static func cancellationOwnershipCases() async -> [String] {
        var failures: [String] = []
        for mode in ["stop", "quit"] {
            let owner = PocketAgentVoice()
            let playback = PocketSpeechBacking(voiceForTesting: "alba", voiceOwnerForTesting: owner)
            let synth = AgentSpeechSynthesizer(backing: playback)
            synth.useTestingBacking(playback)
            var entered = false
            var ended = false
            var release: CheckedContinuation<Void, Never>?
            playback.replyWorkForTesting = {
                entered = true
                await withCheckedContinuation { release = $0 }
                ended = true
            }
            synth.speak("The first note is ready.")
            let deadline = ContinuousClock.now.advanced(by: .seconds(5))
            while !entered && ContinuousClock.now < deadline { await Task.yield() }
            if !entered {
                failures.append("\(mode) held backing work was not admitted")
                synth.stop(); synth.restoreSystemBacking()
                continue
            }
            if mode == "stop" { synth.stop() }
            owner.beginTermination()
            var joinStarted = false
            var joined = false
            let join = Task { @MainActor in
                joinStarted = true
                await owner.finishTermination()
                joined = true
            }
            while !joinStarted { await Task.yield() }
            await Task.yield()
            if playback.isSpeaking || playback.isPlaybackEngineRunning {
                failures.append("\(mode) did not stop output immediately")
            }
            if joined || ended {
                failures.append("\(mode) owner termination escaped held backing work")
            }
            release?.resume()
            await join.value
            while !ended { await Task.yield() }
            synth.stop()
            await playback.finishStoppedPlayback()
            playback.replyWorkForTesting = nil
            synth.restoreSystemBacking()
            if !joined { failures.append("\(mode) owner failed to join released backing work") }
            print("POCKET_PIPELINE_LIFETIME mode=\(mode) entered=\(entered) ended=\(ended) joined=\(joined)")
        }
        return failures
    }
}
