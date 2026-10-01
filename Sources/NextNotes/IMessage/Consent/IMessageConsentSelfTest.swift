import Foundation

/// `--selftest-imessage-consent` — IM-17a: the consent decision as a pure value.
///
/// No grant, no pairing, no model: the graph is a pure function of state, event
/// and origin. The final line is `IMESSAGE_CONSENT_OK: <n> cases`; per-case
/// lines are `IMESSAGE_CONSENT_WRONG: …`, which is not a verdict token.
enum IMessageConsentSelfTest {
    static func run() -> String {
        var failures: [String] = []
        var caseCount = 0

        func check(_ name: String, _ body: () -> String?) {
            caseCount += 1
            if let problem = body() { failures.append("\(name): \(problem)") }
        }

        func next(_ state: IMessageConsentState, _ event: IMessageConsentEvent,
                  origin: ActionOriginContext? = nil) -> IMessageConsentState? {
            IMessageConsentTransition.next(from: state, event: event, origin: origin)
        }

        let remote = ActionOriginContext(transport: .iMessage)

        // The four steps advance in order.
        check("steps_advance_in_order") {
            guard next(.off, .switchOn) == .explaining else { return "off did not explain" }
            guard next(.explaining, .continuePressed) == .askingForFullDiskAccess(hasOpenedPane: false) else {
                return "explaining did not ask"
            }
            guard next(.askingForFullDiskAccess(hasOpenedPane: false), .openedSettingsPane)
                    == .askingForFullDiskAccess(hasOpenedPane: true) else {
                return "the pane press did not escalate"
            }
            guard next(.askingForFullDiskAccess(hasOpenedPane: true), .accessReadable)
                    == .waitingForTheMessage else {
                return "readable did not wait"
            }
            guard next(.waitingForTheMessage, .commandArrived) == .confirming else {
                return "the command did not confirm"
            }
            guard next(.confirming, .confirmationVerified) == .connected else {
                return "verification did not connect"
            }
            return nil
        }

        // A granted verdict on entry skips step 2.
        check("granted_on_entry_skips_step_2") {
            guard next(.askingForFullDiskAccess(hasOpenedPane: false), .accessGranted)
                    == .waitingForTheMessage else {
                return "a granted entry did not skip"
            }
            return nil
        }

        // A timed-out confirmation returns to waiting; the wait continues.
        check("timed_out_confirmation_waits_on") {
            guard next(.confirming, .confirmationTimedOut) == .waitingForTheMessage else {
                return "a timeout did not return to waiting"
            }
            return nil
        }

        // Not now, I'll do this later, and dismissed each reach off with their
        // own reason.
        check("not_now_reaches_off") {
            guard next(.askingForFullDiskAccess(hasOpenedPane: false), .notNow)
                    == .declined(reason: .notNow) else {
                return "not now did not decline"
            }
            return nil
        }
        check("do_later_reaches_off") {
            guard next(.waitingForTheMessage, .doLater) == .declined(reason: .later) else {
                return "later did not decline"
            }
            return nil
        }
        check("dismissed_reaches_off") {
            guard next(.explaining, .dismissed) == .declined(reason: .dismissed) else {
                return "a dismiss did not decline"
            }
            return nil
        }

        // A later switch-on starts over from the beginning, same copy, no variant.
        check("later_switch_on_starts_over") {
            guard next(.declined(reason: .later), .switchOn) == .explaining else {
                return "a later switch-on did not explain"
            }
            guard next(.declined(reason: .notNow), .switchOn) == .explaining else {
                return "a switch-on after not-now did not explain"
            }
            return nil
        }

        // No transition in this graph can be driven from the phone.
        check("remote_origin_refuses_everything") {
            let samples: [(IMessageConsentState, IMessageConsentEvent)] = [
                (.off, .switchOn), (.explaining, .continuePressed),
                (.waitingForTheMessage, .commandArrived), (.connected, .switchOff),
                (.declined(reason: .later), .switchOn),
            ]
            for (state, event) in samples {
                guard next(state, event, origin: remote) == nil else {
                    return "a remote origin drove \(event) from \(state)"
                }
            }
            return nil
        }

        // Connected to off is immediate.
        check("connected_to_off_is_immediate") {
            guard next(.connected, .switchOff) == .off else {
                return "switching off did not end immediately"
            }
            return nil
        }

        // Unlisted events default to nothing.
        check("unlisted_events_refuse") {
            guard next(.off, .commandArrived) == nil else {
                return "a command while off did something"
            }
            guard next(.explaining, .switchOn) == nil else {
                return "a second switch-on did something"
            }
            guard next(.connected, .continuePressed) == nil else {
                return "a continue while connected did something"
            }
            return nil
        }

        // No copy names the agent: the trigger sentence references the constant,
        // and step 4 interpolates the runtime name.
        check("no_copy_names_the_agent") {
            let fixed = [IMessageConsentCopy.switchTitle, IMessageConsentCopy.switchDetail,
                         IMessageConsentCopy.sheetTitle, IMessageConsentCopy.step1Headline,
                         IMessageConsentCopy.step1Body, IMessageConsentCopy.step1Conversation,
                         IMessageConsentCopy.step1WhatIsUsed, IMessageConsentCopy.step1WhoAnswers,
                         IMessageConsentCopy.continueButton, IMessageConsentCopy.step2Headline,
                         IMessageConsentCopy.step2Body, IMessageConsentCopy.openSettingsButton,
                         IMessageConsentCopy.notNowButton, IMessageConsentCopy.step3Headline,
                         IMessageConsentCopy.step3Waiting, IMessageConsentCopy.sendTestButton,
                         IMessageConsentCopy.doLaterButton, IMessageConsentCopy.step4Headline,
                         IMessageConsentCopy.doneButton, IMessageConsentCopy.stopButton,
                         IMessageConsentCopy.refusal]
            for line in fixed where line.contains("You are ") {
                return "a copy line names the agent: \(line)"
            }
            guard IMessageConsentCopy.step3Body.hasSuffix(SelfChannel.triggerPhrase) else {
                return "step 3 does not end in the trigger constant"
            }
            let titled = IMessageConsentCopy.step4Body(agentName: "TestName")
            guard titled.contains("TestName") else {
                return "step 4 does not interpolate the runtime name"
            }
            return nil
        }

        var lines = failures.map { "IMESSAGE_CONSENT_WRONG: \($0)" }
        lines.append(failures.isEmpty
            ? "IMESSAGE_CONSENT_OK: \(caseCount) cases"
            : "IMESSAGE_CONSENT_FAILED: \(failures[0])")
        return lines.joined(separator: "\n")
    }
}
