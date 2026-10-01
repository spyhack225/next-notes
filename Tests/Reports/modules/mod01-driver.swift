import Foundation

@main
struct ModuleFoundationDriver {
    @MainActor
    static func main() {
        var failures: [String] = []
        func check(_ ok: Bool, _ message: String) {
            if !ok { failures.append(message) }
        }
        let suiteName = "NextNotes-MOD01-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let keys: [AppModule: String] = [
            .dictation: "moduleDictationEnabled", .meetings: "moduleMeetingsEnabled",
            .assistant: "agentEnabled"
        ]
        let absent = Settings(defaults: defaults)
        check(absent.isModuleEnabled(.dictation), "absent Dictation key must remain on")
        check(absent.isModuleEnabled(.meetings), "absent Meetings key must remain on")
        check(!absent.isModuleEnabled(.assistant), "absent Assistant key must remain off")
        check(defaults.dictionaryRepresentation().keys.filter { keys.values.contains($0) }.isEmpty,
              "reading absent choices must not persist new preferences")

        let assistantSections: [SidebarSection] = [.agent, .graph, .portrait, .ideas, .goals, .reminders, .skills]
        for mask in 0..<8 {
            let dictation = mask & 1 != 0
            let meetings = mask & 2 != 0
            let assistant = mask & 4 != 0
            let settings = Settings(defaults: defaults)
            settings.moduleDictationEnabled = dictation
            settings.moduleMeetingsEnabled = meetings
            settings.agentEnabled = assistant
            let reopened = Settings(defaults: UserDefaults(suiteName: suiteName)!)
            let enabled = Set(AppModule.allCases.filter { reopened.isModuleEnabled($0) })
            check(enabled.contains(.dictation) == dictation, "Dictation read-back \(mask)")
            check(enabled.contains(.meetings) == meetings, "Meetings read-back \(mask)")
            check(enabled.contains(.assistant) == assistant, "existing Assistant key read-back \(mask)")
            for indexOn in [false, true] {
                let rows = ModulePolicy.visibleSections(for: enabled, knowledgeIndexEnabled: indexOn)
                check(rows.contains(.dictation) == dictation, "Dictation row \(mask)")
                check(rows.contains(.meetings) == meetings, "Meetings row \(mask)")
                check(assistantSections.allSatisfy { rows.contains($0) == assistant }, "Assistant rows \(mask)")
                check(rows.contains(.search) == (indexOn && (meetings || assistant)), "Search row \(mask)")
                check(rows.contains(.dictionary) && !rows.contains(.settings) && !rows.contains(.comparison),
                      "always-available Dictionary and separate Settings \(mask)")
            }
            let fallback: SidebarSection = dictation ? .dictation : meetings ? .meetings : assistant ? .agent : .dictionary
            check(ModulePolicy.firstEnabledSection(dictation: dictation, meetings: meetings,
                                                   assistant: assistant) == fallback, "fallback order \(mask)")
            let steps = ModulePolicy.onboardingSteps(for: enabled)
            check(steps.first == .welcome && steps.last == .allSet, "setup endpoints \(mask)")
            check(steps.contains(.dictation) == dictation && steps.contains(.shortcut) == dictation,
                  "Dictation setup \(mask)")
            check(steps.contains(.meetings) == meetings && steps.contains(.files) == assistant,
                  "Meetings / Assistant setup \(mask)")
            check(steps.contains(.brain) == (mask != 0), "local-model setup may be needed by any module \(mask)")
        }
        check(defaults.object(forKey: "moduleAssistantEnabled") == nil, "no second Assistant key")
        if failures.isEmpty {
            print("MOD01_DRIVER_OK: 8 combinations; absent defaults; persisted choices; production reader")
        } else {
            failures.forEach { print("MOD01_DRIVER_WRONG: \($0)") }
            print("MOD01_DRIVER_FAILED: \(failures.count)")
            exit(1)
        }
    }
}
