import AppKit
import Foundation

/// `--selftest-avatar` — the character's vocabulary, and the face it is drawn with.
///
/// Nothing here needs a screen, a grant or a model, and that is the point: the whole of the
/// avatar's *behaviour* is values — a generated config, a pose table, a mapping from what
/// the app is doing to what the character is doing — and the only part that cannot be
/// answered from a terminal is whether the drawing looks right. So this pins the parts a
/// person cannot check twice by looking: that a generated face round-trips through disk,
/// that the four animation layers actually compose, that no two states ever move the same
/// way, and that every activity the app can report lands on a state.
///
/// A red run here is not cosmetic. The avatar is the only thing on the island that says
/// *which* agent state is running once a run has more than one kind of step.
@MainActor
enum AgentAvatarSelfTest {
    static func run() -> Bool {
        print("AVATAR: the agent's character")
        var failures: [String] = []

        func expect(_ condition: Bool, _ message: String) {
            if condition {
                SelfTest.diagnostic("  ok   \(message)")
            } else {
                SelfTest.diagnostic("  FAIL \(message)")
                failures.append(message)
            }
        }

        // MARK: A generated face is a valid one

        let randomIsValid = (0..<400).allSatisfy { _ in
            let config = NotionAvatarConfig.random()
            return NotionAvatarConfig.Part.allCases.allSatisfy { part in
                let value = config[part]
                return value >= 0 && value <= part.maxIndex
            }
        }
        expect(randomIsValid, "400 generated faces stay inside every part's range")

        var clamped = NotionAvatarConfig.default
        clamped[.hair] = 9_999
        expect(clamped.hair == NotionAvatarConfig.Part.hair.maxIndex,
               "an index above a part's range clamps to its maximum")
        clamped[.hair] = -3
        expect(clamped.hair == 0, "an index below a part's range clamps to zero")

        // MARK: It survives a relaunch

        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "NextNotesAvatarSelfTest-\(ProcessInfo.processInfo.processIdentifier)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let store = AgentIdentityStore(directory: root)
        expect(store.name == AgentIdentityStore.defaultName,
               "a fresh install has an assistant and a face")
        let generated = NotionAvatarConfig.random()
        store.setAvatar(generated)
        store.setDisplayName("  Ada  ")

        let reloaded = AgentIdentityStore(directory: root)
        expect(reloaded.avatar == generated, "a generated face survives a relaunch")
        expect(reloaded.name == "Ada", "…and so does the name, trimmed")

        store.randomiseAvatar()
        expect(AgentIdentityStore(directory: root).avatar == store.avatar,
               "the welcome card's Generate button persists as it shuffles")

        // MARK: The four layers compose

        let side: CGFloat = 96
        if NotionAvatarRenderer.layers(for: .default, side: side) == nil {
            expect(NotionAvatarRenderer.partsDirectory() != nil,
                   "the vendored avatar parts are reachable — run from the app bundle or the repo")
        }
        if let layers = NotionAvatarRenderer.layers(for: .default, side: side) {
            let expected = CGSize(width: side, height: side)
            expect(layers.under.size == expected && layers.eyes.size == expected
                   && layers.brows.size == expected && layers.over.size == expected,
                   "all four animation layers rasterise at the asked-for size")
            expect(NotionAvatarRenderer.image(for: .default, side: side) != nil,
                   "the flattened face still renders for the editor's previews")
            expect(NotionAvatarRenderer.svgString(for: .default) != nil,
                   "the composite SVG still composes")
        }

        // MARK: No two states move the same way

        let samples: [Double] = [0, 0.37, 1.7, 3.1, 7.9, 23.4]
        var signatures: [AgentAvatarState: [String]] = [:]
        var allFinite = true
        var withinBounds = true
        for state in AgentAvatarState.allCases {
            var signature: [String] = []
            for time in samples {
                let pose = AgentAvatarChoreography.pose(state, at: time)
                allFinite = allFinite && Self.isFinite(pose)
                withinBounds = withinBounds && Self.isWithinBounds(pose)
                signature.append(String(
                    format: "%.3f/%.3f/%.3f/%.3f/%.3f/%.2f",
                    pose.tilt, pose.drift.width, pose.drift.height,
                    pose.gaze.width, pose.gaze.height, pose.blink
                ))
            }
            signatures[state] = signature
            expect(
                AgentAvatarChoreography.pose(state, at: 2.5)
                    == AgentAvatarChoreography.pose(state, at: 2.5),
                "\(state.rawValue) is deterministic at a fixed instant"
            )
        }
        expect(allFinite, "every state's pose is a finite number at every sampled instant")
        expect(withinBounds, "no state moves the head, eyes or brows past its bounds")
        let distinctSignatures = Set(AgentAvatarState.allCases.compactMap { signatures[$0]?.joined(separator: "|") })
        expect(distinctSignatures.count == AgentAvatarState.allCases.count,
               "no two states share a pose at any sampled instant")

        // MARK: The states a person would notice are wrong

        expect(AgentAvatarChoreography.pose(.sleeping, at: 5).blink == 1,
               "sleeping has the eyes shut")
        let awake = AgentAvatarState.allCases.filter { $0 != .sleeping }
        // A blink is `blinkDuration` long, so the sampling has to be finer than the lid —
        // a 0.1 s grid steps straight over it and reports a state that never blinks.
        let blinksWithinTwelveSeconds = awake.allSatisfy { state in
            (0..<600).contains { step in
                AgentAvatarChoreography.pose(state, at: Double(step) * 0.02).blink > 0.5
            }
        }
        expect(blinksWithinTwelveSeconds, "every awake state blinks inside twelve seconds")
        expect(awake.allSatisfy {
                   AgentAvatarChoreography.pose($0, at: AgentAvatarChoreography.stillFrame).blink < 0.2
               },
               "the frame Reduce Motion freezes on is not mid-blink")

        // MARK: Every gadget is a real one

        let props = AgentAvatarState.allCases.compactMap { AgentAvatarChoreography.prop($0) }
        expect(props.count == AgentAvatarState.allCases.count - 1,
               "every state but idle works with a gadget")
        expect(Set(props.map(\.rawValue)).count == props.count,
               "no two states share a gadget")
        let missingSymbols = AgentAvatarChoreography.Prop.allCases.filter {
            NSImage(systemSymbolName: $0.symbolName, accessibilityDescription: nil) == nil
        }
        expect(missingSymbols.isEmpty,
               "every gadget's symbol resolves on this macOS: \(missingSymbols.map(\.rawValue).joined(separator: ", "))")

        // MARK: The activity table

        expect(AgentAvatarState(activity: .thinking) == .thinking, "thinking is thinking")
        expect(AgentAvatarState(activity: .searching) == .browsing, "a search is browsing")
        expect(AgentAvatarState(activity: .reading) == .browsing, "a read is browsing")
        expect(AgentAvatarState(activity: .writing) == .writing, "a write is writing")
        expect(AgentAvatarState(activity: .executing) == .tool, "an execution is the tool state")
        expect(AgentAvatarState(activity: .waiting) == .waiting, "a wait is waiting")
        expect(AgentAvatarState(activity: .completed) == .done, "completion is done")

        // MARK: The tool table
        //
        // Risk first, namespace second — these are the four classes the island's agent
        // states are drawn from, and each one is a different picture.

        expect(AgentAvatarState.forTool(namespace: .browser, name: "snapshot", risk: .read) == .browsing,
               "reading a browser tab is browsing")
        expect(AgentAvatarState.forTool(namespace: .computer, name: "click", risk: .modify) == .tool,
               "clicking in another app is the tool state")
        expect(AgentAvatarState.forTool(namespace: .filesystem, name: "write", risk: .write) == .writing,
               "writing a file is writing")
        expect(AgentAvatarState.forTool(namespace: .shell, name: "run", risk: .modify) == .writing,
               "a command is the closest thing to writing code")
        expect(AgentAvatarState.forTool(namespace: .workspace, name: "send_email", risk: .send) == .sending,
               "anything sent in the user's name is sending")
        expect(AgentAvatarState.forTool(namespace: .schedule, name: "create", risk: .write) == .waiting,
               "a reminder is a thing about waiting")
        expect(AgentAvatarState.forTool(namespace: .knowledge, name: "search", risk: .read) == .browsing,
               "searching the user's own knowledge is browsing")
        expect(AgentAvatarState.forTool(namespace: .filesystem, name: "delete", risk: .destructive) == .tool,
               "a deletion is a change with an effect, not writing")
        expect(AgentAvatarState.forTool(namespace: .mcp, name: "install", risk: .privileged) == .tool,
               "an install is the tool state")
        expect(AgentAvatarState.forTool(namespace: .browser, name: "purchase", risk: .purchase) == .tool,
               "a purchase is not a message")

        // MARK: Sleep is a long quiet, not a pause

        expect(AgentAvatarState.resting(quietFor: 0, asleepAfter: 600) == .idle,
               "an avatar that just finished is awake")
        expect(AgentAvatarState.resting(quietFor: 599, asleepAfter: 600) == .idle,
               "…and stays awake for the whole threshold")
        expect(AgentAvatarState.resting(quietFor: 600, asleepAfter: 600) == .sleeping,
               "…and sleeps at it")

        // MARK: The tools report the state they put the character in

        let activities = AgentActivityStore.shared
        activities.resetForSelfTest()
        activities.update(taskID: "fixture", kind: .executing, title: "Running a command…")
        expect(activities.liveAvatarState == .tool,
               "a step the tool layer did not label falls back to its activity kind")
        activities.update(taskID: "fixture", kind: .searching,
                          title: "Opening a page…", avatar: .sending)
        expect(activities.liveAvatarState == .sending, "a labelled step wins over its kind")
        expect(activities.steps(taskID: "fixture").last?.avatar == .sending,
               "…and the step keeps it, so a working card shows its own run rather than the newest")
        activities.finish(taskID: "fixture", title: "Done")
        expect(activities.liveAvatarState == nil, "a finished run stops claiming a live state")
        activities.resetForSelfTest()

        // MARK: The island wears the character for the agent's own states — and only those

        let island = IslandState.shared
        island.apply(.agentListening(transcript: "", level: 0))
        expect(island.avatarState == .listening, "a listening island is a listening character")
        island.apply(.agentWorking(steps: ["Thinking…"], current: 1, total: 1))
        expect(island.avatarState == .thinking, "a run with no labelled step is thinking")
        island.apply(.agentProposal(IslandProposal(
            id: "fixture", title: "Send an email", detail: "To Marie", meetingID: nil
        )))
        expect(island.avatarState == .waiting, "a card waiting on an answer is waiting")
        island.apply(.agentReply("Hello"))
        expect(island.avatarState == .done, "a reply is the end of a run")
        island.apply(.dictating(transcript: "", level: 0, isCapturing: true))
        expect(island.avatarState == nil, "dictation keeps the orb — the character is the agent's")
        expect(island.kind.orb == .listening, "…and the orb still says what dictation is doing")
        island.apply(.hidden)
        expect(island.avatarConfig == AgentIdentityStore.shared.avatar,
               "the island reads the saved face rather than one of its own")

        if failures.isEmpty {
            SelfTest.diagnostic("AVATAR_OK")
            return true
        }
        SelfTest.diagnostic("AVATAR: \(failures.count) failed — \(failures.joined(separator: "; "))")
        SelfTest.diagnostic("AVATAR_FAILED")
        return false
    }

    // MARK: - Pose sanity

    private static func isFinite(_ pose: AgentAvatarChoreography.Pose) -> Bool {
        pose.tilt.isFinite
            && pose.drift.width.isFinite && pose.drift.height.isFinite
            && pose.gaze.width.isFinite && pose.gaze.height.isFinite
            && pose.blink.isFinite && pose.brow.isFinite && pose.phase.isFinite
    }

    /// What the table above may never exceed. Generous enough to tune within, tight enough
    /// that a runaway amplitude — a decimal point in the wrong place — fails here rather
    /// than shipping as a portrait that whips its head around.
    private static func isWithinBounds(_ pose: AgentAvatarChoreography.Pose) -> Bool {
        abs(pose.tilt) <= 6
            && abs(pose.drift.width) <= 0.03 && abs(pose.drift.height) <= 0.03
            && abs(pose.gaze.width) <= 0.03 && abs(pose.gaze.height) <= 0.03
            && pose.blink >= 0 && pose.blink <= 1
            && abs(pose.brow) <= 0.02
            && pose.phase >= 0 && pose.phase < 1
    }
}
