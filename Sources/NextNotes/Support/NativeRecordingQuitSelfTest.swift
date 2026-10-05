import AppKit
import Foundation

/// COMMON actual delegate/factory/pipeline regression. This mode intentionally
/// substitutes confirmed recording-stop input; it does not exercise real capture.
@MainActor
enum NativeRecordingQuitSelfTest {
    static let modeFlag = "--native-termination-recording-mode"
    static var isRequested: Bool { CommandLine.arguments.contains(modeFlag) }

    static func arm() async throws {
        let arguments = CommandLine.arguments
        guard SelfTest.isRunning, SelfTest.requested == "--selftest-native-termination",
              arguments.filter({ $0 == modeFlag }).count == 1,
              arguments.filter({ $0 == "--selftest-native-termination" }).count == 1,
              !arguments.contains("--native-termination-model"),
              let position = arguments.firstIndex(of: modeFlag),
              arguments.indices.contains(position + 1),
              ["recording", "idle"].contains(arguments[position + 1]),
              let delegate = AppDelegate.current else { throw CocoaError(.fileReadNoPermission) }
        let mode = arguments[position + 1]
        let recording = mode == "recording"
        let trace = RecordingQuitTrace()
        func check(_ label: String, _ value: Bool) {
            trace.checks += 1
            if !value {
                trace.failures += 1
                SelfTest.failed = true
                SelfTest.diagnostic("NATIVE_RECORDING_QUIT_ASSERT_FAILED: \(label)")
            }
        }
        // Refuse before any preference write or default Notes factory access.
        let settings = Settings.shared
        guard settings.usesHarnessPreferencesForTesting,
              NotesService.sharedIfLoaded == nil else { throw CocoaError(.fileReadNoPermission) }
        check("I01 actual shared Notes owner starts unloaded", NotesService.sharedIfLoaded == nil)
        check("I02 actual preferences are process-owned harness domain", settings.usesHarnessPreferencesForTesting)
        settings.notesAutoGenerate = true
        settings.notesRelatedContext = false

        // COMMON MeetingStore.shared routes only this exact mode to isolated(at:).
        let store = MeetingStore.shared
        let probeID = UUID()
        let root = store.directory(for: probeID).deletingLastPathComponent().standardizedFileURL
        let temporary = FileManager.default.temporaryDirectory.standardizedFileURL.resolvingSymlinksInPath()
        let prefix = "NextNotesMeetingResumeTest-"
        guard root.path == root.resolvingSymlinksInPath().path,
              root.deletingLastPathComponent().path == temporary.path,
              root.lastPathComponent.hasPrefix(prefix),
              UUID(uuidString: String(root.lastPathComponent.dropFirst(prefix.count))) != nil else {
            throw CocoaError(.fileReadNoPermission)
        }
        check("I03 actual shared Meeting store uses canonical generated temporary root", true)
        let meeting = Meeting(title: "Synthetic recording quit", start: Date(timeIntervalSince1970: 1_700_000_000),
                              status: .transcribing)
        let transcript = [TranscriptSegment(start: 0, end: 1,
                                           text: "Synthetic meeting stop handoff.", source: .mic)]
        guard store.save(meeting), store.saveTranscript(transcript, for: meeting.id) else {
            throw CocoaError(.fileWriteUnknown)
        }
        check("I04 real temporary meeting and transcript were saved", store.meeting(id: meeting.id)?.id == meeting.id
              && store.transcript(for: meeting.id).map(\.text) == transcript.map(\.text))
        // Actual default Agent constructor only stores its dependencies. Its fresh
        // auth state is not an account observation; review must exit at isReady.
        let agent = AgentService.shared
        guard !agent.hasCachedAuthStatus, !agent.authState.isSignedIn, !agent.isReady else {
            throw CocoaError(.fileReadNoPermission)
        }
        check("I05 fresh actual Agent readiness rejects followups without an account probe",
              !agent.hasCachedAuthStatus && !agent.authState.isSignedIn && !agent.isReady)
        // A unique unavailable descriptor is only constructor data; the real runtime
        // closes before any count/load. No fake native result or model file is supplied.
        let runtime = NotesModelRuntime(
            spec: ModelSpec(displayName: "Synthetic closed quit owner",
                            fileName: "recording-quit-unused-\(UUID().uuidString).gguf",
                            url: root.appendingPathComponent("unused.gguf"),
                            expectedBytes: 1, expectedSHA256: nil), gpuLayers: 0)
        var assembler = MeetingNotesContextAssembler()
        assembler.memoryEnabled = { false }
        assembler.recallMemory = { _, _ in ([], []) }
        assembler.knowledge = { nil }
        assembler.decisionThreads = { [] }
        assembler.graphCloudConsent = { false }
        assembler.relatedNodes = { _ in [] }
        assembler.files = { EmptyFileRetrieval() }
        assembler.filesCloudConsent = { false }
        try NotesService.configureRecordingQuitSharedFactory(
            store: store,
            providerResolver: { _ in
                trace.providerCalls += 1
                return LlamaLLMProvider(modelName: "Synthetic closed quit owner", runtime: runtime)
            },
            contextAssembler: assembler,
            didCreate: { trace.factoryCreations += 1 }
        )
        try delegate.configureRecordingQuitFixture(
            runtime: runtime, isRecording: recording,
            stop: {
                trace.stopCalls += 1
                var refused = false
                do { _ = try await runtime.countTokens("Synthetic admission check") }
                catch { refused = error is CancellationError }
                check("S01 real runtime is closed before the pipeline handoff", refused)
                guard refused else { return } // failed COMMON prerequisite; no model fallback
                check("S02 confirmed diagnostic stop callback runs exactly once", trace.stopCalls == 1)
                // Default parameter is the ACTUAL lazy NotesService.shared factory.
                let handedOff = MeetingPipeline.afterDiarizing(meeting, store: store)
                check("S03 real pipeline retains exact meeting and summarizing handoff", handedOff.id == meeting.id
                      && handedOff.status == .summarizing)
                guard let service = NotesService.sharedIfLoaded,
                      let queued = service.recordingQuitTaskSnapshotForTesting() else {
                    check("S04 real shared service and exact-case task snapshot exist", false)
                    return
                }
                check("S04 real shared service and exact-case task snapshot exist", trace.factoryCreations == 1
                      && service === NotesService.shared)
                // Freeze these actual queue/owner facts synchronously before any await.
                trace.queuedTasks = queued.count
                trace.closedAtHandoff = service.terminationAdmissionClosedForRecordingQuitTesting == true
                check("S05 quit-closed owner queues no new real Notes Task", queued.isEmpty)
                check("S06 exact pipeline Notes owner was closed before submission", trace.closedAtHandoff)
                // Diagnostic-only join of SAME real Tasks, in BOTH producer versions.
                // Production MeetingController.stop does not await generated notes.
                for task in queued { await task.value }
                let fresh = store.freshReaderForTesting()
                trace.wasSummarizingAfterJoin = fresh.meeting(id: meeting.id)?.status == .summarizing
                trace.wasDoneAfterJoin = fresh.meeting(id: meeting.id)?.status == .done
                check("S07 fresh persisted meeting stays resumable after real Task join", trace.wasSummarizingAfterJoin)
                check("S08 actual Task cleanup and concrete provider call count join", service.ownedTaskCountForTerminationTesting == 0
                      && trace.providerCalls == queued.count)
                check("S09 fresh temporary transcript survives and no notes were fabricated", fresh.transcript(for: meeting.id).map(\.text)
                      == transcript.map(\.text) && fresh.notes(for: meeting.id) == nil)
                SelfTest.diagnostic("NATIVE_RECORDING_QUIT_STOP_TRACE queued=\(trace.queuedTasks) closed=\(trace.closedAtHandoff) providers=\(trace.providerCalls) summarizing=\(trace.wasSummarizingAfterJoin) done=\(trace.wasDoneAfterJoin)")
            },
            reply: { reply in
                check("Q01 actual delegate returns Later", reply == .terminateLater)
                check("Q02 required lazy Notes factory closes before stopping; idle stays unloaded",
                      trace.factoryCreations == (recording ? 1 : 0))
                check("Q03 actual stop has not run synchronously at delegate reply", trace.stopCalls == 0)
                SelfTest.diagnostic("NATIVE_RECORDING_QUIT_REPLY_TRACE recording=\(recording) factories=\(trace.factoryCreations) stopCalls=\(trace.stopCalls) later=\(reply == .terminateLater)")
            },
            willExit: {
                check("E01 actual stop branch matches recording versus idle", trace.stopCalls == (recording ? 1 : 0))
                check("E02 exact default factory constructed at most once", trace.factoryCreations == (recording ? 1 : 0))
                check("E03 joined actual task map is empty in both versions", (NotesService.sharedIfLoaded?.ownedTaskCountForTerminationTesting ?? 0) == 0)
                let fresh = store.freshReaderForTesting()
                let status = fresh.meeting(id: meeting.id)?.status
                check("E04 exit retains exact post-join status; idle remains transcribing",
                      recording ? ((status == .summarizing) == trace.wasSummarizingAfterJoin
                                   && (status == .done) == trace.wasDoneAfterJoin)
                          : status == .transcribing)
                check("E05 no generated notes were published", fresh.notes(for: meeting.id) == nil)
                check("E06 exact saved temporary meeting and transcript survive", fresh.meeting(id: meeting.id)?.id == meeting.id
                      && fresh.transcript(for: meeting.id).map(\.text) == transcript.map(\.text))
                check("E07 harness preference ownership/choices remain exact", settings.usesHarnessPreferencesForTesting
                      && settings.notesAutoGenerate && !settings.notesRelatedContext)
                SelfTest.diagnostic("NATIVE_RECORDING_QUIT_EXIT_TRACE mode=\(mode) factories=\(trace.factoryCreations) stopCalls=\(trace.stopCalls) queued=\(trace.queuedTasks) providers=\(trace.providerCalls) summarizing=\(status == .summarizing) done=\(status == .done) checks=\(trace.checks) failures=\(trace.failures)")
                SelfTest.diagnostic(trace.failures == 0
                    ? "NATIVE_RECORDING_QUIT_OK: \(trace.checks) checks"
                    : "NATIVE_RECORDING_QUIT_FAILED: \(trace.failures)/\(trace.checks)")
                try? FileManager.default.removeItem(at: root)
            }
        )
        SelfTest.diagnostic("NATIVE_RECORDING_QUIT_INPUT_OK: actual shared factories, canonical temporary fixture, mode=\(mode)")
        // Reuse actual standalone AppKit lifetime; quit is a Cocoa run-loop callback.
        SelfTest.requestTermination()
    }
}

@MainActor
private final class RecordingQuitTrace {
    var checks = 0
    var failures = 0
    var factoryCreations = 0
    var stopCalls = 0
    var providerCalls = 0
    var queuedTasks = 0
    var closedAtHandoff = false
    var wasSummarizingAfterJoin = false
    var wasDoneAfterJoin = false
}
