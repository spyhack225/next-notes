import SwiftUI

/// The same checklist the app shows on first launch, kept somewhere permanent.
///
/// TCC keys every grant to the code signature, so a re-signed build silently loses them —
/// which makes "where do I check this?" a question the app has to answer more than once.
struct PermissionsSettingsTab: View {
    var body: some View {
        Form {
            Section {
                PermissionsChecklist()
            } footer: {
                SettingsNote(text: "Grants are tied to this build's code signature. "
                             + "Reinstalling Next Notes can reset them.")
            }
        }
        .formStyle(.grouped)
    }
}
