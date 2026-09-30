import Foundation

/// IM-09 — the Apple Event that sends a message, built in-process.
///
/// **In-process, and the reason is the predecessor's own principle.** `osascript` is on
/// `Shell/ShellExecutor.swift`'s `privilegedPrefixes`, so a send through the shell
/// would demand approval on *every message*. `NSAppleScript` runs in-process under
/// the one-time Automation grant — the same TCC posture as a raw descriptor, without
/// a shell in the path.
///
/// ## Why AppleScript and not a raw descriptor
///
/// The raw-descriptor construction was tried first and measured twice: a hand-built
/// participant record answers `-1700` on a reply-bearing `get`, and a `send` built
/// on it dispatches without error and delivers nothing — which a `.noReply` send
/// cannot report and only the row-watch caught. An AERecord is not an object
/// specifier, and guessing at its internals per send attempt is how the app spams
/// its owner. `--imessage-address-probe` asks Messages with reads only, and
/// `exists participant "<handle>"` resolves while `exists participant id
/// "<handle>"` does not — so the send below is the by-name form the probe proved.
///
/// ## The dictionary terms, verified by IM-02
///
/// `Messages.sdef` on this macOS carries exactly one command:
///
/// ```xml
/// <command name="send" code="ichtsend" description="Sends a message to a participant or to a chat.">
///   <direct-parameter> file | text </direct-parameter>
///   <parameter name="to" code="TO  ">
///     <type type="participant"/>
///     <type type="chat"/>
///   </parameter>
/// </command>
/// ```
///
/// ## Addressing a participant, not a chat
///
/// A `chat.guid` is not an address (IM-02's finding). A self-conversation is reachable
/// only as a **participant** addressed by its handle. So the event sends to the
/// participant the probe resolved, and the handle is the user's own number.
enum MessagesAppleEvent {
    /// Sends the message and returns the result.
    ///
    /// - Returns: `.sent` on success, `.failed(reason)` on failure with a person-readable
    ///   reason — never a raw Apple Event error number.
    static func send(text: String, toHandle handle: String) async -> OutboundDispatchResult {
        let source = """
        with timeout of 30 seconds
        tell application "Messages" to send "\(literal(text))" to participant "\(literal(handle))"
        end timeout
        """
        // Main actor, like `--imessage-send-path`: AppleScript executes on the calling
        // thread, and the component is not safe to drive from a pool thread. The
        // `with timeout` bounds the block at 30 seconds either way.
        let outcome = await MainActor.run { () -> OutboundDispatchResult in
            var error: NSDictionary?
            NSAppleScript(source: source)?.executeAndReturnError(&error)
            guard let error else { return .sent }
            let number = (error[NSAppleScript.errorNumber] as? Int) ?? 0
            if number == -1743 {
                return .failed(reason: "Next can receive your messages but can't reply yet. Open Next Notes on your Mac to finish Messages permission.")
            }
            return .failed(reason: "Next couldn't send that just now. Check the conversation before trying again — it may have gone out anyway.")
        }
        return outcome
    }

    /// An AppleScript string literal. Three replacements and no more: a backslash or a
    /// quote would end the literal (or start an interpolation the owner did not write),
    /// and a newline cannot sit inside one, so it becomes a `return` concatenation.
    /// Pure, so the self-test can pin it without Messages, a grant or a send.
    static func literal(_ value: String) -> String {
        var out = value.replacingOccurrences(of: "\\", with: "\\\\")
        out = out.replacingOccurrences(of: "\"", with: "\\\"")
        out = out.replacingOccurrences(of: "\r\n", with: "\" & return & \"")
        out = out.replacingOccurrences(of: "\r", with: "\" & return & \"")
        out = out.replacingOccurrences(of: "\n", with: "\" & return & \"")
        return out
    }
}

/// The result of a send. A typed outcome, never a raw error number.
enum OutboundDispatchResult: Equatable, Sendable {
    case sent
    case failed(reason: String)
}
