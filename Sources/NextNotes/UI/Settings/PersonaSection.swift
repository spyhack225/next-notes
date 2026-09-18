import SwiftUI

/// The SOUL editor — free text saved to `persona.md` as it is typed.
///
/// Two live counters show what each kind of path hears — the Apple-model voice answer gets
/// only the first paragraph — and the part a cap cuts is shown struck through. Used from
/// Agent → About; Settings points here rather than hosting a second copy.
struct SoulEditor: View {
    @State private var settings = Settings.shared
    @State private var text = ""
    @State private var loaded = false
    @State private var saveError: String?
    @State private var saveTask: Task<Void, Never>?
    @State private var confirmingReset = false

    private let store = PersonaStore.shared

    var body: some View {
        Section {
            Toggle("Give the Agent this soul", isOn: $settings.agentPersonaEnabled)

            TextEditor(text: $text)
                .font(DS.Font.body)
                .frame(minHeight: 180)
                .disabled(!settings.agentPersonaEnabled)
                .onChange(of: text) { _, newValue in
                    guard loaded else { return }
                    scheduleSave(newValue)
                }

            let card = PersonaStore.shortCard(of: text)
            let full = PersonaStore.fullCard(of: text)
            HStack(spacing: DS.Space.m) {
                counter("Voice card (first paragraph)", card)
                counter("Everything else", full)
                Spacer()
                Button("Reset to base") { confirmingReset = true }
                    .confirmationDialog("Replace your soul with the base preset?",
                                        isPresented: $confirmingReset) {
                        Button("Reset to base", role: .destructive) { reset() }
                    }
            }

            if card.isTruncated {
                cutPreview(label: "The voice answer will not hear:", cut: card)
            }
            if full.isTruncated {
                cutPreview(label: "No prompt will hear:", cut: full)
            }
            if let saveError {
                Text(saveError).font(DS.Font.caption).foregroundStyle(DS.Color.warning)
            }
        } header: {
            Text("SOUL")
        } footer: {
            SettingsNote(text: "How the Agent talks, in your words. Fast spoken answers hear "
                         + "only the first paragraph, up to \(PersonaStore.shortCardLimit) "
                         + "characters; every other Agent prompt hears up to "
                         + "\(PersonaStore.fullLimit.formatted()). Safety rules always come after "
                         + "the soul and override it. Coding agents never receive it. When "
                         + "OpenRouter is the Agent model, the soul is sent with each request.")
        }
        .onAppear(perform: load)
        .onDisappear(perform: flush)
    }

    private func counter(_ title: String, _ cut: PersonaStore.Cut) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.xxs) {
            Text(title)
                .font(DS.Font.caption)
                .foregroundStyle(DS.Color.textSecondary)
            Text("\(cut.sourceCount.formatted()) / \(cut.limit.formatted())")
                .font(DS.Font.counterSmall)
                .foregroundStyle(cut.isTruncated ? DS.Color.warning : DS.Color.textSecondary)
        }
    }

    private func cutPreview(label: String, cut: PersonaStore.Cut) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.xxs) {
            Text(label)
                .font(DS.Font.caption)
                .foregroundStyle(DS.Color.warning)
            Text(cut.cut)
                .font(DS.Font.caption)
                .strikethrough(true, color: DS.Color.warning)
                .foregroundStyle(DS.Color.textSecondary)
                .lineLimit(4)
                .truncationMode(.middle)
        }
    }

    private func load() {
        text = store.text()
        DispatchQueue.main.async { loaded = true }
    }

    private func scheduleSave(_ value: String) {
        saveTask?.cancel()
        saveTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            write(value)
        }
    }

    private func flush() {
        guard loaded, saveTask != nil else { return }
        saveTask?.cancel()
        saveTask = nil
        write(text)
    }

    private func write(_ value: String) {
        do {
            try store.save(value)
            saveError = nil
        } catch {
            saveError = "Could not save persona.md: \(error.localizedDescription)"
        }
    }

    private func reset() {
        saveTask?.cancel()
        saveTask = nil
        do {
            loaded = false
            text = try store.resetToBase()
            saveError = nil
        } catch {
            saveError = "Could not reset persona.md: \(error.localizedDescription)"
        }
        DispatchQueue.main.async { loaded = true }
    }
}

/// Settings → Agent: points at the single SOUL editor in Agent → About.
struct PersonaSection: View {
    var body: some View {
        Section {
            Button("Edit Soul in Agent → About") {
                NavigationState.shared.showAgentAbout()
            }
        } header: {
            Text("SOUL")
        } footer: {
            SettingsNote(text: "How the Agent talks lives under Agent → About. The file on disk "
                         + "is still persona.md; only the word you see is SOUL.")
        }
    }
}
