import AppKit
import UniformTypeIdentifiers
import SwiftUI

/// Which app gets which formatting, and the editor for that table.
///
/// The list is a grid rather than a `Table`: at the settings window's width six columns plus
/// an app name leaves a `Table`'s own column headers no room, and the headers are the only
/// thing that says what the checkboxes mean. A header row of symbols with tooltips, over rows
/// of unlabelled controls, fits and reads as a table anyway.
///
/// The sixth column is not a sixth checkbox. Five of them are capabilities — a set, any
/// combination valid — and the last is `PathReferenceStyle`, one choice of three on a
/// different axis, so it is a menu. It shares the capability columns' width because a symbol
/// fits there and the words fit inside the menu it opens; see `PathReferenceStyle.systemImage`.
///
/// Alone among the settings tabs this one is NOT a `Form`. It was, and the app list could not
/// be scrolled: a grouped `Form` is itself a scroll view, and a `List` nested inside one gets
/// a fixed height with no way to reach the rows past it — every app below the fold was simply
/// unreachable. The tab is a plain stack so the list is the only scroll view on the pane and
/// owns the wheel. Do not put this back inside a `Form`.
struct FormattingSettingsTab: View {
    @State private var store = OutputProfileStore.shared
    @State private var screenContext = ScreenContextStore.shared
    /// Bound directly, like every other settings tab. `screenContext.isEnabled` reads through to
    /// the same property; the tab binds the owner so the toggle needs no hand-written `Binding`.
    @State private var settings = Settings.shared
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

            screenNames

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
            AppPickerSheet(alreadyListed: Set(store.profiles.map(\.bundleID))) {
                app, capabilities, pathReference in
                store.upsert(OutputProfile(
                    bundleID: app.bundleID,
                    displayName: app.displayName,
                    capabilities: capabilities,
                    pathReference: pathReference
                ))
                selection = [app.bundleID]
            }
        }
    }

    // MARK: - Screen names

    /// The switch for reading names off the screen at all, and the plainest statement of what
    /// that means the user is going to get.
    ///
    /// The note is long and stays long. Wispr Flow took real reputational damage over screen
    /// capture, and a feature that reads another application's window has to say what it reads
    /// and what it does not, in the place where it is switched on — not in a support article.
    /// Naming the exclusions is the point: "we skip password fields" is the sentence somebody
    /// needs to see before they trust the switch, and it is only worth writing because
    /// `AXHarvester` actually enforces it.
    @ViewBuilder
    private var screenNames: some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            Text("Screen names")
                .font(DS.Font.headline)

            Toggle(
                "Use file and folder names visible on screen",
                isOn: $settings.screenContextEnabled
            )
            .help("Lets \"the login handler file\" come out as the real file name")

            // The one harvest failure the user can fix, and the only reason `AXHarvester` goes to
            // the trouble of telling a stub tree apart from an empty project. Bound to the
            // sticky record rather than to the live capture: by the time this window is
            // frontmost the captured harvest has been cleared and would never be a Cursor one
            // anyway. Dismissible because the user may have just fixed it, and the next hold
            // into that editor puts it back if they have not.
            if let remediation = screenContext.stubRemediation {
                ProblemBanner(message: remediation) {
                    screenContext.dismissStubRemediation()
                }
            }

            SettingsNote(
                text: "While you hold the dictation key, Next Notes reads the names of open "
                    + "tabs, files and folders in the app you are dictating into, and uses "
                    + "them to recognise a file you say out loud. Nothing is stored, nothing "
                    + "leaves your Mac, and no page or document text is read — only names. "
                    + "Password fields, number-only fields and browser address bars are "
                    + "skipped, and banking and finance apps are never read at all."
            )

            SettingsNote(
                text: "Needs cleanup set to fix grammar as well as punctuation: the "
                    + "punctuation-only model takes no instructions, so it has nowhere to be "
                    + "told which names are on screen."
            )
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
            Image(systemName: "at")
                .font(DS.Font.caption)
                .foregroundStyle(DS.Color.textSecondary)
                .frame(width: DS.Size.formatCapabilityColumn)
                .help("Whether this app resolves @-paths into files")
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
                    OutputProfileRow(
                        profile: profile,
                        onToggle: { capability, isOn in
                            store.setCapability(capability, on: isOn, for: profile.bundleID)
                        },
                        onPathReference: { style in
                            store.setPathReference(style, for: profile.bundleID)
                        }
                    )
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
    let onPathReference: (PathReferenceStyle) -> Void

    var body: some View {
        HStack(spacing: DS.Space.xs) {
            VStack(alignment: .leading, spacing: 0) {
                Text(profile.displayName)
                    .font(DS.Font.body)
                Text(profile.isPlain && !profile.resolvesPaths ? "Plain prose" : profile.bundleID)
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
            pathReferenceMenu
        }
        .padding(.vertical, DS.Space.xxs)
    }

    /// A `Picker` nested inside a `Menu` rather than a `Picker` on its own, so the trigger can
    /// be the current style's symbol while the options keep their words and their checkmark.
    /// A bare menu-style `Picker` shows its selected title, and "Backticked paths" is wider
    /// than the app-name column beside it.
    private var pathReferenceMenu: some View {
        Menu {
            Picker(
                "Path references",
                selection: Binding(
                    get: { profile.pathReference },
                    set: { onPathReference($0) }
                )
            ) {
                ForEach(PathReferenceStyle.allCases, id: \.self) { style in
                    Text(style.displayName).tag(style)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            Image(systemName: profile.pathReference.systemImage)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(width: DS.Size.formatCapabilityColumn)
        .help("\(profile.displayName): \(profile.pathReference.help)")
    }
}

// MARK: - Path references

/// The path-reference control both sheets use.
///
/// A labelled `Picker` here rather than the table row's symbol menu. A sheet has the width for
/// words, and a sheet is where someone is deciding what the setting means rather than flipping
/// one they already understand — the two contexts want opposite amounts of text, which is why
/// this is a second control rather than the row's one reused.
@ViewBuilder
private func pathReferencePicker(_ selection: Binding<PathReferenceStyle>) -> some View {
    Picker("File references", selection: selection) {
        ForEach(PathReferenceStyle.allCases, id: \.self) { style in
            Text(style.displayName).tag(style)
        }
    }
    .help("What this app does with a spoken file name. Choose \"@-paths\" only for an app that "
          + "opens the file the path names — anywhere else the @ arrives as a literal @.")
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
    @State private var pathReference: PathReferenceStyle

    init(existing: OutputProfile?, onSave: @escaping (OutputProfile) -> Void) {
        self.existing = existing
        self.onSave = onSave
        _bundleID = State(initialValue: existing?.bundleID ?? "")
        _displayName = State(initialValue: existing?.displayName ?? "")
        _capabilities = State(initialValue: existing?.capabilities ?? [])
        _pathReference = State(initialValue: existing?.pathReference ?? .plain)
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

                pathReferencePicker($pathReference)
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
                        capabilities: capabilities,
                        pathReference: pathReference
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
    let onAdd: (InstalledApp, Set<OutputCapability>, PathReferenceStyle) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var apps: [InstalledApp] = []
    @State private var isLoading = true
    @State private var query = ""
    @State private var selectedID: String?
    @State private var capabilities: Set<OutputCapability> = []
    @State private var pathReference: PathReferenceStyle = .plain

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
                    onAdd(selected, capabilities, pathReference)
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

            pathReferencePicker($pathReference)
                .fixedSize()

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
