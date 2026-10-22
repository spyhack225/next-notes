import Foundation
import Observation
import PhononTTS
import MLXAudioTTS
import MLX

/// Optional native voices. Loading/downloads happen only after a selection in Settings.
/// The benchmark uses its own instance and temporary model directory in a separate process.
@MainActor
@Observable
final class NativeAgentVoice {
    enum Engine: String, CaseIterable { case qwen, phonon }
    static let qwen = NativeAgentVoice(.qwen)
    static let phonon = NativeAgentVoice(.phonon)
    let engine: Engine
    private(set) var isReady = false
    private(set) var isPreparing = false
    private(set) var progress: Double = 0
    private(set) var errorMessage: String?
    private var preparation: Task<Void, Never>?
    private var qwenModel: Qwen3TTSModel?
    private var phononModel: Phonon?
    private var rendering = false

    init(_ engine: Engine) { self.engine = engine }
    var sampleRate: Double { engine == .phonon ? Phonon.sampleRate : Double(qwenModel?.sampleRate ?? 24_000) }
    var voiceName: String { engine == .qwen ? "Ryan" : (phononModel?.voice ?? "Default") }
    var installed: Bool {
        switch engine {
        case .qwen: NativeVoiceAssets.qwenFiles.allSatisfy { NativeVoiceAssets.isPresent($0) }
        case .phonon: PhononModels.isInstalled(at: NativeVoiceAssets.phononDirectory)
        }
    }

    func prepare(download: Bool = false) async {
        if isReady { return }
        if let preparation { await preparation.value; return }
        guard download || installed else { return }
        if engine == .qwen, !NativeVoiceAssets.hasMLXMetalLibrary {
            errorMessage = "This version can’t prepare Qwen3-TTS yet. Choose Phonon or a macOS voice for now."
            return
        }
        isPreparing = true
        errorMessage = nil
        let task = Task { @MainActor in
            defer { isPreparing = false; preparation = nil }
            do {
                let report: @Sendable (Double) -> Void = { [weak self] fraction in
                    Task { @MainActor in self?.progress = fraction }
                }
                switch engine {
                case .qwen:
                    // Verification and loading are off the UI actor. No model is loaded per clause.
                    try await NativeVoiceAssets.downloadQwen(progress: report)
                    let directory = NativeVoiceAssets.qwenDirectory
                    qwenModel = try await Task.detached(priority: .userInitiated) {
                        if CommandLine.arguments.contains("--selftest-tts-benchmark") {
                            FileHandle.standardError.write(Data("QWEN_MEMORY before-load \(Memory.snapshot()) cacheLimit=\(Memory.cacheLimit)\n".utf8))
                        }
                        return try await Qwen3TTSModel.fromModelDirectory(directory)
                    }.value
                    if CommandLine.arguments.contains("--selftest-tts-benchmark") {
                        FileHandle.standardError.write(Data("QWEN_MEMORY prepared \(Memory.snapshot())\n".utf8))
                    }
                case .phonon:
                    if !installed { try await NativeVoiceAssets.downloadPhonon(progress: report) }
                    phononModel = try await Phonon.load(models: NativeVoiceAssets.phononDirectory, language: .english)
                }
                isReady = true
            } catch { errorMessage = error.localizedDescription }
        }
        preparation = task
        await task.value
    }

    /// Uses a single model owner. A cancelled Qwen clause joins its actual native call
    /// before that owner can be reused; the microphone and playback are never held.
    func synthesize(_ text: String,
                    consume: @escaping @MainActor ([Float]) async throws -> Void) async throws {
        guard isReady else { throw NativeVoiceError.missing }
        guard !rendering else { throw NativeVoiceError.busy }
        rendering = true
        defer { rendering = false }
        switch engine {
        case .qwen:
            guard let model = qwenModel else { throw NativeVoiceError.missing }
            // This SDK's public streaming API cancels its consumer before its hidden
            // native producer joins. Use the joined whole-clause API until it exposes
            // a drain receipt; never overlap mutable decoder state after interruption.
            let task = Task.detached(priority: .userInitiated) {
                try Task.checkCancellation()
                if CommandLine.arguments.contains("--selftest-tts-benchmark") {
                    FileHandle.standardError.write(Data("QWEN_MEMORY before-clause \(Memory.snapshot())\n".utf8))
                }
                let audio = try await model.generate(text: text, voice: "Ryan", refAudio: nil,
                                                     refText: nil, language: "English")
                try Task.checkCancellation()
                let samples = audio.asArray(Float.self)
                if CommandLine.arguments.contains("--selftest-tts-benchmark") {
                    FileHandle.standardError.write(Data("QWEN_MEMORY after-clause \(Memory.snapshot())\n".utf8))
                }
                return samples
            }
            let samples = try await withTaskCancellationHandler {
                try await task.value
            } onCancel: { task.cancel() }
            try Task.checkCancellation()
            guard !samples.isEmpty else { throw NativeVoiceError.empty }
            try await consume(samples)
        case .phonon:
            guard let model = phononModel else { throw NativeVoiceError.missing }
            var produced = false
            for try await samples in model.stream(text) {
                try Task.checkCancellation()
                guard !samples.isEmpty else { continue }
                produced = true
                try await consume(samples)
            }
            guard produced else { throw NativeVoiceError.empty }
        }
    }
}
