import Foundation
import llama

/// `--selftest-chat-template` (P0-04): per-family templates and control-token survival.
///
/// Six cases. Detection, rendering and the runtime's family renderer are pure. The last two
/// open a vocabulary `vocab_only` — weights are never loaded and nothing is written — so the
/// planner decode can be asked about real control tokens:
///
/// 1. detection for the six families plus `unsupported`;
/// 2. exact rendering for each family, and Gemma never falls back to ChatML;
/// 3. `NotesModelRuntime.render(forFamily:)`, the helper the runtime calls, uses the family;
/// 4. S1-mini's `<|im_end|>` survives `LlamaHelpers.piece(renderSpecial: true)` and the
///    planner decode (`NotesModelRuntime.plannerPiece`);
/// 5. MiniCPM5 (G N3): the control-token delimiters of a native call survive the planner
///    decode, and render as "" without the flag;
/// 6. `CHAT_TEMPLATE_OK` / `CHAT_TEMPLATE_FAILED`.
@MainActor
enum ChatTemplateSelfTest {
    private static let probeMessages: [LLMChatMessage] = [.init(role: .user, content: "U")]

    /// The failures, without the final marker. `runSelfTest()` prints it for a Bool
    /// registration; exactly one of the two is used.
    static func run() async -> [String] {
        var failures: [String] = []
        failures += detectionFailures()
        failures += renderingFailures()
        failures += runtimeFamilyFailures()
        let s1Mini = await s1MiniControlTokenFailures()
        failures += s1Mini
        let miniCPM5 = await miniCPM5Failures()
        failures += miniCPM5
        return failures
    }

    static func runSelfTest() async -> Bool {
        let failures = await run()
        for failure in failures { SelfTest.diagnostic("chat-template · \(failure)") }
        SelfTest.diagnostic(
            failures.isEmpty
                ? "CHAT_TEMPLATE_OK: 6 families detected and rendered; control tokens survive planner decode"
                : "CHAT_TEMPLATE_FAILED: \(failures.count) problem(s)")
        return failures.isEmpty
    }

    // MARK: - Detection

    private static func detectionFailures() -> [String] {
        let cases: [(template: String, architecture: String?, expected: ChatTemplateFamily)] = [
            ("{{- '<|turn>system\n' -}}…{{- '<|turn>model\n' -}}", nil, .gemma4),
            ("<start_of_turn>user", nil, .gemma),
            ("<|start_header_id|>", nil, .llama3),
            ("<|im_start|>… enable_thinking …<think>", nil, .chatmlThinking),
            ("<|im_start|>assistant\n", "qwen3", .chatml),
            ("<|ifm|im_start|>", nil, .unsupported),
        ]
        var failures: [String] = []
        for entry in cases {
            let actual = ChatTemplate.detect(
                template: entry.template, architecture: entry.architecture)
            if actual != entry.expected {
                failures.append(
                    "detect(\(quoted(String(entry.template.prefix(40))))) = \(actual.rawValue), "
                        + "expected \(entry.expected.rawValue)")
            }
        }
        return failures
    }

    // MARK: - Rendering

    private static func renderingFailures() -> [String] {
        let expected: [(family: ChatTemplateFamily, prompt: String)] = [
            (.gemma4, "<|turn>system\nS<turn|>\n<|turn>user\nU<turn|>\n<|turn>model\n"),
            (.llama3, "<|start_header_id|>system<|end_header_id|>\n\nS<|eot_id|>"
                + "<|start_header_id|>user<|end_header_id|>\n\nU<|eot_id|>"
                + "<|start_header_id|>assistant<|end_header_id|>\n\n"),
            (.gemma, "<start_of_turn>user\nS\n\nU<end_of_turn>\n<start_of_turn>model\n"),
            (.chatml, "<|im_start|>system\nS<|im_end|>\n<|im_start|>user\nU<|im_end|>\n"
                + "<|im_start|>assistant\n"),
            (.chatmlThinking, "<|im_start|>system\nS<|im_end|>\n<|im_start|>user\nU<|im_end|>\n"
                + "<|im_start|>assistant\n<think>\n\n</think>\n\n"),
            (.minicpm5, "<|im_start|>system\nS<|im_end|>\n<|im_start|>user\nU<|im_end|>\n"
                + "<|im_start|>assistant\n<think>\n\n</think>\n\n"),
        ]
        var failures: [String] = []
        for entry in expected {
            let rendered = ChatTemplate.render(entry.family, system: "S", messages: probeMessages)
            if rendered != entry.prompt {
                failures.append(
                    "render(\(entry.family.rawValue)) = \(quoted(rendered)), "
                        + "expected \(quoted(entry.prompt))")
            }
            if (entry.family == .gemma || entry.family == .gemma4), rendered.contains("<|im_start|>") {
                failures.append("render(\(entry.family.rawValue)) fell back to ChatML")
            }
        }
        return failures
    }

    // MARK: - The runtime's renderer

    private static func runtimeFamilyFailures() -> [String] {
        var failures: [String] = []
        let rendered = NotesModelRuntime.render(
            forFamily: .gemma4, system: "S", messages: probeMessages)
        if rendered.contains("<|im_start|>") {
            failures.append("NotesModelRuntime.render(forFamily: .gemma4) produced ChatML")
        }
        let viaTemplate = ChatTemplate.render(.gemma4, system: "S", messages: probeMessages)
        if rendered != viaTemplate {
            failures.append("NotesModelRuntime.render(forFamily:) and ChatTemplate.render disagree")
        }
        return failures
    }

    // MARK: - Special tokens, live

    /// Case 4: S1-mini's vocabulary knows `<|im_end|>` as one special token, and both the
    /// explicit `renderSpecial: true` call and the planner decode return it literally.
    private static func s1MiniControlTokenFailures() async -> [String] {
        guard S1MiniModels.spec.isDownloaded else {
            SelfTest.diagnostic(
                "S1MINI_ABSENT: S1-mini is not downloaded, so the special-token case was skipped")
            return []
        }
        await LlamaBackend.shared.initialize()
        guard let failures = withVocabulary(
            at: S1MiniModels.spec.fileURL,
            { (vocabulary: OpaquePointer) -> [String] in
                var failures: [String] = []
                guard let tokens = try? LlamaHelpers.tokenize(
                    "<|im_end|>", vocabulary: vocabulary),
                    tokens.count == 1, let token = tokens.first
                else {
                    failures.append("S1-mini: “<|im_end|>” did not tokenize to exactly one token")
                    return failures
                }
                let rendered = LlamaHelpers.piece(
                    token, vocabulary: vocabulary, renderSpecial: true)
                if rendered != "<|im_end|>" {
                    failures.append(
                        "S1-mini: piece(renderSpecial: true) rendered \(quoted(rendered)), "
                            + "expected “<|im_end|>”")
                }
                let planner = NotesModelRuntime.plannerPiece(token, vocabulary: vocabulary)
                if planner != "<|im_end|>" {
                    failures.append(
                        "S1-mini: the planner decode rendered \(quoted(planner)), "
                            + "expected “<|im_end|>”")
                }
                return failures
            })
        else {
            return ["S1-mini: its vocabulary could not be opened"]
        }
        return failures
    }

    /// Case 5: MiniCPM5's two pure markers outrank ChatML and ask for an explicit BOS, and a
    /// live native call keeps its `<function …>` / `<param …>` delimiters through the
    /// planner decode (G N3).
    private static func miniCPM5Failures() async -> [String] {
        var failures: [String] = []
        if ChatTemplate.detect(
            template: "{{ bos_token }}<|im_start|>…<function name=",
            architecture: "llama") != .minicpm5 {
            failures.append("detect(template with <function name=) was not minicpm5")
        }
        if ChatTemplate.detect(
            template: nil, architecture: "llama", preTokenizer: "minicpm5") != .minicpm5 {
            failures.append("detect(preTokenizer: minicpm5) was not minicpm5")
        }
        if !ChatTemplate.needsExplicitBOS(
            template: "{{ bos_token }}<|im_start|>", vocabularyAddsBOS: false) {
            failures.append(
                "needsExplicitBOS is false for a template that starts with {{ bos_token }}")
        }
        if ChatTemplate.needsExplicitBOS(
            template: "{{ bos_token }}<|im_start|>", vocabularyAddsBOS: true) {
            failures.append("needsExplicitBOS is true for a vocabulary that already adds BOS")
        }

        guard let url = miniCPM5FileURL() else {
            SelfTest.diagnostic(
                "MINICPM5_ABSENT: no MiniCPM5 file in \(ModelSpec.directory.path), "
                    + "so the control-token case was skipped")
            return failures
        }
        await LlamaBackend.shared.initialize()
        guard let live = withVocabulary(
            at: url,
            { (vocabulary: OpaquePointer) -> [String] in
                miniCPM5LiveFailures(vocabulary: vocabulary)
            })
        else {
            failures.append(
                "MiniCPM5: \(url.lastPathComponent) could not be opened vocabulary-only")
            return failures
        }
        return failures + live
    }

    private static func miniCPM5LiveFailures(vocabulary: OpaquePointer) -> [String] {
        let call = "<function name=\"x\"><param name=\"k\">v</param></function>"
        guard let tokens = try? LlamaHelpers.tokenize(call, vocabulary: vocabulary) else {
            return ["MiniCPM5: the native call could not be tokenized"]
        }
        var failures: [String] = []
        let delimiters: [(id: llama_token, marker: String)] = [
            (18, "<function"),
            (20, "<param"),
            (21, "</param>"),
            (19, "</function>"),
        ]
        for delimiter in delimiters {
            guard tokens.contains(delimiter.id) else {
                failures.append(
                    "MiniCPM5: token id \(delimiter.id) is missing from the tokenized native call")
                continue
            }
            let rendered = NotesModelRuntime.plannerPiece(delimiter.id, vocabulary: vocabulary)
            if rendered != delimiter.marker {
                failures.append(
                    "MiniCPM5: plannerPiece(\(delimiter.id)) = \(quoted(rendered)), "
                        + "expected \(quoted(delimiter.marker))")
            }
        }
        if tokens.contains(18) {
            // The loss this task fixes: without the planner flag a control token is "".
            let stripped = LlamaHelpers.piece(18, vocabulary: vocabulary, renderSpecial: false)
            if !stripped.isEmpty {
                failures.append(
                    "MiniCPM5: piece(18, renderSpecial: false) = \(quoted(stripped)), "
                        + "expected a control token to render as empty")
            }
        }
        return failures
    }

    // MARK: - Helpers

    /// Opens a model's vocabulary only and frees it before returning: no weights, no
    /// contexts, nothing left resident.
    private static func withVocabulary<T>(
        at url: URL, _ body: (OpaquePointer) -> T
    ) -> T? {
        var parameters = llama_model_default_params()
        parameters.vocab_only = true
        parameters.n_gpu_layers = 0
        guard let model = llama_model_load_from_file(url.path, parameters),
              let vocabulary = llama_model_get_vocab(model)
        else { return nil }
        defer { llama_model_free(model) }
        return body(vocabulary)
    }

    /// The MiniCPM5 file by name, read-only, so the case runs without the library store
    /// having to select it.
    private static func miniCPM5FileURL() -> URL? {
        let directory = ModelSpec.directory
        guard let names = try? FileManager.default.contentsOfDirectory(
            atPath: directory.path)
        else { return nil }
        guard let name = names.first(where: {
            $0.localizedCaseInsensitiveContains("MiniCPM5") && $0.lowercased().hasSuffix(".gguf")
        }) else { return nil }
        return directory.appendingPathComponent(name)
    }

    private static func quoted(_ text: String) -> String {
        "“\(text)”"
    }
}
