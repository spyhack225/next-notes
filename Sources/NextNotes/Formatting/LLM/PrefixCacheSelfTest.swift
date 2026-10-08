import Foundation
import llama

/// Cancel only at an observed successful native chunk boundary; no sleep or fake cache.
private final class PrefixCacheCancellationProbe: @unchecked Sendable {
    private let lock = NSLock()
    private let target: Int
    private var chunks = 0
    private var cancelled = false
    init(atChunk: Int) { target = atChunk }
    var didCancel: Bool { lock.withLock { cancelled } }
    func decoded() {
        let stop = lock.withLock { chunks += 1; return chunks == target }
        if stop {
            withUnsafeCurrentTask { task in
                task?.cancel()
                lock.withLock { cancelled = task != nil }
            }
        }
    }
}

/// `--selftest-llm-prefix-cache` (P0-18): the runtime keeps its KV cache across calls and
/// decodes only the tokens that changed.
///
/// **Red-first.** Part A is pure — the `PrefixReuse.keepCount` table and, for every family,
/// that `renderPrefix` / `renderHistory` really are prefixes of `render`. It fails on
/// today's tree because `keepCount` is a seam returning 0, which is the clear-and-re-prefill
/// behaviour the fix replaces. Part B drives a **private** `NotesModelRuntime` on S1-mini
/// (never the shared runtime) and reads `prefillStatsForTesting()` after each call. A
/// missing S1-mini is `LLM_PREFIX_CACHE_ABSENT`, and only after Part A passed: a missing
/// precondition is never a pass.
@MainActor
enum PrefixCacheSelfTest {
    /// REVIEW-LOG §4.4 item 4: batched and incremental decoding can round differently, so
    /// the first-token equality check may come out unequal in rare cases. If it does, drop
    /// this to 1 and record the deviation in STATUS — never delete the check.
    private static let identicalPieceCount = 4
    private static let generationBudget = 8

    /// The six families the runtime can render. `unsupported` renders nothing and has no
    /// prefix to check.
    private static let renderedFamilies: [ChatTemplateFamily] = [
        .chatmlThinking, .chatml, .llama3, .gemma, .gemma4, .minicpm5,
    ]

    private enum LiveOutcome {
        case ok(reused: Int, promptTokens: Int, firstSeconds: Double, secondSeconds: Double)
        case failed([String])
    }

    private struct Streamed: Sendable {
        var text = ""
        var pieces: [String] = []
        var error: String?
        var wasCancelled = false
    }

    static func runSelfTest() async -> Bool {
        if CommandLine.arguments.contains("--interactive-prefill-resident") {
            return await residentPrefillChecks()
        }
        if CommandLine.arguments.contains("--interactive-prefill") {
            return await interactivePrefillChecks()
        }
        if CommandLine.arguments.contains("--native-stream-finish") {
            return await nativeStreamFinishChecks()
        }
        let pure = pureFailures()
        for problem in pure {
            SelfTest.diagnostic("LLM_PREFIX_CACHE_WRONG: \(problem)")
        }
        guard pure.isEmpty else {
            SelfTest.diagnostic("LLM_PREFIX_CACHE_FAILED: \(pure.count) problem(s)")
            return false
        }

        guard S1MiniModels.spec.isDownloaded else {
            SelfTest.diagnostic("LLM_PREFIX_CACHE_ABSENT: S1-mini not downloaded")
            return false
        }

        switch await liveChecks() {
        case .ok(let reused, let promptTokens, let first, let second):
            SelfTest.diagnostic(
                "LLM_PREFIX_CACHE_OK: reused \(reused)/\(promptTokens) tokens, "
                    + "prefill \(formatted(first))s → \(formatted(second))s; "
                    + "stable prompt front \(stableFrontPercent)% "
                    + "(was 73% before P1-28)")
            return true
        case .failed(let problems):
            for problem in problems {
                SelfTest.diagnostic("LLM_PREFIX_CACHE_WRONG: \(problem)")
            }
            SelfTest.diagnostic("LLM_PREFIX_CACHE_FAILED: \(problems.count) problem(s)")
            return false
        }
    }

    /// Actual native stream -> provider recorder -> persisted usage reader. The same
    /// finite grammar must exhaust a small allowance and end normally with a larger one.
    /// The caller deliberately supplies its ordinary "stop" fallback in both cases.
    private static func nativeStreamFinishChecks() async -> Bool {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: "--model"),
              arguments.indices.contains(index + 1),
              arguments.filter({ $0 == "--model" }).count == 1,
              arguments[index + 1].hasPrefix("file:") else {
            SelfTest.diagnostic("NATIVE_STREAM_FINISH_FAILED: explicit --model file pin required")
            return false
        }
        let path = String(arguments[index + 1].dropFirst("file:".count))
        let file = URL(fileURLWithPath: path)
        // ModelSpec resolves its filename in Models. Match the existing file resolver's
        // directory admission, then require a regular existing file; never adopt defaults.
        guard file.path == path, file.pathExtension.lowercased() == "gguf",
              file.deletingLastPathComponent().standardizedFileURL ==
                  ModelSpec.directory.standardizedFileURL,
              let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              attributes[.type] as? FileAttributeType == .typeRegular,
              let bytes = (attributes[.size] as? NSNumber)?.int64Value, bytes > 0 else {
            SelfTest.diagnostic("NATIVE_STREAM_FINISH_FAILED: invalid or absent model file pin")
            return false
        }
        let spec = ModelSpec(
            displayName: file.deletingPathExtension().lastPathComponent,
            fileName: file.lastPathComponent, url: file,
            expectedBytes: bytes, expectedSHA256: nil)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "NextNotesStreamFinish-" + UUID().uuidString, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            SelfTest.diagnostic("NATIVE_STREAM_FINISH_FAILED: private usage directory unavailable")
            return false
        }
        let log = UsageLog(directory: directory)
        let runtime = NotesModelRuntime(spec: spec, gpuLayers: NotesModelRuntime.allGPULayers)
        let provider = LlamaLLMProvider(modelName: spec.displayName, runtime: runtime)
        let literal = "alpha bravo charlie delta echo foxtrot golf hotel india juliet"
        let grammar = GBNFGrammar(text: #"root ::= "alpha bravo charlie delta echo foxtrot golf hotel india juliet""#)
        let system = "Return exactly the requested fixed phrase."
        let user = literal
        var failures: [String] = []
        func check(_ condition: Bool, _ problem: String) {
            if !condition { failures.append(problem) }
        }
        do {
            // This check uses the pinned vocabulary, not a character/token estimate.
            let tokens = try await provider.countTokens(literal)
            guard tokens > 2, tokens < 64, grammar.structuralProblems().isEmpty else {
                throw CocoaError(.coderInvalidValue)
            }
            for (pass, cap, limited) in [
                ("native-stream-finish-limited", 2, true),
                ("native-stream-finish-complete", 64, false),
            ] {
                let turnID = UUID()
                let recorder = ModelPassRecorder(
                    feature: .agentTyped, pass: pass, provider: provider,
                    ids: UsageCorrelation(turnID: turnID), log: log)
                let result = await ModelPassRecorder.$current.withValue(recorder) {
                    await drain(await provider.stream(
                        system: system, user: user, maxTokens: cap, grammar: grammar),
                        recorder: recorder)
                }
                recorder.noteModelEnd()
                if let error = result.error { recorder.fail(message: error) }
                recorder.finish(reason: "stop")
                recorder.finish(reason: "stop") // Existing once-only commit remains once-only.
                log.flush()
                let rows = try UsageLog.loadForReport(directory: directory)
                let matching = rows.filter { $0.turnID == turnID }
                check(matching.count == 1, "\(pass): expected one persisted row for the actual turn")
                check(result.error == nil && !result.wasCancelled,
                      "\(pass): native stream failed or was cancelled")
                check(!result.text.isEmpty && literal.hasPrefix(result.text),
                      "\(pass): actual streamed output is not a nonempty authored prefix")
                check(limited ? result.text != literal : result.text == literal,
                      "\(pass): actual grammar completion does not match its allowance")
                guard let row = matching.first else { continue }
                check(row.pass == pass && row.feature == UsageFeature.agentTyped.rawValue
                          && row.provider == UsageProvider.llama.rawValue
                          && row.modelID == spec.displayName && row.locality == "local",
                      "\(pass): persisted row does not identify the actual pinned provider")
                check(row.countsEstimated == false && (row.promptTokens ?? 0) > 0,
                      "\(pass): native prompt/completion usage is absent or estimated")
                let completion = row.completionTokens ?? 0
                check(limited ? completion == cap : completion > 0 && completion < cap,
                      "\(pass): native generated count does not prove allowance/end distinction")
                check(row.cachedTokens != nil && (row.cachedTokens ?? -1) >= 0
                          && (row.cachedTokens ?? Int.max) <= (row.promptTokens ?? 0),
                      "\(pass): native cached-token count is absent or invalid")
                if !limited {
                    check((row.cachedTokens ?? 0) > 0 && row.warm == true,
                          "\(pass): same-runtime repeated prompt did not reuse its native prefix")
                }
                check(row.errorClass == nil, "\(pass): persisted usage records a native failure")
                check(row.finishReason == (limited ? "length" : "stop"),
                      "\(pass): persisted finish reason lost the actual native termination")
                check(row.truncated == limited,
                      "\(pass): persisted truncation lost the actual native termination")
                SelfTest.diagnostic(
                    "NATIVE_STREAM_FINISH_ROW pass=\(pass) cap=\(cap) "
                        + "prompt=\(row.promptTokens ?? -1) cached=\(row.cachedTokens ?? -1) "
                        + "completion=\(completion) estimated=\(row.countsEstimated == true) "
                        + "finish=\(row.finishReason ?? "nil") truncated=\(row.truncated == true)")
                // Authored fixture output only; never included in the usage record itself.
                SelfTest.diagnostic("NATIVE_STREAM_FINISH_OUTPUT pass=\(pass) text=\(result.text)")
            }
            check(try UsageLog.loadForReport(directory: directory).count == 2,
                  "expected exactly two native pass rows in the private usage log")
        } catch {
            failures.append("native grammar/usage qualification failed: \(error.localizedDescription)")
        }
        // Join the same private native owner before removing its temporary consumer files.
        check(await runtime.finishTermination(), "private native owner did not finish termination")
        log.flush()
        do { try FileManager.default.removeItem(at: directory) }
        catch { failures.append("private usage directory cleanup failed") }
        for problem in failures { SelfTest.diagnostic("NATIVE_STREAM_FINISH_WRONG: \(problem)") }
        SelfTest.diagnostic(failures.isEmpty ? "NATIVE_STREAM_FINISH_OK"
                          : "NATIVE_STREAM_FINISH_FAILED: \(failures.count) problem(s)")
        return failures.isEmpty
    }

    /// Additive real producer admission: optional partials cannot initiate cold
    /// weights/context work and strand the existing cancelled speculative owner.
    private static func residentPrefillChecks() async -> Bool {
        guard S1MiniModels.spec.isDownloaded else {
            SelfTest.diagnostic("RESIDENT_PREFILL_ABSENT")
            return false
        }
        let runtime = NotesModelRuntime(spec: S1MiniModels.spec, gpuLayers: 0)
        let messages: [LLMChatMessage] = [.init(role: .user, content: "First question.")]
        var problems: [String] = []
        func refused() async -> Bool {
            do {
                _ = try await runtime.prepareInteractiveConversation(system: fixtureSystem(), messages: messages,
                    maxTokens: generationBudget, residentOnly: true)
                return false
            } catch LlamaError.notLoaded { return true }
            catch { return false }
        }
        if !(await refused()) { problems.append("cold partial initiated native preparation") }
        if await runtime.loadAttemptCount != 0 { problems.append("cold partial entered actual weight loader") }
        do {
            try await runtime.prepare() // weights only, independently required setup
            if !(await refused()) { problems.append("weights-only partial initiated cold context/prefill") }
            if await runtime.loadAttemptCount != 1 { problems.append("resident refusal changed load count") }
            _ = try await runtime.prepareInteractiveConversation(system: fixtureSystem(), messages: messages,
                maxTokens: generationBudget)
            let ready = try await runtime.prepareInteractiveConversation(system: fixtureSystem(), messages: messages,
                maxTokens: generationBudget, residentOnly: true)
            if ready.decoded != 1 || ready.reused != ready.promptTokens - 1 {
                problems.append("prepared resident admission failed exact cache reuse")
            }
            let beforeGrowth = await runtime.prefillStatsForTesting()
            do {
                _ = try await runtime.prepareInteractiveConversation(system: fixtureSystem(), messages: messages,
                    maxTokens: 2048, residentOnly: true)
                problems.append("partial admitted context growth")
            } catch LlamaError.notLoaded {} catch { problems.append("context growth had wrong refusal") }
            if await runtime.prefillStatsForTesting() != beforeGrowth {
                problems.append("refused context growth changed committed prefix state")
            }
            let result = await drain(await runtime.streamInteractiveConversation(system: fixtureSystem(),
                messages: messages, maxTokens: generationBudget))
            if result.error != nil || result.text.isEmpty { problems.append("resident successor failed actual sampling") }
        } catch { problems.append("resident setup failed: \(error.localizedDescription)") }
        if !(await runtime.finishTermination()) { problems.append("resident owner termination failed") }
        for p in problems { SelfTest.diagnostic("RESIDENT_PREFILL_WRONG: \(p)") }
        SelfTest.diagnostic(problems.isEmpty ? "RESIDENT_PREFILL_OK" : "RESIDENT_PREFILL_FAILED: \(problems.count) problem(s)")
        return problems.isEmpty
    }

    /// Real private native owner: prefill-only -> revised prefix -> committed sampling.
    /// The existing chunk observer cancels only after successful native decode.
    private static func interactivePrefillChecks() async -> Bool {
        guard S1MiniModels.spec.isDownloaded else {
            SelfTest.diagnostic("INTERACTIVE_PREFILL_ABSENT: S1-mini not downloaded")
            return false
        }
        let runtime = NotesModelRuntime(spec: S1MiniModels.spec, gpuLayers: 0)
        let system = fixtureSystem()
        let messages: [LLMChatMessage] = [.init(role: .user, content: "First question.")]
        var problems: [String] = []
        do {
            let first = try await runtime.prepareInteractiveConversation(system: system, messages: messages, maxTokens: generationBudget)
            if first.reused != 0 || first.decoded != first.promptTokens || first.promptTokens <= 128 {
                problems.append("fresh prefill did not decode the entire actual rendered prompt")
            }
            let repeated = try await runtime.prepareInteractiveConversation(system: system, messages: messages, maxTokens: generationBudget)
            if repeated.promptTokens != first.promptTokens || repeated.decoded != 1 || repeated.reused != first.promptTokens - 1 {
                problems.append("matched prefill did not retain exact native prefix")
            }
            let committed = await drain(await runtime.streamInteractiveConversation(system: system, messages: messages, maxTokens: generationBudget))
            let sampled = await runtime.prefillStatsForTesting()
            if sampled?.decoded != 1 || committed.error != nil || committed.text.isEmpty {
                problems.append("actual committed sampler did not reuse prefilled prompt")
            }
            for user in ["First question. More words.", "Second question instead."] {
                let revised = try await runtime.prepareInteractiveConversation(system: system, messages: [.init(role: .user, content: user)], maxTokens: generationBudget)
                if revised.reused < first.promptTokens - 16 || revised.decoded <= 1 || revised.decoded >= revised.promptTokens {
                    problems.append("append/revision did not trim and decode the exact changed suffix")
                }
                let result = await drain(await runtime.streamInteractiveConversation(system: system, messages: [.init(role: .user, content: user)], maxTokens: generationBudget))
                if await runtime.prefillStatsForTesting()?.decoded != 1 || result.error != nil || result.text.isEmpty {
                    problems.append("revised prefill's actual commit failed")
                }
            }
            let different = try await runtime.prepareInteractiveConversation(system: differentOpeningSystem(), messages: messages, maxTokens: generationBudget)
            if different.reused > 8 { problems.append("changed instructions retained incompatible prompt tokens") }
            for partial in [true, false] {
                await runtime.resetPrefixCacheForTesting()
                let probe = PrefixCacheCancellationProbe(atChunk: partial ? 1 : (first.promptTokens + 127) / 128)
                await runtime.setPrefillChunkObserverForTesting { probe.decoded() }
                let cancelled = Task {
                    try await runtime.prepareInteractiveConversation(system: system, messages: messages, maxTokens: generationBudget)
                }
                let result = await cancelled.result
                await runtime.setPrefillChunkObserverForTesting(nil)
                if !probe.didCancel { problems.append("prefill cancellation never reached actual successful native chunk") }
                if case .success = result { problems.append("cancelled prefill reported success") }
                let successor = try await runtime.prepareInteractiveConversation(system: system, messages: messages, maxTokens: generationBudget)
                let expected = partial ? 128 : first.promptTokens - 1
                if successor.reused != expected { problems.append("cancelled prefill discarded known successful native prefix") }
            }
            let count = await runtime.prefillStatsForTesting()?.promptTokens
            do {
                _ = try await runtime.prepareInteractiveConversation(system: system, messages: messages, maxTokens: Int.max / 2)
                problems.append("sampling budget overflow was admitted")
            } catch {}
            if await runtime.prefillStatsForTesting()?.promptTokens != count { problems.append("rejected budget changed prefix statistics") }
        } catch { problems.append("prefill-only native entry failed: \(error.localizedDescription)") }
        if !(await runtime.finishTermination()) { problems.append("private owner did not finish termination") }
        for problem in problems { SelfTest.diagnostic("INTERACTIVE_PREFILL_WRONG: \(problem)") }
        SelfTest.diagnostic(problems.isEmpty ? "INTERACTIVE_PREFILL_OK" : "INTERACTIVE_PREFILL_FAILED: \(problems.count) problem(s)")
        return problems.isEmpty
    }

    // MARK: - Part A, pure

    /// P1-28 R2: how much of the system prompt two different requests share.
    ///
    /// The rule is about **position**, not about the set: every selected tool is still in the
    /// prompt (that is `--selftest-native-tools`'s job) and the grammar still comes from
    /// `manifest.selected`. What changed is that the part that varies per request moved to the
    /// very end, so a turn selecting a different class no longer invalidates the cache from
    /// section 3 onwards.
    /// The measured share of the system prompt two different requests have in common, as a
    /// percentage. Recorded in the marker because a number nobody reads is a bar nobody can
    /// tell has moved: this was 73 % before P1-28 and is recorded on every run after.
    private(set) static var stableFrontPercent = 0

    static func stableFrontFailures() -> [String] {
        var failures: [String] = []
        func manifest(for request: String) -> AgentCapabilityManifest {
            AgentCapabilityManifestBuilder.build(
                AgentCapabilityInputs.live(reader: .voiceFrontend), request: request)
        }
        // Two requests that cannot select the same classes: one is about mail, one about
        // files. If the shared front were small this is what would catch it.
        let mail = RealtimeAgent.plannerSystem(
            manifest: manifest(for: "Summarise my last emails"), voice: false,
            request: "Summarise my last emails")
        let files = RealtimeAgent.plannerSystem(
            manifest: manifest(for: "find the login handler file"), voice: false,
            request: "find the login handler file")
        guard mail.isEmpty == false, files.isEmpty == false else {
            return ["a planner system prompt came back empty, so there is no front to compare"]
        }
        let shared = mail.commonPrefix(with: files).count
        let ratio = Double(shared) / Double(min(mail.count, files.count))
        stableFrontPercent = Int(ratio * 100)
        // 80 % is the task's bar, and the measurement before the change was 484–1,012 of about
        // 2,000 — between a quarter and a half.
        if ratio < 0.8 {
            failures.append(
                "two requests selecting different classes share only \(shared) characters "
                    + "(\(Int(ratio * 100))%) of the smaller prompt, expected at least 80% — "
                    + "something that varies per request is still near the front")
        }
        // And the varying part really is at the end, by construction rather than by luck: the
        // last section of one prompt must not be the first section of the other's front.
        if let mailTail = mail.components(separatedBy: "\n\n").last,
           mailTail.contains("tool_call") || mailTail.contains("Also available:") {
            // Expected: the call format is last.
        } else {
            failures.append("the call format is not in the last section of the prompt")
        }
        return failures
    }

    private static func pureFailures() -> [String] {
        var failures: [String] = []

        let keepCases: [(cached: [llama_token], prompt: [llama_token], expected: Int)] = [
            ([], [1, 2, 3], 0),
            ([1, 2, 3], [1, 2, 3], 2),
            ([1, 2, 3, 4], [1, 2, 9], 2),
            ([1, 2], [1, 2, 3, 4], 2),
            ([5], [1], 0),
        ]
        for entry in keepCases {
            let actual = PrefixReuse.keepCount(cached: entry.cached, prompt: entry.prompt)
            if actual != entry.expected {
                failures.append(
                    "keepCount(cached: \(entry.cached), prompt: \(entry.prompt)) = \(actual), "
                        + "expected \(entry.expected)")
            }
        }

        // P1-28 R2, and it is pure: **two requests that select different classes must share
        // almost the whole system prompt.**
        //
        // This is the measurement the finding was traced from — two turns shared only 484–1,012
        // of about 2,000 tokens because the per-request rule lines sat at section 3, above
        // memory, skills and the date. It needs no model at all: the question is a property of
        // the assembled string, and that is what makes it worth having here rather than only in
        // the live half, which needs the Agent model and is `LLM_PREFIX_CACHE_ABSENT` without it.
        // Called directly rather than through `MainActor.assumeIsolated`, which *asserts*
        // isolation rather than checking it and takes the process down when it is wrong. The
        // enclosing enum is already `@MainActor`, so this is already on the main actor.
        failures.append(contentsOf: stableFrontFailures())

        let system = "You are a helpful assistant. Keep the answer short."
        let firstUser = LLMChatMessage(role: .user, content: "First question.")
        let firstAnswer = LLMChatMessage(role: .assistant, content: "First answer.")
        let secondUser = LLMChatMessage(role: .user, content: "Second question.")
        for family in renderedFamilies {
            let prefix = ChatTemplate.renderPrefix(family, system: system)
            let oneTurn = ChatTemplate.render(family, system: system, messages: [firstUser])
            if prefix.isEmpty || !oneTurn.hasPrefix(prefix) {
                failures.append(
                    "render(\(family.rawValue), [u1]) does not start with renderPrefix")
            }
            let history = ChatTemplate.renderHistory(family, system: system, messages: [firstUser])
            let manyTurns = ChatTemplate.render(
                family, system: system, messages: [firstUser, firstAnswer, secondUser])
            if history.isEmpty || !manyTurns.hasPrefix(history) {
                failures.append(
                    "render(\(family.rawValue), [u1, a1, u2]) does not start with "
                        + "renderHistory([u1])")
            }
        }
        return failures
    }

    // MARK: - Part B, live on a private runtime

    private static func liveChecks() async -> LiveOutcome {
        let runtime = NotesModelRuntime(spec: S1MiniModels.spec, gpuLayers: 0)
        var failures: [String] = []

        let system = fixtureSystem()
        let differentSystem = differentOpeningSystem()
        let firstUser = "First question."
        let secondUser = "Second question."

        // 1. A fresh runtime has nothing to reuse.
        let firstStream = await runtime.streamConversation(
            system: system,
            messages: [.init(role: .user, content: firstUser)],
            maxTokens: generationBudget)
        let first = await drain(firstStream)
        guard let stats1 = await runtime.prefillStatsForTesting() else {
            _ = await runtime.shutdown()
            return .failed(failures + ["call 1 produced no prefill statistics"])
        }
        if stats1.reused != 0 {
            failures.append("call 1 reused \(stats1.reused) tokens with an empty cache")
        }
        if let error = first.error {
            failures.append("call 1 failed: \(error)")
        }
        if first.text.isEmpty {
            failures.append("call 1 generated no text, so the equality probe has nothing to compare")
        }

        // 2. The same conversation with the answer appended shares most of the prefix.
        let secondMessages: [LLMChatMessage] = [
            .init(role: .user, content: firstUser),
            .init(role: .assistant, content: first.text),
            .init(role: .user, content: secondUser),
        ]
        let secondStream = await runtime.streamConversation(
            system: system, messages: secondMessages, maxTokens: generationBudget)
        let second = await drain(secondStream)
        guard let stats2 = await runtime.prefillStatsForTesting() else {
            _ = await runtime.shutdown()
            return .failed(failures + ["call 2 produced no prefill statistics"])
        }
        if Double(stats2.reused) < 0.8 * Double(stats1.promptTokens) {
            failures.append(
                "call 2 reused \(stats2.reused)/\(stats2.promptTokens) tokens, expected at least "
                    + "80% of call 1's \(stats1.promptTokens)")
        }
        if Double(stats2.decoded) >= 0.5 * Double(stats2.promptTokens) {
            failures.append(
                "call 2 decoded \(stats2.decoded)/\(stats2.promptTokens) tokens, expected less "
                    + "than half")
        }
        if stats2.seconds > 0.5 * stats1.seconds {
            failures.append(
                "call 2 prefill \(formatted(stats2.seconds))s is not at most half of call 1's "
                    + "\(formatted(stats1.seconds))s")
        }
        if let error = second.error {
            failures.append("call 2 failed: \(error)")
        }

        // 3. A system prompt that differs in its first sentence means nothing to keep.
        let thirdStream = await runtime.streamConversation(
            system: differentSystem,
            messages: [.init(role: .user, content: firstUser)],
            maxTokens: generationBudget)
        let third = await drain(thirdStream)
        guard let stats3 = await runtime.prefillStatsForTesting() else {
            _ = await runtime.shutdown()
            return .failed(failures + ["call 3 produced no prefill statistics"])
        }
        if stats3.reused > 8 {
            failures.append("call 3 reused \(stats3.reused) tokens after a different system prompt")
        }
        if let error = third.error {
            failures.append("call 3 failed: \(error)")
        }

        // 4. Reuse must not change the answer: the same call with the cache cleared generates
        // the same first pieces. The stream yields text pieces; with these prompts each piece
        // is one token's text.
        await runtime.resetPrefixCacheForTesting()
        let repeatedStream = await runtime.streamConversation(
            system: system, messages: secondMessages, maxTokens: generationBudget)
        let repeated = await drain(repeatedStream)
        // REVIEW-LOG §4.4 item 4: with a short generation the two passes can legitimately
        // produce fewer pieces than the probe asks for (measured 2026-09-24: 3 of 4, and
        // identical in both). Compare every piece both produced, never fewer than one, and
        // record the measured count rather than failing on length alone.
        let comparablePieces = min(identicalPieceCount,
                                   min(second.pieces.count, repeated.pieces.count))
        if comparablePieces < 1 {
            failures.append(
                "the equality probe generated \(second.pieces.count) and "
                    + "\(repeated.pieces.count) pieces, needs at least 1 each")
        } else {
            let expectedPieces = Array(second.pieces.prefix(comparablePieces))
            let repeatedPieces = Array(repeated.pieces.prefix(comparablePieces))
            if expectedPieces != repeatedPieces {
                failures.append(
                    "cached and cleared decoding generated different first pieces: "
                        + "\(expectedPieces) vs \(repeatedPieces)")
            }
        }
        if let error = repeated.error {
            failures.append("the cleared repeat failed: \(error)")
        }

        // 5. The typed prewarm prefills the typed prefix, and the next typed turn reuses it.
        // P1-02: the typed turn's first prompt is the planner's, so that is what the prewarm
        // fills and what this case measures against. Both sides move together, which is the
        // point: a prewarm of a prompt no typed turn sends passes nothing.
        do {
            try await runtime.prepareForConversation(workClass: .background, voice: false)
        } catch {
            failures.append(
                "prepareForConversation(voice: false) failed: \(error.localizedDescription)")
        }
        let typedSystem = await RealtimeAgent.typedWarmSystem()
        let family = await runtime.family
        let prefix = ChatTemplate.renderPrefix(family, system: typedSystem)
        if let prefixTokens = try? await runtime.countTokens(prefix) {
            let typedStream = await runtime.streamConversation(
                system: typedSystem,
                messages: [.init(role: .user, content: "What can you do?")],
                maxTokens: generationBudget)
            let typed = await drain(typedStream)
            guard let stats5 = await runtime.prefillStatsForTesting() else {
                _ = await runtime.shutdown()
                return .failed(failures + ["the typed call produced no prefill statistics"])
            }
            if stats5.reused < prefixTokens {
                failures.append(
                    "the warmed typed prefix was not reused: \(stats5.reused) < \(prefixTokens)")
            }
            if let error = typed.error {
                failures.append("the typed call failed: \(error)")
            }
        } else {
            failures.append("the typed prefix could not be tokenized")
        }

        // 6. A shutdown forgets the cache.
        _ = await runtime.shutdown()
        let afterStream = await runtime.streamConversation(
            system: system,
            messages: [.init(role: .user, content: firstUser)],
            maxTokens: generationBudget)
        let after = await drain(afterStream)
        guard let stats6 = await runtime.prefillStatsForTesting() else {
            _ = await runtime.shutdown()
            return .failed(failures + ["call 6 produced no prefill statistics"])
        }
        if stats6.reused != 0 {
            failures.append("call 6 reused \(stats6.reused) tokens after a shutdown")
        }
        if let error = after.error {
            failures.append("call 6 failed: \(error)")
        }
        failures += await cancellationReuseFailures(runtime, system: system,
            firstUser: firstUser, promptTokens: stats6.promptTokens)
        _ = await runtime.shutdown()

        if failures.isEmpty {
            return .ok(
                reused: stats2.reused,
                promptTokens: stats2.promptTokens,
                firstSeconds: stats1.seconds,
                secondSeconds: stats2.seconds)
        }
        return .failed(failures)
    }

    private static func cancellationReuseFailures(
        _ runtime: NotesModelRuntime, system: String, firstUser: String, promptTokens: Int
    ) async -> [String] {
        // The producer currently decodes prompt chunks of at most128 native tokens.
        guard promptTokens > 128 else { return ["cancelled prefill fixture needs more than128 actual tokens"] }
        var failures: [String] = []
        for partialPrefill in [true, false] {
            await runtime.resetPrefixCacheForTesting()
            let probe = PrefixCacheCancellationProbe(atChunk: partialPrefill ? 1 : (promptTokens + 127) / 128)
            await runtime.setPrefillChunkObserverForTesting { probe.decoded() }
            let cancelledStream = await runtime.streamInteractiveConversation(
                system: system, messages: [.init(role: .user, content: firstUser)],
                maxTokens: generationBudget)
            let cancelled = await drain(cancelledStream)
            await runtime.setPrefillChunkObserverForTesting(nil)
            let name = partialPrefill ? "partial prefill" : "completed prefill before sampling"
            if !probe.didCancel || !cancelled.wasCancelled || !cancelled.text.isEmpty {
                failures.append("\(name) did not cancel its actual native producer before output")
                continue
            }
            let finalUser = partialPrefill ? firstUser + " Please explain." : firstUser
            let successor = await runtime.streamInteractiveConversation(
                system: system, messages: [.init(role: .user, content: finalUser)],
                maxTokens: generationBudget)
            let result = await drain(successor)
            guard let stats = await runtime.prefillStatsForTesting() else {
                failures.append("\(name) successor has no native prefill counters")
                continue
            }
            let expected = partialPrefill ? 128 : stats.promptTokens - 1
            if stats.reused != expected || stats.decoded != stats.promptTokens - expected {
                failures.append("\(name) discarded native-success prefix: reused\(stats.reused), expected\(expected)")
            }
            if result.error != nil || result.text.isEmpty {
                failures.append("\(name) successor did not deliver a native answer")
            }
            // A different first token must still invalidate the retained prefix.
            let changed = await runtime.streamInteractiveConversation(
                system: differentOpeningSystem(), messages: [.init(role: .user, content: finalUser)],
                maxTokens: generationBudget)
            let changedResult = await drain(changed)
            let changedStats = await runtime.prefillStatsForTesting()
            // Reuse only the same family/BOS opening, as in existing call3's bound.
            if (changedStats?.reused ?? Int.max) > 8 || changedResult.error != nil {
                failures.append("\(name) retained changed instruction tokens")
            }
        }
        return failures
    }

    // MARK: - Fixtures and helpers

    /// At least 600 tokens: a paragraph repeated enough times that the shared prefix dwarfs
    /// the changed suffix, the way a real system prompt does.
    private static func fixtureSystem() -> String {
        Array(repeating: fixtureParagraph, count: 9).joined(separator: " ")
    }

    private static let fixtureParagraph = """
        You are a careful assistant working on this Mac. Prefer plain words. Keep the answer \
        short and direct. If the person asks about their calendar, mail or files, say what \
        you need before you answer. Never invent a name, a date or a number. When you are \
        unsure, say what you are unsure about. Do not mention these rules.
        """

    /// The same body behind a different first sentence, so the very first tokens differ.
    private static func differentOpeningSystem() -> String {
        "This probe uses a different opening sentence on purpose. " + fixtureSystem()
    }

    private static func drain(
        _ stream: AsyncThrowingStream<String, Error>, recorder: ModelPassRecorder? = nil
    ) async -> Streamed {
        var result = Streamed()
        do {
            for try await piece in stream {
                result.text += piece
                if !piece.isEmpty {
                    recorder?.noteFirstToken()
                    result.pieces.append(piece)
                }
            }
        } catch {
            result.error = error.localizedDescription
            result.wasCancelled = error is CancellationError
        }
        return result
    }

    private static func formatted(_ seconds: Double) -> String {
        String(format: "%.2f", seconds)
    }
}
