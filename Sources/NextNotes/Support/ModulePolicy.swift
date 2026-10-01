/// The three independently enabled features. Their choices live in `Settings`.
enum AppModule: CaseIterable, Hashable, Sendable {
    case dictation
    case meetings
    case assistant
}

/// Pure module decisions shared by navigation, setup and runtime gates.
/// No stored state, model selection, downloads or access to `Settings.shared`.
enum ModulePolicy {
    static func isEnabled(_ module: AppModule, dictation: Bool, meetings: Bool,
                          assistant: Bool) -> Bool {
        switch module {
        case .dictation: dictation
        case .meetings: meetings
        case .assistant: assistant
        }
    }

    /// Settings stays outside the section group; Dictionary is always available.
    static func visibleSections(for modules: Set<AppModule>,
                                knowledgeIndexEnabled: Bool) -> [SidebarSection] {
        SidebarSection.allCases.filter { section in
            switch section {
            case .dictation: modules.contains(.dictation)
            case .meetings: modules.contains(.meetings)
            case .agent, .graph, .portrait, .ideas, .goals, .reminders, .skills:
                modules.contains(.assistant)
            case .search:
                knowledgeIndexEnabled && (modules.contains(.meetings) || modules.contains(.assistant))
            case .dictionary: true
            case .comparison, .settings: false
            }
        }
    }

    /// Initial routing sketch only; MOD-08 adds the module picker and model offers.
    /// Dictation cleanup may use a local model, so Dictation alone keeps the setup step.
    static func onboardingSteps(for modules: Set<AppModule>) -> [OnboardingStep] {
        OnboardingStep.allCases.filter { step in
            switch step {
            case .welcome, .allSet: true
            case .dictation, .shortcut: modules.contains(.dictation)
            case .meetings: modules.contains(.meetings)
            case .files: modules.contains(.assistant)
            case .brain: !modules.isEmpty
            }
        }
    }

    static func firstEnabledSection(dictation: Bool, meetings: Bool,
                                    assistant: Bool) -> SidebarSection {
        if dictation { return .dictation }
        if meetings { return .meetings }
        if assistant { return .agent }
        return .dictionary
    }

    /// Normalize navigation and its detail consumer through the same module matrix.
    static func resolvedSection(_ requested: SidebarSection, for modules: Set<AppModule>,
                                knowledgeIndexEnabled: Bool) -> SidebarSection {
        if requested == .settings || requested == .comparison { return .settings }
        if visibleSections(for: modules, knowledgeIndexEnabled: knowledgeIndexEnabled).contains(requested) {
            return requested
        }
        return firstEnabledSection(dictation: modules.contains(.dictation),
            meetings: modules.contains(.meetings), assistant: modules.contains(.assistant))
    }
}
