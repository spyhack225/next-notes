import Foundation

/// Actual Library -> Live handoff -> isolated AgentSession and actual tool approval.
/// Playback uses the actual player with a substituted file transport/activity snapshot;
/// no speaker, microphone, model, account, notification or owner conversation is used.
@MainActor
enum CatchUpHandoffSelfTest {
    private final class Audio: CatchUpAudioPlaying {
        var duration: TimeInterval = 120
        var currentTime: TimeInterval = 17
        var isPlaying = false
        var starts = 0
        var pauses = 0
        func prepareToPlay() -> Bool { true }
        func play() -> Bool { starts += 1; isPlaying = true; return true }
        func pause() { pauses += 1; isPlaying = false }
        func stop() { isPlaying = false }
    }

    static func run() async -> [String] {
        var failures: [String] = []
        var checks = 0
        func expect(_ condition: Bool, _ message: String) {
            checks += 1
            if !condition { failures.append("handoff: " + message) }
        }
        let text = "Dana needs the launch reminder by noon. Want me to send the reminders?"
        let entry = CatchUpText.entry(id: "catchup-handoff-1", title: "Your morning catch-up",
                                     madeAt: Date(), text: text,
                                     audioURL: URL(fileURLWithPath: "/unused/catch-up.m4a"), duration: 120)!
        let session = AgentSession(fileURL: nil)
        var order: [String] = []
        var turns = 0
        let acting = LiveCatchUpOfferActing(session: session, open: { order.append("open") }, submit: { words in
            // This runs at the exact submission boundary, before the ordinary user row.
            let rows = session.currentSessionMessages
            expect(rows.last?.text == text && rows.last?.contextKind == AgentSession.backgroundTaskContextKind,
                   "catch-up was not recorded before the yes turn")
            order.append("recorded-before-turn")
            session.recordUser(words, source: .text)
            order.append("user")
            turns += 1
        })
        let suite = "NextNotesCatchUpHandoff-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else { return ["handoff: isolated preferences unavailable"] }
        defer { defaults.removePersistentDomain(forName: suite) }
        let routine = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let task = AgentTask(id: entry.id, objective: entry.title, source: AgentTask.scheduledSource,
                             createdAt: entry.madeAt, status: .completed, result: text, scheduleID: routine, finishedAt: entry.madeAt)
        let library = CatchUpLibrary(tasks: { [task] }, catchUpScheduleIDs: { [routine] },
                                     defaults: defaults, offers: acting)
        library.reload(announce: false)
        expect(session.messages.isEmpty, "reading the library delivered text or started a turn")
        expect(library.entries.map(\.id) == [entry.id], "scheduled fixture was not admitted to the library")
        if let offered = library.entries.first {
            library.acceptOffer(offered)
            library.acceptOffer(offered)
        }
        print("CATCH_UP_HANDOFF_OBSERVED roles=\(session.messages.map(\.role).joined(separator: ",")) background_rows=\(session.messages.filter { $0.contextKind == AgentSession.backgroundTaskContextKind }.count) turns=\(turns)")
        expect(turns == 1, "the offer did not submit exactly one ordinary turn")
        expect(order == ["open", "recorded-before-turn", "user"], "record/open/user order changed")
        expect(session.messages.map(\.role) == ["assistant", "user"], "context/user rows missing or out of order")
        expect(session.contextForCurrentTurn(scrubToolClaims: true).contains("Dana needs the launch reminder"),
               "the actual planner prompt consumer did not receive the antecedent")
        expect(session.chatHistoryForCurrentTurn(maxCharacters: 8_000, scrubToolClaims: true).contains {
            $0.content.contains("Dana needs the launch reminder")
        }, "the actual chat prompt consumer did not receive the antecedent")

        // Duplicate handoff/recreated producer retains one row, including after JSON readback.
        let repeatActing = LiveCatchUpOfferActing(session: session, open: {}, submit: { _ in })
        repeatActing.say(entry.offer!.yesText, for: entry)
        expect(session.messages.filter { $0.contextKind == AgentSession.backgroundTaskContextKind }.count == 1,
               "a repeated catch-up was recorded again")
        var distinct = entry
        distinct = CatchUpText.entry(id: "catchup-handoff-2", title: entry.title, madeAt: entry.madeAt,
                                    text: text, audioURL: nil, duration: nil)!
        repeatActing.say(distinct.offer!.yesText, for: distinct)
        expect(session.messages.filter { $0.contextKind == AgentSession.backgroundTaskContextKind }.count == 2,
               "distinct catch-ups with identical words were collapsed")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("NextNotesSelfTest-catchup-handoff-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("conversation.json")
        let saved = AgentSession(fileURL: url)
        LiveCatchUpOfferActing(session: saved, open: {}, submit: { _ in }).say(entry.offer!.yesText, for: entry)
        let fresh = AgentSession(fileURL: url)
        LiveCatchUpOfferActing(session: fresh, open: {}, submit: { _ in }).say(entry.offer!.yesText, for: entry)
        expect(fresh.messages.count == 1 && fresh.messages.first?.text == text,
               "fresh conversation reader duplicated or lost catch-up context")
        var clock = Date()
        let idle = AgentSession(fileURL: nil, now: { clock })
        let idleActing = LiveCatchUpOfferActing(session: idle, open: {}, submit: { words in idle.recordUser(words, source: .text) })
        idle.recordUser("Earlier question", source: .text)
        clock = clock.addingTimeInterval(31 * 60)
        idleActing.say(entry.offer!.yesText, for: entry)
        expect(idle.currentSessionMessages.map(\.role) == ["assistant", "user"],
               "idle session boundary orphaned the catch-up yes")

        failures += await approvalFailures(entry: entry)
        print("CATCH_UP_HANDOFF_CHECKS \(checks)")
        if failures.isEmpty { print("CATCH_UP_HANDOFF_OK") }
        else { for failure in failures { print("CATCH_UP_HANDOFF_CHECK_FAILED: \(failure)") }; print("CATCH_UP_HANDOFF_FAILED") }
        return failures + playbackFailures(entry: entry)
    }

    private static func approvalFailures(entry: CatchUpEntry) async -> [String] {
        guard PermissionGate.shared.pending == nil else { return ["handoff: approval gate was already occupied"] }
        let oldFake = AgentToolExecutor.fakeForTesting
        let oldFire = AgentToolExecutor.fireOverrideForTesting
        let oldPolicy = AgentToolExecutor.policyOverrideForTesting
        AgentToolExecutor.fakeForTesting = nil
        AgentToolExecutor.policyOverrideForTesting = .denyMutations
        var fired = 0
        AgentToolExecutor.fireOverrideForTesting = { _, _ in
            fired += 1
            return AgentToolResult(summary: "Sent fixture reminder", verification: "Fixture effect recorded")
        }
        defer {
            AgentToolExecutor.fakeForTesting = oldFake
            AgentToolExecutor.fireOverrideForTesting = oldFire
            AgentToolExecutor.policyOverrideForTesting = oldPolicy
        }
        var failures: [String] = []
        for approved in [false, true] {
            let session = AgentSession(fileURL: nil)
            var pendingJob: Task<AgentToolResult, Error>?
            // Scripted turn/model picks a send; registry, executor, broker and card are real.
            let acting = LiveCatchUpOfferActing(session: session, open: {}, submit: { words in
                session.recordUser(words, source: .text)
                pendingJob = Task { @MainActor in
                    try await AgentToolExecutor.run("send_email", arguments: ["to": "dana@fixture.invalid", "subject": "Launch", "body": "Please confirm by noon."],
                                                    policy: .denyMutations, promptIfNeeded: true, authority: .user)
                }
            })
            let before = fired
            acting.say(entry.offer!.yesText, for: entry)
            guard let job = pendingJob else {
                failures.append("handoff: yes did not reach scripted turn")
                continue
            }
            // Bound cooperative wait for actual presentation, never a fixed sleep.
            for _ in 0..<2_000 {
                if PermissionGate.shared.pending != nil { break }
                await Task.yield()
            }
            if fired != before { failures.append("handoff: irreversible backing ran before approval") }
            if let request = PermissionGate.shared.pending {
                if request.toolID != "send_email" { failures.append("handoff: approval card named a different action") }
                if approved {
                    // The fixture introduces a recipient the user has not vouched for.
                    // The SAME normal card must refuse that, then accept the real row confirmation.
                    let review = PermissionGate.shared.pendingReview
                    print("CATCH_UP_APPROVAL_BLOCKERS \(review?.blockers.map { $0.name + ":" + String(describing: $0.problem) }.joined(separator: ",") ?? "no-review")")
                    if review?.field("to")?.problem != .notConfirmed {
                        failures.append("handoff: unknown fixture recipient was not held for review")
                    }
                    if PermissionGate.shared.respond(id: request.id, approved: true) {
                        failures.append("handoff: unconfirmed recipient was approved")
                    }
                    ToolCallReviewStore.shared.confirm(id: request.id, field: "to")
                    if PermissionGate.shared.pendingReview?.isReadyToRun != true || fired != before {
                        failures.append("handoff: row confirmation sent early or did not ready the card")
                    }
                }
                if !PermissionGate.shared.respond(id: request.id, approved: approved) {
                    failures.append("handoff: actual card decision was refused")
                    job.cancel()
                }
            } else {
                failures.append("handoff: send never reached the actual approval card")
                job.cancel()
            }
            do {
                _ = try await job.value
                if !approved { failures.append("handoff: denied send reported success") }
            } catch {
                if approved { failures.append("handoff: approved fixture send failed: " + error.localizedDescription) }
            }
            print("CATCH_UP_APPROVAL_OBSERVED approved=\(approved) effects=\(fired - before)")
            if fired != before + (approved ? 1 : 0) {
                failures.append("handoff: backing count did not match exact card decision")
            }
        }
        print(failures.isEmpty ? "CATCH_UP_APPROVAL_OK" : "CATCH_UP_APPROVAL_FAILED")
        return failures
    }

    private static func playbackFailures(entry: CatchUpEntry) -> [String] {
        var failures: [String] = []
        var checks = 0
        func expect(_ condition: Bool, _ message: String) {
            checks += 1
            if !condition { failures.append("playback: " + message) }
        }
        let busy: [(String, CatchUpPlaybackActivity)] = [
            ("listening/working", .init(activationIdle: false)),
            ("dictation", .init(dictating: true)), ("meeting", .init(recording: true)),
            ("reply", .init(speaking: true)), ("call", .init(callActive: true)),
        ]
        for (name, state) in busy {
            var activity = state
            let audio = Audio()
            var opens = 0
            let player = CatchUpPlayer(activity: { activity }, makePlayer: { _ in opens += 1; return audio })
            expect(opens == 0 && audio.starts == 0, "initialization auto-played")
            player.play(entry)
            print("CATCH_UP_PLAYBACK_OBSERVED activity=\(name) file_opens=\(opens) starts=\(audio.starts) playing=\(player.isPlaying)")
            expect(opens == 0 && audio.starts == 0 && !player.isPlaying, "Play started during \(name)")
            expect(player.problem != nil, "blocked Play gave no explanation for \(name)")
            player.stop()
            activity = .init()
            player.play(entry)
            expect(player.isPlaying && audio.starts >= 1, "idle tap did not play")
            let starts = audio.starts
            activity = state
            player.pollPlayback() // SAME tick seam, with no wall-clock wait.
            expect(!player.isPlaying && !audio.isPlaying && player.playingID == entry.id,
                   "tick failed to preserve paused playback during \(name)")
            expect(player.elapsed == 17, "pause lost file position")
            player.toggle(entry)
            expect(!player.isPlaying && audio.starts == starts, "Resume started during \(name)")
            activity = .init()
            player.pollPlayback()
            expect(!player.isPlaying && audio.starts == starts, "idle tick auto-resumed")
            player.toggle(entry)
            expect(player.isPlaying && audio.starts == starts + 1, "idle tap did not resume")
            player.stop()
        }
        print("CATCH_UP_PLAYBACK_CHECKS \(checks)")
        if failures.isEmpty { print("CATCH_UP_PLAYBACK_OK") }
        else { for failure in failures { print("CATCH_UP_PLAYBACK_CHECK_FAILED: \(failure)") }; print("CATCH_UP_PLAYBACK_FAILED") }
        return failures
    }
}
