import Foundation

/// `--imessage-pair-now`: pairs the self-channel on the newest "Hi Next" already in
/// this Mac's Messages database.
///
/// A diagnostic and modifier, not a `--selftest-*` flag, for the same two reasons
/// `--imessage-self-flow` is one: it reads the live `chat.db`, which needs Full Disk
/// Access and therefore a LaunchServices launch (`--via-open`), and it writes the
/// owner's real `imessage-settings.json`, which the self-test harness would swap away.
/// It runs before `runRequestedSelfTest` with `SelfTest.isRunning` still false.
///
/// It pairs on a message that is already there rather than watching for a new one:
/// the owner sends "Hi Next" to themselves from their phone first, then runs this.
/// The newest matching pair wins, so a stale trigger phrase from an earlier attempt
/// cannot pair the wrong conversation.
///
/// ## Why the twin, and why no join
///
/// IM-01 measured that a self-message is **two rows** — same text, opposite
/// `is_from_me`, adjacent ROWIDs. One lone row carrying the phrase is somebody else's
/// message, or half of a pair, and pairs nothing: the twin is what proves the phrase
/// was sent to yourself rather than at you. And the pass reads the **unfiltered**
/// tail (`messages(after:)` with no chat), because the chat join this database can
/// answer is probed, not assumed — a filter this machine cannot run is refused by
/// `MessagesDatabase`, and a pairing tool must work under the refusal rather than
/// fail on it. The chat is then the direct conversation whose identifier names the
/// pair's own handle.
///
/// It sends nothing. The confirmation reply is IM-09's send and needs the owner's
/// approval of the exact words, so pairing succeeding here means "paired, confirmation
/// pending" — the settings screen must not read `Connected` until the confirmation
/// row is observed (IM-07's gate).
///
/// Every line it returns goes through `writeSelfTest`, which honours `--selftest-out`:
/// a LaunchServices launch has no stdout, so `print` alone never reaches the runner
/// and the run times out waiting for a verdict that was already spoken.
enum IMessagePairNow {
    /// The flag, as the dispatch site spells it.
    static let flag = "--imessage-pair-now"

    /// How far back from the newest row one pass looks for the trigger phrase.
    /// A thousand rows is months of a self-conversation and one bounded query.
    static let lookbackRows: Int64 = 1000

    /// Pairs on the newest "Hi Next" twin. One string per line, marker last.
    static func run() async -> [String] {
        // Pairing is a local act (`RemoteAccessPolicy.mayEnterPairing`): this flag
        // runs in a local process, so the origin is nil and the gate is open. The
        // call exists so a future remote trigger has a gate to fail rather than a
        // path that silently pairs.
        guard RemoteAccessPolicy.mayEnterPairing(origin: nil) else {
            return ["IMESSAGE_PAIR_NOW_FAILED: pairing needs the Mac — it cannot start from a message"]
        }
        let store = RemoteIdentityStore(directory: AppIdentity.applicationSupportDirectory)
        if store.configuration.isPaired {
            return ["IMESSAGE_PAIR_NOW_OK: already paired — the confirmation reply still needs your approval"]
        }
        let database: MessagesDatabase
        do {
            database = try MessagesDatabase()
        } catch {
            // `String(describing:)`, not `localizedDescription`: `OpenError` carries its
            // reason in `CustomStringConvertible.description`, which `localizedDescription`
            // never shows — it answers "error 0" for every failure, which reads as a
            // verdict with the evidence removed.
            return ["IMESSAGE_PAIR_NOW_FAILED: chat.db unreadable — \(sanitise(String(describing: error)))"]
        }
        do {
            let latest = try await database.latestRowID()
            guard latest > 0 else {
                return ["IMESSAGE_PAIR_NOW_FAILED: chat.db holds no messages"]
            }
            // Unfiltered tail: needs no join table, so this works whatever shape the
            // join tables are in. `messages(after:)` walks oldest-first, so the floor is
            // the tail, not the head — asking after row 0 with a limit returns the oldest
            // rows, which is where a "Hi Next" sent today never is.
            let floor = max(0, latest - lookbackRows)
            let rows = try await database.messages(after: floor, limit: Int(lookbackRows))
            let candidates = rows
                .filter { $0.text == SelfChannel.triggerPhrase }
                .sorted { $0.rowID > $1.rowID }
            guard !candidates.isEmpty else {
                return ["IMESSAGE_PAIR_NOW_FAILED: no 'Hi Next' in the last \(lookbackRows) rows — send Hi Next to yourself from your phone, then run this again"]
            }
            let chats = try await database.chats(limit: MessagesDatabase.defaultChatPage)
            let direct = chats.filter { SelfChannel.isDirectChat($0.guid) }
            var lines = [joinLine(database: database)]
            lines.append("IMESSAGE_PAIR_NOW_SEEN: \(candidates.count) phrase row(s), "
                + "\(candidates.filter { twin(of: $0, in: rows) != nil }.count) with a twin, "
                + "\(direct.count) direct conversation(s)")
            // The chat is the direct conversation that *contains* the twin: the pair's
            // rows are found through the join this database can actually run, never by
            // matching a handle string. Newest pair first, newest chat first.
            for candidate in candidates {
                guard let twin = twin(of: candidate, in: rows) else { continue }
                let wanted: Set<Int64> = [candidate.rowID, twin.rowID]
                var holding: ChatRow? = nil
                for chat in direct {
                    let contents = try await database.messages(
                        after: floor, chatGUID: chat.guid, limit: Int(lookbackRows))
                    if contents.contains(where: { wanted.contains($0.rowID) }) {
                        holding = chat
                        break
                    }
                }
                guard let chat = holding else {
                    lines.append("IMESSAGE_PAIR_NOW_HANDLE: twin at rows \(twin.rowID)/\(candidate.rowID) held by no direct conversation")
                    continue
                }
                let messageHandle = await resolveHandle(candidate: candidate, twin: twin, in: database)
                // The conversation's own address is the next authority: for a direct
                // chat `chat_identifier` is the handle, and the twin already proved this
                // chat is the self-conversation.
                var raw = messageHandle
                var source = "message.handle_id"
                if raw == nil { raw = chat.chatIdentifier; source = "chat_identifier" }
                if raw == nil { raw = chat.participants.first; source = "participants" }
                lines.append("IMESSAGE_PAIR_NOW_CHAT: row \(candidate.rowID) held, "
                    + "handle from \(raw == nil ? "nothing" : source), "
                    + "identifier=\(chat.chatIdentifier == nil ? "absent" : "present"), "
                    + "participants=\(chat.participants.count)")
                guard let handle = raw, !handle.isEmpty else {
                    lines.append("IMESSAGE_PAIR_NOW_HANDLE: absent on rows \(twin.rowID)/\(candidate.rowID)")
                    continue
                }
                let canonical = RemoteIdentity(raw: handle)?.canonical ?? handle
                try store.update { config in
                    config.enabled = true
                    config.pairedChatGUID = chat.guid
                    config.pairedAt = Date().timeIntervalSince1970
                    config.localIdentity = canonical
                    config.chatHandleCache = handle
                    config.lastProcessedRowID = latest
                }
                lines.append("IMESSAGE_PAIR_NOW_OK: paired to the self-conversation at row \(candidate.rowID) — the confirmation reply still needs your approval")
                return lines
            }
            lines.append("IMESSAGE_PAIR_NOW_FAILED: found 'Hi Next' but no twin pair inside a direct conversation — send Hi Next to yourself from your phone, then run this again")
            return lines
        } catch {
            return ["IMESSAGE_PAIR_NOW_FAILED: \(sanitise(String(describing: error)))"]
        }
    }

    /// The twin: same text, opposite `is_from_me`, adjacent ROWIDs. Twins are inserted
    /// together, so a wider window is drift, not tolerance.
    static func twin(of row: MessageRow, in rows: [MessageRow]) -> MessageRow? {
        rows.first {
            $0.text == row.text
                && $0.isFromMe != row.isFromMe
                && abs($0.rowID - row.rowID) <= 2
        }
    }

    /// The pair's own handle. The `is_from_me = 0` copy's `handle_id` names the sender,
    /// which on a self-message is the owner; the `1` copy's names the recipient, which
    /// here is the same person, but the sender copy is the one to trust.
    static func resolveHandle(candidate: MessageRow, twin: MessageRow, in database: MessagesDatabase) async -> String? {
        let ordered = [twin, candidate].sorted { !$0.isFromMe && $1.isFromMe }
        for row in ordered {
            if let id = row.handleID, let handle = try? await database.handle(id: id) {
                return handle
            }
        }
        return nil
    }

    /// The join tables' probed shape, names only. Printed on every run so a refusal
    /// carries the measurement of what this database can actually join — column names
    /// are Apple's schema, never anybody's content.
    static func joinLine(database: MessagesDatabase) -> String {
        let columns = database.schema.columns
        func shape(_ table: String) -> String {
            guard let names = columns[table] else { return "\(table)=absent" }
            return "\(table)=[\(names.sorted().joined(separator: ","))]"
        }
        return "IMESSAGE_PAIR_NOW_JOIN: \(shape("chat_message_join")) \(shape("chat_handle_join"))"
    }

    /// An error line that may land in a log must not carry the home directory or a
    /// contact: SQLite errors quote the path they failed on, and the path holds the
    /// owner's user name.
    static func sanitise(_ text: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let masked = text.replacingOccurrences(of: home, with: "~")
        guard masked.count > 200 else { return masked }
        return String(masked.prefix(200)) + "…"
    }
}
