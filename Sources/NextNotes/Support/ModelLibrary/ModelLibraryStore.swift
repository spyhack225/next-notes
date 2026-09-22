import Foundation
import Observation

/// One row in the browse list: a Hugging Face repository, sized and judged for this Mac.
struct ModelListing: Identifiable, Sendable, Equatable {
    let model: HuggingFaceModel
    /// What the download will probably weigh, before the repo's file list has been read.
    let estimatedBytes: Int64
    let fit: ModelFitEstimator.Fit

    var id: String { model.id }
}

/// A download in flight, or the reason one stopped.
enum ModelDownloadState: Sendable, Equatable {
    case checking
    case downloading(completed: Int64, total: Int64)
    case verifying
    case finished
    case failed(String)

    var fraction: Double {
        if case .downloading(let completed, let total) = self, total > 0 {
            return min(1, Double(completed) / Double(total))
        }
        return 0
    }

    /// Plain-language status under the progress bar.
    var sentence: String {
        switch self {
        case .checking: "Getting ready…"
        case .downloading(let completed, let total):
            total > 0
                ? "\(ByteCountFormatter.string(fromByteCount: completed, countStyle: .file)) of "
                    + ByteCountFormatter.string(fromByteCount: total, countStyle: .file)
                : ByteCountFormatter.string(fromByteCount: completed, countStyle: .file)
        case .verifying: "Checking the file…"
        case .finished: "Ready to use"
        case .failed(let message): message
        }
    }

    var isActive: Bool {
        switch self {
        case .checking, .downloading, .verifying: true
        case .finished, .failed: false
        }
    }
}

/// What the app needs from the user before it can fetch a particular model.
enum ModelAccessRequest: Sendable, Equatable {
    /// The makers want their terms accepted on the model's own page.
    case termsOnModelPage(repoID: String, pageURL: URL)
    /// Hugging Face wants a signed-in account.
    case accessKey(repoID: String, wasRejected: Bool)
}

/// One `.part` file sitting in the Models folder: a download that was stopped, by a press of
/// Stop or by the app quitting, before it finished.
///
/// There is no persisted record of which Hugging Face repository a `.part` file came from —
/// only its own file name, which `installedFileName(model:file:)` already writes as
/// `<owner>--<file>`. That is enough to show a person what it probably is and how much of it
/// arrived; a real resume is "download that model again", which lands on the same path and
/// picks the transfer up where it stopped, because `ModelDownloader.download` always resumes
/// from whatever is already in a file's `.part` sibling.
struct PartialModelDownload: Identifiable, Equatable, Sendable {
    let fileName: String
    let bytes: Int64
    var id: String { fileName }

    var displayName: String {
        var name = fileName
        if name.hasSuffix(".part") { name.removeLast(5) }
        return name.replacingOccurrences(of: "--", with: " / ")
    }
}

/// The Models tab's brain: what this Mac is, what is worth running on it, and what is
/// currently being fetched.
///
/// A feature-local store rather than another handful of properties on `Settings`: none of
/// this is a preference, most of it is a cache of something the network said a minute ago,
/// and the installed list already has its own home in `InstalledModelLibrary`.
@MainActor
@Observable
final class ModelLibraryStore {
    static let shared = ModelLibraryStore()

    /// What happens after a new brain finishes downloading, when one was already in use.
    ///
    /// The default is the one that cannot surprise anyone: use the new one, keep the old one
    /// on disk. Freeing space is a decision with a cost — a model the user might want back —
    /// so it needs its own, explicit choice, never a side effect of asking for something new.
    enum PostDownloadPolicy: String, CaseIterable, Identifiable, Codable, Sendable {
        case switchKeepOld
        case switchDeleteOld
        case downloadOnly

        var id: String { rawValue }

        var title: String {
            switch self {
            case .switchKeepOld: "Start using it, keep the old one"
            case .switchDeleteOld: "Start using it, delete the old one"
            case .downloadOnly: "Just download it, I'll switch myself"
            }
        }

        var sentence: String {
            switch self {
            case .switchKeepOld:
                "Next Notes will switch to the new one once it opens, and leave the old one "
                    + "on this Mac."
            case .switchDeleteOld:
                "Next Notes will switch to the new one once it opens, then remove the old "
                    + "one to free up space."
            case .downloadOnly:
                "Next Notes will only download it. Use \u{201c}Use this one\u{201d} below when "
                    + "you're ready to switch."
            }
        }
    }

    private static let policyDefaultsKey = "modelLibrary.postDownloadPolicy"

    /// Persisted, not another property on `Settings`: it belongs to this feature alone, the
    /// same reasoning `InstalledModelLibrary.activeAgentModelID` already follows.
    var postDownloadPolicy: PostDownloadPolicy {
        didSet {
            guard oldValue != postDownloadPolicy else { return }
            UserDefaults.standard.set(postDownloadPolicy.rawValue, forKey: Self.policyDefaultsKey)
        }
    }

    private(set) var hardware: HardwareProfile

    /// Models worth suggesting on this particular Mac, best fit first.
    private(set) var recommended: [ModelListing] = []
    private(set) var isLoadingRecommended = false

    private(set) var searchResults: [ModelListing] = []
    private(set) var isSearching = false
    private(set) var nextSearchPage: URL?
    var searchText = ""

    /// Anything that went wrong, already in plain language.
    private(set) var problem: String?

    /// Keyed by repository id.
    private(set) var downloads: [String: ModelDownloadState] = [:]

    /// Set when a poor verdict needs a "Download anyway" confirmation.
    var pendingConfirmation: PendingDownload?
    /// Set when Hugging Face needs terms accepted or a key pasted.
    var accessRequest: ModelAccessRequest?

    private(set) var hasAccessKey = false
    private(set) var accountName: String?

    /// The repo and file a confirmation sheet is about.
    struct PendingDownload: Identifiable, Sendable, Equatable {
        let model: HuggingFaceModel
        let file: HuggingFaceRepoFile
        let details: HuggingFaceModelDetails
        let fit: ModelFitEstimator.Fit
        /// What will happen once this download finishes. Starts as the persisted default and
        /// is only ever changed for this one download — answering "not now" in the sheet
        /// below never rewrites what every future download does.
        var policy: PostDownloadPolicy
        /// Free space after this download would fall under this app's own reserve twice
        /// over — the point at which the sheet should say so and lean the person toward
        /// deleting the old one, without ever choosing it for them.
        let recommendsDeletingOld: Bool
        /// True only when the *verdict* is why the sheet appeared — a poor fit that the
        /// downloader's own disk reserve would otherwise refuse. A sheet shown only because a
        /// brain is being replaced must not also waive that reserve.
        var bypassesDiskReserve: Bool
        var id: String { model.id + "/" + file.path }
    }

    @ObservationIgnored private var tasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var searchTask: Task<Void, Never>?

    private init() {
        hardware = HardwareProfile.current()
        postDownloadPolicy = UserDefaults.standard.string(forKey: Self.policyDefaultsKey)
            .flatMap(PostDownloadPolicy.init(rawValue:)) ?? .switchKeepOld
    }

    // MARK: - This Mac

    /// Free disk and thermal state move; everything else does not. Called when the tab
    /// appears and after every download.
    func refreshHardware() {
        hardware = HardwareProfile.current()
    }

    func fit(weightBytes: Int64, parameterBillions: Double?) -> ModelFitEstimator.Fit {
        ModelFitEstimator.fit(
            weightBytes: weightBytes,
            parameterBillions: parameterBillions,
            contextTokens: ModelFitEstimator.typicalContextTokens,
            hardware: hardware
        )
    }

    /// The fit of a model already on disk, for the installed list.
    func fit(for installed: InstalledLocalModel) -> ModelFitEstimator.Fit {
        fit(weightBytes: installed.bytes, parameterBillions: installed.parameterBillions)
    }

    // MARK: - Access key

    func refreshAccessKey() async {
        guard !SelfTest.isRunning else { return }
        hasAccessKey = await HuggingFaceAccessStore.hasKeyAsync()
    }

    /// Saves a key only once the Hub has confirmed it. A key that is silently wrong is worse
    /// than no key: every later failure looks like a network problem.
    func saveAccessKey(_ value: String) async -> Bool {
        do {
            let name = try await HuggingFaceClient.validate(token: value)
            try await HuggingFaceAccessStore.saveAsync(value)
            HuggingFaceAccessStore.invalidateCache()
            hasAccessKey = true
            accountName = name
            problem = nil
            accessRequest = nil
            return true
        } catch {
            problem = plainMessage(for: error)
            return false
        }
    }

    func removeAccessKey() async {
        try? await HuggingFaceAccessStore.clearAsync()
        HuggingFaceAccessStore.invalidateCache()
        hasAccessKey = false
        accountName = nil
    }

    private func token() async -> String? {
        guard !SelfTest.isRunning else { return nil }
        return await HuggingFaceAccessStore.keyAsync()
    }

    // MARK: - Shelves

    /// The "Recommended for this Mac" shelf.
    ///
    /// Built from the Hub's most-downloaded GGUF repositories rather than from a list baked
    /// into the app, then filtered down to the ones that actually run well here. A hard-coded
    /// shelf goes stale the week after a release and cannot know what machine it is on.
    func loadRecommended(force: Bool = false) async {
        guard force || (recommended.isEmpty && !isLoadingRecommended) else { return }
        isLoadingRecommended = true
        defer { isLoadingRecommended = false }
        do {
            let page = try await HuggingFaceClient.search(
                sort: .downloads, limit: 100, token: await token())
            recommended = pickRecommended(from: page.models)
            problem = nil
        } catch {
            problem = plainMessage(for: error)
        }
    }

    /// Keeps one entry per model family, best verdict first, and only what this Mac can run.
    private func pickRecommended(from models: [HuggingFaceModel]) -> [ModelListing] {
        var seenFamilies = Set<String>()
        var chosen: [ModelListing] = []
        for listing in models.compactMap(listing(for:)) {
            guard !listing.model.isGated else { continue }
            guard listing.fit.verdict == .runsGreat || listing.fit.verdict == .runsWell else { continue }
            guard isGeneralPurpose(listing.model) else { continue }
            let family = familyKey(listing.model.name)
            guard seenFamilies.insert(family).inserted else { continue }
            chosen.append(listing)
        }
        return chosen
            .sorted { lhs, rhs in
                let order: [ModelFitEstimator.Verdict: Int] = [.runsGreat: 0, .runsWell: 1, .slow: 2, .notRecommended: 3]
                let left = order[lhs.fit.verdict] ?? 9
                let right = order[rhs.fit.verdict] ?? 9
                if left != right { return left < right }
                return lhs.model.downloads > rhs.model.downloads
            }
            .prefix(6)
            .map { $0 }
    }

    /// "qwen3-4b-instruct-2507" and "Qwen3-4B-Instruct-2507-abliterated" are the same shelf
    /// entry as far as a person choosing one is concerned.
    private func familyKey(_ name: String) -> String {
        let lower = name.lowercased()
        let head = lower.split(whereSeparator: { $0 == "-" || $0 == " " || $0 == "." }).prefix(2)
        return head.joined(separator: "-")
    }

    /// Filters out the repositories that are technically GGUF text models but are not what a
    /// person means when they ask for a model that writes their notes.
    private func isGeneralPurpose(_ model: HuggingFaceModel) -> Bool {
        let name = model.name.lowercased()
        let excluded = ["embed", "rerank", "whisper", "bge-", "clip", "-vl", "vision",
                        "guard", "code", "coder", "sd-", "flux", "diffusion", "tts",
                        "uncensored", "abliterated", "nsfw", "roleplay", "erp"]
        if excluded.contains(where: { name.contains($0) }) { return false }
        guard let billions = model.parameterBillions, billions >= 0.5 else { return false }
        return true
    }

    /// Builds a row from a search result, estimating the download size from the parameter
    /// count in the name. The exact size arrives with the file list when the user opens it.
    private func listing(for model: HuggingFaceModel) -> ModelListing? {
        guard let billions = model.parameterBillions else { return nil }
        // Q4_K_M lands near 4.7 bits a weight once the embedding and output tensors, which
        // stay at higher precision, are counted in.
        let bytes = Int64(billions * 1e9 * 4.7 / 8)
        return ModelListing(model: model, estimatedBytes: bytes, fit: fit(weightBytes: bytes, parameterBillions: billions))
    }

    // MARK: - Search

    func search() {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        searchTask?.cancel()
        guard !query.isEmpty else {
            searchResults = []
            nextSearchPage = nil
            return
        }
        isSearching = true
        searchTask = Task { [weak self] in
            guard let self else { return }
            // Typing should not fire a request a letter.
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            do {
                let page = try await HuggingFaceClient.search(
                    query: query, sort: .downloads, limit: 40, token: await self.token())
                guard !Task.isCancelled else { return }
                self.searchResults = page.models.compactMap(self.listing(for:))
                self.nextSearchPage = page.nextPageURL
                self.problem = nil
            } catch {
                guard !Task.isCancelled else { return }
                self.problem = self.plainMessage(for: error)
            }
            self.isSearching = false
        }
    }

    /// "Show more" at the bottom of the results.
    func loadNextSearchPage() async {
        guard let url = nextSearchPage, !isSearching else { return }
        isSearching = true
        defer { isSearching = false }
        do {
            let page = try await HuggingFaceClient.page(at: url, token: await token())
            searchResults.append(contentsOf: page.models.compactMap(listing(for:)))
            nextSearchPage = page.nextPageURL
        } catch {
            problem = plainMessage(for: error)
        }
    }

    // MARK: - Downloading

    func state(for repoID: String) -> ModelDownloadState? { downloads[repoID] }

    /// Step one of a download: read the repo, pick a file, check the verdict and the licence.
    ///
    /// Nothing is fetched here. Either the download starts, or a sheet asks the one question
    /// that has to be answered first — never a refusal.
    func startDownload(_ model: HuggingFaceModel) {
        guard downloads[model.id]?.isActive != true else { return }
        downloads[model.id] = .checking
        tasks[model.id]?.cancel()
        tasks[model.id] = Task { [weak self] in
            guard let self else { return }
            await self.prepareDownload(model)
        }
    }

    private func prepareDownload(_ model: HuggingFaceModel) async {
        let key = await token()
        do {
            let details = try await HuggingFaceClient.details(repoID: model.id, token: key)
            guard let file = details.recommendedFile else {
                downloads[model.id] = .failed("This model has no file this app can open.")
                return
            }
            let verdict = fit(weightBytes: file.sizeBytes, parameterBillions: details.parameterBillions ?? model.parameterBillions)

            if details.isGated || model.isGated {
                // A gated repo answers 401 rather than 403 to a request with no key at all,
                // which would otherwise send the user straight to "paste a key" — and the
                // key alone would not have helped, because the terms are the real gate.
                // Verified against meta-llama/Llama-3.1-8B-Instruct, which returns 401.
                guard key != nil else {
                    downloads[model.id] = nil
                    accessRequest = .termsOnModelPage(repoID: model.id, pageURL: model.pageURL)
                    return
                }
                if let problem = await HuggingFaceClient.checkAccess(repoID: model.id, path: file.path, token: key) {
                    downloads[model.id] = nil
                    present(problem, for: model)
                    return
                }
            }

            // A poor-fit verdict always needs a "download anyway"; so does replacing a brain
            // that is already in use, so the sheet's plain sentence about what will happen
            // can be read (and changed, for this one download) before it happens rather than
            // after.
            if verdict.verdict.needsConfirmation || InstalledModelLibrary.shared.hasUsableModel {
                downloads[model.id] = nil
                pendingConfirmation = PendingDownload(
                    model: model, file: file, details: details, fit: verdict,
                    policy: postDownloadPolicy,
                    recommendsDeletingOld: recommendsDeletingOld(fileBytes: file.sizeBytes),
                    bypassesDiskReserve: verdict.verdict.needsConfirmation
                )
                return
            }
            await run(model: model, file: file, details: details, policy: postDownloadPolicy)
        } catch {
            downloads[model.id] = nil
            if let hubError = error as? HuggingFaceError, isAccessProblem(hubError) {
                present(hubError, for: model)
            } else {
                downloads[model.id] = .failed(plainMessage(for: error))
            }
        }
    }

    /// The user answered the confirmation sheet — "Download anyway", or simply "Download" on
    /// a sheet that only asked about replacing the current brain. `policy` overrides what the
    /// sheet was shown with when the person changed it there for this one download; it never
    /// rewrites `postDownloadPolicy` itself.
    func confirmPendingDownload(policy: PostDownloadPolicy? = nil) {
        guard let pending = pendingConfirmation else { return }
        pendingConfirmation = nil
        downloads[pending.model.id] = .checking
        tasks[pending.model.id]?.cancel()
        tasks[pending.model.id] = Task { [weak self] in
            await self?.run(
                model: pending.model, file: pending.file, details: pending.details,
                confirmed: pending.bypassesDiskReserve, policy: policy ?? pending.policy)
        }
    }

    /// Whether free space after this download would be under this app's own 4 GB reserve
    /// twice over — the point at which the confirmation sheet leans the person toward
    /// deleting the old brain rather than merely mentioning that the option exists.
    private func recommendsDeletingOld(fileBytes: Int64) -> Bool {
        let free = ModelDownloader.availableDiskBytes()
        return free - fileBytes < ModelDownloader.minimumFreeBytesAfterDownload * 2
    }

    /// The transfer itself.
    private func run(
        model: HuggingFaceModel,
        file: HuggingFaceRepoFile,
        details: HuggingFaceModelDetails,
        confirmed: Bool = false,
        policy: PostDownloadPolicy = .downloadOnly
    ) async {
        let key = await token()
        let destination = ModelSpec.directory
            .appendingPathComponent(installedFileName(model: model, file: file))
        let remote = ModelDownloader.RemoteFile(
            url: HuggingFaceClient.downloadURL(repoID: model.id, path: file.path),
            destination: destination,
            expectedBytes: file.sizeBytes,
            expectedSHA256: file.sha256,
            bearerToken: key,
            allowLowDiskSpace: confirmed
        )

        let previousActiveID = InstalledModelLibrary.shared.activeAgentModelID
        downloads[model.id] = .downloading(completed: remote.resumeOffset, total: file.sizeBytes)
        do {
            try await ModelDownloader.download(remote) { [weak self] progress in
                Task { @MainActor [weak self] in
                    guard let self, self.downloads[model.id]?.isActive == true else { return }
                    self.downloads[model.id] = progress.completedBytes >= progress.totalBytes
                        ? .verifying
                        : .downloading(completed: progress.completedBytes, total: progress.totalBytes)
                }
            }
            let newModel = InstalledLocalModel(
                id: "\(model.id)/\(file.path)",
                displayName: model.name,
                fileURL: destination,
                parameterBillions: details.parameterBillions ?? model.parameterBillions,
                quantization: file.quantization,
                bytes: file.sizeBytes,
                isBuiltIn: false
            )
            InstalledModelLibrary.shared.add(newModel)
            downloads[model.id] = .finished
            refreshHardware()
            Log.app.info("model library: installed \(model.id, privacy: .public)")
            await applyPostDownloadPolicy(policy, previousActiveID: previousActiveID, newModel: newModel)
        } catch is CancellationError {
            // The partial file stays; pressing Download again resumes it.
            downloads[model.id] = nil
        } catch let urlError as URLError where urlError.code == .cancelled {
            // The same press of Stop, arriving as URLSession's own cancellation. Painting a
            // failure over a row the user deliberately paused would be a lie.
            downloads[model.id] = nil
        } catch {
            if let hubError = error as? HuggingFaceError, isAccessProblem(hubError) {
                downloads[model.id] = nil
                present(hubError, for: model)
            } else {
                downloads[model.id] = .failed(plainMessage(for: error))
            }
        }
    }

    // MARK: - What happens after a download finishes

    /// The result of finishing a download and, when the policy calls for it, trying the new
    /// model for real.
    struct PostDownloadOutcome: Equatable {
        /// Which model id should end up active.
        let activeID: String
        /// Which model id, if any, should be removed from disk.
        let deleteID: String?
    }

    /// The decision alone, with no file I/O and no model load — the part a self-test can
    /// drive directly, because both of the real actions this decides between cost something
    /// a table of inputs should never have to pay: a multi-gigabyte load, or a person's file.
    /// `nonisolated`: it touches no store state, so a self-test can call it without hopping
    /// onto the main actor for a pure decision table.
    nonisolated static func decide(
        policy: PostDownloadPolicy,
        previousActiveID: String,
        newModelID: String,
        loadSucceeded: Bool
    ) -> PostDownloadOutcome {
        switch policy {
        case .downloadOnly:
            return PostDownloadOutcome(activeID: previousActiveID, deleteID: nil)
        case .switchKeepOld:
            return loadSucceeded
                ? PostDownloadOutcome(activeID: newModelID, deleteID: nil)
                : PostDownloadOutcome(activeID: previousActiveID, deleteID: nil)
        case .switchDeleteOld:
            guard loadSucceeded else {
                return PostDownloadOutcome(activeID: previousActiveID, deleteID: nil)
            }
            let deleteID = previousActiveID == newModelID ? nil : previousActiveID
            return PostDownloadOutcome(activeID: newModelID, deleteID: deleteID)
        }
    }

    /// Switches to the model just downloaded (unless the policy says not to), asks the
    /// runtime to actually open it, and only then — never before — deletes the model it is
    /// replacing.
    ///
    /// "Verified" means a real load was attempted: `NotesModelRuntime.prepare()` opens
    /// whatever is active and, on its own, falls back to the built-in model and reports why
    /// through `ModelLoadNotice` if that file will not open (`NotesModelRuntime.swift` §
    /// `revertToBuiltIn`). This reuses that existing safety net rather than duplicating it:
    /// after `prepare()` returns, `InstalledModelLibrary.activeAgentModelID` says which model
    /// actually ended up loaded, and that is the one fact this function trusts. On a
    /// reverted (failed) load this restores the model that was active *before* this download
    /// — not necessarily the built-in one the runtime falls back to — so "switch back" means
    /// what it sounds like even when the previous brain was itself a downloaded one.
    private func applyPostDownloadPolicy(
        _ policy: PostDownloadPolicy,
        previousActiveID: String,
        newModel: InstalledLocalModel
    ) async {
        guard policy != .downloadOnly, previousActiveID != newModel.id else { return }
        InstalledModelLibrary.shared.activeAgentModelID = newModel.id
        let loadSucceeded: Bool
        do {
            try await NotesModelRuntime.shared.prepare()
            loadSucceeded = InstalledModelLibrary.shared.activeAgentModelID == newModel.id
        } catch {
            loadSucceeded = false
        }
        let outcome = Self.decide(
            policy: policy, previousActiveID: previousActiveID,
            newModelID: newModel.id, loadSucceeded: loadSucceeded
        )
        if InstalledModelLibrary.shared.activeAgentModelID != outcome.activeID {
            InstalledModelLibrary.shared.activeAgentModelID = outcome.activeID
        }
        if let deleteID = outcome.deleteID {
            InstalledModelLibrary.shared.remove(id: deleteID)
        }
        refreshHardware()
    }

    // MARK: - Partial downloads

    /// Every `.part` file sitting in the Models folder that is not part of a transfer this
    /// session is actively running — those already have their own progress row. Largest
    /// first, so the biggest piece of reclaimable space leads.
    func partialDownloads(in directory: URL = ModelSpec.directory) -> [PartialModelDownload] {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.fileSizeKey]
        ) else { return [] }
        let activeDestinations = Set(tasks.keys.map { installedPartialFileName(repoIDPrefix: $0) })
        return entries
            .filter { $0.pathExtension == "part" }
            .compactMap { url -> PartialModelDownload? in
                let bytes = ModelDownloader.fileSize(at: url)
                guard bytes > 0 else { return nil }
                let name = url.lastPathComponent
                if activeDestinations.contains(where: { name.hasPrefix($0) }) { return nil }
                return PartialModelDownload(fileName: name, bytes: bytes)
            }
            .sorted { $0.bytes > $1.bytes }
    }

    /// The prefix a repo id's own file would be written under, so an in-flight download's
    /// `.part` file can be told apart from an orphaned one left by a previous session.
    private func installedPartialFileName(repoIDPrefix repoID: String) -> String {
        repoID.split(separator: "/").first.map { "\($0)--" } ?? repoID
    }

    /// Frees the space a stopped download left behind. Downloading the same model again
    /// starts a fresh transfer rather than resuming this one, which is the honest trade —
    /// there is no record of which repository this file came from once it is gone.
    func discardPartial(_ partial: PartialModelDownload, in directory: URL = ModelSpec.directory) {
        try? FileManager.default.removeItem(at: directory.appendingPathComponent(partial.fileName))
        refreshHardware()
    }

    /// Stops a transfer and keeps what has arrived so far.
    func cancelDownload(_ repoID: String) {
        tasks[repoID]?.cancel()
        tasks[repoID] = nil
        downloads[repoID] = nil
    }

    func dismissFailure(_ repoID: String) {
        if downloads[repoID]?.isActive != true { downloads[repoID] = nil }
    }

    /// Deletes an installed model and, when it was the one in use, hands the agent back to
    /// the built-in one.
    func delete(_ model: InstalledLocalModel) {
        // Deleting the model in use moves the selection back to the built-in one, and
        // `InstalledModelLibrary` hands that change to the runtime itself.
        InstalledModelLibrary.shared.remove(id: model.id)
        refreshHardware()
    }

    /// Makes an installed model the one the agent uses. The library tells the runtime.
    func makeActive(_ model: InstalledLocalModel) {
        InstalledModelLibrary.shared.activeAgentModelID = model.id
    }

    /// Where a downloaded model lands. Owner-qualified so two repos publishing the same file
    /// name cannot overwrite each other.
    private func installedFileName(model: HuggingFaceModel, file: HuggingFaceRepoFile) -> String {
        let owner = model.author.replacingOccurrences(of: "/", with: "-")
        return "\(owner)--\(file.fileName)"
    }

    // MARK: - Errors, in plain language

    private func isAccessProblem(_ error: HuggingFaceError) -> Bool {
        switch error {
        case .gated, .needsAccessKey, .accessKeyRejected: true
        default: false
        }
    }

    private func present(_ error: HuggingFaceError, for model: HuggingFaceModel) {
        switch error {
        case .gated:
            accessRequest = .termsOnModelPage(repoID: model.id, pageURL: model.pageURL)
        case .needsAccessKey:
            accessRequest = .accessKey(repoID: model.id, wasRejected: false)
        case .accessKeyRejected:
            accessRequest = .accessKey(repoID: model.id, wasRejected: true)
        default:
            problem = plainMessage(for: error)
        }
    }

    /// No status codes, no URLs, no "unexpected nil" — the person reading this cannot act on
    /// any of it.
    func plainMessage(for error: Error) -> String {
        if let hubError = error as? HuggingFaceError {
            return hubError.errorDescription ?? "Something went wrong."
        }
        if let downloadError = error as? ModelDownloadError {
            return downloadError.errorDescription ?? "The download did not finish."
        }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .notConnectedToInternet, .cannotFindHost, .cannotConnectToHost, .networkConnectionLost:
                return "No internet connection."
            case .timedOut:
                return "The connection timed out. Try again in a moment."
            default:
                return "The download stopped unexpectedly. Try again."
            }
        }
        return error.localizedDescription
    }
}
