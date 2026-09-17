import Darwin
import Foundation

/// Evaluation-only dynamic bridge. Nothing in the installed product requires
/// this dylib unless an explicit self-test chooses `--acoustic-aec3`.
final class AEC3ProbeBridge {
    private typealias Create = @convention(c) () -> UnsafeMutableRawPointer?
    private typealias CreateOptions = @convention(c) (UInt32) -> UnsafeMutableRawPointer?
    private typealias GetLinearOutput = @convention(c) (
        UnsafeMutableRawPointer?, UnsafeMutablePointer<Float>?
    ) -> Int32
    private typealias Destroy = @convention(c) (UnsafeMutableRawPointer?) -> Void
    private typealias Feed = @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<Float>?) -> Int32
    private typealias Process = @convention(c) (
        UnsafeMutableRawPointer?, UnsafePointer<Float>?, UnsafeMutablePointer<Float>?, Int32
    ) -> Int32

    private let library: UnsafeMutableRawPointer
    private let state: UnsafeMutableRawPointer
    private let destroy: Destroy
    private let feed: Feed
    private let processFrame: Process
    private let getLinearOutput: GetLinearOutput?
    private let streamDelayMilliseconds: Int32
    let outputMode: String

    init?() {
        let aec3Requested = SelfTest.isRunning
            && CommandLine.arguments.contains("--acoustic-aec3")
        guard aec3Requested else { return nil }
        let linearRequested = aec3Requested
            && CommandLine.arguments.contains("--acoustic-aec3-linear")
        let noInitialRequested = aec3Requested
            && CommandLine.arguments.contains("--acoustic-aec3-no-initial")
        let noReverbRequested = aec3Requested
            && CommandLine.arguments.contains("--acoustic-aec3-no-reverb")
        let sensitiveNearRequested = aec3Requested
            && CommandLine.arguments.contains("--acoustic-aec3-sensitive-near")
        let boundedNearRequested = aec3Requested
            && CommandLine.arguments.contains("--acoustic-aec3-bounded-near")
        let override = SelfTest.isRunning
            ? ProcessInfo.processInfo.environment["NEXTNOTES_AEC3_BRIDGE_PATH"] : nil
        let path = override ?? Bundle.main.privateFrameworksURL?
            .appendingPathComponent("libNextNotesAEC.dylib").path
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Caches/NextNotesBuild/webrtc/current/libNextNotesAEC.dylib").path
        guard let library = dlopen(path, RTLD_NOW | RTLD_LOCAL) else { return nil }
        guard let createSymbol = dlsym(library, "aec_create"),
              let destroySymbol = dlsym(library, "aec_destroy"),
              let feedSymbol = dlsym(library, "aec_feed_render"),
              let processSymbol = dlsym(library, "aec_process_capture") else {
            dlclose(library)
            return nil
        }
        let linearCreate: Create?
        let linearOutput: GetLinearOutput?
        if linearRequested {
            // The linear experiment is opt-in and must fail closed when the
            // versioned ABI is absent; never silently run the final-output path.
            guard let symbol = dlsym(library, "aec_create_linear_v1"),
                  let outputSymbol = dlsym(library, "aec_get_linear_aec_output_v1") else {
                dlclose(library)
                return nil
            }
            linearCreate = unsafeBitCast(symbol, to: Create.self)
            linearOutput = unsafeBitCast(outputSymbol, to: GetLinearOutput.self)
        } else {
            linearCreate = nil
            linearOutput = nil
        }
        // This is an explicit evaluation knob, not an inferred device latency.
        // Production must measure its render/capture timing before setting it.
        guard let delay = Self.delaySelection() else {
            dlclose(library)
            return nil
        }
        let created: UnsafeMutableRawPointer?
        let options = (linearRequested ? 1 : 0)
            | (noInitialRequested ? 2 : 0)
            | (noReverbRequested ? 4 : 0)
            | (sensitiveNearRequested ? 8 : 0)
            | (boundedNearRequested ? 16 : 0)
        // Keep the pre-existing linear constructor on its own. The options ABI
        // is required only when one of the new evaluation switches is present.
        if options & ~1 != 0 {
            guard let symbol = dlsym(library, "aec_create_options_v1") else {
                dlclose(library)
                return nil
            }
            let create = unsafeBitCast(symbol, to: CreateOptions.self)
            created = create(UInt32(options))
        } else {
            let create = linearCreate ?? unsafeBitCast(createSymbol, to: Create.self)
            created = create()
        }
        guard let state = created else { dlclose(library); return nil }
        self.library = library
        self.state = state
        destroy = unsafeBitCast(destroySymbol, to: Destroy.self)
        feed = unsafeBitCast(feedSymbol, to: Feed.self)
        processFrame = unsafeBitCast(processSymbol, to: Process.self)
        getLinearOutput = linearOutput
        outputMode = "aec3" + (linearRequested ? "-linear" : "")
            + (noInitialRequested ? "-no-initial" : "")
            + (noReverbRequested ? "-no-reverb" : "")
            + (sensitiveNearRequested ? "-sensitive-near" : "")
            + (boundedNearRequested ? "-bounded-near" : "") + "-evaluation"
        streamDelayMilliseconds = delay
    }

    deinit {
        destroy(state)
        dlclose(library)
    }

    func feedRendered(_ samples: [Float]) -> Bool {
        guard samples.count == 160 else { return false }
        return samples.withUnsafeBufferPointer { feed(state, $0.baseAddress) == 0 }
    }

    func process(_ samples: [Float]) -> [Float]? {
        guard samples.count == 160 else { return nil }
        var output = [Float](repeating: 0, count: 160)
        let status = samples.withUnsafeBufferPointer { input in
            output.withUnsafeMutableBufferPointer { result in
                processFrame(state, input.baseAddress, result.baseAddress, streamDelayMilliseconds)
            }
        }
        guard status == 0 else { return nil }
        // Export is a snapshot of the capture frame just processed, not an
        // alternative call that can advance the AEC state by itself.
        if let getLinearOutput {
            let linearStatus = output.withUnsafeMutableBufferPointer {
                getLinearOutput(state, $0.baseAddress)
            }
            guard linearStatus == 0 else { return nil }
        }
        return output
    }

    private static func delaySelection() -> Int32? {
        guard SelfTest.isRunning else { return 0 }
        let arguments = CommandLine.arguments
        let flag = "--acoustic-aec3-delay-ms"
        if arguments.contains(flag) {
            guard let value = SelfTest.value(after: flag),
                  let parsed = Int32(value), (0...500).contains(parsed) else {
                return nil
            }
            return parsed
        }
        guard let value = ProcessInfo.processInfo.environment["NEXTNOTES_AEC3_DELAY_MS"] else {
            return 0
        }
        guard let parsed = Int32(value), (0...500).contains(parsed) else {
            return nil
        }
        return parsed
    }
}
