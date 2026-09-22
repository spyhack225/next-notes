import SwiftUI

/// Agent → About: identity (name + Notion avatar), SOUL, and MEMORY — OpenClaw/Hermes-inspired
/// cards inside the existing glass / DS vocabulary (no textured gradients on chrome).
struct AgentAboutView: View {
    @State private var identity = AgentIdentityStore.shared
    @State private var memory = NextMemory.shared
    @State private var settings = Settings.shared
    @State private var editingName = false
    @State private var nameDraft = ""
    @State private var showAvatarEditor = false
    @State private var avatarDraft = NotionAvatarConfig.default
    @State private var showSoul = false
    @State private var showMemories = false

    var body: some View {
        ScrollView {
            VStack(spacing: DS.Space.xl) {
                identityHeader
                accessCards
                AgentDataControlsCard()
            }
            .padding(DS.Space.page)
            .frame(maxWidth: DS.Size.agentAboutMaxWidth)
            .frame(maxWidth: .infinity)
        }
        .sheet(isPresented: $showAvatarEditor) {
            NotionAvatarEditor(config: $avatarDraft) {
                identity.setAvatar(avatarDraft)
                showAvatarEditor = false
            }
        }
        .sheet(isPresented: $showSoul) {
            SoulEditorSheet()
        }
        .sheet(isPresented: $showMemories) {
            MemoriesEditorSheet()
                .onDisappear {
                    if memory.newCount > 0 { memory.markListViewed() }
                }
        }
    }

    // MARK: - Identity

    private var identityHeader: some View {
        VStack(spacing: DS.Space.m) {
            AgentAvatarBadge(config: identity.avatar, size: DS.Size.agentAvatarHero) {
                avatarDraft = identity.avatar
                showAvatarEditor = true
            }

            if editingName {
                HStack(spacing: DS.Space.s) {
                    TextField("Agent name", text: $nameDraft)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: DS.Size.settingsFieldWidth)
                        .onSubmit(commitName)
                    Button("Save") { commitName() }
                        .buttonStyle(.borderedProminent)
                    Button("Cancel") { editingName = false }
                        .buttonStyle(.borderless)
                }
            } else {
                HStack(spacing: DS.Space.s) {
                    Text(identity.name)
                        .font(DS.Font.title2.weight(.semibold))
                        .tracking(DS.Font.wordTracking)
                    Button {
                        nameDraft = identity.displayName
                        editingName = true
                    } label: {
                        Image(systemName: "pencil")
                            .foregroundStyle(DS.Color.textSecondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Edit name")
                }
            }

            // G3: what the Agent calls you — from the first voice session, one tap to change.
            Button {
                showMemories = true
            } label: {
                Text(userNamingLine)
                    .font(DS.Font.callout)
                    .foregroundStyle(DS.Color.textSecondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Change what the Agent calls you")

            connectedStatus
        }
        .padding(.vertical, DS.Space.m)
    }

    private var connectedStatus: some View {
        HStack(spacing: DS.Space.xs) {
            Image(systemName: "bolt.fill")
                .font(DS.Font.caption)
            Text(settings.voiceWakeEnabled || settings.agentShortcutEnabled
                 ? "Connected"
                 : "Ready")
                .font(DS.Font.callout.weight(.medium))
        }
        .foregroundStyle(DS.Color.success)
        .accessibilityElement(children: .combine)
    }

    // MARK: - SOUL / MEMORY cards

    private var accessCards: some View {
        GlassGroup(spacing: DS.Space.m) {
            HStack(alignment: .top, spacing: DS.Space.m) {
                accessCard(
                    title: "SOUL",
                    subtitle: "ACCESS WITH CARE",
                    date: personaDate,
                    symbol: "heart.fill"
                ) { showSoul = true }

                accessCard(
                    title: "MEMORY",
                    subtitle: "ACCESS WITH CARE",
                    date: memoryDate,
                    symbol: "heart.fill"
                ) { showMemories = true }
            }
            .frame(maxWidth: .infinity)
        }
    }

    /// SOUL and MEMORY read as one monochrome family — black, white and grey, with hierarchy
    /// coming from weight, size and glass depth rather than a colour key.
    private func accessCard(
        title: String,
        subtitle: String,
        date: String,
        symbol: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: DS.Space.s) {
                Text(title)
                    .font(DS.Font.headline)
                    .tracking(DS.Font.eyebrowTracking)
                    .foregroundStyle(DS.Color.text)
                Text(subtitle)
                    .font(DS.Font.eyebrow)
                    .tracking(DS.Font.eyebrowTracking)
                    .foregroundStyle(DS.Color.textSecondary)
                Spacer(minLength: DS.Space.l)
                HStack {
                    Text(date)
                        .font(DS.Font.caption)
                        .foregroundStyle(DS.Color.textTertiary)
                        .monospacedDigit()
                    Spacer()
                    Image(systemName: symbol)
                        .foregroundStyle(DS.Color.textSecondary)
                        .font(DS.Font.callout)
                }
            }
            .padding(DS.Space.card)
            .frame(maxWidth: .infinity, minHeight: DS.Size.agentAccessCardMinHeight, alignment: .leading)
            .glassSurface(cornerRadius: DS.Radius.glass)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(title). \(subtitle)")
    }

    private var personaDate: String {
        let url = PersonaStore.shared.fileURL
        let modified = (try? FileManager.default
            .attributesOfItem(atPath: url.path)[.modificationDate]) as? Date
        return (modified ?? Date()).formatted(.dateTime.month(.twoDigits).day(.twoDigits).year(.twoDigits))
    }

    private var memoryDate: String {
        let latest = memory.entries.map(\.updatedAt).max()
        return (latest ?? Date()).formatted(.dateTime.month(.twoDigits).day(.twoDigits).year(.twoDigits))
    }

    private func commitName() {
        identity.setDisplayName(nameDraft)
        editingName = false
    }

    /// G3: "What should I call you?" answered once, shown beside the avatar.
    private var userNamingLine: String {
        let prose = AgentIdentityProse.shared.displayName
        if !prose.isEmpty { return "Calls you \(prose) · tap to change" }
        let remembered = memory.entries.first {
            $0.text.lowercased().contains("wants to be called")
        }?.text
        if let remembered,
           let range = remembered.range(of: "wants to be called ", options: .caseInsensitive) {
            let name = remembered[range.upperBound...].trimmingCharacters(in: .punctuationCharacters.union(.whitespaces))
            if !name.isEmpty { return "Calls you \(name) · tap to change" }
        }
        return "Tap to tell it what to call you"
    }
}

// MARK: - Sheets

private struct SoulEditorSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("SOUL")
                    .font(DS.Font.headline)
                    .tracking(DS.Font.eyebrowTracking)
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(DS.Space.card)
            Form {
                SoulEditor()
            }
            .formStyle(.grouped)
        }
        .frame(minWidth: 520, minHeight: 480)
    }
}

private struct MemoriesEditorSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("MEMORY")
                    .font(DS.Font.headline)
                    .tracking(DS.Font.eyebrowTracking)
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(DS.Space.card)
            Form {
                MemoriesEditor()
            }
            .formStyle(.grouped)
        }
        .frame(minWidth: 560, minHeight: 520)
    }
}
