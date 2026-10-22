import AppKit
import SwiftUI

/// `--selftest-island`'s live-dictation half: the card that shows a hold's words as they
/// arrive, its stage label after key-up, and its going away once the words are typed.
///
/// The lifecycle is walked through `IslandState.card(for:…)` — the same pure function
/// `liveKind()` calls with the controller's real state — then applied to a real
/// `IslandState` and a real `IslandPanel`, because "the card opens" is a claim about
/// `isExpanded` and the panel's mouse handling, not about an enum.
///
/// `--island-sheet <dir>` additionally renders the dictation cards to PNGs through an
/// offscreen host, so the layout can be looked at on a machine with no Screen Recording
/// grant. The renders never order a window on screen.
@MainActor
enum IslandLiveTextSelfTest {
    static let sheetFlag = "--island-sheet"

    static func failures() async -> [String] {
        var failures: [String] = []
        func check(_ name: String, _ ok: Bool) {
            if !ok { failures.append("live dictation: \(name)") }
        }

        let words = "Let's move the design review to Thursday afternoon"
        let state = IslandState()

        // 1. Dictating with words: the live card opens by itself, wearing the listening orb.
        let live = IslandState.card(for: .listening, transcript: words, level: 0.5, isCapturing: true)
        state.apply(live)
        check("words while dictating open the card", state.isExpanded)
        check("the live card listens", live.orb == .listening)
        check("the live card says it is listening", state.cardTitle == "Listening\u{2026}")
        check("the live card never takes a click", !live.takesClicks)
        if case .dictating(let shown, _, true, false) = live {
            check("the live card carries the words as heard", shown == words)
        } else {
            check("the live card is a capturing dictation card", false)
        }

        // 2. Dictating with nothing heard yet: still a badge.
        for empty in ["", "   ", "\n"] {
            let quiet = IslandState.card(for: .listening, transcript: empty, level: 0.2, isCapturing: true)
            state.apply(quiet)
            check("a hold with no words stays collapsed (\(empty.debugDescription))", !state.isExpanded)
        }
        check("pre-roll capture is listening too",
              IslandState.card(for: .starting, transcript: words, level: 0.1, isCapturing: true).orb == .listening)

        // More words are the same card; the first words are a different one, because that
        // is what moves the panel's mouse handling and rectangle.
        check("more words are the same card",
              IslandState.Kind.dictating(transcript: "Let's", level: 0.1, isCapturing: true).identity
                == IslandState.Kind.dictating(transcript: words, level: 0.9, isCapturing: true).identity)
        check("the first words are a new card",
              IslandState.Kind.dictating(transcript: "", level: 0.1, isCapturing: true).identity
                != IslandState.Kind.dictating(transcript: "Let's", level: 0.1, isCapturing: true).identity)

        // 3. Key up: the raw words stay, under a plain stage label.
        let writing = IslandState.card(for: .finishing, transcript: words, level: 0, isCapturing: false)
        state.apply(writing)
        check("finishing keeps the card open", state.isExpanded)
        check("finishing says it is writing", state.cardTitle == "Writing it out\u{2026}")
        check("writing it out is work", writing.orb == .working)
        check("finishing keeps the raw words", {
            if case .dictating(let shown, _, false, false) = writing { return shown == words }
            return false
        }())
        check("finishing shows no red dot", {
            if case .dictating(_, _, let capturing, _) = writing { return !capturing }
            return false
        }())

        let tidying = IslandState.card(
            for: .finishing, transcript: words, level: 0, isCapturing: false, isTidying: true)
        state.apply(tidying)
        check("tidying keeps the card open", state.isExpanded)
        check("tidying says so", state.cardTitle == "Tidying up\u{2026}")
        check("tidying composes", tidying.orb == .composing)
        check("tidying is a different card from writing", tidying.identity != writing.identity)
        check("tidying keeps the raw words", {
            if case .dictating(let shown, _, _, true) = tidying { return shown == words }
            return false
        }())
        check("tidying cannot be claimed while the key is down",
              IslandState.card(for: .listening, transcript: words, level: 0.3,
                               isCapturing: true, isTidying: true).dictationStage == .listening)

        // 4. Inserted: the hold is over and the card goes.
        let inserted = IslandState.card(for: .idle, transcript: "", level: 0, isCapturing: false)
        state.apply(inserted)
        check("inserted words close the card", inserted == .hidden && !state.isExpanded)

        // A failure is still the problem card, with its button reachable.
        let problem = IslandState.card(for: .error("No microphone audio reached dictation."),
                                       transcript: "", level: 0, isCapturing: false)
        check("a failure is still the problem card", problem.dictationStage == nil && problem.takesClicks)

        // The island and the bottom capsule say the same thing at every stage.
        let pairs: [(DictationController.State, Bool, DictationController.FinishingStage, IslandState.Kind)] = [
            (.listening, true, .transcribing, live),
            (.finishing, false, .transcribing, writing),
            (.finishing, false, .tidying, tidying),
        ]
        for (controllerState, capturing, stage, kind) in pairs {
            check("the capsule and the island agree at \(kind.identity)",
                  LiveDictationStage.of(controllerState, isCapturing: capturing, finishing: stage)
                    == kind.dictationStage)
        }
        check("before the microphone opens the capsule is getting ready",
              LiveDictationStage.of(.starting, isCapturing: false, finishing: .transcribing) == .gettingReady)
        check("an idle hold has no stage",
              LiveDictationStage.of(.idle, isCapturing: false, finishing: .tidying) == nil)

        // The two-line tail keeps the newest words and opens on a whole word.
        let long = String(repeating: "one two three four five six seven eight nine ten ", count: 8)
            + "and the newest words land here"
        let tail = LiveDictationText.tail(long, limit: DS.LiveText.islandTailCharacters)
        check("a long hold keeps its newest words", tail.hasSuffix("and the newest words land here"))
        check("a long hold says it was shortened", tail.hasPrefix("\u{2026}"))
        check("a long hold fits its budget", tail.count <= DS.LiveText.islandTailCharacters + 1)
        check("a long hold opens on a whole word", {
            let first = tail.dropFirst().split(separator: " ").first.map(String.init) ?? ""
            return ["one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten"]
                .contains(first)
        }())
        check("a short hold is shown whole", LiveDictationText.tail(words, limit: 140) == words)

        // 5. The real panel: an open live card lets every click through and never takes
        // focus; the problem card that can follow it still takes its button's click.
        state.apply(live)
        let panel = IslandPanel(state: state)
        check("the open live card ignores the mouse", panel.ignoresMouseEvents)
        check("the island still cannot become key", !panel.canBecomeKey)
        state.apply(.problem("No microphone audio reached dictation."))
        try? await Task.sleep(for: .milliseconds(300))
        check("the problem card that follows takes clicks", !panel.ignoresMouseEvents)
        state.apply(.hidden)
        try? await Task.sleep(for: .milliseconds(300))
        check("a hidden island ignores the mouse", panel.ignoresMouseEvents)
        panel.orderOut(nil)

        if let directory = SelfTest.value(after: sheetFlag) {
            let written = writeSheet(to: URL(fileURLWithPath: directory))
            if written.isEmpty { failures.append("live dictation: no island sheet was written") }
            for path in written { SelfTest.diagnostic("  ISLAND_SHEET: \(path)") }
        }
        return failures
    }

    // MARK: - Offscreen renders

    /// One PNG per card, at both geometries. Offscreen: the hosting panel is never ordered
    /// in, so this needs no grant and takes no focus.
    static func writeSheet(to directory: URL) -> [String] {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // The built-in notch as `--selftest-island` measures it on the reference Mac.
        let menuBar: CGFloat = 37, notch: CGFloat = 208
        let notched = IslandGeometry.Metrics(
            bounds: NSRect(x: 0, y: 0, width: DS.Size.islandExpandedWidth,
                           height: menuBar + DS.Size.islandExpandedDrop),
            collapsedSize: CGSize(width: notch + 2 * DS.Size.islandFlank, height: menuBar),
            expandedSize: CGSize(width: DS.Size.islandExpandedWidth, height: menuBar + DS.Size.islandExpandedDrop),
            notchWidth: notch,
            hugsNotch: true
        )
        let floating = IslandGeometry.Metrics(
            bounds: NSRect(x: 0, y: 0, width: DS.Size.islandExpandedWidth,
                           height: DS.Size.islandCapsuleHeight + DS.Size.islandExpandedDrop),
            collapsedSize: CGSize(width: 2 * DS.Size.islandFlank, height: DS.Size.islandCapsuleHeight),
            expandedSize: CGSize(width: DS.Size.islandExpandedWidth,
                                 height: DS.Size.islandCapsuleHeight + DS.Size.islandExpandedDrop),
            notchWidth: 0,
            hugsNotch: false
        )
        let short = "Let's move the design review to Thursday"
        let long = "Let's move the design review to Thursday afternoon, and can you ask Maya to "
            + "bring the updated deck and the numbers from last quarter so we can decide on the "
            + "launch date before the end of the week"
        let cards: [(String, IslandState.Kind)] = [
            ("1-listening-no-words", .dictating(transcript: "", level: 0.4, isCapturing: true)),
            ("2-listening-short", .dictating(transcript: short, level: 0.6, isCapturing: true)),
            ("3-listening-long", .dictating(transcript: long, level: 0.5, isCapturing: true)),
            ("4-writing-it-out", .dictating(transcript: long, level: 0, isCapturing: false)),
            ("5-tidying-up", .dictating(transcript: long, level: 0, isCapturing: false, isTidying: true)),
        ]
        var written: [String] = []
        for (geometry, metrics) in [("notch", notched), ("floating", floating)] {
            for (name, kind) in cards {
                let state = IslandState()
                state.apply(kind)
                let view = IslandView(state: state, metrics: metrics)
                    // A muted backdrop so the light card's edge is visible in the PNG.
                    .background(DS.Color.groupedFill)
                guard let data = render(view, size: metrics.expandedSize) else { continue }
                let url = directory.appendingPathComponent("island-\(geometry)-\(name).png")
                if (try? data.write(to: url)) != nil { written.append(url.path) }
            }
        }
        return written
    }

    private static func render(_ view: some View, size: CGSize) -> Data? {
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        defer { panel.close() }
        let hosting = NSHostingView(rootView: view)
        hosting.safeAreaRegions = []
        hosting.frame = NSRect(origin: .zero, size: size)
        panel.contentView = hosting
        panel.layoutIfNeeded()
        hosting.layoutSubtreeIfNeeded()
        guard let representation = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { return nil }
        hosting.cacheDisplay(in: hosting.bounds, to: representation)
        return representation.representation(using: .png, properties: [:])
    }
}
