import Foundation

/// The user's own iMessage identity, in the one form the trust boundary needs.
///
/// **A canonical form, and the reason is IM-02's finding.** A `chat.guid` is not an
/// address, and a scripting-interface `handle` is not a `chat.guid`. The two namespaces
/// do not meet, so the only way to compare a row's sender against "is this me" is to
/// reduce both to the same shape. That shape is this type.
///
/// **The canonical form is digits only, with a leading `+`.** A phone number arrives
/// in more than one shape — `+15551234567`, `+1 (555) 123-4567`, `5551234567` — and
/// a comparison that does not normalise will miss the one that matters. The `+` is
/// kept because it is what makes an E.164 handle routable, and stripping it would make
/// a local number look like a short code.
struct RemoteIdentity: Equatable, Sendable, Codable, Hashable {
    /// The canonical E.164 form: `+` followed by digits. No spaces, no punctuation,
    /// no country-code ambiguity.
    let canonical: String

    /// Builds from any shape Messages or the scripting interface can produce.
    /// Returns `nil` when the input has no digits at all — an empty identity is not
    /// an identity, and a pairing that stored one would fail closed on every row.
    init?(raw: String) {
        let digits = raw.filter(\.isNumber)
        guard !digits.isEmpty else { return nil }
        canonical = "+" + digits
    }

    /// The canonical form, for when the caller already has one.
    init(canonical: String) {
        self.canonical = canonical
    }

    /// Whether a row's sender handle is this identity. Compares canonical forms, so
    /// `+15551234567` and `+1 (555) 123-4567` are the same person.
    func matches(handle: String) -> Bool {
        guard let other = RemoteIdentity(raw: handle) else { return false }
        return other == self
    }

    /// Whether a row's sender handle is this identity, for a handle that is already
    /// canonical. Used by the classifier, which resolves once and compares many.
    func matches(canonicalHandle: String) -> Bool {
        canonical == canonicalHandle
    }
}
