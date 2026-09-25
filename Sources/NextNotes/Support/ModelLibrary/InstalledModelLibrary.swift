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
    /// What the probe said about this file, once it has been asked. nil on a row written
    /// before the probe existed; such a row is probed lazily rather than treated as broken.
    var support: LlamaProbeResult?
    /// What the last real trial of this exact file found, or nil when it has never been
    /// tried. P0-02: `support` says the file opens; only `lastTrial` says it answers, and
    /// the Models tab gates "Use for agent turns" on the difference.
    var lastTrial: ModelTrialResult?

    init(
        id: String,
        displayName: String,
        fileURL: URL,
        parameterBillions: Double?,
        quantization: String?,
        bytes: Int64,
        isBuiltIn: Bool,
        support: LlamaProbeResult? = nil,
        lastTrial: ModelTrialResult? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.fileURL = fileURL
        self.parameterBillions = parameterBillions
        self.quantization = quantization
        self.bytes = bytes
        self.isBuiltIn = isBuiltIn
        self.support = support
        self.lastTrial = lastTrial
    }

    /// Hand-written on purpose: a new field must be `decodeIfPresent`, or every
    /// `library.json` row written before it existed fails to decode and vanishes from the
    /// list. `id`, `displayName` and `fileURL` stay required — a row without them is not a
    /// model this app could ever use.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        displayName = try container.decode(String.self, forKey: .displayName)
        fileURL = try container.decode(URL.self, forKey: .fileURL)
        parameterBillions = try container.decodeIfPresent(Double.self, forKey: .parameterBillions)
        quantization = try container.decodeIfPresent(String.self, forKey: .quantization)
        bytes = try container.decode(Int64.self, forKey: .bytes)
        isBuiltIn = try container.decode(Bool.self, forKey: .isBuiltIn)
        support = try container.decodeIfPresent(LlamaProbeResult.self, forKey: .support)
        lastTrial = try container.decodeIfPresent(ModelTrialResult.self, forKey: .lastTrial)
    }

    /// "2.6 GB" — the form the settings rows use.
    var displaySize: String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    /// A file that is one piece of a model — a vision projector or an MTP draft head —
    /// rather than a model. It cannot answer, so it is never adopted and never offered to a
    /// role; it is listed only so its space can be reclaimed. With no repo to compare
    /// against, the size line in `ModelFitEstimator` is what separates a head from a model
    /// with multi-token prediction merged into it.
    var isAuxiliary: Bool {
        ModelFitEstimator.isAuxiliaryGGUF(
            fileName: fileURL.lastPathComponent, bytes: bytes, comparedToLargestGGUF: nil)
    }

    /// True when this file can actually answer: the probe opened it, or it is the model the
    /// app ships with — that one is pinned by `NotesModels.spec` and needs no probe.
    var isRunnable: Bool { isBuiltIn || support?.verdict == .opens }

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
/// `activeAgentModelID` is the weight file the runtime loads. It is half of the choice:
/// the Agent role decides what answers, and re-asserts its own choice over this file on
/// every turn — so a file switch with the role still on Built-in flips back. It persists
/// in UserDefaults and falls back to the built-in whenever the chosen file has gone
/// missing, so a deleted model can never leave the app pointing at nothing.
@MainActor
@Observable
final class InstalledModelLibrary {
    /// The process-wide library.
    ///
    /// The adopter is the one thing a self-test changes here: a test injects a runtime it
    /// owns instead of the process runtime, and the harness's default is no adopter at all
    /// — so a test can never be handed whatever the owner of this Mac has selected.
    /// `--selftest-agent-answers` and `--selftest-llm-metal` are the two flags that read
    /// the real selection on purpose (read-only).
    static let shared = InstalledModelLibrary(
        defaults: sharedDefaults,
        runtimeAdopter: sharedRuntimeAdopter
    )

    /// The defaults `.shared` reads and writes.
    ///
    /// P0-11: under `SelfTest.isRunning` this is the per-process
    /// `UserDefaults(suiteName: "NextNotesSelfTest-<pid>")` in `SelfTestHarnessDefaults`,
    /// so a self-test that drives `.shared` cannot move the owner's `modelLibrary.*` keys.
    /// When `SelfTest.allowsSavedModelSelection` asked for the owner's real selection the
    /// suite was seeded with it — read-only; every write still lands in the suite. A real
    /// run keeps `.standard`.
    private static var sharedDefaults: UserDefaults {
        SelfTest.isRunning ? SelfTestHarnessDefaults.shared : .standard
    }

    /// The adopter the process-wide library gets. Nil under the harness unless the flag
    /// asked to read the real selection, so a test can never be handed whatever the owner
    /// of this Mac has selected.
    private static var sharedRuntimeAdopter: (@Sendable (InstalledLocalModel?) async -> Void)? {
        guard !SelfTest.isRunning || SelfTest.allowsSavedModelSelection else { return nil }
        return { await NotesModelRuntime.shared.useInstalledModel($0) }
    }

    /// The id of the model that ships with the app. `nonisolated`: a plain constant, and
    /// `canRemoveBuiltIn` below needs to read it without a main-actor hop.
    nonisolated static let builtInID = "built-in/gemma-4-e4b"

    private static let activeDefaultsKey = "modelLibrary.activeAgentModelID"

    private(set) var models: [InstalledLocalModel] = []

    /// The weight file the runtime loads — not, on its own, what answers.
    ///
    /// Setting this persists the file choice and hands the runtime the new weights. Two
    /// screens set it — the Models tab and the model picker in Settings ▸ Agent — and the
    /// Agent role still decides the turns: `ModelRoleStore.setChoice(.installedModel, for:
    /// .agent)` is what converges the two, and the Models tab prompts for it on "Use
    /// this one" rather than pretending the file is enough.
    var activeAgentModelID: String {
        didSet {
            guard oldValue != activeAgentModelID else { return }
            activeSelectionWrites += 1
            defaults.set(activeAgentModelID, forKey: Self.activeDefaultsKey)
            recordUse(activeAgentModelID)
            NotificationCenter.default.post(name: .installedModelLibraryActiveModelChanged, object: nil)
            adoptInRuntime()
        }
    }

    /// How many times `activeAgentModelID` has actually changed since this store was
    /// created.
    ///
    /// P0-02's post-download self-test reads it to prove the trial ran *before* the
    /// switch: a verify closure that sees the same count it captured before the call
    /// means nothing had been switched yet. Never read by production.
    private(set) var activeSelectionWrites = 0

    private static let lastUsedDefaultsKey = "modelLibrary.lastUsedAt"

    /// When each model was last made active, cheap to keep because it is only ever written
    /// on the same switch that already persists `activeAgentModelID` — no extra hook, no
    /// polling.
    private func recordUse(_ id: String) {
        var table = defaults.dictionary(forKey: Self.lastUsedDefaultsKey) as? [String: Double] ?? [:]
        table[id] = Date().timeIntervalSince1970
        defaults.set(table, forKey: Self.lastUsedDefaultsKey)
    }

    func lastUsedDate(for id: String) -> Date? {
        guard let table = defaults.dictionary(forKey: Self.lastUsedDefaultsKey) as? [String: Double],
              let seconds = table[id] else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }

    /// Tells the runtime which file to answer with next. It swaps immediately when nothing is
    /// running and waits for the work in flight when something is.
    ///
    /// Fire-and-forget on purpose: this is the store's own reaction to a selection change
    /// (the Models tab, the Agent picker), and nothing is waiting on it. A turn that needs
    /// the swap decided before it asks which provider answers calls the runtime's awaited
    /// `select(_:)` instead — which is what removed the race the second resolution used to
    /// lose.
    private func adoptInRuntime() {
        guard let runtimeAdopter else { return }
        let chosen = activeModel
        Task { await runtimeAdopter(chosen) }
    }

    /// Where the manifest of downloaded (non-built-in) models lives.
    private let manifestURL: URL

    /// Where the active selection and the last-used table are persisted. Injected so a
    /// self-test can drive a library without writing the user's own defaults.
    private let defaults: UserDefaults

    /// Hands a newly selected model to a runtime. Nil means "this store never touches a
    /// runtime" — the harness's default, and what a self-test passes when it wants the
    /// selection to be recorded without a model being swapped.
    private let runtimeAdopter: (@Sendable (InstalledLocalModel?) async -> Void)?

    init(
        manifestURL: URL? = nil,
        defaults: UserDefaults = .standard,
        runtimeAdopter: (@Sendable (InstalledLocalModel?) async -> Void)? = nil
    ) {
        self.manifestURL = manifestURL
            ?? ModelSpec.directory.appendingPathComponent("library.json")
        self.defaults = defaults
        self.runtimeAdopter = runtimeAdopter
        self.activeAgentModelID = defaults.string(forKey: Self.activeDefaultsKey)
            ?? Self.builtInID
        refresh()
    }

    // MARK: - Reading

    /// The model the agent should load, or nil when only the built-in is wanted.
    var activeModel: InstalledLocalModel? {
        usableModels.first { $0.id == activeAgentModelID }
    }

    /// True when there is a model on this Mac the app can answer with.
    ///
    /// The question every caller actually means. Asking `NotesModels.isDownloaded` instead
    /// says "is the *built-in* model here", which reads as "no model at all" to someone whose
    /// only model came from Hugging Face.
    var hasUsableModel: Bool { !usableModels.isEmpty }

    /// The installed files that can actually answer. A projector or a draft head is a real
    /// file on disk and stays in `models` so it can be deleted, but it is not a brain and
    /// must never be counted as one — and neither is a file the probe could not open. Such
    /// a row stays in `models` so it can be seen and deleted; it never reaches a role.
    var usableModels: [InstalledLocalModel] { models.filter { !$0.isAuxiliary && $0.isRunnable } }

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

    /// Rebuilds `models` from disk, and starts the lazy support probe for any row that has
    /// never been classified. Rows whose file has vanished are dropped rather than shown as
    /// broken: the user deleted it in Finder, and the app should agree.
    func refresh() {
        reloadFromDisk()
        // Off the main path on purpose: a probe opens a vocabulary, which is milliseconds,
        // but it is not something the UI should wait behind. `usableModels` simply leaves an
        // unprobed row out until the answer is in.
        Task { await refreshSupportVerdicts() }
    }

    private func reloadFromDisk() {
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

    // MARK: - Support probe

    /// Probes every row whose verdict is missing, was made by a different build of
    /// llama.cpp, or describes a different file, and persists the answers.
    ///
    /// Called lazily from `refresh()`, and awaited by the provider path before a turn, so a
    /// role can never be handed a file nobody has classified. The manifest is read again
    /// after the probes, because a download can finish while they run and a save built from
    /// the earlier read would drop it.
    func refreshSupportVerdicts() async {
        var probed: [String: LlamaProbeResult] = [:]
        for entry in loadManifest() where entry.fileIsPresent {
            if let support = entry.support,
               support.llamaBuildTag == LlamaArchitectures.buildTag,
               support.fileBytes == entry.bytes {
                continue
            }
            probed[entry.id] = await LlamaLoadProbe.probe(entry.fileURL)
        }
        guard !probed.isEmpty else { return }

        var manifest = loadManifest()
        var changed = false
        for index in manifest.indices {
            guard let result = probed[manifest[index].id] else { continue }
            manifest[index].support = result
            changed = true
        }
        guard changed else { return }
        saveManifest(manifest)
        reloadFromDisk()
    }

    // MARK: - Writing

    /// Probes one row when its verdict is missing, or was made by a different build of
    /// llama.cpp or describes a different file, and returns the row as it stands afterwards.
    ///
    /// The provider path awaits this before it decides, so a role is never handed a file
    /// nobody has classified — the lazy whole-list probe may not have reached it yet.
    @discardableResult
    func refreshSupportVerdictIfNeeded(_ model: InstalledLocalModel) async -> InstalledLocalModel {
        let current = self.model(withID: model.id) ?? model
        if let support = current.support,
           support.llamaBuildTag == LlamaArchitectures.buildTag,
           support.fileBytes == current.bytes {
            return current
        }
        let result = await LlamaLoadProbe.probe(current.fileURL)
        var manifest = loadManifest()
        guard let index = manifest.firstIndex(where: { $0.id == current.id }) else {
            // The built-in model has no manifest row of its own, and is runnable by
            // definition; there is nothing to record.
            return current
        }
        manifest[index].support = result
        saveManifest(manifest)
        reloadFromDisk()
        return self.model(withID: current.id) ?? current
    }

    /// Records a model that has just finished downloading and makes it visible everywhere.
    func add(_ model: InstalledLocalModel) {
        var manifest = loadManifest().filter { $0.id != model.id }
        manifest.append(model)
        saveManifest(manifest)
        refresh()
    }

    /// Records what a real trial of this file found, on its own manifest row, so "opened"
    /// and "answered" stay apart across launches.
    ///
    /// The built-in model has no manifest row of its own — `refresh()` synthesizes it —
    /// so there is nothing to rewrite for it; it is runnable by definition and no trial
    /// has to be recorded for it to be offered.
    func setLastTrial(_ result: ModelTrialResult?, for id: String) {
        var manifest = loadManifest()
        guard let index = manifest.firstIndex(where: { $0.id == id }) else { return }
        manifest[index].lastTrial = result
        saveManifest(manifest)
        reloadFromDisk()
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

    /// Falls back to the built-in whenever the selection points at something that is gone —
    /// or at a file that is only part of a model, which can never answer.
    ///
    /// A row that has not been probed yet is in limbo, not broken: the lazy probe runs on
    /// its own, and moving the selection before it answers would be a choice nobody made.
    private func normalizeActiveSelection() {
        let selectable = models.filter { !$0.isAuxiliary && ($0.isRunnable || $0.support == nil) }
        if selectable.contains(where: { $0.id == activeAgentModelID }) { return }
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
