import SwiftUI

/// "Free up space…" from Settings ▸ Models ▸ Your assistant's brain.
///
/// Everything here is a brain that is *not* the one in use, plus any stopped download —
/// largest first, so the biggest piece of reclaimable space leads. Checking a row is not a
/// delete; nothing happens until "Free up space" is pressed once, over everything checked.
struct ModelSpaceManagerSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var library = ModelLibraryStore.shared
    @State private var installed = InstalledModelLibrary.shared
    @State private var selectedModelIDs: Set<String> = []
    @State private var selectedPartialIDs: Set<String> = []

    private var removable: [InstalledLocalModel] {
        installed.models
            .filter { installed.canRemove($0) && $0.id != installed.activeAgentModelID }
            .sorted { $0.bytes > $1.bytes }
    }

    private var partials: [PartialModelDownload] {
        library.partialDownloads()
    }

    private var totalSelectedBytes: Int64 {
        removable.filter { selectedModelIDs.contains($0.id) }.map(\.bytes).reduce(0, +)
            + partials.filter { selectedPartialIDs.contains($0.id) }.map(\.bytes).reduce(0, +)
    }

    private var hasSelection: Bool {
        !selectedModelIDs.isEmpty || !selectedPartialIDs.isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.m) {
            Text("Free up space")
                .font(DS.Font.title3)
            Text("Everything below is not the brain in use right now, or a download that "
                 + "never finished. Removing one frees its space; a brain can be downloaded "
                 + "again any time.")
                .font(DS.Font.caption)
                .foregroundStyle(DS.Color.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            if removable.isEmpty, partials.isEmpty {
                Text("Nothing to free up — only the brain in use is on this Mac.")
                    .font(DS.Font.callout)
                    .foregroundStyle(DS.Color.textSecondary)
                    .padding(.vertical, DS.Space.m)
            } else {
                List {
                    ForEach(removable) { model in modelRow(model) }
                    ForEach(partials) { partial in partialRow(partial) }
                }
                .frame(minHeight: 220, maxHeight: 320)
            }

            HStack {
                Text(hasSelection
                     ? "Frees \(Self.bytesText(totalSelectedBytes))"
                     : "Nothing selected")
                    .font(DS.Font.caption)
                    .foregroundStyle(DS.Color.textSecondary)
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Free up space") {
                    freeSelected()
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!hasSelection)
            }
        }
        .padding(DS.Space.xl)
        .frame(width: DS.Size.sheetWidth)
    }

    private func modelRow(_ model: InstalledLocalModel) -> some View {
        Toggle(isOn: Binding(
            get: { selectedModelIDs.contains(model.id) },
            set: { isOn in
                if isOn { selectedModelIDs.insert(model.id) } else { selectedModelIDs.remove(model.id) }
            }
        )) {
            VStack(alignment: .leading, spacing: DS.Space.xxs) {
                Text(model.displayName)
                    .font(DS.Font.callout)
                Text(model.displaySize)
                    .font(DS.Font.caption)
                    .foregroundStyle(DS.Color.textSecondary)
            }
        }
        .toggleStyle(.checkbox)
    }

    private func partialRow(_ partial: PartialModelDownload) -> some View {
        Toggle(isOn: Binding(
            get: { selectedPartialIDs.contains(partial.id) },
            set: { isOn in
                if isOn { selectedPartialIDs.insert(partial.id) } else { selectedPartialIDs.remove(partial.id) }
            }
        )) {
            VStack(alignment: .leading, spacing: DS.Space.xxs) {
                Text(partial.displayName)
                    .font(DS.Font.callout)
                Text("Paused · \(Self.bytesText(partial.bytes)) so far")
                    .font(DS.Font.caption)
                    .foregroundStyle(DS.Color.textSecondary)
            }
        }
        .toggleStyle(.checkbox)
    }

    private func freeSelected() {
        for model in removable where selectedModelIDs.contains(model.id) {
            installed.remove(id: model.id)
        }
        for partial in partials where selectedPartialIDs.contains(partial.id) {
            library.discardPartial(partial)
        }
        library.refreshHardware()
    }

    private static func bytesText(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
