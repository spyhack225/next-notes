import Foundation
import Observation

/// What the person said about a named coding harness that is not on PATH.
enum ACPConfirmationOutcome: Equatable, Sendable {
    case notRequired
    case pending
    case confirmedOnce
    case cancelled
}

struct ACPConfirmationRequest: Identifiable, Equatable, Sendable {
    let id: String
    let harnessID: AgentHarnessID
    let title: String
    let detail: String
    let utterance: String
}

/// Local tools may run when the user asked for local, or when they confirmed
/// once after a named ACP CLI was missing. An unavailable harness without
/// that outcome must not silently execute.
enum ACPConfirmation {
    static func allowsLocalTools(
        _ choice: AgentHarnessChoice,
        outcome: ACPConfirmationOutcome
    ) -> Bool {
        if choice.id == .local { return true }
        if choice.available { return false }
        return outcome == .confirmedOnce
    }

    /// What voice `handle` may do with a router pick. A missing CLI is never
    /// “run local” or “start ACP” until [Run once] / [Cancel].
    static func entryAction(
        _ choice: AgentHarnessChoice,
        outcome: ACPConfirmationOutcome
    ) -> ACPEntryAction {
        if choice.needsACPConfirmation {
            switch outcome {
            case .confirmedOnce: return .runLocalOnce
            case .cancelled: return .cancelled
            case .pending, .notRequired: return .awaitConfirmation
            }
        }
        return choice.id == .local || !choice.available ? .runLocal : .startACP
    }

    /// Sync mirror of the decision `waitForACPConfirmation` makes before
    /// parking. Voice `handle` uses this — never “run local” / “start ACP”
    /// while a missing CLI still has no confirmation outcome.
    static func voiceEntryAction(_ choice: AgentHarnessChoice) -> ACPEntryAction {
        entryAction(
            choice,
            outcome: choice.needsACPConfirmation ? .pending : .notRequired
        )
    }
}

/// Voice `handle` consults `ACPConfirmation.entryAction` before starting work.
enum ACPEntryAction: Equatable, Sendable {
    case startACP
    case runLocal
    case runLocalOnce
    case awaitConfirmation
    case cancelled
}

/// One in-flight “ACP isn’t installed — run locally once?” The Agent sidebar
/// shows [Run once] [Cancel]. Voice parks the same card; it does not auto-run.
@MainActor
@Observable
final class ACPConfirmationGate {
    static let shared = ACPConfirmationGate()

    private(set) var pending: ACPConfirmationRequest?
    private(set) var lastOutcome: ACPConfirmationOutcome = .notRequired
    private var waiter: CheckedContinuation<ACPConfirmationOutcome, Never>?

    private init() {}

    func offer(_ choice: AgentHarnessChoice, utterance: String) {
        guard choice.needsACPConfirmation else { return }
        pending = ACPConfirmationRequest(
            id: UUID().uuidString,
            harnessID: choice.id,
            title: "\(choice.id.displayName) isn’t installed",
            detail: choice.note,
            utterance: utterance
        )
        lastOutcome = .pending
    }

    /// Parks until [Run once] / [Cancel]. A second voice turn cancels the
    /// waiter already sitting here so `handle` cannot leak a continuation.
    func request(_ choice: AgentHarnessChoice, utterance: String) async -> ACPConfirmationOutcome {
        guard choice.needsACPConfirmation else {
            lastOutcome = .notRequired
            return .notRequired
        }
        if let previous = waiter {
            waiter = nil
            previous.resume(returning: .cancelled)
        }
        offer(choice, utterance: utterance)
        return await withCheckedContinuation { continuation in
            waiter = continuation
        }
    }

    /// Returns true when a waiter was resumed, so the button must not also run.
    @discardableResult
    func confirmOnce() -> Bool {
        resolve(.confirmedOnce)
    }

    @discardableResult
    func cancel() -> Bool {
        resolve(.cancelled)
    }

    func resetForTesting() {
        pending = nil
        lastOutcome = .notRequired
        waiter?.resume(returning: .cancelled)
        waiter = nil
    }

    @discardableResult
    private func resolve(_ outcome: ACPConfirmationOutcome) -> Bool {
        let hadWaiter = waiter != nil
        pending = nil
        lastOutcome = outcome
        waiter?.resume(returning: outcome)
        waiter = nil
        return hadWaiter
    }
}

extension ACPConfirmation {
    /// Fail if an unavailable CLI would run local tools without a confirmation
    /// outcome. Not wired to `--selftest-acp` and never calls `RunLog.record`.
    @MainActor
    @discardableResult
    static func runSelfTest() -> Bool {
        var failures: [String] = []
        func check(_ name: String, _ condition: Bool) {
            if !condition { failures.append(name) }
        }

        AgentHarnessRouter.shared.resetForTesting()
        AgentHarnessRouter.shared.availabilityProbe = { _ in false }

        let named = AgentHarnessRouter.shared.choose(for: "use claude code to investigate this repo")
        check("an unavailable Claude pick did not stay on the ACP harness", named.id == .claude)
        check("an unavailable Claude pick silently became local", named.backend == .acp)
        check("fallbackToLocal was still set for a missing CLI", named.fallbackToLocal == false)
        check("a missing CLI did not ask for confirmation", named.needsACPConfirmation)
        check(
            "an unavailable CLI ran local tools without a confirmation outcome",
            !allowsLocalTools(named, outcome: .pending)
                && !allowsLocalTools(named, outcome: .notRequired)
                && !allowsLocalTools(named, outcome: .cancelled)
        )
        check(
            "confirming once still refused local tools",
            allowsLocalTools(named, outcome: .confirmedOnce)
        )
        check(
            "the confirm card was not parked for a missing CLI",
            ACPConfirmationGate.shared.pending != nil
                && ACPConfirmationGate.shared.lastOutcome == .pending
        )
        check(
            "voice entry ran local or started ACP without a confirmation outcome",
            voiceEntryAction(named) == .awaitConfirmation
                && entryAction(named, outcome: .pending) == .awaitConfirmation
                && entryAction(named, outcome: .notRequired) == .awaitConfirmation
                && entryAction(named, outcome: ACPConfirmationGate.shared.lastOutcome)
                    == .awaitConfirmation
        )
        check(
            "voice [Run once] did not run local tools once",
            entryAction(named, outcome: .confirmedOnce) == .runLocalOnce
        )
        check(
            "voice [Cancel] was not cancelled",
            entryAction(named, outcome: .cancelled) == .cancelled
        )

        // Same helper `waitForACPConfirmation` / voice `handle` consult before
        // parking. Sync on purpose — this flag is not Task-wrapped in
        // NextNotesApp, and never calls `RunLog.record`.
        check(
            "voice-shaped entry returned run local or start ACP before an outcome",
            voiceEntryAction(named) != .runLocal
                && voiceEntryAction(named) != .startACP
                && voiceEntryAction(named) != .runLocalOnce
                && voiceEntryAction(named) == .awaitConfirmation
        )
        ACPConfirmationGate.shared.resetForTesting()
        ACPConfirmationGate.shared.offer(
            named,
            utterance: "use claude code to investigate this repo"
        )
        check(
            "voice-shaped gate offer did not park the confirm card",
            ACPConfirmationGate.shared.pending != nil
                && ACPConfirmationGate.shared.lastOutcome == .pending
                && voiceEntryAction(named) == .awaitConfirmation
        )
        _ = ACPConfirmationGate.shared.cancel()
        check(
            "voice-shaped cancel resolved to run local or start ACP",
            entryAction(named, outcome: ACPConfirmationGate.shared.lastOutcome) == .cancelled
        )
        ACPConfirmationGate.shared.offer(
            named,
            utterance: "use claude code to investigate this repo"
        )
        _ = ACPConfirmationGate.shared.confirmOnce()
        check(
            "voice-shaped [Run once] did not become runLocalOnce",
            entryAction(named, outcome: ACPConfirmationGate.shared.lastOutcome) == .runLocalOnce
        )
        check(
            "voice-shaped [Run once] resolved to start ACP",
            entryAction(named, outcome: ACPConfirmationGate.shared.lastOutcome) != .startACP
                && entryAction(named, outcome: ACPConfirmationGate.shared.lastOutcome) != .runLocal
        )

        let calendar = AgentHarnessRouter.shared.choose(for: "what's on my calendar")
        check("calendar left stayLocalMarks", calendar.id == .local)
        check("calendar asked for ACP confirmation", !calendar.needsACPConfirmation)
        check(
            "calendar was not allowed to run locally",
            allowsLocalTools(calendar, outcome: .notRequired)
        )
        check(
            "calendar voice entry did not stay local",
            voiceEntryAction(calendar) == .runLocal
        )

        let click = AgentHarnessRouter.shared.choose(for: "click the Run button")
        check("click left stayLocalMarks", click.id == .local)
        check("click asked for ACP confirmation", !click.needsACPConfirmation)
        check(
            "click voice entry did not stay local",
            voiceEntryAction(click) == .runLocal
        )

        AgentHarnessRouter.shared.availabilityProbe = { _ in true }
        let present = AgentHarnessRouter.shared.choose(for: "use claude code to investigate this repo")
        check("an installed CLI asked for confirmation", !present.needsACPConfirmation)
        check(
            "an installed CLI was treated as a local-tools run",
            !allowsLocalTools(present, outcome: .notRequired)
        )
        check(
            "an installed CLI voice entry did not start ACP",
            voiceEntryAction(present) == .startACP
        )

        let unknown = AgentProposal(
            meetingID: UUID(),
            tool: "definitely_unknown_tool_xyz",
            arguments: [:],
            rationale: ""
        )
        check("an unknown tool isn't treated as the most dangerous class", unknown.risk == .send)
        check(
            "compatibility CLI fallback could run without explicit approval",
            ACPCompatibilityCLIBackend.runSelfTest()
        )

        AgentHarnessRouter.shared.restorePersistence()
        ACPConfirmationGate.shared.resetForTesting()

        for failure in failures {
            print("ACP_CONFIRM_WRONG: \(failure)")
        }
        print(failures.isEmpty ? "ACP_CONFIRM_OK" : "ACP_CONFIRM_FAILED")
        return failures.isEmpty
    }
}
