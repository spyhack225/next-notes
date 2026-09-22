import Foundation
import Observation

/// Drives "Bring memory in" from the first choice to the receipt.
///
/// One object so the sheet stays a view: every decision that is not a tap lives here, and
/// the self-test drives the same object with a scripted model and a temporary store.
@MainActor
@Observable
final class MemoryPortabilityController {
    enum Stage: Equatable {
        /// From a file, or from another assistant?
        case start
        /// Guided copy-and-paste for one assistant.
        case paste
        /// Reading, distilling — the model may be thinking.
        case working(String)
        /// One of our own exports: replace everything, or add to it?
        case restore
        /// The list with the checkboxes. Nothing is saved until this is confirmed.
        case review
        /// Saved, with an Undo.
        case done

        /// Whether something is running behind the spinner.
        var isWorking: Bool {
            if case .working = self { return true }
            return false
        }
    }

    // MARK: - State

    private(set) var stage: Stage = .start
    var source: MemoryImportSource = .other
    var pastedText = ""
    private(set) var content: MemoryImportContent?
    var plan = MemoryImportPlan(origin: "")
    var restoreMode: NextMemory.RestoreMode = .merge
    /// A full restore also puts back the name, the avatar and the soul. Off means memories only.
    var restoreIdentityAndSoul = true
    private(set) var receipt: NextMemory.ImportReceipt?
    private(set) var error: String?
    /// Where the copy of the old list was written before a replace threw it away.
    private(set) var backupFolder: URL?
    /// Which route this import took, so "that had nothing in it" goes back to the step the
    /// person can change rather than to the paste box they never opened.
    private var cameFromFile = false

    /// The step that is running, so *Start over* can stop it rather than let it finish into
    /// a sheet the person has left. Reading a zip and asking a 4B model can take a minute.
    @ObservationIgnored private var work: Task<Void, Never>?
    /// Bumped by every new step and by `reset`. Work that resumes on an old number has been
    /// abandoned: it drops its result instead of pushing the sheet back to a step nobody is
    /// on any more.
    @ObservationIgnored private var generation = 0

    private let memory: NextMemory
    private let identity: AgentIdentityStore
    private let persona: PersonaStore
    /// Nil asks for whatever this Mac has. The self-test passes a scripted model, or none.
    private let modelProvider: @Sendable () async -> (any MemoryImportModel)?

    init(
        memory: NextMemory = .shared,
        identity: AgentIdentityStore = .shared,
        persona: PersonaStore = .shared,
        model: (@Sendable () async -> (any MemoryImportModel)?)? = nil
    ) {
        self.memory = memory
        self.identity = identity
        self.persona = persona
        modelProvider = model ?? { await MemoryPortabilityController.liveModel() }
    }

    /// The model that rewrites imported notes.
    ///
    /// Apple's model first: it is already on the Mac, it answers in seconds, and this runs
    /// while someone is watching a sheet. Local model next, which is worth its load time here
    /// because the person asked for this and can see it happening — unlike the background
    /// memory review, which must never pull gigabytes in behind a voice reply. Neither
    /// available is not a failure: `MemoryFactRewriter` does the same job with rules.
    static func liveModel() async -> (any MemoryImportModel)? {
        let apple = LLMProviders.make(.appleFoundation)
        if await apple.unavailableReason == nil {
            return ProviderMemoryImportModel(provider: apple)
        }
        // Whichever local model is selected, not only the built-in one. The provider's own
        // availability check below is the accurate test; a built-in-only guard in front of it
        // turned a Mac with a model from the library into a Mac with none.
        guard InstalledModelLibrary.shared.hasUsableModel else { return nil }
        let local = LLMProviders.make(.gemma4E4B)
        return await local.unavailableReason == nil ? ProviderMemoryImportModel(provider: local) : nil
    }

    // MARK: - Steps

    func reset() {
        // Cancelled, not forgotten: the reference stays so the abandoned run can still be
        // waited on, and the next `start` replaces it.
        work?.cancel()
        generation += 1
        stage = .start
        pastedText = ""
        content = nil
        plan = MemoryImportPlan(origin: "")
        receipt = nil
        error = nil
        backupFolder = nil
        restoreMode = .merge
        restoreIdentityAndSoul = true
        cameFromFile = false
    }

    func choosePaste(_ source: MemoryImportSource) {
        work?.cancel()
        generation += 1
        self.source = source
        pastedText = ""
        error = nil
        cameFromFile = false
        stage = .paste
    }

    /// Starts one step, replacing whatever was running, and hands it its own number.
    private func start(_ body: @escaping @MainActor @Sendable (Int) async -> Void) {
        work?.cancel()
        generation += 1
        let run = generation
        work = Task { @MainActor in await body(run) }
    }

    /// Whether the run that is asking is still the one the sheet is showing.
    private func isCurrent(_ run: Int) -> Bool { run == generation && !Task.isCancelled }

    /// Waits for the running step. For the self-test; nothing in the UI awaits it.
    func finishWork() async {
        await work?.value
    }

    /// A file, a folder or a zip the person picked.
    ///
    /// Every heavy part of this runs off the main actor. Reading can mean spawning `unzip`,
    /// walking four hundred files and parsing a 64 MB `conversations.json`, and all of it used
    /// to happen inline on the main thread — which meant the spinner this sets one line above
    /// could never draw, and the dictation HUD and the hotkeys froze with it.
    func read(fileAt url: URL) {
        error = nil
        cameFromFile = true
        stage = .working("Reading \(url.lastPathComponent)…")
        start { [self] run in
            do {
                let content = try await Task.detached(priority: .userInitiated) {
                    try MemoryImportReader.read(fileAt: url)
                }.value
                guard isCurrent(run) else { return }
                self.content = content
                if content.isOurOwnExport {
                    stage = .restore
                } else {
                    await distil(content, run: run)
                }
            } catch {
                guard isCurrent(run) else { return }
                self.error = error.localizedDescription
                stage = .start
            }
        }
    }

    /// The block pasted back from another assistant.
    func readPastedText() {
        error = nil
        let text = pastedText
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            error = "Paste what \(source.displayName) answered first."
            return
        }
        let content = MemoryImportReader.read(pasted: text, from: source)
        self.content = content
        start { [self] run in await distil(content, run: run) }
    }

    /// Candidates → model (or rules) → screened proposals.
    ///
    /// Each resume checks its run number first. Without that, *Start over* during a minute of
    /// model work left the old run to finish and drop the person back into the review list for
    /// the import they had just walked away from.
    private func distil(_ content: MemoryImportContent, run: Int) async {
        stage = .working("Reading what's in there…")
        let text = content.text
        let candidates = await Task.detached(priority: .userInitiated) {
            MemoryCandidateExtractor.candidates(in: text)
        }.value
        guard isCurrent(run) else { return }
        guard !candidates.isEmpty else {
            error = "There was nothing that looked like a memory in that."
            stage = cameFromFile ? .start : .paste
            return
        }
        let model = await modelProvider()
        guard isCurrent(run) else { return }
        if model != nil {
            stage = .working("Reading \(candidates.count) lines on this Mac…")
        }
        let distilled = await MemoryImportDistiller.distil(candidates, model: model)
        guard isCurrent(run) else { return }
        var note = content.note
        if let failure = distilled.modelFailure {
            note = [note, "The model on this Mac couldn't read it (\(failure)), so these were "
                    + "worked out from the wording. Check them."].compactMap { $0 }.joined(separator: " ")
        }
        let facts = distilled.facts
        let existing = memory.entries
        let origin = content.origin
        let label = distilled.modelLabel
        let prepared = note
        let plan = await Task.detached(priority: .userInitiated) {
            MemoryImportPlanner.plan(facts: facts, existing: existing, origin: origin,
                                     modelLabel: label, note: prepared)
        }.value
        guard isCurrent(run) else { return }
        self.plan = plan
        if plan.isEmpty {
            error = plan.dropped.isEmpty
                ? "There was nothing worth remembering in that."
                : "Nothing in that could be kept — see the list below for why."
        }
        stage = .review
    }

    // MARK: - Saving

    /// Writes the ticked facts.
    func saveReviewed() {
        let facts = plan.selected.map { (kind: $0.kind, text: $0.text) }
        guard !facts.isEmpty else {
            error = "Tick at least one memory to keep."
            return
        }
        let receipt = memory.applyImport(facts, from: plan.origin)
        self.receipt = receipt
        error = receipt.saved.isEmpty && !receipt.notSaved.isEmpty
            ? receipt.notSaved.first?.reason : nil
        stage = .done
        Log.agent.info("""
            memory import from \(self.plan.origin, privacy: .public): \
            saved \(receipt.saved.count) already known \(receipt.alreadyKnown.count) \
            not saved \(receipt.notSaved.count)
            """)
    }

    /// How many memories a replace would throw away, for the sentence on the warning.
    var currentMemoryCount: Int { memory.entries.count }

    /// Restores one of our own exports.
    func restorePackage() {
        guard let package = content?.package else { return }
        if restoreMode == .replace { backupFolder = backUpCurrentMemory() }
        do {
            let receipt = try memory.restore(package, mode: restoreMode)
            if restoreIdentityAndSoul, restoreMode == .replace {
                identity.setDisplayName(package.assistant.name)
                if let avatar = package.assistant.avatar { identity.setAvatar(avatar) }
                if let soul = package.assistant.soul, !soul.isEmpty { try? persona.save(soul) }
            }
            self.receipt = receipt
            error = nil
            stage = .done
            Log.agent.info("""
                memory restore (\(self.restoreMode.rawValue, privacy: .public)): \
                \(receipt.saved.count) memories
                """)
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Writes what the assistant remembers now beside `next-memory.json`, before a replace
    /// throws it away.
    ///
    /// *Replace everything* is the one action in this sheet that has no Undo — the old list
    /// is gone, ids and history and all. So it stops being irreversible instead: the copy is
    /// an ordinary export, and the person brings it back through the same door they used to
    /// get here. Silent on failure, because a backup that could not be written is a reason to
    /// warn harder, which the confirmation already does, not a reason to block the restore
    /// they asked for.
    /// - Returns: the folder, when one was written.
    private func backUpCurrentMemory() -> URL? {
        guard let directory = memory.fileURL?.deletingLastPathComponent() else { return nil }
        let stamp = DateFormatter()
        stamp.dateFormat = "yyyy-MM-dd HH-mm-ss"
        let backups = directory.appendingPathComponent(Self.backupFolderName, isDirectory: true)
        let folder = backups.appendingPathComponent("Memory before restore \(stamp.string(from: Date()))",
                                                    isDirectory: true)
        let package = MemoryExporter.package(memory: memory, identity: identity, persona: persona,
                                             includeRoutines: false)
        guard (try? MemoryExporter.write(package, to: folder)) != nil else { return nil }
        pruneBackups(in: backups)
        return folder
    }

    static let backupFolderName = "Memory backups"
    /// How many copies are kept. Enough to undo a mistake, not enough to become a second
    /// copy of the memory file growing quietly in Application Support.
    static let backupsKept = 3

    private func pruneBackups(in folder: URL) {
        let manager = FileManager.default
        guard let found = try? manager.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil,
                                                           options: [.skipsHiddenFiles]) else { return }
        // The names carry a sortable timestamp, so oldest first is alphabetical.
        let sorted = found.sorted { $0.lastPathComponent < $1.lastPathComponent }
        for old in sorted.dropLast(Self.backupsKept) { try? manager.removeItem(at: old) }
    }

    /// Takes the whole import back.
    func undo() {
        guard let receipt else { return }
        let removed = memory.undoImport(batchID: receipt.batchID)
        self.receipt = nil
        error = nil
        stage = .start
        Log.agent.info("memory import undone: \(removed) memories removed")
    }

    /// Whether Undo can still do anything — a fact forgotten by hand meanwhile does not
    /// come back, and a restore is not a batch.
    var undoableCount: Int {
        guard let receipt else { return 0 }
        return memory.importBatchCount(receipt.batchID)
    }

    // MARK: - Export

    /// Writes the package. The save panel has already chosen the folder.
    func export(to folder: URL, includeRoutines: Bool) -> MemoryExporter.Result? {
        do {
            let result = try MemoryExporter.export(to: folder, includeRoutines: includeRoutines)
            error = nil
            Log.agent.info("""
                memory exported: \(result.memoryCount) memories, \
                \(result.routineCount) routines
                """)
            return result
        } catch {
            self.error = "Couldn't write there: \(error.localizedDescription)"
            return nil
        }
    }
}
