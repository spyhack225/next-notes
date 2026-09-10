import AppKit
import UniformTypeIdentifiers
import SwiftUI

/// Which app gets which formatting, and the editor for that table.
///
/// The list is a grid rather than a `Table`: at the settings window's width five capability
/// columns plus an app name leaves a `Table`'s own column headers no room, and the headers
/// are the only thing that says what the five checkboxes mean. A header row of symbols with
/// tooltips, over rows of unlabelled checkboxes, fits and reads as a table anyway.
///
/// Alone among the settings tabs this one is NOT a `Form`. It was, and the app list could not
/// be scrolled: a grouped `Form` is itself a scroll view, and a `List` nested inside one gets
/// a fixed height with no way to reach the rows past it — every app below the fold was simply
/// unreachable. The tab is a plain stack so the list is the only scroll view on the pane and
/// owns the wheel. Do not put this back inside a `Form`.
struct FormattingSettingsTab: View {
    @State private var store = OutputProfileStore.shared
    @State private var selection: Set<String> = []
    @State private var isAdding = false
    @State private var isPicking = false

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.m) {
            Text("Apps")
                .font(DS.Font.headline)

            columnHeader
            profileList
            controls

            SettingsNote(
                text: "Dictated text is written to suit the app it is about to land in — a "
                    + "spoken list becomes bullets in Slack and a sentence in Mail. An "
                    + "app that isn't listed gets plain prose, because a formatting mark "
                    + "an app doesn't render is worse than none."
            )

            Divider()

            HStack {
                Button("Add apps Next Notes knows about") { store.addMissingDefaults() }
                    .help("Puts back any built-in app you have removed. Your own rows and "
                          + "your edits are left alone.")
                Spacer()
                Button("Reveal formatting.txt") {
                    NSWorkspace.shared.activateFileViewerSelecting([OutputProfileStore.fileURL])
                }
                .buttonStyle(.link)
                .help(OutputProfileStore.fileURL.path)
            }

            SettingsNote(text: "The table is a plain text file. Edit it in any editor and "
                         + "the app picks up the change immediately.")
        }
        .padding(DS.Space.xl)
        .sheet(isPresented: $isAdding) {
            OutputProfileEditor(existing: nil) { store.upsert($0) }
        }
        .sheet(isPresented: $isPicking) {
            AppPickerSheet(alreadyListed: Set(store.profiles.map(\.bundleID))) { app, capabilities in
                store.upsert(OutputProfile(
                    bundleID: app.bundleID,
                    displayName: app.displayName,
                    capabilities: capabilities
                ))
                selection = [app.bundleID]
            }
        }
    }

    // MARK: - The table

    private var columnHeader: some View {
        HStack(spacing: DS.Space.xs) {
            Text("App")
                .font(DS.Font.caption)
                .foregroundStyle(DS.Color.textSecondary)
            Spacer()
            ForEach(OutputCapability.allCases, id: \.self) { capability in
                Image(systemName: capability.systemImage)
                    .font(DS.Font.caption)
                    .foregroundStyle(DS.Color.textSecondary)
                    .frame(width: DS.Size.formatCapabilityColumn)
                    .help("\(capability.displayName) — \(capability.help)")
            }
        }
    }

    @ViewBuilder
    private var profileList: some View {
        if store.profiles.isEmpty {
            // A stage, not a fault: an empty table is what a fresh install looks like, and
            // every app still gets plain prose meanwhile. `breathing` is the orb for
            // nothing-here-yet — a grey symbol would say the screen was broken.
            OrbUnavailableView(
                .breathing,
                title: "No apps listed",
                message: "Every app gets plain prose until you add one."
            )
            .frame(maxHeight: .infinity)
        } else {
            List(selection: $selection) {
                ForEach(store.profiles) { profile in
                    OutputProfileRow(profile: profile) { capability, isOn in
                        store.setCapability(capability, on: isOn, for: profile.bundleID)
                    }
                    .tag(profile.bundleID)
                }
            }
            .listStyle(.inset)
            .alternatingRowBackgrounds()
            .frame(minHeight: DS.Size.formatListHeight, maxHeight: .infinity)
        }
    }

    private var controls: some View {
        HStack(spacing: DS.Space.s) {
            Menu {
                Button("Choose from Installed Apps…") { isPicking = true }
                Button("Enter a Bundle Identifier…") { isAdding = true }
            } label: {
                Label("Add", systemImage: "plus")
            }
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Add an app")

            Button {
                store.delete(bundleIDs: selection)
                selection = []
            } label: {
                Label("Remove", systemImage: "minus")
            }
            .disabled(selection.isEmpty)
            .help("Remove the selected apps. They fall back to plain prose.")

            Spacer()

            addFrontmostButton
        }
        .labelStyle(.iconOnly)
    }

    /// One click for the app the user was in a moment ago.
    ///
    /// Far kinder than asking anyone to find a bundle identifier, and it is the reason the
    /// store tracks app activations: by the time this window is open Next Notes is itself
    /// the frontmost app, so asking the workspace right now would only ever answer
    /// "Next Notes".
    @ViewBuilder
    private var addFrontmostButton: some View {
        if let app = store.lastForeignApp {
            let known = store.profile(for: app.bundleID) != nil
            Button {
                store.upsert(OutputProfile(bundleID: app.bundleID, displayName: app.displayName))
                selection = [app.bundleID]
            } label: {
                Label("Add \(app.displayName)", systemImage: "plus.rectangle.on.rectangle")
            }
            .labelStyle(.titleAndIcon)
            .disabled(known)
            .help(known
                  ? "\(app.displayName) is already listed"
                  : "Add \(app.displayName) (\(app.bundleID)), the app you were last in")
        }
    }
}

// MARK: - Row

private struct OutputProfileRow: View {
    let profile: OutputProfile
    let onToggle: (OutputCapability, Bool) -> Void

    var body: some View {
        HStack(spacing: DS.Space.xs) {
            VStack(alignment: .leading, spacing: 0) {
                Text(profile.displayName)
                    .font(DS.Font.body)
                Text(profile.isPlain ? "Plain prose" : profile.bundleID)
                    .font(DS.Font.caption2)
                    .foregroundStyle(DS.Color.textTertiary)
            }
            Spacer()
            ForEach(OutputCapability.allCases, id: \.self) { capability in
                Toggle(
                    capability.displayName,
                    isOn: Binding(
                        get: { profile.capabilities.contains(capability) },
                        set: { onToggle(capability, $0) }
                    )
                )
                .labelsHidden()
                .toggleStyle(.checkbox)
                .frame(width: DS.Size.formatCapabilityColumn)
                .help("\(profile.displayName): \(capability.help)")
            }
        }
        .padding(.vertical, DS.Space.xxs)
    }
}

// MARK: - Editor

/// Add an app by bundle identifier, for anything not currently running.
private struct OutputProfileEditor: View {
    let existing: OutputProfile?
    let onSave: (OutputProfile) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var bundleID: String
    @State private var displayName: String
    @State private var capabilities: Set<OutputCapability>

    init(existing: OutputProfile?, onSave: @escaping (OutputProfile) -> Void) {
        self.existing = existing
        self.onSave = onSave
        _bundleID = State(initialValue: existing?.bundleID ?? "")
        _displayName = State(initialValue: existing?.displayName ?? "")
        _capabilities = State(initialValue: existing?.capabilities ?? [])
    }

    private var trimmedBundleID: String {
        bundleID.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.l) {
            Text(existing == nil ? "Add an App" : "Edit App")
                .font(DS.Font.title3)

            Form {
                TextField(
                    "Bundle identifier",
                    text: $bundleID,
                    prompt: Text("com.tinyspeck.slackmacgap")
                )
                TextField("Name", text: $displayName, prompt: Text("Slack"))

                ForEach(OutputCapability.allCases, id: \.self) { capability in
                    Toggle(capability.displayName, isOn: Binding(
                        get: { capabilities.contains(capability) },
                        set: { isOn in
                            if isOn { capabilities.insert(capability) }
                            else { capabilities.remove(capability) }
                        }
                    ))
                    .help(capability.help)
                }
            }
            .formStyle(.grouped)

            SettingsNote(text: "Leave every switch off for plain prose. Only switch on what "
                         + "the app actually renders — a mark it doesn't render shows up as "
                         + "literal punctuation in your message.")

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    onSave(OutputProfile(
                        bundleID: trimmedBundleID,
                        displayName: displayName.trimmingCharacters(in: .whitespacesAndNewlines)
                            .isEmpty
                            ? trimmedBundleID
                            : displayName.trimmingCharacters(in: .whitespacesAndNewlines),
                        capabilities: capabilities
                    ))
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(trimmedBundleID.isEmpty)
            }
        }
        .padding(DS.Space.xl)
        .frame(width: DS.Size.sheetWidth)
    }
}

// MARK: - Installed app picker

/// Pick an app off this Mac, and say what it can render.
///
/// The identifier form below is still there for the rare app this cannot see, but nobody
/// should have to use it. A bundle identifier typed from memory fails silently: the profile
/// simply never matches, and the user gets plain prose with nothing to explain why.
private struct AppPickerSheet: View {
    let alreadyListed: Set<String>
    let onAdd: (InstalledApp, Set<OutputCapability>) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var apps: [InstalledApp] = []
    @State private var isLoading = true
    @State private var query = ""
    @State private var selectedID: String?
    @State private var capabilities: Set<OutputCapability> = []

    /// Apps already in the table are dropped rather than shown greyed out. This list is long
    /// enough that the shortest version of it is the kindest.
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
            Text("Add an App")
                .font(DS.Font.title3)

            TextField("Search", text: $query, prompt: Text("Search apps"))
                .textFieldStyle(.roundedBorder)

            appList

            Divider()

            capabilityRow

            HStack {
                Button("Browse…") { browse() }
                    .help("Find an app this list does not show")
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Add") {
                    guard let selected else { return }
                    onAdd(selected, capabilities)
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
            // `searching` — reading things it did not write, to find something — for a walk
            // over every application folder on the Mac. It is the one wait on this sheet,
            // so it is the one orb.
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

    private var capabilityRow: some View {
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            ForEach(OutputCapability.allCases, id: \.self) { capability in
                Toggle(capability.displayName, isOn: Binding(
                    get: { capabilities.contains(capability) },
                    set: { isOn in
                        if isOn { capabilities.insert(capability) } else { capabilities.remove(capability) }
                    }
                ))
                .help(capability.help)
            }

            SettingsNote(text: "Leave every switch off for plain prose. Only switch on what "
                         + "the app actually renders — a mark it doesn't render shows up as "
                         + "literal punctuation in your message.")
        }
        .disabled(selected == nil)
        .opacity(selected == nil ? DS.Opacity.disabled : 1)
    }

    /// The escape hatch for an app outside the folders the scan walks.
    private func browse() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = "Choose"
        guard panel.runModal() == .OK, let url = panel.url,
              let app = InstalledApps.app(at: url) else { return }

        // Fold it into the list so the selection machinery has something to point at, rather
        // than carrying a second "chosen app" that the rest of this view would have to know
        // about everywhere it reads `selected`.
        if !apps.contains(where: { $0.bundleID == app.bundleID }) { apps.append(app) }
        query = app.displayName
        selectedID = app.bundleID
    }
}
