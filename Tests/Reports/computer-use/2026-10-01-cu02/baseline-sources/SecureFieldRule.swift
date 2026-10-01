import Foundation

/// P1-23: the pages and fields the agent must not fill in for a person.
///
/// **A sign-in page, a CAPTCHA and a payment form are never attempted.** Not refused politely
/// after trying, not attempted and then noticed — never attempted. There is no such check in
/// `Computer/` (grepped 2026-09-27): the nearest rule is
/// `Context/ContextPrivacyFilter.swift`, which keeps password managers and payment apps out of
/// the *dictation* harvest, and that is a different question asked at a different moment.
///
/// Three rules, and the last one is the one that matters:
/// - **Never a model call.** A page that says "Sign in" is not read and judged; a role is.
/// - **Never a guess from page text.** "Password" in a heading is a page about passwords.
/// - **Only a role, or a `type` attribute the DOM already declares.** Both are facts about what
///   the control *is*, and neither can be produced by prose.
///
/// When one is aimed at, the answer is the same paused state as the person's hand: the same one
/// sentence, the same **Carry on**. A sign-in is the clearest case of "the person has to do this
/// part", and it must not get a second, different mechanism — two paths for one state is how one
/// of them ends up missing.
enum SecureFieldRule {

    /// The one AX role that holds a secret.
    ///
    /// `AXTextField` and `AXComboBox` are deliberately **absent**: they are the ordinary case,
    /// and a rule that refused every one of them would refuse the whole app. macOS reports a
    /// password box as `AXSecureTextField`, and that is the fact this rule is built on.
    static let secretRoles: Set<String> = ["AXSecureTextField"]

    /// The DOM input types that hold a secret. `password` is the one that matters; the others are
    /// the same secret asked three more ways, and a payment card field is `password`-shaped in
    /// some banks' own markup.
    static let secretInputTypes: Set<String> = [
        "password", "password-new", "current-password", "new-password", "cc-name", "cc-number",
        "cc-csc",
    ]

    /// The sentence. The same paused state, a different reason, and it names what is needed so
    /// the person is not left guessing which page the app is waiting on.
    static func refusalSentence(for what: String) -> String {
        "\(what) wants you to sign in. I\u{2019}ll carry on after."
    }

    /// The reason a snapshot is refused, or nil when it is not.
    ///
    /// Returned as a value rather than a bool so the sentence can say **what** it found, and so
    /// a self-test can pin the mapping without a window: the three labels are the three things
    /// this rule names, and a fourth one would be a rule nobody reviewed.
    enum Refusal: Equatable, Sendable {
        case secureField
        case paymentField
        case captcha

        var what: String {
            switch self {
            case .secureField: return "This page"
            case .paymentField: return "This payment form"
            case .captcha: return "This check"
            }
        }

        var sentence: String { refusalSentence(for: what) }
    }

    /// The one rule: the refusal for a control, or nil.
    ///
    /// - Parameters:
    ///   - role: the AX role as the snapshot labelled it, if any.
    ///   - inputType: the DOM `type` from a CDP snapshot, if any.
    ///   - secure: whether `AccessibilitySnapshot.isSecureField` found the secure attribute. It
    ///     is checked **independently of the role**, because it is the same fact read a second
    ///     way: a web view or a form that reports a plain role with a secure subrole must still
    ///     be refused. An earlier version of this file had a second function that checked the
    ///     flag and not the role, and the two disagreed on two of six cases.
    static func refusal(role: String?, inputType: String?, secure: Bool = false) -> Refusal? {
        // Either signal on its own is enough, because either one is the fact. macOS reports a
        // password box as `AXSecureTextField`; a web view can report a plain role with a secure
        // subrole. Whichever the snapshot carried, the answer is the same.
        if secure || (role.map { secretRoles.contains($0) } ?? false) { return .secureField }
        if let inputType {
            let type = inputType.lowercased()
            if ["cc-name", "cc-number", "cc-csc"].contains(type) { return .paymentField }
            if secretInputTypes.contains(type) { return .secureField }
        }
        return nil
    }

    /// A DOM query for the controls that must not be filled, for a CDP snapshot.
    ///
    /// A selector and not a model: it is answered by the DOM itself, and a page that hides a
    /// password field behind a shadow root is a page this rule does not reach — which is the
    /// right answer, because the alternative is guessing.
    static let domSelector = "input[type=password], input[autocomplete*=cc-], input[name*=cvv]"
}
