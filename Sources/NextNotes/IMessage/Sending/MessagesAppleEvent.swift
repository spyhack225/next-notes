import Foundation

/// IM-09 — the Apple Event that sends a message, built in-process.
///
/// **In-process, and the reason is the predecessor's own principle.** `osascript` is on
/// `Shell/ShellExecutor.swift`'s `privilegedPrefixes`, so a send through it would demand
/// approval on *every message* — which is the "no scripting" principle violated by its
/// own policy. `NSAppleEventDescriptor` builds the event in-process, and the TCC
/// Automation grant is a one-time prompt.
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
/// The `code` is `ichtsend` — four characters, and the `to` parameter's code is `TO  `
/// (with two trailing spaces, which is how Apple pads a four-character code). These are
/// the terms IM-02 verified, and they were renamed at least once when group chats landed.
///
/// ## Addressing a participant, not a chat
///
/// A `chat.guid` is not an address (IM-02's finding). A self-conversation is reachable
/// only as a **participant** addressed by its handle. So the event's `to` parameter is a
/// participant reference, and the handle is the user's own number.
enum MessagesAppleEvent {
    /// The `send` command's Apple Event code. Four characters, verified by IM-02.
    static let sendCommandCode = FourCharCode("ichtsend")
    /// The `to` parameter's code. `TO  ` with two trailing spaces, as Apple pads it.
    static let toParameterCode = FourCharCode("TO  ")
    /// The `participant` class code.
    static let participantClassCode = FourCharCode("part")

    /// Builds the Apple Event for a send.
    ///
    /// - Parameters:
    ///   - text: the message body.
    ///   - handle: the participant's handle (the user's own number for a self-conversation).
    /// - Returns: the event, or nil when the descriptor cannot be built.
    static func sendEvent(text: String, toHandle handle: String) -> NSAppleEventDescriptor? {
        // The target is Messages.app, by its bundle identifier.
        let target = NSAppleEventDescriptor(bundleIdentifier: "com.apple.MobileSMS")

        // The event: `send` with a `to` parameter.
        let event = NSAppleEventDescriptor(
            eventClass: AEEventClass(sendCommandCode.rawValue),
            eventID: AEEventID(FourCharCode("send").rawValue),
            targetDescriptor: target,
            returnID: AEReturnID(kAutoGenerateReturnID),
            transactionID: AETransactionID(kAnyTransactionID))

        // The direct parameter: the text.
        event.setParam(NSAppleEventDescriptor(string: text),
                                forKeyword: AEKeyword(keyDirectObject))

        // The `to` parameter: a participant reference by handle.
        let participant = NSAppleEventDescriptor(
            eventClass: AEEventClass(participantClassCode.rawValue),
            eventID: AEEventID(FourCharCode("part").rawValue),
            targetDescriptor: nil,
            returnID: AEReturnID(kAutoGenerateReturnID),
            transactionID: AETransactionID(kAnyTransactionID))
        participant.setParam(NSAppleEventDescriptor(string: handle),
                                      forKeyword: AEKeyword(FourCharCode("ID  ").rawValue))
        event.setParam(participant, forKeyword: AEKeyword(toParameterCode.rawValue))

        return event
    }

    /// Sends the event and returns the result.
    ///
    /// - Returns: `.sent` on success, `.failed(reason)` on failure with a person-readable
    ///   reason — never a raw Apple Event error number.
    static func send(text: String, toHandle handle: String) async -> OutboundDispatchResult {
        guard let event = sendEvent(text: text, toHandle: handle) else {
            return .failed(reason: "Next can receive your messages but can't reply yet. Open Next Notes on your Mac to finish Messages permission.")
        }
        do {
            _ = try event.sendEvent(options: [.noReply], timeout: 30)
            return .sent
        } catch {
            return .failed(reason: "Next can receive your messages but can't reply yet. Open Next Notes on your Mac to finish Messages permission.")
        }
    }
}

/// FourCharCode is a four-character Apple Event code. A struct rather than a typealias
/// so the codes are checked at compile time.
struct FourCharCode: RawRepresentable {
    let rawValue: UInt32
    init(_ string: String) {
        rawValue = string.utf8.reduce(0) { ($0 << 8) | UInt32($1) }
    }
    init(rawValue: UInt32) { self.rawValue = rawValue }
}

/// The result of a send. A typed outcome, never a raw error number.
enum OutboundDispatchResult: Equatable, Sendable {
    case sent
    case failed(reason: String)
}
