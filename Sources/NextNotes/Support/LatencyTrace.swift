import Darwin
import Foundation

/// Named timing spans for the three product pipelines.
///
/// The identifiers match roadmap §35 (dictation / meeting / agent) plus the four
/// splits the dictation tail already prints — drain, transcribe, names, cleanup —
/// so a later call site can record the number it already has rather than inventing
/// a second clock. Nothing here is a live budget: exceeding a target is a number
/// on disk, not a thrown error.
enum LatencySpanID: String, Codable, Sendable, CaseIterable, Hashable {
    // Dictation — §35
    case dictationKeyDownToCapture = "dictation.keyDown_to_capture"
    case dictationSpeechToFirstPartial = "dictation.speech_to_first_partial"
    case dictationKeyUpToASRFinal = "dictation.keyUp_to_asr_final"
    case dictationASRFinalToCleanup = "dictation.asr_final_to_cleanup"
    case dictationCleanupToInjection = "dictation.cleanup_to_injection"
    case dictationKeyUpToInjection = "dictation.keyUp_to_injection"

    // Dictation — existing tail splits (`dictation tail · drain … · transcribe …`)
    case dictationDrain = "dictation.drain"
    case dictationTranscribe = "dictation.transcribe"
    case dictationNames = "dictation.names"
    case dictationCleanup = "dictation.cleanup"

    // Meeting — §35
    case meetingSpeechToPartial = "meeting.speech_to_partial"
    case meetingSpeechToFinal = "meeting.speech_to_final"
    case meetingTranscriptToContext = "meeting.transcript_to_context"
    case meetingActionPhraseToCandidate = "meeting.action_phrase_to_candidate"
    case meetingCandidateToCard = "meeting.candidate_to_card"

    // Agent — §35
    case agentWakeToListeningUI = "agent.wake_to_listening_ui"
    case agentSpeechEndToTranscript = "agent.speech_end_to_transcript"
    case agentTranscriptToFirstToken = "agent.transcript_to_first_token"
    case agentFirstTokenToFirstTTS = "agent.first_token_to_first_tts"
    case agentToolCallToResult = "agent.tool_call_to_result"
    case agentBargeInToTTSStopped = "agent.barge_in_to_tts_stopped"

    // Milestone 1 also asked for model-load timing. One span, the model name in `note`.
    case modelLoad = "model.load"
    case modelQueue = "model.queue"
    case modelContext = "model.context"
    case modelPrefill = "model.prefill"
    case modelFirstToken = "model.first_token"

    // Knowledge Ask / Search — request → retrieve → first answer paint → done
    case askTotal = "ask.total"
    case askProvider = "ask.provider"
    case askRetrieve = "ask.retrieve"
    case askFirstToken = "ask.first_token"
    case askGenerate = "ask.generate"
    case searchTotal = "search.total"
    case searchEmbed = "search.embed"
    case searchQuery = "search.query"

    var pipeline: LatencyPipeline {
        switch self {
        case .dictationKeyDownToCapture, .dictationSpeechToFirstPartial,
             .dictationKeyUpToASRFinal, .dictationASRFinalToCleanup,
             .dictationCleanupToInjection, .dictationKeyUpToInjection,
             .dictationDrain, .dictationTranscribe, .dictationNames, .dictationCleanup:
            return .dictation
        case .meetingSpeechToPartial, .meetingSpeechToFinal, .meetingTranscriptToContext,
             .meetingActionPhraseToCandidate, .meetingCandidateToCard:
            return .meeting
        case .agentWakeToListeningUI, .agentSpeechEndToTranscript,
             .agentTranscriptToFirstToken, .agentFirstTokenToFirstTTS,
             .agentToolCallToResult, .agentBargeInToTTSStopped:
            return .agent
        case .modelLoad, .modelQueue, .modelContext, .modelPrefill, .modelFirstToken:
            return .model
        case .askTotal, .askProvider, .askRetrieve, .askFirstToken, .askGenerate,
             .searchTotal, .searchEmbed, .searchQuery:
            return .knowledge
        }
    }

    /// Suggested upper bound from `LatencyBudget` (roadmap §36), if one is named.
    ///
    /// Documentation, not a gate. Production paths must not assert on this.
    var target: Duration? {
        switch self {
        case .dictationKeyDownToCapture: LatencyBudget.Dictation.wakeToCapture
        case .dictationSpeechToFirstPartial: LatencyBudget.Dictation.firstPartialASR
        case .dictationKeyUpToInjection: LatencyBudget.Dictation.keyUpToFinal
        case .dictationCleanupToInjection: LatencyBudget.Dictation.injectionAfterFormat
        case .meetingSpeechToPartial: LatencyBudget.Meeting.speechToPartial
        case .meetingSpeechToFinal: LatencyBudget.Meeting.speechToFinal
        case .meetingActionPhraseToCandidate: LatencyBudget.Meeting.actionDetection
        case .agentWakeToListeningUI: LatencyBudget.Agent.wakeToListeningUI
        case .agentSpeechEndToTranscript: LatencyBudget.Agent.speechEndToResponse
        case .agentFirstTokenToFirstTTS: LatencyBudget.Agent.firstTTSAudio
        case .agentBargeInToTTSStopped: LatencyBudget.Agent.bargeInStop
        default: nil
        }
    }
}

enum LatencyPipeline: String, Codable, Sendable {
    case dictation
    case meeting
    case agent
    case model
    case knowledge
}

/// Optional identity propagated through child tasks for an interactive model turn.
/// Callers wrap work with `LatencyCorrelation.$current.withValue(identity) { ... }`.
struct LatencyCorrelation: Codable, Sendable, Equatable {
    let sessionID: UUID?
    let workID: UUID?
    let revision: Int?

    @TaskLocal static var current: LatencyCorrelation?

    init(sessionID: UUID? = nil, workID: UUID? = nil, revision: Int? = nil) {
        self.sessionID = sessionID
        self.workID = workID
        self.revision = revision
    }
}

/// Engineering targets from roadmap §36. Not hard promises, and not asserted on
/// any production path — they exist so a later dashboard has numbers to compare
/// against rather than inventing them at the call site.
enum LatencyBudget {
    enum Dictation {
        /// Wake / capture start: <100 ms.
        static let wakeToCapture: Duration = .milliseconds(100)
        /// First partial ASR: typical 300–500 ms. Stored as the upper end.
        static let firstPartialASR: Duration = .milliseconds(500)
        /// Key release → final text: typical 300–700 ms. Stored as the upper end.
        static let keyUpToFinal: Duration = .milliseconds(700)
        /// Injection: <50 ms after formatting.
        static let injectionAfterFormat: Duration = .milliseconds(50)
    }

    enum Meeting {
        /// Speech → visible partial: <500 ms.
        static let speechToPartial: Duration = .milliseconds(500)
        /// Speech → stable text: <1–2 s. Stored as the upper end.
        static let speechToFinal: Duration = .seconds(2)
        /// Action detection: <2 s after the relevant sentence.
        static let actionDetection: Duration = .seconds(2)
    }

    enum Agent {
        /// Wake → visual ACK: <100 ms.
        static let wakeToListeningUI: Duration = .milliseconds(100)
        /// Speech end → response: <500–1000 ms for a local / simple answer.
        static let speechEndToResponse: Duration = .milliseconds(1_000)
        /// First TTS audio: <300–500 ms after the reply begins.
        static let firstTTSAudio: Duration = .milliseconds(500)
        /// Barge-in stop: <100 ms.
        static let bargeInStop: Duration = .milliseconds(100)
    }
}

/// Cheap host and process snapshot taken when a span closes. CPU values are cumulative
/// process time; comparing snapshots gives the CPU spent between two stages. The optional
/// fields keep older `metrics.jsonl` rows decodable after this instrumentation is added.
/// GPU / ANE utilization is not inferred from CPU or memory measurements.
struct ProcessSnapshot: Codable, Sendable, Equatable {
    var processorCount: Int
    var activeProcessorCount: Int
    var physicalMemoryBytes: UInt64
    var thermalState: String
    var isLowPowerModeEnabled: Bool
    var hostUptime: TimeInterval
    var residentMemoryBytes: UInt64?
    var peakResidentMemoryBytes: UInt64?
    var userCPUSeconds: Double?
    var systemCPUSeconds: Double?

    static func current() -> ProcessSnapshot {
        let info = ProcessInfo.processInfo
        var task = mach_task_basic_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout.size(ofValue: task) / MemoryLayout<integer_t>.size
        )
        let taskStatus = withUnsafeMutablePointer(to: &task) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        var usage = rusage()
        let usageStatus = getrusage(RUSAGE_SELF, &usage)
        func seconds(_ value: timeval) -> Double {
            Double(value.tv_sec) + Double(value.tv_usec) / 1_000_000
        }
        return ProcessSnapshot(
            processorCount: info.processorCount,
            activeProcessorCount: info.activeProcessorCount,
            physicalMemoryBytes: info.physicalMemory,
            thermalState: Self.label(info.thermalState),
            isLowPowerModeEnabled: info.isLowPowerModeEnabled,
            hostUptime: info.systemUptime,
            residentMemoryBytes: taskStatus == KERN_SUCCESS ? UInt64(task.resident_size) : nil,
            peakResidentMemoryBytes: usageStatus == 0 ? UInt64(usage.ru_maxrss) : nil,
            userCPUSeconds: usageStatus == 0 ? seconds(usage.ru_utime) : nil,
            systemCPUSeconds: usageStatus == 0 ? seconds(usage.ru_stime) : nil
        )
    }

    private static func label(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: "nominal"
        case .fair: "fair"
        case .serious: "serious"
        case .critical: "critical"
        @unknown default: "unknown"
        }
    }
}

/// One closed timing span. Wall-clock stamps line up with `runs.jsonl`; duration
/// comes from the monotonic clock so a time-zone step cannot invent a 3600 s tail.
struct LatencySpan: Codable, Sendable, Identifiable, Equatable {
    var id: UUID
    var name: LatencySpanID
    var pipeline: LatencyPipeline
    var startedAt: Date
    var endedAt: Date
    var durationSeconds: Double
    var process: ProcessSnapshot
    var note: String?
    var correlation: LatencyCorrelation?

    init(
        id: UUID = UUID(),
        name: LatencySpanID,
        startedAt: Date,
        endedAt: Date,
        durationSeconds: Double,
        process: ProcessSnapshot = .current(),
        note: String? = nil,
        correlation: LatencyCorrelation? = LatencyCorrelation.current
    ) {
        self.id = id
        self.name = name
        self.pipeline = name.pipeline
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.durationSeconds = durationSeconds
        self.process = process
        self.note = note
        self.correlation = correlation
    }
}

/// Starts and closes a named span, then hands it to `MetricsStore`.
///
/// Info-level os_log lines age out within minutes, which is why the store writes
/// JSONL rather than trusting the unified log. Call sites come later — this type
/// is the seam, not the instrumentation of any controller.
struct LatencyTrace: Sendable {
    let name: LatencySpanID
    let startedAt: Date
    let startedNanos: UInt64

    static func start(_ name: LatencySpanID) -> LatencyTrace {
        LatencyTrace(
            name: name,
            startedAt: Date(),
            startedNanos: monotonicNanos()
        )
    }

    /// Closes the span from the monotonic clock and persists it.
    @discardableResult
    func end(note: String? = nil, store: MetricsStore = .shared) -> LatencySpan {
        let endedNanos = monotonicNanos()
        let endedAt = Date()
        let seconds = Double(endedNanos &- startedNanos) / 1_000_000_000
        return Self.persist(
            LatencySpan(
                name: name,
                startedAt: startedAt,
                endedAt: endedAt,
                durationSeconds: seconds,
                note: note
            ),
            to: store
        )
    }

    /// Records a span that was already timed elsewhere.
    ///
    /// The dictation tail already has `Date().timeIntervalSince(began)` splits;
    /// timing those a second time would be a different number for the same work.
    @discardableResult
    static func record(
        _ name: LatencySpanID,
        seconds: Double,
        endedAt: Date = Date(),
        note: String? = nil,
        store: MetricsStore = .shared
    ) -> LatencySpan {
        persist(
            LatencySpan(
                name: name,
                startedAt: endedAt.addingTimeInterval(-seconds),
                endedAt: endedAt,
                durationSeconds: seconds,
                note: note
            ),
            to: store
        )
    }

    @discardableResult
    static func persist(_ span: LatencySpan, to store: MetricsStore = .shared) -> LatencySpan {
        store.record(span)
        if SelfTest.requested == "--selftest-voice-pipeline" {
            Task { @MainActor in
                SelfTest.diagnostic("VOICE_PIPELINE_SPAN=\(span.name.rawValue) \(String(format: "%.3f", span.durationSeconds))s \(span.note ?? "")")
            }
        }
        Log.metrics.info(
            "span · \(span.name.rawValue, privacy: .public) · \(span.durationSeconds, format: .fixed(precision: 3))s"
        )
        return span
    }

    /// Records one fake span against an isolated store and fails if that span is
    /// missing in memory or on disk. Never touches `RunLog`.
    ///
    /// The harness wires `--selftest-metrics` later; until then this is the
    /// function to call: `LatencyTrace.runSelfTest()`.
    @discardableResult
    static func runSelfTest() -> Bool {
        var failures: [String] = []

        let uniqueIDs = Set(LatencySpanID.allCases.map(\.rawValue))
        if uniqueIDs.count != LatencySpanID.allCases.count {
            failures.append("LatencySpanID raw values are not unique")
        }
        if LatencySpanID.allCases.isEmpty {
            failures.append("LatencySpanID has no cases")
        }

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("nextnotes-metrics-selftest-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        } catch {
            failures.append("could not create the self-test directory: \(error.localizedDescription)")
            for failure in failures { print("METRICS_WRONG: \(failure)") }
            print("METRICS_FAILED")
            return false
        }

        let store = MetricsStore(directory: root)
        let marker = "selftest-\(UUID().uuidString)"
        let correlation = LatencyCorrelation(
            sessionID: UUID(), workID: UUID(), revision: 2
        )
        let span = LatencyCorrelation.$current.withValue(correlation) {
            LatencyTrace.start(.dictationDrain).end(note: marker, store: store)
        }
        if span.correlation != correlation {
            failures.append("TaskLocal correlation did not reach the persisted span")
        }

        if span.process.residentMemoryBytes == nil || span.process.residentMemoryBytes == 0 {
            failures.append("process resident memory was not sampled")
        }
        if span.process.userCPUSeconds == nil || span.process.systemCPUSeconds == nil {
            failures.append("process CPU time was not sampled")
        }

        if store.span(id: span.id) == nil {
            failures.append("fake span \(span.id.uuidString) missing from the in-memory ring")
        }
        if store.spans(named: .dictationDrain).contains(where: { $0.note == marker }) == false {
            failures.append("fake span note \(marker) missing from the in-memory ring")
        }

        let fileURL = store.fileURL
        guard let data = try? Data(contentsOf: fileURL), !data.isEmpty else {
            failures.append("metrics.jsonl was not written")
            for failure in failures { print("METRICS_WRONG: \(failure)") }
            print("METRICS_FAILED")
            return false
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let fromDisk: [LatencySpan] = data.split(separator: 0x0A).compactMap { line in
            try? decoder.decode(LatencySpan.self, from: Data(line))
        }
        if fromDisk.contains(where: { $0.id == span.id }) == false {
            failures.append("fake span \(span.id.uuidString) missing from metrics.jsonl")
        }
        if fromDisk.contains(where: { $0.note == marker }) == false {
            failures.append("fake span note \(marker) missing from metrics.jsonl")
        }
        if fromDisk.first(where: { $0.id == span.id })?.correlation != correlation {
            failures.append("correlation missing from metrics.jsonl")
        }
        if let encoded = try? JSONEncoder().encode(span),
           var legacy = (try? JSONSerialization.jsonObject(with: encoded)) as? [String: Any] {
            legacy.removeValue(forKey: "correlation")
            if let legacyData = try? JSONSerialization.data(withJSONObject: legacy),
               let decoded = try? JSONDecoder().decode(LatencySpan.self, from: legacyData) {
                if decoded.correlation != nil {
                    failures.append("legacy span unexpectedly acquired correlation")
                }
            } else {
                failures.append("legacy span without correlation did not decode")
            }
        } else {
            failures.append("could not construct legacy span fixture")
        }

        let reloaded = MetricsStore(directory: root)
        if reloaded.span(id: span.id) == nil {
            failures.append("fake span \(span.id.uuidString) missing after reload from disk")
        }

        for failure in failures { print("METRICS_WRONG: \(failure)") }
        if failures.isEmpty {
            print("METRICS_OK")
            return true
        }
        print("METRICS_FAILED")
        return false
    }
}

/// `CLOCK_UPTIME_RAW` is what `ContinuousClock` uses on Apple platforms: it does
/// not tick while the machine is asleep, so a lid-close cannot inflate a span.
private func monotonicNanos() -> UInt64 {
    clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
}
