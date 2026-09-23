import AVFoundation
import CoreMedia
import Foundation

// MARK: - Long-form audio (roadmap §8.3, Option B)

/// Text → one audio file on disk. Nothing else.
///
/// The live voice path (`AgentSpeechSynthesizer`, `AgentPCMRenderer`, the dictation
/// audio session) deliberately caps a spoken reply at a few hundred characters and
/// enqueues it for immediate playback. This renderer is the other path the decision
/// asked for: a whole script, synthesized offline, written to a file, played only when
/// the user asks for it. The two paths must never meet, so the guarantees below are
/// load-bearing, and each one is structural rather than a convention:
///
/// - **File sink only.** This file contains no `AVAudioEngine`, no `AVAudioPlayerNode`,
///   no `AVAudioPlayer`, no reference to `AgentSpeechSynthesizer` or `AgentPCMRenderer`,
///   and never touches `AVAudioSession`. Its only audio input is the injected
///   `Synthesis` closure; its only output is the file it is handed a directory for.
///   `PodcastSelfTest` asserts the live graph is idle across a render.
/// - **It never plays anything.** There is no playback call in the file to reach.
/// - **It yields.** Before the first clause and between clauses it waits for the same
///   things the routine runner waits for — a meeting or dictation, the ASR lane, the
///   notes lane — and for any in-flight dictation cleanup pass, with an honest
///   `.busy` error after `Limits.yieldTimeout` rather than rendering through them.
/// - **Atomic.** Every byte is written to a staging file on the destination's own
///   volume; the destination is never opened, truncated or replaced until the whole
///   file encoded and closed. A failure (disk full, cancellation, encoder refusal)
///   removes the staging file and leaves any previous edition exactly as it was.
/// - **Bounded memory.** Chunks are appended as they are synthesized and dropped; the
///   renderer holds one clause at a time plus counters. A script longer than
///   `Limits.maxDuration` stops with `.tooLong` instead of growing without bound.
///
/// Concurrent renders are not a thing here: one routine runs at a time, and the
/// `AgentScheduler` pass chain already serializes runs. The renderer therefore makes
/// no claim about two calls at once against one directory.
@MainActor
final class LongFormRenderer {
    // MARK: - Types

    enum Container: String, Sendable, Equatable {
        /// Preferred: one AAC track in an `.m4a`, a fraction of WAV's size.
        case m4a
        /// Fallback when the AAC encoder refuses. Same audio, no compression.
        case wav

        var fileExtension: String { rawValue }
    }

    /// One synthesized clause. The sample rate is the engine's own — 24 kHz for both
    /// Pocket and Kokoro — and must not change mid-script.
    struct Audio: Sendable, Equatable {
        var samples: [Float]
        var sampleRate: Double
    }

    /// What one clause asks the voice for. `speaker` is the script's host label
    /// (`LongFormScript.hostA` / `.hostB`) when the line has one, so a two-voice
    /// engine can pick a different voice per host.
    struct SynthesisRequest: Sendable, Equatable {
        var text: String
        var speaker: String?
    }

    /// The seam the self-test injects through. Production is
    /// `LongFormSynthesisFactory.live()`; the renderer cannot tell them apart, which is
    /// the point — every sample it writes came from this closure.
    typealias Synthesis = @MainActor (SynthesisRequest) async throws -> Audio

    /// One chapter mark: the heading and where its section starts in the file.
    struct Chapter: Sendable, Equatable {
        var title: String
        var start: TimeInterval
    }

    /// A finished file and what a Library item needs to show it.
    struct RenderedFile: Sendable, Equatable {
        var url: URL
        var duration: TimeInterval
        var chapters: [Chapter]
        var container: Container
        var byteCount: Int
    }

    struct Limits: Sendable, Equatable {
        /// Twenty minutes of speech is far past a morning briefing and keeps the WAV
        /// fallback's eventual size honest. A longer script is an error, not a bigger file.
        var maxDuration: TimeInterval = 20 * 60
        /// How long to wait for a recording, the ASR lane or the notes lane to clear.
        var yieldTimeout: TimeInterval = 10 * 60
        var yieldPoll: TimeInterval = 2
    }

    // MARK: - Storage

    /// `<Application Support>/Next Notes/Library` — the app-owned Library the naming
    /// map (§8.3) promises. Audio lives one level deeper so the Library can hold other
    /// kinds of prepared things later without moving anything.
    ///
    /// The Library surface reads `audioDirectory` for its rows: an item is the file, the
    /// title before the `yyyy-MM-dd` stamp in its name, and the duration returned by
    /// `render` (also recorded on the run's `AgentTask` as an artifact URL). Nothing
    /// here is published, uploaded or played automatically; deleting a file deletes the
    /// item.
    static var libraryRoot: URL {
        AppIdentity.applicationSupportDirectory.appendingPathComponent("Library", isDirectory: true)
    }

    static var audioDirectory: URL {
        libraryRoot.appendingPathComponent("Audio", isDirectory: true)
    }

    let directory: URL
    let container: Container
    let synthesis: Synthesis
    let environment: any LongFormRenderingEnvironment
    var limits: Limits
    /// Fraction complete, by clause count. Never called with a value above 1.
    var onProgress: ((Double) -> Void)?

    init(
        directory: URL,
        container: Container,
        synthesis: @escaping Synthesis,
        environment: any LongFormRenderingEnvironment,
        limits: Limits = Limits(),
        onProgress: ((Double) -> Void)? = nil
    ) {
        self.directory = directory
        self.container = container
        self.synthesis = synthesis
        self.environment = environment
        self.limits = limits
        self.onProgress = onProgress
    }

    /// The production renderer: the app's Library, AAC, the live voice engines, and the
    /// live yield probes.
    static func live() -> LongFormRenderer {
        LongFormRenderer(
            directory: audioDirectory,
            container: .m4a,
            synthesis: LongFormSynthesisFactory.live(),
            environment: LiveLongFormEnvironment())
    }

    // MARK: - Rendering

    /// Renders the whole script and returns the file that now exists at its
    /// deterministic name: `<title> <edition>.<extension>`.
    ///
    /// A second run for the same edition replaces the previous file atomically. `.m4a`
    /// is attempted first when asked for; if the AAC encoder refuses the session, the
    /// same audio is written as a WAV instead and `RenderedFile.container` says so.
    func render(_ script: LongFormScript, title: String, edition: String) async throws -> RenderedFile {
        guard script.clauseCount > 0 else { throw LongFormRenderError.emptyScript }
        do {
            return try await renderOnce(script, title: title, edition: edition, container: container)
        } catch let error as LongFormRenderError {
            guard container == .m4a, error.isEncoderRefusal else { throw error }
            // The AAC encoder is the only thing that can fail this way, and the decision
            // accepts WAV. Everything else — disk full, busy, cancellation — propagates.
            Log.agent.error("long-form m4a encode refused, falling back to wav: \(error.localizedDescription, privacy: .public)")
            return try await renderOnce(script, title: title, edition: edition, container: .wav)
        }
    }

    private func renderOnce(
        _ script: LongFormScript, title: String, edition: String, container: Container
    ) async throws -> RenderedFile {
        let staging: URL
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            // `.itemReplacementDirectory` is on the destination's own volume, which is what
            // makes the final move a rename rather than a copy, and therefore atomic.
            staging = try FileManager.default.url(
                for: .itemReplacementDirectory, in: .userDomainMask,
                appropriateFor: directory, create: true)
        } catch {
            throw Self.classify(error)
        }
        defer { try? FileManager.default.removeItem(at: staging) }
        let destination = directory.appendingPathComponent(
            Self.fileName(title: title, edition: edition, container: container))
        let temporary = staging.appendingPathComponent(destination.lastPathComponent)

        do {
            let written = try await write(script, to: temporary, container: container)
            try Self.place(temporary, at: destination)
            try? FileManager.default.removeItem(at: staging)
            return RenderedFile(
                url: destination, duration: written.duration, chapters: written.chapters,
                container: container, byteCount: written.byteCount)
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw Self.classify(error)
        }
    }

    private func write(
        _ script: LongFormScript, to url: URL, container: Container
    ) async throws -> (duration: TimeInterval, chapters: [Chapter], byteCount: Int) {
        try await waitForQuietLane()
        guard let firstClause = script.sections.first?.clauses.first else {
            throw LongFormRenderError.emptyScript
        }
        // The first clause establishes the sample rate: the writer's header and the
        // duration math both need it before anything is created on disk.
        let firstAudio = try await synthesis(SynthesisRequest(text: firstClause.text, speaker: firstClause.speaker))
        guard !firstAudio.samples.isEmpty, firstAudio.sampleRate > 0 else {
            throw LongFormRenderError.noAudio
        }
        let rate = firstAudio.sampleRate
        let writer: any LongFormFileWriter
        switch container {
        case .m4a:
            writer = try M4AAudioFileWriter(url: url, sampleRate: rate)
        case .wav:
            writer = try WAVAudioFileWriter(url: url, sampleRate: rate)
        }

        var totalFrames = 0
        var servedClauses = 0
        var chapters: [Chapter] = []
        do {
            for section in script.sections {
                if !section.title.isEmpty {
                    chapters.append(Chapter(title: section.title, start: Double(totalFrames) / rate))
                }
                for clause in section.clauses {
                    try Task.checkCancellation()
                    let audio: Audio
                    if servedClauses == 0 {
                        audio = firstAudio
                    } else {
                        try await waitForQuietLane()
                        audio = try await synthesis(SynthesisRequest(text: clause.text, speaker: clause.speaker))
                    }
                    guard !audio.samples.isEmpty else { throw LongFormRenderError.noAudio }
                    guard audio.sampleRate == rate else {
                        throw LongFormRenderError.inconsistentSampleRate(expected: rate, got: audio.sampleRate)
                    }
                    try await writer.append(audio.samples)
                    totalFrames += audio.samples.count
                    guard Double(totalFrames) / rate <= limits.maxDuration else {
                        throw LongFormRenderError.tooLong(limit: limits.maxDuration)
                    }
                    servedClauses += 1
                    onProgress?(Double(servedClauses) / Double(script.clauseCount))
                }
            }
            let byteCount = try await writer.finish()
            return (Double(totalFrames) / rate, chapters, byteCount)
        } catch {
            writer.abort()
            throw error
        }
    }

    /// Waits for a clear machine: no meeting or dictation, both compute lanes idle,
    /// no dictation cleanup in flight. Called before the first clause and between
    /// clauses, so a recording that starts mid-render pauses the work instead of
    /// fighting it for the machine or the microphone.
    private func waitForQuietLane() async throws {
        let deadline = Date().addingTimeInterval(limits.yieldTimeout)
        // The awaits cannot live inside a `||` autoclosure, so the probes are hoisted.
        while true {
            let asrBusy = await environment.isASRLaneBusy()
            let notesBusy = await environment.isNotesLaneBusy()
            if !environment.isRecording, !asrBusy, !notesBusy { break }
            try Task.checkCancellation()
            guard Date() < deadline else {
                throw LongFormRenderError.busy(waited: limits.yieldTimeout)
            }
            try await Task.sleep(for: .seconds(limits.yieldPoll))
        }
        // The one-directional cleanup gate: a dictation cleanup pass holds the model the
        // voice load would otherwise race. Returns immediately when nothing is running.
        await environment.awaitCleanupIdle()
    }

    // MARK: - Placement and errors

    static func fileName(title: String, edition: String, container: Container) -> String {
        let safe = title
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return "\(safe) \(edition).\(container.fileExtension)"
    }

    /// Atomic placement: replace when an edition already exists, move when it does not.
    /// A failed replace leaves the previous file untouched — the never-truncate rule.
    private static func place(_ temporary: URL, at destination: URL) throws {
        if FileManager.default.fileExists(atPath: destination.path) {
            _ = try FileManager.default.replaceItemAt(destination, withItemAt: temporary)
        } else {
            try FileManager.default.moveItem(at: temporary, to: destination)
        }
    }

    /// Normalizes whatever Foundation threw into the two cases a person can act on:
    /// no room on the disk, or something else. A `LongFormRenderError` passes through.
    @discardableResult
    nonisolated static func classify(_ error: Error) -> Error {
        if error is LongFormRenderError || error is CancellationError { return error }
        let ns = error as NSError
        if ns.domain == NSCocoaErrorDomain, ns.code == CocoaError.Code.fileWriteOutOfSpace.rawValue {
            return LongFormRenderError.diskFull
        }
        if ns.domain == NSPOSIXErrorDomain, ns.code == Int(ENOSPC) {
            return LongFormRenderError.diskFull
        }
        return LongFormRenderError.writeFailed(ns.localizedDescription)
    }
}

/// What went wrong, in the renderer's own words. `PodcastTemplate` turns these into
/// sentences; the renderer never talks to the user itself.
enum LongFormRenderError: LocalizedError, Equatable {
    /// Neither offline voice engine is available. Never triggers a download: the
    /// model is fetched because the user asked for it in Settings, not at 06:00.
    case voiceUnavailable
    case busy(waited: TimeInterval)
    case emptyScript
    case noAudio
    case tooLong(limit: TimeInterval)
    case inconsistentSampleRate(expected: Double, got: Double)
    case diskFull
    case writeFailed(String)
    case encodeFailed(String)

    /// True when retrying as WAV has a chance. Only encoder trouble qualifies; a full
    /// disk would fail the WAV too, and cancellation must stay cancellation.
    var isEncoderRefusal: Bool {
        if case .encodeFailed = self { return true }
        return false
    }

    var errorDescription: String? {
        switch self {
        case .voiceUnavailable: "The voice used for long recordings isn't set up."
        case .busy(let waited): "The Mac was recording or busy for \(Int(waited)) seconds."
        case .emptyScript: "The script had nothing to read."
        case .noAudio: "The voice returned no audio."
        case .tooLong(let limit): "The recording would run past \(Int(limit / 60)) minutes."
        case .inconsistentSampleRate(let expected, let got):
            "The voice changed its sample rate mid-script (\(expected) → \(got))."
        case .diskFull: "There was no room on the disk."
        case .writeFailed(let reason): "The audio file could not be written: \(reason)"
        case .encodeFailed(let reason): "The audio file could not be encoded: \(reason)"
        }
    }
}

// MARK: - Yield probes

/// The three things long-form rendering yields to. `LiveLongFormEnvironment` reads the
/// same probes the routine runner's environment reads: `isRecording` is verbatim
/// `LiveMemoryReviewEnvironment`'s definition, the lanes are the ones the notes runtime
/// and dictation ASR acquire in `ComputeScheduler`.
@MainActor
protocol LongFormRenderingEnvironment: AnyObject {
    var isRecording: Bool { get }
    func isASRLaneBusy() async -> Bool
    func isNotesLaneBusy() async -> Bool
    func awaitCleanupIdle() async
}

@MainActor
final class LiveLongFormEnvironment: LongFormRenderingEnvironment {
    var isRecording: Bool {
        MeetingController.shared.session != nil || (AppDelegate.current?.controller.state.isActive ?? false)
    }

    func isASRLaneBusy() async -> Bool {
        await ComputeScheduler.shared.isBusy(.realtimeASR)
    }

    func isNotesLaneBusy() async -> Bool {
        await ComputeScheduler.shared.isBusy(.background)
    }

    func awaitCleanupIdle() async {
        await LlamaBackend.shared.awaitCleanupIdle()
    }
}

// MARK: - Live voices

/// The offline adapters for the two engines that can render without a session. Both
/// return whole clauses; `PocketAgentVoice.frames` is streamed and accumulated per
/// clause, which keeps at most one clause in memory.
@MainActor
enum LongFormSynthesisFactory {
    static let sampleRate: Double = 24_000

    /// Voice for a host. Pocket has four voices, so the two hosts get two; `speaker` is
    /// nil for narration, which reads in the primary voice.
    static func pocketVoice(for speaker: String?) -> String {
        let primary = Settings.shared.agentPocketVoice
        guard speaker == LongFormScript.hostB else { return primary }
        return ["alba", "azelma", "cosette", "javert"].first { $0 != primary } ?? primary
    }

    /// The production synthesis closure.
    ///
    /// Engine choice, in order: what the user set in Settings, then — when the setting
    /// is Apple's voice, which cannot render offline — whichever of Pocket or Kokoro is
    /// already loaded in this process. If neither is, this throws `.voiceUnavailable`
    /// rather than asking FluidAudio's manager to fetch a model nobody chose at 06:00.
    static func live() -> LongFormRenderer.Synthesis {
        { request in
            let selected = Settings.shared.agentVoiceEngine
            switch selected {
            case "pocket":
                return try await pocket(request)
            case "kokoro" where KokoroAgentVoice.isSupportedOS:
                return try await kokoro(request)
            default:
                if PocketAgentVoice.shared.isReady { return try await pocket(request) }
                if KokoroAgentVoice.isSupportedOS, KokoroAgentVoice.shared.isReady {
                    return try await kokoro(request)
                }
                throw LongFormRenderError.voiceUnavailable
            }
        }
    }

    static func pocket(_ request: LongFormRenderer.SynthesisRequest) async throws -> LongFormRenderer.Audio {
        let voice = pocketVoice(for: request.speaker)
        var samples: [Float] = []
        let frames = try await PocketAgentVoice.shared.frames(for: request.text, voice: voice)
        for try await frame in frames {
            try Task.checkCancellation()
            samples.append(contentsOf: frame.samples)
        }
        guard !samples.isEmpty else { throw LongFormRenderError.noAudio }
        return LongFormRenderer.Audio(samples: samples, sampleRate: sampleRate)
    }

    static func kokoro(_ request: LongFormRenderer.SynthesisRequest) async throws -> LongFormRenderer.Audio {
        let data = try await KokoroAgentVoice.shared.wav(for: request.text)
        return try decodeWAV(data)
    }

    /// FluidAudio's `AudioWAV.data` is RIFF/WAVE with a 16-byte `fmt ` chunk and 16-bit
    /// mono PCM — both engines' one-shot output. Parsed rather than read through
    /// AVAudioFile so the render path touches no audio session, no temp file, and no
    /// playback graph.
    static func decodeWAV(_ data: Data) throws -> LongFormRenderer.Audio {
        func littleEndian<T: FixedWidthInteger>(_ type: T.Type, at offset: Int) -> T? {
            let size = MemoryLayout<T>.size
            guard offset >= 0, offset + size <= data.count else { return nil }
            return data.withUnsafeBytes { raw in
                var value: T = 0
                withUnsafeMutableBytes(of: &value) { destination in
                    destination.copyBytes(from: raw[offset..<(offset + size)])
                }
                return T(littleEndian: value)
            }
        }
        guard data.count > 44,
              data.prefix(4) == Data("RIFF".utf8),
              data[8..<12] == Data("WAVE".utf8) else {
            throw LongFormRenderError.encodeFailed("the voice returned a file that is not a WAV")
        }
        var offset = 12
        var sampleRate = 0
        var channels = 0
        var bits = 0
        var pcmFormat = 0
        var payload: Data?
        while offset + 8 <= data.count {
            let id = data[offset..<(offset + 4)]
            guard let size = littleEndian(UInt32.self, at: offset + 4).map(Int.init) else { break }
            let body = offset + 8
            if id == Data("fmt ".utf8), size >= 16 {
                pcmFormat = littleEndian(UInt16.self, at: body).map(Int.init) ?? 0
                channels = littleEndian(UInt16.self, at: body + 2).map(Int.init) ?? 0
                sampleRate = littleEndian(UInt32.self, at: body + 4).map(Int.init) ?? 0
                bits = littleEndian(UInt16.self, at: body + 14).map(Int.init) ?? 0
            } else if id == Data("data".utf8) {
                let end = min(body + size, data.count)
                payload = data.subdata(in: body..<end)
                break
            }
            offset = body + size + (size % 2)
        }
        guard pcmFormat == 1, channels == 1, bits == 16, sampleRate > 0, let payload else {
            throw LongFormRenderError.encodeFailed("the voice returned an unsupported WAV layout")
        }
        var samples = [Float](repeating: 0, count: payload.count / 2)
        payload.withUnsafeBytes { raw in
            for index in samples.indices {
                let low = UInt16(raw[index * 2])
                let high = UInt16(raw[index * 2 + 1]) << 8
                samples[index] = Float(Int16(bitPattern: low | high)) / 32_768
            }
        }
        guard !samples.isEmpty else { throw LongFormRenderError.noAudio }
        return LongFormRenderer.Audio(samples: samples, sampleRate: Double(sampleRate))
    }
}

// MARK: - File writers

/// A streaming sink for one container. `append` may suspend (AVAssetWriter applies
/// backpressure); `abort` must make the staging file disappear.
@MainActor
private protocol LongFormFileWriter: AnyObject {
    func append(_ samples: [Float]) async throws
    func finish() async throws -> Int
    func abort()
}

/// AAC in an `.m4a` through `AVAssetWriter`, appending one `CMSampleBuffer` per clause.
private final class M4AAudioFileWriter: LongFormFileWriter {
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private let sampleRate: Double
    private let formatDescription: CMAudioFormatDescription
    private var frameOffset = CMTime.zero

    init(url: URL, sampleRate: Double) throws {
        self.sampleRate = sampleRate
        do {
            writer = try AVAssetWriter(outputURL: url, fileType: .m4a)
        } catch {
            throw LongFormRenderError.encodeFailed(error.localizedDescription)
        }
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 64_000,
        ]
        input = AVAssetWriterInput(mediaType: .audio, outputSettings: settings)
        input.expectsMediaDataInRealTime = false
        guard writer.canAdd(input) else {
            throw LongFormRenderError.encodeFailed("the audio track could not be added")
        }
        writer.add(input)

        var asbd = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4,
            mChannelsPerFrame: 1, mBitsPerChannel: 32, mReserved: 0)
        var description: CMAudioFormatDescription?
        let status = CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault, asbd: &asbd, layoutSize: 0, layout: nil,
            magicCookieSize: 0, magicCookie: nil, extensions: nil,
            formatDescriptionOut: &description)
        guard status == noErr, let description else {
            throw LongFormRenderError.encodeFailed("the PCM format description could not be made")
        }
        formatDescription = description

        guard writer.startWriting() else {
            throw LongFormRenderError.encodeFailed(writer.error?.localizedDescription ?? "the writer did not start")
        }
        writer.startSession(atSourceTime: .zero)
    }

    func append(_ samples: [Float]) async throws {
        guard !samples.isEmpty else { return }
        let byteCount = samples.count * MemoryLayout<Float>.size
        var block: CMBlockBuffer?
        let blockStatus = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: byteCount,
            blockAllocator: kCFAllocatorDefault, customBlockSource: nil,
            offsetToData: 0, dataLength: byteCount, flags: 0, blockBufferOut: &block)
        guard blockStatus == kCMBlockBufferNoErr, let block else {
            throw LongFormRenderError.encodeFailed("the audio block could not be allocated")
        }
        let copyStatus = samples.withUnsafeBytes { raw -> OSStatus in
            guard let base = raw.baseAddress else { return -1 }
            return CMBlockBufferReplaceDataBytes(
                with: base, blockBuffer: block, offsetIntoDestination: 0, dataLength: byteCount)
        }
        guard copyStatus == kCMBlockBufferNoErr else {
            throw LongFormRenderError.encodeFailed("the audio block could not be filled")
        }

        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: CMTimeScale(sampleRate)),
            presentationTimeStamp: frameOffset, decodeTimeStamp: .invalid)
        var sampleBuffer: CMSampleBuffer?
        let sampleStatus = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault, dataBuffer: block,
            formatDescription: formatDescription, sampleCount: samples.count,
            sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &sampleBuffer)
        guard sampleStatus == noErr, let sampleBuffer else {
            throw LongFormRenderError.encodeFailed("the audio buffer could not be made")
        }

        while !input.isReadyForMoreMediaData {
            try Task.checkCancellation()
            if writer.status == .failed {
                throw LongFormRenderError.encodeFailed(writer.error?.localizedDescription ?? "the encoder stopped")
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        guard input.append(sampleBuffer) else {
            throw LongFormRenderError.encodeFailed(writer.error?.localizedDescription ?? "the encoder refused a chunk")
        }
        frameOffset = CMTimeAdd(
            frameOffset, CMTime(value: CMTimeValue(samples.count), timescale: CMTimeScale(sampleRate)))
    }

    func finish() async throws -> Int {
        input.markAsFinished()
        await withCheckedContinuation { continuation in
            writer.finishWriting { continuation.resume() }
        }
        guard writer.status == .completed else {
            throw LongFormRenderError.encodeFailed(writer.error?.localizedDescription ?? "the file did not finish")
        }
        return Self.fileSize(writer.outputURL)
    }

    func abort() {
        if writer.status == .writing { writer.cancelWriting() }
    }

    private static func fileSize(_ url: URL) -> Int {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? Int else { return 0 }
        return size
    }
}

/// 16-bit mono PCM WAV, same layout FluidAudio's `AudioWAV` writes. The header is
/// patched at the end because its two size fields are only known then; the file is
/// only ever closed by `finish`.
private final class WAVAudioFileWriter: LongFormFileWriter {
    private let url: URL
    private let sampleRate: Double
    private let handle: FileHandle
    private var dataBytes = 0

    init(url: URL, sampleRate: Double) throws {
        self.url = url
        self.sampleRate = sampleRate
        FileManager.default.createFile(atPath: url.path, contents: nil)
        guard let handle = FileHandle(forWritingAtPath: url.path) else {
            throw LongFormRenderError.writeFailed("the staging file could not be opened")
        }
        self.handle = handle
        try handle.write(contentsOf: Self.header(sampleRate: sampleRate, dataBytes: 0))
    }

    func append(_ samples: [Float]) async throws {
        guard !samples.isEmpty else { return }
        var pcm = [Int16](repeating: 0, count: samples.count)
        for (index, sample) in samples.enumerated() {
            pcm[index] = Int16(max(-1, min(1, sample)) * 32_767)
        }
        let data = pcm.withUnsafeBufferPointer { Data(buffer: $0) }
        try handle.write(contentsOf: data)
        dataBytes += data.count
    }

    func finish() async throws -> Int {
        try handle.seek(toOffset: 4)
        try handle.write(contentsOf: Self.uint32(UInt32(36 + dataBytes)))
        try handle.seek(toOffset: 40)
        try handle.write(contentsOf: Self.uint32(UInt32(dataBytes)))
        try handle.synchronize()
        try handle.close()
        return 44 + dataBytes
    }

    func abort() {
        try? handle.close()
        try? FileManager.default.removeItem(at: url)
    }

    private static func header(sampleRate: Double, dataBytes: Int) -> Data {
        var data = Data()
        data.append(Data("RIFF".utf8))
        data.append(uint32(UInt32(36 + dataBytes)))
        data.append(Data("WAVE".utf8))
        data.append(Data("fmt ".utf8))
        data.append(uint32(16))
        data.append(uint16(1))
        data.append(uint16(1))
        data.append(uint32(UInt32(sampleRate)))
        data.append(uint32(UInt32(sampleRate * 2)))
        data.append(uint16(2))
        data.append(uint16(16))
        data.append(Data("data".utf8))
        data.append(uint32(UInt32(dataBytes)))
        return data
    }

    private static func uint32(_ value: UInt32) -> Data {
        var little = value.littleEndian
        return withUnsafeBytes(of: &little) { Data($0) }
    }

    private static func uint16(_ value: UInt16) -> Data {
        var little = value.littleEndian
        return withUnsafeBytes(of: &little) { Data($0) }
    }
}

// MARK: - Script → clauses

/// A two-host script parsed into the speakable units the renderer writes.
///
/// `## Heading` lines open a section and become one chapter each. `Host A:` / `Host B:`
/// prefixes name the speaker and are not read aloud. Stage directions in brackets or
/// parentheses are dropped. Clause boundaries inside a line are
/// `AgentSpeechPolicy.splitIntoClauses` — the live policy's own splitter, reused
/// rather than reimplemented, so long-form and short-form agree on what a clause is.
struct LongFormScript: Sendable, Equatable {
    static let hostA = "Host A"
    static let hostB = "Host B"

    struct Clause: Sendable, Equatable {
        var text: String
        var speaker: String?
    }

    struct Section: Sendable, Equatable {
        /// Empty for lines that appeared before the first heading; those clauses are
        /// still read but mark no chapter.
        var title: String
        var clauses: [Clause]
    }

    var sections: [Section]

    var clauseCount: Int { sections.reduce(0) { $0 + $1.clauses.count } }
    var isEmpty: Bool { clauseCount == 0 }

    static func parse(_ text: String) -> LongFormScript {
        var sections: [Section] = []
        var current = Section(title: "", clauses: [])
        func flush() {
            if !current.clauses.isEmpty || !current.title.isEmpty { sections.append(current) }
            current = Section(title: "", clauses: [])
        }
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            if let heading = headingText(line) {
                flush()
                current.title = heading
                continue
            }
            if isStageDirection(line) { continue }
            let (speaker, body) = speakerAndBody(line)
            let spoken = spokenText(body)
            guard !spoken.isEmpty else { continue }
            for clause in AgentSpeechPolicy.splitIntoClauses(spoken) {
                current.clauses.append(Clause(text: clause, speaker: speaker))
            }
        }
        flush()
        return LongFormScript(sections: sections.filter { !$0.clauses.isEmpty })
    }

    /// `## Heading`, `# Heading`, or a line that is nothing but bold text.
    private static func headingText(_ line: String) -> String? {
        if line.hasPrefix("#") {
            let title = String(line.drop { $0 == "#" })
                .trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "*_:"))
                .trimmingCharacters(in: .whitespaces)
            return title.isEmpty ? nil : title
        }
        if line.hasPrefix("**"), line.hasSuffix("**"), line.count > 4 {
            let title = String(line.dropFirst(2).dropLast(2))
                .trimmingCharacters(in: .whitespaces)
            return title.isEmpty ? nil : title
        }
        return nil
    }

    private static func isStageDirection(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: CharacterSet(charactersIn: "*_ "))
        return (trimmed.hasPrefix("[") && trimmed.hasSuffix("]"))
            || (trimmed.hasPrefix("(") && trimmed.hasSuffix(")"))
    }

    private static func speakerAndBody(_ line: String) -> (String?, String) {
        var body = line.trimmingCharacters(in: CharacterSet(charactersIn: "*_ "))
        let lowered = body.lowercased()
        for (prefix, speaker) in [
            ("host a:", hostA), ("host a —", hostA), ("host a -", hostA), ("host a –", hostA),
            ("host b:", hostB), ("host b —", hostB), ("host b -", hostB), ("host b –", hostB),
        ] where lowered.hasPrefix(prefix) {
            body = String(body.dropFirst(prefix.count))
            return (speaker, body.trimmingCharacters(in: .whitespaces))
        }
        return (nil, body)
    }

    /// Markdown emphasis is how a model stresses a word; a voice stresses it with
    /// prosody, so the characters are removed rather than read.
    private static func spokenText(_ text: String) -> String {
        text.replacingOccurrences(of: "*", with: "")
            .replacingOccurrences(of: "`", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
