import Foundation

/// IM-08c — the handle resolution and the `ResolvedSender` rules, as pure functions.
///
/// **A pure function, and the reason is the same as `IMessageClassifier`'s.** The
/// direction decision is the one that decides whether a row is the user's or a
/// stranger's, and a bug here turns a stranger's message into a command. So the
/// decision is a function of the row's sender handle and the local identity.
///
/// ## The rule
///
/// A row's sender is resolved against the local identity by **whole-value comparison
/// of canonical forms**. A normalised comparison that would match a *suffix* of the
/// local number does not — the comparison is whole-value, not `LIKE`. `+15551234567`
/// and `+15551234567` are the same; `+15551234567` and `5551234567` are not (the
/// latter is missing the country code, and a suffix match would call them the same).
///
/// ## Fail-closed
///
/// When the local identity is unknown, the answer is `.unresolved` — not
/// `.localNumber` and not `.foreignNumber`. A row whose sender cannot be resolved is
/// not the user's, but it is not *not* the user's either: it is a row this Mac cannot
/// classify, and the fail-closed answer is to say nothing.
enum IMessageDirectionResolver {
    /// The direction decision for one row.
    ///
    /// - Parameters:
    ///   - senderHandle: the row's sender handle, or nil when it is unknown.
    ///   - localIdentity: the user's own identity in canonical form.
    /// - Returns: `.localNumber` when the sender is the user, `.foreignNumber` when it
    ///   is somebody else, `.unresolved` when it cannot be resolved.
    static func resolve(senderHandle: String?, localIdentity: RemoteIdentity?) -> ResolvedSender {
        guard let handle = senderHandle, !handle.isEmpty else { return .unresolved }
        guard let local = localIdentity else { return .unresolved }
        return local.matches(handle: handle) ? .localNumber : .foreignNumber
    }

    /// Whether a canonical handle matches the local identity. Whole-value, not suffix.
    static func isLocal(_ handle: String, localIdentity: RemoteIdentity?) -> Bool {
        guard let local = localIdentity else { return false }
        return local.matches(handle: handle)
    }
}
