import AppKit
import SwiftUI
import Observation
import Darwin

// Only external dependencies are stand-ins. MeetingLiveView, TranscriptView,
// orb geometry/drawing, dotted field, counter and bar meter compile from repo source.
enum DS {
    enum Color {
        static let text = SwiftUI.Color.primary
        static let textSecondary = SwiftUI.Color.secondary
        static let textTertiary = SwiftUI.Color.gray
        static let accent = SwiftUI.Color.blue
        static let record = SwiftUI.Color.red
        static let warning = SwiftUI.Color.orange
        static let meterTrack = SwiftUI.Color.gray.opacity(0.2)
        static let meterNominal = SwiftUI.Color.green
        static let meterHot = SwiftUI.Color.orange
        static let meterPeak = SwiftUI.Color.red
        static func speaker(named: String) -> SwiftUI.Color { .blue }
    }
    enum Font {
        static let title3 = SwiftUI.Font.title3
        static let caption = SwiftUI.Font.caption
        static let subheadline = SwiftUI.Font.subheadline
        static let transcript = SwiftUI.Font.body
        static let emptyStateTitle = SwiftUI.Font.title2
        static let emptyStateMessage = SwiftUI.Font.body
        static let timestamp = SwiftUI.Font.caption.monospacedDigit()
        static let counter = SwiftUI.Font.body.monospacedDigit()
        static let counterSmall = SwiftUI.Font.caption.monospacedDigit()
        static let chip = SwiftUI.Font.caption
    }
    enum Space {
        static let xxs: CGFloat = 2, xs: CGFloat = 4, s: CGFloat = 8
        static let m: CGFloat = 12, l: CGFloat = 16, xl: CGFloat = 24
    }
    enum Size {
        static let orbInline: CGFloat = 20, orbLarge: CGFloat = 64, orbInlineCeiling: CGFloat = 96
        static let trackLabelWidth: CGFloat = 56, emptyStateWidth: CGFloat = 340, readingWidth: CGFloat = 680
        static let chipColumn: CGFloat = 52, recordDot: CGFloat = 10, recordDotCompact: CGFloat = 8
        static let levelBarHeight: CGFloat = 6, levelBarPeakWidth: CGFloat = 2, speakerDot: CGFloat = 8
    }
    enum Opacity { static let field = 0.1, fieldFaint = 0.06, recordPulseLow = 0.35 }
    enum Field {
        static let dot: CGFloat = 1.5, spacing: CGFloat = 14
        static let inkLevels = 8
        static let falloff = 1.6, reach = 0.92
    }
    enum Motion {
        static let standard = Animation.easeInOut(duration: 0.2)
        static let recordPulse = Animation.easeInOut(duration: 1).repeatForever(autoreverses: true)
        static let barSettle = 2.0, barAttack = 0.05, barRelease = 0.25, peakHold = 1.0
    }
    enum Meter { static let hotPoint = 0.7, peakPoint = 0.9 }
}
enum AudioSource: Hashable { case mic, system }
struct TranscriptSegment: Identifiable {
    let id = UUID()
    var start: Double, end: Double, text: String, source: AudioSource
    var displaySpeaker: String { source == .mic ? "You" : "Others" }
    var includeInMeetingNotes: Bool { true }
}
struct Meeting { let id = UUID(); var title = "Generated meeting rendering diagnostic"; var speakerNames: [String:String] = [:] }
struct Warning { var message: String }
@MainActor @Observable final class MeetingSession {
    var meeting = Meeting()
    var segments: [TranscriptSegment] = []
    var provisionalText: [AudioSource:String] = [:]
    var micLevel: Float = 0
    var systemLevel: Float = 0
    var elapsed = 0.0
    var isRecording = true
    var liveTranscriptPaused = false
    var systemAudioProblem: String?
    var audioProblem: String?
    var healthWarnings: [String] = []
}
extension String { var message: String { self } }
@MainActor final class MeetingController { static let shared = MeetingController(); func stop() async {} }
@MainActor final class MeetingStore { static let shared = MeetingStore(); func rename(_ meeting: Meeting, to title: String) {} }
enum SelfTest { static let isRunning = true }
enum MeetingConsolePolicy { static func shouldPresent(isSelfTest: Bool) -> Bool { false } }
@MainActor final class MeetingConsoleWindowController { static let shared = MeetingConsoleWindowController(); func show(session: MeetingSession) {} }
struct RenameMeetingSheet: View { let meeting: Meeting; let action: (String) -> Void; var body: some View { EmptyView() } }
enum Permissions { static func openSystemAudioSettings() {} }
enum NavigationState { struct TranscriptFocus: Equatable { var time: Double } }
struct SpeakerLabel: View {
    let name: String, color: SwiftUI.Color
    var body: some View { Text(name).font(.caption).foregroundStyle(color) }
}

@main @MainActor struct UIAllocationProbe {
    static func footprint() -> UInt64 {
        var v = task_vm_info_data_t()
        var n = mach_msg_type_number_t(MemoryLayout.size(ofValue:v)/MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &v) { p in
            p.withMemoryRebound(to: integer_t.self, capacity: Int(n)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &n) }
        }
        return result == KERN_SUCCESS ? UInt64(v.phys_footprint) : 0
    }
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let session = MeetingSession()
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 900, height: 650), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "Next Notes — generated rendering diagnostic"
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: MeetingLiveView(session: session))
        window.orderFrontRegardless()
        let began = Date(), baseline = footprint()
        let burst = CommandLine.arguments.contains("--burst")
        let duration = burst ? 120.0 : 35.0
        let ticksPerSecond = burst ? 50 : 10
        print("UI_PROBE_BASELINE bytes=\(baseline)")
        Task { @MainActor in
            var tick = 0, peak = baseline
            while Date().timeIntervalSince(began) < duration {
                session.elapsed = Date().timeIntervalSince(began)
                session.micLevel = Float(0.4 + 0.3 * sin(session.elapsed))
                session.systemLevel = Float(0.4 + 0.3 * cos(session.elapsed))
                if tick % (ticksPerSecond * 3) == 0 {
                    session.segments.append(.init(start: session.elapsed, end: session.elapsed + 1, text: "Generated speech for live transcript allocation measurement.", source: tick % (ticksPerSecond * 6) == 0 ? .mic : .system))
                }
                if tick % ticksPerSecond == 0 {
                    let bytes = footprint(); peak = max(peak, bytes)
                    print("UI_PROBE_SAMPLE seconds=\(String(format: "%.1f", session.elapsed)) bytes=\(bytes) segments=\(session.segments.count)")
                    if bytes == 0 || bytes > baseline + 512_000_000 {
                        print("UI_PROBE_ABORT bytes=\(bytes) bounded_limit=\(baseline + 512_000_000)")
                        window.close(); exit(2)
                    }
                }
                tick += 1
                try? await Task.sleep(for: .milliseconds(burst ? 20 : 100))
            }
            print("UI_PROBE_OK peak_bytes=\(peak) final_bytes=\(footprint()) generated=true models=false physical_capture=false")
            window.close(); exit(0)
        }
        app.run()
    }
}
