import Foundation
import Network

/// `--selftest-model-roles`.
///
/// Five things are checked, and each of them can fail:
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
@MainActor
enum ModelRoleSelfTest {
    static func run() async -> [String] {
        var failures: [String] = []
        failures += tokenRoundTrip()
        failures += fallbackToBuiltIn()
        failures += honoursWhatIsThere()
        failures += whatEachJobCanUse()
        failures += greenOnlyWhenItWouldWork()
        failures += whichJobARequestBelongsTo()
        failures += await callPathsFollowTheRoles()
        failures += addressNormalisation()
        failures += toolCallBridging()
        failures += await discovery()
        return failures
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
        case .some(.gemma4E4B), .some(.appleFoundation):
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
        if let voiced, voiced.id != .gemma4E4B, voiced.id != .appleFoundation {
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
