import AVFoundation
import FluidAudio
import Foundation

/// `--selftest-meeting-tap-retry` (M-09): the system-audio tap is retried while a
/// meeting records, instead of the one 5 s start attempt that used to leave the meeting
/// mic-only for its whole length (I2 #10).
///
/// A `MeetingSession` is driven through the same track wiring and tap start `start()`
/// runs, with the capture injected through `SystemAudioCapture.startCallOverrideForTesting`
/// and the transcriber model call through `MeetingSession`'s own test seam — no
/// microphone, no real tap, no Parakeet, and every meeting lives in
/// `MeetingStore.isolated()`. Three phases:
///
/// 1. *Join* — the injected start throws twice and then succeeds on a 0.2 s cadence:
///    the problem clears, and the system track's first segment carries the first
///    captured buffer's time, rather than a retry attempt's earlier start time.
/// 2. *Exhaustion* — a tap that never joins gives up after ten attempts and stays
///    stopped without anyone stopping the meeting.
/// 3. *Stop* — `stop()` cancels a live retry; no start is attempted afterwards. The
///    full post-Stop hand-off (diarize → notes → agent review) is exercised elsewhere;
///    this phase's transcript is empty, so the pipeline finishes without a model.
///
/// The retry cannot detect a missing grant — a tap without one returns silence, not an
/// error — so it answers start errors and timeouts only, and this test never asks it to
/// do more.
@MainActor
enum MeetingTapRetrySelfTest {
    static func run(log: (String) -> Void) async -> Bool {
        var failures: [String] = []
        func check(_ name: String, _ condition: Bool) {
            if !condition { failures.append(name) }
        }

        let store = MeetingStore.isolated()
        let fake = FakeTap()

        // The seams under test. Restored whichever way the run ends.
        let previousStart = SystemAudioCapture.startCallOverrideForTesting
        let previousTranscribe = MeetingSession.transcribeOverrideForTesting
        let previousPermission = MeetingSession.microphonePermissionOverrideForTesting
        SystemAudioCapture.startCallOverrideForTesting = { format, onBuffer, onLevel in
            try await fake.start(outputFormat: format, onBuffer: onBuffer, onLevel: onLevel)
        }
        MeetingSession.transcribeOverrideForTesting = { [fake] samples in
            try await fake.transcribe(samples)
        }
        defer {
            SystemAudioCapture.startCallOverrideForTesting = previousStart
            MeetingSession.transcribeOverrideForTesting = previousTranscribe
            MeetingSession.microphonePermissionOverrideForTesting = previousPermission
        }

        // Stop while start() is suspended at the permission prompt. A late grant
        // must not subscribe the microphone or leave a finished empty meeting.
        let permissionGate = MeetingPermissionGate()
        MeetingSession.microphonePermissionOverrideForTesting = { await permissionGate.wait() }
        let pendingMeeting = Meeting(title: "Cancelled before capture", start: Date(), status: .scheduled)
        let pendingController = MeetingController(store: store)
        let pendingStart = Task { await pendingController.start(meeting: pendingMeeting) }
        while !permissionGate.entered { await Task.yield() }
        await pendingController.stop()
        permissionGate.release()
        let startedAfterStop = await pendingStart.value
        check("a late permission grant restarted a stopped meeting", !startedAfterStop)
        check("stopped pending start still owns the controller slot", pendingController.session == nil)
        check("stopped pending start persisted an empty meeting", store.meeting(id: pendingMeeting.id) == nil)
        MeetingSession.microphonePermissionOverrideForTesting = previousPermission

        // --- Phase 1: two failures, then a join on the 0.2 s cadence.
        await fake.configure(succeedOnCall: 3)
        let joinMeeting = Meeting(title: "Tap retry join", start: Date(), status: .scheduled)
        let session = MeetingSession(meeting: joinMeeting, store: store)
        session.setTapRetryIntervalForTesting(.milliseconds(200))
        let began = Date()
        do {
            try await session.startTapForTesting()
        } catch {
            check("the tap-start seam threw: \(error.localizedDescription)", false)
        }

        var joined = false
        var joinElapsed: TimeInterval = 0
        while Date().timeIntervalSince(began) < 3 {
            if session.systemAudioProblem == nil {
                joined = true
                joinElapsed = Date().timeIntervalSince(began)
                break
            }
            try? await Task.sleep(for: .milliseconds(25))
        }
        check("the problem never cleared — no retry ran", joined)
        log(String(
            format: "MEETING_TAP_RETRY_JOINED=%.2fs CALLS=%d",
            joinElapsed, await fake.calls))

        // The late track must sit at the first captured buffer, not at zero or the
        // time the retry began. The fake delivers buffers before start() returns, so
        // the problem-clear time is later than the actual join on a busy machine.
        var firstSystem: TranscriptSegment?
        while Date().timeIntervalSince(began) < 6 {
            firstSystem = session.segments.first { $0.source == .system }
            if firstSystem != nil { break }
            try? await Task.sleep(for: .milliseconds(50))
        }
        check("no system segment arrived from the late tap", firstSystem != nil)
        let firstBufferAt = await fake.firstBufferAt
        check("the fake tap delivered no first buffer", firstBufferAt != nil)
        if let segment = firstSystem {
            let captureElapsed = firstBufferAt?.timeIntervalSince(began) ?? joinElapsed
            check(
                String(
                    format: "first system segment starts at %.2fs but capture began at %.2fs — origin not placed",
                    segment.start, captureElapsed),
                segment.start >= captureElapsed - 0.1 && segment.start <= captureElapsed + 0.3)
        }

        // Success ends the loop: no further attempts after the join.
        try? await Task.sleep(for: .milliseconds(900))
        let callsAfterJoin = await fake.calls
        check("the retry kept starting after the join (\(callsAfterJoin) calls, expected 3)",
              callsAfterJoin == 3)
        session.endAbruptly()

        // --- Phase 2: a tap that never joins gives up after ten attempts, alone.
        await fake.configure(succeedOnCall: nil)
        let exhaustedMeeting = Meeting(title: "Tap retry exhaustion", start: Date(), status: .scheduled)
        let exhausted = MeetingSession(meeting: exhaustedMeeting, store: store)
        exhausted.setTapRetryIntervalForTesting(.milliseconds(200))
        let exhaustionBegan = Date()
        do {
            try await exhausted.startTapForTesting()
        } catch {
            check("the exhaustion tap-start threw: \(error.localizedDescription)", false)
        }
        var reachedLimit = false
        while Date().timeIntervalSince(exhaustionBegan) < 5 {
            if await fake.calls >= 11 {
                reachedLimit = true
                break
            }
            try? await Task.sleep(for: .milliseconds(25))
        }
        check("the retry never reached its 10 attempts (\(await fake.calls) calls)", reachedLimit)
        let exhaustedCalls = await fake.calls
        try? await Task.sleep(for: .milliseconds(600))
        check("the retry kept going after giving up (\(exhaustedCalls) → \(await fake.calls) calls)",
              await fake.calls == exhaustedCalls)
        exhausted.endAbruptly()

        // --- Phase 3: stop() cancels a live retry; nothing starts afterwards.
        await fake.configure(succeedOnCall: nil)
        let stoppedMeeting = Meeting(title: "Tap retry stop", start: Date(), status: .scheduled)
        let stopped = MeetingSession(meeting: stoppedMeeting, store: store)
        stopped.setTapRetryIntervalForTesting(.milliseconds(200))
        let stopBegan = Date()
        do {
            try await stopped.startTapForTesting()
        } catch {
            check("the stop-phase tap-start threw: \(error.localizedDescription)", false)
        }
        var retryLive = false
        while Date().timeIntervalSince(stopBegan) < 2 {
            if await fake.calls >= 3 {
                retryLive = true
                break
            }
            try? await Task.sleep(for: .milliseconds(25))
        }
        check("no retry was live when stop arrived (\(await fake.calls) calls)", retryLive)
        await stopped.stop()
        let atStop = await fake.calls
        try? await Task.sleep(for: .milliseconds(400))
        let settled = await fake.calls
        check("an attempt raced the stop (\(atStop) → \(settled) calls)", settled <= atStop + 1)
        try? await Task.sleep(for: .milliseconds(1000))
        check("the retry fired after stop() (\(settled) → \(await fake.calls) calls)",
              await fake.calls == settled)

        for failure in failures {
            log("MEETING_TAP_RETRY_WRONG: \(failure)")
        }
        log(failures.isEmpty
            ? "MEETING_TAP_RETRY_OK: joined late, placed at first capture, gave up and stopped cleanly"
            : "MEETING_TAP_RETRY_FAILED: \(failures.count) check(s) wrong")
        return failures.isEmpty
    }
}

@MainActor
private final class MeetingPermissionGate {
    private var continuation: CheckedContinuation<Bool, Never>?
    private(set) var entered = false

    func wait() async -> Bool {
        entered = true
        return await withCheckedContinuation { continuation = $0 }
    }

    func release() {
        continuation?.resume(returning: true)
        continuation = nil
    }
}

// MARK: - Fakes

/// The injected capture: throws until `succeedOnCall`, then joins and yields 6 s of
/// 0.1-RMS noise in 0.1 s buffers — the way the real tap's IOProc would have delivered
/// the other half of the conversation from the moment it started.
private actor FakeTap {
    private(set) var calls = 0
    private(set) var firstBufferAt: Date?
    private var succeedOnCall: Int?
    private var noise: [Float] = []

    func configure(succeedOnCall: Int?) {
        self.succeedOnCall = succeedOnCall
        // Each phase counts its own attempts: 1 initial + the retries it watches.
        calls = 0
        firstBufferAt = nil
        if noise.isEmpty { noise = Self.syntheticNoise(seconds: 6) }
    }

    func start(
        outputFormat: AVAudioFormat,
        onBuffer: @Sendable (AudioChunk) -> Void,
        onLevel: @Sendable (Float) -> Void
    ) async throws {
        calls += 1
        guard let succeedOnCall, calls >= succeedOnCall else {
            throw SystemAudioError.deviceStartTimedOut
        }
        let chunk = Int(0.1 * ChunkedTranscriber.sampleRate)
        var index = 0
        while index < noise.count {
            let end = min(index + chunk, noise.count)
            if let buffer = Self.buffer(Array(noise[index..<end]), format: outputFormat) {
                if firstBufferAt == nil { firstBufferAt = Date() }
                onBuffer(AudioChunk(buffer: buffer))
                onLevel(0.1)
            }
            index = end
        }
    }

    /// The injected model call: text without token timings, so the window falls back to
    /// one segment spanning it — the segment whose start carries the placed origin.
    func transcribe(_ samples: [Float]) async throws -> (
        result: ASRResult, laneWait: TimeInterval, compute: TimeInterval
    ) {
        let duration = Double(samples.count) / ChunkedTranscriber.sampleRate
        return (
            result: ASRResult(
                text: "probe window", confidence: 1, duration: duration,
                processingTime: 0, tokenTimings: nil),
            laneWait: 0, compute: 0
        )
    }

    /// Uniform draw in ±a has RMS a/√3; a = 0.1√3 is the 0.1 the roadmap asks for.
    private static func syntheticNoise(seconds: Double) -> [Float] {
        let total = Int(seconds * ChunkedTranscriber.sampleRate)
        var samples = [Float](repeating: 0, count: total)
        let amplitude = Float(0.1 * 3.0.squareRoot())
        var state: UInt64 = 0x5EED_1234_9876_ABCD
        for slot in 0..<total {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            let unit = Double(state >> 11) / Double(1 << 53)
            samples[slot] = Float(unit * 2 - 1) * amplitude
        }
        return samples
    }

    private static func buffer(_ samples: [Float], format: AVAudioFormat) -> AVAudioPCMBuffer? {
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(samples.count)
        ), let channel = buffer.floatChannelData?[0] else { return nil }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        for (index, sample) in samples.enumerated() {
            channel[index] = sample
        }
        return buffer
    }
}
