import Foundation

/// Authored producer controls; no model latency claim.
enum SmartTurnEndpointSelfTest {
    static func failures() async -> [String] {
        var failures = VoiceDecoderProgressSelfTest.failures()
        func expect(_ condition: Bool, _ name: String) { if !condition { failures.append(name) } }
        for quiet in [0.2, 0.4, 0.6, 0.9, 1.2, 1.5, 2.5] {
            expect(SmartTurnEndpointPolicy.decide(quiet: quiet, probability: 0.1,
                inferencePending: false, modelAvailable: true, transcriptReady: true,
                legacyEligible: true) == .wait, "incomplete pause \(quiet) committed")
        }
        expect(SmartTurnEndpointPolicy.decide(quiet: 0.2, probability: 0.8, inferencePending: false,
            modelAvailable: true, transcriptReady: true, legacyEligible: false) == .complete,
            "complete question waited for Parakeet EOU")
        expect(SmartTurnEndpointPolicy.decide(quiet: 0.9, probability: 0.8, inferencePending: false,
            modelAvailable: true, transcriptReady: false, legacyEligible: true) == .wait,
            "usable processed transcript was bypassed")
        expect(SmartTurnEndpointPolicy.decide(quiet: 0.19, probability: 0.8, inferencePending: false,
            modelAvailable: true, transcriptReady: true, legacyEligible: true) == .wait,
            "speech/pause boundary was bypassed")
        expect(SmartTurnEndpointPolicy.decide(quiet: 0.9, probability: nil, inferencePending: false,
            modelAvailable: false, transcriptReady: true, legacyEligible: true) == .fallback,
            "missing artifact disabled the existing fallback")
        expect(SmartTurnEndpointPolicy.decide(quiet: 0.9, probability: nil, inferencePending: true,
            modelAvailable: true, transcriptReady: true, legacyEligible: true) == .wait,
            "live inference was bypassed")
        expect(SmartTurnEndpointPolicy.decide(quiet: 5, probability: 0.1, inferencePending: false,
            modelAvailable: true, transcriptReady: true, legacyEligible: true) == .fallback,
            "incomplete maximum-quiet fallback was lost")
        let state = SmartTurnEndpoint(captureID: UUID(), epoch: 1,
            cachedOnly: true, skipModelForTesting: true)
        let decoder = VoiceDecoderProgress()
        let scope = decoder.invalidate(sessionID: state.captureID, epoch: 1)
        state.attachDecoder(decoder)
        let voice = [Float](repeating: 0.2, count: 8_000)
        voice.withUnsafeBufferPointer { _ = state.append($0, nearSpeech: true) }
        let first = state.evaluate(now: 1_000_000_000, usableText: true,
            transcriptStable: true, localText: true, legacyEligible: true)
        expect(state.stillCurrent(first.token), "fresh token lost authority")
        decoder.processed(through: 8_000, in: scope)
        let published = decoder.produced(in: scope)!
        _ = decoder.apply(published)
        [Float](repeating: 0, count: 41_600).withUnsafeBufferPointer {
            _ = state.append($0, nearSpeech: false)
        }
        let beforePending = state.evaluate(now: 1_050_000_000, usableText: true,
            transcriptStable: true, localText: true, legacyEligible: true)
        expect(beforePending.decoderStamp != nil, "covered fallback omitted its publication fence")
        _ = decoder.produced(in: scope) // Hold the actual consumer publication.
        let held = state.evaluate(now: 1_060_000_000, usableText: true,
            transcriptStable: true, localText: true, legacyEligible: true)
        expect(held.decision == .wait, "2.6s coverage fallback bypassed a known pending publication")
        expect(!state.stillCurrent(beforePending.token, decoderStamp: beforePending.decoderStamp),
               "pending native revision kept selected commit authority")
        voice.withUnsafeBufferPointer { _ = state.append($0, nearSpeech: true) }
        expect(!state.stillCurrent(first.token), "resumed speech retained stale completion authority")
        let second = state.evaluate(now: 1_100_000_000, usableText: true,
            transcriptStable: true, localText: true, legacyEligible: true)
        state.reset(epoch: 2)
        expect(!state.stillCurrent(second.token), "reset retained old turn authority")
        await state.close().value
        expect(!state.stillCurrent(second.token), "closed capture retained authority")
        let replay = SmartTurnEndpoint(captureID: UUID(), epoch: 1,
            cachedOnly: true, skipModelForTesting: true)
        let progress = VoiceDecoderProgress()
        let original = progress.invalidate(sessionID: replay.captureID, epoch: 1)
        voice.withUnsafeBufferPointer { _ = replay.append($0, nearSpeech: true, sequence: 1) }
        let selected = replay.evaluate(now: 2_000_000_000, usableText: true,
            transcriptStable: true, localText: true, legacyEligible: true)
        // Both chunks already finished on the retiring decoder before commit.
        for (sequence, value) in [(2, Float(0.01)), (3, Float(0.02))] {
            [Float](repeating: value, count: 160).withUnsafeBufferPointer {
                _ = replay.append($0, nearSpeech: false, sequence: sequence)
            }
        }
        progress.processed(through: 8_320, in: original)
        let revision = progress.produced(in: original)!
        _ = progress.apply(revision)
        var installed = 0
        let accepted = replay.claimCommit(selected.token, boundary: selected.endSample) { tail in
            expect(tail.samples == [Float](repeating: 0.01, count: 160)
                + [Float](repeating: 0.02, count: 160), "already-consumed successor PCM was lost")
            expect(tail.sequence == 3 && tail.endSample == 8_320, "replay clock/sequence changed")
            return progress.commit(ifPublished: revision, sessionID: replay.captureID,
                fromEpoch: 1, toEpoch: 2, through: selected.endSample) { installed += 1 }
        }
        expect(accepted && installed == 1, "atomic successor reset not installed once")
        progress.processed(through: 9_000, in: original)
        expect(progress.snapshot().processedEnd == 8_000, "retired decoder lent coverage to replay")
        let next = progress.snapshot().scope
        let firstRevision = progress.produced(in: next)!
        _ = progress.apply(firstRevision)
        _ = progress.produced(in: next)
        expect(!progress.commit(ifPublished: firstRevision, sessionID: replay.captureID,
            fromEpoch: 2, toEpoch: 3, through: 8_320) { installed += 1 },
            "pending native publication crossed atomic commit")
        expect(installed == 1 && progress.snapshot().scope == next, "rejected commit installed reset")
        [Float](repeating: 0, count: 96_001).withUnsafeBufferPointer {
            _ = replay.append($0, nearSpeech: false, sequence: 4)
        }
        expect(!replay.claimCommit(selected.token, boundary: selected.endSample) { _ in true },
            "oversized successor tail bypassed six-second ASR bound")
        await replay.close().value
        return failures
    }
}
