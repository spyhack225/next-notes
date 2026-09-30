import Foundation

/// IM-10 — `dispatched` is not `landed`, and the difference is an `ActionReceipt`.
///
/// A successful Apple Event is not a delivery (measured twice: a `send` that
/// dispatched without error while no row ever landed). So after dispatch the send
/// is watched: the matching `chat.db` row is the proof, its guid names the receipt,
/// and a bounded wait that finds nothing is `.failed` — never `.dispatched`, because
/// a sent-but-unseen row reported as "dispatched" reads as progress and is none.
///
/// No second receipt store: the receipt is built for the existing
/// `ActionReceiptStore` (`action-receipts.json`), which already owns rotation,
/// harness isolation and the upsert-by-`actionID` that makes a second recording of
/// the same send an update rather than a duplicate. A parallel store would be the
/// second ledger `AGENTS.md` warns about.
enum IMessageSendVerification: Sendable, Equatable {
    /// Handed to Messages; the watch has not run (or could not run) yet.
    case dispatched
    /// The row exists. Its guid is captured; delivery is unconfirmed or the column
    /// is absent, and the receipt says which.
    case landed(messageGUID: String)
    /// The row exists with `is_delivered` set. Never reported when the capability
    /// probe says the column is absent — that degrades to `.landed`, honestly.
    case delivered(messageGUID: String)
    /// The bounded wait found no row. A send Apple Events accepted and that never
    /// landed — not a dispatch in progress.
    case failed(String)
}

/// Waits for a dispatched send's row and builds its receipt.
///
/// The fetch is injected so the five cases pin without Messages, a grant or a
/// live database: the db suite binds it to a fixture (`send-verify`), production
/// binds it to the paired chat. The receipt is recorded by the caller through the
/// store it owns — the shared store in production, a temp file in tests — so this
/// type never decides where the truth lands.
enum IMessageActionVerifier {
    /// Polls for an `is_from_me` row whose text digest matches, up to `maxAttempts`
    /// rounds `pauseNanos` apart.
    ///
    /// - `delivered` only when the row's `isDelivered` reads true **and** the
    ///   capabilities say the column exists; every other found row is `.landed`.
    ///   A row is never half-reported: without the column there is no delivery
    ///   claim to make.
    /// - The timeout is `.failed`, and the sentence says the send was accepted but
    ///   unobserved — because that is the one outcome that must never read as
    ///   `.landed`.
    static func verify(textDigest: Data,
                       afterRowID: Int64,
                       capabilities: MessagesCapabilities,
                       fetch: @Sendable (Int64) async throws -> [MessageRow],
                       maxAttempts: Int = 30,
                       pauseNanos: UInt64 = 1_000_000_000) async -> IMessageSendVerification {
        for attempt in 0..<max(1, maxAttempts) {
            do {
                let rows = try await fetch(afterRowID)
                if let landed = rows.first(where: {
                    $0.isFromMe && $0.text.map(OutboundDigest.text) == textDigest
                }) {
                    if capabilities.hasDeliveryState, landed.isDelivered == true {
                        return .delivered(messageGUID: landed.guid)
                    }
                    return .landed(messageGUID: landed.guid)
                }
            } catch {
                return .failed("the watch itself failed: \(IMessagePairNow.sanitise(String(describing: error)))")
            }
            if attempt + 1 < maxAttempts {
                try? await Task.sleep(nanoseconds: pauseNanos)
            }
        }
        return .failed("accepted by Messages but no matching row in the bounded wait")
    }

    /// Builds the receipt for a verification. The intent is the caller's frozen
    /// intent — verb, target shape, authority, and `arguments["textHash"]` holding
    /// the dispatched digest in hex — so "the receipt's payload equals the payload
    /// that was dispatched" is an equality the test can hold byte for byte:
    /// `receipt.intent == intent`, with the hash inside it.
    ///
    /// Identifiers stay shapes and hashes: the guid is an opaque handle captured
    /// into `verification`, the digest is one-way, and the target is the
    /// conversation's shape, never its guid or handle. The body itself appears
    /// nowhere — a receipt is an audit trail, not a transcript.
    ///
    /// Recording is the caller's, through the store it owns: the same `actionID`
    /// recorded twice upserts rather than duplicates, which is what makes a crash
    /// between dispatch and verification leave the ledger row pending with no
    /// second receipt.
    static func receipt(verification: IMessageSendVerification,
                        intent: ActionIntent,
                        actionID: UUID,
                        toolID: String = "imessage.send") -> ActionReceipt {
        var receipt = ActionReceipt(actionID: actionID, intent: intent,
                                    source: intent.source, authority: intent.authority,
                                    toolID: toolID)
        switch verification {
        case .dispatched:
            receipt.status = .fired
            receipt.result = "Handed to Messages; delivery not yet watched."
            receipt.events.append(ActionReceiptEvent(stage: .fired, detail: "dispatched"))
        case .landed(let guid):
            receipt.status = .completed
            receipt.result = "Your message landed."
            receipt.verification = "iMessage row \(guid) observed"
            receipt.events.append(ActionReceiptEvent(stage: .completed, detail: "landed"))
        case .delivered(let guid):
            receipt.status = .completed
            receipt.result = "Your message was delivered."
            receipt.verification = "iMessage row \(guid) observed, is_delivered set"
            receipt.events.append(ActionReceiptEvent(stage: .completed, detail: "delivered"))
        case .failed(let reason):
            receipt.status = .failed
            receipt.result = reason
            receipt.events.append(ActionReceiptEvent(stage: .failed, detail: reason))
        }
        receipt.completedAt = Date()
        return receipt
    }

    /// Lowercase hex of a digest, for `arguments["textHash"]`.
    static func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }
}
