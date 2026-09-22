import SwiftUI

/// The "Your Mac" card at the top of the Models tab.
///
/// It exists because every verdict below it is relative to this machine, and a person who
/// does not know what a Mac's memory is still needs to see that the app knows.
struct YourMacCard: View {
    let hardware: HardwareProfile

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            HStack(spacing: DS.Space.s) {
                Image(systemName: "laptopcomputer")
                    .font(DS.Font.title3)
                    .foregroundStyle(DS.Color.accent)
                VStack(alignment: .leading, spacing: DS.Space.xxs) {
                    Text(hardware.plainSummary)
                        .font(DS.Font.headline)
                    Text(hardware.coreSummary)
                        .font(DS.Font.caption)
                        .foregroundStyle(DS.Color.textSecondary)
                }
            }
            Text(capacitySentence)
                .font(DS.Font.caption)
                .foregroundStyle(DS.Color.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            if let warning {
                Label(warning, systemImage: "bolt.slash")
                    .font(DS.Font.caption)
                    .foregroundStyle(DS.Color.warning)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(DS.Space.card)
        .background(DS.Color.groupedFill, in: RoundedRectangle(cornerRadius: DS.Radius.card))
    }

    /// The headline claim, in the user's own terms: how big a model this Mac can hold.
    private var capacitySentence: String {
        let usable = ModelFitEstimator.safelyUsableMemoryBytes(hardware)
        guard usable > 0 else {
            return "There isn’t enough memory here to run a model on this Mac."
        }
        let size = ModelFitEstimator.gigabytes(usable)
        return "Next Notes can give a model about \(size) GB of this Mac’s memory, "
            + "and still leave room for everything else you have open. "
            + "That’s roughly \(comfortableSize) worth of model."
    }

    /// Translated into the unit model names are written in, since that is what the person is
    /// about to read on every card below.
    private var comfortableSize: String {
        let usable = Double(ModelFitEstimator.safelyUsableMemoryBytes(hardware))
        // Working back from the same arithmetic the estimator uses: weights, cache, buffers.
        let weights = max(0, (usable - 600_000_000) / 1.05 - 800_000_000)
        let billions = weights * 8 / 4.7 / 1e9
        switch billions {
        case ..<1: return "a very small one"
        case ..<4: return "a 3-billion-word-pattern model"
        case ..<9: return "an 8-billion-word-pattern model"
        case ..<16: return "a 14-billion-word-pattern model"
        case ..<40: return "a 30-billion-word-pattern model"
        default: return "a 70-billion-word-pattern model"
        }
    }

    private var warning: String? {
        if hardware.isLowPowerModeEnabled {
            return "Low Power Mode is on, so models will run slower than usual."
        }
        switch hardware.thermalState {
        case .serious, .critical:
            return "This Mac is running hot, so models will be slower until it cools down."
        default:
            return nil
        }
    }
}

/// The coloured verdict badge that appears on every model card.
struct ModelVerdictBadge: View {
    let fit: ModelFitEstimator.Fit

    var body: some View {
        Label(fit.verdict.title, systemImage: fit.verdict.symbolName)
            .font(DS.Font.chip)
            .foregroundStyle(tint)
    }

    private var tint: Color {
        switch fit.verdict {
        case .runsGreat, .runsWell: DS.Color.success
        case .slow: DS.Color.warning
        case .notRecommended: DS.Color.textSecondary
        }
    }
}

/// One model in the "Recommended" or search list.
struct ModelBrowseRow: View {
    let listing: ModelListing
    let downloadState: ModelDownloadState?
    let isInstalled: Bool
    let onDownload: () -> Void
    let onCancel: () -> Void

    @State private var showsDetail = false

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            HStack(alignment: .top, spacing: DS.Space.m) {
                VStack(alignment: .leading, spacing: DS.Space.xxs) {
                    Text(listing.model.name)
                        .font(DS.Font.headline)
                    Text("\(listing.model.makerSentence) · \(listing.model.popularitySentence)")
                        .font(DS.Font.caption)
                        .foregroundStyle(DS.Color.textSecondary)
                    ModelVerdictBadge(fit: listing.fit)
                    Text(listing.fit.reason)
                        .font(DS.Font.caption)
                        .foregroundStyle(DS.Color.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let speed = listing.fit.speedSentence {
                        Text(speed)
                            .font(DS.Font.caption)
                            .foregroundStyle(DS.Color.textSecondary)
                    }
                    if listing.model.isGated {
                        Label("The makers ask you to agree to their terms first",
                              systemImage: "hand.raised")
                            .font(DS.Font.caption)
                            .foregroundStyle(DS.Color.textSecondary)
                    }
                }
                Spacer(minLength: DS.Space.s)
                action
            }

            if let downloadState, downloadState.isActive {
                VStack(alignment: .leading, spacing: DS.Space.xxs) {
                    ProgressView(value: downloadState.fraction)
                        .frame(width: DS.Size.progressWidth)
                    Text(downloadState.sentence)
                        .font(DS.Font.caption)
                        .foregroundStyle(DS.Color.textSecondary)
                }
            } else if case .failed(let message) = downloadState {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(DS.Font.caption)
                    .foregroundStyle(DS.Color.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }

            DisclosureGroup("Technical details", isExpanded: $showsDetail) {
                VStack(alignment: .leading, spacing: DS.Space.xxs) {
                    Text(listing.fit.technicalDetail)
                    Text(listing.model.licenseSentence)
                    Link("Open this model’s page", destination: listing.model.pageURL)
                }
                .font(DS.Font.caption)
                .foregroundStyle(DS.Color.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, DS.Space.xxs)
            }
            .font(DS.Font.caption)
        }
        .padding(.vertical, DS.Space.xxs)
    }

    @ViewBuilder
    private var action: some View {
        if isInstalled {
            Label("On this Mac", systemImage: "checkmark.circle.fill")
                .font(DS.Font.caption)
                .foregroundStyle(DS.Color.success)
        } else if downloadState?.isActive == true {
            Button("Stop", action: onCancel)
        } else {
            VStack(alignment: .trailing, spacing: DS.Space.xxs) {
                Button("Download", action: onDownload)
                    .buttonStyle(.borderedProminent)
                Text(ByteCountFormatter.string(
                    fromByteCount: listing.estimatedBytes, countStyle: .file))
                    .font(DS.Font.caption2)
                    .foregroundStyle(DS.Color.textSecondary)
            }
        }
    }
}

/// One model already on this Mac.
///
/// "In use" answers one question — will the next agent turn come from this file? —
/// and nothing else. The runtime's selected file (`activeAgentModelID`) is not that
/// answer: the Agent role re-asserts its own choice over the file on every turn, so a
/// badge drawn from the file alone reads "in use" on a model nothing will reach.
struct InstalledModelRow: View {
    let model: InstalledLocalModel
    let fit: ModelFitEstimator.Fit
    /// Whether the Agent role effectively resolves to this file. The only thing the
    /// badge may claim.
    let answersTurns: Bool
    /// Shown when this file is loaded but something else answers — the state the old
    /// badge reported as "In use".
    var statusNote: String? = nil
    /// Whether Delete may even be offered. The built-in model only allows it once a
    /// different brain is already the one in use — see `InstalledModelLibrary.canRemove`.
    var canRemove: Bool = true
    var lastUsed: Date? = nil
    let onUse: () -> Void
    let onDelete: () -> Void

    @State private var confirmingDelete = false

    var body: some View {
        HStack(alignment: .top, spacing: DS.Space.m) {
            VStack(alignment: .leading, spacing: DS.Space.xxs) {
                HStack(spacing: DS.Space.xs) {
                    Text(model.displayName)
                        .font(DS.Font.headline)
                    if model.isBuiltIn {
                        Text("Built in")
                            .font(DS.Font.chip)
                            .foregroundStyle(DS.Color.textSecondary)
                    }
                }
                Text(subtitle)
                    .font(DS.Font.caption)
                    .foregroundStyle(DS.Color.textSecondary)
                if let statusNote {
                    Text(statusNote)
                        .font(DS.Font.caption)
                        .foregroundStyle(DS.Color.warning)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ModelVerdictBadge(fit: fit)
            }
            Spacer(minLength: DS.Space.s)
            VStack(alignment: .trailing, spacing: DS.Space.xs) {
                if answersTurns {
                    Label("In use", systemImage: "checkmark.circle.fill")
                        .font(DS.Font.caption)
                        .foregroundStyle(DS.Color.success)
                } else {
                    Button("Use this one", action: onUse)
                }
                if canRemove {
                    Button("Delete", role: .destructive) { confirmingDelete = true }
                        .font(DS.Font.caption)
                }
            }
        }
        .padding(.vertical, DS.Space.xxs)
        .confirmationDialog(
            "Delete \(model.displayName)?",
            isPresented: $confirmingDelete,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive, action: onDelete)
            Button("Keep it", role: .cancel) {}
        } message: {
            Text(deleteMessage)
        }
    }

    private var deleteMessage: String {
        let base = "This frees \(model.displaySize) on this Mac. "
        return base + (model.isBuiltIn
            ? "It's the model Next Notes ships with, so it can be downloaded again any time."
            : "You can download it again later.")
    }

    private var subtitle: String {
        var parts = [model.displaySize]
        if let billions = model.parameterBillions {
            parts.append(billions < 1
                ? "\(Int(billions * 1_000)) million word patterns"
                : "\(formatted(billions)) billion word patterns")
        }
        if let quantization = model.quantization {
            parts.append(ModelFitEstimator.quantizationDescription(quantization))
        }
        if let lastUsed {
            parts.append("last used \(lastUsed.formatted(date: .abbreviated, time: .omitted))")
        }
        return parts.joined(separator: " · ")
    }

    private func formatted(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(format: "%.1f", value)
    }
}

/// Before a download starts: what this Mac will make of it, and — whenever a brain is
/// already in use — what happens to that one once the new one arrives.
///
/// The app never refuses. It says what it thinks will happen, and the person decides. Shown
/// for a poor-fit verdict (`pending.bypassesDiskReserve`) and, separately, whenever this
/// download would replace a model already in use — the second case skips the "will be slow"
/// framing entirely, because the fit is fine; the only open question is what to do with the
/// old one.
struct ModelDownloadConfirmSheet: View {
    let pending: ModelLibraryStore.PendingDownload
    let onConfirm: (ModelLibraryStore.PostDownloadPolicy) -> Void
    let onCancel: () -> Void

    @State private var policy: ModelLibraryStore.PostDownloadPolicy

    init(
        pending: ModelLibraryStore.PendingDownload,
        onConfirm: @escaping (ModelLibraryStore.PostDownloadPolicy) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.pending = pending
        self.onConfirm = onConfirm
        self.onCancel = onCancel
        _policy = State(initialValue: pending.policy)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.m) {
            if pending.bypassesDiskReserve {
                Label(pending.fit.verdict.title, systemImage: pending.fit.verdict.symbolName)
                    .font(DS.Font.title3)
                    .foregroundStyle(pending.fit.verdict == .slow ? DS.Color.warning : DS.Color.textSecondary)
            }
            Text(pending.model.name)
                .font(DS.Font.headline)
            if pending.bypassesDiskReserve {
                Text(pending.fit.reason)
                    .fixedSize(horizontal: false, vertical: true)
                if let speed = pending.fit.speedSentence {
                    Text(speed)
                        .foregroundStyle(DS.Color.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text("You can download it anyway. Nothing here stops you — this is only what "
                     + "we expect it to feel like on this Mac.")
                    .font(DS.Font.caption)
                    .foregroundStyle(DS.Color.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(pending.fit.technicalDetail)
                    .font(DS.Font.caption)
                    .foregroundStyle(DS.Color.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Picker("When it finishes", selection: $policy) {
                ForEach(ModelLibraryStore.PostDownloadPolicy.allCases) { choice in
                    Text(choice.title).tag(choice)
                }
            }
            .pickerStyle(.radioGroup)
            Text(policy.sentence)
                .font(DS.Font.caption)
                .foregroundStyle(DS.Color.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            if pending.recommendsDeletingOld, policy != .switchDeleteOld {
                Label("This Mac is short on space — deleting the old one is worth considering.",
                      systemImage: "externaldrive.badge.exclamationmark")
                    .font(DS.Font.caption)
                    .foregroundStyle(DS.Color.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button("Not now", role: .cancel, action: onCancel)
                Button(pending.bypassesDiskReserve ? "Download anyway" : "Download") {
                    onConfirm(policy)
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(DS.Space.xl)
        .frame(width: DS.Size.sheetWidth)
    }
}

/// The two things Hugging Face can ask for, asked without jargon.
struct HuggingFaceAccessSheet: View {
    let request: ModelAccessRequest
    let onSaveKey: (String) async -> Bool
    let onDismiss: () -> Void

    @State private var keyInput = ""
    @State private var isSaving = false
    @State private var problem: String?
    /// The terms step leads into the key step, in one sheet, because a gated model needs
    /// both and sending the user back to the list in between loses them.
    @State private var showingKeyStep = false

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.m) {
            if case .termsOnModelPage(let repoID, let pageURL) = request, !showingKeyStep {
                terms(repoID: repoID, pageURL: pageURL)
            } else {
                accessKey
            }
        }
        .padding(DS.Space.xl)
        .frame(width: DS.Size.sheetWidth)
    }

    @ViewBuilder
    private func terms(repoID: String, pageURL: URL) -> some View {
        Label("One step first", systemImage: "hand.raised")
            .font(DS.Font.title3)
        Text("The people who made this model ask you to agree to their terms before it can "
             + "be downloaded. Open its page, agree, then come back here.")
            .fixedSize(horizontal: false, vertical: true)
        Text(repoID)
            .font(DS.Font.caption)
            .foregroundStyle(DS.Color.textSecondary)
        Text("Agreeing needs a free Hugging Face account. Afterwards this Mac needs an "
             + "access key from that account, so it can prove the agreement is yours.")
            .font(DS.Font.caption)
            .foregroundStyle(DS.Color.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
        HStack {
            Link("Open the model’s page", destination: pageURL)
                .buttonStyle(.borderedProminent)
            Spacer()
            Button("Not now", role: .cancel, action: onDismiss)
            Button("I’ve agreed — next") { showingKeyStep = true }
        }
    }

    @ViewBuilder
    private var accessKey: some View {
        Label(wasRejected ? "That key didn’t work" : "Add your access key",
              systemImage: "key")
            .font(DS.Font.title3)
        Text("Paste an access key from your Hugging Face account. It stays in this Mac’s "
             + "Keychain and is only used to fetch models you have asked for.")
            .fixedSize(horizontal: false, vertical: true)
        Link("Where to find your access key", destination: HuggingFaceAccessStore.keyPageURL)
        SecureField("Paste your access key", text: $keyInput)
            .textFieldStyle(.roundedBorder)
        if let problem {
            Text(problem)
                .font(DS.Font.caption)
                .foregroundStyle(DS.Color.warning)
                .fixedSize(horizontal: false, vertical: true)
        }
        HStack {
            Spacer()
            Button("Not now", role: .cancel, action: onDismiss)
            Button(isSaving ? "Checking…" : "Save key") {
                let value = keyInput
                isSaving = true
                problem = nil
                Task {
                    let worked = await onSaveKey(value)
                    isSaving = false
                    if worked {
                        keyInput = ""
                        onDismiss()
                    } else {
                        problem = "Hugging Face didn’t accept that key. Check you copied all of it."
                    }
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(isSaving || keyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    private var wasRejected: Bool {
        if case .accessKey(_, let rejected) = request { return rejected }
        return false
    }
}
