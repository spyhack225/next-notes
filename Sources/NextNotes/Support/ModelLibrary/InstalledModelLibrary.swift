import Foundation
import Observation

/// One model file that is present on this Mac right now.
///
/// The built-in model appears here the moment it finishes downloading, with the same
/// shape as anything fetched from Hugging Face, so the rest of the app never has to ask
/// which kind of model it is holding.
struct InstalledLocalModel: Identifiable, Codable, Sendable, Hashable {
    /// Stable across launches. For the built-in model this is `InstalledModelLibrary.builtInID`;
    /// for a downloaded one it is the Hugging Face `owner/repo/file` path.
    let id: String
    let displayName: String
    let fileURL: URL
    let parameterBillions: Double?
    let quantization: String?
    let bytes: Int64
    let isBuiltIn: Bool

    init(
        id: String,
        displayName: String,
        fileURL: URL,
        parameterBillions: Double?,
        quantization: String?,
        bytes: Int64,
        isBuiltIn: Bool
    ) {
        self.id = id
        self.displayName = displayName
        self.fileURL = fileURL
        self.parameterBillions = parameterBillions
        self.quantization = quantization
        self.bytes = bytes
        self.isBuiltIn = isBuiltIn
    }

    /// "2.6 GB" — the form the settings rows use.
    var displaySize: String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    /// Present and the expected length. A half-finished copy that was moved into place
    /// would otherwise look ready.
    ///
    /// Read through `FileManager`, not `URL.resourceValues`: this model holds one `URL`
    /// value for the life of the app, and a `URL` answers a second `resourceValues` call
    /// from its own cache — so a file deleted after the first check would go on looking
    /// present until the next launch.
    var fileIsPresent: Bool {
        ModelDownloader.fileSize(at: fileURL) == bytes
    }
}

/// Everything the app knows about the models sitting in Application Support.
///
/// Two stores in one, deliberately: a JSON manifest of the models fetched from Hugging Face,
/// and a synthesized entry for the built-in model, which is downloaded by
/// `NotesModels.download` and has no manifest row of its own. Callers read one list.
///
/// `activeAgentModelID` is the model the agent and the notes writer should use. It persists in
/// UserDefaults and falls back to the built-in whenever the chosen file has gone missing, so a
/// deleted model can never leave the app pointing at nothing.
@MainActor
@Observable
final class InstalledModelLibrary {
    static let shared = InstalledModelLibrary()

    /// The id of the model that ships with the app. `nonisolated`: a plain constant, and
    /// `canRemoveBuiltIn` below needs to read it without a main-actor hop.
    nonisolated static let builtInID = "built-in/gemma-4-e4b"

    private static let activeDefaultsKey = "modelLibrary.activeAgentModelID"

    private(set) var models: [InstalledLocalModel] = []

    /// The model the agent answers with.
    ///
    /// Setting this is the *whole* act of choosing a model: it persists the choice and hands
    /// the runtime the new file. Two screens set it — the Models tab and the model picker in
    /// Settings ▸ Agent — and when the swap lived in one of those screens instead of here,
    /// the other one changed the stored id and the next answer still came from the old
    /// weights. One setter, one behaviour.
    var activeAgentModelID: String {
        didSet {
            guard oldValue != activeAgentModelID else { return }
            UserDefaults.standard.set(activeAgentModelID, forKey: Self.activeDefaultsKey)
            recordUse(activeAgentModelID)
            NotificationCenter.default.post(name: .installedModelLibraryActiveModelChanged, object: nil)
            adoptInRuntime()
        }
    }

    private static let lastUsedDefaultsKey = "modelLibrary.lastUsedAt"

    /// When each model was last made active, cheap to keep because it is only ever written
    /// on the same switch that already persists `activeAgentModelID` — no extra hook, no
    /// polling.
    private func recordUse(_ id: String) {
        var table = UserDefaults.standard.dictionary(forKey: Self.lastUsedDefaultsKey) as? [String: Double] ?? [:]
        table[id] = Date().timeIntervalSince1970
        UserDefaults.standard.set(table, forKey: Self.lastUsedDefaultsKey)
    }

    func lastUsedDate(for id: String) -> Date? {
        guard let table = UserDefaults.standard.dictionary(forKey: Self.lastUsedDefaultsKey) as? [String: Double],
              let seconds = table[id] else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }

    /// Tells the runtime which file to answer with next. It swaps immediately when nothing is
    /// running and waits for the work in flight when something is.
    private func adoptInRuntime() {
        // A self-test must not have its model swapped out from under it by whatever the
        // person who owns this Mac happens to have chosen in the UI.
        guard !SelfTest.isRunning else { return }
        let chosen = activeModel
        Task { await NotesModelRuntime.shared.useInstalledModel(chosen) }
    }

    /// Where the manifest of downloaded (non-built-in) models lives.
    private let manifestURL: URL

    init(manifestURL: URL? = nil) {
        self.manifestURL = manifestURL
            ?? ModelSpec.directory.appendingPathComponent("library.json")
        self.activeAgentModelID = UserDefaults.standard.string(forKey: Self.activeDefaultsKey)
            ?? Self.builtInID
        refresh()
    }

    // MARK: - Reading

    /// The model the agent should load, or nil when only the built-in is wanted.
    var activeModel: InstalledLocalModel? {
        models.first { $0.id == activeAgentModelID }
    }

    /// True when there is a model on this Mac the app can answer with.
    ///
    /// The question every caller actually means. Asking `NotesModels.isDownloaded` instead
    /// says "is the *built-in* model here", which reads as "no model at all" to someone whose
    /// only model came from Hugging Face.
    var hasUsableModel: Bool { !models.isEmpty }

    var builtIn: InstalledLocalModel? {
        models.first { $0.isBuiltIn }
    }

    var downloaded: [InstalledLocalModel] {
        models.filter { !$0.isBuiltIn }
    }

    func model(withID id: String) -> InstalledLocalModel? {
        models.first { $0.id == id }
    }

    /// Total bytes every installed brain is using right now.
    var totalBytes: Int64 { models.map(\.bytes).reduce(0, +) }

    /// Whether `model` may be removed.
    ///
    /// A downloaded model may always go — the agent falls back to whatever else is
    /// installed, and to the built-in one if that is all that is left. The built-in model is
    /// different: it is the one file every fallback in the app assumes exists, so it may only
    /// go once a *different* brain is already the one in use — never the one that is loaded
    /// right now, and never when it would leave the app with nothing to answer with.
    func canRemove(_ model: InstalledLocalModel) -> Bool {
        guard model.isBuiltIn else { return true }
        return Self.canRemoveBuiltIn(activeID: activeAgentModelID, installedIDs: Set(models.map(\.id)))
    }

    /// The rule above, with no store, no disk and no `self` — so a self-test can drive every
    /// case of it directly instead of standing up a real installed-model library to prove a
    /// three-line guard. `nonisolated` for the same reason: nothing here touches actor state.
    nonisolated static func canRemoveBuiltIn(activeID: String, installedIDs: Set<String>) -> Bool {
        activeID != builtInID && installedIDs.contains(activeID)
    }

    /// Rebuilds `models` from disk. Rows whose file has vanished are dropped rather than
    /// shown as broken: the user deleted it in Finder, and the app should agree.
    func refresh() {
        var found: [InstalledLocalModel] = []

        if NotesModels.isDownloaded {
            found.append(
                InstalledLocalModel(
                    id: Self.builtInID,
                    displayName: NotesModels.spec.displayName,
                    fileURL: NotesModels.fileURL,
                    parameterBillions: 4,
                    quantization: "Q4_K_M",
                    bytes: NotesModels.spec.expectedBytes,
                    isBuiltIn: true
                )
            )
        }

        for entry in loadManifest() where entry.fileIsPresent {
            guard !found.contains(where: { $0.id == entry.id }) else { continue }
            found.append(entry)
        }

        models = found
        normalizeActiveSelection()
    }

    // MARK: - Writing

    /// Records a model that has just finished downloading and makes it visible everywhere.
    func add(_ model: InstalledLocalModel) {
        var manifest = loadManifest().filter { $0.id != model.id }
        manifest.append(model)
        saveManifest(manifest)
        refresh()
    }

    /// Removes the file and, for a downloaded model, the manifest row.
    ///
    /// The built-in model has no manifest row — `refresh()` synthesizes it from
    /// `NotesModels.isDownloaded` — so removing it is only ever a file delete; `canRemove`
    /// above is what keeps that safe. `LocalModelStore.prepareNotesModel()` downloads it
    /// again exactly the way it did the first time, so this is never a one-way door.
    @discardableResult
    func remove(id: String) -> Bool {
        guard let model = model(withID: id), canRemove(model) else { return false }
        try? FileManager.default.removeItem(at: model.fileURL)
        if !model.isBuiltIn {
            saveManifest(loadManifest().filter { $0.id != id })
        }
        refresh()
        return true
    }

    /// Falls back to the built-in whenever the selection points at something that is gone.
    private func normalizeActiveSelection() {
        if models.contains(where: { $0.id == activeAgentModelID }) { return }
        if activeAgentModelID != Self.builtInID {
            activeAgentModelID = Self.builtInID
        }
    }

    // MARK: - Manifest

    private func loadManifest() -> [InstalledLocalModel] {
        guard let data = try? Data(contentsOf: manifestURL) else { return [] }
        return (try? JSONDecoder().decode([InstalledLocalModel].self, from: data)) ?? []
    }

    private func saveManifest(_ entries: [InstalledLocalModel]) {
        do {
            try FileManager.default.createDirectory(
                at: manifestURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(entries).write(to: manifestURL, options: .atomic)
        } catch {
            Log.app.error("Could not save the model library: \(error.localizedDescription, privacy: .public)")
        }
    }
}

extension Notification.Name {
    /// Posted when the user picks a different model for the agent to use.
    static let installedModelLibraryActiveModelChanged =
        Notification.Name("InstalledModelLibraryActiveModelChanged")
}
