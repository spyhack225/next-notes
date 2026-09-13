import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Pick one application off this Mac.
///
/// The formatting table has its own picker because that one also asks what the app can
/// render. This is the same walk without those switches — auto-send only needs a bundle
/// identifier.
struct InstalledAppPickerSheet: View {
    let alreadyListed: Set<String>
    let onAdd: (InstalledApp) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var apps: [InstalledApp] = []
    @State private var isLoading = true
    @State private var query = ""
    @State private var selectedID: String?

    private var candidates: [InstalledApp] {
        let pool = apps.filter { !alreadyListed.contains($0.bundleID) }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return pool }
        return pool.filter {
            $0.displayName.localizedStandardContains(trimmed)
                || $0.bundleID.localizedStandardContains(trimmed)
        }
    }

    private var selected: InstalledApp? {
        candidates.first { $0.bundleID == selectedID }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.l) {
            SectionHeading(
                title: "Choose an app",
                eyebrow: "Auto-send",
                subtitle: "Dictation in this app will press Return after the text is typed."
            )

            TextField("Search", text: $query, prompt: Text("Search apps"))
                .textFieldStyle(.roundedBorder)

            appList

            HStack {
                Button("Browse…") { browse() }
                    .help("Find an app this list does not show")
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Add") {
                    guard let selected else { return }
                    onAdd(selected)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(selected == nil)
            }
        }
        .padding(DS.Space.xl)
        .frame(width: DS.Size.sheetWidth)
        .task {
            apps = await InstalledApps.scan()
            isLoading = false
        }
    }

    @ViewBuilder
    private var appList: some View {
        if isLoading {
            LabeledOrb(
                state: .searching,
                title: "Looking through your applications\u{2026}",
                size: DS.Size.orbSmall
            )
            .frame(maxWidth: .infinity)
            .frame(height: DS.Size.formatListHeight)
        } else if candidates.isEmpty {
            ContentUnavailableView.search(text: query)
                .frame(height: DS.Size.formatListHeight)
        } else {
            List(candidates, selection: $selectedID) { app in
                HStack(spacing: DS.Space.s) {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: app.path))
                        .resizable()
                        .frame(width: DS.Size.appIcon, height: DS.Size.appIcon)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(app.displayName)
                            .font(DS.Font.body)
                        Text(app.bundleID)
                            .font(DS.Font.caption2)
                            .foregroundStyle(DS.Color.textTertiary)
                    }
                }
                .tag(app.bundleID)
            }
            .listStyle(.inset)
            .alternatingRowBackgrounds()
            .frame(height: DS.Size.formatListHeight)
        }
    }

    private func browse() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = "Choose"
        guard panel.runModal() == .OK, let url = panel.url,
              let app = InstalledApps.app(at: url) else { return }

        if !apps.contains(where: { $0.bundleID == app.bundleID }) { apps.append(app) }
        query = app.displayName
        selectedID = app.bundleID
    }
}
