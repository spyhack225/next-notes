import Foundation

/// `--imessage-send-test <text>`: sends owner-approved words to the paired
/// self-conversation and watches for the row.
///
/// A diagnostic and modifier, not a `--selftest-*` flag, for the same reasons
/// `--imessage-pair-now` is one: it needs Full Disk Access (read the row back),
/// the Automation grant (the send itself), and the owner's real
/// `imessage-settings.json` plus the real outbound ledger — everything the
/// self-test harness swaps away. It runs before `runRequestedSelfTest` with
/// `SelfTest.isRunning` still false.
///
/// The words always come from the person, as the flag's argument. There is no
/// default text and no text anywhere in this file: a send this app composed for
/// itself is a send nobody approved. That is IM-09's whole permission model, and
/// a convenience default would be the hole in it.
///
/// Verification is `IMessageActionVerifier` (IM-10): the ledger row is written
/// before dispatch (by `MessagesSender`), and the pass polls for a new
/// `is_from_me` row whose text digest matches. A dispatch that reports `.sent`
/// with no row observed still wears the `FAILED` marker — the runner only wakes
/// on `OK`/`FAILED` — but its sentence says "dispatched but unconfirmed", never
/// "failed": a write that did not answer is "not sure", never "failed". Every
/// terminal outcome is recorded as an `ActionReceipt` in the shared store,
/// because a real send happened and the audit trail is where it belongs.
///
/// Every line goes through `writeSelfTest` (see `--imessage-pair-now`): a
/// LaunchServices launch has no stdout. Shapes only — states and counts, never
/// the text, the handle or the guid.
enum IMessageSendTest {
    /// The flag. The message follows it as one argument.
    static let flag = "--imessage-send-test"

    /// Sends approved words, verifies, and receipts. One string per line, marker last.
    @MainActor
    static func run(text: String) async -> [String] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return ["IMESSAGE_SEND_TEST_FAILED: supply the message text after the flag"]
        }
        let store = RemoteIdentityStore(directory: AppIdentity.applicationSupportDirectory)
        guard store.configuration.isPaired,
              let handle = store.configuration.chatHandleCache,
              !handle.isEmpty,
              let chatGUID = store.configuration.pairedChatGUID else {
            return ["IMESSAGE_SEND_TEST_FAILED: no paired conversation — run --imessage-pair-now first"]
        }
        // The frozen intent: the exact payload this run was approved for, with the
        // dispatched digest in hex inside it. The receipt carries it back byte for
        // byte, which is what makes "the receipt's payload equals the payload that
        // was dispatched" an equality rather than a claim.
        let body = AgentMessageFormat.prefixed(trimmed, name: AgentGroundingFacts.assistantName())
        let digest = OutboundDigest.text(body)
        let intent = ActionIntent(
            source: .agent, authority: .user, verb: "send", target: "self-conversation",
            arguments: ["textHash": IMessageActionVerifier.hex(digest)], risk: .send)
        let actionID = UUID()
        let sender = MessagesSender(ledger: .shared, store: store)
        // The send goes first and never waits on the watch: in a direct launch the
        // watch has no Full Disk Access, and a verification read must not be able
        // to veto a send the owner approved.
        switch await sender.sendText(trimmed, toHandle: handle) {
        case .breakerRefused:
            return ["IMESSAGE_SEND_TEST_FAILED: the loop breaker refused — too many sends in ten seconds, wait and try again"]
        case .recordFailed(let reason):
            return ["IMESSAGE_SEND_TEST_FAILED: \(reason)"]
        case .sendFailed(let reason):
            return ["IMESSAGE_SEND_TEST_FAILED: \(reason)"]
        case .sent:
            break
        }
        // Dispatched. The row is the proof; verify for it. When this launch cannot
        // read chat.db (a direct launch has no Full Disk Access), record the
        // dispatch and point at the read-only check — never re-run this flag to
        // "verify", which would send again.
        let database: MessagesDatabase
        do {
            database = try MessagesDatabase()
        } catch {
            _ = ActionReceiptStore.shared.record(
                IMessageActionVerifier.receipt(verification: .dispatched, intent: intent, actionID: actionID))
            return [
                "IMESSAGE_SEND_TEST_DISPATCHED: handed to Messages; this launch cannot read chat.db",
                "IMESSAGE_SEND_TEST_FAILED: dispatched-but-unverified — confirm with --imessage-self-flow --via-open (read-only, sends nothing), do not re-run this flag",
            ]
        }
        let verification: IMessageSendVerification
        do {
            let preLatest = try await database.latestRowID()
            verification = await IMessageActionVerifier.verify(
                textDigest: digest, afterRowID: preLatest,
                capabilities: database.capabilities,
                fetch: { try await database.messages(after: $0, chatGUID: chatGUID) })
            await database.close()
        } catch {
            verification = .failed("the watch itself failed: \(IMessagePairNow.sanitise(String(describing: error)))")
        }
        _ = ActionReceiptStore.shared.record(
            IMessageActionVerifier.receipt(verification: verification, intent: intent, actionID: actionID))
        switch verification {
        case .dispatched:
            return ["IMESSAGE_SEND_TEST_FAILED: dispatched but the watch did not run"]
        case .landed:
            return ["IMESSAGE_SEND_TEST_OK: landed"]
        case .delivered:
            return ["IMESSAGE_SEND_TEST_OK: delivered"]
        case .failed(let reason):
            return ["IMESSAGE_SEND_TEST_FAILED: \(reason) — do not send again without checking the conversation"]
        }
    }
}
