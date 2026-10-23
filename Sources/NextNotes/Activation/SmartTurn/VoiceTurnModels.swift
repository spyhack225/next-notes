import Foundation
@preconcurrency import CoreML

/// Immutable exports. Each complete directory is verified before Core ML sees it.
/// The normal downloader's disk reserve is unchanged; no partial bundle is published.
enum VoiceTurnAssets {
    /// Candidate rollout is held until the preserved mid-sentence pause failures
    /// qualify. This developer launch flag never rewrites a saved preference.
    static var enabled: Bool {
        CommandLine.arguments.contains("--voice-smart-turn")
            || SelfTest.value(after: "--turn-model-root") != nil
                && SelfTest.isRunning
    }
    enum Kind: String, Sendable { case smartTurn, silero }
    struct File: Sendable { let path: String; let bytes: Int64; let sha: String }
    static let smartRevision = "75f069717f500947195fa1945c46ddb472559cff"
    static let sileroRevision = "b419383c55c110e2c9271fa6ee0ea83d03c70d96"
    static var root: URL {
        if SelfTest.isRunning, let supplied = SelfTest.value(after: "--turn-model-root") {
            let url = URL(fileURLWithPath: supplied).standardizedFileURL.resolvingSymlinksInPath()
            // Explicit fixture ownership; never adopt an owner's model directory.
            if FileManager.default.fileExists(atPath: url.appendingPathComponent(".nextnotes-turn-fixture").path) {
                return url
            }
        }
        // Computing a diagnostic path must not trigger rename/defaults migrations.
        return AppIdentity.applicationSupportDirectoryURL.appendingPathComponent("Models")
    }
    static func files(_ kind: Kind) -> [File] {
        switch kind {
        case .smartTurn: return [
            File(path: "weights/weight.bin", bytes: 16_714_240, sha: "b6295316741a0149e1fcab7cdf030e1b9bfb0eef778207accee91a2a9703a39c"),
            File(path: "coremldata.bin", bytes: 643, sha: "9245ac99889c9d738cba6c89da9e851fd16488bf8effbc15a109d06b401c9383"),
            File(path: "analytics/coremldata.bin", bytes: 243, sha: "1646746d0029e78d26be065e62602d4f89e51013ec238b653adf7d7d21057f89"),
            File(path: "model.mil", bytes: 69_968, sha: "41a6d9ac0f7d01d738e56ecdf4435e55f139591541b7cf1a4dba6b9ce2f1c9ef")]
        case .silero: return [
            File(path: "weights/weight.bin", bytes: 882_304, sha: "853cf34740d3f5061f977ebe2976f7c921b064261c9c4753b3a1196f2dba42b4"),
            File(path: "coremldata.bin", bytes: 593, sha: "f460dcdf796b19c04bc38ab6e69601831f634e5e74d499487f0c8fe17ca12f0f"),
            File(path: "analytics/coremldata.bin", bytes: 243, sha: "2141be60ea0adf7acb1232fbcfaffb2be308ae02e6672d3762aedf36611ea9fd"),
            File(path: "model.mil", bytes: 25_126, sha: "79eea23c368f3e7edf85af798a953f5b0910e4b08ff48e55fff8545dd05fd047"),
            File(path: "metadata.json", bytes: 3_232, sha: "282b1b788b5d4d66d6a70d468464a7ada71d2469a8705526b741fd9ab841295a")]
        }
    }
    static func directory(_ kind: Kind, root: URL = VoiceTurnAssets.root) -> URL {
        root.appendingPathComponent("VoiceTurn/" + (kind == .smartTurn ? smartRevision : sileroRevision))
            .appendingPathComponent(kind == .smartTurn ? "smart_turn.mlmodelc" : "silero-vad-unified-v6.0.0.mlmodelc")
    }
    static func verify(_ kind: Kind, at directory: URL) throws {
        for file in files(kind) {
            _ = try VerifiedModelArtifact.verify(directory.appendingPathComponent(file.path),
                bytes: file.bytes, expectedSHA256: file.sha)
        }
    }
    static func prepare(_ kind: Kind, cachedOnly: Bool, root: URL = VoiceTurnAssets.root) async throws -> URL {
        let destination = directory(kind, root: root)
        if FileManager.default.fileExists(atPath: destination.path) {
            try verify(kind, at: destination)
            return destination
        }
        guard !cachedOnly else { throw CocoaError(.fileNoSuchFile) }
        let parent = destination.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let stage = parent.appendingPathComponent(".stage-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: stage) }
        let remote = kind == .smartTurn
            ? "https://huggingface.co/aufklarer/Smart-Turn-v3.2-CoreML/resolve/\(smartRevision)/smart_turn.mlmodelc/"
            : "https://huggingface.co/FluidInference/silero-vad-coreml/resolve/\(sileroRevision)/silero-vad-unified-v6.0.0.mlmodelc/"
        // Reserve the complete remaining artifact, not just the next tiny metadata file.
        let total = files(kind).reduce(Int64(0)) { $0 + $1.bytes }
        guard ModelDownloader.availableDiskBytes(at: parent) - total >= ModelDownloader.minimumFreeBytesAfterDownload else {
            throw ModelDownloadError.insufficientDisk(free: ModelDownloader.availableDiskBytes(at: parent), needed: total)
        }
        for file in files(kind) {
            try Task.checkCancellation()
            try await ModelDownloader.download(ModelSpec(displayName: "Conversation listening", fileName: file.path,
                url: URL(string: remote + file.path)!, expectedBytes: file.bytes, expectedSHA256: file.sha), directory: stage)
        }
        try verify(kind, at: stage)
        try Task.checkCancellation()
        try FileManager.default.moveItem(at: stage, to: destination)
        return destination
    }
}

/// Used only from the capture owner's retained serial inference handle.
final class SmartTurnModel: @unchecked Sendable {
    private let model: MLModel
    init(directory: URL) throws {
        try VoiceTurnAssets.verify(.smartTurn, at: directory)
        let config = MLModelConfiguration()
        config.computeUnits = .cpuAndNeuralEngine
        model = try MLModel(contentsOf: directory, configuration: config)
        guard model.modelDescription.inputDescriptionsByName["audio"]?.multiArrayConstraint?.shape == [1, 128_000],
              model.modelDescription.outputDescriptionsByName["probability"]?.multiArrayConstraint?.shape == [1, 1] else {
            throw CocoaError(.coderInvalidValue)
        }
    }
    func probability(_ samples: [Float]) throws -> Float {
        try autoreleasepool { try predict(samples) }
    }
    private func predict(_ samples: [Float]) throws -> Float {
        // The export contains its own log-mel extraction/normalization. Raw PCM only.
        let input = try MLMultiArray(shape: [1, 128_000], dataType: .float32)
        let values = input.dataPointer.assumingMemoryBound(to: Float.self)
        values.update(repeating: 0, count: 128_000)
        let tail = samples.suffix(128_000)
        for (index, sample) in tail.enumerated() { values[128_000 - tail.count + index] = sample }
        let output = try model.prediction(from: MLDictionaryFeatureProvider(dictionary: ["audio": input]))
        guard let probability = output.featureValue(for: "probability")?.multiArrayValue,
              probability.count == 1 else { throw CocoaError(.coderInvalidValue) }
        let value = probability[0].floatValue
        guard value.isFinite, (0...1).contains(value) else { throw CocoaError(.coderInvalidValue) }
        return value
    }
}

/// Silero's 512-sample graph, with explicit 64-sample context and recurrent state.
/// Reset after a discontinuity; overlapping/sliding windows must never share LSTM state.
final class SileroFrameModel: @unchecked Sendable {
    static let frames = 512
    private let model: MLModel
    private var context = [Float](repeating: 0, count: 64)
    private var hidden: MLMultiArray
    private var cell: MLMultiArray
    private var previousEnd: UInt64?
    init(directory: URL) throws {
        try VoiceTurnAssets.verify(.silero, at: directory)
        let config = MLModelConfiguration()
        config.computeUnits = .cpuAndNeuralEngine
        model = try MLModel(contentsOf: directory, configuration: config)
        guard model.modelDescription.inputDescriptionsByName["audio_input"]?.multiArrayConstraint?.shape == [1, 576] else {
            throw CocoaError(.coderInvalidValue)
        }
        hidden = try MLMultiArray(shape: [1, 128], dataType: .float32)
        cell = try MLMultiArray(shape: [1, 128], dataType: .float32)
        reset()
    }
    private func reset() {
        context = [Float](repeating: 0, count: 64)
        hidden.dataPointer.assumingMemoryBound(to: Float.self).update(repeating: 0, count: 128)
        cell.dataPointer.assumingMemoryBound(to: Float.self).update(repeating: 0, count: 128)
    }
    func probability(_ samples: [Float], endNanos: UInt64) throws -> Float {
        try autoreleasepool { try predict(samples, endNanos: endNanos) }
    }
    private func predict(_ samples: [Float], endNanos: UInt64) throws -> Float {
        guard samples.count == Self.frames else { throw CocoaError(.coderInvalidValue) }
        // Capture host stamps can differ by a few ticks from an exact sample
        // duration. A skipped frame is >=64ms; ordinary stamp jitter isn't a gap.
        if previousEnd.map({ endNanos < $0 || !(24_000_000...40_000_000).contains(endNanos - $0) }) ?? true { reset() }
        previousEnd = endNanos
        let input = try MLMultiArray(shape: [1, 576], dataType: .float32)
        let values = input.dataPointer.assumingMemoryBound(to: Float.self)
        for (i, x) in context.enumerated() { values[i] = x }
        for (i, x) in samples.enumerated() { values[i + 64] = x }
        let output = try model.prediction(from: MLDictionaryFeatureProvider(dictionary: [
            "audio_input": input, "hidden_state": hidden, "cell_state": cell]))
        guard let p = output.featureValue(for: "vad_output")?.multiArrayValue,
              let nextHidden = output.featureValue(for: "new_hidden_state")?.multiArrayValue,
              let nextCell = output.featureValue(for: "new_cell_state")?.multiArrayValue,
              p.count == 1, nextHidden.count == 128, nextCell.count == 128 else { throw CocoaError(.coderInvalidValue) }
        let value = p[0].floatValue
        guard value.isFinite, (0...1).contains(value) else { throw CocoaError(.coderInvalidValue) }
        context = Array(samples.suffix(64))
        hidden = nextHidden; cell = nextCell
        return value
    }
}
