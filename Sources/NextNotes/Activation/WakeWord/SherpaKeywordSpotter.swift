import AVFoundation
import Foundation
import SherpaOnnxKWS

/// Loads the downloaded sherpa-onnx dylib and runs keyword spotting on PCM.
///
/// The C API is reached through `SherpaOnnxKWS` so a missing dylib is a runtime error
/// (`WAKE_MODEL_MISSING` / load failure), not a link error at `make build`.
final class SherpaKeywordSpotter: @unchecked Sendable {
    private let raw: OpaquePointer
    private let lock = NSLock()

    init(
        dylibDirectory: URL,
        encoder: URL,
        decoder: URL,
        joiner: URL,
        tokens: URL,
        keywords: URL,
        threshold: Float
    ) throws {
        let spotter = dylibDirectory.path.withCString { dylib in
            encoder.path.withCString { enc in
                decoder.path.withCString { dec in
                    joiner.path.withCString { join in
                        tokens.path.withCString { tok in
                            keywords.path.withCString { keys in
                                nn_wake_create(dylib, enc, dec, join, tok, keys, threshold)
                            }
                        }
                    }
                }
            }
        }
        guard let spotter else {
            let reason = String(cString: nn_wake_last_error())
            throw AgentError.backendUnavailable(
                reason.isEmpty ? "The keyword model failed to load." : reason
            )
        }
        raw = spotter
    }

    deinit {
        nn_wake_destroy(raw)
    }

    /// Returns the fired keyword, or nil.
    func accept(samples: [Float], sampleRate: Int32 = 16_000) -> String? {
        lock.lock()
        defer { lock.unlock() }
        let hit = samples.withUnsafeBufferPointer { buffer -> Int32 in
            guard let base = buffer.baseAddress else { return 0 }
            return nn_wake_accept(raw, base, Int32(buffer.count), sampleRate)
        }
        guard hit != 0 else { return nil }
        return String(cString: nn_wake_keyword(raw))
    }

    func reset() {
        lock.lock()
        nn_wake_reset(raw)
        lock.unlock()
    }

    /// Feed a WAV through the spotter. Used by `--selftest-wake` so "loaded" is not a claim.
    func spot(wav url: URL) throws -> String? {
        var samples = try AudioConversion.monoSamples(fromFileAt: url, sampleRate: 16_000)
        samples.append(contentsOf: [Float](repeating: 0, count: 16_000))
        let rate: Int32 = 16_000
        var spotted: String?
        let chunk = 3_200
        var start = 0
        while start < samples.count {
            let end = min(start + chunk, samples.count)
            if let keyword = accept(samples: Array(samples[start..<end]), sampleRate: rate) {
                spotted = keyword
            }
            start = end
        }
        lock.lock()
        if nn_wake_finish(raw) != 0 {
            spotted = String(cString: nn_wake_keyword(raw))
        }
        lock.unlock()
        return spotted
    }
}
