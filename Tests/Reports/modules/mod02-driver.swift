import Foundation

@main
struct ModuleNavigationDriver {
    @MainActor
    static func main() {
        var failures: [String] = []
        var checks = 0
        func check(_ ok: Bool, _ message: String) {
            checks += 1
            if !ok { failures.append(message) }
        }
        let suite = "NextNotes-MOD02-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = Settings.shared
        let sectionKey = "navigation.section"
#if MOD02
        let ownerBefore = UserDefaults.standard.object(forKey: sectionKey) as? String
        SelfTestHarnessDefaults.shared.set("meetings", forKey: sectionKey)
        settings.modules = []
        check(NavigationState.shared.selectedSection == .dictionary, "shared self-test navigation normalizes harness")
        check(SelfTestHarnessDefaults.shared.string(forKey: sectionKey) == "dictionary", "shared writes harness suite")
        check(UserDefaults.standard.object(forKey: sectionKey) as? String == ownerBefore, "shared leaves standard defaults unchanged")
        defer { SelfTestHarnessDefaults.shared.removePersistentDomain(forName: SelfTestHarnessDefaults.suiteName) }
#endif
        for mask in 0..<8 {
            settings.modules = Set(AppModule.allCases.enumerated().compactMap { index, module in
                mask & (1 << index) != 0 ? module : nil
            })
            let fallback: SidebarSection = mask & 1 != 0 ? .dictation : mask & 2 != 0 ? .meetings : mask & 4 != 0 ? .agent : .dictionary
            for indexOn in [false, true] {
                settings.knowledgeIndexEnabled = indexOn
                let rows = ModulePolicy.visibleSections(for: settings.modules, knowledgeIndexEnabled: indexOn)
#if MOD02
                let controller = DictationController()
                let meeting = MeetingController()
                let sidebar = SidebarProbe(settings: settings, controller: controller, meetings: meeting)
                check(sidebar.rows == rows, "actual Sidebar rows use matrix \(mask)")
                for dictationActive in [false, true] {
                    for meetingActive in [false, true] {
                        controller.state = CaptureState(isActive: dictationActive)
                        meeting.isRecording = meetingActive
                        let visibleMeeting = meetingActive && mask & 2 != 0
                        let visibleDictation = dictationActive && mask & 1 != 0
                        check(sidebar.recording == (visibleMeeting || visibleDictation), "actual Sidebar capture gates \(mask)")
                        if sidebar.recording {
                            check(sidebar.state == (visibleMeeting ? .weaving : .listening), "actual Sidebar live state \(mask)")
                        }
                    }
                }
                meeting.isRecording = false
                controller.state = .finishing
                check(sidebar.recording == (mask & 1 != 0), "finishing belongs to enabled Dictation \(mask)")
                if sidebar.recording { check(sidebar.state == .working, "finishing draws working orb \(mask)") }
#endif
                func expected(_ requested: SidebarSection) -> SidebarSection {
                    if requested == .settings || requested == .comparison { return .settings }
                    return rows.contains(requested) ? requested : fallback
                }
                for section in SidebarSection.allCases {
                    defaults.set(section.rawValue, forKey: sectionKey)
                    // Default production closures must consult the live Settings collaborator.
                    let restored = NavigationState(defaults: defaults)
                    check(restored.selectedSection == (section == .settings ? fallback : expected(section)),
                          "restore \(section.rawValue), mask=\(mask), index=\(indexOn)")
                    let stored = defaults.string(forKey: sectionKey)
                    check(stored == (section == .settings || section == .comparison ? fallback.rawValue : expected(section).rawValue),
                          "restore persists landing \(section.rawValue), mask=\(mask), index=\(indexOn)")
                    let nav = NavigationState(defaults: defaults)
                    nav.show(section)
                    check(nav.selectedSection == expected(section), "show \(section.rawValue), mask=\(mask)")
                    nav.selectedSection = section // The Sidebar binding bypasses show().
                    check(nav.selectedSection == expected(section), "binding \(section.rawValue), mask=\(mask)")
                    if section != .settings && section != .comparison {
                        check(defaults.string(forKey: sectionKey) == expected(section).rawValue,
                              "binding persists landing \(section.rawValue), mask=\(mask)")
                    }
                }
                for raw in ["", "unknown-section"] {
                    defaults.set(raw, forKey: sectionKey)
                    check(NavigationState(defaults: defaults).selectedSection == fallback, "invalid/default selection mask=\(mask)")
                }
                let nav = NavigationState(defaults: defaults)
                nav.showRoutines(); check(nav.selectedSection == expected(.reminders), "routines helper \(mask)")
                nav.showAgentAbout(); check(nav.selectedSection == expected(.agent), "about helper \(mask)")
                nav.showGraph(); check(nav.selectedSection == expected(.graph), "graph helper \(mask)")
                nav.showSkills(); check(nav.selectedSection == expected(.skills), "skills helper \(mask)")
                nav.showConversation(); check(nav.selectedSection == expected(.agent), "conversation helper \(mask)")
                nav.openMemories(UUID()); check(nav.selectedSection == expected(.agent), "memory helper \(mask)")
                let meetingID = UUID()
                nav.show(meeting: meetingID); check(nav.selectedSection == expected(.meetings), "meeting helper \(mask)")
                nav.show(meeting: meetingID, at: 12); check(nav.selectedSection == expected(.meetings), "transcript helper \(mask)")
#if MOD02
                if mask & 2 == 0 { check(nav.selectedMeetingID == nil && nav.transcriptFocus == nil, "disabled meeting stages no detail request") }
                if mask & 4 == 0 { check(nav.consumePendingMemory() == nil, "disabled Agent stages no memory request") }
#endif
                nav.showComparison()
                check(nav.selectedSection == .settings && nav.selectedSettingsTab == .comparison, "Comparison door \(mask)")
            }
        }
#if MOD02
        settings.modules = Set(AppModule.allCases)
        settings.knowledgeIndexEnabled = true
        let nav = NavigationState(defaults: defaults)
        nav.show(.meetings)
        settings.modules.remove(.meetings)
        check(nav.resolvedSection == .dictation, "detail resolves disabled module before reconciliation")
        nav.reconcileSelection()
        check(nav.selectedSection == .dictation && defaults.string(forKey: sectionKey) == "dictation", "toggle rehomes and persists")
        nav.show(.search)
        settings.knowledgeIndexEnabled = false
        check(nav.resolvedSection == .dictation, "index off resolves Search immediately")
        nav.reconcileSelection()
        check(nav.selectedSection == .dictation, "index off rehomes Search")
        nav.show(.settings)
        settings.modules = []
        nav.reconcileSelection()
        check(nav.selectedSection == .settings && defaults.string(forKey: sectionKey) == "dictionary", "Settings stays open; hidden stored landing repaired")
#endif
        if failures.isEmpty {
            print("MOD02_DRIVER_OK: \(checks) checks; actual NavigationState; 8 combinations")
        } else {
            failures.prefix(30).forEach { print("MOD02_DRIVER_WRONG: \($0)") }
            print("MOD02_DRIVER_FAILED: \(failures.count)/\(checks)")
            exit(1)
        }
    }
}
