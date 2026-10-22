    /// Actual controller factory and finishing consumer; requires isolated harness stores.
    /// Semantic answers are identity/trimmed; native quality and physical insertion are separate.
    static func incrementalStructureReuseFailures() async -> [String] {
        guard SelfTest.isRunning, Settings.shared.usesHarnessPreferencesForTesting else {
            return ["incremental structure fixture requires isolated preferences"]
        }
        struct Recording: TextFormatter {
            let inputs: LockedBox<[String]>
            func format(_ raw: String) async -> String {
                inputs.value.append(raw)
                return raw.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        let settings = Settings.shared
        let old = (settings.cleanupEnabled, settings.cleanupEngine,
                   settings.cleanupFixesGrammar, settings.cleanupFormatsLists)
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DictationStructureReuse-\(UUID().uuidString)")
        defer {
            settings.cleanupEnabled = old.0
            settings.cleanupEngine = old.1
            settings.cleanupFixesGrammar = old.2
            settings.cleanupFormatsLists = old.3
            try? FileManager.default.removeItem(at: root)
        }
        settings.cleanupEnabled = true
        settings.cleanupEngine = .apple
        settings.cleanupFixesGrammar = true
        let quote = "Open quote. We will deliver every required feature and preserve its exact meaning. End quote."
        let code = "Start code. npm run dev --host zero dot zero dot zero dot zero. End code."
        let list = "Start the list. First point, preserve the original dictated words and their meaning. Second point, preserve all file tags and final formatting. Close the list."
        let prose = "We will deliver every required feature and preserve its exact meaning."
        let tail = "The remaining sentence finishes later."
        let cases: [(String, [String], String, Bool)] = [
            ("quote", [quote], quote + " " + tail, true),
            ("code", [code], code + " " + tail, true),
            ("list", [list], list + " " + tail, true),
            ("ordinary", [prose], prose + " " + tail, true),
            ("revised", [prose], "We must retain the original words and their meaning. " + tail, false),
            ("cross-quote", ["Open quote. We will deliver every required feature.", quote], quote + " " + tail, false),
            ("cross-list", ["Start the list. First point, preserve the original dictated words and their meaning.", list], list + " " + tail, false),
            ("unicode", ["ßeta is a named file and must retain all of its original content."], "ßeta is a named file and must retain all of its original content. " + tail, true),
            ("two-blocks", [quote, quote + " " + code], quote + " " + code + " " + tail, true),
            ("paragraph", [prose, prose + " New paragraph. " + prose], prose + " New paragraph. " + prose + " " + tail, true)
        ]
        var failures: [String] = []
        for markdown in [false, true] {
            let profile = OutputProfile(bundleID: "fixture", displayName: "Fixture",
                capabilities: markdown ? Set(OutputCapability.allCases) : [])
            for enabled in [false, true] {
                settings.cleanupFormatsLists = enabled
                for (name, commits, final, mustReuse) in cases {
                    let inputs = LockedBox<[String]>([])
                    let semantic = Recording(inputs: inputs)
                    let trace = CleanupTrace()
                    let usage = UsageLog(directory: root.appendingPathComponent(UUID().uuidString))
                    var delivered: String?
                    let controller = DictationController(
                        insert: { text, _ in delivered = text; return .superseded },
                        record: { _ in }, log: .selfTest, outcome: { _ in }, usage: usage,
                        cleanupPieces: { CleanupPieces(preclean: semantic, pass: { head in
                            CleanupRouter(semantic: semantic, engine: .apple,
                                formatsLists: enabled, target: profile, trace: trace,
                                head: head, pressureSample: { .idle })
                        }) }, contextCapture: { .empty }, referenceProfile: profile
                    )
                    let label = "\(name) markdown=\(markdown) enabled=\(enabled)"
                    guard let producer = controller.makeIncrementalCleanup() else {
                        failures.append("\(label): actual controller did not create producer")
                        continue
                    }
                    for committed in commits {
                        await producer.notePartial(committed, committed: committed)
                    }
                    let head = await producer.head()
                    for task in head.cleaned { _ = await task.value }
                    let during = inputs.value.count
                    let expected = await CleanupRouter(
                        semantic: Recording(inputs: LockedBox([])), engine: .apple,
                        formatsLists: enabled, target: profile, pressureSample: { .idle }
                    ).format(final)
                    controller.incrementalCleanup = producer
                    controller.transcript = final
                    controller.holdStarted = Date().addingTimeInterval(-30)
                    controller.releasedAt = Date()
                    controller.state = .finishing
                    controller.captureDrainTask = Task { true }
                    await controller.runTail(session: controller.session, audio: nil)
                    usage.flush()
                    let reused = !head.cleaned.isEmpty && trace.snapshot.precleanedGroups == head.cleaned.count
                    if reused != mustReuse {
                        failures.append("\(label): actual finishing consumer reuse/refusal is wrong")
                    }
                    if delivered != expected || trace.snapshot.cleanedText != expected {
                        failures.append("\(label): actual delivered/recorded formatting differs")
                    }
                    if reused && inputs.value.count - during != 1 {
                        failures.append("\(label): release repeats cleanup beyond the remaining tail")
                    }
                    await producer.cancel()
                }
            }
        }
        return failures
    }
