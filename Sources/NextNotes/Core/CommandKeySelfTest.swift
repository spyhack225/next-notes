import CoreGraphics
import Foundation
import SwiftUI

/// `--selftest-commandkey` — the Command Mode key does nothing until it means something,
/// and says something the moment it does.
///
/// Four claims, and all four were false before:
///
/// 1. **A tap is not a hold, and a shortcut is not a hold.** The key Command Mode is bound
///    to is ⌘, so pressing it on its own or as part of ⌘C used to open the microphone
///    against whatever happened to be selected. `ModifierHoldGate` is the decision that
///    stops it, and it is pure state precisely so this can drive it: a keyboard, an event
///    tap and an Accessibility grant are all out of reach from a terminal. A shortcut is a
///    click or a scroll as often as it is a keystroke, and ⌘ is the hand that holds the
///    mouse — so the spoilers are checked as a set, not as "key-down".
/// 2. **The gate is wired to the key.** Every check on the gate itself passes whether or not
///    anything ever installs it, so the suite used to stay green with the feature reverted
///    to firing on key-down. `DictationController.arm(_:forCommandModeOn:)` gives that
///    wiring a name, and section 8b asserts what the name promises.
/// 3. **Nothing happens silently.** A hold that cannot start leaves a `CommandModeStatus`
///    behind — words, on a card of its own — and a message that outlives its hold does not
///    then narrate the next recording. A dictation that fails says so in words at the notch
///    rather than as an orb with the sentence thrown away.
/// 4. **The correction editor leaves room for its buttons**, at any length of dictation.
///
/// It fails if the gate ever reports a press for a tap, a chord or a ⌘-click; if a monitor
/// comes back from arming without a threshold, a cancel handler or the pointer events in its
/// mask; if a leftover Command Mode message claims an ordinary dictation; if any status or
/// failure card is missing its words; or if the editor box can grow without stopping.
@MainActor
enum CommandKeySelfTest {
    static func run() async -> Bool {
        var failures: [String] = []

        func check(_ what: String, _ ok: Bool) {
            if !ok { failures.append(what) }
        }

        // MARK: 1. Push-to-talk is untouched.

        var instant = ModifierHoldGate(requiresHold: false)
        check("push-to-talk presses on key-down", instant.modifierDown() == .press)
        check(
            "push-to-talk ignores other keys while held",
            instant.otherInput() == .nothing
        )
        check("push-to-talk releases on key-up", instant.modifierUp() == .release)

        // MARK: 2. A bare tap of the Command Mode key produces nothing at all.

        var tap = ModifierHoldGate(requiresHold: true)
        check("a tap raises nothing on key-down", tap.modifierDown() == .nothing)
        check("a tap raises nothing on key-up", tap.modifierUp() == .nothing)

        // MARK: 3. ⌘C is a shortcut, not a hold — before or after the threshold.

        var chord = ModifierHoldGate(requiresHold: true)
        _ = chord.modifierDown()
        check("a chord raises nothing when the other key lands", chord.otherInput() == .nothing)
        check("a spoiled hold cannot fire late", chord.holdElapsed() == .nothing)
        check("a spoiled hold raises nothing on key-up", chord.modifierUp() == .nothing)

        // MARK: 4. A real hold presses once and releases once.

        var held = ModifierHoldGate(requiresHold: true)
        _ = held.modifierDown()
        check("a hold presses when the threshold passes", held.holdElapsed() == .press)
        check("the threshold cannot press twice", held.holdElapsed() == .nothing)
        check("a hold releases on key-up", held.modifierUp() == .release)

        // MARK: 5. A shortcut struck *after* the hold started withdraws it, silently.

        var interrupted = ModifierHoldGate(requiresHold: true)
        _ = interrupted.modifierDown()
        check("the interrupted hold started", interrupted.holdElapsed() == .press)
        check("a later key cancels the hold", interrupted.otherInput() == .cancel)
        check("a cancelled hold does not also release", interrupted.modifierUp() == .nothing)

        // MARK: 5b. A click is a shortcut too, and so is a scroll.
        //
        // ⌘ lives under the right thumb, which is the hand on the mouse. ⌘-click to
        // multi-select in Finder, ⌘-click to open a link in a new tab and ⌘-scroll to zoom
        // all hold the key for as long as it takes to aim a pointer — far longer than the
        // threshold. While only key-downs were watched, each of those opened the microphone
        // and then replaced the user's selection in another app on release.

        for spoiler in ModifierHoldGate.spoilers {
            check("\(spoiler.rawValue) counts as a shortcut", ModifierHoldGate.spoils(spoiler))
        }
        for pointerEvent in [CGEventType.leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel] {
            check(
                "a mouse chord is watched for (\(pointerEvent.rawValue))",
                ModifierHoldGate.spoils(pointerEvent)
            )
        }
        check("the modifier's own event is not a shortcut", !ModifierHoldGate.spoils(.flagsChanged))
        // Out of range for the bit test, and the event that re-arms a tap the system killed.
        // Treating it as a shortcut would silently cancel a live hold; trapping on the shift
        // would take the process down.
        check(
            "a disabled tap is not mistaken for a shortcut",
            !ModifierHoldGate.spoils(.tapDisabledByTimeout)
        )

        // MARK: 6. Every status has words, and names the key in words.

        let key = PushToTalkKey.rightCommand
        let statuses: [CommandModeStatus] = [
            .listening, .rewriting, .needsSelection, .problem("The model is busy."),
        ]
        for status in statuses {
            check("\(status) has a title", !status.title.isEmpty)
            check("\(status) has a detail", !status.detail(key: key).isEmpty)
            check("\(status) has a glyph", !status.symbol.isEmpty)
        }
        check(
            "the listening card names the key in words",
            CommandModeStatus.listening.detail(key: key).contains("right Command key")
        )
        check(
            "the no-selection card says what to do",
            CommandModeStatus.needsSelection.detail(key: key).localizedCaseInsensitiveContains("highlight")
        )
        check("only listening claims the microphone", CommandModeStatus.listening.isCapturing)
        check("rewriting does not claim the microphone", !CommandModeStatus.rewriting.isCapturing)
        check("a message takes itself down", CommandModeStatus.needsSelection.lifetime != nil)
        check("a live state does not expire", CommandModeStatus.listening.lifetime == nil)

        // MARK: 7. Holding the key with nothing selected says so, and says it in the HUD.

        let controller = DictationController(
            formatter: RuleBasedFormatter(),
            makeEngine: { SelfTestEngine(shape: .prompt(delay: .zero)) },
            insert: { _, _ in .inserted },
            record: { _ in },
            // The branch that matters: the key was held properly and there is nothing to act on.
            captureSelection: { nil }
        )
        controller.beginCommandMode()

        check("something is said about the hold", controller.commandMode != nil)
        check("the heads-up display is handed to Command Mode", controller.commandModeOwnsHUD)
        // The old behaviour. `.error` is what the island draws as a dictation card with an
        // empty transcript, which is the wordless animation this whole change is about.
        check("the dictation error state is not used", controller.state == .idle)

        // Apple's on-device model may be missing on the machine this runs on, in which case
        // the honest answer is the unavailability message rather than "select some text".
        // Either is a pass; silence is not, and neither is an empty sentence.
        switch controller.commandMode {
        case .needsSelection:
            check(
                "the no-selection message is the selection one",
                FoundationModelCommandProcessor.isAvailable
            )
        case .problem(let message):
            check("the problem is explained", !message.isEmpty)
            check(
                "a problem is only reported when the model is missing",
                !FoundationModelCommandProcessor.isAvailable
            )
        default:
            failures.append("holding the key with no selection said the wrong thing")
        }

        // MARK: 8. The message takes itself down again.

        let lifetime = controller.commandMode?.lifetime ?? .seconds(4)
        let deadline = Date().addingTimeInterval(Double(lifetime.milliseconds) / 1000 + 3)
        while controller.commandMode != nil, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(100))
        }
        check("the message clears itself", controller.commandMode == nil)
        check("and hands the heads-up display back", !controller.commandModeOwnsHUD)

        // MARK: 8b. The gate is actually wired to the key.
        //
        // The single most important thing in this file, and the thing it could not see
        // before. Every section above drives `ModifierHoldGate` as pure logic, so deleting
        // the one line in `DictationController` that gives the monitor a hold threshold —
        // which restores the original key-down bug exactly — left the whole suite green.
        // Arming a throwaway monitor through the same function `activate()` uses is what
        // closes that: the wiring has a name, and this is what the name promises.

        let monitor = HotkeyMonitor()
        check("a fresh monitor is push-to-talk: instant", monitor.holdThreshold == nil)
        check("and asks only for modifier changes", !monitor.watchesChords)
        check(
            "push-to-talk does not watch the rest of the keyboard",
            monitor.eventMask & (CGEventMask(1) << CGEventType.keyDown.rawValue) == 0
        )

        controller.arm(monitor, forCommandModeOn: .rightCommand)
        check("arming picks the key", monitor.key == .rightCommand)
        check(
            "arming installs the hold threshold",
            monitor.holdThreshold == DictationController.commandHoldThreshold
        )
        check("a hold has somewhere to start", monitor.onPress != nil)
        check("a hold has somewhere to end", monitor.onRelease != nil)
        // Without this the gate can decide a hold was a shortcut and have nobody to tell.
        check("a withdrawn hold has somewhere to go", monitor.onCancel != nil)
        check("an armed monitor watches for shortcuts", monitor.watchesChords)
        for spoiler in ModifierHoldGate.spoilers {
            check(
                "the armed tap asks for \(spoiler.rawValue)",
                monitor.eventMask & (CGEventMask(1) << spoiler.rawValue) != 0
            )
        }
        check(
            "the threshold is long enough to outlast a shortcut",
            DictationController.commandHoldThreshold >= .milliseconds(250)
        )
        check(
            "and short enough not to feel dead",
            DictationController.commandHoldThreshold <= .milliseconds(700)
        )
        monitor.stop()

        // MARK: 8c. A message that outlived its hold does not narrate the next recording.
        //
        // "Select some text first" stays up for four seconds so it can be read. Every
        // surface used to take "a message exists" to mean "this hold is Command Mode", so an
        // ordinary dictation started inside those four seconds wore the Command Mode card,
        // disappeared from the notch, and on release announced that the user's selected text
        // was about to be replaced — none of which was true.

        check(
            "a message with nothing recording owns the display",
            DictationController.commandModeOwnsHUD(
                status: .needsSelection, isRecording: false, isCommandRecording: false
            )
        )
        check(
            "a leftover message does not own an ordinary dictation",
            !DictationController.commandModeOwnsHUD(
                status: .needsSelection, isRecording: true, isCommandRecording: false
            )
        )
        check(
            "a real Command Mode hold still owns the display",
            DictationController.commandModeOwnsHUD(
                status: .listening, isRecording: true, isCommandRecording: true
            )
        )
        check(
            "no message, no claim",
            !DictationController.commandModeOwnsHUD(
                status: nil, isRecording: true, isCommandRecording: true
            )
        )

        // And the same thing end to end on a real controller: raise the message, start an
        // ordinary dictation, and the message is gone before anything is drawn. Nothing is
        // awaited between the two calls, so the recording's own task never runs and no
        // microphone is opened; `deactivate()` unwinds it.
        if Settings.shared.compareMode {
            // Compare mode reaches into Wispr Flow on every button recording. Not something
            // to do from a self-test on somebody's machine.
            SelfTest.diagnostic("  skipped the live stale-message check: compare mode is on")
        } else {
            controller.beginCommandMode()
            check("there is a message to go stale", controller.commandMode != nil)
            controller.startButtonRecording()
            check("an ordinary dictation clears it", controller.commandMode == nil)
            check("and is not narrated by Command Mode", !controller.commandModeOwnsHUD)
            controller.deactivate()
        }

        // MARK: 8d. A failed dictation says what went wrong, at the notch.
        //
        // The other half of the report — "it shows an animation, I do not know what it is".
        // `fail()` sets `.error(message)` and clears the transcript on the next line, and the
        // island's only dictation state drew that as an orb with an empty caption. The
        // message had nowhere to go until `Kind.problem` existed.

        let failure = "No microphone audio reached dictation."
        let problem = IslandState.Kind.problem(failure)
        check(
            "a failed dictation is drawn as its words",
            IslandState.card(for: .error(failure), transcript: "", level: 0) == problem
        )
        check(
            "a live dictation is still drawn as one",
            IslandState.card(for: .listening, transcript: "hello", level: 0.4)
                == .dictating(transcript: "hello", level: 0.4, isCapturing: true)
        )
        check(
            "and the wait after the key comes up is not capturing",
            IslandState.card(for: .finishing, transcript: "hello", level: 0)
                == .dictating(transcript: "hello", level: 0, isCapturing: false)
        )
        check("a failure is not drawn as an orb", problem.orb == nil)
        check("a failure opens itself", problem.demandsAttention)
        check("two different failures are two different cards", problem.identity != IslandState.Kind.problem("other").identity)
        let island = IslandState()
        island.apply(problem)
        check("the failure card has a headline", !island.cardTitle.isEmpty)
        check("the island is showing it", island.kind == problem)

        // MARK: 9. The correction editor grows, stops, and leaves room for its buttons.

        let short = "Call Priya back."
        let long = String(repeating: "This is a long dictation that goes on for a while. ", count: 40)
        let shortBox = TranscriptEditorSheet.editorHeight(for: short)
        let longBox = TranscriptEditorSheet.editorHeight(for: long)
        check("a short transcript gets the minimum box", shortBox == TranscriptEditorSheet.minEditorHeight)
        check("a long transcript grows the box", longBox > shortBox)
        check("growth stops", longBox == TranscriptEditorSheet.maxEditorHeight)

        // The bug this replaced was a row that was measured once and then clipped what was
        // added to it. A sheet is laid out at its fitting size, so the check is that the
        // fitting size actually accounts for the editor *and* everything under it — and
        // that a dictation of any length cannot push it off a laptop screen.
        let sheet = TranscriptEditorSheet(original: long, onSave: { _ in }, onCancel: {})
        let host = NSHostingView(rootView: sheet)
        let fitting = host.fittingSize
        check("the editor sheet has a width", fitting.width >= TranscriptEditorSheet.width)
        check(
            "the sheet is taller than the editor inside it",
            fitting.height > TranscriptEditorSheet.maxEditorHeight + 40
        )
        check("the sheet still fits a laptop screen", fitting.height <= 560)
        SelfTest.diagnostic(
            "  editor box \(Int(shortBox))\u{2192}\(Int(longBox))pt, sheet "
                + "\(Int(fitting.width))x\(Int(fitting.height))pt"
        )

        for failure in failures {
            SelfTest.diagnostic("  COMMANDKEY_FAIL: \(failure)")
        }
        SelfTest.diagnostic(failures.isEmpty ? "COMMANDKEY_OK" : "COMMANDKEY_FAILED")
        return failures.isEmpty
    }
}
