import Foundation
import FluidAudio

/// Model-backed comparison of Pocket's one-shot path and the native persistent
/// session. This test does not select a playback implementation for the app.
@MainActor
enum PocketTtsSessionSelfTest {
    private static func elapsed(since start: ContinuousClock.Instant) -> Double {
        let parts = start.duration(to: .now).components
        return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
    }

    static func run() async -> Bool {
        let voice = PocketAgentVoice.shared
        let readyBegan = ContinuousClock.now
        await voice.prepare()
        let readySeconds = elapsed(since: readyBegan)
        guard voice.isReady else {
            print("POCKET_SESSION_FAILED: model unavailable: \(voice.errorMessage ?? "unknown")")
            return false
        }

        let manager = voice.manager
        let clauses = [
            "The first note is ready.",
            "I will keep working while we talk."
        ]
        do {
            if CommandLine.arguments.contains("--voice-pocket-session-first") {
                let coldStart = ContinuousClock.now
                let staged = try await manager.makeSession(voice: "alba")
                let coldPrefill = elapsed(since: coldStart)
                let submitted = ContinuousClock.now
                staged.enqueue(clauses[0])
                staged.finish()
                var firstPCM: Double?
                var frames = 0
                for try await frame in staged.frames {
                    if firstPCM == nil { firstPCM = elapsed(since: submitted) }
                    frames += 1
                    guard frame.utteranceIndex == 0 else {
                        print("POCKET_SESSION_FAILED: cold stage emitted wrong utterance")
                        return false
                    }
                }
                await staged.cancel()
                guard let firstPCM, frames >= 3 else {
                    print("POCKET_SESSION_FAILED: cold staged session emitted no frames")
                    return false
                }
                print(String(format: "Pocket session-first cold prefill %.3fs; first PCM after enqueue %.3fs; total %.3fs",
                             coldPrefill, firstPCM, coldPrefill + firstPCM))
            }
            var oneShotFirst: [Double] = []
            var oneShotFrames: [Int] = []
            for text in clauses {
                let began = ContinuousClock.now
                let stream = try await manager.synthesizeStreaming(text: text, voice: "alba")
                var first: Double?
                var count = 0
                var nonzero = false
                for try await frame in stream {
                    if first == nil { first = elapsed(since: began) }
                    count += 1
                    if !nonzero { nonzero = frame.samples.contains { abs($0) > 0.0001 } }
                }
                guard let first, count >= 3, nonzero else {
                    print("POCKET_SESSION_FAILED: one-shot generated no audible frames")
                    return false
                }
                oneShotFirst.append(first)
                oneShotFrames.append(count)
            }

            let preparationBegan = ContinuousClock.now
            let session = try await manager.makeSession(voice: "alba")
            let preparationSeconds = elapsed(since: preparationBegan)
            let enqueueBegan = ContinuousClock.now
            session.enqueue(clauses[0])
            session.enqueue(clauses[1])
            session.finish()
            var sessionFirst: [Double?] = [nil, nil]
            var sessionFrames = [0, 0]
            var sessionNonzero = [false, false]
            var lastFirstUtteranceAt: Double?
            for try await frame in session.frames {
                guard let index = frame.utteranceIndex, (0..<2).contains(index) else {
                    print("POCKET_SESSION_FAILED: missing or unexpected utterance index")
                    return false
                }
                let elapsed = elapsed(since: enqueueBegan)
                if sessionFirst[index] == nil { sessionFirst[index] = elapsed }
                if index == 0 { lastFirstUtteranceAt = elapsed }
                sessionFrames[index] += 1
                if !sessionNonzero[index] {
                    sessionNonzero[index] = frame.samples.contains { abs($0) > 0.0001 }
                }
            }
            await session.cancel() // Must return after all CoreML predictions stop.
            guard let first = sessionFirst[0], let second = sessionFirst[1],
                  sessionFrames.allSatisfy({ $0 >= 3 }), sessionNonzero.allSatisfy({ $0 }),
                  let lastFirstUtteranceAt, second >= lastFirstUtteranceAt else {
                print("POCKET_SESSION_FAILED: native session lost a clause or crossed frame order")
                return false
            }
            let gap = second - lastFirstUtteranceAt
            print(String(format: "Pocket one-shot first PCM: %.3fs, %.3fs; frames: %d, %d",
                         oneShotFirst[0], oneShotFirst[1], oneShotFrames[0], oneShotFrames[1]))
            print(String(format: "Pocket model load plus real prediction warmup: %.3fs", readySeconds))
            print(String(format: "Pocket persistent voice prefill: %.3fs; first PCM after enqueue: %.3fs; second clause boundary gap: %.3fs; frames: %d, %d",
                         preparationSeconds, first, gap, sessionFrames[0], sessionFrames[1]))
            print("POCKET_SESSION_OK")
            return true
        } catch {
            print("POCKET_SESSION_FAILED: \(error.localizedDescription)")
            return false
        }
    }
}
