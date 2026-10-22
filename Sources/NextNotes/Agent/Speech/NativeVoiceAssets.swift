import Foundation
import PhononTTS

/// Pinned public artifacts; downloads use the app's existing size/hash/disk checks.
enum NativeVoiceAssets {
    static let qwenRevision = "08c72cad5e2fd0f41730c8bd1f28149585e46361"
    static let qwenFiles: [ModelSpec] = [
        .init(displayName: "Qwen3-TTS", fileName: "Qwen3TTS/config.json",
              url: URL(string: "https://huggingface.co/mlx-community/Qwen3-TTS-12Hz-0.6B-CustomVoice-4bit/resolve/08c72cad5e2fd0f41730c8bd1f28149585e46361/config.json")!,
              expectedBytes: 6058, expectedSHA256: "612cb591b44547319e5c68a78c0e93e4defb57882a4aa9ef5f06cc2f071ed036"),
        .init(displayName: "Qwen3-TTS", fileName: "Qwen3TTS/generation_config.json",
              url: URL(string: "https://huggingface.co/mlx-community/Qwen3-TTS-12Hz-0.6B-CustomVoice-4bit/resolve/08c72cad5e2fd0f41730c8bd1f28149585e46361/generation_config.json")!,
              expectedBytes: 245, expectedSHA256: "f1b90b4513f3b34c62851049e2492d7b4c5940daf1276f89c82b8ef04127f3aa"),
        .init(displayName: "Qwen3-TTS", fileName: "Qwen3TTS/merges.txt",
              url: URL(string: "https://huggingface.co/mlx-community/Qwen3-TTS-12Hz-0.6B-CustomVoice-4bit/resolve/08c72cad5e2fd0f41730c8bd1f28149585e46361/merges.txt")!,
              expectedBytes: 1671839, expectedSHA256: "599bab54075088774b1733fde865d5bd747cbcc7a547c5bc12610e874e26f5e3"),
        .init(displayName: "Qwen3-TTS", fileName: "Qwen3TTS/model.safetensors",
              url: URL(string: "https://huggingface.co/mlx-community/Qwen3-TTS-12Hz-0.6B-CustomVoice-4bit/resolve/08c72cad5e2fd0f41730c8bd1f28149585e46361/model.safetensors")!,
              expectedBytes: 1006772520, expectedSHA256: "4ab02a20be381700f6e73dbb5efdc424cadf9f1d0652cbffd662872ea41e296a"),
        .init(displayName: "Qwen3-TTS", fileName: "Qwen3TTS/model.safetensors.index.json",
              url: URL(string: "https://huggingface.co/mlx-community/Qwen3-TTS-12Hz-0.6B-CustomVoice-4bit/resolve/08c72cad5e2fd0f41730c8bd1f28149585e46361/model.safetensors.index.json")!,
              expectedBytes: 71447, expectedSHA256: "f3b84ec5c1b38220008c3a300b8a73502f7d4ec67b232e0193d9376909fc4e3e"),
        .init(displayName: "Qwen3-TTS", fileName: "Qwen3TTS/preprocessor_config.json",
              url: URL(string: "https://huggingface.co/mlx-community/Qwen3-TTS-12Hz-0.6B-CustomVoice-4bit/resolve/08c72cad5e2fd0f41730c8bd1f28149585e46361/preprocessor_config.json")!,
              expectedBytes: 127, expectedSHA256: "efdde1022ea9d76928bf7a9cd53139138f5ba2e466e837f08f6105ab1af1c119"),
        .init(displayName: "Qwen3-TTS", fileName: "Qwen3TTS/speech_tokenizer/config.json",
              url: URL(string: "https://huggingface.co/mlx-community/Qwen3-TTS-12Hz-0.6B-CustomVoice-4bit/resolve/08c72cad5e2fd0f41730c8bd1f28149585e46361/speech_tokenizer/config.json")!,
              expectedBytes: 2336, expectedSHA256: "ee65bb901c876664ab8707c487157aa1a6ee57c65969b28fb5ec9dc211e68167"),
        .init(displayName: "Qwen3-TTS", fileName: "Qwen3TTS/speech_tokenizer/configuration.json",
              url: URL(string: "https://huggingface.co/mlx-community/Qwen3-TTS-12Hz-0.6B-CustomVoice-4bit/resolve/08c72cad5e2fd0f41730c8bd1f28149585e46361/speech_tokenizer/configuration.json")!,
              expectedBytes: 76, expectedSHA256: "6bc26d64eb5024b4d1dab5a52371958b429256d6c9d59787f1f5294a54e0cebd"),
        .init(displayName: "Qwen3-TTS", fileName: "Qwen3TTS/speech_tokenizer/model.safetensors",
              url: URL(string: "https://huggingface.co/mlx-community/Qwen3-TTS-12Hz-0.6B-CustomVoice-4bit/resolve/08c72cad5e2fd0f41730c8bd1f28149585e46361/speech_tokenizer/model.safetensors")!,
              expectedBytes: 682293092, expectedSHA256: "836b7b357f5ea43e889936a3709af68dfe3751881acefe4ecf0dbd30ba571258"),
        .init(displayName: "Qwen3-TTS", fileName: "Qwen3TTS/speech_tokenizer/preprocessor_config.json",
              url: URL(string: "https://huggingface.co/mlx-community/Qwen3-TTS-12Hz-0.6B-CustomVoice-4bit/resolve/08c72cad5e2fd0f41730c8bd1f28149585e46361/speech_tokenizer/preprocessor_config.json")!,
              expectedBytes: 234, expectedSHA256: "fcb3805e597e786d4067706e602f6688524640f8d3396790e2e09b5942fcbdfb"),
        .init(displayName: "Qwen3-TTS", fileName: "Qwen3TTS/tokenizer_config.json",
              url: URL(string: "https://huggingface.co/mlx-community/Qwen3-TTS-12Hz-0.6B-CustomVoice-4bit/resolve/08c72cad5e2fd0f41730c8bd1f28149585e46361/tokenizer_config.json")!,
              expectedBytes: 7344, expectedSHA256: "dc3c31c3bdaedd5016382bb3cbe07323026775ad51f5a4fb564505992ae4a670"),
        .init(displayName: "Qwen3-TTS", fileName: "Qwen3TTS/vocab.json",
              url: URL(string: "https://huggingface.co/mlx-community/Qwen3-TTS-12Hz-0.6B-CustomVoice-4bit/resolve/08c72cad5e2fd0f41730c8bd1f28149585e46361/vocab.json")!,
              expectedBytes: 2776833, expectedSHA256: "ca10d7e9fb3ed18575dd1e277a2579c16d108e32f27439684afa0e10b1440910"),
    ]
    static let phononArchive = ModelSpec(
        displayName: "Phonon", fileName: "phonon-31m-en-coreml-v0.4.0.zip",
        url: URL(string: "https://github.com/gradium-ai/xn-ptts/releases/download/v0.4.0/phonon-31m-en-coreml.zip")!,
        expectedBytes: 137096081,
        expectedSHA256: "10f3a99fd39256db44f826267ef21d78cca959b16c0554926344c09fde27b436")

    // Only the headless benchmark can substitute an owned temporary model root.
    @MainActor static var benchmarkRoot: URL?
    @MainActor static var root: URL { benchmarkRoot ?? ModelSpec.directory }
    // The headless runner owns and removes one model, and independently monitors
    // actual free disk. Ordinary downloads retain the existing 4 GiB reserve.
    @MainActor static var downloadReserve: Int64 {
        benchmarkRoot != nil && SelfTest.requested == "--selftest-tts-benchmark"
            ? 2 * 1_024 * 1_024 * 1_024 : ModelDownloader.minimumFreeBytesAfterDownload
    }
    @MainActor static func isPresent(_ spec: ModelSpec) -> Bool {
        let size = (try? root.appendingPathComponent(spec.fileName).resourceValues(forKeys: [.fileSizeKey]))?.fileSize
        return size.map(Int64.init) == spec.expectedBytes
    }
    @MainActor static var qwenDirectory: URL { root.appendingPathComponent("Qwen3TTS") }
    @MainActor static var phononDirectory: URL { root.appendingPathComponent("Phonon31m") }

    /// MLX's SwiftPM CLI build does not compile Metal shaders. Refuse before
    /// downloading weights when the distributed app lacks that runtime resource.
    static var hasMLXMetalLibrary: Bool {
        let roots = [Bundle.main.bundleURL, Bundle.main.resourceURL,
                     Bundle.main.executableURL?.deletingLastPathComponent()].compactMap { $0 }
        let paths = ["default.metallib", "mlx-swift_Cmlx.bundle/default.metallib",
                     "mlx-swift_Cmlx.bundle/Contents/Resources/default.metallib"]
        return roots.contains { base in
            paths.contains { FileManager.default.isReadableFile(atPath: base.appendingPathComponent($0).path) }
        }
    }

    @MainActor static func downloadQwen(progress: @escaping @Sendable (Double) -> Void) async throws {
        if benchmarkRoot != nil {
            let existing = AppIdentity.applicationSupportDirectoryURL.appendingPathComponent("Models/Qwen3TTS")
            try await cloneCachedDirectory(from: existing, to: qwenDirectory)
        }
        let missing = qwenFiles.filter { !isPresent($0) }.reduce(Int64(0)) { $0 + $1.expectedBytes }
        // An installed voice requires no download space. Keep the reserve at
        // the actual download boundary rather than refusing offline loading.
        guard missing == 0 || ModelDownloader.availableDiskBytes(at: root) - missing >= downloadReserve else {
            throw NativeVoiceError.space
        }
        let total = Double(qwenFiles.reduce(Int64(0)) { $0 + $1.expectedBytes })
        var done = 0.0
        for spec in qwenFiles {
            try Task.checkCancellation()
            try FileManager.default.createDirectory(at: root.appendingPathComponent(spec.fileName).deletingLastPathComponent(), withIntermediateDirectories: true)
            let before = done
            try await ModelDownloader.download(spec, directory: root, reserveBytes: downloadReserve) { progress((before + $0 * Double(spec.expectedBytes)) / total) }
            done += Double(spec.expectedBytes)
        }
    }

    @MainActor static func downloadPhonon(progress: @escaping @Sendable (Double) -> Void) async throws {
        if benchmarkRoot != nil {
            let existing = AppIdentity.applicationSupportDirectoryURL.appendingPathComponent("Models/Phonon31m")
            try await cloneCachedDirectory(from: existing, to: phononDirectory)
            if PhononModels.isInstalled(at: phononDirectory) { return }
        }
        // Pinned v0.4.0 observed compiled benchmark roots are323.7 MB;
        // the137.1 MB archive is removed after extraction. A1 GB diagnostic
        // budget retains >539 MB above both together. Production stays1.5 GB.
        let transient: Int64 = benchmarkRoot == nil ? 1_500_000_000 : 1_000_000_000
        guard ModelDownloader.availableDiskBytes(at: root) >= downloadReserve + transient else {
            throw NativeVoiceError.space
        }
        try await ModelDownloader.download(phononArchive, directory: root, reserveBytes: downloadReserve, progress: progress)
        let archive = root.appendingPathComponent(phononArchive.fileName)
        let destination = phononDirectory
        try await Task.detached(priority: .utility) {
            let scratch = destination.deletingLastPathComponent().appendingPathComponent(".phonon-unpack-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: scratch) }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            process.arguments = ["-x", "-k", archive.path, scratch.path]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { throw NativeVoiceError.unpack }
            // Find the manifest rather than relying on an archive's outer directory name.
            let entries = FileManager.default.enumerator(at: scratch, includingPropertiesForKeys: nil)
            var bundle: URL?
            while let entry = entries?.nextObject() as? URL {
                if entry.lastPathComponent == "bundle.json" { bundle = entry.deletingLastPathComponent(); break }
            }
            guard let bundle else { throw NativeVoiceError.unpack }
            // This download is already writable. Move the verified bundle on the
            // same volume instead of making the extra full copy needed for app resources.
            guard PhononModels.isInstalled(at: bundle) else { throw NativeVoiceError.unpack }
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.moveItem(at: bundle, to: destination)
            try? FileManager.default.removeItem(at: archive)
        }.value
    }

    /// APFS copy-on-write snapshot: reuses physical model blocks while insulating
    /// owner files from SDK cache repair/deletion. Only the benchmark owns this copy.
    static func cloneCachedDirectory(from source: URL, to destination: URL) async throws {
        guard FileManager.default.fileExists(atPath: source.path),
              !FileManager.default.fileExists(atPath: destination.path) else { return }
        try await Task.detached(priority: .utility) {
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/cp")
            process.arguments = ["-cRL", source.path, destination.path]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { throw NativeVoiceError.unpack }
        }.value
    }
}

enum NativeVoiceError: LocalizedError {
    case space, missing, unpack, empty, busy
    var errorDescription: String? {
        switch self {
        case .space: "There isn’t enough free space to prepare this voice. Free some space, then try again."
        case .missing: "Download this voice in Settings before using it."
        case .unpack: "The voice download could not be opened. Please try again."
        case .empty: "The voice did not produce any audio."
        case .busy: "This voice is already speaking. Try again when it finishes."
        }
    }
}
