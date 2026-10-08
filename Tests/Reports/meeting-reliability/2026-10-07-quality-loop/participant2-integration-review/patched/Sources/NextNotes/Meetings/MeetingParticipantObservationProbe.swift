import AppKit
import ApplicationServices
import Foundation

/// Explicit, one-shot private evidence collection. Never a capture-path observer,
/// participant parser or voice binding. Existing AX deadlines/CDP reply caps remain open.
enum MeetingParticipantObservationProbe {
    static let flag = "--selftest-meeting-participant-observation"
    static var isRequested: Bool { isAuthorized(isRunning: SelfTest.isRunning, requested: SelfTest.requested) }
    static func isAuthorized(isRunning: Bool, requested: String?) -> Bool {
        isRunning && requested == flag
    }

    struct Observation: Sendable, Codable {
        let platform: String
        let source: String
        let startedAt: Date
        let endedAt: Date
        let status: String
        let processID: Int32?
        let processLaunchedAt: Date?
        let browserTargetID: String?
        let observedURL: String?
        let rawEvidence: String?
        let evidenceWasClipped: Bool
        let traversalCoverage: AccessibilitySnapshot.CaptureCoverage?
        // A process/tab/room URL never proves joined-call or voice identity.
        let callState = "unverified"
        // No platform parser is established. Raw labels never become claimed identities.
        let participantNames: [String] = []
        let activeSpeakerName: String? = nil
    }

    struct ZoomProcess: Sendable, Equatable {
        let processID: Int32
        let bundleIdentifier: String?
        let launchedAt: Date?
        let isTerminated: Bool
    }

    enum Selection: Equatable {
        case selected(Int)
        case unavailable
        case ambiguous
    }

    // These are the exact selectors consumed by the diagnostic, with no focus/ordering guess.
    static func zoomSelection(_ processes: [ZoomProcess]) -> Selection {
        let indices = processes.indices.filter {
            processes[$0].bundleIdentifier == "us.zoom.xos" && !processes[$0].isTerminated
        }
        guard let index = indices.first else { return .unavailable }
        guard indices.count == 1 else { return .ambiguous }
        guard processes[index].processID > 0, processes[index].launchedAt != nil else {
            return .unavailable
        }
        return .selected(index)
    }

    static func meetSelection(_ targets: [BrowserCDPTarget]) -> Selection {
        let indices = targets.indices.filter {
            guard let url = URL(string: targets[$0].url) else { return false }
            return url.scheme?.lowercased() == "https" && url.host?.lowercased() == "meet.google.com"
                && !url.path.isEmpty && url.path != "/"
        }
        guard let index = indices.first else { return .unavailable }
        guard indices.count == 1 else { return .ambiguous }
        let target = targets[index]
        guard !target.id.isEmpty, let socket = URL(string: target.webSocketDebuggerURL),
              ["ws", "wss"].contains(socket.scheme?.lowercased() ?? ""), socket.host != nil else {
            return .unavailable
        }
        return .selected(index)
    }

    private static func empty(platform: String, source: String, began: Date,
                              status: String) -> Observation {
        Observation(platform: platform, source: source, startedAt: began, endedAt: Date(),
            status: status, processID: nil, processLaunchedAt: nil, browserTargetID: nil,
            observedURL: nil, rawEvidence: nil, evidenceWasClipped: false, traversalCoverage: nil)
    }

    /// Uses existing permission only; never opens/focuses Zoom or requests AX access.
    /// AX capture lacks a deadline: invoke only from this explicit diagnostic process.
    @MainActor
    static func zoom(processID: pid_t) -> Observation {
        let began = Date()
        func result(_ status: String, app: NSRunningApplication? = nil,
                    raw: String? = nil,
                    coverage: AccessibilitySnapshot.CaptureCoverage? = nil) -> Observation {
            Observation(platform: "zoom", source: "focused-window-accessibility",
                startedAt: began, endedAt: Date(), status: status,
                processID: processID, processLaunchedAt: app?.launchDate,
                browserTargetID: nil, observedURL: nil,
                rawEvidence: raw.map { String($0.prefix(32_768)) },
                evidenceWasClipped: raw.map { $0.count > 32_768 } ?? false,
                traversalCoverage: coverage)
        }
        guard isRequested else { return result("diagnostic-not-authorized") }
        guard let app = NSRunningApplication(processIdentifier: processID),
              app.bundleIdentifier == "us.zoom.xos", !app.isTerminated,
              let launch = app.launchDate else { return result("zoom-process-unavailable") }
        guard AXIsProcessTrusted() else { return result("accessibility-unavailable", app: app) }
        let captured = AccessibilitySnapshot.captureWithCoverage(processID: processID, limit: 120)
        let raw = captured.snapshot
        guard let current = NSRunningApplication(processIdentifier: processID),
              current.bundleIdentifier == app.bundleIdentifier,
              current.launchDate == launch, !current.isTerminated else {
            return result("process-changed")
        }
        let stub = AccessibilitySnapshot.isStub(raw)
        return result(stub ? "no-observable-window" : "raw-evidence-only", app: app,
            raw: stub ? nil : raw, coverage: captured.coverage)
    }

    @MainActor
    static func meet(targetID: String, expectedURL: String) async throws -> Observation {
        guard isRequested else {
            throw AgentError.backendUnavailable("The participant diagnostic was not requested.")
        }
        let began = Date()
        let raw = try await BrowserCDPClient.meetingParticipantAXObservation(
            targetID: targetID, expectedURL: expectedURL)
        return Observation(platform: "google-meet", source: "browser-accessibility-tree",
            startedAt: began, endedAt: Date(), status: "raw-evidence-only",
            processID: nil, processLaunchedAt: nil, browserTargetID: targetID,
            observedURL: expectedURL, rawEvidence: String(raw.prefix(32_768)),
            evidenceWasClipped: raw.count > 32_768, traversalCoverage: nil)
    }

    /// Private evidence is separate from stdout, --selftest-out and the system log.
    /// This writes no Meeting record, owner defaults or participant-name mapping.
    @MainActor
    private static func savePrivate(_ observation: Observation) throws -> UUID {
        guard isRequested else {
            throw AgentError.backendUnavailable("The participant diagnostic was not requested.")
        }
        let manager = FileManager.default
        guard let support = manager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw CocoaError(.fileWriteUnknown)
        }
        let id = UUID()
        let folder = support.appendingPathComponent("Next Notes/Diagnostics/ParticipantObservation", isDirectory: true)
            .appendingPathComponent(id.uuidString, isDirectory: true)
        try manager.createDirectory(at: folder, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        // Preserve observation-clock fractions; the existing meeting codec is unrelated.
        encoder.dateEncodingStrategy = .secondsSince1970
        let file = folder.appendingPathComponent("observation.json")
        try encoder.encode(observation).write(to: file, options: [.atomic])
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        return id
    }

    @MainActor
    static func run(mode: String?) async -> String {
        guard isRequested else { return "MEETING_PARTICIPANT_OBSERVATION_FAILED: diagnostic-not-authorized" }
        if mode == "contracts" { return contractMarker() }
        let began = Date()
        let observation: Observation
        switch mode {
        case "zoom":
            let apps = NSRunningApplication.runningApplications(withBundleIdentifier: "us.zoom.xos")
            let processes = apps.map {
                ZoomProcess(processID: $0.processIdentifier, bundleIdentifier: $0.bundleIdentifier,
                    launchedAt: $0.launchDate, isTerminated: $0.isTerminated)
            }
            switch zoomSelection(processes) {
            case .selected(let index): observation = zoom(processID: processes[index].processID)
            case .ambiguous: observation = empty(platform: "zoom", source: "running-processes", began: began,
                status: "ambiguous-target")
            case .unavailable: observation = empty(platform: "zoom", source: "running-processes", began: began,
                status: "target-unavailable")
            }
        case "meet":
            guard let probe = await BrowserCDPClient.probe() else {
                return finish(empty(platform: "google-meet", source: "local-browser-debugger", began: began,
                    status: "browser-unavailable"))
            }
            switch meetSelection(probe.targets) {
            case .selected(let index):
                let target = probe.targets[index]
                do { observation = try await meet(targetID: target.id, expectedURL: target.url) }
                catch { observation = empty(platform: "google-meet", source: "browser-accessibility-tree",
                    began: began, status: "read-unavailable") }
            case .ambiguous: observation = empty(platform: "google-meet", source: "local-browser-debugger",
                began: began, status: "ambiguous-target")
            case .unavailable: observation = empty(platform: "google-meet", source: "local-browser-debugger",
                began: began, status: "target-unavailable")
            }
        default: return "MEETING_PARTICIPANT_OBSERVATION_FAILED: expected-zoom-meet-or-contracts"
        }
        return finish(observation)
    }

    @MainActor
    private static func finish(_ observation: Observation) -> String {
        do {
            let id = try savePrivate(observation)
            let verdict = observation.status == "raw-evidence-only" ? "OK" : "FAILED"
            return "MEETING_PARTICIPANT_OBSERVATION_\(verdict): platform=\(observation.platform) status=\(observation.status) private-id=\(id.uuidString) names-unassigned call-state-unverified"
        } catch { return "MEETING_PARTICIPANT_OBSERVATION_FAILED: private-write-unavailable" }
    }

    /// Public generic inputs, no OS/browser reads and no private file writes.
    private static func contractMarker() -> String {
        var failures = 0
        var checks = 0
        func expect(_ condition: Bool) { checks += 1; if !condition { failures += 1 } }
        expect(!isAuthorized(isRunning: false, requested: flag))
        expect(!isAuthorized(isRunning: true, requested: nil))
        expect(!isAuthorized(isRunning: true, requested: "--selftest-meeting-context"))
        expect(isAuthorized(isRunning: true, requested: flag))
        let launch = Date(timeIntervalSince1970: 1_750_000_000.125)
        let live = ZoomProcess(processID: 10, bundleIdentifier: "us.zoom.xos", launchedAt: launch, isTerminated: false)
        let gone = ZoomProcess(processID: 11, bundleIdentifier: "us.zoom.xos", launchedAt: launch, isTerminated: true)
        let foreign = ZoomProcess(processID: 12, bundleIdentifier: "example.foreign", launchedAt: launch, isTerminated: false)
        expect(zoomSelection([]) == .unavailable)
        expect(zoomSelection([foreign, gone]) == .unavailable)
        expect(zoomSelection([foreign, live, gone]) == .selected(1))
        expect(zoomSelection([live, live]) == .ambiguous)
        expect(zoomSelection([ZoomProcess(processID: 10, bundleIdentifier: "us.zoom.xos", launchedAt: nil,
            isTerminated: false)]) == .unavailable)
        expect(zoomSelection([ZoomProcess(processID: 0, bundleIdentifier: "us.zoom.xos", launchedAt: launch,
            isTerminated: false)]) == .unavailable)
        let target = BrowserCDPTarget(id: "generic-target", title: "Generic", url: "https://meet.google.com/abc-defg-hij",
            webSocketDebuggerURL: "ws://127.0.0.1:9222/devtools/page/generic")
        var other = target; other.url = "https://example.invalid/"
        var insecure = target; insecure.url = "http://meet.google.com/abc-defg-hij"
        var lookalike = target; lookalike.url = "https://meet.google.com.example.invalid/abc-defg-hij"
        var landing = target; landing.url = "https://meet.google.com"
        var rootLanding = target; rootLanding.url = "https://meet.google.com/"
        var missingID = target; missingID.id = ""
        var invalidSocket = target; invalidSocket.webSocketDebuggerURL = "https://example.invalid/"
        expect(meetSelection([]) == .unavailable)
        expect(meetSelection([other, insecure, lookalike]) == .unavailable)
        expect(meetSelection([other, target]) == .selected(1))
        expect(meetSelection([target, target]) == .ambiguous)
        expect(meetSelection([landing]) == .unavailable)
        expect(meetSelection([rootLanding]) == .unavailable)
        expect(meetSelection([missingID]) == .unavailable)
        expect(meetSelection([invalidSocket]) == .unavailable)
        let observation = Observation(platform: "zoom", source: "focused-window-accessibility", startedAt: launch,
            endedAt: launch.addingTimeInterval(0.25), status: "raw-evidence-only", processID: 10,
            processLaunchedAt: launch, browserTargetID: nil, observedURL: nil, rawEvidence: "generic unknown label",
            evidenceWasClipped: false, traversalCoverage: nil)
        expect(observation.participantNames.isEmpty && observation.activeSpeakerName == nil)
        expect(observation.callState == "unverified" && observation.traversalCoverage == nil)
        expect(observation.processID == live.processID && observation.processLaunchedAt == launch)
        expect(observation.startedAt == launch && observation.endedAt == launch.addingTimeInterval(0.25))
        return failures == 0 ? "MEETING_PARTICIPANT_OBSERVATION_OK: contracts checks=\(checks) physical-observation-unverified"
            : "MEETING_PARTICIPANT_OBSERVATION_FAILED: contracts failures=\(failures) checks=\(checks)"
    }
}
