import Foundation
import Network

/// `--selftest-model-roles`.
///
/// Seven things are checked, and each of them can fail:
///
/// 1. **Fallback lands on the built-in model.** Every kind of choice is resolved against a
///    Mac that has nothing installed, and every one of them must come back as `.builtIn`
///    with a sentence a person could read. A resolution that kept an unavailable choice, or
///    landed anywhere other than the built-in model, fails the test — that is the whole
///    promise of the feature.
/// 2. **A choice that *is* available is not tampered with.** Without this the first check
///    would pass on a resolver that returned `.builtIn` unconditionally.
/// 3. **A job is only given what it can carry out**, and an ordinary question is not
///    mistaken for a request to drive the Mac. Both of these were showing a person a green
///    dot, or an online model, for something else entirely.
/// 4. **The call paths follow the rows.** The model a turn is answered with and the place a
///    coding turn runs are both asked for here, so reverting the wiring and leaving only the
///    settings screen fails the test rather than passing it.
/// 5. **Discovery.** A real HTTP server is started on loopback, answers `/v1/models` and
///    `/api/tags` the way LM Studio and Ollama do, and must be found and parsed. Then it is
///    stopped and the same probe must report "not running" rather than hanging or throwing.
/// 6. **(P0-03) A role resolves only to a model that can answer**, a stored role pointed at
///    a draft head is repaired once at launch with one notice, and the agent publishes the
///    model that actually answered the last turn.
/// 7. **(P1-12) Codex's allowance is remembered, and the fallback follows the Agent.** The
///    date is parsed out of the sentence Codex actually wrote, the window expires on its own
///    and is announced once with no link and no error code, a turn that stays here answers
///    with the model the person chose for the Agent, and a remembered window starts no
///    hand-off at all — in both states the readiness snapshot can be in.
@MainActor
enum ModelRoleSelfTest {
    static func run() async -> [String] {
        var failures: [String] = []
        failures += tokenRoundTrip()
        failures += providerIdentity()
        failures += fallbackToBuiltIn()
        failures += honoursWhatIsThere()
        failures += whatEachJobCanUse()
        failures += greenOnlyWhenItWouldWork()
        failures += whichJobARequestBelongsTo()
        failures += await callPathsFollowTheRoles()
        failures += await answerableOnly()
        failures += await launchRepair()
        failures += await answeringModelIsPublished()
        failures += addressNormalisation()
        failures += toolCallBridging()
        failures += await discovery()
        failures += multiStepRoutesToCloud()
        failures += slowWarningPresent()
        failures += await codexQuotaWindow()
        return failures
    }

    // MARK: - P1-3 Long plans leave the on-device model

    /// A ≥3-step request routes to cloud when configured and consented, and to the
    /// honest slow warning when not. Consent off and key missing both stay local.
    private static func multiStepRoutesToCloud() -> [String] {
        var failures: [String] = []
        let multi = "Find tonight's showing and then book two seats after checking the price"
        if !ModelRoleStore.likelyMultiStep(multi) {
            failures.append("a multi-step request was not recognised as one: “\(multi)”")
        }
        if ModelRoleStore.role(forUtterance: multi) != .agent {
            failures.append("a multi-step request was routed away from the everyday assistant")
        }
        if ModelRoleStore.likelyMultiStep("open Safari") {
            failures.append("a single app request was read as a multi-step plan")
        }
        // Two verbs and a sequencer, but the shortcut already answers it with no model
        // round — it must never be sent online for being long.
        if ModelRoleStore.likelyMultiStep("open Chrome and then go to youtube.com") {
            failures.append("a direct-intent request was read as a multi-step plan")
        }
        let cloud = ModelRoleStore.multiStepRoute(
            for: multi, role: .agent, cloudReady: true, cloudConsent: true)
        if cloud != .cloud {
            failures.append("a consented multi-step plan did not route to cloud (got \(cloud))")
        }
        let noConsent = ModelRoleStore.multiStepRoute(
            for: multi, role: .agent, cloudReady: true, cloudConsent: false)
        if noConsent != .localWithWarning {
            failures.append("a multi-step plan without consent left the slow path (got \(noConsent))")
        }
        let noKey = ModelRoleStore.multiStepRoute(
            for: multi, role: .agent, cloudReady: false, cloudConsent: true)
        if noKey != .localWithWarning {
            failures.append("a multi-step plan without an online model left the slow path (got \(noKey))")
        }
        let single = ModelRoleStore.multiStepRoute(
            for: "open Safari", role: .agent, cloudReady: true, cloudConsent: true)
        if single != .local {
            failures.append("a single-step request took the multi-step route (got \(single))")
        }
        let driving = ModelRoleStore.multiStepRoute(
            for: multi, role: .computerUse, cloudReady: true, cloudConsent: true)
        if driving == .cloud {
            failures.append("a computer-use request took the agent cloud route")
        }
        failures += multiStepNoticeTable()
        return failures
    }

    /// P0-22: the sentence a multi-step turn opens with has to name the model that actually
    /// answers it, and may not promise a duration. Four cases, each red on today's forwarder
    /// in `MultiStepNotices.notice`:
    ///
    /// - **a.** an online answer names "Ling", says "online", and never says "minute",
    ///   "slower" or "faster" — today's names the configured account instead and says
    ///   "slower";
    /// - **b.** the online sentence is said once per session, not once per turn — today's
    ///   has no flag and says it every time;
    /// - **c.** on this Mac the sentence is exactly "This takes a few steps on this Mac.",
    ///   and a single-step request carries nothing — today's promises "a few minutes";
    /// - **d.** a spoken turn never carries the notice — today's voice path still emits the
    ///   slow warning.
    private static func multiStepNoticeTable() -> [String] {
        var failures: [String] = []

        // (a) Online: the answering model is named and no speed or duration is promised.
        MultiStepNotices.resetForTesting()
        let online = MultiStepNotices.notice(
            providerID: .openRouter, modelName: "Ling", likelyMultiStep: true, voice: false
        )
        if let online {
            if !online.contains("Ling") {
                failures.append("the online notice does not name the model that answers: \(online)")
            }
            if !online.lowercased().contains("online") {
                failures.append("the online notice does not say the turn goes online: \(online)")
            }
            for banned in ["minute", "slower", "faster"] where online.lowercased().contains(banned) {
                failures.append("the online notice promises “\(banned)”: \(online)")
            }
        } else {
            failures.append("an online model answered without saying the words leave this Mac")
        }

        // (b) Once per session, not once per turn.
        MultiStepNotices.resetForTesting()
        _ = MultiStepNotices.notice(
            providerID: .openRouter, modelName: "Ling", likelyMultiStep: true, voice: false)
        if MultiStepNotices.notice(
            providerID: .openRouter, modelName: "Ling", likelyMultiStep: true, voice: false
        ) != nil {
            failures.append("the online notice appeared more than once in a session")
        }

        // (c) On this Mac, one sentence — and only for a request that takes several steps.
        MultiStepNotices.resetForTesting()
        let local = MultiStepNotices.notice(
            providerID: .appLLM, modelName: "Qwen3-4B", likelyMultiStep: true, voice: false
        )
        if local != "This takes a few steps on this Mac." {
            failures.append("the local multi-step notice reads “\(local ?? "nothing")”")
        }
        MultiStepNotices.resetForTesting()
        if MultiStepNotices.notice(
            providerID: .appLLM, modelName: "Qwen3-4B", likelyMultiStep: false, voice: false
        ) != nil {
            failures.append("a single-step request carried a multi-step notice")
        }

        // (d) The spoken path never carries this notice, whatever model answers.
        for provider in LLMProviderID.allCases + [.localServer] {
            MultiStepNotices.resetForTesting()
            if MultiStepNotices.notice(
                providerID: provider, modelName: "Ling", likelyMultiStep: true, voice: true
            ) != nil {
                failures.append("a spoken turn carried a multi-step notice from \(provider.rawValue)")
            }
        }
        MultiStepNotices.resetForTesting()
        return failures
    }

    /// One honest sentence, once per session, in words a person would use — never a
    /// tool id or a plan, and never a promised duration. The online notice names the
    /// model that answers and says the words leave this Mac.
    ///
    /// P0-22 replaced the two forwarders this used to drive (`slowWarningIfNeeded`,
    /// `cloudSlowNotice`) with the single `notice(…)`, so it drives that directly.
    private static func slowWarningPresent() -> [String] {
        var failures: [String] = []
        MultiStepNotices.resetForTesting()
        defer { MultiStepNotices.resetForTesting() }
        guard let first = MultiStepNotices.notice(
            providerID: .appLLM, modelName: "Qwen3-4B", likelyMultiStep: true, voice: false
        ) else {
            return ["the slow-plan warning never appeared"]
        }
        if MultiStepNotices.notice(
            providerID: .appLLM, modelName: "Qwen3-4B", likelyMultiStep: true, voice: false
        ) != nil {
            failures.append("the slow-plan warning appeared more than once in a session")
        }
        for id in ["computer.", "filesystem.", "browser.", "<tool_call>", "tool plan"] {
            if first.contains(id) {
                failures.append("the slow-plan warning reads like a log line (\(id)): \(first)")
            }
        }
        if first.isEmpty {
            failures.append("the slow-plan warning was empty")
        }
        let notice = MultiStepNotices.notice(
            providerID: .openRouter, modelName: "Ling", likelyMultiStep: true, voice: false) ?? ""
        if !notice.contains("Ling") {
            failures.append("the online notice does not name the model that answers: \(notice)")
        }
        let lowered = notice.lowercased()
        if !lowered.contains("online") || !lowered.contains("leaves your mac") {
            failures.append("the online notice does not say the words leave this Mac: \(notice)")
        }
        for banned in ["minute", "second", "slower", "faster"] where lowered.contains(banned) {
            failures.append("the online notice promises “\(banned)”: \(notice)")
        }
        return failures
    }

    // MARK: - P1-12 Codex's allowance, and the fallback that follows the Agent

    /// The exact sentence Codex wrote on 2026-09-23 at 22:06, read out of this Mac's own
    /// `agent-audit.jsonl`. Copied whole — apostrophe, link, ordinal and all — because a
    /// parser written against a paraphrase proves nothing about the parser.
    private static let capturedQuotaOutput =
        "ERROR: You\u{2019}ve hit your usage limit. "
        + "Visit https://chatgpt.com/codex/settings/usage to purchase more credits "
        + "or try again at Sep 26th, 2026 3:43 PM."

    /// The same failure with a window that cannot pass during a test run, for the cases that
    /// need the shared store rather than an isolated one with an injected clock.
    private static let farFutureQuotaOutput =
        "ERROR: You\u{2019}ve hit your usage limit. "
        + "Visit https://chatgpt.com/codex/settings/usage to purchase more credits "
        + "or try again at Dec 31st, 2099 11:59 PM."

    /// Four things, each of which was wrong on 2026-09-23:
    ///
    /// **a.** the date is read out of the sentence Codex actually wrote, a usage-limit
    /// sentence with no date in it is still a quota failure, and an ordinary failure is not;
    /// **b.** the window is remembered, expires on its own, and is announced once — with a
    /// sentence carrying no link and no error code;
    /// **c.** a turn that stays here answers with the model the person chose for the Agent
    /// rather than with whichever file the library points at;
    /// **d.** a remembered quota runs no hand-off at all, says so once, and is silent for
    /// the rest of the window.
    ///
    /// Four functions rather than one, and none of them can return early past another: the
    /// first version had (a) bail out into a helper that ran only (c) and (d), so a run
    /// where the parser was broken never reached (b) and could not show it was red either.
    private static func codexQuotaWindow() async -> [String] {
        var failures: [String] = []
        failures += quotaParseTable()
        failures += quotaStoreWindow()
        failures += await codexFallbackFollowsTheAgent()
        failures += await rememberedQuotaRunsNoHandOff()
        return failures
    }

    /// The two fixed moments every case shares: 3:00 on the morning Codex's sentence was
    /// captured, and the 3:43 PM it named. Read once so (a) and (b) cannot disagree about
    /// them, and so a failure names a real moment rather than "nil".
    private static func quotaFixtureClock() -> (morning: Date, reset: Date)? {
        let calendar = Calendar.current
        guard let morning = calendar.date(
            from: DateComponents(year: 2026, month: 9, day: 26, hour: 3)),
            let reset = calendar.date(
                from: DateComponents(year: 2026, month: 9, day: 26, hour: 15, minute: 43))
        else { return nil }
        return (morning, reset)
    }

    /// **(a)** The parse table, against the captured text and the shapes around it. Pure, so
    /// it needs nothing installed and nothing running.
    private static func quotaParseTable() -> [String] {
        var failures: [String] = []
        let calendar = Calendar.current
        guard let clock = quotaFixtureClock() else {
            return [wrong("a", "the fixed clock for the quota fixture could not be built")]
        }
        let (morning, reset) = clock

        let captured = CodexQuotaStore.parseUsageLimit(
            capturedQuotaOutput, now: morning, calendar: calendar)
        if let capturedDate = captured ?? nil, capturedDate != reset {
            failures.append(wrong(
                "a", "the reset time was read as \(describe(capturedDate)) rather than "
                    + "\(describe(reset))"))
        } else if captured == nil {
            failures.append(wrong(
                "a", "the sentence Codex actually wrote was not read as a usage limit"))
        }
        switch CodexQuotaStore.parseUsageLimit(
            "You\u{2019}ve hit your usage limit.", now: morning, calendar: calendar)
        {
        case .some(.some(let date)):
            failures.append(wrong("a", "a usage limit with no date in it invented one: \(date)"))
        case .some(nil):
            break
        case nil:
            failures.append(wrong("a", "a usage limit with no date in it was not recognised"))
        }
        if CodexQuotaStore.parseUsageLimit(
            "Codex couldn\u{2019}t find Safari", now: morning, calendar: calendar) != nil {
            failures.append(wrong("a", "an ordinary failure was read as a usage limit"))
        }
        // A different way of saying it, because the CLI's wording is not a contract.
        if CodexQuotaStore.parseUsageLimit(
            "You have hit your limit and resets at Sep 26th, 2026 3:43 PM.",
            now: morning, calendar: calendar
        ) ?? nil != reset {
            failures.append(wrong("a", "“hit your limit … resets at” was not read as a quota window"))
        }
        return failures
    }

    /// **(b)** The store itself, on an isolated suite and a clock the test moves. Three
    /// things in one place: the window is remembered as the moment Codex named, it closes
    /// by itself, and the sentence is said once per window with no link and no error code in
    /// it. A failure that is not a quota must leave nothing behind.
    private static func quotaStoreWindow() -> [String] {
        var failures: [String] = []
        guard let clock = quotaFixtureClock() else {
            return [wrong("b", "the fixed clock for the quota fixture could not be built")]
        }
        let (morning, reset) = clock
        guard let isolated = isolatedDefaults(tag: "codex-quota") else {
            return [wrong("b", "the isolated defaults suite could not be created")]
        }
        defer { isolated.defaults.removePersistentDomain(forName: isolated.domain) }
        let now = MovableClock(morning)
        let store = CodexQuotaStore(defaults: isolated.defaults, now: { now.now })

        if !store.recordFailure(output: capturedQuotaOutput) {
            failures.append(wrong("b", "the captured quota sentence was not recognised"))
        }
        if let remembered = store.exhaustedUntil {
            if remembered != reset {
                failures.append(wrong(
                    "b", "the window was remembered as \(describe(remembered)) rather than "
                        + "\(describe(reset))"))
            }
        } else {
            failures.append(wrong("b", "a quota failure left no remembered window"))
        }
        now.now = reset.addingTimeInterval(1)
        if store.exhaustedUntil != nil {
            failures.append(wrong("b", "the window was still open after the moment it named"))
        }
        if store.announcementIfNew() != nil {
            failures.append(wrong("b", "an expired window still announced itself"))
        }

        now.now = morning
        guard let first = store.announcementIfNew() else {
            return failures + [wrong("b", "the first request in a window said nothing")]
        }
        if store.announcementIfNew() != nil {
            failures.append(wrong("b", "the same window announced itself twice"))
        }
        if first.contains("http") || first.contains("ERROR") {
            failures.append(wrong("b", "the sentence carries Codex's own output: \(first)"))
        }
        if !first.contains(CodexQuotaStore.resetPhrase(reset)) {
            failures.append(wrong("b", "the sentence does not say when Codex is back: \(first)"))
        }
        // A second, later window is a new fact and gets its own sentence.
        now.now = reset
        if !store.recordFailure(output: farFutureQuotaOutput) {
            failures.append(wrong("b", "a second quota failure was not recognised"))
        }
        guard let second = store.announcementIfNew() else {
            return failures + [wrong("b", "a new window did not announce itself")]
        }
        if second == first {
            failures.append(wrong("b", "a new window repeated the previous window's sentence"))
        }
        // Only "Try Codex again" and a pass window clear the memory.
        store.clear()
        if store.exhaustedUntil != nil {
            failures.append(wrong("b", "clearing the store left the window open"))
        }
        let quiet = CodexQuotaStore(defaults: isolated.defaults, now: { now.now })
        if quiet.recordFailure(output: "ERROR: the model could not be loaded.") {
            failures.append(wrong("b", "a failure that was not a quota was remembered as one"))
        }
        if quiet.exhaustedUntil != nil {
            failures.append(wrong("b", "a non-quota failure left a window behind"))
        }
        return failures
    }

    /// **(c)** A role pointed at an agent app is not a model, so a turn that stays here
    /// answers with the one the person chose for the Agent.
    ///
    /// The Agent role is pointed at a **loopback server this test starts**, and that is the
    /// whole point of the fixture. The obvious fixture — Apple's model against the built-in
    /// file — cannot tell the two apart on this Mac: under the harness the built-in model is
    /// not runnable, `LLMProviders.resolve(preferring: .appLLM)` walks on to Apple's, and both
    /// branches answer with the same provider. A test that passes for that reason is a green
    /// answer to a question nobody asked. A local server is a third thing the walk cannot
    /// reach, so the assertion is about the branch rather than about this machine's models.
    private static func codexFallbackFollowsTheAgent() async -> [String] {
        var failures: [String] = []
        guard let isolated = isolatedDefaults(tag: "codex-fallback") else {
            return [wrong("c", "the isolated defaults suite could not be created")]
        }
        defer { isolated.defaults.removePersistentDomain(forName: isolated.domain) }
        guard let server = FixtureServer(), let port = await server.start(),
              let base = URL(string: "http://127.0.0.1:\(port)/v1")
        else {
            return [wrong("c", "the fixture server for the Agent role could not be started")]
        }
        defer { Task { await server.stop() } }

        var availability = ModelRoleAvailability()
        availability.builtInModelReady = true
        availability.appleFoundationReady = true
        availability.installedApps = [.claude, .codex]
        // Codex is installed and signed in but cannot drive the screen, so the row falls
        // back — which is the state a person meets every time the allowance runs out.
        availability.codexComputerUse = .helperMissing
        let address = base.absoluteString
        let store = ModelRoleStore(
            defaults: isolated.defaults,
            catalog: LocalRuntimeCatalog(customAddresses: [address]),
            availability: availability,
            failures: ModelOpenFailureStore(defaults: isolated.defaults))
        store.setChoiceForTesting(.app(.codex), for: .computerUse)
        store.setChoiceForTesting(
            .localServer(endpointID: address, modelID: "qwen2.5-7b-instruct"), for: .agent)

        let computerUse = await store.provider(for: .computerUse)
        let agent = await store.provider(for: .agent)
        // Always printed, so a run says which two models it actually compared — a green run
        // on a Mac where the two coincide must not read as a leg that was checked.
        SelfTest.diagnostic(
            "MODEL_ROLES_CODEX_FALLBACK: agent=\(agent?.id.rawValue ?? "none") "
                + "computerUse=\(computerUse?.id.rawValue ?? "none")")
        if agent?.id != .localServer {
            failures.append(wrong(
                "c", "the Agent role answered the fixture with \(describe(agent?.id)), so this "
                    + "case cannot tell the two branches apart"))
        }
        if computerUse?.id != agent?.id {
            failures.append(wrong(
                "c", "a turn that stayed here answered with \(describe(computerUse?.id)) "
                    + "while the Agent role answers with \(describe(agent?.id))"))
        }
        // The point of the change, stated so a Mac where the two happen to agree still
        // fails a resolver that went back to the built-in model: if the Agent role does not
        // answer with the app's own file, neither may the fallback.
        if let agentID = agent?.id, agentID != .appLLM, computerUse?.id == .appLLM {
            failures.append(wrong(
                "c", "the fallback used the app's own model while the Agent role is on "
                    + "\(agentID.rawValue)"))
        }
        // The Assistant's own choice is untouched by any of this.
        if await store.provider(for: .agent)?.id != agent?.id {
            failures.append(wrong("c", "resolving the computer-use role changed the Agent role"))
        }
        return failures
    }

    /// **(d)** A remembered quota starts no hand-off, asks nobody, and says so once. The
    /// counter is what makes "no hand-off" a measurement rather than an inference: it sits
    /// above `CodexComputerUse.probe`, so it counts a decision on a Mac with no Codex at
    /// all. `runOverrideForTesting` stands in for the launch, so the test neither needs nor
    /// runs the real CLI.
    ///
    /// Twice, once for each state the store's readiness snapshot can be in, because the two
    /// are different turns of a real session. The turn right after the failure still sees
    /// the old `.ready`; the next launch, or opening Settings, refreshes the probe and sees
    /// `.outOfQuota`. Both must announce the window and start nothing — a guard that asked
    /// the live question first answered the first turn and went silent on every one after
    /// it, which is the way this was shipped for one revision of this file.
    private static func rememberedQuotaRunsNoHandOff() async -> [String] {
        let roles = ModelRoleStore.shared
        let storedChoices = roles.snapshotChoicesForTesting()
        let storedAvailability = roles.availability
        let previousOverride = CodexComputerUse.runOverrideForTesting
        let previousCount = CodexComputerUse.handOffsForTesting
        let store = CodexQuotaStore.shared
        roles.setChoiceForTesting(.app(.codex), for: .computerUse)
        CodexComputerUse.runOverrideForTesting = { objective in
            throw CodexComputerUse.HandoffError.couldNotStart(objective)
        }
        defer {
            roles.restoreChoicesForTesting(storedChoices)
            roles.overrideAvailabilityForTesting(storedAvailability)
            CodexComputerUse.runOverrideForTesting = previousOverride
            CodexComputerUse.handOffsForTesting = previousCount
            store.clear()
        }
        if roles.computerUseChosenHarness != .codex {
            return [wrong("d", "the fixture did not point the computer-use role at Codex")]
        }
        var failures: [String] = []
        for snapshot in [CodexComputerUseReadiness.ready, .outOfQuota] {
            failures += await oneQuotaWindow(snapshot: snapshot)
        }
        // And the dot the Settings row draws has to agree with the turn: a window that is
        // open makes the row grey rather than promising a hand-off that will not happen.
        _ = store.recordFailure(output: farFutureQuotaOutput)
        if CodexComputerUse.probe().isReady {
            failures.append(wrong(
                "d", "the probe still reported ready with Codex's allowance used up"))
        }
        store.clear()
        if CodexComputerUse.probe() == .outOfQuota {
            failures.append(wrong("d", "the probe still reported out of allowance after a reset"))
        }
        return failures
    }

    /// One window, one pair of turns, against one state of the readiness snapshot.
    private static func oneQuotaWindow(
        snapshot: CodexComputerUseReadiness
    ) async -> [String] {
        var failures: [String] = []
        let roles = ModelRoleStore.shared
        var availability = roles.availability
        availability.codexComputerUse = snapshot
        roles.overrideAvailabilityForTesting(availability)
        let store = CodexQuotaStore.shared
        store.clear()
        CodexComputerUse.handOffsForTesting = 0

        if !store.recordFailure(output: farFutureQuotaOutput) {
            failures.append(wrong("d", "the shared store did not recognise a quota failure"))
        }
        guard let until = store.exhaustedUntil else {
            return failures + [wrong("d", "the shared store kept no window to fall back from")]
        }
        let expected = CodexQuotaStore.turnSentence(until: until)
        let where_ = "with the readiness snapshot at \(snapshot.rawValue)"

        let first = await CodexComputerUse.route("open chrome")
        if CodexComputerUse.handOffsForTesting != 0 {
            failures.append(wrong(
                "d", "a remembered quota still started \(CodexComputerUse.handOffsForTesting) "
                    + "hand-off(s) \(where_)"))
        }
        if first != .fellBack(expected) {
            failures.append(wrong("d", "the first turn said \(describe(first)) \(where_)"))
        }
        if let first, case .fellBack(let note) = first,
           note.contains("http") || note.contains("ERROR") {
            failures.append(wrong("d", "the turn carried Codex's own output \(where_): \(note)"))
        }
        // The rest of the window is silent, which is the other half of "once per window".
        let second = await CodexComputerUse.route("open chrome")
        if second != nil {
            failures.append(wrong(
                "d", "a later turn in the same window said \(describe(second)) \(where_)"))
        }
        if CodexComputerUse.handOffsForTesting != 0 {
            failures.append(wrong(
                "d", "a remembered quota still started \(CodexComputerUse.handOffsForTesting) "
                    + "hand-off(s) across two turns \(where_)"))
        }
        store.clear()
        return failures
    }

    /// The one marker a P1-12 case prints, so a failing run names which of the four it was.
    private static func wrong(_ letter: String, _ reason: String) -> String {
        let line = "MODEL_ROLES_WRONG: \(letter) — \(reason)"
        SelfTest.diagnostic(line)
        return "P1-12 case \(letter): \(reason)"
    }

    private static func describe(_ date: Date?) -> String {
        guard let date else { return "nothing" }
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    private static func describe(_ outcome: CodexComputerUse.Outcome?) -> String {
        switch outcome {
        case .none: "nothing at all"
        case .some(.done(let reply)): "Codex’s own answer (“\(reply)”)"
        case .some(.fellBack(let note)): "“\(note)”"
        }
    }

    private static func describe(_ id: LLMProviderID?) -> String {
        guard let id else { return "nothing" }
        return id.rawValue
    }

    // MARK: - 0. The stored form survives a round trip

    private static func tokenRoundTrip() -> [String] {
        var failures: [String] = []
        let samples: [ModelRoleChoice] = [
            .builtIn,
            .appleFoundation,
            .installedModel(id: "bartowski/Qwen3-8B-GGUF/Qwen3-8B-Q4_K_M.gguf"),
            .localServer(endpointID: "ollama", modelID: "llama3.2:3b"),
            .cloud,
            .app(.claude),
        ]
        for sample in samples {
            guard let back = ModelRoleChoice(token: sample.token) else {
                failures.append("token “\(sample.token)” did not read back at all")
                continue
            }
            if back != sample { failures.append("token “\(sample.token)” read back as \(back.token)") }
        }
        if ModelRoleChoice(token: "something-a-later-build-wrote") != nil {
            failures.append("an unknown token was accepted instead of falling back to the default")
        }
        if ModelRoleChoice(token: "app:local") != nil {
            failures.append("“local tools” was accepted as an agent app choice")
        }
        // The defaults the product asks for, checked as data rather than prose.
        if ModelRoleStore.defaultChoice(for: .agent) != .builtIn {
            failures.append("the everyday assistant does not default to the built-in model")
        }
        if ModelRoleStore.defaultChoice(for: .computerUse) != .app(.codex) {
            failures.append("controlling the Mac does not default to Codex")
        }
        if ModelRoleStore.defaultChoice(for: .coding) != .app(.claude) {
            failures.append("writing code does not default to Claude Code")
        }
        return failures
    }

    // MARK: - 0b. The provider identity follows the model on this Mac

    /// The two drifts that made a notes history lie. `LLMProviderID` used to name the
    /// model that shipped this release (`gemma4E4B`), so a machine running an installed
    /// model recorded that model as Gemma; and a stored provider id that no longer decoded
    /// silently became a different provider. Both are pinned here: the retired spelling
    /// still reads, and the local provider reports the file it was told about.
    private static func providerIdentity() -> [String] {
        var failures: [String] = []

        if LLMProviderID(rawValue: "gemma4E4B") != .appLLM {
            failures.append("a stored gemma4E4B provider id no longer reads as the app's model")
        }
        if LLMProviderID(rawValue: "appLLM") != .appLLM {
            failures.append("the app model's own provider id does not read back")
        }
        guard let stored = "\"gemma4E4B\"".data(using: .utf8),
              let decoded = try? JSONDecoder().decode(LLMProviderID.self, from: stored) else {
            failures.append("a stored gemma4E4B provider id does not survive JSON decoding")
            return failures
        }
        if decoded != .appLLM {
            failures.append("a stored gemma4E4B provider id decoded as \(decoded.rawValue)")
        }
        // The fallback chain and the Regenerate menu both walk `allCases`; the local model
        // falling out of it would leave notes with only Apple's model on a Mac that has one.
        if !LLMProviderID.allCases.contains(.appLLM) {
            failures.append("the app's own model is missing from the provider list")
        }
        if LlamaLLMProvider(modelName: "An Installed Model").displayModelName != "An Installed Model" {
            failures.append("the local provider did not report the model it was given")
        }
        if LlamaLLMProvider().displayModelName != NotesModels.spec.displayName {
            failures.append("a local provider with no captured model did not name the built-in one")
        }
        return failures
    }

    // MARK: - 1. Nothing installed → the built-in model, every time

    private static func fallbackToBuiltIn() -> [String] {
        var failures: [String] = []
        let bare = ModelRoleAvailability.nothingInstalled
        let cases: [(ModelRole, ModelRoleChoice, String)] = [
            (.coding, .app(.claude), "Claude Code"),
            (.computerUse, .app(.codex), "Codex"),
            (.agent, .app(.qwen), "Qwen Code"),
            (.agent, .appleFoundation, "Apple Intelligence"),
            (.agent, .installedModel(id: "gone/from/disk.gguf"), "a deleted model file"),
            (.agent, .localServer(endpointID: "ollama", modelID: "llama3.2:3b"), "a stopped Ollama"),
            (.agent, .cloud, "an unset cloud account"),
        ]
        for (role, choice, label) in cases {
            failures += judgeFallback(
                ModelRoleStore.resolve(role: role, choice: choice, availability: bare),
                label: label
            )
        }

        // The checker has to have teeth. A resolver that quietly kept an unavailable choice
        // is the exact bug this whole test exists to catch, so the judgement above is run
        // once against a fabricated result that never fell back — and must reject it.
        let pretendItWorked = ModelRoleResolution(
            role: .coding, requested: .app(.claude), effective: .app(.claude), note: nil
        )
        if judgeFallback(pretendItWorked, label: "a resolver that never fell back").isEmpty {
            failures.append(
                "the fallback check passed a resolution that stayed on an uninstalled app — "
                    + "it would not have caught a broken fallback"
            )
        }

        // The sentence the product asked for, word for word in substance.
        let claude = ModelRoleStore.resolve(role: .coding, choice: .app(.claude), availability: bare)
        if claude.note?.contains("isn’t installed on this Mac") != true {
            failures.append("the Claude Code fallback does not say it isn’t installed on this Mac")
        }

        // The built-in model itself is the floor and is never reported as a fallback.
        let floor = ModelRoleStore.resolve(role: .agent, choice: .builtIn, availability: bare)
        if floor.effective != .builtIn || floor.didFallBack || floor.note != nil {
            failures.append("the built-in model was treated as a fallback from itself")
        }

        // A server that is running but has dropped the chosen model is still a fallback.
        var partial = ModelRoleAvailability.nothingInstalled
        partial.localServerModels = ["ollama": ["qwen3:4b"]]
        partial.localServerNames = ["ollama": "Ollama"]
        let missingModel = ModelRoleStore.resolve(
            role: .agent,
            choice: .localServer(endpointID: "ollama", modelID: "llama3.2:3b"),
            availability: partial
        )
        if missingModel.effective != .builtIn {
            failures.append("a running server missing the chosen model did not fall back")
        }
        return failures
    }

    /// Everything wrong with one "this wasn't available" resolution. Empty means it landed
    /// on the built-in model and said so.
    private static func judgeFallback(
        _ resolved: ModelRoleResolution,
        label: String
    ) -> [String] {
        var problems: [String] = []
        if resolved.effective != .builtIn {
            problems.append(
                "\(label) did not fall back to the built-in model "
                    + "(landed on \(resolved.effective.token))"
            )
        }
        if !resolved.didFallBack {
            problems.append("\(label) was reported as honoured when it was not available")
        }
        guard let note = resolved.note, !note.isEmpty else {
            problems.append("\(label) fell back without telling the person why")
            return problems
        }
        // "its built-in model" and "its own model" are the same promise in two registers;
        // the screen prefers the second. What matters is that the sentence names Next Notes
        // as the one answering, rather than leaving the person to guess.
        if !note.contains("built-in model") && !note.contains("its own model") {
            problems.append("the note for \(label) does not say Next Notes took over: \(note)")
        }
        return problems
    }

    // MARK: - 2. What is there is left alone

    private static func honoursWhatIsThere() -> [String] {
        var failures: [String] = []
        var rich = ModelRoleAvailability()
        rich.builtInModelReady = true
        rich.appleFoundationReady = true
        rich.installedModelIDs = ["bartowski/Qwen3-8B-GGUF/Qwen3-8B-Q4_K_M.gguf"]
        rich.localServerModels = ["ollama": ["llama3.2:3b", "qwen3:4b"]]
        rich.localServerNames = ["ollama": "Ollama"]
        rich.installedApps = [.claude, .codex]
        rich.cloudReady = true

        // Only choices the job in question can actually carry out; what happens to the rest
        // is `whatEachJobCanUse`'s subject.
        let honoured: [(ModelRole, ModelRoleChoice)] = [
            (.coding, .app(.claude)),
            (.computerUse, .localServer(endpointID: "ollama", modelID: "qwen3:4b")),
            (.agent, .appleFoundation),
            (.agent, .installedModel(id: "bartowski/Qwen3-8B-GGUF/Qwen3-8B-Q4_K_M.gguf")),
            (.agent, .localServer(endpointID: "ollama", modelID: "llama3.2:3b")),
            (.agent, .cloud),
        ]
        for (role, choice) in honoured {
            let resolved = ModelRoleStore.resolve(role: role, choice: choice, availability: rich)
            if resolved.effective != choice {
                failures.append(
                    "\(choice.token) was replaced by \(resolved.effective.token) although it was available"
                )
            }
            if resolved.note != nil {
                failures.append("\(choice.token) was available but still carried a fallback note")
            }
        }
        // An app that is installed is the harness for that role; one that is not, is not.
        if ModelRoleStore.resolve(role: .coding, choice: .app(.claude), availability: rich)
            .effective.harness != .claude {
            failures.append("an installed Claude Code did not become the coding harness")
        }
        if ModelRoleStore.resolve(role: .coding, choice: .app(.opencode), availability: rich)
            .effective.harness != nil {
            failures.append("an uninstalled OpenCode was still offered as a harness")
        }
        // The spoken-request classifier has to send a click to the computer-use role.
        if ModelRoleStore.role(forUtterance: "click the send button for me") != .computerUse {
            failures.append("a click request was not routed to the computer-use role")
        }
        if ModelRoleStore.role(forUtterance: "what is on my calendar tomorrow") != .agent {
            failures.append("a calendar question was routed away from the everyday assistant")
        }
        return failures
    }

    // MARK: - 2b. A job is only offered what it can actually be given

    /// The failure this guards against is a green dot on a choice the app structurally
    /// cannot carry out: an agent app picked for everyday questions, or a second model file
    /// picked for a job that cannot load one. Both used to resolve as honoured and then
    /// answer with the built-in model without a word.
    private static func whatEachJobCanUse() -> [String] {
        var failures: [String] = []
        var everything = ModelRoleAvailability()
        everything.builtInModelReady = true
        everything.appleFoundationReady = true
        everything.installedModelIDs = ["library/Qwen3-8B-Q4_K_M.gguf"]
        everything.installedApps = [.claude, .codex, .qwen, .opencode]
        everything.cloudReady = true
        everything.codexComputerUse = .ready

        // Present on this Mac, and still not what this job does.
        let unsuited: [(ModelRole, ModelRoleChoice)] = [
            (.agent, .app(.claude)),
            (.agent, .app(.codex)),
            // Codex ships a helper that drives the screen; Claude Code does not, so it
            // still cannot take this job however thoroughly it is installed.
            (.computerUse, .app(.claude)),
            (.computerUse, .installedModel(id: "library/Qwen3-8B-Q4_K_M.gguf")),
            (.coding, .installedModel(id: "library/Qwen3-8B-Q4_K_M.gguf")),
        ]
        for (role, choice) in unsuited {
            let resolved = ModelRoleStore.resolve(
                role: role, choice: choice, availability: everything
            )
            if resolved.effective != .builtIn {
                failures.append(
                    "\(role.rawValue) kept \(choice.token), which it cannot use "
                        + "(landed on \(resolved.effective.token))"
                )
            }
            if resolved.reason != .notThisJob {
                failures.append(
                    "\(role.rawValue) with \(choice.token) was reported as \(resolved.reason) "
                        + "rather than a job that kind of model does not do"
                )
            }
            guard let note = resolved.note, !note.isEmpty else {
                failures.append("\(role.rawValue) dropped \(choice.token) without saying why")
                continue
            }
            if resolved.needsAttention {
                failures.append(
                    "\(role.rawValue) with \(choice.token) asks the person to fix something "
                        + "that is not broken: \(note)"
                )
            }
            if role.canUse(choice) {
                failures.append("\(role.rawValue) claims it can use \(choice.token)")
            }
        }

        // And the ones that are the point of the feature are still allowed.
        let suited: [(ModelRole, ModelRoleChoice)] = [
            (.coding, .app(.claude)),
            (.computerUse, .app(.codex)),
            (.agent, .installedModel(id: "library/Qwen3-8B-Q4_K_M.gguf")),
            (.computerUse, .cloud),
            (.computerUse, .builtIn),
            (.agent, .appleFoundation),
        ]
        for (role, choice) in suited where !role.canUse(choice) {
            failures.append("\(role.rawValue) refuses \(choice.token), which it can use")
        }
        for (role, choice) in suited {
            let resolved = ModelRoleStore.resolve(
                role: role, choice: choice, availability: everything
            )
            if resolved.effective != choice {
                failures.append("\(choice.token) was dropped from \(role.rawValue) although it fits")
            }
        }
        return failures
    }

    // MARK: - 2b². The dot and the hand-off are the same answer

    /// The question the user asked when they opened this screen: *why is that one not
    /// green?* A dot is a promise, and there are only two ways to break it — claim a job
    /// works when the hand-off would fall back, or claim it does not when it would run.
    /// Both are checked here for every state Codex can be in, in both directions.
    ///
    /// `ModelRoleResolution.reason == .honoured` is exactly what paints the dot green, and
    /// `effective.harness` is exactly what the turn hands the request to, so comparing them
    /// against the readiness they were built from is comparing the screen to the call path.
    private static func greenOnlyWhenItWouldWork() -> [String] {
        var failures: [String] = []
        for readiness in CodexComputerUseReadiness.allCases {
            var availability = ModelRoleAvailability()
            availability.builtInModelReady = true
            // Installed as a coding agent in every case, so nothing here can pass by
            // accidentally reading the coding question instead of the screen one.
            availability.installedApps = [.claude, .codex]
            availability.codexComputerUse = readiness

            let resolved = ModelRoleStore.resolve(
                role: .computerUse, choice: .app(.codex), availability: availability
            )
            let green = resolved.reason == .honoured
            let wouldRun = resolved.effective.harness == .codex

            if green != readiness.isReady {
                failures.append(
                    "controlling the Mac shows \(green ? "green" : "not green") with Codex "
                        + "\(readiness.rawValue), which is backwards"
                )
            }
            if green != wouldRun {
                failures.append(
                    "controlling the Mac shows \(green ? "green" : "not green") but would "
                        + "\(wouldRun ? "" : "not ")hand the request to Codex"
                )
            }
            if readiness.isReady {
                if resolved.note != nil {
                    failures.append("a working row still explains itself: \(resolved.note ?? "")")
                }
                continue
            }
            // Not ready: one sentence, and it has to be the one for this state rather than
            // a generic "something is wrong".
            guard let note = resolved.note, !note.isEmpty else {
                failures.append("Codex \(readiness.rawValue) fell back without saying why")
                continue
            }
            if note != readiness.note {
                failures.append(
                    "Codex \(readiness.rawValue) is explained as “\(note)”, which is not what "
                        + "that state means"
                )
            }
            if !resolved.needsAttention {
                failures.append(
                    "Codex \(readiness.rawValue) is something the person can put right, but "
                        + "the row does not draw attention to it"
                )
            }
            if resolved.effective != .builtIn {
                failures.append(
                    "Codex \(readiness.rawValue) fell back to \(resolved.effective.token) "
                        + "rather than the model Next Notes comes with"
                )
            }
        }

        // Every not-ready state has to name a different thing to do, or the sentence is
        // decoration rather than help.
        let notes = Set(CodexComputerUseReadiness.allCases.compactMap(\.note))
        if notes.count != CodexComputerUseReadiness.allCases.count - 1 {
            failures.append("two of Codex's problems are explained with the same sentence")
        }

        // What this Mac actually reports, compared with what the row would claim. This is
        // the only check here that touches the disk, and it cannot fail on a Mac without
        // Codex — it fails when the probe and the dot disagree about the Mac it is on.
        // The only check here that touches this Mac. It cannot fail for want of Codex — it
        // fails when the probe would paint the row green with nothing to run.
        if CodexComputerUse.probe().isReady, CodexComputerUse.resolvedCLI() == nil {
            failures.append("the Codex probe says ready without finding Codex to run")
        }

        // What comes back from a hand-off is read out loud next to the person's own words,
        // so the banner and the token footer must not be in it — and the answer must not be
        // repeated, which is what walking the transcript backwards used to do.
        let transcript = """
            OpenAI Codex v0.155.0
            --------
            workdir: /Users/someone
            --------
            user
            open the front window
            codex
            I opened Safari and clicked Save.
            tokens used
            18,148
            I opened Safari and clicked Save.
            """
        let reply = CodexComputerUse.reply(fromTranscript: transcript)
        if reply != "I opened Safari and clicked Save." {
            failures.append("what Codex did was read back as “\(reply)”")
        }
        if CodexComputerUse.reply(fromTranscript: "   \n \n").isEmpty {
            failures.append("an empty transcript was read back as nothing at all")
        }
        return failures
    }

    // MARK: - 2c. Which job an ordinary sentence belongs to

    /// Word boundaries, not bare substrings. Each of these was routed to the computer-use
    /// job by the first version — and with that job pointed at an online model, "draft a
    /// press release about the acquisition" would have left the Mac because of "press".
    private static func whichJobARequestBelongsTo() -> [String] {
        var failures: [String] = []
        let everyday = [
            "what type of report should I write",
            "draft a press release about the acquisition",
            "what approach should I take with this client",
            "what apple intelligence does on this mac",
            "what is on my calendar tomorrow",
            "summarise the dragnet chapter for me",
            "who typed up the notes from yesterday",
        ]
        for text in everyday where ModelRoleStore.role(forUtterance: text) != .agent {
            failures.append("“\(text)” was sent to the computer-use job")
        }
        let driving = [
            "click the send button for me",
            "type my address into the form",
            "press return",
            "can you please click Save",
            "and then type hello there",
            "what app is in front right now",
            "take a screenshot of this",
            "read what’s on my screen",
        ]
        for text in driving where ModelRoleStore.role(forUtterance: text) != .computerUse {
            failures.append("“\(text)” was not recognised as driving the Mac")
        }
        return failures
    }

    // MARK: - 2d. The call paths actually follow the rows

    /// Without this the rest of the file would pass with every wiring change reverted:
    /// `resolve` is a pure function, and a settings screen that nothing reads would still
    /// satisfy it. Both checks below run without a network, a model or an account.
    private static func callPathsFollowTheRoles() async -> [String] {
        var failures: [String] = []
        let roles = ModelRoleStore.shared
        let storedChoices = roles.snapshotChoicesForTesting()
        let storedAvailability = roles.availability
        defer {
            roles.restoreChoicesForTesting(storedChoices)
            roles.overrideAvailabilityForTesting(storedAvailability)
        }

        var asIfInstalled = ModelRoleAvailability()
        asIfInstalled.builtInModelReady = true
        asIfInstalled.installedApps = [.claude, .codex]
        roles.overrideAvailabilityForTesting(asIfInstalled)

        // (a) The model a turn is answered with. An agent app is not an answering model, so
        // the assistant has to come back with the model this Mac came with — never a cloud
        // provider, and never nothing.
        roles.setChoiceForTesting(.app(.claude), for: .agent)
        let answered = await roles.provider(for: .agent)
        switch answered?.id {
        case .some(.appLLM), .some(.appleFoundation):
            break
        case .none:
            if NotesModels.isDownloaded {
                failures.append(
                    "the assistant had no model to answer with although the built-in one is here"
                )
            }
        case .some(let other):
            failures.append("an agent app picked for the assistant answered with \(other)")
        }
        // The same decision, through the enum every live turn calls.
        let voiced = await AgentModelRouting.provider(for: "click the send button", voice: true)
        if let voiced, voiced.id != .appLLM, voiced.id != .appleFoundation {
            failures.append("a spoken turn was routed off this Mac, to \(voiced.id)")
        }

        // (b) Where a coding turn runs. `roleDecision` is what `choose` calls; driving it
        // directly keeps the person's own settings untouched.
        roles.setChoiceForTesting(.app(.claude), for: .coding)
        if AgentHarnessRouter.settingsHarness(
            for: "investigate the failing build in this repo", roles: roles, acpBackendID: "codex"
        ) != .claude {
            failures.append("an installed Claude Code chosen for code was not given the turn")
        }
        roles.setChoiceForTesting(.builtIn, for: .coding)
        if AgentHarnessRouter.settingsHarness(
            for: "investigate the failing build in this repo", roles: roles, acpBackendID: "codex"
        ) != .local {
            failures.append(
                "“keep code on this Mac” still handed the turn to an external agent app"
            )
        }
        roles.setChoiceForTesting(.app(.opencode), for: .coding)
        if AgentHarnessRouter.settingsHarness(
            for: "investigate the failing build in this repo", roles: roles, acpBackendID: "codex"
        ) != .local {
            failures.append("a coding app that is not installed did not come back to this Mac")
        }
        // Nobody has chosen: the older backend setting still decides, as it did before.
        roles.restoreChoicesForTesting([:])
        if AgentHarnessRouter.settingsHarness(
            for: "investigate the failing build in this repo", roles: roles, acpBackendID: "codex"
        ) != .codex {
            failures.append("an untouched row overruled the backend the person had configured")
        }
        // Driving the Mac never leaves it: no agent app can see these windows.
        if AgentHarnessRouter.settingsHarness(
            for: "click the Save button", roles: roles, acpBackendID: "codex"
        ) != .local {
            failures.append("a request to click something was handed to an external agent app")
        }
        return failures
    }

    // MARK: - 2e. A role resolves only to a model that can answer (P0-03)

    /// A file that is real, on disk and probed as openable can still be unable to answer.
    /// The measured case is the Gemma 4 E4B MTP draft head: 59.7 MB, a legal GGUF, and no
    /// context can ever be built from it — every turn handed one answered "Inference could
    /// not start". The fixture's verdict is pre-seeded as `.opens`, so only the auxiliary
    /// check stands between it and a role.
    private static func answerableOnly() async -> [String] {
        var failures: [String] = []
        guard let fixture = makeDraftHeadFixture() else {
            return ["the draft-head fixture could not be created"]
        }
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        guard let isolated = isolatedDefaults(tag: "answerable") else {
            return ["the isolated defaults suite could not be created"]
        }
        defer { isolated.defaults.removePersistentDomain(forName: isolated.domain) }

        let runtime = NotesModelRuntime(spec: NotesModels.spec, gpuLayers: 0)
        let library = InstalledModelLibrary(
            manifestURL: fixture.directory.appendingPathComponent("library.json"),
            defaults: isolated.defaults)
        library.add(fixture.model)
        let store = ModelRoleStore(
            defaults: isolated.defaults,
            availability: .nothingInstalled,
            library: library,
            runtime: runtime,
            failures: ModelOpenFailureStore(defaults: isolated.defaults))
        store.setChoiceForTesting(.installedModel(id: fixture.model.id), for: .agent)

        let provider = await store.provider(for: .agent)
        if let provider, let local = provider as? LlamaLLMProvider,
           local.displayModelName == fixture.model.displayName {
            failures.append(
                "the everyday assistant answered with “\(fixture.model.displayName)”, "
                    + "which can open but cannot answer")
        }
        if !NotesModels.isDownloaded, provider?.id == .appLLM {
            failures.append("the assistant resolved to the app's own runtime although no "
                + "runnable model is on this Mac")
        }
        return failures
    }

    /// A stored role outlives the file it names. When that file cannot answer, launch has
    /// to rewrite the role once — to Apple's on-device model when it is available, to the
    /// built-in one otherwise — and say so once per (role, file), ever.
    private static func launchRepair() async -> [String] {
        var failures: [String] = []
        guard let fixture = makeDraftHeadFixture() else {
            return ["the draft-head fixture could not be created"]
        }
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        guard let isolated = isolatedDefaults(tag: "repair") else {
            return ["the isolated defaults suite could not be created"]
        }
        defer { isolated.defaults.removePersistentDomain(forName: isolated.domain) }

        isolated.defaults.set(
            ModelRoleChoice.installedModel(id: fixture.model.id).token,
            forKey: "modelRoles.agent")

        let runtime = NotesModelRuntime(spec: NotesModels.spec, gpuLayers: 0)
        let library = InstalledModelLibrary(
            manifestURL: fixture.directory.appendingPathComponent("library.json"),
            defaults: isolated.defaults)
        library.add(fixture.model)
        let store = ModelRoleStore(
            defaults: isolated.defaults,
            availability: .nothingInstalled,
            library: library,
            runtime: runtime,
            failures: ModelOpenFailureStore(defaults: isolated.defaults))
        if store.choice(for: .agent) != .installedModel(id: fixture.model.id) {
            return ["the stored role was not read back; the fixture is wrong, not the code"]
        }

        ModelLoadNotice.shared.clear()
        let repaired = await store.repairUnanswerableRoles()
        if repaired.isEmpty {
            failures.append("the launch repair found nothing to repair for a role pointing "
                + "at a draft head")
        }
        let appleReady = await LLMProviders.make(.appleFoundation).unavailableReason == nil
        let expected: ModelRoleChoice = appleReady ? .appleFoundation : .builtIn
        if store.choice(for: .agent) != expected {
            failures.append("the launch repair left the assistant role on "
                + "\(store.choice(for: .agent).token), not \(expected.token)")
        }
        if isolated.defaults.string(forKey: "modelRoles.agent") != expected.token {
            failures.append("the launch repair did not persist the replacement role")
        }
        if ModelLoadNotice.shared.message?.contains("can’t run on this Mac") != true {
            failures.append("the launch repair did not say the chosen model can’t run on "
                + "this Mac (\(ModelLoadNotice.shared.message ?? "no notice"))")
        }

        // The same repair twice must not say the same thing twice.
        ModelLoadNotice.shared.clear()
        let second = await store.repairUnanswerableRoles()
        if !second.isEmpty {
            failures.append("a second launch repair reported \(second.count) repaired role(s)")
        }
        if let message = ModelLoadNotice.shared.message {
            failures.append("a second launch repair repeated the notice: \(message)")
        }
        return failures
    }

    /// The pane must be able to name the model that answered. One typed turn on a stub
    /// whose name is like no real model's: the published name can only have come from the
    /// provider the turn ran on, not from the role's stored choice.
    private static func answeringModelIsPublished() async -> [String] {
        let agent = RealtimeAgent.shared
        let stub = StubAnsweringProvider()
        let previousProvider = agent.localModelProviderForTesting
        agent.localModelProviderForTesting = stub
        defer { agent.localModelProviderForTesting = previousProvider }

        _ = await agent.runGeneralToolLoop("What can you do?")
        guard let answering = agent.answeringModel else {
            return ["the pane was never told which model answered the turn"]
        }
        var failures: [String] = []
        if answering.name != stub.displayModelName {
            failures.append("the pane named “\(answering.name)” as the answering model, "
                + "not “\(stub.displayModelName)”")
        }
        if answering.id != stub.id {
            failures.append("the pane recorded \(answering.id.rawValue) as the answering "
                + "provider, not \(stub.id.rawValue)")
        }
        return failures
    }

    /// A sparse file with the exact name and size of the Gemma 4 E4B MTP draft head. It
    /// takes no real disk, and its row carries an `.opens` verdict.
    private static func makeDraftHeadFixture()
        -> (directory: URL, model: InstalledLocalModel)? {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "NextNotesSelfTest-p0-03-\(ProcessInfo.processInfo.processIdentifier)",
                isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let fileURL = directory.appendingPathComponent("mtp-gemma-4-E4B-it-Q4_0.gguf")
            guard FileManager.default.createFile(atPath: fileURL.path, contents: nil) else {
                return nil
            }
            let handle = try FileHandle(forWritingTo: fileURL)
            try handle.truncate(atOffset: 59_700_000)
            try handle.close()
            let bytes = ModelDownloader.fileSize(at: fileURL)
            let model = InstalledLocalModel(
                id: "self-test/p0-03/mtp-gemma-4-E4B-it-Q4_0.gguf",
                displayName: "Gemma 4 E4B draft head",
                fileURL: fileURL,
                parameterBillions: nil,
                quantization: "Q4_0",
                bytes: bytes,
                isBuiltIn: false,
                support: LlamaProbeResult(
                    verdict: .opens,
                    detail: nil,
                    llamaBuildTag: LlamaArchitectures.buildTag,
                    fileBytes: bytes))
            return (directory, model)
        } catch {
            return nil
        }
    }

    /// A per-run `UserDefaults` suite this test owns, so nothing lands in the owner's
    /// `modelRoles.*` keys.
    private static func isolatedDefaults(tag: String)
        -> (defaults: UserDefaults, domain: String)? {
        let domain = "NextNotesSelfTest-p0-03-\(tag)-\(ProcessInfo.processInfo.processIdentifier)"
        guard let defaults = UserDefaults(suiteName: domain) else { return nil }
        defaults.removePersistentDomain(forName: domain)
        return (defaults, domain)
    }

    // MARK: - 3a. Addresses

    private static func addressNormalisation() -> [String] {
        var failures: [String] = []
        let accepted = [
            "localhost:1234", "http://127.0.0.1:1234/v1",
            "http://127.0.0.1:1234/v1/chat/completions", "127.0.0.1:8080/v1/models",
        ]
        for text in accepted {
            switch LocalRuntimeDiscovery.normalizeAddress(text) {
            case .failure(let problem):
                failures.append("“\(text)” was rejected: \(problem.message)")
            case .success(let url):
                if url.path.hasSuffix("/chat/completions") || url.path.hasSuffix("/models") {
                    failures.append("“\(text)” was not trimmed back to the server root (\(url))")
                }
            }
        }
        // Loopback only, by default and without exception here.
        for text in ["http://192.168.1.40:11434/v1", "https://example.com/v1"] {
            if case .success = LocalRuntimeDiscovery.normalizeAddress(text) {
                failures.append("“\(text)” was accepted although it is not on this Mac")
            }
        }
        if case .success = LocalRuntimeDiscovery.normalizeAddress("   ") {
            failures.append("an empty address was accepted")
        }
        return failures
    }

    // MARK: - 3b. Structured tool calls become the tags the app already reads

    private static func toolCallBridging() -> [String] {
        var failures: [String] = []
        var accumulator = OpenAICompatibleLLMProvider.ToolCallAccumulator()
        let lines = [
            #"data: {"choices":[{"delta":{"content":"Looking that up."}}]}"#,
            #"data: {"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"name":"calendar_"}}]}}]}"#,
            #"data: {"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"name":"list"}}]}}]}"#,
            #"data: {"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"{\"day\":"}}]}}]}"#,
            #"data: {"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"\"tomorrow\"}"}}]}}]}"#,
            "data: [DONE]",
        ]
        var text = ""
        var sawDone = false
        for line in lines {
            do {
                guard let chunk = try OpenAICompatibleLLMProvider.parseStreamLine(line) else { continue }
                text += chunk.text
                for delta in chunk.toolCalls { accumulator.apply(delta) }
                if chunk.isDone { sawDone = true }
            } catch {
                failures.append("a normal stream line threw: \(error.localizedDescription)")
            }
        }
        if !sawDone { failures.append("the end of the stream was not recognised") }
        if text != "Looking that up." { failures.append("streamed text was lost: “\(text)”") }

        let calls = AgentToolCallParser.calls(in: accumulator.tags())
        guard calls.count == 1 else {
            failures.append("a split tool call did not reassemble into exactly one call (\(calls.count))")
            return failures
        }
        if calls[0].name != "calendar_list" {
            failures.append("the reassembled call is named \(calls[0].name)")
        }
        if calls[0].arguments["day"] != "tomorrow" {
            failures.append("the reassembled call lost its arguments")
        }

        // Two calls in one delta is legal, and dropping the second would silently lose
        // half of what the model asked for.
        var pair = OpenAICompatibleLLMProvider.ToolCallAccumulator()
        let both = #"data: {"choices":[{"delta":{"tool_calls":["#
            + #"{"index":0,"function":{"name":"get_agenda","arguments":"{}"}},"#
            + #"{"index":1,"function":{"name":"search_email","arguments":"{}"}}]}}]}"#
        if let chunk = try? OpenAICompatibleLLMProvider.parseStreamLine(both) {
            for delta in chunk.toolCalls { pair.apply(delta) }
        }
        let pairNames = AgentToolCallParser.calls(in: pair.tags()).map(\.name)
        if pairNames != ["get_agenda", "search_email"] {
            failures.append("two calls in one chunk became \(pairNames)")
        }

        // Some servers end with a finish_reason rather than a [DONE] line.
        var finishedTheStream = false
        if let finished = try? OpenAICompatibleLLMProvider.parseStreamLine(
            #"data: {"choices":[{"delta":{},"finish_reason":"stop"}]}"#
        ) {
            finishedTheStream = finished.isDone
        }
        if !finishedTheStream {
            failures.append("a finish_reason did not end the stream")
        }

        // A server that reports an error mid-stream must not look like a quiet answer.
        do {
            _ = try OpenAICompatibleLLMProvider.parseStreamLine(
                #"data: {"error":{"message":"model not loaded"}}"#
            )
            failures.append("a mid-stream server error was swallowed")
        } catch {}

        // The non-streaming shape has to bridge too.
        let blocking = Data(
            #"{"choices":[{"message":{"content":"","tool_calls":[{"function":{"name":"open_app","arguments":"{\"name\":\"Safari\"}"}}]}}]}"#
                .utf8
        )
        if let rendered = try? OpenAICompatibleLLMProvider.text(fromCompletion: blocking) {
            let parsed = AgentToolCallParser.calls(in: rendered)
            if parsed.first?.name != "open_app" || parsed.first?.arguments["name"] != "Safari" {
                failures.append("a non-streamed tool call did not become a readable call")
            }
        } else {
            failures.append("a non-streamed tool-call answer could not be read")
        }
        return failures
    }

    // MARK: - 3c. Discovery against a real server, and against none

    private static func discovery() async -> [String] {
        var failures: [String] = []
        guard let server = FixtureServer(), let port = await server.start() else {
            return ["could not start the fixture server on loopback"]
        }
        guard let base = URL(string: "http://127.0.0.1:\(port)/v1") else {
            await server.stop()
            return ["could not build the fixture server's address"]
        }
        let endpoint = LocalRuntimeEndpoint(
            id: "fixture", kind: .custom, baseURL: base, displayName: "Fixture"
        )
        let found = await LocalRuntimeDiscovery.probe(endpoint)
        if let problem = found.problem {
            failures.append("a running server was reported as a problem: \(problem.message)")
        }
        let ids = Set(found.models.map(\.modelID))
        if !ids.contains("qwen2.5-7b-instruct") {
            failures.append("the fixture server's model was not listed (got \(ids.sorted()))")
        }
        if ids.contains("nomic-embed-text-v1.5") {
            failures.append("an embedding model was offered as a chat model")
        }

        await server.stop()
        // Let the socket finish closing, so the probe below is testing a shut port rather
        // than racing the teardown and passing for the wrong reason.
        try? await Task.sleep(for: .milliseconds(300))
        // The port is now closed. This is the case that has to be quiet rather than fatal.
        let gone = await LocalRuntimeDiscovery.probe(endpoint)
        if !gone.models.isEmpty {
            failures.append("a stopped server still reported models")
        }
        guard case .notRunning = gone.problem else {
            failures.append("a stopped server was not reported as not running")
            return failures
        }

        // Ollama's own listing carries the detail the picker rows show.
        let tagsJSON = #"{"models":[{"name":"llama3.2:3b","model":"llama3.2:3b","size":2019393189,"#
            + #""details":{"parameter_size":"3.2B","quantization_level":"Q4_K_M"}}]}"#
        let tags = Data(tagsJSON.utf8)
        let parsed = LocalRuntimeDiscovery.parseOllamaTags(tags, endpointID: "ollama")
        guard parsed.count == 1, parsed[0].modelID == "llama3.2:3b" else {
            failures.append("Ollama's listing did not parse")
            return failures
        }
        if parsed[0].detail?.contains("3.2B") != true || parsed[0].detail?.contains("Q4_K_M") != true {
            failures.append("Ollama's size and quantisation were dropped: \(parsed[0].detail ?? "nil")")
        }
        if !LocalRuntimeDiscovery.parseOllamaTags(Data("not json".utf8), endpointID: "ollama").isEmpty {
            failures.append("nonsense from a server was parsed into models")
        }
        return failures
    }

    /// A one-request-at-a-time HTTP server on an OS-assigned loopback port.
    ///
    /// Small on purpose: enough to answer the two listing paths a discovery probe asks for,
    /// and nothing else. It exists so the probe under test is a real network round trip
    /// rather than a parse of a literal.
    private actor FixtureServer {
        private let listener: NWListener
        private var connections: [NWConnection] = []

        init?() {
            guard let listener = try? NWListener(using: .tcp, on: .any) else { return nil }
            self.listener = listener
        }

        func start() async -> UInt16? {
            listener.newConnectionHandler = { [weak self] connection in
                guard let self else { return }
                Task { await self.accept(connection) }
            }
            return await withCheckedContinuation { continuation in
                let box = ContinuationBox(continuation)
                listener.stateUpdateHandler = { state in
                    switch state {
                    case .ready: box.finish(self.listener.port?.rawValue)
                    case .failed, .cancelled: box.finish(nil)
                    default: break
                    }
                }
                listener.start(queue: .global(qos: .userInitiated))
            }
        }

        func stop() {
            for connection in connections { connection.cancel() }
            connections = []
            listener.cancel()
        }

        private func accept(_ connection: NWConnection) {
            connections.append(connection)
            connection.start(queue: .global(qos: .userInitiated))
            connection.receive(minimumIncompleteLength: 1, maximumLength: 8_192) { data, _, _, _ in
                let request = data.map { String(decoding: $0, as: UTF8.self) } ?? ""
                let body = Self.body(for: request)
                let response = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n"
                    + "Content-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n" + body
                connection.send(
                    content: Data(response.utf8),
                    completion: .contentProcessed { _ in connection.cancel() }
                )
            }
        }

        private static func body(for request: String) -> String {
            if request.contains("/api/tags") {
                return #"{"models":[{"name":"llama3.2:3b","model":"llama3.2:3b","size":2019393189,"#
                    + #""details":{"parameter_size":"3.2B","quantization_level":"Q4_K_M"}}]}"#
            }
            return #"{"object":"list","data":[{"id":"qwen2.5-7b-instruct"},"#
                + #"{"id":"nomic-embed-text-v1.5"}]}"#
        }
    }

    /// `NWListener` can report `.ready` more than once; a continuation may only be resumed
    /// once, and resuming it twice is a crash rather than a failed test.
    private final class ContinuationBox: @unchecked Sendable {
        private var continuation: CheckedContinuation<UInt16?, Never>?
        private let lock = NSLock()

        init(_ continuation: CheckedContinuation<UInt16?, Never>) {
            self.continuation = continuation
        }

        func finish(_ value: UInt16?) {
            lock.lock()
            let pending = continuation
            continuation = nil
            lock.unlock()
            pending?.resume(returning: value)
        }
    }
}

/// One typed turn's model, named so no real file can share it.
private struct StubAnsweringProvider: LLMProvider {
    let id = LLMProviderID.appLLM
    var displayModelName: String { "Stub" }
    var contextTokens: Int { 4_096 }
    var unavailableReason: String? { get async { nil } }

    func countTokens(_ text: String) async throws -> Int { text.count / 4 + 1 }

    func complete(system: String, user: String, maxTokens: Int) async throws -> LLMCompletion {
        LLMCompletion(text: "<answer/>Answered by the stub.", generatedTokens: 5, duration: 0)
    }
}

/// A clock a test can move, so "until that moment" and "after it" are both reachable
/// without a sleep. `@unchecked Sendable` because `CodexQuotaStore` takes its clock as a
/// `@Sendable` closure; every access is on the test's own task.
private final class MovableClock: @unchecked Sendable {
    var now: Date
    init(_ start: Date) { now = start }
}
