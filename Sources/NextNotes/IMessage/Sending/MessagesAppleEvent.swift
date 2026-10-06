import Foundation
import OSAKit
import os

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
    // Blocking OSA runs on this one in-process serial executor, never the main or
    // cooperative executor. Each invocation owns a private language component.
    private static let executionQueue = DispatchQueue(label: "ai.pivotstudio.nextnotes.messages-send",
                                                      qos: .userInitiated)
    @TaskLocal static var fixtureDirectoryForTesting: URL?
    @TaskLocal static var executeForTesting: (@Sendable (String) -> Int?)?
    @TaskLocal static var sourceForTesting: String?
    @TaskLocal static var observeForTesting: (@Sendable (Bool, Bool) -> Void)?

    private static var admitsFixture: Bool {
        guard SelfTest.requested == "--selftest-imessage-loop",
              CommandLine.arguments.contains("--imessage-nonblocking-send"),
              let fixture = fixtureDirectoryForTesting else { return false }
        let root = FileManager.default.temporaryDirectory
            .standardizedFileURL.resolvingSymlinksInPath().path + "/"
        return fixture.standardizedFileURL.resolvingSymlinksInPath().path.hasPrefix(root)
    }

    private static func result(errorNumber: Int?) -> OutboundDispatchResult {
        guard let errorNumber else { return .sent }
        if errorNumber == -1743 {
            return .failed(reason: "Next can receive your messages but can't reply yet. Open Next Notes on your Mac to finish Messages permission.")
        }
        return .failed(reason: "Next couldn't send that just now. Check the conversation before trying again — it may have gone out anyway.")
    }

    /// Sends the message and returns the result.
    ///
    /// - Returns: `.sent` on success, `.failed(reason)` on failure with a person-readable
    ///   reason — never a raw Apple Event error number.
    static func send(text: String, toHandle handle: String) async -> OutboundDispatchResult {
        var source = """
        with timeout of 30 seconds
        tell application "Messages" to send "\(literal(text))" to participant "\(literal(handle))"
        end timeout
        """
        let fixture = admitsFixture
        let execution = fixture ? executeForTesting : nil
        let observer = fixture ? observeForTesting : nil
        if SelfTest.isRunning {
            // An unqualified self-test must never fall through to a real Messages send.
            guard fixture else { return result(errorNumber: -1) }
            if let replacement = sourceForTesting {
                guard replacement == "return 7" || replacement == "return (" else {
                    return result(errorNumber: -1)
                }
                source = replacement
            } else if execution == nil {
                return result(errorNumber: -1)
            }
        }
        let cancelled = OSAllocatedUnfairLock(initialState: Task.isCancelled)
        let preparedSource = source
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                executionQueue.async {
                    let outcome: OutboundDispatchResult = autoreleasepool {
                        // Cancellation before entry dispatches nothing. Once execution
                        // starts, await its real result; never repeat an uncertain send.
                        guard !cancelled.withLock({ $0 }) else { return result(errorNumber: -1) }
                        if let execution { return result(errorNumber: execution(preparedSource)) }
                        return executeScript(preparedSource, observer: observer)
                    }
                    continuation.resume(returning: outcome)
                }
            }
        } onCancel: {
            cancelled.withLock { $0 = true }
        }
    }

    private static func executeScript(_ source: String,
        observer: (@Sendable (Bool, Bool) -> Void)?) -> OutboundDispatchResult {
        // Use OSAKit's thread-safe language directly with a private instance;
        // no shared generic scripting component participates in this execution.
        guard let language = OSALanguage(forName: "AppleScript"), language.isThreadSafe else {
            return result(errorNumber: -1)
        }
        let instance = OSALanguageInstance(language: language)
        let script = OSAScript(source: source, from: nil, languageInstance: instance,
                               using: OSAStorageOptions(rawValue: 0))
        observer?(Thread.isMainThread, instance.componentInstance != language.componentInstance)
        var error: NSDictionary?
        let reply = script.executeAndReturnError(&error)
        if let error {
            return result(errorNumber: (error[OSAScriptErrorNumber] as? Int) ?? -1)
        }
        guard reply != nil else { return result(errorNumber: -1) }
        return .sent
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
