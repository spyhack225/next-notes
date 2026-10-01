import AVFoundation
import FluidAudio
import Foundation

/// Generated packets, real writer/window producers, no capture grant or model.
/// Model footprint is a separate opt-in diagnostic; this flag proves audio bounds
/// and recovery admission without pretending that scripted models measure CoreML.
@MainActor
enum MeetingResourceSelfTest {
    static func run(log: (String) -> Void) async -> Bool {
        var failures: [String] = []
        func check(_ name: String, _ passed: Bool) {
            if !passed { failures.append(name) }
        }

        let stride = MemoryLayout<Float>.stride
        let rate = Int(ChunkedTranscriber.sampleRate)
        let bound = Int(ChunkedTranscriber.maxPendingAudioSeconds) * rate * stride
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent(
            "meeting-resource-fixture-\(UUID().uuidString)", isDirectory: true)
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            defer { try? fm.removeItem(at: dir) }

            // Ordinary timed packets reach the actual stereo file unchanged. Read
            // with the same channel reader used by the final pass/diarizer.
            let url = dir.appendingPathComponent("paired.caf")
            let writer = try MeetingAudioWriter(url: url)
            for index in 0..<200 {
                let mic = Float(index % 10 + 1) / 20
                let system = -mic
                await writer.append([Float](repeating: mic, count: 1_600), from: .mic,
                                    startFrame: index * 1_600)
                await writer.append([Float](repeating: system, count: 1_600), from: .system,
                                    startFrame: index * 1_600)
            }
            await writer.finish()
            let state = await writer.resourceSnapshot()
            let mic = try AudioConversion.samples(fromFileAt: url, sampleRate: Double(rate),
                                                  channel: MeetingAudioWriter.micChannel)
            let system = try AudioConversion.samples(fromFileAt: url, sampleRate: Double(rate),
                                                     channel: MeetingAudioWriter.systemChannel)
            check("writer saved every timed frame", state.writtenFrames == 320_000)
            check("final-pass reader receives both complete tracks", mic.count == 320_000 && system.count == 320_000)
            for index in 0..<200 where mic.count == 320_000 && system.count == 320_000 {
                let expected = Float(index % 10 + 1) / 20
                check("timed packet \(index) retains microphone/system sample values",
                      abs(mic[index * 1_600] - expected) < 0.0001
                      && abs(system[index * 1_600] + expected) < 0.0001)
            }
            let size = (try fm.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? 0
            check("stereo int16 disk growth", size >= state.writtenFrames * 4 && size < state.writtenFrames * 4 + 16_384)
            log("MEETING_RESOURCES_WRITER frames=\(state.writtenFrames) pcm_bytes=\(state.writtenFrames * 4) file_bytes=\(size) retained_capacity_bytes=\(state.queueCapacityBytes)")

            // Acceptance into the five-second pairing queue is not disk coverage.
            // Recovery authority also cannot return after any original on that
            // track was trimmed behind an already-saved silent channel.
            let coverageURL = dir.appendingPathComponent("coverage.caf")
            let coverage = try MeetingAudioWriter(url: coverageURL)
            let oneSecond = [Float](repeating: 0.1, count: rate)
            let onlyQueued = await coverage.append(oneSecond, from: .mic, startFrame: 0,
                                                   requireWritten: true)
            check("queued one-sided originals falsely authorized ASR shedding", !onlyQueued)
            let paired = await coverage.append(oneSecond, from: .system, startFrame: 0,
                                               requireWritten: true)
            check("written paired originals did not authorize recovery", paired)
            await coverage.append([Float](repeating: 0.1, count: 8 * rate), from: .mic)
            let advanced = await coverage.resourceSnapshot()
            check("late/trim fixture did not advance file cursor", advanced.writtenFrames >= 4 * rate)
            let trimmed = await coverage.append(oneSecond, from: .system,
                                                requireWritten: true)
            check("trimmed originals falsely authorized recovery behind file cursor", !trimmed)
            // Catch up past that cursor and save new originals. The missing older
            // system originals may still be in live ASR; this track stays unsafe.
            let later = await coverage.append([Float](repeating: 0.2, count: 7 * rate),
                                              from: .system, requireWritten: true)
            let writtenLater = await coverage.resourceSnapshot()
            check("catch-up packet was not actually written", writtenLater.writtenFrames >= 9 * rate)
            check("later successful saving erased missing-original recovery fact", !later)
            let safeMic = await coverage.append(oneSecond, from: .mic, requireWritten: true)
            check("only queued current mic originals authorized recovery", !safeMic)
            let cleanLater = await coverage.append(oneSecond, from: .system, requireWritten: true)
            let cleanState = await coverage.resourceSnapshot()
            check("later untrimmed originals were not actually written", cleanState.writtenFrames == 10 * rate)
            check("untrimmed successful packet erased prior source loss", !cleanLater)
            let emptyTrimmed = await coverage.append([], from: .system, requireWritten: true)
            check("empty packet erased permanently unsafe source", !emptyTrimmed)
            await coverage.finish()
            let finalCoverage = coverage.resourceSnapshot()
            check("source loss counts actual omitted originals once", finalCoverage.missingSavedMicFrames == 0
                  && finalCoverage.missingSavedSystemFrames == 3 * rate)
            let savedSystem = try AudioConversion.samples(fromFileAt: coverageURL, sampleRate: Double(rate),
                                                          channel: MeetingAudioWriter.systemChannel)
            let savedMic = try AudioConversion.samples(fromFileAt: coverageURL, sampleRate: Double(rate),
                                                       channel: MeetingAudioWriter.micChannel)
            check("trim fixture did not retain its exact saved timeline", savedSystem.count == 10 * rate && savedMic.count == 10 * rate)
            if savedSystem.count == 10 * rate && savedMic.count == 10 * rate {
                check("trimmed originals unexpectedly reached the final-pass reader",
                      savedSystem[rate..<4 * rate].allSatisfy { $0 == 0 })
                check("unaffected mic originals changed", savedMic.allSatisfy { abs($0 - 0.1) < 0.0001 })
                check("later saved system originals changed", savedSystem[4 * rate..<9 * rate].allSatisfy { abs($0 - 0.2) < 0.0001 }
                      && savedSystem[9 * rate..<10 * rate].allSatisfy { abs($0 - 0.1) < 0.0001 })
            }
            log("MEETING_RESOURCES_TRIM written_frames=\(finalCoverage.writtenFrames) missing_saved_mic_frames=\(finalCoverage.missingSavedMicFrames) missing_saved_system_frames=\(finalCoverage.missingSavedSystemFrames) actual_readback_frames=\(savedSystem.count)")

            // The real synchronous file boundary occupies the actor. Health must
            // still read its own producer progress instead of awaiting that actor.
            let writeGate = BlockingWriteGate()
            let heldURL = dir.appendingPathComponent("held-write.caf")
            let heldWriter = try MeetingAudioWriter(url: heldURL, write: { file, buffer in
                guard writeGate.holdFirst() else {
                    throw NSError(domain: NSPOSIXErrorDomain, code: Int(ETIMEDOUT))
                }
                try file.write(from: buffer)
            })
            let pendingWrite = Task.detached {
                await heldWriter.append([Float](repeating: 0.1, count: 6 * 16_000),
                                        from: .mic, startFrame: 0)
            }
            let deadline = ContinuousClock.now.advanced(by: .seconds(3))
            while !writeGate.entered, ContinuousClock.now < deadline {
                try? await Task.sleep(for: .milliseconds(1))
            }
            check("native write hold never entered", writeGate.entered)
            let snapshotBegan = ContinuousClock.now
            let heldProgress = heldWriter.resourceSnapshot() // deliberately no await
            let snapshotSeconds = ChunkedTranscriber.seconds(snapshotBegan.duration(to: .now))
            check("blocked writer hid in-flight progress", heldProgress.writeInFlight && heldProgress.writeStartedAt != nil && heldProgress.writtenFrames == 0)
            check("blocked writer delayed its health reader", snapshotSeconds < 0.1)
            let healthNow = Date()
            let heldHealth = MeetingResourceHealth.issues(.init(
                now: healthNow, beganAt: healthNow.addingTimeInterval(-MeetingResourceHealth.stallInterval - 1),
                disk: .init(immediateBytes: 10_000_000_000, importantBytes: 10_000_000_000),
                memoryIsTight: false, lastMicAt: healthNow, lastSystemAt: nil,
                expectsSystem: false, writerPresent: true, writerFailed: heldProgress.writeFailed,
                lastWriteProgressAt: nil))
            check("actual blocked write progress cannot produce saving-stalled warning", heldHealth.contains(.savingStalled))
            writeGate.release()
            check("released native write did not accept packet", await pendingWrite.value)
            let returnedProgress = heldWriter.resourceSnapshot()
            check("completed native write did not publish successful progress", !returnedProgress.writeInFlight && returnedProgress.writtenFrames == rate)
            await heldWriter.finish()
            let heldSamples = try AudioConversion.samples(fromFileAt: heldURL, sampleRate: Double(rate),
                                                         channel: MeetingAudioWriter.micChannel)
            check("held native write changed saved audio", heldSamples.count == 6 * rate
                  && abs((heldSamples.first ?? 0) - 0.1) < 0.0001
                  && abs((heldSamples.last ?? 0) - 0.1) < 0.0001)
            let finishedProgress = heldWriter.resourceSnapshot()
            let afterFinish = await heldWriter.append(oneSecond, from: .mic)
            check("finished writer accepted additional audio", !afterFinish)
            await heldWriter.finish()
            check("repeated finish changed saved frame progress", heldWriter.resourceSnapshot().writtenFrames == finishedProgress.writtenFrames)
            check("finish retained unused audio queue capacity", finishedProgress.queuedBytes == 0 && finishedProgress.queueCapacityBytes == 0)
            log("MEETING_RESOURCES_HELD_WRITE snapshot_seconds=\(String(format: "%.6f", snapshotSeconds)) actual_saved_samples=\(heldSamples.count)")

            // First ENOSPC closes the producer permanently. Retaining a one-sided
            // lead afterward was the original failure; later packets cannot save.
            let errors = ErrorCounter()
            let failed = try MeetingAudioWriter(
                url: dir.appendingPathComponent("rejected.caf"),
                onWriteError: { _ in errors.increment() },
                write: { _, _ in throw NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC)) })
            await failed.append([Float](repeating: 0.1, count: 6 * rate), from: .mic, startFrame: 0)
            let refused = await failed.resourceSnapshot()
            await failed.append([Float](repeating: 0.2, count: rate), from: .system)
            await failed.finish()
            let after = await failed.resourceSnapshot()
            check("write rejection is latched", refused.writeFailed && after.writeFailed)
            check("write rejection releases residual samples and capacity", refused.queuedBytes == 0 && refused.queueCapacityBytes == 0)
            check("failed writer never queues or retries", after.queuedBytes == 0 && after.queueCapacityBytes == 0 && after.writtenFrames == 0)
            check("failed writer reports exactly once", errors.value == 1)
            log("MEETING_RESOURCES_FAILED_WRITER retained_bytes=\(refused.queueCapacityBytes) callbacks=\(errors.value)")
        } catch {
            failures.append("actual writer fixture: \(error.localizedDescription)")
        }

        // A native call is held across pressure. Resume before it returns: no
        // second call may enter, no stale segment may publish, and Stop must join
        // the successor drain rather than just the invalidated one.
        let held = HeldModel()
        let output = OutputCollector()
        let deferred = ChunkedTranscriber(
            source: .system,
            transcribe: { await held.transcribe($0) },
            onSegment: { await output.add($0) })
        await deferred.append([Float](repeating: 0.1, count: 5 * rate))
        await held.waitUntilEntered()
        await deferred.append([Float](repeating: 0.1, count: 5 * rate))
        await deferred.deferForRecovery(throughSample: 15 * rate)
        await deferred.deferForRecovery(throughSample: 20 * rate)
        let paused = await deferred.resourceSnapshot()
        check("pressure clears waiting audio allocations", paused.queuedBytes == 0 && paused.bufferBytes == 0 && paused.queuedCapacityBytes == 0 && paused.bufferCapacityBytes == 0)
        check("active native input remains accounted until return", paused.activeBytes == 5 * rate * stride)
        check("repeated pressure counts each skipped sample once", paused.droppedSeconds == 20)
        await deferred.append([Float](repeating: 0.1, count: 2 * rate))
        let flushing = Task { await deferred.flush() }
        await held.release()
        await flushing.value
        let delivered = await output.segments
        let modelCalls = await held.calls
        let peakCalls = await held.peakConcurrentCalls
        check("resume retains one native owner", modelCalls == 2 && peakCalls == 1)
        check("stale active result is fenced and resumed origin is preserved",
              delivered.count == 1 && delivered.first?.start == 20 && delivered.first?.end == 22)
        let resumed = await deferred.resourceSnapshot()
        check("Stop joins resumed generation", resumed.activeBytes == 0 && resumed.queuedBytes == 0 && resumed.bufferBytes == 0)
        log("MEETING_RESOURCES_RECOVERY dropped_seconds=\(paused.droppedSeconds) calls=\(modelCalls) peak_concurrent_calls=\(peakCalls) resumed_segments=\(delivered.count)")

        // Two hours represented by small generated packets, never a whole-track
        // array. Verify ordered samples at the actual model seam and both logical
        // bytes and retained array capacity throughout the production windowing.
        let streaming = OrderedModel()
        let long = ChunkedTranscriber(
            source: .mic,
            transcribe: { await streaming.transcribe($0) },
            onSegment: { _ in })
        let streamingSystem = OrderedModel()
        let longSystem = ChunkedTranscriber(
            source: .system,
            transcribe: { await streamingSystem.transcribe($0) },
            onSegment: { _ in })
        var peakLogical = 0
        var peakCapacity = 0
        let began = ContinuousClock.now
        for packet in 0..<72_000 {
            let input = [Float](repeating: OrderedModel.value(packet), count: 1_600)
            await long.append(input)
            await longSystem.append(input)
            if packet % 100 == 0 {
                let sample = await long.resourceSnapshot()
                let systemSample = await longSystem.resourceSnapshot()
                peakLogical = max(peakLogical, sample.queuedBytes + sample.bufferBytes + sample.activeBytes
                                  + systemSample.queuedBytes + systemSample.bufferBytes + systemSample.activeBytes)
                peakCapacity = max(peakCapacity, sample.queuedCapacityBytes + sample.bufferCapacityBytes + sample.activeCapacityBytes
                                   + systemSample.queuedCapacityBytes + systemSample.bufferCapacityBytes + systemSample.activeCapacityBytes)
                check("both queued tracks respect sample bound", sample.queuedBytes <= bound && systemSample.queuedBytes <= bound)
            }
        }
        await long.flush()
        await longSystem.flush()
        let final = await long.resourceSnapshot()
        let finalSystem = await longSystem.resourceSnapshot()
        let ordered = await streaming.report
        let orderedSystem = await streamingSystem.report
        let elapsed = ChunkedTranscriber.seconds(began.duration(to: .now))
        check("two-hour model seam receives every packet in order", ordered.samples == 72_000 * 1_600 && ordered.wrong == 0
              && orderedSystem.samples == 72_000 * 1_600 && orderedSystem.wrong == 0)
        check("two-hour input loses no speech", final.droppedSeconds == 0 && finalSystem.droppedSeconds == 0)
        check("two-hour logical audio remains bounded", peakLogical <= 2 * (bound + 20 * rate * stride))
        check("two-hour retained array capacity remains bounded", peakCapacity <= 4 * (bound + 20 * rate * stride))
        log("MEETING_RESOURCES_TWO_HOURS tracks=2 input_samples=\(ordered.samples + orderedSystem.samples) wrong=\(ordered.wrong + orderedSystem.wrong) peak_logical_bytes=\(peakLogical) peak_capacity_bytes=\(peakCapacity) wall_seconds=\(String(format: "%.3f", elapsed))")

        for keep in [false, true] {
            for diarize in [false, true] {
                for finalPass in [false, true] {
                    check("audio policy matrix sufficient capacity",
                          MeetingSession.shouldWriteAudio(keep: keep, diarize: diarize, finalPass: finalPass,
                                                          freeBytes: 2_000_000_000) == (keep || diarize || finalPass))
                    check("audio policy matrix insufficient capacity",
                          !MeetingSession.shouldWriteAudio(keep: keep, diarize: diarize, finalPass: finalPass,
                                                           freeBytes: 999_999_999))
                }
            }
        }

        for failure in failures { log("MEETING_RESOURCES_WRONG: \(failure)") }
        log(failures.isEmpty ? "MEETING_RESOURCES_OK" : "MEETING_RESOURCES_FAILED: \(failures.count) check(s) wrong")
        return failures.isEmpty
    }

    private final class ErrorCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        func increment() { lock.lock(); count += 1; lock.unlock() }
        var value: Int { lock.lock(); defer { lock.unlock() }; return count }
    }

    private final class BlockingWriteGate: @unchecked Sendable {
        private let lock = NSLock()
        private let semaphore = DispatchSemaphore(value: 0)
        private var didEnter = false
        var entered: Bool { lock.lock(); defer { lock.unlock() }; return didEnter }
        func holdFirst() -> Bool {
            lock.lock()
            if didEnter { lock.unlock(); return true }
            didEnter = true
            lock.unlock()
            return semaphore.wait(timeout: .now() + 10) == .success
        }
        func release() { semaphore.signal() }
    }

    private actor HeldModel {
        private var gate: CheckedContinuation<Void, Never>?
        private var enteredWaiter: CheckedContinuation<Void, Never>?
        private var concurrent = 0
        private(set) var calls = 0
        private(set) var peakConcurrentCalls = 0
        func waitUntilEntered() async {
            if calls > 0 { return }
            await withCheckedContinuation { enteredWaiter = $0 }
        }
        func release() { gate?.resume(); gate = nil }
        func transcribe(_ samples: [Float]) async -> (result: ASRResult, laneWait: TimeInterval, compute: TimeInterval) {
            calls += 1
            concurrent += 1
            peakConcurrentCalls = max(peakConcurrentCalls, concurrent)
            if calls == 1 {
                enteredWaiter?.resume(); enteredWaiter = nil
                await withCheckedContinuation { gate = $0 }
            }
            concurrent -= 1
            return (ASRResult(text: "speech", confidence: 1,
                              duration: Double(samples.count) / 16_000,
                              processingTime: 0, tokenTimings: nil), 0, 0)
        }
    }

    private actor OutputCollector {
        private(set) var segments: [TranscriptSegment] = []
        func add(_ segment: TranscriptSegment) { segments.append(segment) }
    }

    private actor OrderedModel {
        private var samples = 0
        private var wrong = 0
        var report: (samples: Int, wrong: Int) { (samples, wrong) }
        nonisolated static func value(_ packet: Int) -> Float { 0.1 + Float(packet % 100) * 0.0001 }
        func transcribe(_ input: [Float]) -> (result: ASRResult, laneWait: TimeInterval, compute: TimeInterval) {
            for index in stride(from: 0, to: input.count, by: 1_600) {
                if input[index] != Self.value((samples + index) / 1_600) { wrong += 1 }
            }
            samples += input.count
            return (ASRResult(text: "", confidence: 1, duration: Double(input.count) / 16_000,
                              processingTime: 0, tokenTimings: nil), 0, 0)
        }
    }
}
