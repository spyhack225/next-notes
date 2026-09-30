import Foundation

/// How an agent reply is shaped on the wire, so a self-conversation tells its two
/// authors apart.
///
/// **The constraint is Apple's UI, not this app's.** Every message in a
/// self-conversation renders twice (blue and grey) with no API to style, label or
/// de-duplicate either copy — so "who said this" can only live in the content.
/// The roadmap decided the shape in IM-13 and gave IM-17 its final form:
/// the agent's runtime name as a prefix (`Next · Done.` in the roadmap's sample
/// identity), read from `agent-identity.json` through `AgentGroundingFacts` and
/// never hardcoded (`--selftest-persona` fails a hardcoded one).
///
/// One function, called by the one sender (`MessagesSender`) and by the one
/// manual test that watches for the row (`IMessageSendTest` digests the same final
/// string it polls for). Two call sites agreeing is a drift risk, and the defence
/// is that drift fails loudly: a digest over the wrong string never matches a row,
/// so `--imessage-send-test` goes red rather than pairing a send with a stranger.
enum AgentMessageFormat {
    /// The separator between the name and the reply. A middle dot with spaces, as
    /// in the roadmap's `Next · Done.` — a colon reads as a label on a log line.
    static let separator = " · "

    /// Prefixes an outbound reply with the agent's name: `"Will · <text>"`.
    ///
    /// - Idempotent: text already carrying `"<name> · "` passes through unchanged,
    ///   so a retry, a re-send or an approval shown twice never stacks prefixes.
    /// - An empty name sends the text as-is rather than a dangling separator: a
    ///   fresh install with no name yet must still answer, and the prefix returns
    ///   with the name.
    /// - Pure, so its cases pin without Messages, a grant or a send.
    /// - The name is always a parameter, never a default: a literal agent name in
    ///   this file would be the hardcoded identity `--selftest-persona` fails.
    static func prefixed(_ text: String, name: String) -> String {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty, !text.isEmpty else { return text }
        let prefix = trimmedName + separator
        if text.hasPrefix(prefix) { return text }
        return prefix + text
    }

    /// `--selftest-imessage-format`: the cases above, with no grant, no pairing,
    /// no store and no model. One string per line, marker last.
    static func runSelfTest() -> [String] {
        struct Case {
            var name: String
            var text: String
            var agentName: String
            var expect: String
        }
        let cases: [Case] = [
            Case(name: "basic", text: "Done.", agentName: "Will", expect: "Will · Done."),
            Case(name: "idempotent", text: "Will · Done.", agentName: "Will", expect: "Will · Done."),
            Case(name: "empty-name", text: "Done.", agentName: "", expect: "Done."),
            Case(name: "blank-name", text: "Done.", agentName: "   ", expect: "Done."),
            Case(name: "empty-text", text: "", agentName: "Will", expect: ""),
            Case(name: "name-trimmed", text: "Hi.", agentName: "  Will  ", expect: "Will · Hi."),
            Case(name: "other-name-is-content", text: "Will · Done.", agentName: "Next",
                 expect: "Next · Will · Done."),
            Case(name: "multiline", text: "First.\nSecond.", agentName: "Will",
                 expect: "Will · First.\nSecond."),
        ]
        var wrong: [String] = []
        for c in cases {
            let got = prefixed(c.text, name: c.agentName)
            if got != c.expect {
                wrong.append("IMESSAGE_FORMAT_WRONG: \(c.name) — got \(got.count) character(s)")
            }
        }
        if wrong.isEmpty {
            return ["IMESSAGE_FORMAT_OK: \(cases.count) cases"]
        }
        wrong.append("IMESSAGE_FORMAT_FAILED: \(wrong.count) of \(cases.count) cases")
        return wrong
    }
}
