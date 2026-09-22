import SwiftUI

/// "Which model does what", in three rows.
///
/// The words on screen are the jobs, not the technology: someone who has never heard of a
/// parameter count still knows what "Writing code" means. The menu groups the choices by
/// where they live — on this Mac, apps you already have, online — and a dot says whether
/// each one can answer right now. When the choice cannot be honoured the row says so in a
/// whole sentence, because a greyed-out row is a puzzle and a sentence is an answer.
struct ModelRoleSection: View {
    @State private var roles = ModelRoleStore.shared
    @State private var runtimes = LocalRuntimeCatalog.shared
    @State private var library = InstalledModelLibrary.shared
    @State private var settings = Settings.shared
    @State private var models = LocalModelStore.shared
    @State private var newAddress = ""
    @State private var addressProblem: String?

    var body: some View {
        Section {
            ForEach(ModelRole.allCases) { role in
                ModelRoleRow(role: role, roles: roles, options: options(for: role))
            }
            HStack(spacing: DS.Space.s) {
                Button(runtimes.isChecking ? "Checking…" : "Check again") {
                    Task { await roles.refreshAvailability() }
                }
                .disabled(runtimes.isChecking || roles.isCheckingAvailability)
                if let checked = runtimes.lastChecked {
                    Text("Last checked \(checked.formatted(date: .omitted, time: .shortened))")
                        .font(DS.Font.caption)
                        .foregroundStyle(DS.Color.textSecondary)
                }
            }
            resetButton
            otherApps
        } header: {
            Text("Which model does what")
        } footer: {
            SettingsNote(text: footer)
        }
        .task {
            if !SelfTest.isRunning { await roles.refreshAvailability() }
        }
    }

    private var footer: String {
        "Next Notes comes with its own model and uses it for everything unless you say "
            + "otherwise. If Ollama or LM Studio are running on this Mac, their models show "
            + "up here on their own, and apps like Claude Code and Codex show up for the "
            + "jobs they can do. A green dot means it would work right now; grey means it "
            + "wouldn't, and the line underneath says what's missing. Either way, if what "
            + "you picked isn't there when you ask for something, Next Notes uses its own "
            + "model instead and tells you."
    }

    /// A button to restore the default model when a different model is installed.
    @ViewBuilder
    private var resetButton: some View {
        let activeModelID = library.activeAgentModelID
        let isUsingNonDefaultModel = activeModelID != InstalledModelLibrary.builtInID

        if isUsingNonDefaultModel {
            Button {
                Task {
                    // Download the built-in model if not already downloaded
                    if !NotesModels.isDownloaded {
                        models.prepareNotesModel()
                    }
                    // Route through the role store, not straight at the file: the next
                    // agent turn re-asserts the agent role's choice over the file, so a
                    // direct file switch with the choice still on MiniCPM would flip back.
                    roles.setChoice(.builtIn, for: .agent)
                    // Refresh the roles to update the display
                    await roles.refreshAvailability()
                }
            } label: {
                HStack {
                    Image(systemName: "arrow.counterclockwise")
                    Text("Restore default model")
                }
            }
            .disabled(models.notesModelState.isBusy)
        }
    }

    /// Only shown once, under the rows: a way to point at a model app that isn't one of the
    /// two we look for. Deliberately undramatic — most people will never open it.
    @ViewBuilder
    private var otherApps: some View {
        DisclosureGroup("Another model app on this Mac") {
            VStack(alignment: .leading, spacing: DS.Space.s) {
                ForEach(runtimes.customAddresses, id: \.self) { address in
                    HStack {
                        Text(address)
                            .font(DS.Font.caption)
                            .foregroundStyle(DS.Color.textSecondary)
                        Spacer()
                        Button("Remove") { runtimes.removeCustomAddress(address) }
                    }
                }
                HStack(spacing: DS.Space.s) {
                    TextField("Address, for example localhost:8080", text: $newAddress)
                        .textFieldStyle(.roundedBorder)
                    Button("Add") {
                        addressProblem = runtimes.addCustomAddress(newAddress)
                        if addressProblem == nil {
                            newAddress = ""
                            Task { await roles.refreshAvailability() }
                        }
                    }
                    .disabled(newAddress.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                if let addressProblem {
                    Text(addressProblem)
                        .font(DS.Font.caption)
                        .foregroundStyle(DS.Color.warning)
                }
                Text("Only apps running on this Mac can be added. Nothing is sent over the network.")
                    .font(DS.Font.caption)
                    .foregroundStyle(DS.Color.textSecondary)
            }
            .padding(.top, DS.Space.xs)
        }
    }

    // MARK: - Building the menu

    /// The choices for one role, in the three groups the menu shows.
    ///
    /// Only what that job can actually be given: a model file from the library belongs to
    /// the everyday assistant, because Next Notes loads one of them at a time, and an agent
    /// app can only take coding work. Offering the rest and then quietly using something
    /// else is what this screen exists to stop, so they are not offered — see
    /// `ModelRole.canUse`.
    private func options(for role: ModelRole) -> [ModelRoleOptionGroup] {
        everyKnownModel()
            .map {
                ModelRoleOptionGroup(
                    title: $0.title,
                    options: $0.options
                        .filter { role.canUse($0.choice) }
                        .map { detailed($0, for: role) }
                )
            }
            .filter { !$0.options.isEmpty }
    }

    /// "Installed" is the right word for writing code and the wrong one for driving the
    /// Mac: the part of Codex that clicks and types is a separate download behind a
    /// sign-in, so an app can be installed and still not able to do this job. The menu says
    /// which, rather than letting someone pick it and find out afterwards.
    private func detailed(_ option: ModelRoleOption, for role: ModelRole) -> ModelRoleOption {
        guard role == .computerUse, case .app(.codex) = option.choice else { return option }
        let readiness = roles.availability.codexComputerUse
        return ModelRoleOption(
            choice: option.choice,
            title: option.title,
            detail: readiness.isReady ? "Ready" : readiness.menuDetail,
            isReady: readiness.isReady
        )
    }

    /// Everything this Mac can reach, before any one job's limits are applied.
    private func everyKnownModel() -> [ModelRoleOptionGroup] {
        var groups: [ModelRoleOptionGroup] = []

        // Names the file the runtime actually loads, so replacing the default brain
        // renames this row too. One helper owns the name; see `ModelRoleStore.displayName`.
        let builtInTitle: String = roles.displayName(for: .builtIn, role: .agent)

        var onThisMac: [ModelRoleOption] = [
            ModelRoleOption(
                choice: .builtIn,
                title: builtInTitle,
                detail: builtInDetail,
                isReady: roles.availability.builtInModelReady
            )
        ]
        for model in library.models where !model.isBuiltIn {
            onThisMac.append(
                ModelRoleOption(
                    choice: .installedModel(id: model.id),
                    title: model.displayName,
                    detail: model.displaySize,
                    isReady: true
                )
            )
        }
        if roles.availability.appleFoundationReady {
            onThisMac.append(
                ModelRoleOption(
                    choice: .appleFoundation,
                    title: "Apple’s built-in intelligence",
                    detail: "Already on this Mac",
                    isReady: true
                )
            )
        }
        for endpoint in runtimes.endpoints {
            for model in runtimes.models(forEndpoint: endpoint.id) {
                onThisMac.append(
                    ModelRoleOption(
                        choice: .localServer(endpointID: endpoint.id, modelID: model.modelID),
                        title: model.displayName,
                        detail: [endpoint.displayName, model.detail].compactMap { $0 }
                            .joined(separator: " · "),
                        isReady: true
                    )
                )
            }
        }
        groups.append(ModelRoleOptionGroup(title: "On this Mac", options: onThisMac))

        var apps: [ModelRoleOption] = []
        for harness in AgentHarnessID.allCases where harness != .local {
            let ready = roles.availability.installedApps.contains(harness)
            // An app that is not installed is still listed, so the choice the product
            // ships with is visible and its absence is explained rather than hidden.
            apps.append(
                ModelRoleOption(
                    choice: .app(harness),
                    title: harness.displayName,
                    detail: ready ? "Installed" : "Not installed",
                    isReady: ready
                )
            )
        }
        groups.append(ModelRoleOptionGroup(title: "Apps you have", options: apps))

        let cloudModel = settings.openRouterAgentModelID
        groups.append(
            ModelRoleOptionGroup(
                title: "Online",
                options: [
                    ModelRoleOption(
                        choice: .cloud,
                        title: cloudModel.isEmpty ? "An online model" : cloudModel,
                        detail: roles.availability.cloudReady
                            ? "Set up in Models settings"
                            : "Needs setting up in Models settings",
                        isReady: roles.availability.cloudReady
                    )
                ]
            )
        )
        return groups
    }

    private var builtInDetail: String {
        roles.availability.builtInModelReady
            ? "Ready · nothing leaves this Mac"
            : "Not downloaded yet"
    }
}

/// One selectable model in the menu.
struct ModelRoleOption: Identifiable, Hashable {
    let choice: ModelRoleChoice
    let title: String
    let detail: String
    let isReady: Bool

    var id: String { choice.token }
}

struct ModelRoleOptionGroup: Identifiable, Hashable {
    let title: String
    let options: [ModelRoleOption]

    var id: String { title }
}

/// One job, its model, and the truth about whether that model can answer.
struct ModelRoleRow: View {
    let role: ModelRole
    let roles: ModelRoleStore
    let options: [ModelRoleOptionGroup]

    private var resolution: ModelRoleResolution { roles.resolution(for: role) }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            HStack(spacing: DS.Space.s) {
                Circle()
                    .fill(dotColour)
                    .frame(width: DS.Size.statusDot, height: DS.Size.statusDot)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 0) {
                    Text(role.displayName)
                    Text(role.summary)
                        .font(DS.Font.caption)
                        .foregroundStyle(DS.Color.textSecondary)
                }
                Spacer(minLength: DS.Space.m)
                picker
            }
            if let note = resolution.note {
                Text(note)
                    .font(DS.Font.caption)
                    .foregroundStyle(
                        resolution.needsAttention ? DS.Color.warning : DS.Color.textSecondary
                    )
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, DS.Space.xxs)
    }

    /// Amber only for something the person can put right — an app to install, a key to add.
    /// A job that is simply never done by that kind of model is explained in the sentence
    /// below the row rather than flagged as a fault.
    private var dotColour: Color {
        switch resolution.reason {
        case .honoured: DS.Color.success
        case .notThere: DS.Color.warning
        case .notThisJob: DS.Color.textSecondary
        }
    }

    private var picker: some View {
        Picker(role.displayName, selection: selection) {
            ForEach(options) { group in
                Section(group.title) {
                    ForEach(group.options) { option in
                        Text(label(for: option)).tag(option.choice)
                    }
                }
            }
            // A choice stored before an app was removed still has to have a row to sit in,
            // or the menu would silently show the wrong thing.
            if !options.flatMap(\.options).contains(where: { $0.choice == storedChoice }) {
                Text(orphanLabel).tag(storedChoice)
            }
        }
        .labelsHidden()
        .frame(maxWidth: DS.Size.progressWidth, alignment: .trailing)
    }

    private var storedChoice: ModelRoleChoice { roles.choice(for: role) }

    private var selection: Binding<ModelRoleChoice> {
        Binding(
            get: { storedChoice },
            set: { roles.setChoice($0, for: role) }
        )
    }

    private func label(for option: ModelRoleOption) -> String {
        option.detail.isEmpty ? option.title : "\(option.title) — \(option.detail)"
    }

    /// The row a stored choice sits in when it is not one of the ones on offer — an app
    /// that has since been removed, or a choice this job cannot use. Saying which of the two
    /// it is keeps the menu honest about what is actually selected.
    private var orphanLabel: String {
        guard role.canUse(storedChoice) else {
            switch storedChoice {
            case .app(let harness): return "\(harness.displayName) — not used for this job"
            case .installedModel(let id): return "\(id) — not used for this job"
            default: return "Not used for this job"
            }
        }
        switch storedChoice {
        case .installedModel(let id): return "\(id) — no longer on this Mac"
        case .localServer(_, let modelID): return "\(modelID) — not running"
        case .cloud, .app, .builtIn, .appleFoundation:
            return roles.displayName(for: storedChoice, role: role)
        }
    }
}
