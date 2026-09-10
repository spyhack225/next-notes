import ApplicationServices
import Foundation

/// What must never leave the other app's window, checked before a value is kept rather than
/// after.
///
/// These are the floor, not a feature. Wispr Flow took real reputational damage over screen
/// capture, and the difference between "reads the file tree of your editor" and "reads your
/// screen" is exactly this file. Every rule here rejects; none of them transform. A value
/// that trips any of them is dropped whole, because a redacted password is still a password
/// that was read.
enum ContextPrivacyFilter {
    /// Never harvested at all, whatever the adapter table says: banking, payments, password
    /// managers, health.
    ///
    /// A belt-and-braces list, and knowingly so — `AXAppAdapters` already answers "no" for
    /// every one of these, so nothing here is reachable today. It is here because the deny
    /// list has to be older than the adapter table it guards: the day someone adds a fourth
    /// adapter, or replaces the table with a capability probe, this is the file that stops a
    /// 1Password window being walked, and a rule written on that day would be written too
    /// late.
    static let deniedBundleIDs: Set<String> = [
        "com.apple.Passwords",
        "com.apple.keychainaccess",
        "com.apple.Health",
        "com.apple.WalletApp",
        "com.apple.stocks",
        "com.lastpass.LastPass",
        "com.bitwarden.desktop",
        "in.sinew.Enpass-Desktop",
        "com.stripe.dashboard",
    ]

    /// Prefix-matched as well as exact-matched, so a vendor's whole bundle namespace goes
    /// with it. Banks in particular ship one bundle per product and rename them yearly;
    /// matching `com.chase.` covers a build that has not shipped yet, which is the only kind
    /// of coverage worth anything in a deny list.
    static let deniedBundlePrefixes: Set<String> = [
        "com.1password",
        "com.agilebits",
        "com.dashlane",
        "com.keepersecurity",
        "org.keepassxc",
        "com.stickypassword",
        "com.intuit.",
        "com.quicken",
        "com.ynab",
        "com.mint",
        "com.paypal",
        "com.coinbase",
        "com.robinhood",
        "com.chase",
        "com.bankofamerica",
        "com.wellsfargo",
        "com.citi",
        "com.capitalone",
        "com.americanexpress",
        "com.schwab",
        "com.charlesschwab",
        "com.fidelity",
        "com.vanguard",
        "com.revolut",
        "com.wise",
        "com.n26",
        "com.monzo",
    ]

    /// Roles never read. The secure text field above all: a password field's value is
    /// readable through the accessibility API on macOS, which is the whole reason this role
    /// has to be named somewhere in this feature rather than assumed to be safe.
    ///
    /// A literal rather than a constant because HIServices exports no `kAX…` name for this
    /// one — the role string is real and documented, the Swift constant is not.
    static let deniedRoles: Set<String> = [
        "AXSecureTextField",
    ]

    /// The browser URL field's subroles — a URL is browsing history and it is never a file
    /// name — plus the secure-field subrole, which some toolkits set on a plain text field
    /// instead of changing its role.
    ///
    /// Spelled as string literals rather than framework constants on purpose: HIServices
    /// exports no constant for `AXAddressField` at all, so half this table would be literals
    /// anyway, and a table where half the rows are constants and half are strings is one
    /// somebody edits wrongly.
    static let deniedSubroles: Set<String> = [
        "AXSecureTextField",
        "AXAddressField",
        "AXSearchField",
    ]

    static func isDenied(bundleID: String) -> Bool {
        if deniedBundleIDs.contains(bundleID) { return true }
        return deniedBundlePrefixes.contains { bundleID.hasPrefix($0) }
    }

    /// Whether an element may be read at all, before its value is looked at.
    ///
    /// The identifier check is the one that earns its place: an Electron app builds its own
    /// password and token fields out of ordinary text inputs, so the role says `AXTextField`
    /// and only the id says `password`. Substring-matched, because the id is a DOM id and
    /// reads `settings.password.input` rather than `password`.
    static func allows(role: String, subrole: String?, identifier: String?) -> Bool {
        guard !deniedRoles.contains(role) else { return false }
        if let subrole, deniedSubroles.contains(subrole) { return false }
        guard let identifier, !identifier.isEmpty else { return true }
        let lowered = identifier.lowercased()
        return !deniedIdentifierFragments.contains { lowered.contains($0) }
    }

    private static let deniedIdentifierFragments: [String] = [
        "password", "passwd", "secret", "token", "apikey", "api-key", "api_key",
        "credential", "otp", "cvv", "iban", "account-number", "accountnumber", "ssn",
    ]

    /// Whether a harvested string may be kept.
    ///
    /// Scanned scalar by scalar rather than with a regular expression, so that each rejection
    /// below is a line somebody can read and argue with. The rules are in the order they were
    /// added, which is roughly cheapest first.
    static func allows(value: String) -> Bool {
        guard !value.isEmpty, value.count <= maxValueLength else { return false }

        var hasLetter = false
        var digitRun = 0
        var longestDigitRun = 0

        for character in value {
            // A newline or a tab means this is a block of text rather than a name — a whole
            // editor pane arrives as one value in some apps, and the length cap alone lets a
            // short two-line one through.
            if character.isNewline || character == "\t" { return false }
            if character.isNumber {
                digitRun += 1
                longestDigitRun = max(longestDigitRun, digitRun)
            } else if !isGroupingSeparator(character) {
                // Only a non-separator ends a run. That is the whole trick below.
                digitRun = 0
                if character.isLetter { hasLetter = true }
            }
        }

        // No letter at all: a numeric-only field is an account number, an amount or a line
        // number, and never a file name.
        guard hasLetter else { return false }
        guard !value.contains("://"), !looksLikeEmail(value) else { return false }

        // Card- and IBAN-shaped: what makes one is a long unbroken run of digits once the
        // grouping is taken out, which is why spaces and hyphens do not end a run above.
        // "4111 1111 1111 1111" is a run of sixteen and "GB29 NWBK 6016 1331 9268 19" a run of
        // fourteen, while "IMG_20240513_120001.jpg" — a real file name carrying fourteen
        // digits — has runs of only eight and six, because the underscores between its parts
        // are not grouping and do break them. A digit *share* was tried first and could not
        // tell those two apart: the IBAN is 73% digits and the photo 64%, and no threshold
        // fits in that gap worth trusting.
        if longestDigitRun >= 11 { return false }

        return true
    }

    /// The characters banks and card printers group long numbers with, which therefore must
    /// not break a run of digits.
    private static func isGroupingSeparator(_ character: Character) -> Bool {
        character == " " || character == "-" || character == "." || character == "/"
    }

    /// An @ with a letter before it and a dot after it. Matched as a shape rather than
    /// against a list of domains, because the domain is the part that varies — and matched at
    /// all because an email address in a sidebar row is a person, and a person's address has
    /// no business in a prompt about file names.
    private static func looksLikeEmail(_ value: String) -> Bool {
        guard let at = value.firstIndex(of: "@"), at != value.startIndex else { return false }
        let local = value[..<at]
        let domain = value[value.index(after: at)...]
        return local.contains(where: \.isLetter) && domain.contains(".")
    }

    /// Placeholder text is dropped by comparing an element's value against its
    /// `kAXPlaceholderValueAttribute` — "Search files", "Type a message" are not names, and
    /// they look exactly like names to a scoring function.
    static func isPlaceholder(value: String, placeholder: String?) -> Bool {
        guard let placeholder, !placeholder.isEmpty else { return false }
        return value.trimmingCharacters(in: .whitespaces)
            .compare(
                placeholder.trimmingCharacters(in: .whitespaces),
                options: [.caseInsensitive, .diacriticInsensitive]
            ) == .orderedSame
    }

    static let maxValueLength = 120
}
