import Foundation

/// The last check before a tool runs, and the one that does not depend on a card having
/// been drawn.
///
/// The review card is where a person sees what is wrong. This is where the machine refuses
/// it. They are separate on purpose: arguments reach `AgentToolExecutor` from places no
/// card ever touched — a cloud model's tool call, an MCP server, an ACP session, a routine
/// replaying a frozen plan, a proposal decoded off disk by a newer build. A fabricated
/// required argument must not reach execution from any of them.
///
/// It checks only what it can decide from the schema and the string: required and empty,
/// or filled with a stand-in. Grounding — "this address appears nowhere" — stays on the
/// card, because it is a judgement a person can overrule and this is not.
enum ToolCallValidation {

    /// Nil when the arguments may run. Otherwise a sentence a non-technical person can act
    /// on, naming the field by the label they saw rather than by the schema key.
    static func problem(tool: AgentTool, arguments: [String: String]) -> String? {
        for parameter in tool.parameters {
            let raw = arguments[parameter.name] ?? ""
            let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            let label = ToolCallReviewBuilder.label(for: parameter.name, toolID: tool.id)
            if value.isEmpty {
                guard parameter.isRequired else { continue }
                return "\u{201c}\(label)\u{201d} is empty, so nothing was run."
            }
            let kind = fieldKind(of: parameter)
            if ToolCallInspector.isPlaceholder(value, kind: kind, risk: tool.risk, name: parameter.name) {
                return "\u{201c}\(label)\u{201d} still says \u{201c}\(clip(value))\u{201d}, "
                    + "which is a stand-in rather than a real answer. Nothing was run."
            }
        }
        return nil
    }

    /// Whether these arguments would run. The self-test's gate, and a cheap pre-check for
    /// anything that wants to know before it asks.
    static func isRunnable(tool: AgentTool, arguments: [String: String]) -> Bool {
        problem(tool: tool, arguments: arguments) == nil
    }

    /// Strips the values a model invented to fill a slot it did not know, so the call
    /// arrives as what it really is — incomplete — and the card asks instead of the user
    /// discovering "[Name]" in their sent mail.
    ///
    /// Only whole-value stand-ins go. A message body with a bracket in it is left alone
    /// here and blocked on the card, where the user can see the sentence it sits in.
    static func withoutInventedValues(_ arguments: [String: String], tool: AgentTool?) -> [String: String] {
        var cleaned: [String: String] = [:]
        for (name, value) in arguments {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }
            let kind = tool?.parameters.first { $0.name == name }.map(fieldKind) ?? .text
            // An unknown tool is treated as the most dangerous one there is: a call nobody
            // can look up is the last place to be relaxed about a stand-in.
            let risk = tool?.risk ?? .send
            if kind != .longText,
               ToolCallInspector.isPlaceholder(trimmed, kind: kind, risk: risk, name: name) {
                continue
            }
            cleaned[name] = value
        }
        return cleaned
    }

    private static func fieldKind(of parameter: WorkspaceTool.Parameter) -> ToolCallFieldKind {
        switch parameter.kind {
        case .multiline: return .longText
        case .date: return .dateTime
        case .list, .text:
            let name = parameter.name.lowercased()
            if name == "to" || name == "cc" || name == "bcc" || name.contains("email")
                || name.contains("recipient") || name.contains("attendee") { return .email }
            if name == "path" || name.contains("file") { return .file }
            return .text
        }
    }

    private static func clip(_ value: String) -> String {
        let flat = value.replacingOccurrences(of: "\n", with: " ")
        return flat.count > 48 ? flat.prefix(47) + "\u{2026}" : flat
    }
}
