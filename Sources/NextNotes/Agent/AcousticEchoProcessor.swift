import AVFoundation
import Foundation
import SpeexEcho

/// Agent-only acoustic echo cancellation. The render reference is the PCM
/// observed at the output engine's mixer, after per-voice gain and scheduling.
/// Capture uses the 16 kHz hub delivery lane, so neither Speex nor conversion
/// runs on the microphone or speaker realtime callbacks.
final class AcousticEchoProcessor: @unchecked Sendable {
    struct Evidence: Sendable {
        let aecProcessed: Bool
        let recentReference: Bool
        let nearCandidate: Bool
        let independentNearCandidate: Bool
        let echoCoherence: Double
        let bestCoherence: Double
        let bestLagSamples: Int
        let referenceUnderflow: Bool
        let queuedReferenceSamples: Int
        let rawRMS: Double
        let cleanedRMS: Double
        let referenceRMS: Double
    }

    static let shared = AcousticEchoProcessor()
    private let lock = NSLock()
    private let conversionLock = NSLock()
    private let aec3Requested = SelfTest.isRunning
        && CommandLine.arguments.contains("--acoustic-aec3")
    /// Evaluation-only Speex path. The normal production path keeps the
    /// soundcard-delay playback queue; this flag compares the direct API
    /// against it without changing trust, timing, or adaptation policy.
    private let synchronousSpeexRequested = SelfTest.isRunning
        && CommandLine.arguments.contains("--acoustic-speex-synchronous")
        && !CommandLine.arguments.contains("--acoustic-aec3")
    /// Evaluation-only reference bookkeeping. The production path deliberately
    /// retains its existing accounting until the paired-reference regression is
    /// measured on the real output routes.
    private let activeReferenceAccountingRequested = SelfTest.isRunning
        && CommandLine.arguments.contains("--acoustic-active-reference-accounting")
        && !CommandLine.arguments.contains("--acoustic-aec3")
    private var aec3: AEC3ProbeBridge?
    private var aec3ProcessingFailures = 0
    private var aec3Rendered: [Float] = []
    private var aec3RenderStartSeconds: Double?
    private var aec3Captured: [Float] = []
    private var aec3Ready: [Float] = [Float](repeating: 0, count: 160)
    private var aec3CaptureStartHostTime: UInt64?
    private var renderTiming = TimingAccumulator()
    private var renderTapTiming = TimingAccumulator()
    private var renderDispatchTiming = TimingAccumulator()
    private var captureTiming = TimingAccumulator()
    private var renderBufferFrames = TimingAccumulator()
    private var captureBufferFrames = TimingAccumulator()
    private var missingRenderTimestamps = 0
    private var missingCaptureTimestamps = 0
    private var convertedInputFormat: AVAudioFormat?
    private var downConverter: AVAudioConverter?
    private var upConverter: AVAudioConverter?
    private let frameSize = 160
    private var state: OpaquePointer?
    private var postfilter: OpaquePointer?
    private var playback: [Int16] = []
    private var captured: [Int16] = []
    private var processed: [Int16] = []
    private var rawDelay: [Int16] = [Int16](repeating: 0, count: 160)
    private var rawReady: [Int16] = [Int16](repeating: 0, count: 160)
    private var coherenceFar: [Int16] = []
    private var coherenceMic: [Int16] = []
    /// Microphone frames actually processed while the output reference was
    /// present. Rendered frames alone do not prove the filter has adapted.
    private var adaptedMicFrames = 0
    private var independentNearFrames = 0
    private var previousRate: Double = 0
    private var renderPhase: Double = 0
    private var lastReference = Date.distantPast
    private var tailRemainingSamples = 0
    private var tailStarted = Date.distantPast
    private var outputStopped = false
    /// In the opt-in accounting path, silence is retained only while an active
    /// reference is still recent enough to keep the render/capture clocks paired.
    private var hasActiveReference = false
    private var referenceSquares = 0.0
    private var referenceFrames = 0
    /// Opt-in diagnostic count of every converted renderer receipt, including
    /// zero clock placeholders that are intentionally not queued for Speex.
    private var observedReferenceSquares = 0.0
    private var observedReferenceFrames = 0
    private var latestReferenceRMS = 0.0
    private var evidence = Evidence(aecProcessed: false, recentReference: false,
                                    nearCandidate: false, independentNearCandidate: false,
                                    echoCoherence: 0, bestCoherence: 0,
                                    bestLagSamples: 0, referenceUnderflow: false,
                                    queuedReferenceSamples: 0, rawRMS: 0,
                                    cleanedRMS: 0, referenceRMS: 0)

    private struct TimingAccumulator {
        var count = 0
        var sum = 0.0
        var minimum = Double.infinity
        var maximum = -Double.infinity
        mutating func add(_ milliseconds: Double) {
            guard milliseconds.isFinite, abs(milliseconds) < 10_000 else { return }
            count += 1
            sum += milliseconds
            minimum = min(minimum, milliseconds)
            maximum = max(maximum, milliseconds)
        }
        var description: String {
            guard count > 0 else { return "unavailable" }
            return String(format: "%.1fms [%.1f..%.1f] n=%d",
                          sum / Double(count), minimum, maximum, count)
        }
        var frameDescription: String {
            guard count > 0 else { return "unavailable" }
            return String(format: "%.0f [%.0f..%.0f] n=%d",
                          sum / Double(count), minimum, maximum, count)
        }
    }

    private init() {
        if aec3Requested { aec3 = AEC3ProbeBridge() }
        state = speex_echo_state_init(160, 5_600)
        var rate: Int32 = 16_000
        if let state { _ = speex_echo_ctl(state, Int32(SPEEX_ECHO_SET_SAMPLING_RATE), &rate) }
        postfilter = speex_preprocess_state_init(160, 16_000)
        if let postfilter, let state {
            // SET_ECHO_STATE takes the state address itself (the GET request
            // alone takes a pointer-to-pointer). Passing &state corrupts the
            // postfilter's echo estimate and can crash on the first frame.
            _ = speex_preprocess_ctl(postfilter, Int32(SPEEX_PREPROCESS_SET_ECHO_STATE),
                                     UnsafeMutableRawPointer(state))
            // In Speex the "denoise" switch controls *all* spectral gains,
            // including residual-echo suppression. Keep it enabled, but set
            // ordinary noise attenuation to a gentle -3 dB to preserve voice.
            var enabled: Int32 = 1
            var disabled: Int32 = 0
            var noiseSuppress: Int32 = -3
            _ = speex_preprocess_ctl(postfilter, Int32(SPEEX_PREPROCESS_SET_DENOISE), &enabled)
            _ = speex_preprocess_ctl(postfilter, Int32(SPEEX_PREPROCESS_SET_NOISE_SUPPRESS), &noiseSuppress)
            _ = speex_preprocess_ctl(postfilter, Int32(SPEEX_PREPROCESS_SET_AGC), &disabled)
            var suppress: Int32 = -55
            var suppressNear: Int32 = -18
            _ = speex_preprocess_ctl(postfilter, Int32(SPEEX_PREPROCESS_SET_ECHO_SUPPRESS), &suppress)
            _ = speex_preprocess_ctl(postfilter, Int32(SPEEX_PREPROCESS_SET_ECHO_SUPPRESS_ACTIVE), &suppressNear)
        }
    }

    deinit {
        if let postfilter { speex_preprocess_state_destroy(postfilter) }
        if let state { speex_echo_state_destroy(state) }
    }

    /// After barge-in, the speaker and room can continue reflecting PCM already
    /// rendered before output stop. Retain that reference and Speex's learned
    /// filter for at most 350 ms of microphone audio, feeding zero far frames
    /// when the buffered reference runs out. Full reset belongs to session
    /// begin/end or an input/output route change.
    func stopPlayback() {
        lock.lock()
        outputStopped = true
        if Date().timeIntervalSince(lastReference) < 0.3 && referenceFrames > 0 {
            tailRemainingSamples = 5_600
            tailStarted = Date()
        } else {
            playback.removeAll()
            captured.removeAll()
            processed.removeAll()
            tailRemainingSamples = 0
            lastReference = .distantPast
        }
        lock.unlock()
    }

    /// Invalidate pending speaker samples on interruption or output-route reset.
    func reset() {
        lock.lock()
        if aec3Requested { aec3 = AEC3ProbeBridge() }
        aec3Rendered.removeAll()
        aec3ProcessingFailures = 0
        aec3RenderStartSeconds = nil
        aec3Captured.removeAll()
        aec3Ready = [Float](repeating: 0, count: frameSize)
        aec3CaptureStartHostTime = nil
        renderTiming = TimingAccumulator()
        renderTapTiming = TimingAccumulator()
        renderDispatchTiming = TimingAccumulator()
        captureTiming = TimingAccumulator()
        renderBufferFrames = TimingAccumulator()
        captureBufferFrames = TimingAccumulator()
        missingRenderTimestamps = 0
        missingCaptureTimestamps = 0
        playback.removeAll()
        captured.removeAll()
        processed.removeAll()
        rawDelay = [Int16](repeating: 0, count: frameSize)
        rawReady = [Int16](repeating: 0, count: frameSize)
        coherenceFar.removeAll()
        coherenceMic.removeAll()
        adaptedMicFrames = 0
        independentNearFrames = 0
        lastReference = .distantPast
        tailRemainingSamples = 0
        tailStarted = .distantPast
        outputStopped = false
        hasActiveReference = false
        referenceSquares = 0
        referenceFrames = 0
        observedReferenceSquares = 0
        observedReferenceFrames = 0
        latestReferenceRMS = 0
        evidence = Evidence(aecProcessed: false, recentReference: false,
                            nearCandidate: false, independentNearCandidate: false,
                            echoCoherence: 0, bestCoherence: 0,
                            bestLagSamples: 0, referenceUnderflow: false,
                            queuedReferenceSamples: 0, rawRMS: 0,
                            cleanedRMS: 0, referenceRMS: 0)
        renderPhase = 0
        if let state { speex_echo_state_reset(state) }
        lock.unlock()
    }

    /// Feed samples actually rendered by the output mixer, not TTS frames merely
    /// scheduled for later. A 500 ms ceiling bounds reference memory if capture
    /// pauses while output continues.
    func feedRendered(_ buffer: AVAudioPCMBuffer, renderHostTime: UInt64? = nil,
                      tapArrivalHostTime: UInt64? = nil,
                      outputPresentationLatency: TimeInterval = 0) {
        guard let channels = buffer.floatChannelData, buffer.frameLength > 0 else { return }
        let count = Int(buffer.frameLength)
        let rate = buffer.format.sampleRate
        guard rate >= 8_000, rate <= 192_000 else { return }
        let channelCount = Int(buffer.format.channelCount)
        lock.lock()
        defer { lock.unlock() }

        // The source renderer emits zero-filled buffers while its graph stays
        // alive. In the opt-in path, inspect their RMS before any lifecycle
        // mutation: an idle zero buffer must neither clear the acoustic tail nor
        // resurrect a stopped output session. The actual samples still enter
        // `playback` while an energetic reference is recent, preserving the
        // render/capture clock pairing needed by Speex.
        var preflightReferenceRMS = 0.0
        var preflightReferenceSquares = 0.0
        var preflightReferenceFrames = 0
        if activeReferenceAccountingRequested {
            var phase = renderPhase
            while phase < Double(count) {
                let source = min(count - 1, Int(phase))
                let next = min(count - 1, source + 1)
                let fraction = Float(phase - Double(source))
                var sample: Float = 0
                for channel in 0..<channelCount {
                    sample += channels[channel][source] * (1 - fraction)
                        + channels[channel][next] * fraction
                }
                sample /= Float(channelCount)
                preflightReferenceSquares += Double(sample * sample)
                preflightReferenceFrames += 1
                phase += rate / 16_000
            }
            preflightReferenceRMS = sqrt(preflightReferenceSquares
                / Double(max(preflightReferenceFrames, 1)))
            // Keep receipt diagnostics truthful without putting bypassed
            // silence into the Speex FIFO or its adaptation accounting.
            observedReferenceSquares += preflightReferenceSquares
            observedReferenceFrames += preflightReferenceFrames
        }
        if aec3Requested {
            renderBufferFrames.add(Double(count))
            if let renderHostTime, let tapArrivalHostTime {
                let renderFirst = AVAudioTime.seconds(forHostTime: renderHostTime)
                    + outputPresentationLatency
                let tapArrival = AVAudioTime.seconds(forHostTime: tapArrivalHostTime)
                renderTapTiming.add((renderFirst - tapArrival) * 1_000)
                renderDispatchTiming.add((AVAudioTime.seconds(forHostTime: mach_absolute_time())
                    - tapArrival) * 1_000)
            }
        }
        let energeticReference = preflightReferenceRMS > 0.005
        if activeReferenceAccountingRequested {
            if energeticReference {
                if tailRemainingSamples > 0 {
                    // A new utterance begins: prior room tail must not be
                    // interpreted as the first PCM reference of this answer.
                    playback.removeAll()
                    captured.removeAll()
                    processed.removeAll()
                    rawDelay = [Int16](repeating: 0, count: frameSize)
                    rawReady = [Int16](repeating: 0, count: frameSize)
                    tailRemainingSamples = 0
                    tailStarted = .distantPast
                }
                outputStopped = false
                hasActiveReference = true
            } else {
                let stale = !hasActiveReference
                    || outputStopped
                    || tailRemainingSamples > 0
                    || Date().timeIntervalSince(lastReference) >= 0.3
                if stale {
                    // No output is currently active. Do not accumulate idle
                    // zero placeholders while the processor is intentionally
                    // bypassing; a later energetic buffer starts a fresh FIFO.
                    if hasActiveReference,
                       Date().timeIntervalSince(lastReference) >= 0.3 {
                        playback.removeAll()
                        hasActiveReference = false
                    }
                    if !outputStopped && tailRemainingSamples == 0 {
                        captured.removeAll()
                        processed.removeAll()
                        rawDelay = [Int16](repeating: 0, count: frameSize)
                        rawReady = [Int16](repeating: 0, count: frameSize)
                    }
                    return
                }
                // Recent silence is retained below so the far/mic clocks stay
                // paired across an active output gap.
            }
        } else if tailRemainingSamples > 0 {
            // A new utterance begins: prior room tail must not be interpreted
            // as the first PCM reference of this different answer.
            playback.removeAll()
            captured.removeAll()
            processed.removeAll()
            rawDelay = [Int16](repeating: 0, count: frameSize)
            rawReady = [Int16](repeating: 0, count: frameSize)
            tailRemainingSamples = 0
            tailStarted = .distantPast
        }
        if !activeReferenceAccountingRequested { outputStopped = false }
        if previousRate != rate {
            playback.removeAll()
            aec3Rendered.removeAll()
            aec3RenderStartSeconds = nil
            renderPhase = 0
            if let state { speex_echo_state_reset(state) }
            previousRate = rate
            if activeReferenceAccountingRequested {
                hasActiveReference = energeticReference
            }
        }
        let step = rate / 16_000
        var latestSquares = 0.0
        var latestFrames = 0
        while renderPhase < Double(count) {
            let source = min(count - 1, Int(renderPhase))
            let next = min(count - 1, source + 1)
            let fraction = Float(renderPhase - Double(source))
            var sample: Float = 0
            for channel in 0..<channelCount {
                sample += channels[channel][source] * (1 - fraction)
                    + channels[channel][next] * fraction
            }
            sample /= Float(channelCount)
            referenceSquares += Double(sample * sample)
            referenceFrames += 1
            latestSquares += Double(sample * sample)
            latestFrames += 1
            playback.append(Self.pcm16(sample))
            if let aec3 {
                if aec3Rendered.isEmpty {
                    aec3RenderStartSeconds = renderHostTime.map {
                        AVAudioTime.seconds(forHostTime: $0)
                            + renderPhase / rate + outputPresentationLatency
                    }
                }
                aec3Rendered.append(sample)
                while aec3Rendered.count >= frameSize {
                    let frame = Array(aec3Rendered.prefix(frameSize))
                    aec3Rendered.removeFirst(frameSize)
                    if let renderSeconds = aec3RenderStartSeconds {
                        let analyzedSeconds = AVAudioTime.seconds(forHostTime: mach_absolute_time())
                        renderTiming.add((renderSeconds - analyzedSeconds) * 1_000)
                        aec3RenderStartSeconds = renderSeconds + 0.010
                    } else {
                        missingRenderTimestamps += 1
                    }
                    if !aec3.feedRendered(frame) { Log.agent.error("AEC3 render feed failed") }
                }
            }
            renderPhase += step
        }
        renderPhase -= Double(count)
        latestReferenceRMS = sqrt(latestSquares / Double(max(latestFrames, 1)))
        if playback.count > 8_000 { playback.removeFirst(playback.count - 8_000) }
        if !activeReferenceAccountingRequested || energeticReference {
            lastReference = Date()
        }
    }

    func referenceSnapshot() -> (rms: Double, frames: Int) {
        lock.lock()
        defer { lock.unlock() }
        if activeReferenceAccountingRequested {
            return (sqrt(observedReferenceSquares
                / Double(max(observedReferenceFrames, 1))), observedReferenceFrames)
        }
        return (sqrt(referenceSquares / Double(max(referenceFrames, 1))), referenceFrames)
    }

    private func activeReferenceAccountingSnapshot() -> (observed: Int, adapted: Int) {
        lock.lock()
        defer { lock.unlock() }
        return (observedReferenceFrames, adaptedMicFrames)
    }

    /// Measured clock components of AEC3's stream-delay API. The render
    /// component includes AVAudioOutputNode's estimated presentation latency;
    /// neither component includes physical acoustic room propagation. These
    /// observations do not silently alter the configured AEC3 delay.
    func timingSnapshot() -> String {
        lock.lock()
        defer { lock.unlock() }
        return "render-to-hardware \(renderTiming.description), capture-to-process "
            + "\(captureTiming.description), missing timestamps "
            + "\(missingRenderTimestamps)/\(missingCaptureTimestamps); render tap "
            + "\(renderTapTiming.description), dispatch \(renderDispatchTiming.description), "
            + "render frames \(renderBufferFrames.frameDescription), mic frames "
            + "\(captureBufferFrames.frameDescription)"
    }

    var backendAvailable: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !aec3Requested || aec3 != nil
    }

    var backendName: String {
        lock.lock()
        defer { lock.unlock() }
        if aec3Requested { return aec3?.outputMode ?? "aec3-unavailable" }
        return synchronousSpeexRequested ? "speex-sync-evaluation" : "speex"
    }

    var backendProcessingFailures: Int {
        lock.lock()
        defer { lock.unlock() }
        return aec3ProcessingFailures
    }

    /// Synchronous advisory for the voice turn policy. It reports that actual
    /// render-reference PCM was available and processed; `nearCandidate` is
    /// deliberately conservative, not proof of a human speaker. Both recognizers
    /// hear the same residual echo; even agreement cannot establish identity.
    /// This advisory must never override textual echo protection.
    func evidenceSnapshot() -> Evidence {
        lock.lock()
        defer { lock.unlock() }
        return evidence
    }

    /// Called inside the Agent's serial 16 kHz capture lane. The input and
    /// reference frame clocks can differ by one callback; Speex's playback /
    /// capture API accommodates that jitter with its internal playback queue.
    /// No reference means untouched microphone audio, preserving near speech.
    func process(_ chunk: AudioChunk) -> AudioChunk {
        let input = chunk.buffer
        if input.format.sampleRate != 16_000 || input.format.channelCount != 1
            || input.format.commonFormat != .pcmFormatFloat32
            || input.format.isInterleaved {
            guard let internalFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: 16_000,
                channels: 1, interleaved: false
            ) else { return chunk }
            conversionLock.lock()
            if convertedInputFormat != input.format {
                convertedInputFormat = input.format
                downConverter = AVAudioConverter(from: input.format, to: internalFormat)
                upConverter = AVAudioConverter(from: internalFormat, to: input.format)
                reset()
            }
            guard let downConverter,
                  let converted = AudioConversion.convert(
                    input, to: internalFormat, using: downConverter
                  ) else {
                conversionLock.unlock()
                return chunk
            }
            conversionLock.unlock()
            let cleaned = process(AudioChunk(buffer: converted,
                captureHostTime: chunk.captureHostTime)).buffer
            conversionLock.lock()
            let restored = upConverter.flatMap {
                AudioConversion.convert(cleaned, to: input.format, using: $0)
            }
            conversionLock.unlock()
            guard let restored else { return chunk }
            return AudioChunk(buffer: restored, captureHostTime: chunk.captureHostTime)
        }
        guard input.format.sampleRate == 16_000,
              input.format.channelCount == 1,
              let samples = input.floatChannelData?[0],
              let output = AudioConversion.copy(input),
              let result = output.floatChannelData?[0] else { return chunk }
        lock.lock()
        defer { lock.unlock() }
        if aec3Requested {
            guard let aec3 else { return chunk }
            let count = Int(input.frameLength)
            captureBufferFrames.add(Double(count))
            if aec3Captured.isEmpty {
                aec3CaptureStartHostTime = chunk.captureHostTime
            }
            aec3Captured.append(contentsOf: (0..<count).map { samples[$0] })
            while aec3Captured.count >= frameSize {
                let frame = Array(aec3Captured.prefix(frameSize))
                aec3Captured.removeFirst(frameSize)
                if let captureHostTime = aec3CaptureStartHostTime {
                    let capturedSeconds = AVAudioTime.seconds(forHostTime: captureHostTime)
                    let processedSeconds = AVAudioTime.seconds(forHostTime: mach_absolute_time())
                    captureTiming.add((processedSeconds - capturedSeconds) * 1_000)
                    aec3CaptureStartHostTime = AVAudioTime.hostTime(
                        forSeconds: capturedSeconds + 0.010)
                } else {
                    missingCaptureTimestamps += 1
                }
                guard let rendered = aec3.process(frame) else {
                    aec3ProcessingFailures += 1
                    return chunk
                }
                aec3Ready.append(contentsOf: rendered)
            }
            guard aec3Ready.count >= count else { return chunk }
            for index in 0..<count { result[index] = aec3Ready[index] }
            aec3Ready.removeFirst(count)
            var rawSquares = 0.0
            var cleanSquares = 0.0
            for index in 0..<count {
                rawSquares += Double(samples[index] * samples[index])
                cleanSquares += Double(result[index] * result[index])
            }
            let rawRMS = sqrt(rawSquares / Double(max(1, count)))
            let cleanedRMS = sqrt(cleanSquares / Double(max(1, count)))
            let referenceActive = !outputStopped
                && Date().timeIntervalSince(lastReference) < 0.3
                && latestReferenceRMS > 0.005
            // AEC3's processed output keeps near speech but reduces echo.
            // Demand consecutive energetic cleaned frames and preserved mic
            // energy; an output-side model EOU and novel ASR still decide if
            // the candidate is a human turn, not this level estimate alone.
            let independentNow = referenceActive && cleanedRMS > 0.025
                && cleanedRMS > rawRMS * 0.65
            independentNearFrames = independentNow
                ? min(16_000, independentNearFrames + count) : 0
            let near = independentNearFrames >= 480
            evidence = Evidence(aecProcessed: referenceActive,
                recentReference: referenceActive,
                nearCandidate: near, independentNearCandidate: near,
                echoCoherence: 0, bestCoherence: 0, bestLagSamples: 0,
                referenceUnderflow: false, queuedReferenceSamples: 0,
                rawRMS: rawRMS, cleanedRMS: cleanedRMS,
                referenceRMS: latestReferenceRMS)
            return AudioChunk(buffer: output, captureHostTime: chunk.captureHostTime)
        }
        let tailActive = tailRemainingSamples > 0
            && Date().timeIntervalSince(tailStarted) < 0.5
        guard let state,
              (!outputStopped && Date().timeIntervalSince(lastReference) < 0.3)
                || tailActive else {
            if tailRemainingSamples > 0 {
                playback.removeAll()
                captured.removeAll()
                processed.removeAll()
                rawDelay = [Int16](repeating: 0, count: frameSize)
                rawReady = [Int16](repeating: 0, count: frameSize)
                tailRemainingSamples = 0
            }
            independentNearFrames = 0
            evidence = Evidence(aecProcessed: false, recentReference: false,
                                nearCandidate: false, independentNearCandidate: false,
                                echoCoherence: 0, bestCoherence: 0,
                                bestLagSamples: 0, referenceUnderflow: false,
                                queuedReferenceSamples: playback.count, rawRMS: 0,
                                cleanedRMS: 0, referenceRMS: latestReferenceRMS)
            return chunk
        }
        let count = Int(input.frameLength)
        // 160-sample frames avoid synthetic zeros at callback boundaries.
        captured.append(contentsOf: (0..<count).map { Self.pcm16(samples[$0]) })
        let queuedAtEntry = playback.count
        var referenceUnderflow = false
        if processed.isEmpty { processed = [Int16](repeating: 0, count: frameSize) }
        while captured.count >= frameSize {
            let mic = Array(captured.prefix(frameSize))
            captured.removeFirst(frameSize)
            let far: [Int16]
            let hadReference = playback.count >= frameSize
            if !hadReference { referenceUnderflow = true }
            if hadReference {
                far = Array(playback.prefix(frameSize))
                playback.removeFirst(frameSize)
            } else {
                far = [Int16](repeating: 0, count: frameSize)
            }
            if activeReferenceAccountingRequested {
                // Only a consumed pair with an energetic far frame proves that
                // Speex had a real reference for this microphone frame. A
                // missing queue frame or an idle zero placeholder must not
                // advance adaptation trust.
                if hadReference && !outputStopped && Self.hasEnergeticReference(far) {
                    adaptedMicFrames += frameSize
                }
            }
            coherenceFar.append(contentsOf: far)
            coherenceMic.append(contentsOf: mic)
            if coherenceFar.count > 2_560 { coherenceFar.removeFirst(coherenceFar.count - 2_560) }
            if coherenceMic.count > 640 { coherenceMic.removeFirst(coherenceMic.count - 640) }
            var near = [Int16](repeating: 0, count: frameSize)
            mic.withUnsafeBufferPointer { source in
                near.withUnsafeMutableBufferPointer { destination in
                    if synchronousSpeexRequested {
                        // The direct API has no implicit two-frame soundcard
                        // delay. Underflow still uses the same zero far frame
                        // assembled above, preserving this path's paired data.
                        far.withUnsafeBufferPointer { reference in
                            speex_echo_cancellation(state, source.baseAddress,
                                reference.baseAddress, destination.baseAddress)
                        }
                    } else {
                        if hadReference || tailActive {
                            far.withUnsafeBufferPointer { reference in
                                speex_echo_playback(state, reference.baseAddress)
                            }
                        }
                        speex_echo_capture(state, source.baseAddress, destination.baseAddress)
                    }
                }
            }
            if let postfilter {
                near.withUnsafeMutableBufferPointer { output in
                    _ = speex_preprocess_run(postfilter, output.baseAddress)
                }
            }
            processed.append(contentsOf: near)
            rawDelay.append(contentsOf: mic)
            rawReady.append(contentsOf: rawDelay.prefix(frameSize))
            rawDelay.removeFirst(frameSize)
        }
        // One fixed 10 ms frame of latency keeps the microphone and filter
        // frame clocks aligned without dropping a syllable at callback edges.
        guard processed.count >= count, rawReady.count >= count else { return chunk }
        if !activeReferenceAccountingRequested, !outputStopped {
            // Preserve the original production accounting until the opt-in
            // replay proves the paired-reference replacement safe.
            adaptedMicFrames += count
        }
        // A cold Speex filter can suppress independent near speech. Keep its
        // 20-ms-matched raw path when the microphone is incoherent with the
        // rendered speaker reference; use cancellation immediately when a
        // room-delayed far signal explains the mic. This avoids leaking the
        // whole first reply through an unconditional raw warm-up. Speex still
        // adapts continuously, and after convergence we trust its cleaned
        // output even during double-talk.
        let trainedFrames = min(referenceFrames, adaptedMicFrames)
        let trainedTrust = Float(max(0, min(1, Double(trainedFrames - 16_000) / 16_000)))
        let echoCoherence = Self.echoCoherence(microphone: coherenceMic, reference: coherenceFar)
        let diagnostic = SelfTest.isRunning
            ? Self.bestEchoCoherence(microphone: coherenceMic,
                consumedReference: coherenceFar,
                futureReference: Array(playback.prefix(2_400)))
            : (score: echoCoherence, lag: 0)
        let trust = max(trainedTrust, echoCoherence >= 0.70 ? 1 : 0)
        for index in 0..<count {
            result[index] = (Float(rawReady[index]) * (1 - trust)
                             + Float(processed[index]) * trust) / 32768
        }
        processed.removeFirst(count)
        rawReady.removeFirst(count)
        if tailActive { tailRemainingSamples = max(0, tailRemainingSamples - count) }
        var rawSquares = 0.0
        var cleanSquares = 0.0
        for index in 0..<count {
            rawSquares += Double(samples[index] * samples[index])
            cleanSquares += Double(result[index] * result[index])
        }
        let rawRMS = sqrt(rawSquares / Double(max(count, 1)))
        let cleanedRMS = sqrt(cleanSquares / Double(max(count, 1)))
        let independentNow = !outputStopped && latestReferenceRMS > 0.005
            && echoCoherence > 0 && echoCoherence < 0.55 && rawRMS > 0.025
        independentNearFrames = independentNow
            ? min(16_000, independentNearFrames + count) : 0
        let independentNearCandidate = independentNearFrames >= 480
        let nearCandidate = trust >= 1
            && echoCoherence < 0.70
            && referenceFrames >= 16_000
            && latestReferenceRMS > 0.005
            && cleanedRMS > 0.015
            && cleanedRMS > rawRMS * 0.6
        evidence = Evidence(aecProcessed: trust >= 1, recentReference: tailActive ||
                                (!outputStopped && Date().timeIntervalSince(lastReference) < 0.3),
                            nearCandidate: nearCandidate,
                            independentNearCandidate: independentNearCandidate,
                            echoCoherence: echoCoherence,
                            bestCoherence: diagnostic.score,
                            bestLagSamples: diagnostic.lag,
                            referenceUnderflow: referenceUnderflow,
                            queuedReferenceSamples: queuedAtEntry,
                            rawRMS: rawRMS, cleanedRMS: cleanedRMS,
                            referenceRMS: latestReferenceRMS)
        return AudioChunk(buffer: output, captureHostTime: chunk.captureHostTime)
    }

    /// Short-window normalized correlation over plausible speaker-to-mic
    /// delays. A separate near voice lowers this score even if the raw level
    /// rises. The search occurs on the serial Agent worker, never an audio IO
    /// callback, and is bounded to ~45 × 640 multiply-adds per 10-ms frame.
    private static func echoCoherence(microphone: [Int16], reference: [Int16]) -> Double {
        let width = 640
        guard microphone.count >= width, reference.count >= width + 160 else { return 0 }
        let micEnergy = microphone.suffix(width).reduce(0.0) {
            $0 + Double($1) * Double($1)
        }
        guard micEnergy > 640 * 100 * 100 else { return 0 }
        let end = reference.count
        var highest = 0.0
        for lag in stride(from: 160, through: 1_920, by: 40) where end >= width + lag {
            let start = end - width - lag
            var dot = 0.0
            var farEnergy = 0.0
            for index in 0..<width {
                let near = Double(microphone[microphone.count - width + index])
                let far = Double(reference[start + index])
                dot += near * far
                farEnergy += far * far
            }
            if farEnergy > 640 * 100 * 100 {
                highest = max(highest, abs(dot) / sqrt(micEnergy * farEnergy))
            }
        }
        return highest
    }

    /// Probe-only signed lag search. Negative lag means the best acoustic
    /// speaker match is still queued *ahead* of the reference frame consumed
    /// by Speex; positive lag points into already consumed render history.
    private static func bestEchoCoherence(
        microphone: [Int16], consumedReference: [Int16], futureReference: [Int16]
    ) -> (score: Double, lag: Int) {
        let width = 640
        guard microphone.count >= width else { return (0, 0) }
        let reference = consumedReference + futureReference
        let boundary = consumedReference.count
        let micEnergy = microphone.suffix(width).reduce(0.0) {
            $0 + Double($1) * Double($1)
        }
        guard micEnergy > 640 * 100 * 100 else { return (0, 0) }
        var best = (score: 0.0, lag: 0)
        for lag in stride(from: -1_760, through: 1_920, by: 40) {
            let start = boundary - width - lag
            guard start >= 0, start + width <= reference.count else { continue }
            var dot = 0.0
            var energy = 0.0
            for index in 0..<width {
                let near = Double(microphone[microphone.count - width + index])
                let far = Double(reference[start + index])
                dot += near * far
                energy += far * far
            }
            if energy > 640 * 100 * 100 {
                let score = abs(dot) / sqrt(micEnergy * energy)
                if score > best.score { best = (score, lag) }
            }
        }
        return best
    }

    private static func pcm16(_ sample: Float) -> Int16 {
        Int16(max(-32768, min(32767, Int((sample.isFinite ? sample : 0) * 32767))))
    }

    /// Reuse the existing reference-activity criterion for paired training.
    /// The conversion to Int16 happens before Speex, so compare in that same
    /// scale rather than introducing a second acoustic threshold.
    private static func hasEnergeticReference(_ frame: [Int16]) -> Bool {
        guard !frame.isEmpty else { return false }
        let threshold = 0.005 * 32767.0
        let minimumEnergy = threshold * threshold * Double(frame.count)
        let energy = frame.reduce(0.0) { total, sample in
            total + Double(sample) * Double(sample)
        }
        return energy > minimumEnergy
    }

    /// Acoustic replay: far speech reflects into the microphone two frames
    /// later; a separate near voice overlaps for the last half. The test fails
    /// if the echo remains or double-talk loses the local speaker. It executes
    /// the exact production processor and rendered-reference entry point.
    static func runReplaySelfTest() -> (Bool, String) {
        if SelfTest.isRunning && CommandLine.arguments.contains(
            "--acoustic-active-reference-accounting") {
            return runActiveReferenceAccountingSelfTest()
        }
        let processor = AcousticEchoProcessor()
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 16_000,
            channels: 1, interleaved: false
        ) else { return (false, "ECHO_FAILED: no PCM format") }
        var rawEcho: Double = 0
        var cleanedEcho: Double = 0
        var rawNear: Double = 0
        var cleanedNear: Double = 0
        let totalFrames = 500
        for frame in 0..<totalFrames {
            guard let far = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 160),
                  let mic = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 160),
                  let f = far.floatChannelData?[0], let m = mic.floatChannelData?[0]
            else { return (false, "ECHO_FAILED: no PCM buffers") }
            far.frameLength = 160
            mic.frameLength = 160
            for index in 0..<160 {
                let sample = frame * 160 + index
                func signal(_ time: Int) -> Float {
                    Float(0.16 * sin(Double(time) * 2 * .pi * 277 / 16_000)
                          + 0.09 * sin(Double(time) * 2 * .pi * 631 / 16_000))
                }
                f[index] = signal(sample)
                let echo = sample >= 320 ? signal(sample - 320) * 0.45 : 0
                let near = frame >= 250
                    ? Float(0.11 * sin(Double(sample) * 2 * .pi * 419 / 16_000)) : 0
                m[index] = echo + near
            }
            processor.feedRendered(far)
            let result = processor.process(AudioChunk(buffer: mic)).buffer
            guard let cleaned = result.floatChannelData?[0] else {
                return (false, "ECHO_FAILED: no processed samples")
            }
            if frame >= 125 && frame < 245 {
                for index in 0..<160 {
                    rawEcho += Double(m[index] * m[index])
                    cleanedEcho += Double(cleaned[index] * cleaned[index])
                }
            }
            if frame >= 375 && frame < 495 {
                for index in 0..<160 {
                    rawNear += Double(m[index] * m[index])
                    cleanedNear += Double(cleaned[index] * cleaned[index])
                }
            }
        }
        let echoRatio = sqrt(cleanedEcho / max(rawEcho, 1e-12))
        let nearRatio = sqrt(cleanedNear / max(rawNear, 1e-12))
        let passed = echoRatio < 0.8 && nearRatio > 0.22
        let detail = String(format: "echo residual %.2f, double-talk output %.2f", echoRatio, nearRatio)
        return (passed, "ECHO_\(passed ? "OK" : "FAILED"): \(detail)")
    }

    /// Evaluation-only accounting probe. It deliberately uses the same
    /// production `feedRendered` and `process` entry points, but no devices,
    /// models, or synthetic route changes. The three cases catch idle source
    /// silence, a stopped graph's tail being resurrected by silence, and sparse
    /// reference underflow being counted as adaptation.
    private static func runActiveReferenceAccountingSelfTest() -> (Bool, String) {
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                         sampleRate: 16_000, channels: 1,
                                         interleaved: false) else {
            return (false, "ECHO_ACTIVE_REFERENCE_FAILED: PCM format unavailable")
        }

        func buffer(_ sample: (Int) -> Float) -> AVAudioPCMBuffer? {
            guard let result = AVAudioPCMBuffer(pcmFormat: format,
                                                frameCapacity: 160),
                  let samples = result.floatChannelData?[0] else { return nil }
            result.frameLength = 160
            for index in 0..<160 { samples[index] = sample(index) }
            return result
        }

        func rms(_ buffer: AVAudioPCMBuffer) -> Double {
            guard let samples = buffer.floatChannelData?[0] else { return 0 }
            var squares = 0.0
            for index in 0..<Int(buffer.frameLength) {
                squares += Double(samples[index] * samples[index])
            }
            return sqrt(squares / Double(max(1, Int(buffer.frameLength))))
        }

        func near(_ frame: Int) -> Float {
            let sample = frame * 160
            return Float(0.12 * sin(Double(sample) * 2 * .pi * 419 / 16_000))
        }

        // Case 1: an idle source graph emits zero placeholders for over two
        // seconds. It must not become an active reference or train the filter.
        let startup = AcousticEchoProcessor()
        var startupInput = 0.0
        var startupOutput = 0.0
        for frame in 0..<240 {
            guard let zero = buffer({ _ in 0 }),
                  let microphone = buffer({ index in
                      Float(0.12 * sin(Double(frame * 160 + index)
                                      * 2 * .pi * 419 / 16_000))
                  }) else {
                return (false, "ECHO_ACTIVE_REFERENCE_FAILED: startup buffers")
            }
            startup.feedRendered(zero)
            let inputRMS = rms(microphone)
            let output = startup.process(AudioChunk(buffer: microphone)).buffer
            if frame >= 40 {
                startupInput += inputRMS
                startupOutput += rms(output)
            }
        }
        let startupEvidence = startup.evidenceSnapshot()
        let startupReference = startup.referenceSnapshot()
        let startupAccounting = startup.activeReferenceAccountingSnapshot()
        let startupGain = startupOutput / max(startupInput, 1e-9)
        let startupPass = startupReference.frames > 32_000
            && startupAccounting.adapted == 0
            && !startupEvidence.aecProcessed && startupGain > 0.9

        // Case 2: after a real reference and stopPlayback, later zero render
        // buffers must not clear the tail or reopen the stopped graph. The
        // final near window is after the fixed tail has been consumed.
        let stopped = AcousticEchoProcessor()
        for frame in 0..<80 {
            guard let far = buffer({ index in
                let sample = frame * 160 + index
                return Float(0.16 * sin(Double(sample) * 2 * .pi * 277 / 16_000)
                           + 0.09 * sin(Double(sample) * 2 * .pi * 631 / 16_000))
            }), let microphone = buffer({ _ in 0 }) else {
                return (false, "ECHO_ACTIVE_REFERENCE_FAILED: stop buffers")
            }
            stopped.feedRendered(far)
            _ = stopped.process(AudioChunk(buffer: microphone))
        }
        stopped.stopPlayback()
        var stoppedInput = 0.0
        var stoppedOutput = 0.0
        for frame in 0..<320 {
            guard let zero = buffer({ _ in 0 }),
                  let microphone = buffer({ _ in near(frame) }) else {
                return (false, "ECHO_ACTIVE_REFERENCE_FAILED: stopped-tail buffers")
            }
            stopped.feedRendered(zero)
            let inputRMS = rms(microphone)
            let output = stopped.process(AudioChunk(buffer: microphone)).buffer
            if frame >= 80 {
                stoppedInput += inputRMS
                stoppedOutput += rms(output)
            }
        }
        let stoppedEvidence = stopped.evidenceSnapshot()
        let stoppedAccounting = stopped.activeReferenceAccountingSnapshot()
        let stoppedGain = stoppedOutput / max(stoppedInput, 1e-9)
        let stoppedPass = !stoppedEvidence.recentReference
            && stoppedAccounting.adapted <= 12_800 && stoppedGain > 0.9

        // Case 3: a sparse render stream with zero placeholders and genuine
        // queue underflow must train only on the energetic paired frames.
        let sparse = AcousticEchoProcessor()
        var sparseInput = 0.0
        var sparseOutput = 0.0
        var sparseUnderflowSeen = false
        for frame in 0..<360 {
            if frame % 6 == 0 {
                guard let far = buffer({ index in
                    let sample = frame * 160 + index
                    return Float(0.16 * sin(Double(sample) * 2 * .pi * 277 / 16_000)
                               + 0.09 * sin(Double(sample) * 2 * .pi * 631 / 16_000))
                }) else {
                    return (false, "ECHO_ACTIVE_REFERENCE_FAILED: sparse far buffer")
                }
                sparse.feedRendered(far)
            } else if frame % 6 != 5 {
                guard let zero = buffer({ _ in 0 }) else {
                    return (false, "ECHO_ACTIVE_REFERENCE_FAILED: sparse zero buffer")
                }
                sparse.feedRendered(zero)
            }
            guard let microphone = buffer({ _ in near(frame) }) else {
                return (false, "ECHO_ACTIVE_REFERENCE_FAILED: sparse mic buffer")
            }
            let inputRMS = rms(microphone)
            let output = sparse.process(AudioChunk(buffer: microphone)).buffer
            sparseUnderflowSeen = sparseUnderflowSeen
                || sparse.evidenceSnapshot().referenceUnderflow
            if frame >= 80 {
                sparseInput += inputRMS
                sparseOutput += rms(output)
            }
        }
        let sparseEvidence = sparse.evidenceSnapshot()
        let sparseAccounting = sparse.activeReferenceAccountingSnapshot()
        let sparseGain = sparseOutput / max(sparseInput, 1e-9)
        let sparsePass = sparseUnderflowSeen
            && sparseAccounting.adapted < 16_000
            && !sparseEvidence.aecProcessed && sparseGain > 0.9

        let passed = startupPass && stoppedPass && sparsePass
        let detail = String(format:
            "startup observed=%d adapted=%d gain=%.2f; stopped recent=%@ adapted=%d gain=%.2f; sparse underflow=%@ adapted=%d active=%@ gain=%.2f",
            startupReference.frames, startupAccounting.adapted, startupGain,
            stoppedEvidence.recentReference ? "true" : "false", stoppedAccounting.adapted,
            stoppedGain,
            sparseUnderflowSeen ? "true" : "false",
            sparseAccounting.adapted,
            sparseEvidence.aecProcessed ? "true" : "false", sparseGain)
        return (passed, "ECHO_ACTIVE_REFERENCE_\(passed ? "OK" : "FAILED"): \(detail)")
    }

    static func runStopTailSelfTest() -> (Bool, String) {
        let processor = AcousticEchoProcessor()
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                         sampleRate: 16_000, channels: 1,
                                         interleaved: false) else {
            return (false, "ECHO_TAIL_FAILED: PCM format unavailable")
        }
        func far(_ sample: Int) -> Float {
            guard sample >= 0, sample < 300 * 160 else { return 0 }
            return Float(0.18 * sin(Double(sample) * 2 * .pi * 317 / 16_000)
                       + 0.08 * sin(Double(sample) * 2 * .pi * 743 / 16_000))
        }
        var rawTail = 0.0
        var cleanTail = 0.0
        var nearEnergy = 0.0
        var nearOutputEnergy = 0.0
        var nearCross = 0.0
        var rawFrameEnergy = [Double](repeating: 0, count: 10)
        var cleanFrameEnergy = [Double](repeating: 0, count: 10)
        for frame in 0..<335 {
            guard let speaker = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 160),
                  let mic = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 160),
                  let output = speaker.floatChannelData?[0],
                  let input = mic.floatChannelData?[0] else {
                return (false, "ECHO_TAIL_FAILED: PCM buffers unavailable")
            }
            speaker.frameLength = 160
            mic.frameLength = 160
            if frame == 300 { processor.stopPlayback() }
            for index in 0..<160 {
                let time = frame * 160 + index
                output[index] = far(time) * 0.7
                let echo = far(time - 320) * 0.48 + far(time - 725) * 0.18
                let near: Float = frame >= 309
                    ? Float(0.12 * sin(Double(time) * 2 * .pi * 419 / 16_000)) : 0
                input[index] = echo + near
            }
            if frame < 300 { processor.feedRendered(speaker) }
            let cleaned = processor.process(AudioChunk(buffer: mic)).buffer
            guard let values = cleaned.floatChannelData?[0] else {
                return (false, "ECHO_TAIL_FAILED: missing processed microphone")
            }
            for index in 0..<160 {
                let time = frame * 160 + index
                if frame >= 300 && frame < 305 {
                    rawTail += Double(input[index] * input[index])
                }
                if frame >= 300 && frame < 310 {
                    rawFrameEnergy[frame - 300] += Double(input[index] * input[index])
                    cleanFrameEnergy[frame - 300] += Double(values[index] * values[index])
                }
                // The fixed AEC frame plus Speex overlap/add frame delay
                // shift cleaned output by exactly 320 samples. Compare the
                // same acoustic interval, not two different transient spans.
                if frame >= 302 && frame < 307 {
                    cleanTail += Double(values[index] * values[index])
                }
                if frame >= 318 && frame < 330 {
                    let near = 0.12 * sin(Double(time - 320) * 2 * .pi * 419 / 16_000)
                    nearEnergy += near * near
                    nearOutputEnergy += Double(values[index] * values[index])
                    nearCross += near * Double(values[index])
                }
            }
        }
        let erle = 10 * log10(rawTail / max(cleanTail, 1e-12))
        let correlation = nearCross / sqrt(max(nearEnergy * nearOutputEnergy, 1e-12))
        let gain = nearCross / max(nearEnergy, 1e-12)
        let passed = rawTail > 0.01 && erle >= 10
            && correlation >= 0.7 && gain >= 0.45
        let frameLevels = zip(rawFrameEnergy, cleanFrameEnergy).map {
            String(format: "%.3f/%.3f", $0, $1)
        }.joined(separator: ",")
        return (passed, String(format:
            "ECHO_TAIL_%@: post-stop echo %.1f dB ERLE, near correlation %.2f, gain %.2f; frames raw/clean %@",
            passed ? "OK" : "FAILED", erle, correlation, gain, frameLevels))
    }

    static func runSpeechReplaySelfTest(farURL: URL, nearURL: URL) -> (Bool, String) {
        do {
            let far = try AudioConversion.monoSamples(fromFileAt: farURL, sampleRate: 16_000)
            let near = try AudioConversion.monoSamples(fromFileAt: nearURL, sampleRate: 16_000)
            guard far.count >= 96_000, near.count >= 96_000,
                  let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                             sampleRate: 16_000, channels: 1,
                                             interleaved: false) else {
                return (false, "ECHO_SPEECH_FAILED: speech files must be at least six seconds")
            }
            let processor = AcousticEchoProcessor()
            let frames = min(far.count, near.count) / 160
            var echoEnergy = 0.0
            var residualEnergy = 0.0
            var nearEnergy = 0.0
            var nearOutputEnergy = 0.0
            var nearCross = 0.0
            var inputEchoEnergy = 0.0
            for frame in 0..<frames {
                guard let render = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 160),
                      let microphone = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 160),
                      let output = render.floatChannelData?[0],
                      let input = microphone.floatChannelData?[0]
                else { return (false, "ECHO_SPEECH_FAILED: buffer allocation") }
                render.frameLength = 160
                microphone.frameLength = 160
                let halfway = frames / 2
                for index in 0..<160 {
                    let time = frame * 160 + index
                    output[index] = far[time] * 0.65
                    // Multi-tap speaker→room→microphone impulse response.
                    let echo = (time >= 320 ? far[time - 320] * 0.28 : 0)
                        + (time >= 571 ? far[time - 571] * 0.16 : 0)
                        + (time >= 1_083 ? far[time - 1_083] * 0.08 : 0)
                    input[index] = echo + (frame >= halfway ? near[time] * 0.55 : 0)
                }
                processor.feedRendered(render)
                let cleaned = processor.process(AudioChunk(buffer: microphone)).buffer
                guard let processed = cleaned.floatChannelData?[0] else {
                    return (false, "ECHO_SPEECH_FAILED: processed output missing")
                }
                // The cold-start raw preservation lasts the first second and
                // crosses to learned AEC over the second. Score the converged
                // far-only segment; the separate early test scores cold speech.
                guard frame >= max(210, frames / 4) else { continue }
                for index in 0..<160 {
                    let time = frame * 160 + index
                    if frame < halfway {
                        echoEnergy += Double(input[index] * input[index])
                        residualEnergy += Double(processed[index] * processed[index])
                    } else {
                        // AEC framing and Speex's spectral overlap/add
                        // postfilter each contribute one 160-sample frame.
                        let nearSample = Double(near[time - 320]) * 0.55
                        nearEnergy += nearSample * nearSample
                        nearOutputEnergy += Double(processed[index] * processed[index])
                        nearCross += Double(processed[index]) * nearSample
                        inputEchoEnergy += Double(input[index] * input[index])
                    }
                }
            }
            let erle = 10 * log10(echoEnergy / max(residualEnergy, 1e-12))
            let correlation = nearCross / sqrt(max(nearEnergy * nearOutputEnergy, 1e-12))
            let nearGain = nearCross / max(nearEnergy, 1e-12)
            let passed = erle >= 15 && correlation >= 0.7 && nearGain >= 0.45
                && nearOutputEnergy > inputEchoEnergy * 0.08
            return (passed, String(format:
                "ECHO_SPEECH_%@: echo ERLE %.1f dB, near correlation %.2f, near gain %.2f",
                passed ? "OK" : "FAILED", erle, correlation, nearGain))
        } catch {
            return (false, "ECHO_SPEECH_FAILED: \(error.localizedDescription)")
        }
    }

    /// AEC3 evaluation-only replay. Measure a *separate near-only* processor's
    /// fixed latency first, then use that exact lag for the mixed speech gate.
    /// There is no best-lag optimization against the double-talk output.
    static func runAEC3SpeechReplaySelfTest(farURL: URL, nearURL: URL) -> (Bool, String) {
        do {
            let far = try AudioConversion.monoSamples(fromFileAt: farURL, sampleRate: 16_000)
            let near = try AudioConversion.monoSamples(fromFileAt: nearURL, sampleRate: 16_000)
            let frames = min(far.count, near.count) / 160
            guard frames >= 600,
                  let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                             sampleRate: 16_000, channels: 1,
                                             interleaved: false) else {
                return (false, "ECHO_AEC3_SPEECH_FAILED: six-second far/near WAVs required")
            }
            func buffer(_ samples: [Float]) -> AVAudioPCMBuffer? {
                guard let result = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 160),
                      let output = result.floatChannelData?[0] else { return nil }
                result.frameLength = 160
                for index in 0..<160 { output[index] = samples[index] }
                return result
            }
            let nearOnly = AcousticEchoProcessor()
            guard nearOnly.backendName == "aec3-evaluation", nearOnly.backendAvailable else {
                return (false, "ECHO_AEC3_SPEECH_FAILED: AEC3 evaluation bridge unavailable")
            }
            var isolated = [Float]()
            for frame in 0..<min(frames, 400) {
                guard let silentFar = buffer([Float](repeating: 0, count: 160)),
                      let mic = buffer((0..<160).map { near[frame * 160 + $0] * 0.55 })
                else { return (false, "ECHO_AEC3_SPEECH_FAILED: near-only PCM") }
                // Run the *same* AEC3 reverse-stream schedule as the mixed
                // experiment. Omitting it changes the engine's internal
                // capture latency, producing a deceptively perfect but wrong
                // near-only lag for double-talk comparison.
                nearOnly.feedRendered(silentFar)
                let outputBuffer = nearOnly.process(AudioChunk(buffer: mic)).buffer
                guard let output = outputBuffer.floatChannelData?[0] else {
                    return (false, "ECHO_AEC3_SPEECH_FAILED: near-only output")
                }
                isolated.append(contentsOf: (0..<160).map { output[$0] })
            }
            let lo = 8_000
            let hi = min(isolated.count - 480, 48_000)
            guard hi > lo else { return (false, "ECHO_AEC3_SPEECH_FAILED: near-only interval") }
            let isolatedEnergy = (lo..<hi).reduce(0.0) {
                $0 + Double(isolated[$1] * isolated[$1])
            }
            let latency = (0...480).max { a, b in
                func score(_ lag: Int) -> Double {
                    (lo..<hi).reduce(0.0) {
                        $0 + Double(isolated[$1] * near[$1 - lag])
                    }
                }
                return score(a) < score(b)
            } ?? 0
            let nearSourceEnergy = (lo..<hi).reduce(0.0) {
                $0 + pow(Double(near[$1 - latency]) * 0.55, 2)
            }
            let nearOnlyGain = (lo..<hi).reduce(0.0) {
                $0 + Double(isolated[$1] * near[$1 - latency]) * 0.55
            } / max(nearSourceEnergy, 1e-12)
            let nearOnlyCorrelation = nearOnlyGain * sqrt(nearSourceEnergy
                / max(isolatedEnergy, 1e-12))

            func onset(_ samples: [Float]) -> Int {
                for index in stride(from: 0, through: samples.count - 320, by: 160) {
                    let energy = samples[index..<(index + 320)].reduce(0.0) {
                        $0 + Double($1 * $1)
                    }
                    if sqrt(energy / 320) > 0.025 { return index }
                }
                return 0
            }
            let farStart = onset(far)
            let nearStart = onset(near)
            guard far.count >= farStart + 16_000, near.count >= nearStart + 16_000 else {
                return (false, "ECHO_AEC3_SPEECH_FAILED: early spoken onset unavailable")
            }
            let early = AcousticEchoProcessor()
            var firstIndependentFrame: Int?
            var earlyEnergy = 0.0
            var earlyOutput = 0.0
            var earlyCross = 0.0
            for frame in 0..<100 {
                let time = frame * 160
                let rendered = (0..<160).map { far[farStart + time + $0] * 0.65 }
                let micSamples: [Float] = (0..<160).map { index in
                    let sample = time + index
                    let echo = sample >= 320
                        ? far[farStart + sample - 320] * 0.28 : 0
                    return echo + near[nearStart + sample] * 0.55
                }
                guard let speaker = buffer(rendered), let mic = buffer(micSamples) else {
                    return (false, "ECHO_AEC3_SPEECH_FAILED: early PCM")
                }
                early.feedRendered(speaker)
                let result = early.process(AudioChunk(buffer: mic)).buffer
                if firstIndependentFrame == nil,
                   early.evidenceSnapshot().independentNearCandidate {
                    firstIndependentFrame = frame
                }
                guard let output = result.floatChannelData?[0] else {
                    return (false, "ECHO_AEC3_SPEECH_FAILED: early output")
                }
                if frame >= 4 && frame < 14 {
                    for index in 0..<160 {
                        let sample = time + index - latency
                        let voice = Double(near[nearStart + sample]) * 0.55
                        earlyEnergy += voice * voice
                        earlyOutput += Double(output[index] * output[index])
                        earlyCross += voice * Double(output[index])
                    }
                }
            }
            let earlyCorrelation = earlyCross
                / sqrt(max(earlyEnergy * earlyOutput, 1e-12))
            let earlyGain = earlyCross / max(earlyEnergy, 1e-12)

            let processor = AcousticEchoProcessor()
            var rawEcho = 0.0
            var cleanedEcho = 0.0
            var nearEnergy = 0.0
            var nearOutput = 0.0
            var nearCross = 0.0
            for frame in 0..<frames {
                let time = frame * 160
                let rendered = (0..<160).map { far[time + $0] * 0.65 }
                let micSamples: [Float] = (0..<160).map { index in
                    let sample = time + index
                    let echo = (sample >= 320 ? far[sample - 320] * 0.28 : 0)
                        + (sample >= 571 ? far[sample - 571] * 0.16 : 0)
                        + (sample >= 1_083 ? far[sample - 1_083] * 0.08 : 0)
                    return echo + (frame >= frames / 2 ? near[sample] * 0.55 : 0)
                }
                guard let speaker = buffer(rendered), let microphone = buffer(micSamples) else {
                    return (false, "ECHO_AEC3_SPEECH_FAILED: mixed PCM")
                }
                processor.feedRendered(speaker)
                let result = processor.process(AudioChunk(buffer: microphone)).buffer
                guard let output = result.floatChannelData?[0] else {
                    return (false, "ECHO_AEC3_SPEECH_FAILED: mixed output")
                }
                for index in 0..<160 {
                    let sample = time + index
                    if frame >= 220 && frame < frames / 2 - 20 {
                        rawEcho += Double(micSamples[index] * micSamples[index])
                        cleanedEcho += Double(output[index] * output[index])
                    } else if frame >= frames / 2 + 30 {
                        let voice = Double(near[sample - latency]) * 0.55
                        nearEnergy += voice * voice
                        nearOutput += Double(output[index] * output[index])
                        nearCross += voice * Double(output[index])
                    }
                }
            }
            let erle = 10 * log10(rawEcho / max(cleanedEcho, 1e-12))
            let correlation = nearCross / sqrt(max(nearEnergy * nearOutput, 1e-12))
            let gain = nearCross / max(nearEnergy, 1e-12)
            let passed = rawEcho > 0.01 && nearEnergy > 0.05
                && erle >= 15 && nearOnlyCorrelation >= 0.90
                && nearOnlyGain >= 0.70 && correlation >= 0.70 && gain >= 0.45
                && earlyEnergy > 0.05 && earlyCorrelation >= 0.70
                && earlyGain >= 0.45 && (firstIndependentFrame ?? 999) <= 10
            return (passed, String(format:
                "ECHO_AEC3_SPEECH_%@: fixed near-only lag %d samples; echo %.1f dB ERLE; near-only corr %.2f/gain %.2f; double-talk corr %.2f/gain %.2f; first100ms corr %.2f/gain %.2f, candidate %dms",
                passed ? "OK" : "FAILED", latency, erle,
                nearOnlyCorrelation, nearOnlyGain, correlation, gain,
                earlyCorrelation, earlyGain, (firstIndependentFrame ?? 999) * 10))
        } catch {
            return (false, "ECHO_AEC3_SPEECH_FAILED: \(error.localizedDescription)")
        }
    }

    /// Regression for SpeechAnalyzer choosing 16 kHz signed 16-bit input.
    /// Equal rate and channel count must not bypass Float32 Speex processing.
    static func runInt16ReplaySelfTest(farURL: URL) -> (Bool, String) {
        do {
            let far = try AudioConversion.monoSamples(fromFileAt: farURL, sampleRate: 16_000)
            guard far.count >= 80_000,
                  let floatFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                                  sampleRate: 16_000, channels: 1,
                                                  interleaved: false),
                  let intFormat = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                                sampleRate: 16_000, channels: 1,
                                                interleaved: false) else {
                return (false, "ECHO_INT16_FAILED: 5-second WAV or PCM formats unavailable")
            }
            let processor = AcousticEchoProcessor()
            var raw = 0.0
            var clean = 0.0
            var convertedFrames = 0
            for frame in 0..<min(far.count / 160, 500) {
                guard let render = AVAudioPCMBuffer(pcmFormat: floatFormat, frameCapacity: 160),
                      let microphone = AVAudioPCMBuffer(pcmFormat: intFormat, frameCapacity: 160),
                      let speaker = render.floatChannelData?[0],
                      let input = microphone.int16ChannelData?[0] else {
                    return (false, "ECHO_INT16_FAILED: buffer allocation")
                }
                render.frameLength = 160
                microphone.frameLength = 160
                for index in 0..<160 {
                    let time = frame * 160 + index
                    speaker[index] = far[time] * 0.65
                    let echo = (time >= 320 ? far[time - 320] * 0.28 : 0)
                        + (time >= 571 ? far[time - 571] * 0.16 : 0)
                        + (time >= 1_083 ? far[time - 1_083] * 0.08 : 0)
                    input[index] = pcm16(echo)
                }
                processor.feedRendered(render)
                let result = processor.process(AudioChunk(buffer: microphone)).buffer
                guard result.format.commonFormat == .pcmFormatInt16,
                      result.frameLength == 160,
                      let output = result.int16ChannelData?[0] else {
                    return (false, "ECHO_INT16_FAILED: processed format or frame count changed")
                }
                convertedFrames += Int(result.frameLength)
                if frame >= 240 {
                    for index in 0..<160 {
                        raw += pow(Double(input[index]) / 32768, 2)
                        clean += pow(Double(output[index]) / 32768, 2)
                    }
                }
            }
            let erle = 10 * log10(raw / max(clean, 1e-12))
            let passed = raw > 0.01 && convertedFrames == 80_000 && erle >= 10
            return (passed, String(format:
                "ECHO_INT16_%@: %.1f dB ERLE, %d converted samples",
                passed ? "OK" : "FAILED", erle, convertedFrames))
        } catch {
            return (false, "ECHO_INT16_FAILED: \(error.localizedDescription)")
        }
    }

    /// Cold first answer with no near speaker: acoustic echo must be removed
    /// before the one-second learned-filter clock matures. Otherwise the
    /// warm-up strategy merely protects barge-in by leaking the whole reply.
    static func runColdFarOnlySelfTest(farURL: URL) -> (Bool, String) {
        do {
            let far = try AudioConversion.monoSamples(fromFileAt: farURL, sampleRate: 16_000)
            guard far.count >= 32_000,
                  let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                             sampleRate: 16_000, channels: 1,
                                             interleaved: false) else {
                return (false, "ECHO_COLD_FAILED: two-second far WAV required")
            }
            let processor = AcousticEchoProcessor()
            var raw = 0.0
            var cleaned = 0.0
            var falseNearChunks = 0
            for frame in 0..<150 {
                guard let speaker = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 160),
                      let mic = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 160),
                      let rendered = speaker.floatChannelData?[0],
                      let input = mic.floatChannelData?[0] else {
                    return (false, "ECHO_COLD_FAILED: PCM buffers unavailable")
                }
                speaker.frameLength = 160
                mic.frameLength = 160
                for index in 0..<160 {
                    let time = frame * 160 + index
                    rendered[index] = far[time] * 0.65
                    input[index] = (time >= 320 ? far[time - 320] * 0.28 : 0)
                        + (time >= 571 ? far[time - 571] * 0.16 : 0)
                        + (time >= 1_083 ? far[time - 1_083] * 0.08 : 0)
                }
                processor.feedRendered(speaker)
                let output = processor.process(AudioChunk(buffer: mic)).buffer
                if processor.evidenceSnapshot().independentNearCandidate {
                    falseNearChunks += 1
                }
                guard let values = output.floatChannelData?[0] else {
                    return (false, "ECHO_COLD_FAILED: output unavailable")
                }
                if frame >= 10 && frame < 100 {
                    for index in 0..<160 {
                        raw += Double(input[index] * input[index])
                    }
                }
                if frame >= 12 && frame < 102 {
                    for index in 0..<160 {
                        cleaned += Double(values[index] * values[index])
                    }
                }
            }
            let erle = 10 * log10(raw / max(cleaned, 1e-12))
            let passed = raw > 0.01 && erle >= 8 && falseNearChunks == 0
            return (passed, String(format:
                "ECHO_COLD_%@: first-second ERLE %.1f dB, false-near %d chunks",
                passed ? "OK" : "FAILED", erle, falseNearChunks))
        } catch {
            return (false, "ECHO_COLD_FAILED: \(error.localizedDescription)")
        }
    }

    /// First-100-ms barge-in pressure test. Unlike the longer replay, the
    /// canceller has no seconds of far-only speech in which to adapt before a
    /// separate near speaker arrives. It judges preservation of the near voice
    /// early, not echo ERLE (the room filter has not converged yet).
    static func runEarlyDoubleTalkSelfTest(farURL: URL, nearURL: URL) -> (Bool, String) {
        do {
            let far = try AudioConversion.monoSamples(fromFileAt: farURL, sampleRate: 16_000)
            let near = try AudioConversion.monoSamples(fromFileAt: nearURL, sampleRate: 16_000)
            func onset(_ samples: [Float]) -> Int {
                guard samples.count > 8_000 else { return 0 }
                for index in stride(from: 0, through: samples.count - 320, by: 160) {
                    let rms = sqrt(samples[index..<(index + 320)].reduce(0.0) {
                        $0 + Double($1 * $1)
                    } / 320)
                    if rms > 0.025 { return index }
                }
                return 0
            }
            let farStart = onset(far)
            let nearStart = onset(near)
            guard far.count > farStart + 20_000, near.count > nearStart + 20_000,
                  let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                             sampleRate: 16_000, channels: 1,
                                             interleaved: false) else {
                return (false, "ECHO_EARLY_FAILED: insufficient spoken PCM")
            }
            let processor = AcousticEchoProcessor()
            var nearEnergy = 0.0
            var outputEnergy = 0.0
            var cross = 0.0
            var firstIndependentFrame: Int?
            for frame in 0..<100 {
                guard let speaker = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 160),
                      let mic = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 160),
                      let f = speaker.floatChannelData?[0],
                      let m = mic.floatChannelData?[0] else {
                    return (false, "ECHO_EARLY_FAILED: no buffers")
                }
                speaker.frameLength = 160
                mic.frameLength = 160
                for index in 0..<160 {
                    let time = frame * 160 + index
                    f[index] = far[farStart + time] * 0.65
                    let echo = time >= 320 ? far[farStart + time - 320] * 0.28 : 0
                    m[index] = echo + near[nearStart + time] * 0.55
                }
                processor.feedRendered(speaker)
                let cleaned = processor.process(AudioChunk(buffer: mic)).buffer
                if firstIndependentFrame == nil,
                   processor.evidenceSnapshot().independentNearCandidate {
                    firstIndependentFrame = frame
                }
                guard let values = cleaned.floatChannelData?[0] else {
                    return (false, "ECHO_EARLY_FAILED: no processed samples")
                }
                // Frames4–13 are the first 100ms of near speech after the
                // fixed 2-frame DSP latency. No best-lag fit is performed.
                if frame >= 4 && frame < 14 {
                    for index in 0..<160 {
                        let time = frame * 160 + index - 320
                        let nearSample = Double(near[nearStart + time]) * 0.55
                        nearEnergy += nearSample * nearSample
                        outputEnergy += Double(values[index] * values[index])
                        cross += Double(values[index]) * nearSample
                    }
                }
            }
            let correlation = cross / sqrt(max(nearEnergy * outputEnergy, 1e-12))
            let gain = cross / max(nearEnergy, 1e-12)
            let passed = nearEnergy > 0.05 && correlation >= 0.7 && gain >= 0.45
                && (firstIndependentFrame ?? 999) <= 10
            return (passed, String(format:
                "ECHO_EARLY_%@: first 100ms near correlation %.2f, gain %.2f, independent at %dms",
                passed ? "OK" : "FAILED", correlation, gain,
                (firstIndependentFrame ?? 999) * 10))
        } catch {
            return (false, "ECHO_EARLY_FAILED: \(error.localizedDescription)")
        }
    }

    /// Real speech stop-tail fixture. The older sine-wave stress probe remains
    /// separate: its 6 dB transient is an unresolved limit, not a green gate.
    /// This compares the same acoustic samples after the exact two-frame
    /// wrapper+Speex latency and checks a distinct spoken near voice after stop.
    static func runSpeechTailSelfTest(farURL: URL, nearURL: URL) -> (Bool, String) {
        do {
            let far = try AudioConversion.monoSamples(fromFileAt: farURL, sampleRate: 16_000)
            let near = try AudioConversion.monoSamples(fromFileAt: nearURL, sampleRate: 16_000)
            let totalFrames = far.count / 160
            guard totalFrames > 650, near.count > 8_000,
                  let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                             sampleRate: 16_000, channels: 1,
                                             interleaved: false) else {
                return (false, "ECHO_SPEECH_TAIL_FAILED: fixtures too short")
            }
            let upper = min(600, totalFrames - 40)
            let stop = (250..<upper).max { left, right in
                func energy(_ frame: Int) -> Double {
                    far[((frame - 5) * 160)..<(frame * 160)].reduce(0.0) {
                        $0 + Double($1 * $1)
                    }
                }
                return energy(left) < energy(right)
            } ?? 350
            let nearStart = stride(from: 0, through: near.count - 320, by: 160)
                .first(where: { index in
                    sqrt(near[index..<(index + 320)].reduce(0.0) {
                        $0 + Double($1 * $1)
                    } / 320) > 0.025
                }) ?? 0
            guard near.count > nearStart + 4_500 else {
                return (false, "ECHO_SPEECH_TAIL_FAILED: near voice too short")
            }
            let processor = AcousticEchoProcessor()
            var rawEcho = 0.0
            var cleanEcho = 0.0
            var nearEnergy = 0.0
            var nearOutput = 0.0
            var nearCross = 0.0
            for frame in 0..<(stop + 35) {
                guard let render = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 160),
                      let mic = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 160),
                      let speaker = render.floatChannelData?[0],
                      let input = mic.floatChannelData?[0] else {
                    return (false, "ECHO_SPEECH_TAIL_FAILED: PCM allocation")
                }
                render.frameLength = 160
                mic.frameLength = 160
                if frame == stop { processor.stopPlayback() }
                for index in 0..<160 {
                    let time = frame * 160 + index
                    speaker[index] = frame < stop ? far[time] * 0.65 : 0
                    var echo: Float = 0
                    let reflections: [(Int, Float)] = [(320, 0.28), (571, 0.16), (1_083, 0.08)]
                    for (delay, gain) in reflections {
                        if time >= delay && time - delay < stop * 160 {
                            echo += far[time - delay] * gain
                        }
                    }
                    let nearIndex = nearStart + time - (stop + 9) * 160
                    let voice = frame >= stop + 9 && nearIndex >= 0
                        && nearIndex < near.count ? near[nearIndex] * 0.55 : 0
                    input[index] = echo + voice
                }
                if frame < stop { processor.feedRendered(render) }
                let cleaned = processor.process(AudioChunk(buffer: mic)).buffer
                guard let values = cleaned.floatChannelData?[0] else {
                    return (false, "ECHO_SPEECH_TAIL_FAILED: no output")
                }
                for index in 0..<160 {
                    if frame >= stop && frame < stop + 5 {
                        rawEcho += Double(input[index] * input[index])
                    }
                    if frame >= stop + 2 && frame < stop + 7 {
                        cleanEcho += Double(values[index] * values[index])
                    }
                    if frame >= stop + 18 && frame < stop + 30 {
                        let source = nearStart + (frame - stop - 11) * 160 + index
                        let voice = Double(near[source]) * 0.55
                        nearEnergy += voice * voice
                        nearOutput += Double(values[index] * values[index])
                        nearCross += voice * Double(values[index])
                    }
                }
            }
            let erle = 10 * log10(rawEcho / max(cleanEcho, 1e-12))
            let correlation = nearCross / sqrt(max(nearEnergy * nearOutput, 1e-12))
            let gain = nearCross / max(nearEnergy, 1e-12)
            let passed = rawEcho > 0.01 && nearEnergy > 0.05
                && erle >= 10 && correlation >= 0.7 && gain >= 0.45
            return (passed, String(format:
                "ECHO_SPEECH_TAIL_%@: echo %.1f dB ERLE, near correlation %.2f, gain %.2f",
                passed ? "OK" : "FAILED", erle, correlation, gain))
        } catch {
            return (false, "ECHO_SPEECH_TAIL_FAILED: \(error.localizedDescription)")
        }
    }
}
