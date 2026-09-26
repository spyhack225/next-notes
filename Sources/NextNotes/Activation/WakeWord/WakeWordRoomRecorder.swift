import AVFoundation
import AppKit
import Darwin
import Foundation

/// `--wake-mic-record [count]`: records real-room "Hey Will" captures for the wake self-test.
///
/// `--selftest-wake-live` is measured red at the shipped sensitivity, and AGENTS.md is
/// explicit that the remaining fix is real-room recordings rather than a lowered bar: the
/// committed set is synth (`say` + `afconvert`) and `WAKE_MIC` has no captures on a machine
/// that has not recorded any. This flag is how a person produces those captures without
/// leaving the app — it is the `--fake-calendar`-shaped modifier for that gap.
///
/// **It is not a self-test.** It is interactive (beeps, a person speaking), so it must not
/// run under the harness: `SelfTest.isRunning` is never set here, it refuses to run when a
/// `--selftest-*` flag is also present, and it is deliberately absent from
/// `Scripts/acceptance.sh`'s catalogue.
///
/// Behaviour:
/// - Prints the phrase the fixture set grades, where the files go, and what each clip is.
/// - Per clip: three system beeps, then roughly two seconds from the default input device,
///   saved as 16 kHz mono 16-bit WAV (`mic-<timestamp>-<nn>.wav`) in
///   `WakeWordLiveSelfTest.liveFixturesDirectory`. Nothing else is ever written, and an
///   existing capture is never overwritten.
/// - `0` is a dry run: the output directory is printed and the microphone is untouched.
/// - Ctrl-C stops early, reports what was saved, and exits 0.
/// - On completion, prints the next command and the `WAKE_MIC m/M` line to expect.
///
/// Microphone capture is a local `AVAudioEngine` input tap rather than
/// `AudioCaptureHub`: the hub is a `@MainActor` singleton shared with dictation, meetings
/// and the wake monitor, and the whole point of the early branch in
/// `applicationDidFinishLaunching` is that none of those are running. The three failure
/// modes (no input device, TCC-denied microphone, the device dying mid-run) each print one
/// plain sentence and exit non-zero.
///
/// The recorder is launched through the app bundle's `applicationDidFinishLaunching`, so a
/// shell-launched binary can be judged as the shell's child for TCC; the denial text says
/// how to relaunch through LaunchServices. `--selftest-out <path>` is honoured as an output
/// mirror because a LaunchServices launch has no stdout.
@MainActor
enum WakeWordRoomRecorder {
    static let flag = "--wake-mic-record"
    /// D7's manual tally is twenty clips across a day; twenty is the default here too.
    static let defaultCount = 20
    /// Roughly two seconds is enough for the phrase plus a beat of silence after it.
    static let recordSeconds: TimeInterval = 2
    static let sampleRate: Double = 16_000
    private static let beepSpacing = Duration.milliseconds(700)
    private static let pauseBetweenClips = Duration.milliseconds(1200)

    /// What followed the flag: a count, nothing, or something that is not a count.
    enum CountArgument: Equatable {
        case absent
        case count(Int)
        case invalid(String)
    }

    static var isRequested: Bool {
        CommandLine.arguments.dropFirst().contains(flag)
    }

    /// A flag is never a value: the argument after the flag is the count only when it does
    /// not itself begin with `--`. Missing or flag-shaped means the default; a non-numeric
    /// value is refused rather than silently treated as the default.
    static func countArgument(_ arguments: [String] = CommandLine.arguments) -> CountArgument {
        guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else {
            return .absent
        }
        let next = arguments[index + 1]
        guard !next.hasPrefix("--") else { return .absent }
        guard let value = Int(next), value >= 0 else { return .invalid(next) }
        return .count(value)
    }

    /// Runs the recorder and exits the process. Non-zero on every failure path.
    static func runAndExit() {
        // The process has no status item, window or agent keeping it alive; without this a
        // quiet minute could be read as "nothing is running" and the app would exit
        // mid-recording.
        ProcessInfo.processInfo.disableAutomaticTermination("wake-mic-record is recording")
        installInterruptHandler()
        Task { @MainActor in
            exit(await run())
        }
    }

    // MARK: - Run

    private static var savedClips = 0
    private static var requestedClips = 0
    private static var outputDirectory: URL?
    private static var interruptSource: DispatchSourceSignal?

    private static func run() async -> Int32 {
        guard !SelfTest.isRunning else {
            say("wake-mic-record: refusing to run under the self-test harness"
                + " (\(SelfTest.requested ?? "a --selftest flag") was also passed) — this is interactive.")
            return 2
        }

        let count: Int
        switch countArgument() {
        case .absent:
            count = defaultCount
        case .count(let value):
            count = value
        case .invalid(let raw):
            say("wake-mic-record: “\(raw)” is not a whole number of clips — pass a count like 20,"
                + " or 0 for a dry run.")
            return 2
        }

        let directory = WakeWordLiveSelfTest.liveFixturesDirectory
        let phrase = WakeWordLiveSelfTest.currentManifestPhrase() ?? "Hey Will"

        say("wake-mic-record: real-room captures for --selftest-wake-live")
        say("  phrase to say: “\(phrase)”")
        say("  files go to:   \(directory.path)")
        say("  they stay on this Mac and are never committed")
        say("  each clip: 3 beeps, then ~\(Int(recordSeconds))s of audio — speak right after the last beep")

        if count == 0 {
            say("wake-mic-record: dry run — 0 clips requested, the microphone was not touched.")
            return 0
        }
        say("wake-mic-record: \(count) clip(s) requested; Ctrl-C stops early and reports what was saved.")
        requestedClips = count

        guard AVCaptureDevice.default(for: .audio) != nil else {
            say("wake-mic-record: no microphone input device is connected — connect one and run again.")
            return 1
        }
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            break
        case .notDetermined:
            say("wake-mic-record: asking macOS for microphone access…")
            guard await requestMicrophoneAccess() else { return reportMicrophoneDenied() }
        case .denied, .restricted:
            return reportMicrophoneDenied()
        @unknown default:
            return reportMicrophoneDenied()
        }

        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            say("wake-mic-record: couldn’t create \(directory.path): \(error.localizedDescription)")
            return 1
        }
        savedClips = 0
        outputDirectory = directory

        for index in 1...count {
            say("")
            say("wake-mic-record: clip \(index) of \(count) — get ready")
            for remaining in stride(from: 3, through: 1, by: -1) {
                say("  \(remaining)…")
                NSSound.beep()
                try? await Task.sleep(for: beepSpacing)
            }
            say("  recording \(Int(recordSeconds))s — say “\(phrase)”")

            switch await captureClip() {
            case .failed(let reason):
                say("wake-mic-record: \(reason)")
                return 1
            case .captured(let samples):
                let peak = samples.reduce(Float(0)) { max($0, abs($1)) }
                guard peak > 0 else {
                    say("wake-mic-record: the capture is digital silence — the microphone is muted,"
                        + " or this process has no microphone grant. Nothing was saved.")
                    return 1
                }
                let url = uniqueURL(in: directory, index: index)
                do {
                    try write(samples: samples, to: url)
                } catch {
                    say("wake-mic-record: couldn’t write \(url.lastPathComponent): \(error.localizedDescription)")
                    return 1
                }
                savedClips += 1
                say(String(
                    format: "  saved %@ (%.2fs, peak %.2f)",
                    url.lastPathComponent,
                    Double(samples.count) / sampleRate,
                    peak
                ))
            }

            if index < count {
                try? await Task.sleep(for: pauseBetweenClips)
            }
        }

        let total = captureFileCount(in: directory)
        say("")
        say("wake-mic-record: \(savedClips) clip(s) saved to \(directory.path)")
        say("wake-mic-record: next — grade them with:")
        say("  Scripts/run-selftest.sh --selftest-wake-live")
        say("wake-mic-record: expect a WAKE_MIC line like:")
        say("  WAKE_MIC: <heard>/\(total) local captures heard (informational, not in the verdict)")
        return 0
    }

    /// Ctrl-C is a normal way to stop: report what was saved and exit cleanly.
    private static func installInterruptHandler() {
        guard interruptSource == nil else { return }
        signal(SIGINT, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        source.setEventHandler {
            Task { @MainActor in
                let directory = outputDirectory?.path ?? WakeWordLiveSelfTest.liveFixturesDirectory.path
                say("")
                say("wake-mic-record: stopped — \(savedClips) of \(requestedClips) clip(s) saved in \(directory)")
                exit(0)
            }
        }
        source.resume()
        interruptSource = source
    }

    private static func requestMicrophoneAccess() async -> Bool {
        await withCheckedContinuation { continuation in
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                continuation.resume(returning: granted)
            }
        }
    }

    private static func reportMicrophoneDenied() -> Int32 {
        say("wake-mic-record: macOS denied microphone access for this process.")
        say("  The grant belongs to the Next Notes app bundle, and a binary started from a shell")
        say("  is judged as the shell’s child instead. Relaunch through LaunchServices so Next")
        say("  Notes itself is responsible — the same route run-selftest.sh --via-open uses:")
        say("    open -n -a \"Next Notes\" --args --wake-mic-record \(requestedClips) --selftest-out /tmp/wake-mic-record.txt")
        say("  If the Next Notes toggle is already on under System Settings > Privacy & Security >")
        say("  Microphone, an ad-hoc rebuild invalidated it:")
        say("    tccutil reset Microphone ai.pivotstudio.nextnotes   # then grant it again")
        return 1
    }

    // MARK: - Capture

    private enum CaptureOutcome {
        case captured([Float])
        case failed(String)
    }

    private static func captureClip() async -> CaptureOutcome {
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let native = input.outputFormat(forBus: 0)
        guard native.sampleRate > 0, native.channelCount > 0 else {
            return .failed("no microphone input device is connected — connect one and run again.")
        }
        guard let target = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        ), let converter = AVAudioConverter(from: native, to: target) else {
            return .failed("the input format (\(Int(native.sampleRate)) Hz, \(native.channelCount) channel(s))"
                + " can’t be converted to 16 kHz mono.")
        }

        let collector = ClipCollector(
            converter: converter,
            targetFormat: target,
            limit: Int(sampleRate * recordSeconds)
        )
        input.installTap(onBus: 0, bufferSize: 4096, format: native, block: makeTapBlock(collector))
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            engine.stop()
            return .failed("the microphone didn’t start (\(error.localizedDescription)) —"
                + " another app may be holding the input device.")
        }
        try? await Task.sleep(for: .seconds(recordSeconds))
        input.removeTap(onBus: 0)
        engine.stop()

        let samples = collector.snapshot()
        guard !samples.isEmpty else {
            return .failed("the input device stopped delivering audio mid-run — nothing was saved for this clip.")
        }
        return .captured(samples)
    }

    /// Built outside the MainActor context on purpose: `installTap` runs it on Core Audio’s
    /// realtime queue, and a closure formed in a `@MainActor` function inherits that
    /// isolation and traps there in release builds.
    nonisolated private static func makeTapBlock(
        _ collector: ClipCollector
    ) -> @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void {
        { buffer, _ in collector.consume(buffer) }
    }

    /// Accumulates converted 16 kHz mono samples from the tap’s realtime thread.
    ///
    /// Conversion happens on the audio thread, which is what the hub’s delivery worker
    /// exists to avoid for model consumers; two seconds of speech is cheap enough that a
    /// queue would cost more than it saves.
    private final class ClipCollector: @unchecked Sendable {
        private let lock = NSLock()
        private let converter: AVAudioConverter
        private let targetFormat: AVAudioFormat
        private let limit: Int
        private var samples: [Float] = []

        init(converter: AVAudioConverter, targetFormat: AVAudioFormat, limit: Int) {
            self.converter = converter
            self.targetFormat = targetFormat
            self.limit = limit
        }

        func consume(_ buffer: AVAudioPCMBuffer) {
            guard let converted = AudioConversion.convert(buffer, to: targetFormat, using: converter) else {
                return
            }
            let incoming = AudioConversion.samples(of: converted)
            guard !incoming.isEmpty else { return }
            lock.lock()
            defer { lock.unlock() }
            guard samples.count < limit else { return }
            samples.append(contentsOf: incoming.prefix(limit - samples.count))
        }

        func snapshot() -> [Float] {
            lock.lock()
            defer { lock.unlock() }
            return samples
        }
    }

    // MARK: - Files

    private enum RecorderError: LocalizedError {
        case writeFailed

        var errorDescription: String? { "couldn’t build a 16 kHz mono WAV buffer" }
    }

    /// 16-bit on disk, float in memory — the same shape as every other WAV this app writes,
    /// and the shape `--selftest-wake-live` expects.
    private static func write(samples: [Float], to url: URL) throws {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        let file = try AVAudioFile(
            forWriting: url,
            settings: settings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        guard !samples.isEmpty,
              let format = AVAudioFormat(
                  commonFormat: .pcmFormatFloat32,
                  sampleRate: sampleRate,
                  channels: 1,
                  interleaved: false
              ),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
              let channel = buffer.floatChannelData?[0]
        else {
            throw RecorderError.writeFailed
        }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { channel.update(from: $0.baseAddress!, count: samples.count) }
        try file.write(from: buffer)
    }

    /// A capture is never overwritten. The timestamp and index make a collision unlikely;
    /// the loop makes it impossible.
    private static func uniqueURL(in directory: URL, index: Int) -> URL {
        let stamp = stampFormatter.string(from: Date())
        var url = directory.appendingPathComponent(String(format: "mic-%@-%02d.wav", stamp, index))
        var suffix = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = directory.appendingPathComponent(
                String(format: "mic-%@-%02d-%d.wav", stamp, index, suffix)
            )
            suffix += 1
        }
        return url
    }

    private static func captureFileCount(in directory: URL) -> Int {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.filter {
            WakeWordLiveSelfTest.captureFileExtensions.contains(($0 as NSString).pathExtension.lowercased())
        }.count
    }

    private static let stampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter
    }()

    // MARK: - Output

    /// stdout, plus the `--selftest-out` mirror so a LaunchServices launch — the only launch
    /// TCC credits to the app bundle — can still be read back.
    private static func say(_ line: String) {
        print(line)
        guard let path = SelfTest.outputPath else { return }
        let text = line + "\n"
        if let handle = FileHandle(forWritingAtPath: path) {
            handle.seekToEndOfFile()
            handle.write(Data(text.utf8))
            try? handle.close()
        } else {
            try? text.write(toFile: path, atomically: true, encoding: .utf8)
        }
    }
}
