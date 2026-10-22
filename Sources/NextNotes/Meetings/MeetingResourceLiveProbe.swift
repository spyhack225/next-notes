import AVFoundation
import Foundation
import FluidAudio

/// Opt-in diagnostic in an isolated harness process. No downloads, cloud calls,
/// microphone, private speech or persisted choice changes. This measures actual
/// native loads/inference separately from the deterministic audio-bound fixture.
@MainActor
enum MeetingResourceLiveProbe {
    static func run(log: (String) -> Void) async -> Bool {
        guard SelfTest.isRunning && SelfTest.requested == "--selftest-meeting-resources-live" else {
            log("MEETING_RESOURCES_LIVE_FAILED: isolated diagnostic required")
            return false
        }
        // An isolated cached-model diagnostic must not purge or re-download a
        // model when native loading fails. Normal app loading is unchanged.
        let previousOffline = ModelHub.offlineMode
        if SelfTest.isRunning && SelfTest.requested == "--selftest-meeting-resources-live" {
            ModelHub.offlineMode = true
        }
        defer { ModelHub.offlineMode = previousOffline }
        if CommandLine.arguments.contains("--meeting-resource-offline-policy") {
            guard ModelHub.offlineMode else {
                log("MEETING_RESOURCES_LIVE_FAILED: cached diagnostic permits model repair/download")
                return false
            }
            do {
                _ = try await ModelHub.fetchWithAuth(from: URL(string: "https://example.invalid/native-probe")!)
                log("MEETING_RESOURCES_LIVE_FAILED: offline boundary admitted a fetch")
                return false
            } catch DownloadError.networkDisabled {
                log("MEETING_RESOURCES_LIVE_OK: SDK network boundary refused before model entry")
                return true
            } catch {
                log("MEETING_RESOURCES_LIVE_FAILED: offline boundary returned another error")
                return false
            }
        }
        if let arm = SelfTest.value(after: "--meeting-resource-normal") {
            return await MeetingResourceNormalComparison.run(arm: arm, log: log)
        }
        // The normal app startup installs this observer; harness startup skips
        // that work. Observe real pressure before any multi-second native load.
        ModelResidencyPolicy.installPressureObserver()
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
        let formerPrewarmEligible = Settings.shared.notesAutoGenerate
            && ModelRoleStore.shared.resolution(for: .meetingNotes).effective == .builtIn
            && InstalledModelLibrary.shared.hasUsableModel
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
            log("MEETING_RESOURCES_LIVE_CONFIG physical_memory_bytes=\(ProcessInfo.processInfo.physicalMemory) available_bytes=\(capacity) notes_file_bytes=\(modelBytes.map(String.init) ?? "unknown") former_prewarm_eligible_in_harness=\(formerPrewarmEligible) native_device_allocations=unavailable synthetic_audio=true")

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
                guard ModelResidencyPolicy.pressureSnapshot.allowsOptionalWork,
                      await !ParakeetModels.shared.isLoaded else { throw ProbeError.noAnswer }
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
                        let result = try await TranscriptionQueue.shared.transcribeWithLaneWait(samples)
                        await micCalls.complete()
                        return result
                    }, onSegment: { _ in })
                    let system = ChunkedTranscriber(source: .system, transcribe: { samples in
                        await systemCalls.enter()
                        let result = try await TranscriptionQueue.shared.transcribeWithLaneWait(samples)
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
                guard ModelResidencyPolicy.pressureSnapshot.allowsOptionalWork,
                      await !NotesModelRuntime.shared.isLoaded else { throw ProbeError.noAnswer }
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
            let releaseMilliseconds = try await measure("notes_pressure_release", log: log) {
                guard ModelResidencyPolicy.pressureSnapshot.allowsOptionalWork,
                      await NotesModelRuntime.shared.isLoaded else { throw ProbeError.noAnswer }
                let began = ContinuousClock.now
                // Inject the event into the real producer in this isolated process.
                // No OS pressure is created and no owner app state is touched.
                ModelResidencyGuardian.shared.receive(.warning)
                do {
                    let deadline = began.advanced(by: .seconds(5))
                    while await NotesModelRuntime.shared.isLoaded, ContinuousClock.now < deadline {
                        try await Task.sleep(for: .milliseconds(10))
                    }
                    guard await !NotesModelRuntime.shared.isLoaded,
                          !ModelResidencyPolicy.pressureSnapshot.allowsOptionalWork,
                          await ParakeetModels.shared.isLoaded else { throw ProbeError.noAnswer }
                    let admitted = await NotesModelRuntime.shared.prepareForOptionalUse()
                    guard !admitted, await !NotesModelRuntime.shared.isLoaded else { throw ProbeError.noAnswer }
                    // isLoaded observes the actual native owner after synchronous
                    // pointer teardown, not just a requested release or registry row.
                    ModelResidencyGuardian.shared.receive(.normal)
                    return Int(ChunkedTranscriber.seconds(began.duration(to: .now)) * 1_000)
                } catch {
                    _ = await NotesModelRuntime.shared.shutdown()
                    if await !NotesModelRuntime.shared.isLoaded {
                        ModelResidencyGuardian.shared.receive(.normal)
                    }
                    throw error
                }
            }
            log("MEETING_RESOURCES_LIVE_PRESSURE action_ms=\(releaseMilliseconds) injected_warning=true optional_reload_denied=true speech_model_retained=true")
            log("MEETING_RESOURCES_LIVE_OK: synthetic native measurement; physical capture and long-duration model overlap remain separate acceptance")
            return true
        } catch {
            _ = await NotesModelRuntime.shared.shutdown()
            log("MEETING_RESOURCES_LIVE_FAILED: native diagnostic did not complete")
            return false
        }
    }

    static func measure<T: Sendable>(
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
        func delta(_ before: UInt64?, _ after: UInt64?) -> String {
            guard let before, let after else { return "unknown" }
            return String(Int64(clamping: after) - Int64(clamping: before))
        }
        let asrLoaded = await ParakeetModels.shared.isLoaded
        let notesLoaded = await NotesModelRuntime.shared.isLoaded
        log("MEETING_RESOURCES_LIVE_STAGE stage=\(stage) wall_seconds=\(String(format: "%.3f", ChunkedTranscriber.seconds(began.duration(to: .now)))) cpu_seconds=\(String(format: "%.3f", cpu)) footprint_before=\(before.physicalFootprintBytes.map(String.init) ?? "unknown") footprint_after=\(after.physicalFootprintBytes.map(String.init) ?? "unknown") footprint_delta=\(delta(before.physicalFootprintBytes, after.physicalFootprintBytes)) sampled_peak_footprint=\(peak.map(String.init) ?? "unknown") rss_after=\(after.residentMemoryBytes.map(String.init) ?? "unknown") interrupt_wakeups_delta=\(delta(before.interruptWakeups, after.interruptWakeups)) platform_idle_wakeups_delta=\(delta(before.platformIdleWakeups, after.platformIdleWakeups)) native_asr_loaded=\(asrLoaded) native_notes_loaded=\(notesLoaded) runtime_registry=\(states)")
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
