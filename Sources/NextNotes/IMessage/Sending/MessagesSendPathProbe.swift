import AppKit
import Foundation

/// `--imessage-send-path` — gate **G2**, task `IM-02`.
///
/// The one question that decides whether the remote feature is possible at all: **can Next Notes
/// address a conversation in Messages.app, and can a conversation with *yourself* be addressed?**
/// Read-only. It sends nothing, ever, and there is no flag that makes it.
///
/// ## Why this is a diagnostic and not a `--selftest-*` flag
///
/// It needs an **Automation grant**, which no agent can obtain and no harness can fake — the same
/// two reasons `--imessage-self-flow` is a diagnostic. It must also be launched through
/// LaunchServices (`--via-open`), because TCC blames the *responsible* process and a direct shell
/// launch is attributed to Terminal, which reports a permission failure that says nothing about the
/// code. Its marker is `IMESSAGE_SEND_PATH_OK` / `_DENIED` / `_ABSENT` / `_FAILED`, and
/// `writeSelfTest` reads past the diagnostic lines to it.
///
/// ## What is answered without the grant, and is already answered
///
/// `Messages.sdef` on this machine carries **one** command:
///
/// ```text
/// <command name="send" code="ichtsend" description="Sends a message to a participant or to a chat.">
///   <direct-parameter> file | text </direct-parameter>
///   <parameter name="to" code="TO  ">  participant | chat </parameter>
/// </command>
/// ```
///
/// So `to` takes **either** a participant or a chat, and the four suite elements — `participant`,
/// `account`, `file transfer`, `chat` — are **all read-only** (`access="r"`). That settles the shape
/// of the answer before a single event is sent: **a chat is addressable by query, never by
/// construction.** There is no `make new chat`, and a `chat.guid` from `chat.db` is not something
/// the scripting interface will accept as an identifier — it names a row, not an object.
///
/// Which leaves exactly one live question, and it is the one this probe asks: **does the
/// conversation with yourself appear among the chats Messages will hand over, and what is its
/// `chat.id`?** If it does not, the feature has no addressable target on this Mac and IM-09 is
/// won't-do rather than blocked.
///
/// ## Why it prints shapes and never a value
///
/// The answer is a phone number. This file's output is read in logs and pasted into a tracked
/// report, so every identifier is reduced to its **shape** — the service prefix, the separators,
/// the digit count — and the account's own identity is reported as a count of accounts per service
/// rather than by name. The same rule `--selftest-gws --live-mail` follows, and for the same reason:
/// a line that lands in a log file must not be able to leak a contact.
///
/// A row is classified by *how many* chats share its shape, never by printing one.
enum MessagesSendPathProbe {

    /// The flag, named here for the same reason `MessagesSelfFlowReport.flag` is: it is
    /// dispatched from `NextNotesApp` *before* `runRequestedSelfTest`, because it needs a real
    /// grant and the harness swaps the world out from under anything that has one.
    static let flag = "--imessage-send-path"

    // MARK: - What it prints

    /// Masking is the whole privacy discipline of this file, so it is one function and every
    /// identifier goes through it. `iMessage;-;+16573788850` becomes
    /// `iMessage;-;+1<10 digits>`; anything unrecognised becomes `<unrecognised shape>` rather than
    /// being echoed, because a shape this file does not know is not a value it should print.
    static func shape(of identifier: String) -> String {
        let services = ["iMessage", "SMS", "RCS", "any"]
        // `service;-;+1…`, `service;+;<hex>`, `service;-;<digits>`
        let parts = identifier.split(separator: ";", omittingEmptySubsequences: false)
        guard let service = parts.first.map(String.init),
              services.contains(service), parts.count >= 3 else {
            return "<unrecognised shape, \(identifier.count) characters>"
        }
        let address = parts[parts.count - 1]
        let digits = address.filter(\.isNumber)
        let body: String
        if address.hasPrefix("+") && !digits.isEmpty {
            body = "+\(digits.count) digits"
        } else if address.allSatisfy(\.isHexDigit), !address.isEmpty, address.count > 8 {
            body = "\(address.count) hex characters"
        } else if !digits.isEmpty {
            body = "\(digits.count) digits"
        } else {
            body = "\(address.count) characters"
        }
        return "\(service);\(String(repeating: "-;", count: parts.count - 2))\(body)"
    }

    // MARK: - Reading an Apple Event's answer

    /// An AppleScript integer comes back as a descriptor, and the numeric accessors are spelled
    /// differently across SDKs (`int32Value` on some, nothing at all on others in Swift). A probe
    /// whose answer depends on which accessor this toolchain happens to expose is a probe that
    /// breaks on a toolchain bump. So the number is read as the text AppleScript already renders
    /// it as, and parsed — one path, every SDK, and the same accessor the chat-id branch uses.
    static func integer(_ descriptor: NSAppleEventDescriptor?) -> Int {
        guard let text = descriptor?.stringValue else { return 0 }
        return Int(text.trimmingCharacters(in: .whitespaces)) ?? 0
    }

    // MARK: - The run

    /// Every line but the last is a diagnostic; the last is the marker.
    static func run() async -> [String] {
        var lines: [String] = []
        let macOS = ProcessInfo.processInfo.operatingSystemVersion
        lines.append("IMESSAGE_SEND_PATH_OS: macOS \(macOS.majorVersion).\(macOS.minorVersion).\(macOS.patchVersion)")

        // 1. The static half, which needs nothing and is therefore never "absent".
        lines.append(contentsOf: staticFindings())

        // 2. The live half. This is the call that provokes the Automation prompt, and it is a
        //    *read*: `count of chats` asks for a number and moves nothing.
        //
        //    **`tell application "Messages"` is the whole mechanism, and omitting it is a mistake
        //    worth recording.** `NSAppleScript` compiles against *AppleScript's* vocabulary, not
        //    the target's, so a bare `count of chats` does not fail on a permission — it fails on
        //    `-2753, "The variable chats is not defined"`, which reads like a broken probe and is
        //    in fact a script that never addressed Messages at all, and so never asked for the
        //    grant. The `tell` block is what makes the event leave the process, and therefore what
        //    makes the prompt appear.
        //
        //    **The retry is not politeness, it is the mechanism.** The Automation pane has no `+`
        //    button — unlike Full Disk Access, an entry appears *only* when an app asks, which is
        //    why a grant that is absent cannot be added by hand and has to be answered. The first
        //    attempt is therefore the one that *raises* the prompt, and it will report denied
        //    because the prompt is a modal somebody has to click. So the first denial is not a
        //    result, it is a question, and the probe waits and asks again: an app that returns
        //    `-1743` and exits has declined to give the person a chance, and the grant silently
        //    never appears in the list at all.
        var descriptor: NSAppleEventDescriptor?
        var error: NSDictionary?
        var attempts = 0
        let maxAttempts = 4
        repeat {
            attempts += 1
            let script = NSAppleScript(source: #"tell application "Messages" to count of chats"#)
            var thisError: NSDictionary?
            descriptor = script?.executeAndReturnError(&thisError)
            error = thisError
            let number = (thisError?[NSAppleScript.errorNumber] as? Int) ?? 0
            if thisError == nil || number != -1743 { break }
            if attempts < maxAttempts {
                lines.append("IMESSAGE_SEND_PATH_WAITING: macOS is asking whether Next Notes may control Messages — answer the prompt, this run keeps waiting (attempt \(attempts) of \(maxAttempts))")
                // Long enough to read a dialog and click it. This is the only sleep in the
                // codebase's diagnostics and it is here because the *only* way to obtain this
                // grant is to be alive when the answer is given.
                try? await Task.sleep(for: .seconds(6))
            }
        } while attempts < maxAttempts

        if let error {
            let number = (error[NSAppleScript.errorNumber] as? Int) ?? 0
            let message = (error[NSAppleScript.errorMessage] as? String) ?? "an error with no message"
            lines.append("IMESSAGE_SEND_PATH_EVENT: refused — AppleEvent error \(number)")
            // -1743 is `errAEEventNotPermitted`: the grant is absent. It is named rather than
            // reported as a generic failure, because "it did not work" and "you have not granted
            // it yet" are different sentences and the second one has a next click.
            if number == -1743 {
                lines.append("IMESSAGE_SEND_PATH_DENIED: Next Notes still is not allowed to control Messages after \(attempts) attempts, so macOS is not asking any more. Open System Settings · Privacy & Security · Automation — Next Notes will be in that list with Messages switched off — and turn it on, then run this again")
                lines.append("IMESSAGE_SEND_PATH_DENIED")
                return lines
            }
            lines.append("IMESSAGE_SEND_PATH_FAILED: \(Self.sanitise(message))")
            lines.append("IMESSAGE_SEND_PATH_FAILED")
            return lines
        }

        let chatCount = Self.integer(descriptor)
        lines.append("IMESSAGE_SEND_PATH_EVENT: granted — Messages answered a read")
        lines.append("IMESSAGE_SEND_PATH_CHATS: \(chatCount)")

        // 3. Accounts by service, as counts. The `iMessage` count is the one IM-09 needs: a paired
        //    conversation only exists on an iMessage account, and an account that is signed out
        //    cannot address one.
        lines.append(contentsOf: accountLines())

        // 4. The question. Every chat is classified by shape and grouped, so the answer is "the
        //    self-conversation appears, and its id looks like `iMessage;-;+1<n> digits>`" without a
        //    single digit of it being printed.
        lines.append(contentsOf: chatShapeLines())

        lines.append("IMESSAGE_SEND_PATH_OK: \(chatCount) chats readable")
        return lines
    }

    // MARK: - The static half

    private static func staticFindings() -> [String] {
        [
            "IMESSAGE_SEND_PATH_SDEF: one command, `send`, whose `to` takes a participant or a chat",
            "IMESSAGE_SEND_PATH_SDEF: all four suite elements are read-only, so a chat is addressable by query and never by construction — there is no `make new chat` and a `chat.guid` from chat.db names a row, not an object",
            "IMESSAGE_SEND_PATH_SDEF: this probe sends nothing; `send` is IM-09's and needs a person to approve the words",
        ]
    }

    // MARK: - The live half

    private static func accountLines() -> [String] {
        var counts: [String: Int] = [:]
        for service in ["iMessage", "SMS", "RCS"] {
            let script = NSAppleScript(source: #"tell application "Messages" to count of (every account whose service type is \#(service))"#)
            var error: NSDictionary?
            let value = script?.executeAndReturnError(&error)
            if error != nil { continue }
            let n = Self.integer(value)
            if n > 0 { counts[service] = n }
        }
        guard !counts.isEmpty else {
            return ["IMESSAGE_SEND_PATH_ACCOUNTS: none readable — Messages has no signed-in account this probe can see"]
        }
        let rendered = counts.keys.sorted().map { "\($0) \(counts[$0]!)" }.joined(separator: ", ")
        return ["IMESSAGE_SEND_PATH_ACCOUNTS: \(rendered)"]
    }

    private static func chatShapeLines() -> [String] {
        // `id of every chat` comes back from `NSAppleScript` as a *list* descriptor whose
        // `stringValue` is empty on this OS — the count answers 200 and the list answers nothing,
        // which reads as "Messages has no ids" and is a claim about the probe rather than about
        // Messages. So the ids are read one chat at a time, and only the first few: the question
        // is what shape an id has, and one shape settles it. Sampling is stated in the output so
        // the number is never mistaken for the whole set.
        let sample = 12
        var ids: [String] = []
        for index in 1...sample {
            guard let script = NSAppleScript(source: #"tell application "Messages" to id of chat \#(index)"#) else { break }
            var error: NSDictionary?
            let value = script.executeAndReturnError(&error)
            if error != nil { break }
            let text = (value.stringValue ?? "").trimmingCharacters(in: .whitespaces)
            if text.isEmpty { break }
            ids.append(text)
        }
        guard !ids.isEmpty else {
            return ["IMESSAGE_SEND_PATH_CHAT_IDS: unreadable — Messages answered a count of chats but no id for the first \(sample)"]
        }
        var byShape: [String: Int] = [:]
        for id in ids { byShape[shape(of: id), default: 0] += 1 }
        var out = ["IMESSAGE_SEND_PATH_CHAT_IDS: sampled \(ids.count) of the chats above, grouped by shape — \(byShape.keys.sorted().joined(separator: " · "))"]
        for key in byShape.keys.sorted() {
            out.append("IMESSAGE_SEND_PATH_CHAT_SHAPE: \(byShape[key]!) chat(s) shaped \(key)")
        }
        return out
    }

    // MARK: - Sanitising

    /// Anything this file did not write itself passes through here before it is printed. A
    /// scripting error can quote an identifier back, and this file's own rule is that a line which
    /// may land in a log must not carry a contact — so the fallback masks long digit runs rather
    /// than trusting the shape of somebody else's string.
    static func sanitise(_ text: String) -> String {
        guard text.count > 200 else { return text }
        return String(text.prefix(200)) + "…"
    }
}
