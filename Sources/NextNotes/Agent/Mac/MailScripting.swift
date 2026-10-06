import Foundation

/// Drafts, sends and replies, done by Mail itself.
///
/// Reading mail is a file read; **writing it is Mail's job**, because Mail owns the account, the
/// signature and the sent folder, and anything that wrote around it would put a message on the
/// person's Google account that Mail did not know it had. The only way to ask Mail is Apple
/// events, so a small script is run with `osascript`, through the same `GoogleWorkspaceCLI.spawn`
/// the Workspace tool uses — one process runner, one timeout, one set of errors.
///
/// **Every value goes in as an argument, never into the script text.** A subject with a quote in
/// it, a body with a backslash, a name with an apostrophe are all just argv entries to
/// `on run argv`, so there is no escaping to get wrong and nothing a message can say that
/// becomes AppleScript.
///
/// Which account sends: the Google one, found by its server (`imap.gmail.com`). If Mail holds
/// none, the script stops before it makes a message (error 7001). The default account is never
/// used instead; a message from the wrong address is worse than no message.
protocol MailScriptRunning: Sendable {
    func run(arguments: [String], timeout: TimeInterval) async throws -> WorkspaceCLIOutput
}

/// `osascript`, spawned by the one process runner the Workspace tool already has.
struct OSAScriptRunner: MailScriptRunning {
    func run(arguments: [String], timeout: TimeInterval) async throws -> WorkspaceCLIOutput {
        try await GoogleWorkspaceCLI.spawn(
            executable: URL(fileURLWithPath: "/usr/bin/osascript"),
            arguments: arguments, timeout: timeout)
    }
}

enum MailScripting {
    /// Long enough for Mail to start and for a message with a long body; short enough that a
    /// stuck Mail does not hold an approved action open.
    static let timeout: TimeInterval = 60

    /// Error numbers the script raises itself.
    static let noGoogleAccountNumber = 7001
    static let messageNotFoundNumber = 7002

    /// A read uses one `account` argument. A write binds the selected Mail id/address, then
    /// mode (`draft`, `send`, `reply`), recipients, subject, body and `mailbox<TAB>id` for reply.
    static let script = """
    on run argv
    set accountOnly to (count of argv) is 1 and (item 1 of argv) is "account"
    if not accountOnly then
    set selectedID to item 1 of argv
    set selectedAddress to item 2 of argv
    set theMode to item 3 of argv
    set theTo to item 4 of argv
    set theSubject to item 5 of argv
    set theBody to item 6 of argv
    set theTarget to item 7 of argv
    end if
    tell application "Mail"
    set theAccount to missing value
    repeat with a in accounts
    try
    if (server name of a) is "imap.gmail.com" then
    if accountOnly then
    set theAccount to contents of a
    exit repeat
    else if ((id of a) as text) is selectedID then
    if item 1 of (email addresses of a) is selectedAddress then
    set theAccount to contents of a
    exit repeat
    end if
    end if
    end if
    end try
    end repeat
    if theAccount is missing value then error "no Google account in Mail" number \(noGoogleAccountNumber)
    set theAddress to item 1 of (email addresses of theAccount)
    if accountOnly then return ((id of theAccount) as text) & tab & theAddress
    if theMode is "reply" then
    set AppleScript's text item delimiters to tab
    set theBoxName to text item 1 of theTarget
    set theID to (text item 2 of theTarget) as integer
    set AppleScript's text item delimiters to ""
    try
    set theMessage to first message of (mailbox theBoxName of theAccount) whose id is theID
    on error
    error "message not found" number \(messageNotFoundNumber)
    end try
    set theReply to reply theMessage opening window false
    set sender of theReply to theAddress
    set content of theReply to theBody & linefeed & linefeed & (content of theReply)
    send theReply
    else
    set theMessage to make new outgoing message with properties {subject:theSubject, content:theBody, visible:false}
    tell theMessage
    repeat with addr in (paragraphs of theTo)
    if (addr as text) is not "" then make new to recipient at end of to recipients with properties {address:(addr as text)}
    end repeat
    set sender to theAddress
    end tell
    if theMode is "send" then
    send theMessage
    else
    save theMessage
    end if
    end if
    end tell
    return "ok"
    end run
    """

    /// The `osascript` arguments for one request. Pure, so a test reads exactly what Mail is told.
    private static var scriptArguments: [String] {
        script.split(separator: "\n", omittingEmptySubsequences: true).flatMap { ["-e", String($0)] }
    }

    static var accountArguments: [String] { scriptArguments + ["account"] }

    static func arguments(for request: MacComposeRequest, replyTarget: (mailbox: String, id: Int64)? = nil,
                          senderID: String = "", senderAddress: String = "") -> [String] {
        let lines = scriptArguments
        let mode: String
        var target = ""
        switch request.kind {
        case .draft: mode = "draft"
        case .send: mode = "send"
        case .reply:
            mode = "reply"
            if let replyTarget { target = "\(replyTarget.mailbox)\t\(replyTarget.id)" }
        }
        return lines + [senderID, senderAddress, mode, request.to.joined(separator: "\n"), request.subject, request.body, target]
    }

    /// What Mail's answer means. A script that finished and said `ok` is success; the rest are
    /// named by what they prove about whether anything was sent.
    static func interpret(_ output: WorkspaceCLIOutput) throws {
        if output.exitCode == 0 {
            guard output.text.trimmingCharacters(in: .whitespacesAndNewlines) == "ok" else {
                throw MacWorkspaceError.scriptFailed("unreadable answer")
            }
            return
        }
        let error = output.standardError
        // -1743: "Not authorized to send Apple events to Mail." Refused before anything ran.
        if error.contains("(-1743)") || error.contains("Not authorized to send Apple events") {
            throw MacWorkspaceError.automationDenied
        }
        if error.contains("(\(noGoogleAccountNumber))") { throw MacWorkspaceError.noMailAccount }
        if error.contains("(\(messageNotFoundNumber))") { throw MacWorkspaceError.messageNotFound }
        let first = error.split(separator: "\n").first.map(String.init) ?? "exit \(output.exitCode)"
        throw MacWorkspaceError.scriptFailed(first)
    }
}
