import Foundation

/// `--imessage-address-probe`: learns which participant reference form Messages.app
/// actually resolves — with reads only, never a send.
///
/// Why this exists: the first `--imessage-send-test` dispatched with `.noReply` and
/// reported `.sent` while no row ever landed. A `send` built on an unresolvable `to`
/// fails silently by construction, and guessing a new construction per send attempt
/// is how the app spams its owner. So the addressing question is answered here
/// before another send is attempted.
///
/// The queries are `exists` over `NSAppleScript` — the same `tell application
/// "Messages"` mechanism `--imessage-send-path` uses, which is what makes the event
/// leave the process and the grant apply, and the same mechanism the send itself
/// uses. `exists` answers a boolean, so there is no content to leak — the output is
/// forms and error numbers only.
///
/// A diagnostic, not a `--selftest-*` flag: it needs the Automation grant and the
/// real settings. Run it **directly** (no `--via-open`): Automation answers depend
/// on the launching process, and a LaunchServices launch gets `-1743` where a
/// direct launch is answered. Every line goes through `writeSelfTest`.
enum IMessageAddressProbe {
    /// The flag.
    static let flag = "--imessage-address-probe"

    /// One candidate reference form.
    struct Form: Sendable {
        /// Short label for the output line.
        var label: String
        /// AppleScript source. The handle is interpolated by the runner, never logged.
        var source: @Sendable (String) -> String
        /// Whether a `true` answer is expected. The guid form is the honest negative:
        /// IM-02 found a guid is not an address, and a probe that cannot show a
        /// failure cannot be trusted to show a success.
        var expectResolves: Bool
    }

    /// The forms. Name and id over the paired handle, plus the guid negative.
    static let forms: [Form] = [
        Form(label: "participant-by-name",
             source: { #"tell application "Messages" to exists participant ""# + $0 + "\"" },
             expectResolves: true),
        Form(label: "participant-by-id",
             source: { #"tell application "Messages" to exists participant id ""# + $0 + "\"" },
             expectResolves: true),
        Form(label: "chat-guid-as-participant",
             source: { #"tell application "Messages" to exists participant ""# + $0 + "\"" },
             expectResolves: false),
    ]

    /// Probes every form. One string per line, marker last.
    static func run() async -> [String] {
        let store = RemoteIdentityStore(directory: AppIdentity.applicationSupportDirectory)
        guard store.configuration.isPaired,
              let handle = store.configuration.chatHandleCache,
              !handle.isEmpty else {
            return ["IMESSAGE_ADDRESS_PROBE_FAILED: no paired conversation — run --imessage-pair-now first"]
        }
        let guid = store.configuration.pairedChatGUID ?? ""
        var lines: [String] = []
        var asExpected = 0
        var total = 0
        for form in Self.forms {
            let selection = form.label == "chat-guid-as-participant" ? guid : handle
            guard !selection.isEmpty else {
                lines.append("IMESSAGE_ADDRESS_PROBE: \(form.label) skipped (nothing to address)")
                continue
            }
            total += 1
            let (answer, number) = ask(source: form.source(selection))
            let ok = answer == form.expectResolves
            if ok { asExpected += 1 }
            lines.append("IMESSAGE_ADDRESS_PROBE: \(form.label) "
                + (answer.map { $0 ? "resolves" : "absent" } ?? "error \(number)")
                + (ok ? "" : " (against expectation)"))
        }
        lines.append(asExpected == total
            ? "IMESSAGE_ADDRESS_PROBE_OK: every form answered as expected"
            : "IMESSAGE_ADDRESS_PROBE_FAILED: \(asExpected) of \(total) forms answered as expected — do not attempt a send")
        return lines
    }

    /// Runs one read. The boolean, or nil with the error number. The selection is
    /// interpolated into the script and never printed.
    static func ask(source: String) -> (Bool?, Int) {
        var error: NSDictionary?
        let descriptor = NSAppleScript(source: source)?.executeAndReturnError(&error)
        if let error {
            return (nil, (error[NSAppleScript.errorNumber] as? Int) ?? 0)
        }
        return (descriptor?.booleanValue, 0)
    }
}
