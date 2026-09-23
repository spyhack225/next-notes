import AppKit
import SwiftUI

/// The two rows the whole feature hangs off: bring memory in, take memory out.
///
/// Two rows and nothing else, on purpose — the same shape Muse's *Data controls* uses, and
/// the reason it reads at a glance. Everything hard happens behind them.
///
/// Both the Settings form and the Agent → About pane show these, so the wording and the
/// order live here once rather than in two places that drift.
enum MemoryDataControls {
    static let importTitle = "Import memory"
    static let importSubtitle = "From a file, or from another assistant"
    static let exportTitle = "Download your assistant's memory"
    static let exportSubtitle = "Everything it knows about you, saved to this Mac"

    static let footer = "Nothing is sent anywhere. Downloading writes a folder where you "
        + "choose; bringing memory in shows you every line before anything is kept."
}

/// Settings → Agent ▸ MEMORY: the rows as a grouped-form section.
struct DataControlsSection: View {
    @State private var isImporting = false
    @State private var isExporting = false

    var body: some View {
        Section {
            Button {
                isImporting = true
            } label: {
                row(title: MemoryDataControls.importTitle,
                    subtitle: MemoryDataControls.importSubtitle,
                    symbol: "square.and.arrow.down")
            }
            .buttonStyle(.plain)

            Button {
                isExporting = true
            } label: {
                row(title: MemoryDataControls.exportTitle,
                    subtitle: MemoryDataControls.exportSubtitle,
                    symbol: "square.and.arrow.up")
            }
            .buttonStyle(.plain)
        } header: {
            Text("Your data")
        } footer: {
            SettingsNote(text: MemoryDataControls.footer)
        }
        .sheet(isPresented: $isImporting) { MemoryImportSheet() }
        .sheet(isPresented: $isExporting) { MemoryExportSheet() }
    }

    private func row(title: String, subtitle: String, symbol: String) -> some View {
        HStack(spacing: DS.Space.m) {
            Image(systemName: symbol)
                .foregroundStyle(DS.Color.textSecondary)
            VStack(alignment: .leading, spacing: DS.Space.xxs) {
                Text(title)
                    .foregroundStyle(DS.Color.text)
                Text(subtitle)
                    .font(DS.Font.caption)
                    .foregroundStyle(DS.Color.textSecondary)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(DS.Font.caption)
                .foregroundStyle(DS.Color.textTertiary)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

/// Agent → About: the same two rows as a glass card, beside SOUL and MEMORY.
struct AgentDataControlsCard: View {
    @State private var isImporting = false
    @State private var isExporting = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("YOUR DATA")
                .font(DS.Font.eyebrow)
                .tracking(DS.Font.eyebrowTracking)
                .foregroundStyle(DS.Color.textSecondary)
                .padding(.horizontal, DS.Space.card)
                .padding(.top, DS.Space.card)
                .padding(.bottom, DS.Space.s)

            row(title: MemoryDataControls.importTitle,
                subtitle: MemoryDataControls.importSubtitle) { isImporting = true }

            Divider()
                .padding(.leading, DS.Space.card)

            row(title: MemoryDataControls.exportTitle,
                subtitle: MemoryDataControls.exportSubtitle) { isExporting = true }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassSurface(cornerRadius: DS.Radius.glass)
        .sheet(isPresented: $isImporting) { MemoryImportSheet() }
        .sheet(isPresented: $isExporting) { MemoryExportSheet() }
    }

    private func row(title: String, subtitle: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: DS.Space.m) {
                VStack(alignment: .leading, spacing: DS.Space.xxs) {
                    Text(title)
                        .font(DS.Font.body)
                        .foregroundStyle(DS.Color.text)
                    Text(subtitle)
                        .font(DS.Font.caption)
                        .foregroundStyle(DS.Color.textSecondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(DS.Font.caption)
                    .foregroundStyle(DS.Color.textTertiary)
            }
            .padding(DS.Space.card)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(title). \(subtitle)")
    }
}

// MARK: - Download

/// "Download your assistant's memory": one question, then a save panel.
struct MemoryExportSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var identity = AgentIdentityStore.shared
    @State private var memory = NextMemory.shared
    @State private var includeRoutines = false
    @State private var saved: MemoryExporter.Result?
    @State private var error: String?

    private var routineCount: Int { ScheduleStore.shared.schedules.count }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.l) {
            Text(MemoryDataControls.exportTitle)
                .font(DS.Font.headline)

            if let saved {
                done(saved)
            } else {
                chooser
            }

            if let error {
                Text(error)
                    .font(DS.Font.caption)
                    .foregroundStyle(DS.Color.warning)
            }
        }
        .padding(DS.Space.page)
        .frame(width: DS.Size.memoryPortabilitySheetWidth)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var chooser: some View {
        VStack(alignment: .leading, spacing: DS.Space.l) {
            Text("This saves a folder holding everything \(identity.name) knows about you — "
                 + "its name and face, how you asked it to talk, and all "
                 + "\(memory.entries.count) "
                 + (memory.entries.count == 1 ? "memory" : "memories")
                 + ". One file for Next Notes to read back, one you can read yourself. "
                 + "It stays on this Mac.")
                .font(DS.Font.callout)
                .foregroundStyle(DS.Color.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            if routineCount > 0 {
                Toggle("Include your \(routineCount) "
                       + (routineCount == 1 ? "goal" : "goals"), isOn: $includeRoutines)
                if includeRoutines {
                    // Written down rather than packed up: a goal runs by itself, and a
                    // file should not be able to start something running on another Mac.
                    SettingsNote(text: "Goals are written down so you have a record of "
                                 + "them. Reading this file back doesn't start them again — "
                                 + "you set those up yourself.")
                }
            }

            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Save…", action: save)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    private func done(_ result: MemoryExporter.Result) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.l) {
            Text("Saved \(result.memoryCount) "
                 + (result.memoryCount == 1 ? "memory" : "memories")
                 + (result.routineCount > 0 ? " and \(result.routineCount) routines" : "")
                 + " to “\(result.folder.lastPathComponent)”.")
                .font(DS.Font.callout)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Button("Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([result.folder])
                }
                Spacer()
                Button("Done") { dismiss() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    private func save() {
        let panel = NSSavePanel()
        panel.title = MemoryDataControls.exportTitle
        panel.prompt = "Save"
        panel.nameFieldStringValue = MemoryExporter.suggestedName(assistant: identity.name)
        // A folder, so the readable copy and the one Next Notes reads back travel together.
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            saved = try MemoryExporter.export(to: url, includeRoutines: includeRoutines)
            error = nil
        } catch {
            self.error = "Couldn't write there: \(error.localizedDescription)"
        }
    }
}
