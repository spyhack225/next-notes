import AVFoundation
import Foundation

/// `--selftest-meeting-frame-shape`: the frame/clock contract of the system
/// frame row — cadence verdicts, format-shape stability, conversion outcomes,
/// yield accounting, and the writer's own coverage counters.
///
/// Pure over in-memory values except the last case, which runs a real writer
/// against a temporary file so the counters are checked on the path that
/// actually writes, not on a fixture of themselves. No model, no microphone,
/// no session, no owner store.
@MainActor
enum MeetingFrameShapeSelfTest {
    static func run(write: (String) -> Void) async -> Bool {
        var failures = 0
        var checks = 0
        func check(_ condition: Bool, _ label: String) {
            checks += 1
            if !condition {
                failures += 1
                write("FRAME_SHAPE_WRONG: \(label)")
            }
        }
        // Host-clock stamps for a synthetic timeline. The accumulator converts
        // through the mach timebase exactly as production does, so these are
        // the same kind of number a Core Audio callback hands in.
        func stamp(_ seconds: TimeInterval) -> UInt64 {
            AVAudioTime.hostTime(forSeconds: 10_000 + seconds)
        }
        let sig16k = MeetingFrameASBDSignature(
            sampleRate: 16_000, formatID: kAudioFormatLinearPCM,
            channelsPerFrame: 1, bytesPerFrame: 4, framesPerBuffer: 0,
            numberBuffers: 1)

        // MARK: Case a — one second of healthy 16 kHz deliveries reads ok.

        write("FRAME_SHAPE_CASE healthy-cadence")
        let healthy = MeetingFrameShapeAccumulator()
        healthy.recordCaptureStarted(stamp(0))
        for second in 0..<90 {
            healthy.recordDelivery(
                hostTime: stamp(TimeInterval(second)), samples: 16_000, signature: sig16k)
        }
        let healthyShape = healthy.snapshot(nowHostTime: stamp(90))
        check(healthyShape.verdict() == .ok, "one second of full-cadence deliveries over 90 seconds reads ok")
        check(abs(healthyShape.expectedSamplesFromElapsed - 1_440_000) <= 1,
              "expected samples from the elapsed window is 1440000")
        check(abs(healthyShape.clockDriftSamples) <= 1, "a healthy track's clock drift is zero")

        // A stream that ended while the meeting was recording stopped
        // delivering, whatever the counts say. Its own case, because it is not
        // a cadence question.
        let ended = MeetingFrameShapeAccumulator()
        ended.recordCaptureStarted(stamp(0))
        for second in 0..<90 {
            ended.recordDelivery(
                hostTime: stamp(TimeInterval(second)), samples: 16_000, signature: sig16k)
        }
        ended.recordTerminatedYield()
        ended.recordUnmatchedYield()
        let endedShape = ended.snapshot(nowHostTime: stamp(90))
        check(endedShape.verdict() == .stalled,
              "a stream that ended while recording reads stalled")
        check(endedShape.terminatedYields == 1 && endedShape.unmatchedYields == 1,
              "terminated and unmatched stream yields are each counted once")

        // MARK: Case b — half the samples the clock promised is the audit's live symptom.

        write("FRAME_SHAPE_CASE half-cadence")
        let half = MeetingFrameShapeAccumulator()
        half.recordCaptureStarted(stamp(0))
        for index in 0..<60 {
            half.recordDelivery(
                hostTime: stamp(TimeInterval(index) * 2), samples: 16_000, signature: sig16k)
        }
        let halfShape = half.snapshot(nowHostTime: stamp(120))
        check(halfShape.deliveredSamples == 960_000, "half cadence delivered 960000 samples in 120 seconds")
        check(halfShape.verdict() == .halfCadenceSuspect,
              "delivering half of what the wall clock says reads half-cadence, never ok")

        // MARK: Case c — a track that stops moving for the minimum window is stalled.

        write("FRAME_SHAPE_CASE stalled")
        let stalled = MeetingFrameShapeAccumulator()
        stalled.recordCaptureStarted(stamp(0))
        for second in 0..<5 {
            stalled.recordDelivery(
                hostTime: stamp(TimeInterval(second)), samples: 16_000, signature: sig16k)
        }
        check(stalled.snapshot(nowHostTime: stamp(300)).verdict() == .stalled,
              "a track silent for longer than the minimum window reads stalled")
        let startedOnly = MeetingFrameShapeAccumulator()
        startedOnly.recordCaptureStarted(stamp(0))
        check(startedOnly.snapshot(nowHostTime: stamp(120)).verdict() == .stalled,
              "capture that started long ago and delivered nothing reads stalled")
        check(startedOnly.snapshot(nowHostTime: stamp(30)).verdict() == .unknownShape,
              "capture that started recently and delivered nothing reads unknown, never stalled and never ok")

        // MARK: Case d — the buffer-list shape, and a format switch mid-recording.

        write("FRAME_SHAPE_CASE buffer-shape")
        if let interleavedStereo = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: true),
            let splitStereo = AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: false) {
            let interleaved = MeetingFrameASBDSignature(interleavedStereo, numberBuffers: 1)
            let split = MeetingFrameASBDSignature(splitStereo, numberBuffers: 2)
            check(interleaved.bytesPerFrame == 8 && interleaved.numberBuffers == 1,
                  "float32 stereo interleaved is one buffer of eight bytes per frame")
            check(split.bytesPerFrame == 4 && split.numberBuffers == 2,
                  "float32 stereo split is two buffers of four bytes per frame")
            check(interleaved.layoutChanged(from: split),
                  "interleaved against split is a layout change")
            check(!interleaved.layoutChanged(from: MeetingFrameASBDSignature(interleavedStereo, numberBuffers: 1)),
                  "an identical shape is not a layout change")

            let stable = MeetingFrameShapeAccumulator()
            stable.recordCaptureStarted(stamp(0))
            for second in 0..<71 {
                stable.recordBuffer(
                    hostTime: stamp(TimeInterval(second)), signature: split,
                    inputSamples: 48_000, convertedSamples: 16_000, outcome: .success)
            }
            let stableShape = stable.snapshot(nowHostTime: stamp(71))
            check(stableShape.signatureTransitions == 0, "a stable format records no transitions")
            check(stableShape.verdict() == .ok,
                  "48 kHz input converted at full 16 kHz cadence reads ok")

            let switching = MeetingFrameShapeAccumulator()
            switching.recordCaptureStarted(stamp(0))
            for second in 0..<30 {
                switching.recordBuffer(
                    hostTime: stamp(TimeInterval(second)), signature: split,
                    inputSamples: 48_000, convertedSamples: 16_000, outcome: .success)
            }
            for second in 30..<70 {
                switching.recordBuffer(
                    hostTime: stamp(TimeInterval(second)), signature: interleaved,
                    inputSamples: 48_000, convertedSamples: 16_000, outcome: .success)
            }
            let switchedShape = switching.snapshot(nowHostTime: stamp(70))
            check(switchedShape.signatureTransitions == 1,
                  "a mid-recording format switch counts one transition")
            check(switchedShape.verdict() == .unknownShape,
                  "an unstable format can never read ok")
        } else {
            check(false, "stereo float32 AVAudioFormat fixtures could not be built")
        }

        let noShape = MeetingFrameShapeAccumulator()
        noShape.recordCaptureStarted(stamp(0))
        for second in 0..<70 {
            noShape.recordDelivery(
                hostTime: stamp(TimeInterval(second)), samples: 16_000, signature: nil)
        }
        let noShapeSnapshot = noShape.snapshot(nowHostTime: stamp(70))
        check(noShapeSnapshot.asbdSignature == nil, "deliveries without a shape leave the shape unknown")
        check(noShapeSnapshot.verdict() == .unknownShape,
              "a track whose shape was never seen is never ok")

        // MARK: Case e — the verdict tracks the converted rate, not the input rate.

        write("FRAME_SHAPE_CASE rate-independence")
        let lowRate = MeetingFrameShapeAccumulator()
        lowRate.recordCaptureStarted(stamp(0))
        let sig44k = MeetingFrameASBDSignature(
            sampleRate: 44_100, formatID: kAudioFormatLinearPCM,
            channelsPerFrame: 1, bytesPerFrame: 4, framesPerBuffer: 0,
            numberBuffers: 1)
        for second in 0..<71 {
            lowRate.recordBuffer(
                hostTime: stamp(TimeInterval(second)), signature: sig44k,
                inputSamples: 44_100, convertedSamples: 16_000, outcome: .success)
        }
        let lowRateShape = lowRate.snapshot(nowHostTime: stamp(71))
        check(lowRateShape.verdict() == .ok,
              "44.1 kHz input converted at full 16 kHz cadence reads ok")
        check(abs(lowRateShape.clockDriftSamples) <= lowRateShape.expectedSamplesFromElapsed / 100,
              "converted samples track the clock within one percent")

        let crossRate = MeetingFrameShapeAccumulator()
        crossRate.recordCaptureStarted(stamp(0))
        for second in 0..<30 {
            crossRate.recordBuffer(
                hostTime: stamp(TimeInterval(second)), signature: sig44k,
                inputSamples: 44_100, convertedSamples: 16_000, outcome: .success)
        }
        for second in 30..<70 {
            crossRate.recordBuffer(
                hostTime: stamp(TimeInterval(second)), signature: sig16k,
                inputSamples: 16_000, convertedSamples: 16_000, outcome: .success)
        }
        check(crossRate.snapshot(nowHostTime: stamp(70)).verdict() == .unknownShape,
              "a rate change mid-recording reads unknown")

        // MARK: Case f — conversion outcomes outrank cadence, but only when they dominate.

        write("FRAME_SHAPE_CASE converter-outcomes")
        let failing = MeetingFrameShapeAccumulator()
        failing.recordCaptureStarted(stamp(0))
        for second in 0..<71 {
            failing.recordBuffer(
                hostTime: stamp(TimeInterval(second)), signature: sig16k,
                inputSamples: 16_000, convertedSamples: 0, outcome: .error)
        }
        let failingShape = failing.snapshot(nowHostTime: stamp(71))
        check(failingShape.converterStatusCounts.errorsDominate,
              "a converter failing every buffer dominates its outcomes")
        check(failingShape.verdict() == .stalled,
              "a converter failing every buffer reads stalled before cadence, never ok")

        let mixed = MeetingFrameShapeAccumulator()
        mixed.recordCaptureStarted(stamp(0))
        for second in 0..<70 {
            mixed.recordBuffer(
                hostTime: stamp(TimeInterval(second)), signature: sig16k,
                inputSamples: 16_000, convertedSamples: 16_000, outcome: .success)
        }
        mixed.recordBuffer(
            hostTime: stamp(70), signature: sig16k,
            inputSamples: 16_000, convertedSamples: 0, outcome: .error)
        mixed.recordBuffer(
            hostTime: stamp(71), signature: sig16k,
            inputSamples: 16_000, convertedSamples: 0, outcome: .error)
        let mixedShape = mixed.snapshot(nowHostTime: stamp(72))
        check(!mixedShape.converterStatusCounts.errorsDominate,
              "two errors among seventy successes do not dominate")
        check(mixedShape.verdict() == .ok,
              "a couple of failed buffers inside a healthy window still reads ok")

        // MARK: Case g — the real writer's coverage counters, on a real file.

        write("FRAME_SHAPE_CASE writer-coverage")
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingFrameShapeSelfTest-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            check(true, "the writer case's temporary directory was created")
        } catch {
            check(false, "the writer case's temporary directory was created (threw \(error))")
        }
        defer { try? FileManager.default.removeItem(at: directory) }

        do {
            let writer = try MeetingAudioWriter(url: directory.appendingPathComponent("a.caf"))
            await writer.append([Float](repeating: 0, count: 80_000), from: .mic, startFrame: 0)
            await writer.append([Float](repeating: 0, count: 160_000), from: .mic)
            await writer.append([Float](repeating: 0, count: 16_000), from: .system, startFrame: 0)
            await writer.finish()
            let snapshot = writer.resourceSnapshot()
            check(snapshot.micRealQueuedFrames == 240_000,
                  "writer A accepted every microphone frame it was offered")
            check(snapshot.systemRealQueuedFrames == 0,
                  "writer A placed no system frame — the trim consumed all of it")
            check(snapshot.leadFillSystemFrames == 160_000,
                  "writer A filled 160000 system frames when the pairing bound released")
            check(snapshot.silenceFilledSystemFrames == 240_000,
                  "writer A's system channel carries silence end to end")
            check(snapshot.silenceFilledMicFrames == 0,
                  "writer A's microphone channel never needed invented silence")
            check(snapshot.missingSavedSystemFrames == 16_000,
                  "writer A trimmed the wholly-behind system packet once")
            check(snapshot.writtenFrames == 240_000,
                  "writer A wrote 240000 paired frames")
            check(snapshot.systemSilentAfterSample == 0,
                  "writer A's system channel never carried real audio, so it is silent from the first frame")
            check(snapshot.micSilentAfterSample == nil,
                  "writer A's microphone carried real audio to the end, so it has no boundary")
        } catch {
            check(false, "writer A ran (threw \(error))")
        }

        do {
            let writer = try MeetingAudioWriter(url: directory.appendingPathComponent("b.caf"))
            await writer.append([Float](repeating: 0, count: 96_000), from: .mic)
            await writer.append([Float](repeating: 0, count: 16_000), from: .system, startFrame: 16_000)
            await writer.finish()
            let snapshot = writer.resourceSnapshot()
            check(snapshot.micRealQueuedFrames == 96_000,
                  "writer B accepted every microphone frame it was offered")
            check(snapshot.systemRealQueuedFrames == 16_000,
                  "writer B placed the system packet exactly on its clock offset")
            check(snapshot.leadFillSystemFrames == 16_000,
                  "writer B's lead fill is only the pairing bound's release")
            check(snapshot.silenceFilledSystemFrames == 80_000,
                  "writer B's system silence is the lead fill plus the closing tail")
            check(snapshot.missingSavedSystemFrames == 0,
                  "writer B trimmed nothing — the system packet aligned exactly")
            check(snapshot.writtenFrames == 96_000,
                  "writer B wrote 96000 paired frames")
            check(snapshot.micSilentAfterSample == nil,
                  "writer B's microphone carried real audio to the end, so it has no boundary")
            check(snapshot.systemSilentAfterSample != nil,
                  "writer B's system channel stopped carrying real audio, so it has a boundary")
        } catch {
            check(false, "writer B ran (threw \(error))")
        }

        if failures == 0 {
            write("FRAME_SHAPE_OK: \(checks) checks")
            return true
        } else {
            write("FRAME_SHAPE_FAILED: \(failures) of \(checks) checks wrong")
            return false
        }
    }
}
