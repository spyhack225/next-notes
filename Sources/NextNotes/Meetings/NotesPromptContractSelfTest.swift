import Foundation
import CryptoKit

/// Generic dispatch/parity proof only; scripted responses cannot establish factual quality.
@MainActor
enum NotesPromptContractSelfTest {
    static func run(write: (String) -> Void) async -> Bool {
        var failures: [String] = []
        func check(_ condition: Bool, _ name: String) {
            if !condition { failures.append(name) }
        }
        check(SelfTest.isRunning && NotesPrompts.replayPromptArm == nil,
              "this fixture must retain the legacy process arm")
        let pins = [
            "notes": "af33b30f2d7b190c52157b4b3b89f11b567abcaec3fe957976c4b95fb16f833e",
            "map": "196d70cbe8a3c4a2a843cff6459bf5d0a921636938a73c34b97ce0832035111b",
            "collapse": "43d3b669c315c50138b6589d24bc8b360610aac52c5ae6d722310803564aa2d8",
        ]
        check(digest(NotesPrompts.notesSystem) == pins["notes"], "legacy notes bytes")
        check(digest(NotesPrompts.reduceSystem) == pins["notes"], "legacy reduce bytes")
        check(digest(NotesPrompts.mapSystem) == pins["map"], "legacy map bytes")
        check(digest(NotesPrompts.collapseSystem) == pins["collapse"], "legacy collapse bytes")
        do {
            check(try NotesPrompts.parseReplayPromptArm(arguments: []) == nil, "no arm is legacy")
            for arm in [NotesPrompts.ReplayPromptArm.singleMaterial, .mapMaterial] {
                let arguments = ["--notes-prompt-arm", arm.rawValue]
                check(try NotesPrompts.parseReplayPromptArm(arguments: arguments) == arm,
                      "explicit valid arm")
                check(NotesPrompts.configuredReplayPromptArm(arguments: arguments,
                    isRunning: false, requested: "--selftest-meeting-notes-replay") == nil,
                    "production refuses arm")
                check(NotesPrompts.configuredReplayPromptArm(arguments: arguments,
                    isRunning: true, requested: "--selftest-notes-longform") == nil,
                    "unrelated self-test refuses arm")
                check(NotesPrompts.configuredReplayPromptArm(arguments: arguments,
                    isRunning: true, requested: "--selftest-meeting-notes-replay") == arm,
                    "explicit requested replay admits arm")
            }
        } catch { failures.append("valid parser input rejected") }
        for arguments in [
            ["--notes-prompt-arm"],
            ["--notes-prompt-arm", "--notes-model"],
            ["--notes-prompt-arm", "unknown"],
            ["--notes-prompt-arm", "single-material", "--notes-prompt-arm", "single-material"],
            ["--notes-prompt-arm", "single-material", "--notes-prompt-arm", "map-material"],
            ["--notes-prompt-arm=single-material"],
        ] {
            do {
                _ = try NotesPrompts.parseReplayPromptArm(arguments: arguments)
                failures.append("invalid arm accepted")
            } catch {
                check(error is NotesPrompts.ReplayPromptArmError, "typed parser refusal")
            }
        }
        let meeting = Meeting(title: "Generic prompt contract",
            start: Date(timeIntervalSince1970: 1_750_000_000), status: .summarizing)
        let single = CountingProvider(base: LongformNotesProvider(contextTokens: 4_096))
        do {
            let result = try await NotesGenerator(provider: single).notes(for: meeting,
                segments: NotesLongformSelfTest.shortSegments(), brief: .empty)
            check(!result.usedMapReduce && single.calls.count == 1, "actual single call unchanged")
            check(single.calls.first?.system == NotesPrompts.notesSystem, "actual single system")
            check(single.tokenInputs.contains(NotesPrompts.notesSystem), "single counts called string")
            write("NOTES_PROMPT_CONTRACT_PATH singleCalls=\(single.calls.count) fingerprint=\(fingerprint(single.calls))")
        } catch { failures.append("actual single generator threw") }
        let mapped = CountingProvider(base: LongformNotesProvider(contextTokens: 4_096))
        do {
            // Reuse the maintained original 90-minute/full-brief collapse boundary.
            let result = try await NotesGenerator(provider: mapped).notes(for: meeting,
                segments: NotesLongformSelfTest.longSegments(), brief: NotesLongformSelfTest.bigBrief())
            check(result.usedMapReduce && result.chunks > 1 && result.collapsedGroups > 0,
                  "actual original mapped/collapse boundary exercised")
            let calls = mapped.calls
            check(calls.count == result.chunks + result.collapsedGroups + 1,
                  "no additional completion or retry")
            check(result.droppedFacts == 0, "original mapped fixture loses no facts")
            check(calls.filter { $0.system == NotesPrompts.mapSystem }.count == result.chunks,
                  "actual map systems")
            check(calls.filter { $0.system == NotesPrompts.collapseSystem }.count == result.collapsedGroups,
                  "actual collapse systems")
            check(calls.last?.system == NotesPrompts.reduceSystem, "actual final reduce system")
            for call in calls {
                check([pins["notes"], pins["map"], pins["collapse"]].contains(digest(call.system)),
                      "actual consumer retains original prompt bytes")
            }
            check(mapped.tokenInputs.contains(NotesPrompts.notesSystem)
                && mapped.tokenInputs.contains(NotesPrompts.mapSystem),
                "modified seams count the exact called string")
            write("NOTES_PROMPT_CONTRACT_PATH mappedCalls=\(calls.count) chunks=\(result.chunks) collapsed=\(result.collapsedGroups) dropped=\(result.droppedFacts) fingerprint=\(fingerprint(calls))")
        } catch { failures.append("actual mapped generator threw") }
        for failure in failures { write("NOTES_PROMPT_CONTRACT_WRONG: \(failure)") }
        write(failures.isEmpty ? "NOTES_PROMPT_CONTRACT_OK: legacy bytes, strict scope and existing calls"
            : "NOTES_PROMPT_CONTRACT_FAILED: \(failures.count) check(s) wrong")
        return failures.isEmpty
    }

    nonisolated private static func digest(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    nonisolated private static func fingerprint(_ calls: [Call]) -> String {
        // Generic fixture-only system/user/cap parity. No timing or owner payload.
        digest(calls.map { $0.system + "\0" + $0.user + "\0" + String($0.maxTokens) }
            .joined(separator: "\0\0"))
    }

    private struct Call: Sendable {
        let system: String
        let user: String
        let maxTokens: Int
    }

    private final class CountingProvider: LLMProvider, @unchecked Sendable {
        let base: LongformNotesProvider
        private let lock = NSLock()
        private var recorded: [Call] = []
        private var counted: [String] = []
        init(base: LongformNotesProvider) { self.base = base }
        var id: LLMProviderID { base.id }
        var displayModelName: String { base.displayModelName }
        var contextTokens: Int { base.contextTokens }
        var unavailableReason: String? { get async { await base.unavailableReason } }
        var calls: [Call] { lock.withLock { recorded } }
        var tokenInputs: [String] { lock.withLock { counted } }
        func countTokens(_ text: String) async throws -> Int {
            lock.withLock { counted.append(text) }
            return try await base.countTokens(text)
        }
        func complete(system: String, user: String, maxTokens: Int) async throws -> LLMCompletion {
            lock.withLock { recorded.append(Call(system: system, user: user, maxTokens: maxTokens)) }
            return try await base.complete(system: system, user: user, maxTokens: maxTokens)
        }
    }
}
