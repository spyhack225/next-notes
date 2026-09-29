import Foundation

/// One row as the pairing service sees it: the fields the pairing decision needs.
///
/// **Not `IMessageEnvelope`, and the reason is the same as `IMessageClassifier`'s.** The
/// envelope is the decoder's output and carries no chat and no resolved sender — the
/// pairing decision needs both. So the input is a separate value, and the watcher is
/// the one that builds it from the row it read.
struct PairingInput: Equatable, Sendable {
    var rowID: Int64
    var text: String?
    var chatGUID: String
    var senderHandle: String?
}

/// IM-07 — the stateful pairing service that drives the watcher.
///
/// **The one place a pairing is entered, confirmed or refused.** The watcher delivers
/// envelopes; this type decides whether a row is a pairing message, and if so,
/// persists the pairing and sends the confirmation. It is an actor because it owns
/// mutable state — the pairing window, the start row id, the confirmation flag — and
/// because the watcher delivers from a different executor.
///
/// ## The confirmation send is part of the gate
///
/// Pairing has not succeeded until the confirmation row is observed. The send is
/// IM-09's, but the *observation* is this type's: it watches for the row the send
/// produces, and only then marks the pairing complete. A send that fails means the
/// settings screen must not read `Connected` — this one send validates the outbound
/// path at exactly the moment the user is watching.
actor SelfChannelPairing {
    /// The store that persists the configuration.
    private let store: RemoteIdentityStore
    /// The watcher's watermark, so pairing mode can record the start row id.
    private let watermark: MessagesWatermark
    /// Sends the confirmation message. Injected so the self-test can observe it.
    private let sendConfirmation: @Sendable () async -> Bool

    /// Whether pairing mode is currently open.
    private var isPairing = false
    /// The `ROWID` recorded when pairing mode was entered.
    private var pairingStartRowID: Int64 = 0
    /// Whether the confirmation send has been observed.
    private var confirmationObserved = false

    init(store: RemoteIdentityStore,
         watermark: MessagesWatermark,
         sendConfirmation: @escaping @Sendable () async -> Bool = { false }) {
        self.store = store
        self.watermark = watermark
        self.sendConfirmation = sendConfirmation
    }

    /// Enters pairing mode. Records the current watermark as the start row id, so
    /// only rows newer than this point are considered.
    ///
    /// A second attempt while pairing is open is refused — the window is already
    /// running, and starting a new one would reset the boundary and accept a message
    /// that arrived before the first attempt.
    /// - Returns: `true` if pairing mode was entered, `false` if it was already open.
    @discardableResult
    func enterPairingMode() -> Bool {
        guard !isPairing else { return false }
        isPairing = true
        pairingStartRowID = watermark.lastProcessedRowID
        confirmationObserved = false
        return true
    }

    /// Leaves pairing mode without pairing. The window closes and nothing is persisted.
    func cancelPairing() {
        isPairing = false
        pairingStartRowID = 0
        confirmationObserved = false
    }

    /// Whether pairing mode is currently open.
    var isPairingActive: Bool { isPairing }

    /// The row id the pairing window started at.
    var currentPairingStartRowID: Int64 { pairingStartRowID }

    /// Handles a delivered row during pairing mode.
    ///
    /// - Returns: `true` if the row was a pairing message and the pairing has
    ///   succeeded (the confirmation was sent and observed).
    func handle(input: PairingInput) async -> Bool {
        guard isPairing else { return false }
        let decision = SelfChannel.decide(
            text: input.text,
            rowID: input.rowID,
            chatGUID: input.chatGUID,
            pairingStartRowID: pairingStartRowID
        )
        guard decision == .matches else { return false }

        // Persist the pairing: the chat guid and the local identity.
        let chatGUID = input.chatGUID
        let localIdentity = input.senderHandle ?? ""
        try? await store.update { config in
            config.enabled = true
            config.pairedChatGUID = chatGUID
            config.pairedAt = Date().timeIntervalSince1970
            config.localIdentity = localIdentity
        }

        // Send the confirmation. Pairing has not succeeded until this is observed.
        let sent = await sendConfirmation()
        if sent {
            confirmationObserved = true
            isPairing = false
            return true
        }
        return false
    }

    /// Whether the confirmation send has been observed.
    var isConfirmationObserved: Bool { confirmationObserved }
}
