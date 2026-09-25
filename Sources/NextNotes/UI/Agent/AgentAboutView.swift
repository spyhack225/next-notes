import SwiftUI

/// Agent → About: identity (name + Notion avatar), SOUL, and MEMORY — OpenClaw/Hermes-inspired
/// cards inside the existing glass / DS vocabulary (no textured gradients on chrome).
struct AgentAboutView: View {
    @State private var identity = AgentIdentityStore.shared
    @State private var memory = NextMemory.shared
    @State private var settings = Settings.shared
    @State private var audit = AgentAuditLog.shared
    @State private var navigation = NavigationState.shared
    @State private var editingName = false
    @State private var nameDraft = ""
    @State private var showAvatarEditor = false
    @State private var avatarDraft = NotionAvatarConfig.default
    @State private var showSoul = false
    @State private var showMemories = false
    /// The fact a graph dot asked to edit, highlighted when the sheet opens.
    @State private var memoryFocus: UUID?
    /// When this pane was opened. The hero falls asleep after ten quiet minutes, and coming
    /// back to a page you just opened is not quiet on any reading — so the clock starts at
    /// the later of the last thing the agent did and now.
    @State private var openedAt = Date()
    /// The pane's own size, so the editor sheets can open large on a large window and
    /// still fit a small one. A sheet is attached to the window, but the pane is what the
    /// person was looking at — and it is always narrower than the window, so clamping to
    /// it cannot overflow.
    @State private var paneSize = CGSize.zero

    var body: some View {
        AgentPaneScroll {
            // The one deliberate centred column in the panes: the identity block reads as
            // a hero, not as a header, so only this block is capped — and
            // `--selftest-agent-panes` allows `agentAboutMaxWidth` here alone. Every
            // section below it fills the pane's width.
            identityHeader
                .frame(maxWidth: DS.Size.agentAboutMaxWidth)
                .frame(maxWidth: .infinity)
            accessCards
            AgentDataControlsCard()
        }
        .onGeometryChange(for: CGSize.self) { $0.size } action: { paneSize = $0 }
        .sheet(isPresented: $showAvatarEditor) {
            NotionAvatarEditor(config: $avatarDraft) {
                identity.setAvatar(avatarDraft)
                showAvatarEditor = false
            }
        }
        .sheet(isPresented: $showSoul) {
            SoulEditorSheet(pane: paneSize)
        }
        .sheet(isPresented: $showMemories) {
            MemoriesEditorSheet(focus: memoryFocus, pane: paneSize)
                .onDisappear {
                    if memory.newCount > 0 { memory.markListViewed() }
                }
        }
        // A graph dot navigates here before this view exists, so the request is read on
        // appear as well as on change.
        .onAppear { presentMemoriesIfAsked() }
        .onChange(of: navigation.pendingMemory) { _, _ in presentMemoriesIfAsked() }
    }

    private func presentMemoriesIfAsked() {
        guard let id = navigation.consumePendingMemory() else { return }
        memoryFocus = id
        showMemories = true
    }

    // MARK: - Identity

    private var identityHeader: some View {
        VStack(spacing: DS.Space.m) {
            AgentAvatarBadge(
                config: identity.avatar,
                size: DS.Size.agentAvatarHero,
                // The agent's own history, not this pane's: anything it has done at all is
                // what the hero is resting from.
                restingSince: max(audit.entries.first?.at ?? .distantPast, openedAt)
            ) {
                avatarDraft = identity.avatar
                showAvatarEditor = true
            }

            if editingName {
                HStack(spacing: DS.Space.s) {
                    // A name is one value, so the field keeps the settings field width
                    // rather than stretching: a 600pt name field reads as a text area.
                    // The container around it is what fills the pane.
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
        GlassGroup(spacing: DS.Space.card) {
            // Two cards, so `AgentCardGrid`'s adaptive columns cannot fill the pane: the
            // grid sizes columns for however many *could* fit, and the two cards then sit
            // in the left half while the rest stays empty (see
            // `DS.Size.agentAboutCardsMinWidth`). This pair splits the width evenly when
            // both cards fit side by side and stacks them when they do not — the narrow
            // direction is the same content, same order, no overflow.
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: DS.Space.card) {
                    soulCard
                    memoryCard
                }
                .frame(minWidth: DS.Size.agentAboutCardsMinWidth, alignment: .leading)

                VStack(spacing: DS.Space.card) {
                    soulCard
                    memoryCard
                }
            }
        }
    }

    private var soulCard: some View {
        accessCard(
            title: "SOUL",
            subtitle: "ACCESS WITH CARE",
            date: personaDate,
            symbol: "heart.fill"
        ) { showSoul = true }
    }

    private var memoryCard: some View {
        accessCard(
            title: "MEMORY",
            subtitle: "ACCESS WITH CARE",
            date: memoryDate,
            symbol: "heart.fill"
        ) { showMemories = true }
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

/// The chrome SOUL and MEMORY share: a title row with Done, and a form that fills the
/// sheet so the editor or list inside stretches with it. Both open at
/// `DS.Size.sheetEditorWidth × sheetEditorHeight` on a pane with room and clamp to the
/// pane minus a page margin on one without — a sheet may not exceed the window, and the
/// pane is always narrower than the window it is attached to. The form scrolls either
/// way, so the sheet is usable at both ends.
private struct AgentEditorSheet<Content: View>: View {
    let title: String
    /// The pane this sheet was opened from, measured by `AgentAboutView`.
    var pane: CGSize
    @ViewBuilder var content: () -> Content

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(title)
                    .font(DS.Font.headline)
                    .tracking(DS.Font.eyebrowTracking)
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(DS.Space.card)

            Form {
                content()
            }
            .formStyle(.grouped)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: size.width, height: size.height)
    }

    /// The comfortable editor size, or the pane minus a page margin on each side when that
    /// is smaller. The fallback is for the instant before the pane's first layout pass
    /// reports a size; the pane cannot be opened from before it has drawn.
    private var size: CGSize {
        guard pane.width > 0, pane.height > 0 else {
            return CGSize(width: DS.Size.sheetEditorWidth, height: DS.Size.sheetEditorHeight)
        }
        return CGSize(
            width: min(DS.Size.sheetEditorWidth, max(0, pane.width - DS.Space.page * 2)),
            height: min(DS.Size.sheetEditorHeight, max(0, pane.height - DS.Space.page * 2))
        )
    }
}

private struct SoulEditorSheet: View {
    var pane: CGSize

    var body: some View {
        AgentEditorSheet(title: "SOUL", pane: pane) { SoulEditor() }
    }
}

private struct MemoriesEditorSheet: View {
    var focus: UUID?
    var pane: CGSize

    var body: some View {
        AgentEditorSheet(title: "MEMORY", pane: pane) { MemoriesEditor(focus: focus) }
    }
}
