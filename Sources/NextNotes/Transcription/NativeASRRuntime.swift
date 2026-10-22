import Foundation
import AVFoundation
import CoreML
import FluidAudio
import PhononCoreML
import Voz
@preconcurrency import MLXAudioSTT
import MLX

/// One warm alternative model. Sessions retain their actor across a picker change,
/// so changing the next model cannot evict a recognition pass already in progress.
actor NativeASRRuntime {
    static let shared = NativeASRRuntime()
    private var cached: (SpeechEngineChoice, NativeASRBackend)?
    private var loading: (SpeechEngineChoice, Task<NativeASRBackend, Error>)?
    func isLoaded(_ choice: SpeechEngineChoice) -> Bool { cached?.0 == choice }
    func unload() async {
        if let loading { _ = await loading.1.result }
        if let cached { await cached.1.drain() }
        cached = nil
    }
    func backend(_ choice: SpeechEngineChoice, directory: URL) async throws -> NativeASRBackend {
        if let cached, cached.0 == choice { return cached.1 }
        if let loading {
            guard loading.0 == choice else { throw ASRModelError.busy(loading.0.displayName) }
            return try await loading.1.value
        }
        cached = nil
        let task = Task {
            let backend = NativeASRBackend(choice: choice, directory: directory)
            try await backend.load()
            return backend
        }
        loading = (choice, task)
        defer { loading = nil }
        let backend = try await task.value
        cached = (choice, backend)
        return backend
    }
}

actor NativeASRBackend {
    let choice: SpeechEngineChoice
    private let directory: URL
    private var phonon: Transcriber?
    private var voz: Voz?
    private var qwen: Qwen3ASRModel?
    private var fluid: AsrManager?
    private var whistle: WhistleASRLibrary?
    private var activePasses = 0
    private var drainWaiters: [CheckedContinuation<Void, Never>] = []
    func drain() async {
        if activePasses > 0 { await withCheckedContinuation { drainWaiters.append($0) } }
    }
    init(choice: SpeechEngineChoice, directory: URL) { self.choice = choice; self.directory = directory }
    func load() async throws {
        switch choice {
        case .phonon:
            // Keep the stable compiled path: ANE specialization is keyed by path.
            let target = directory.appendingPathComponent("Phonon-2.mlmodelc")
            if !FileManager.default.fileExists(atPath: target.path) {
                let compiled = try await MLModel.compileModel(at: directory.appendingPathComponent("Phonon-2.mlpackage"))
                try FileManager.default.moveItem(at: compiled, to: target)
            }
            var options = Transcriber.Options()
            options.functions = [5, 10, 15]
            options.eagerFunctions = [5, 10, 15]
            options.progress = { phase, _ in
                Task { @MainActor in ASRModelStore.shared.reportPreparation(.phonon, phase: phase) }
            }
            phonon = try Transcriber(bundle: directory, options: options)
        case .voz: voz = try Voz(modelDirectory: directory)
        case .qwenSmall, .qwenLarge:
            guard NativeVoiceAssets.hasMLXMetalLibrary else {
                throw ASRModelError.runtime("This copy of the app is missing its speech resources.")
            }
            qwen = try await Qwen3ASRModel.fromModelDirectory(directory)
        case .redux, .ultra:
            let config = MLModelConfiguration(); config.computeUnits = .cpuAndNeuralEngine
            let cpu = MLModelConfiguration(); cpu.computeUnits = .cpuOnly
            let raw = try JSONSerialization.jsonObject(with: Data(contentsOf: directory.appendingPathComponent("parakeet_v3_vocab.json")))
            let vocabulary: [Int: String]
            if let list = raw as? [String] { vocabulary = Dictionary(uniqueKeysWithValues: list.enumerated().map { ($0.offset, $0.element) }) }
            else if let dict = raw as? [String: String] { vocabulary = Dictionary(uniqueKeysWithValues: dict.compactMap { k,v in Int(k).map { ($0,v) } }) }
            else { throw ASRModelError.unavailable }
            let models = try AsrModels(
                encoder: MLModel(contentsOf: directory.appendingPathComponent("Encoder.mlmodelc"), configuration: config),
                preprocessor: MLModel(contentsOf: directory.appendingPathComponent("Preprocessor.mlmodelc"), configuration: cpu),
                decoder: MLModel(contentsOf: directory.appendingPathComponent("Decoder.mlmodelc"), configuration: config),
                joint: MLModel(contentsOf: directory.appendingPathComponent("JointDecisionv3.mlmodelc"), configuration: config),
                configuration: config, vocabulary: vocabulary, version: .v3)
            fluid = AsrManager(config: .default, models: models)
        case .whistle: whistle = try WhistleASRLibrary(directory: directory)
        default: throw ASRModelError.unavailable
        }
    }
    func transcribe(_ audio: [Float], englishOnly: Bool) async throws -> String {
        try Task.checkCancellation()
        activePasses += 1
        defer {
            activePasses -= 1
            if activePasses == 0 {
                let waiting = drainWaiters; drainWaiters = []
                for waiter in waiting { waiter.resume() }
            }
        }
        if let phonon { return try phonon.transcribe(audio).text }
        if let voz { return try await voz.transcribe(samples: audio).text }
        if let qwen {
            // This native Swift implementation is measured again through the app;
            // earlier Python MLX observations are not relabelled as app timings.
            return qwen.generate(audio: MLXArray(audio), generationParameters: .init(maxTokens: 512, language: englishOnly ? "English" : nil)).text
        }
        if let fluid {
            var state = try TdtDecoderState()
            return try await fluid.transcribe(audio, decoderState: &state).text
        }
        if let whistle { return try whistle.transcribe(audio, englishOnly: englishOnly) }
        throw ASRModelError.unavailable
    }
}
