// Standalone, text-only SDK measurement; no product source or owner stores.
import Foundation
import FoundationModels
import Darwin

@available(macOS 27.0, *)
@main struct AppleSpeed {
    static let instructions = "You are a thorough writer."
    static let seed = "Describe, in many detailed paragraphs, a busy restaurant kitchen during a full dinner service. Keep writing; do not summarise or stop early."
    static let filler = " The cooks prepare fresh vegetables, sauces, soups, bread, fish and desserts while orders arrive and servers carry plates to the dining room."
    static func seconds(_ duration: Duration) -> Double {
        let c = duration.components
        return Double(c.seconds) + Double(c.attoseconds) / 1e18
    }
    static func emit(_ value: [String: Any]) {
        let data = try! JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
        FileHandle.standardOutput.write(data + Data([10]))
    }
    static func prompt(near target: Int) async throws -> String {
        var text = seed
        while try await SystemLanguageModel.default.tokenCount(for: text) < target { text += filler }
        let chars = Array(text)
        var low = 1, high = chars.count
        while low < high {
            let mid = (low + high + 1) / 2
            let count = try await SystemLanguageModel.default.tokenCount(for: String(chars.prefix(mid)))
            if count <= target { low = mid } else { high = mid - 1 }
        }
        return String(chars.prefix(low))
    }
    static func measure(_ text: String, label: String, round: Int, limit: Int) async throws {
        let apiPromptTokens = try await SystemLanguageModel.default.tokenCount(for: text)
        let session = LanguageModelSession(model: SystemLanguageModel.default, instructions: instructions)
        let start = ContinuousClock.now
        var first: ContinuousClock.Instant?, firstCount: Int?, lastCount = 0, input = 0, cached = 0, reasoning = 0, monotonicallyIncreasing = true
        let stream = session.streamResponse(to: text, options: GenerationOptions(sampling: .greedy, maximumResponseTokens: limit))
        for try await snapshot in stream {
            let count = snapshot.usage.output.totalTokenCount
            if count < lastCount { monotonicallyIncreasing = false }
            lastCount = count
            input = snapshot.usage.input.totalTokenCount
            cached = snapshot.usage.input.cachedTokenCount
            reasoning = snapshot.usage.output.reasoningTokenCount
            if first == nil && !snapshot.content.isEmpty { first = .now; firstCount = count }
        }
        let end = ContinuousClock.now
        var usage = rusage(); getrusage(RUSAGE_SELF, &usage)
        var record: [String: Any] = ["kind": label, "round": round, "limit": limit, "apiPromptTokens": apiPromptTokens, "inputTokens": input, "cachedInputTokens": cached, "outputTokens": lastCount, "reasoningTokens": reasoning, "totalSeconds": seconds(start.duration(to: end)), "ownPeakRSSBytes": usage.ru_maxrss, "monotonicUsage": monotonicallyIncreasing, "coldLoad": "unmeasured: no public unload/load timer", "modelServerMemory": "excluded: OS service outside this process"]
        if let first, let firstCount {
            let ttft = seconds(start.duration(to: first)), decode = seconds(first.duration(to: end))
            record["firstTextSeconds"] = ttft
            record["firstSnapshotOutputTokens"] = firstCount
            record["postFirstSnapshotSeconds"] = decode
            record["uncachedInputPerFirstTextSecondProxy"] = ttft > 0 ? Double(input - cached) / ttft : 0
            let qualified = limit == 256 && lastCount == 256 && firstCount > 0 && firstCount < lastCount && decode > 0 && reasoning == 0 && monotonicallyIncreasing
            record["fixed256PostSnapshotQualified"] = qualified
            if qualified { record["postFirstSnapshotDecodeTPS"] = Double(lastCount - firstCount) / decode }
        } else { record["fixed256PostSnapshotQualified"] = false }
        emit(record)
    }
    static func main() async {
        guard case .available = SystemLanguageModel.default.availability else {
            emit(["status": "UNAVAILABLE", "availability": String(describing: SystemLanguageModel.default.availability)]); exit(75)
        }
        do {
            for target in [512, 2048] {
                let text = try await prompt(near: target)
                for i in 1...3 { try await measure(text, label: "prefill-first-text-proxy-\(target)", round: i, limit: 1) }
            }
            for i in 1...3 { try await measure(seed, label: "decode256", round: i, limit: 256) }
            emit(["status": "MEASURED", "method": "SDK27 snapshots, fresh sessions; OS model/file cache unqualified; no voice/ASR"])
        } catch { emit(["status": "ERROR", "error": String(describing: error)]); exit(1) }
    }
}
