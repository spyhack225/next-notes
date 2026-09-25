import Foundation

/// How one model family marks its turns (P0-04).
enum ChatTemplateFamily: String, Codable, Sendable {
    case chatmlThinking
    case chatml
    case llama3
    case gemma
    case gemma4
    case minicpm5
    case unsupported
}

/// One renderer per family, because llama.cpp at b10621 does not ship a template engine
/// that knows Gemma 4 or Qwen's thinking variant.
///
/// The table this implements is in `roadmap/in-progress/AGENT-OVERHAUL/01-PHASE-0-MAKE-IT-ANSWER.md`,
/// `### P0-04`. The markers were read from each model's own `tokenizer.chat_template`;
/// re-check one by reading it from the GGUF (`GGUFMetadata.read(url).chatTemplate`) whenever
/// a family misbehaves.
enum ChatTemplate {
    /// The family a model's own template names. Detection order matters: MiniCPM5 first
    /// (its template is also ChatML), then Gemma 4, Gemma, Llama 3, then ChatML.
    static func detect(
        template: String?,
        architecture: String?,
        preTokenizer: String? = nil
    ) -> ChatTemplateFamily {
        if (preTokenizer ?? "").lowercased() == "minicpm5" { return .minicpm5 }
        guard let template, !template.isEmpty else {
            // No template at all: the Qwen architectures this app already knows are
            // ChatML-with-thinking (S1-mini's case). Anything else cannot be rendered.
            if let architecture = architecture?.lowercased(),
               ["qwen2", "qwen3", "qwen35"].contains(architecture) {
                return .chatmlThinking
            }
            return .unsupported
        }
        // Before the ChatML rule: MiniCPM5's template also contains `<|im_start|>`, and its
        // native call spelling is the one concrete reason this family exists (G N3).
        if template.contains("<function name=") { return .minicpm5 }
        if template.contains("<|turn>") { return .gemma4 }
        if template.contains("<start_of_turn>") { return .gemma }
        if template.contains("<|start_header_id|>") { return .llama3 }
        if template.contains("<|im_start|>") {
            if template.contains("enable_thinking") { return .chatmlThinking }
            // A hybrid template can emit `<think>` in its generation prompt without naming
            // a switch. Look only after `add_generation_prompt`: non-thinking templates
            // still mention `<think>` in their history-stripping branch (Qwen3-2507).
            if let range = template.range(of: "add_generation_prompt") {
                if template[range.upperBound...].contains("<think>") { return .chatmlThinking }
            } else if template.contains("<think>") {
                return .chatmlThinking
            }
            return .chatml
        }
        return .unsupported
    }

    /// True when the template starts with `{{ bos_token }}` and the vocabulary does not add
    /// BOS itself, so the runtime has to prepend BOS as a token (MiniCPM5: `<s>`, id 0,
    /// while `add_bos_token = false`). It is never written as the text `<s>`.
    static func needsExplicitBOS(template: String?, vocabularyAddsBOS: Bool) -> Bool {
        guard !vocabularyAddsBOS, let template else { return false }
        let normalized = template
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "{{-", with: "{{")
            .replacingOccurrences(of: "{{ ", with: "{{")
        return normalized.hasPrefix("{{bos_token")
    }

    /// The prompt for `family`, ending in the generation prompt with thinking already
    /// closed where the family has it. An unsupported family renders nothing: the runtime
    /// refuses the model before this can be called in production.
    static func render(
        _ family: ChatTemplateFamily,
        system: String,
        messages: [LLMChatMessage]
    ) -> String {
        switch family {
        case .chatmlThinking, .chatml, .minicpm5, .llama3, .gemma, .gemma4:
            return renderHistory(family, system: system, messages: messages)
                + generationPrompt(family)
        case .unsupported:
            return ""
        }
    }

    /// The exact text `render(_:system:messages:)` starts with, whatever the messages
    /// (P0-18): the text a warm-up can prefill with no sampling and no model interaction.
    ///
    /// For every family but Gemma this is the closed system turn, which the history renders
    /// before the first message. Gemma has no system role — its system text merges into the
    /// first user turn — so its prefix stops where a user message continues with `"\n\n"`
    /// and an assistant message closes the turn instead.
    static func renderPrefix(_ family: ChatTemplateFamily, system: String) -> String {
        switch family {
        case .chatmlThinking, .chatml, .minicpm5:
            return "<|im_start|>system\n\(safe(system, for: family))<|im_end|>\n"
        case .llama3:
            return "<|start_header_id|>system<|end_header_id|>\n\n"
                + "\(safe(system, for: .llama3))<|eot_id|>"
        case .gemma:
            return "<start_of_turn>user\n\(safe(system, for: .gemma))"
        case .gemma4:
            return "<|turn>system\n\(safe(system, for: .gemma4))<turn|>\n"
        case .unsupported:
            return ""
        }
    }

    /// `render(_:system:messages:)` without its trailing generation prompt — the part a later
    /// call in the same session can reuse (P0-18).
    static func renderHistory(
        _ family: ChatTemplateFamily,
        system: String,
        messages: [LLMChatMessage]
    ) -> String {
        switch family {
        case .chatmlThinking, .chatml, .minicpm5:
            return renderChatMLHistory(family, system: system, messages: messages)
        case .llama3:
            return renderLlama3History(system: system, messages: messages)
        case .gemma:
            return renderGemmaHistory(system: system, messages: messages)
        case .gemma4:
            return renderGemma4History(system: system, messages: messages)
        case .unsupported:
            return ""
        }
    }

    /// The trailing text that opens the model's turn. `render` is `renderHistory` plus this.
    private static func generationPrompt(_ family: ChatTemplateFamily) -> String {
        switch family {
        case .chatmlThinking, .minicpm5:
            // Left to themselves, hybrid models open `<think>` and deliberate for hundreds of
            // tokens. An already-closed, empty block starts the answer immediately.
            return "<|im_start|>assistant\n<think>\n\n</think>\n\n"
        case .chatml:
            return "<|im_start|>assistant\n"
        case .llama3:
            // BOS is added by the tokenizer's own `add_special`, so `<|begin_of_text|>` is
            // deliberately not written here as text.
            return "<|start_header_id|>assistant<|end_header_id|>\n\n"
        case .gemma:
            return "<start_of_turn>model\n"
        case .gemma4:
            // No `<|think|>`: thinking stays off in Phase 0.
            return "<|turn>model\n"
        case .unsupported:
            return ""
        }
    }

    /// The text a family's turn boundary is spelled with. Generation stops when the model
    /// emits it, in addition to the vocabulary's own end-of-generation tokens.
    static func stopMarker(_ family: ChatTemplateFamily) -> String {
        switch family {
        case .chatmlThinking, .chatml, .minicpm5: "<|im_end|>"
        case .llama3: "<|eot_id|>"
        case .gemma: "<end_of_turn>"
        case .gemma4: "<turn|>"
        case .unsupported: ""
        }
    }

    /// Markers stripped from text shown to a person. Tool-call delimiters are deliberately
    /// absent: the planner decode renders them on purpose so the parser can see them.
    static func controlMarkers(_ family: ChatTemplateFamily) -> [String] {
        switch family {
        case .chatmlThinking, .chatml, .minicpm5:
            ["<|im_start|>", "<|im_end|>", "<think>", "</think>"]
        case .llama3:
            ["<|begin_of_text|>", "<|start_header_id|>", "<|end_header_id|>", "<|eot_id|>"]
        case .gemma:
            ["<start_of_turn>", "<end_of_turn>"]
        case .gemma4:
            ["<|turn>", "<turn|>", "<|think|>", "<|channel>", "<channel|>", "<think>", "</think>"]
        case .unsupported:
            []
        }
    }

    // MARK: - Families

    private static func renderChatMLHistory(
        _ family: ChatTemplateFamily,
        system: String,
        messages: [LLMChatMessage]
    ) -> String {
        var prompt = "<|im_start|>system\n\(safe(system, for: family))<|im_end|>\n"
        for message in messages {
            prompt += "<|im_start|>\(message.role.rawValue)\n"
                + safe(message.content, for: family) + "<|im_end|>\n"
        }
        return prompt
    }

    private static func renderLlama3History(system: String, messages: [LLMChatMessage]) -> String {
        // BOS is added by the tokenizer's own `add_special`, so `<|begin_of_text|>` is
        // deliberately not written here as text.
        var prompt = "<|start_header_id|>system<|end_header_id|>\n\n"
            + "\(safe(system, for: .llama3))<|eot_id|>"
        for message in messages {
            prompt += "<|start_header_id|>\(message.role.rawValue)<|end_header_id|>\n\n"
                + safe(message.content, for: .llama3) + "<|eot_id|>"
        }
        return prompt
    }

    private static func renderGemmaHistory(system: String, messages: [LLMChatMessage]) -> String {
        // Gemma has no system role: the system text merges into the first user turn.
        // Assistant turns are spelled `model`.
        var prompt = ""
        var pendingSystem = safe(system, for: .gemma)
        var openedUserTurn = false

        func userTurn(_ text: String) -> String {
            "<start_of_turn>user\n\(text)<end_of_turn>\n"
        }
        for message in messages {
            let text = safe(message.content, for: .gemma)
            if message.role == .assistant {
                if !openedUserTurn {
                    prompt += userTurn(pendingSystem)
                    pendingSystem = ""
                    openedUserTurn = true
                }
                prompt += "<start_of_turn>model\n\(text)<end_of_turn>\n"
            } else if !openedUserTurn {
                let merged = pendingSystem.isEmpty ? text : pendingSystem + "\n\n" + text
                prompt += userTurn(merged)
                pendingSystem = ""
                openedUserTurn = true
            } else {
                prompt += userTurn(text)
            }
        }
        if !openedUserTurn { prompt += userTurn(pendingSystem) }
        return prompt
    }

    private static func renderGemma4History(system: String, messages: [LLMChatMessage]) -> String {
        var prompt = "<|turn>system\n\(safe(system, for: .gemma4))<turn|>\n"
        for message in messages {
            let role = message.role == .assistant ? "model" : message.role.rawValue
            prompt += "<|turn>\(role)\n\(safe(message.content, for: .gemma4))<turn|>\n"
        }
        return prompt
    }

    /// Keeps a person's words from being read as turn markers. The generic pass covers
    /// every `<|…|>` family; Gemma's `<start_of_turn>` spelling needs its own.
    private static func safe(_ text: String, for family: ChatTemplateFamily) -> String {
        var escaped = text
            .replacingOccurrences(of: "<|", with: "< |")
            .replacingOccurrences(of: "|>", with: "| >")
        if family == .gemma {
            escaped = escaped
                .replacingOccurrences(of: "<start_of_turn>", with: "< start_of_turn>")
                .replacingOccurrences(of: "<end_of_turn>", with: "< end_of_turn>")
        }
        return escaped
    }
}
