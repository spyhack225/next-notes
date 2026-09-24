import Foundation
import Synchronization
import llama

/// The outcome of asking whether a file can actually be opened here.
enum LlamaProbeVerdict: String, Codable, Sendable, Equatable, Hashable {
    /// llama.cpp opened the file.
    case opens
    /// The header names an architecture this build does not know.
    case unsupportedArchitecture
    /// The header names a pre-tokenizer this build does not know.
    case unsupportedTokenizer
    /// llama.cpp refused the file for some other reason.
    case failedToOpen
}

/// One probe's answer, stored on the model's manifest row so the decision is made once.
struct LlamaProbeResult: Codable, Sendable, Equatable, Hashable {
    let verdict: LlamaProbeVerdict
    /// The architecture, pre-tokenizer or error line the verdict is about.
    let detail: String?
    /// The llama.cpp build that made this call; a different build re-probes.
    let llamaBuildTag: String
    /// The file's size when it was probed; a different size re-probes.
    let fileBytes: Int64
}

/// What llama.cpp said during the most recent vocabulary-only open.
///
/// A C callback cannot capture Swift context, so the callback appends here and `probe`
/// reads the text after the load returns. The mutex is what makes that safe across the
/// threads llama.cpp logs from.
private let probeLog = Mutex("")

/// Decides whether llama.cpp can open a file without ever loading its weights.
///
/// The header answers the common refusal — an architecture this build does not know — with
/// no llama call at all; everything else goes through a vocabulary-only open, which reads
/// metadata and the tokenizer and stops before the weights. The full-weight count exists so
/// the self-test can prove that, not just take the claim.
enum LlamaLoadProbe {
    /// Every full-weight open in the process, so a probe can prove — not claim — that it
    /// did not load weights to answer the question.
    ///
    /// `NotesModelRuntime.openNative` calls `noteFullWeightLoad()` immediately before its
    /// `llama_model_load_from_file`.
    private nonisolated(unsafe) static var fullWeightLoads = 0

    static func fullWeightLoadCount() -> Int { fullWeightLoads }

    /// Called by `NotesModelRuntime.openNative` before a full-weight open.
    static func noteFullWeightLoad() { fullWeightLoads += 1 }

    /// Header first, then a vocab-only open with llama's log captured.
    static func probe(_ url: URL) async -> LlamaProbeResult {
        let bytes = ModelDownloader.fileSize(at: url)
        func result(_ verdict: LlamaProbeVerdict, detail: String?) -> LlamaProbeResult {
            LlamaProbeResult(
                verdict: verdict, detail: detail,
                llamaBuildTag: LlamaArchitectures.buildTag, fileBytes: bytes)
        }

        // A file whose header names an architecture this build does not know is refused
        // without asking llama to open anything at all.
        guard let metadata = GGUFMetadata.read(url) else {
            return result(.failedToOpen, detail: "not a model file")
        }
        if let architecture = metadata.architecture,
           !LlamaArchitectures.isSupported(architecture) {
            return result(.unsupportedArchitecture, detail: architecture)
        }

        // A vocabulary-only open is milliseconds even for gigabytes of weights, and it
        // catches what the header cannot: an unknown pre-tokenizer, a truncated file, a
        // supported name with nothing behind it.
        await LlamaBackend.shared.initialize()
        let (opened, log) = await LlamaBackend.shared.openVocabularyOnly(at: url.path)
        if opened {
            return result(.opens, detail: metadata.architecture)
        }
        if let name = quotedName(in: log, after: "unknown model architecture: '") {
            return result(.unsupportedArchitecture, detail: name)
        }
        if let name = quotedName(in: log, after: "unknown pre-tokenizer type: '") {
            return result(.unsupportedTokenizer, detail: name)
        }
        return result(.failedToOpen, detail: lastErrorLine(in: log))
    }

    /// The `<name>` out of llama's own `…: '<name>'` refusal.
    private static func quotedName(in log: String, after marker: String) -> String? {
        guard let start = log.range(of: marker) else { return nil }
        let rest = log[start.upperBound...]
        guard let end = rest.firstIndex(of: "'") else { return nil }
        return String(rest[..<end])
    }

    /// The last thing llama said, which is the reason the load returned nothing.
    private static func lastErrorLine(in log: String) -> String? {
        log.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .last { !$0.isEmpty }
    }
}

extension LlamaBackend {
    /// Opens a file's vocabulary only, with llama's own log captured for classification.
    ///
    /// Actor-isolated so it cannot overlap another backend-level llama call. It never loads
    /// weights: `vocab_only` stops after the metadata and the tokenizer, and the model is
    /// freed before this returns. The silent callback is restored in a `defer` — a global
    /// callback that kept capturing would swallow every later load's logs.
    func openVocabularyOnly(at path: String) -> (opened: Bool, log: String) {
        probeLog.withLock { $0 = "" }
        llama_log_set({ _, text, _ in
            guard let text else { return }
            probeLog.withLock { log in
                guard log.utf8.count < 16 * 1024 else { return }
                log += String(cString: text)
            }
        }, nil)
        defer { llama_log_set({ _, _, _ in }, nil) }

        var parameters = llama_model_default_params()
        parameters.vocab_only = true
        parameters.n_gpu_layers = 0
        let model = llama_model_load_from_file(path, parameters)
        if let model { llama_model_free(model) }
        return (model != nil, probeLog.withLock { $0 })
    }
}
