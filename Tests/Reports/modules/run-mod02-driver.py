#!/usr/bin/env python3
"""Compile the full production navigation producer against tiny isolated collaborators."""
import pathlib
import subprocess
import sys
import tempfile


def declaration(text, marker):
    start = text.index(marker)
    opening = text.index("{", start)
    depth, end = 1, opening + 1
    while depth:
        depth += (text[end] == "{") - (text[end] == "}")
        end += 1
    return text[start:end]

ROOT = pathlib.Path(__file__).resolve().parents[3]
SOURCE = ROOT / "Sources/NextNotes"
onboarding = (SOURCE / "UI/Onboarding/OnboardingFlow.swift").read_text()
start = onboarding.index("enum OnboardingStep")
opening = onboarding.index("{", start)
depth, end = 1, opening + 1
while depth:
    depth += (onboarding[end] == "{") - (onboarding[end] == "}")
    end += 1
collaborators = "import Foundation\n" + onboarding[start:end] + "\n" + '''
enum SettingsTab { case general, comparison }
enum SelfTest { static let isRunning = true }
@MainActor enum SelfTestHarnessDefaults {
    static let suiteName = "NextNotes-MOD02-Shared-\\(UUID().uuidString)"
    static let shared = UserDefaults(suiteName: suiteName)!
}
@MainActor final class Settings {
    static let shared = Settings()
    var modules: Set<AppModule> = [.dictation, .meetings]
    var knowledgeIndexEnabled = true
    func isModuleEnabled(_ module: AppModule) -> Bool { modules.contains(module) }
}
'''
if "--baseline" not in sys.argv:
    sidebar = (SOURCE / "UI/Sidebar.swift").read_text()
    window = (SOURCE / "UI/MainWindow.swift").read_text()
    assert "switch navigation.resolvedSection" in window, "detail must switch on normalized selection"
    assert "navigation.reconcileSelection()" in window and ".onChange(of:" in window
    for key in ["moduleDictationEnabled", "moduleMeetingsEnabled", "agentEnabled", "knowledgeIndexEnabled"]:
        assert "settings." + key in window, "live reconciliation must observe " + key
    collaborators += '''
enum OrbGeometry { enum State { case weaving, working, listening } }
enum CaptureState {
    case idle, listening, finishing
    init(isActive: Bool = false) { self = isActive ? .listening : .idle }
    var isActive: Bool { self != .idle }
}
final class DictationController { var state = CaptureState() }
final class MeetingController { var isRecording = false; var elapsed: TimeInterval = 0 }
@MainActor struct SidebarProbe {
    let settings: Settings
    let controller: DictationController
    let meetings: MeetingController
    var rows: [SidebarSection] { visibleSections }
    var recording: Bool { isRecording }
    var state: OrbGeometry.State { liveState }
'''
    for marker in ["private var visibleSections:", "private var meetingIsRecording:",
                   "private var dictationIsRecording:", "private var isRecording:", "private var liveState:"]:
        collaborators += declaration(sidebar, marker) + "\n"
    collaborators += "}\n"
with tempfile.TemporaryDirectory(prefix="nextnotes-mod02-") as temporary:
    folder = pathlib.Path(temporary)
    types = folder / "Collaborators.swift"
    types.write_text(collaborators)
    navigation = SOURCE / "Support/NavigationState.swift"
    policy = SOURCE / "Support/ModulePolicy.swift"
    if "--baseline" in sys.argv:
        # Replay the unmodified decisions from committed MOD-01, adding only storage injection.
        before = subprocess.check_output(["git", "show", "450dbaa:Sources/NextNotes/Support/NavigationState.swift"],
                                         cwd=ROOT, text=True)
        before = before.replace("    private init() {", """    @ObservationIgnored private let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults""")
        before = before.replace("UserDefaults.standard", "defaults")
        baseline = folder / "NavigationStateBefore.swift"
        baseline.write_text(before)
        navigation = baseline
    if "--omit-normalization" in sys.argv:
        mutated = folder / "NavigationState.swift"
        text = navigation.read_text().replace("section = resolve(newValue)", "section = newValue // mutation: skip setter normalization")
        assert text != navigation.read_text(), "normalization mutation must actually alter producer"
        mutated.write_text(text)
        navigation = mutated
    flags = [] if "--baseline" in sys.argv else ["-D", "MOD02"]
    binary = folder / "mod02-driver"
    subprocess.run(["xcrun", "swiftc", "-swift-version", "6", "-parse-as-library", *flags,
                    str(types), str(navigation), str(policy),
                    str(ROOT / "Tests/Reports/modules/mod02-driver.swift"), "-o", str(binary)], check=True)
    sys.exit(subprocess.run([str(binary)]).returncode)
