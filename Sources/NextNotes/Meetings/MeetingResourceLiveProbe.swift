import AVFoundation
import Foundation

/// Opt-in diagnostic in an isolated harness process. No downloads, cloud calls,
/// microphone, private speech or persisted choice changes. This measures actual
/// native loads/inference separately from the deterministic audio-bound fixture.
@MainActor
enum MeetingResourceLiveProbe {
    static func run(log: (String) -> Void) async -> Bool {
        let fm = FileManager.default
        let root = fm.temporaryDirectory
        // Deliberately an optional result: unknown capacity must not authorize loads.
        let capacity = MeetingDiskCapacity.current(at: root).immediateBytes
        guard let capacity, capacity >= 8_000_000_000 else {
            log("MEETING_RESOURCES_LIVE_ABSENT: safe storage headroom unavailable; available_bytes=\(capacity.map(String.init) ?? "unknown")")
            return false
        }
        guard ParakeetModels.isDownloaded else {
            log("MEETING_RESOURCES_LIVE_ABSENT: installed speech model required; no download performed")
            return false
        }
        let spec = await NotesModelRuntime.shared.activeSpec()
        guard fm.fileExists(atPath: spec.fileURL.path) else {
            log("MEETING_RESOURCES_LIVE_ABSENT: selected local notes model unavailable; no download performed")
            return false
        }
        guard ModelResidencyPolicy.pressureSnapshot.allowsOptionalWork else {
            log("MEETING_RESOURCES_LIVE_ABSENT: memory pressure active")
            return false
        }
        let modelBytes = (try? fm.attributesOfItem(atPath: spec.fileURL.path)[.size] as? NSNumber)?.uint64Value
        let dir = root.appendingPathComponent("meeting-resource-live-\(UUID().uuidString)", isDirectory: true)
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            defer { try? fm.removeItem(at: dir) }
            log("MEETING_RESOURCES_LIVE_CONFIG physical_memory_bytes=\(ProcessInfo.processInfo.physicalMemory) available_bytes=\(capacity) notes_file_bytes=\(modelBytes.map(String.init) ?? "unknown") native_device_allocations=unavailable synthetic_audio=true")

            // Same twenty seconds/two tracks for each writer stage. No fake native
            // model is used in the ASR stages; transcript content is never printed.
            let packet = (0..<1_600).map { index in
                Float(sin(Double(index) * 2 * .pi * 180 / 16_000)) * 0.1
            }
            let baseline = try await measure("writer_only", log: log) {
                let writer = try MeetingAudioWriter(url: dir.appendingPathComponent("baseline.caf"))
                for index in 0..<200 {
                    await writer.append(packet, from: .mic, startFrame: index * 1_600)
                    await writer.append(packet, from: .system, startFrame: index * 1_600)
                }
                await writer.finish()
                return writer.resourceSnapshot().writtenFrames
            }
            guard baseline == 320_000 else { throw ProbeError.coverage }

            _ = try await measure("asr_cold_load", log: log) {
                try await TranscriptionQueue.shared.warmUp()
                guard await ParakeetModels.shared.isLoaded else { throw ProbeError.noAnswer }
                return 1
            }
            for stage in ["asr_first_inference", "asr_steady_inference"] {
                let frames = try await measure(stage, log: log) {
                    let url = dir.appendingPathComponent("\(stage).caf")
                    let writer = try MeetingAudioWriter(url: url)
                    let micCalls = NativeCallCounter()
                    let systemCalls = NativeCallCounter()
                    let mic = ChunkedTranscriber(source: .mic, transcribe: { samples in
                        await micCalls.enter()
                        let result = try await TranscriptionQueue.shared.transcribe(samples, lane: .realtimeASR)
                        await micCalls.complete()
                        return result
                    }, onSegment: { _ in })
                    let system = ChunkedTranscriber(source: .system, transcribe: { samples in
                        await systemCalls.enter()
                        let result = try await TranscriptionQueue.shared.transcribe(samples, lane: .realtimeASR)
                        await systemCalls.complete()
                        return result
                    }, onSegment: { _ in })
                    for index in 0..<200 {
                        await writer.append(packet, from: .mic, startFrame: index * 1_600)
                        await writer.append(packet, from: .system, startFrame: index * 1_600)
                        await mic.append(packet)
                        await system.append(packet)
                    }
                    await mic.flush()
                    await system.flush()
                    await writer.finish()
                    let micState = await mic.resourceSnapshot()
                    let systemState = await system.resourceSnapshot()
                    guard micState.droppedSeconds == 0 && systemState.droppedSeconds == 0 else {
                        throw ProbeError.coverage
                    }
                    guard await micCalls.allSucceeded, await systemCalls.allSucceeded else {
                        throw ProbeError.noAnswer
                    }
                    return writer.resourceSnapshot().writtenFrames
                }
                guard frames == 320_000 else { throw ProbeError.coverage }
            }
            // This is the removed speculative operation itself, allowing an equal-
            // process load delta to be measured without starting a real meeting.
            // It does not claim the total app footprint was caused by these weights.
            _ = try await measure("optional_notes_load_baseline", log: log) {
                try await NotesModelRuntime.shared.prepare()
                guard await NotesModelRuntime.shared.isLoaded else { throw ProbeError.noAnswer }
                return 1
            }
            _ = try await measure("notes_first_inference", log: log) {
                let result = try await NotesModelRuntime.shared.complete(
                    system: "Write a short factual meeting summary.",
                    user: "Synthetic test: the team agreed to review a design on Monday.", maxTokens: 32)
                guard !result.text.isEmpty else { throw ProbeError.noAnswer }
                return result.text.count
            }
            _ = try await measure("notes_release", log: log) {
                guard await NotesModelRuntime.shared.shutdown() else { throw ProbeError.noAnswer }
                guard await !NotesModelRuntime.shared.isLoaded else { throw ProbeError.noAnswer }
                return 1
            }
            log("MEETING_RESOURCES_LIVE_OK: synthetic native measurement; physical capture and long-duration model overlap remain separate acceptance")
            return true
        } catch {
            _ = await NotesModelRuntime.shared.shutdown()
            log("MEETING_RESOURCES_LIVE_FAILED: native diagnostic did not complete")
            return false
        }
    }

    private static func measure<T: Sendable>(
        _ stage: String,
        log: (String) -> Void,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let before = ProcessSnapshot.current()
        let began = ContinuousClock.now
        let sampler = FootprintSampler()
        let sampleTask = Task.detached(priority: .utility) {
            while !Task.isCancelled {
                await sampler.add(ProcessSnapshot.current())
                try? await Task.sleep(for: .milliseconds(20))
            }
        }
        defer { sampleTask.cancel() }
        let value = try await operation()
        sampleTask.cancel()
        await sampleTask.value
        let after = ProcessSnapshot.current()
        await sampler.add(before)
        await sampler.add(after)
        let peak = await sampler.peak
        let states = await ModelRuntimeManager.shared.snapshots()
            .map { "\($0.model.rawValue):\($0.state.rawValue)" }.joined(separator: ",")
        let cpu = (after.userCPUSeconds ?? 0) + (after.systemCPUSeconds ?? 0)
            - (before.userCPUSeconds ?? 0) - (before.systemCPUSeconds ?? 0)
        log("MEETING_RESOURCES_LIVE_STAGE stage=\(stage) wall_seconds=\(String(format: "%.3f", ChunkedTranscriber.seconds(began.duration(to: .now)))) cpu_seconds=\(String(format: "%.3f", cpu)) footprint_before=\(before.physicalFootprintBytes.map(String.init) ?? "unknown") footprint_after=\(after.physicalFootprintBytes.map(String.init) ?? "unknown") sampled_peak_footprint=\(peak.map(String.init) ?? "unknown") rss_after=\(after.residentMemoryBytes.map(String.init) ?? "unknown") runtime_registry=\(states)")
        return value
    }

    private actor FootprintSampler {
        private(set) var peak: UInt64?
        func add(_ snapshot: ProcessSnapshot) {
            if let value = snapshot.physicalFootprintBytes { peak = max(peak ?? 0, value) }
        }
    }

    /// ChunkedTranscriber intentionally keeps live capture going after a model
    /// error. This diagnostic must still fail if native inference did not finish.
    private actor NativeCallCounter {
        private var entered = 0
        private var completed = 0
        var allSucceeded: Bool { entered > 0 && entered == completed }
        func enter() { entered += 1 }
        func complete() { completed += 1 }
    }

    private enum ProbeError: Error { case coverage, noAnswer }
}
