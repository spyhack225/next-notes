import SwiftUI

/// `--voice-settings-preview [dir]` — the "Speaking back" section in each state it can show,
/// and the text-only line on the two surfaces that carry it, one PNG each.
///
/// A diagnostic for the eye, like `--settings-sheet`: it speaks nothing, downloads nothing and
/// writes nothing outside `dir`. The section is a function of the availability it is handed,
/// which is what lets every state be drawn without a real download going wrong on purpose.
@MainActor
enum VoiceSettingsPreview {
    private static let states: [(name: String, availability: AgentVoiceAvailability, kokoro: Bool)] = [
        ("ready", .ready, true),
        ("preparing", .preparing(progress: nil), true),
        ("preparing-progress", .preparing(progress: 0.4), true),
        ("needs-download", .needsDownload, true),
        ("failed", .failed, true),
        ("kokoro-unavailable", .ready, false),
    ]

    static func write(to directory: String) -> Bool {
        let root = URL(fileURLWithPath: directory, isDirectory: true)
        do { try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true) }
        catch { print("VOICE_SETTINGS_PREVIEW_FAILED: \(error.localizedDescription)"); return false }

        var written: [String] = []
        for state in states {
            let form = Form {
                VoiceSettingsSection(availability: state.availability,
                                     kokoroSupported: state.kokoro,
                                     isPreviewing: false,
                                     togglePreview: {}, stopPreview: {}, details: EmptyView())
            }
            .formStyle(.grouped)
            .background(DS.Color.window)
            if !save(form, width: DS.Size.settingsWidth, named: "voice-\(state.name).png",
                     in: root, into: &written) { return false }
        }

        let lines = VStack(alignment: .leading, spacing: DS.Space.m) {
            VoiceTextOnlyPaneLine(text: AgentVoiceAvailability.needsDownload.message ?? "")
            VoiceTextOnlyPaneLine(text: AgentVoiceAvailability.failed.message ?? "")
            Text(AgentVoiceAvailability.preparing(progress: nil).message ?? "")
                .font(DS.Font.caption)
                .foregroundStyle(DS.Color.islandInk)
                .padding(DS.Space.m)
                .background(DS.Color.island, in: RoundedRectangle(cornerRadius: DS.Radius.card))
        }
        .padding(DS.Space.page)
        .background(DS.Color.window)
        if !save(lines, width: DS.Size.settingsWidth, named: "voice-text-only-lines.png",
                 in: root, into: &written) { return false }

        print("VOICE_SETTINGS_PREVIEW_OK \(written.count) image(s): \(root.path)")
        written.forEach { print("  \($0)") }
        return true
    }

    private static func save(_ view: some View, width: CGFloat, named name: String,
                             in root: URL, into written: inout [String]) -> Bool {
        guard let png = SettingsSheet.render(view, width: width) else {
            print("VOICE_SETTINGS_PREVIEW_FAILED: \(name) did not render"); return false
        }
        do { try png.write(to: root.appendingPathComponent(name)) }
        catch { print("VOICE_SETTINGS_PREVIEW_FAILED: \(error.localizedDescription)"); return false }
        written.append(name)
        return true
    }
}
