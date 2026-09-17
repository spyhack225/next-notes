import AVFoundation
import Foundation

/// Hybrid hardware gate: a real output speaker and microphone supply the far
/// echo, while a known spoken WAV is injected into the captured mic buffer
/// before AEC. This measures preservation and onset against a known near
/// waveform; it is not a test of a human speaking in the room.
@MainActor
enum AcousticHybridProbe {
    private enum Phase: Equatable { case room, calibrationA, calibrationB, waiting, passA, passB }
    private enum CaseID: Int, CaseIterable {
        case calibrationEarlyQuiet, calibrationWarmStrong
        case calibrationEarlyStrong, calibrationWarmQuiet
        case earlyQuiet, warmStrong, earlyStrong, warmQuiet

        var label: String {
            switch self {
            case .calibrationEarlyQuiet: "calibrationEarlyQuiet"
            case .calibrationWarmStrong: "calibrationWarmStrong"
            case .calibrationEarlyStrong: "calibrationEarlyStrong"
            case .calibrationWarmQuiet: "calibrationWarmQuiet"
            case .earlyQuiet: "earlyQuiet"
            case .warmStrong: "warmStrong"
            case .earlyStrong: "earlyStrong"
            case .warmQuiet: "warmQuiet"
            }
        }
        var targetRMS: Double {
            switch self {
            case .calibrationEarlyQuiet, .calibrationWarmQuiet, .earlyQuiet, .warmQuiet: 0.02
            default: 0.10
            }
        }
        var startsAt: Int {
            switch self {
            case .calibrationEarlyQuiet, .calibrationEarlyStrong, .earlyQuiet, .earlyStrong: 1_600
            case .calibrationWarmQuiet, .calibrationWarmStrong, .warmQuiet, .warmStrong: 24_000
            }
        }
    }

    private struct Samples {
        var known: [Float] = []
        var raw: [Float] = []
        var clean: [Float] = []
        var candidateChunks = 0
        var firstCandidateSeconds: Double?
    }

    private final class State: @unchecked Sendable {
        private let lock = NSLock()
        private let near: [Float]
        private let nearRMS: Double
        private var phase: Phase = .room
        private var frame = 0
        private var cases: [CaseID: Samples] = [:]
        private var roomSquares = 0.0
        private var roomFrames = 0
        private var passFarSquares: [PhaseKey: Double] = [:]
        private var passFarFrames: [PhaseKey: Int] = [:]

        private enum PhaseKey: Hashable { case a, b }

        init(near: [Float]) {
            self.near = near
            nearRMS = sqrt(near.reduce(0.0) { $0 + Double($1 * $1) }
                           / Double(max(near.count, 1)))
        }

        func set(_ next: Phase) {
            lock.lock()
            phase = next
            frame = 0
            lock.unlock()
        }

        private func caseFor(_ phase: Phase, frame: Int) -> CaseID? {
            let choices: [CaseID]
            switch phase {
            case .calibrationA: choices = [.calibrationEarlyQuiet, .calibrationWarmStrong]
            case .calibrationB: choices = [.calibrationEarlyStrong, .calibrationWarmQuiet]
            case .passA: choices = [.earlyQuiet, .warmStrong]
            case .passB: choices = [.earlyStrong, .warmQuiet]
            default: return nil
            }
            return choices.first { frame >= $0.startsAt && frame < $0.startsAt + near.count }
        }

        func process(_ chunk: AudioChunk) {
            guard let mixed = AudioConversion.copy(chunk.buffer),
                  let raw = mixed.floatChannelData?[0] else { return }
            let count = Int(mixed.frameLength)
            guard count > 0 else { return }
            var ids = [CaseID?](repeating: nil, count: count)
            var injected = [Float](repeating: 0, count: count)
            var initialFrame = 0
            var currentPhase: Phase = .room
            lock.lock()
            initialFrame = frame
            currentPhase = phase
            for index in 0..<count {
                let position = frame + index
                guard let id = caseFor(phase, frame: position) else { continue }
                let sampleIndex = position - id.startsAt
                let scale = Float(id.targetRMS / max(nearRMS, 1e-8))
                let value = near[sampleIndex] * scale
                raw[index] = max(-0.98, min(0.98, raw[index] + value))
                ids[index] = id
                injected[index] = value
            }
            frame += count
            lock.unlock()

            let cleaned = AcousticEchoProcessor.shared.process(AudioChunk(buffer: mixed,
                captureHostTime: chunk.captureHostTime))
            let evidence = AcousticEchoProcessor.shared.evidenceSnapshot()
            guard let output = cleaned.buffer.floatChannelData?[0] else { return }
            lock.lock()
            var touched: Set<CaseID> = []
            for index in 0..<min(count, Int(cleaned.buffer.frameLength)) {
                if let id = ids[index] {
                    var sample = cases[id] ?? Samples()
                    sample.known.append(injected[index])
                    sample.raw.append(raw[index])
                    sample.clean.append(output[index])
                    cases[id] = sample
                    touched.insert(id)
                } else if currentPhase == .room {
                    roomSquares += Double(raw[index] * raw[index])
                    roomFrames += 1
                } else if currentPhase == .passA || currentPhase == .passB {
                    let key: PhaseKey = currentPhase == .passA ? .a : .b
                    passFarSquares[key, default: 0] += Double(raw[index] * raw[index])
                    passFarFrames[key, default: 0] += 1
                }
            }
            if evidence.independentNearCandidate {
                for id in touched {
                    var sample = cases[id] ?? Samples()
                    sample.candidateChunks += 1
                    if sample.firstCandidateSeconds == nil {
                        // Evidence describes the processed buffer, so the
                        // receipt belongs to its end, not its first sample.
                        let onset = max(0, initialFrame + count - id.startsAt)
                        sample.firstCandidateSeconds = Double(onset) / 16_000
                    }
                    cases[id] = sample
                }
            }
            lock.unlock()
        }

        func snapshot() -> (cases: [CaseID: Samples], roomRMS: Double,
                            farA: Double, farB: Double) {
            lock.lock()
            defer { lock.unlock() }
            let room = sqrt(roomSquares / Double(max(1, roomFrames)))
            let a = sqrt(passFarSquares[.a, default: 0] /
                         Double(max(1, passFarFrames[.a, default: 0])))
            let b = sqrt(passFarSquares[.b, default: 0] /
                         Double(max(1, passFarFrames[.b, default: 0])))
            return (cases, room, a, b)
        }
    }

    private struct Fit {
        var correlation = 0.0
        var gain = 0.0
        var lag = 0
    }

    /// Find the best alignment independently for each raw/clean case. AEC has
    /// algorithmic delay; assuming zero lag misreports preserved speech as 0.
    private static func fitAtLag(_ known: [Float], _ heard: [Float], lag: Int) -> Fit {
        let count = known.count
        guard count >= 1_600, heard.count >= 1_600 else { return Fit() }
        var dot = 0.0, knownSquares = 0.0, heardSquares = 0.0
        for index in 80..<(count - 80) {
            let shifted = index + lag
            guard shifted >= 0, shifted < heard.count else { continue }
            let a = Double(known[index])
            let b = Double(heard[shifted])
            dot += a * b
            knownSquares += a * a
            heardSquares += b * b
        }
        return Fit(correlation: dot / sqrt(max(knownSquares * heardSquares, 1e-12)),
                   gain: dot / max(knownSquares, 1e-12), lag: lag)
    }

    private static func bestCalibrationLag(_ known: [Float], _ heard: [Float]) -> Fit {
        var best = Fit()
        for lag in stride(from: -320, through: 320, by: 8) {
            let candidate = fitAtLag(known, heard, lag: lag)
            if candidate.correlation > best.correlation { best = candidate }
        }
        let low = max(-320, best.lag - 8)
        let high = min(320, best.lag + 8)
        for lag in low...high {
            let candidate = fitAtLag(known, heard, lag: lag)
            if candidate.correlation > best.correlation { best = candidate }
        }
        return best
    }

    private static func nearClip(_ url: URL) throws -> (samples: [Float], onset: Int) {
        let file = try AVAudioFile(forReading: url)
        let capacity = AVAudioFrameCount(min(file.length, 48_000))
        guard let input = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                           frameCapacity: capacity) else {
            throw TranscriptionError.noAudioFormat
        }
        try file.read(into: input)
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000, channels: 1, interleaved: false) else {
            throw TranscriptionError.noAudioFormat
        }
        let converted: AVAudioPCMBuffer
        if input.format == format {
            converted = input
        } else {
            guard let converter = AVAudioConverter(from: input.format, to: format),
                  let output = AudioConversion.convert(input, to: format, using: converter) else {
                throw TranscriptionError.noAudioFormat
            }
            converted = output
        }
        guard let data = converted.floatChannelData?[0], converted.frameLength >= 8_000 else {
            throw TranscriptionError.noAudioFormat
        }
        let total = Int(converted.frameLength)
        let frames = total / 160
        var windows: [Double] = []
        for frame in 0..<frames {
            var squares = 0.0
            for index in 0..<160 {
                let value = Double(data[frame * 160 + index])
                squares += value * value
            }
            windows.append(sqrt(squares / 160))
        }
        let threshold = max(0.003, (windows.max() ?? 0) * 0.08)
        let firstSpeech = windows.indices.first { index in
            index + 2 < windows.count
                && windows[index...(index + 2)].allSatisfy { $0 >= threshold }
        } ?? 0
        let onset = max(0, firstSpeech * 160 - 160)
        let available = min(8_000, total - onset)
        var clip = Array(UnsafeBufferPointer(start: data + onset, count: available))
        if clip.count < 8_000 { clip += [Float](repeating: 0, count: 8_000 - clip.count) }
        return (clip, onset)
    }

    private final class Receipt {
        var began = false
        var finished = false
        var startPhase: Phase = .waiting
        var startedAt: Date?
        var finishedAt: Date?
        var failure: String?
    }

    static func run(voice requestedVoice: String = "selected", nearURL: URL)
        async -> (Bool, String) {
        guard await Permissions.requestMicrophone(),
              let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                  sampleRate: 16_000, channels: 1, interleaved: false) else {
            return (false, "ECHO_HYBRID_FAILED: microphone grant or 16k format unavailable")
        }
        let clip: (samples: [Float], onset: Int)
        do { clip = try nearClip(nearURL) }
        catch { return (false, "ECHO_HYBRID_FAILED: near WAV: \(error.localizedDescription)") }
        var voice = requestedVoice == "selected" ? Settings.shared.agentVoiceEngine : requestedVoice
        var sourceBacking: PCMProbeSpeechBacking?
        if CommandLine.arguments.contains("--acoustic-source-far") {
            guard SelfTest.isRunning,
                  let path = SelfTest.value(after: "--acoustic-source-far") else {
                return (false, "ECHO_HYBRID_FAILED: --acoustic-source-far requires a 3–25s WAV in a self-test")
            }
            voice = "source"
            do {
                let source = try PCMProbeSpeechBacking(farURL: URL(fileURLWithPath: path))
                sourceBacking = source
            } catch {
                return (false, "ECHO_HYBRID_FAILED: source WAV: \(error.localizedDescription)")
            }
        }
        let state = State(near: clip.samples)
        let receipt = Receipt()
        // Reproduce a persistent output graph running silently while TTS is
        // preparing. Silence must not accidentally count as learned room echo.
        var silentPrerollMilliseconds = 0
        if CommandLine.arguments.contains("--acoustic-silent-preroll-ms") {
            guard SelfTest.isRunning, sourceBacking != nil,
                  let value = SelfTest.value(after: "--acoustic-silent-preroll-ms"),
                  let milliseconds = Int(value), (0...5_000).contains(milliseconds) else {
                return (false, "ECHO_HYBRID_FAILED: silent preroll requires a source WAV and 0–5000 milliseconds")
            }
            silentPrerollMilliseconds = milliseconds
        }
        let backing: any AgentSpeechBacking
        switch voice {
        case "source":
            guard let sourceBacking else {
                return (false, "ECHO_HYBRID_FAILED: source backing was not prepared")
            }
            sourceBacking.onUtteranceStarted = { _ in
                receipt.began = true
                receipt.startedAt = Date()
                state.set(receipt.startPhase)
            }
            sourceBacking.onUtteranceFinished = { _ in
                receipt.finished = true
                receipt.finishedAt = Date()
            }
            sourceBacking.onFailure = { [weak sourceBacking] _, _, token in
                let reason = sourceBacking?.sourceFailure ?? "unknown renderer failure"
                receipt.failure = "PCM renderer failed token=\(token): \(reason)"
            }
            backing = sourceBacking
        case "apple":
            let apple = AVSpeechBacking()
            apple.onUtteranceStarted = { _ in
                receipt.began = true
                receipt.startedAt = Date()
                state.set(receipt.startPhase)
            }
            apple.onUtteranceFinished = { _ in
                receipt.finished = true
                receipt.finishedAt = Date()
            }
            backing = apple
        case "pocket":
            await PocketAgentVoice.shared.prepare()
            guard PocketAgentVoice.shared.isReady else {
                return (false, "ECHO_HYBRID_FAILED: Pocket model unavailable")
            }
            let pocket = PocketSpeechBacking()
            pocket.onUtteranceStarted = { _ in
                receipt.began = true
                receipt.startedAt = Date()
                state.set(receipt.startPhase)
            }
            pocket.onUtteranceFinished = { _ in
                receipt.finished = true
                receipt.finishedAt = Date()
            }
            pocket.onFailure = { _, _, token in
                receipt.failure = "Pocket TTS failed token=\(token)"
            }
            backing = pocket
        case "kokoro":
            await KokoroAgentVoice.shared.prepare()
            guard KokoroAgentVoice.shared.isReady else {
                return (false, "ECHO_HYBRID_FAILED: Kokoro model unavailable")
            }
            let kokoro = KokoroSpeechBacking()
            kokoro.onUtteranceStarted = { _ in
                receipt.began = true
                receipt.startedAt = Date()
                state.set(receipt.startPhase)
            }
            kokoro.onUtteranceFinished = { _ in
                receipt.finished = true
                receipt.finishedAt = Date()
            }
            kokoro.onFailure = { _, _, token in
                receipt.failure = "Kokoro TTS failed token=\(token)"
            }
            backing = kokoro
        default:
            sourceBacking?.endTest()
            return (false, "ECHO_HYBRID_FAILED: unknown voice \(voice)")
        }
        let seat = AudioCaptureHub.Consumer.client(UUID())
        AcousticEchoProcessor.shared.reset()
        guard AcousticEchoProcessor.shared.backendAvailable else {
            sourceBacking?.endTest()
            return (false, "ECHO_HYBRID_FAILED: AEC3 evaluation bridge unavailable")
        }
        do {
            try AudioCaptureHub.shared.subscribe(seat, outputFormat: format,
                onBuffer: { chunk in state.process(chunk) })
        } catch {
            sourceBacking?.endTest()
            return (false, "ECHO_HYBRID_FAILED: capture: \(error.localizedDescription)")
        }
        // The input hub owns microphone hardware and may change its format on
        // first subscription. Start the output source only after that change
        // has settled, so the two graphs cannot invalidate each other while
        // the first clause is being acknowledged.
        if let sourceBacking {
            do {
                try sourceBacking.prepare()
            } catch {
                AudioCaptureHub.shared.unsubscribe(seat)
                sourceBacking.endTest()
                return (false, "ECHO_HYBRID_FAILED: source renderer: \(error.localizedDescription)")
            }
        }
        defer {
            AudioCaptureHub.shared.unsubscribe(seat)
            backing.stop()
            sourceBacking?.endTest()
        }
        try? await Task.sleep(for: .seconds(1))

        let sentence = "Next Notes is speaking through its actual output. "
            + "This sentence keeps the laptop speakers active while a known nearby voice "
            + "is injected into the captured microphone at early and warmed moments. "
            + "The acoustic echo processor must preserve that voice and identify its onset."
        let passes: [(phase: Phase, volume: Float)] = [
            (.calibrationA, 0), (.calibrationB, 0),
            (.passA, 0.75), (.passB, 0.75),
        ]
        var zeroRenderReceipts: [(frames: Int, rms: Double)] = []
        var passTimings: [String] = []
        var processingFailures = 0
        for (index, pass) in passes.enumerated() {
            receipt.began = false
            receipt.finished = false
            receipt.startedAt = nil
            receipt.finishedAt = nil
            receipt.failure = nil
            receipt.startPhase = pass.phase
            AcousticEchoProcessor.shared.reset()
            state.set(.waiting)
            if silentPrerollMilliseconds > 0 {
                try? await Task.sleep(for: .milliseconds(silentPrerollMilliseconds))
                let preroll = AcousticEchoProcessor.shared.referenceSnapshot()
                guard preroll.frames >= silentPrerollMilliseconds * 8, preroll.rms < 0.001 else {
                    return (false, "ECHO_HYBRID_FAILED: silent output preroll was not rendered: \(preroll)")
                }
            }
            let submittedAt = Date()
            backing.speak(sentence, volume: pass.volume, token: UInt64(index + 1))
            for _ in 0..<100 where !receipt.began {
                try? await Task.sleep(for: .milliseconds(10))
            }
            // The source-backed fixture may be the full 25 seconds permitted
            // by its validator; leave enough time for the renderer to drain it.
            let finishWaitCycles = voice == "source" ? 320 : 240
            for _ in 0..<finishWaitCycles where !receipt.finished && receipt.failure == nil {
                try? await Task.sleep(for: .milliseconds(100))
            }
            if pass.volume == 0 {
                let rendered = AcousticEchoProcessor.shared.referenceSnapshot()
                zeroRenderReceipts.append((rendered.frames, rendered.rms))
            }
            let referenceAtDrain = AcousticEchoProcessor.shared.referenceSnapshot()
            processingFailures += AcousticEchoProcessor.shared.backendProcessingFailures
            let passReceipt = String(format:
                "pass%d volume=%.2f began=%@ first=%.3fs finished=%@ drain=%.3fs speaking=%@ reference=%d/%.5f failure=%@",
                index + 1, pass.volume, String(receipt.began),
                receipt.startedAt?.timeIntervalSince(submittedAt) ?? -1,
                String(receipt.finished), Date().timeIntervalSince(submittedAt),
                String(backing.isSpeaking), referenceAtDrain.frames,
                referenceAtDrain.rms, receipt.failure ?? "none")
            passTimings.append("\(passReceipt) timing=\(AcousticEchoProcessor.shared.timingSnapshot())")
            backing.stop()
            state.set(.waiting)
            if !receipt.began || !receipt.finished {
                return (false, "ECHO_HYBRID_FAILED: \(voice) real TTS did not start and drain pass \(index + 1); \(passTimings.joined(separator: "; "))")
            }
            try? await Task.sleep(for: .milliseconds(200))
        }
        let data = state.snapshot()
        let reference = AcousticEchoProcessor.shared.referenceSnapshot()
        var details: [String] = []
        var good = processingFailures == 0 && reference.frames > 16_000 && reference.rms > 0.005
            && data.farA > max(0.002, data.roomRMS * 1.5)
            && data.farB > max(0.002, data.roomRMS * 1.5)
            && zeroRenderReceipts.count == 2
            && zeroRenderReceipts.allSatisfy { $0.frames > 16_000 && $0.rms < 0.001 }
        let anchorSample = data.cases[.calibrationWarmStrong] ?? Samples()
        let anchor = bestCalibrationLag(anchorSample.known, anchorSample.clean)
        // One calibrated AEC latency is used for every mixed case. Choosing a
        // fresh best lag per case could inflate weak near-speech correlation.
        let fixedLag = anchor.lag
        good = good && anchor.correlation >= 0.55
        func matchingCalibration(_ id: CaseID) -> CaseID {
            switch id {
            case .earlyQuiet: .calibrationEarlyQuiet
            case .warmStrong: .calibrationWarmStrong
            case .earlyStrong: .calibrationEarlyStrong
            case .warmQuiet: .calibrationWarmQuiet
            default: id
            }
        }
        for id in CaseID.allCases {
            let sample = data.cases[id] ?? Samples()
            let raw = fitAtLag(sample.known, sample.raw, lag: 0)
            let clean = fitAtLag(sample.known, sample.clean, lag: fixedLag)
            let firstKnown = Array(sample.known.prefix(1_600))
            let firstClean = Array(sample.clean.prefix(1_600 + max(0, fixedLag)))
            let first100 = fitAtLag(firstKnown, firstClean, lag: fixedLag)
            let calibration = data.cases[matchingCalibration(id)] ?? Samples()
            let baseline = fitAtLag(calibration.known, calibration.clean, lag: fixedLag)
            let baselineFirst100 = fitAtLag(Array(calibration.known.prefix(1_600)),
                Array(calibration.clean.prefix(1_600 + max(0, fixedLag))), lag: fixedLag)
            let relativeGain = clean.gain / max(baseline.gain, 1e-8)
            let relativeFirst100 = first100.gain / max(baselineFirst100.gain, 1e-8)
            let onset = sample.firstCandidateSeconds.map { String(format: "%.3f", $0) } ?? "none"
            details.append(String(format:
                "%@ frames=%d rawCorr=%.2f/rawGain=%.2f cleanCorr=%.2f/cleanGain=%.2f/fixedLag=%d relGain=%.2f first100Corr=%.2f/relGain=%.2f candidate=%d/first=%@s",
                id.label, sample.known.count, raw.correlation, raw.gain,
                clean.correlation, clean.gain, fixedLag, relativeGain,
                first100.correlation, relativeFirst100,
                sample.candidateChunks, onset))
            if matchingCalibration(id) == id {
                good = good && raw.correlation >= 0.75 && raw.gain >= 0.7
                    && clean.correlation >= 0.55 && clean.gain >= 0.4
                    && first100.correlation >= 0.45 && first100.gain >= 0.35
            } else {
                good = good && sample.known.count >= 7_000
                    && clean.correlation >= 0.45 && relativeGain >= 0.45
                    && first100.correlation >= 0.35 && relativeFirst100 >= 0.35
                    && sample.firstCandidateSeconds.map { $0 <= 0.25 } == true
            }
        }
        let header = String(format:
            "roomRMS=%.5f farA=%.5f farB=%.5f renderedRMS=%.5f/%d frames; zeroRender=%@; nearWavOnset=%d samples calibratedLag=%d; ",
            data.roomRMS, data.farA, data.farB, reference.rms, reference.frames,
            zeroRenderReceipts.map { "\($0.frames)/\($0.rms)" }.joined(separator: ","),
            clip.onset, fixedLag) + "silentPrerollMs=\(silentPrerollMilliseconds); "
        return (good, "ECHO_HYBRID_\(good ? "OK" : "FAILED"): \(voice)/\(AcousticEchoProcessor.shared.backendName); "
            + header + details.joined(separator: "; ")
            + "; processingFailures=\(processingFailures)"
            + "; \(passTimings.joined(separator: "; "))"
            + "; hybrid injected near WAV, not physical human double-talk")
    }
}
