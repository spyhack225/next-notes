import AVFoundation
import CoreAudio
import Foundation
import Synchronization

/// Diagnostic observer of the existing mic and rendered-reference paths. No
/// audio is written to disk and no second microphone or echo processor is opened.
final class TTSOutputProbe: @unchecked Sendable {
    static let enabled = CommandLine.arguments.contains("--tts-speaker-output")
    private static let active = Mutex<TTSOutputProbe?>(nil)
    struct Frame: Sendable { let host: UInt64; let rms: Double; var count: Int = 1 }
    struct Evidence: Codable {
        let requestHost: UInt64
        let callerToken: UInt64
        let renderOrigins: [String]
        let firstRenderedOrigin: String?
        let firstRenderedHost: UInt64?
        let firstRenderedMs: Double?
        let presentationLatencyMs: Double?
        let estimatedPresentationMs: Double?
        let acousticOnsetMs: Double?
        let acousticCorrelation: Double?
        let baselineRMS: Double
        let captureWindows: Int
        let referenceWindows: Int
        let route: [UInt32]
        let qualified: Bool
        let reason: String
    }
    private struct State {
        var mic: [Frame] = []
        var reference: [Frame] = []
        var firstRendered: UInt64?
        var firstOrigin: String?
        var latency: Double?
        var overflow = false
        var missingTimestamp = false
        var request: UInt64?
        var token: UInt64 = 0
        var origins: Set<String> = []
    }
    private let state = Mutex(State())
    private let ticks = Double(AVAudioTime.hostTime(forSeconds: 1))
    static func install(_ probe: TTSOutputProbe?) { active.withLock { $0 = probe } }
    static func rendered(_ buffer: AVAudioPCMBuffer, host: UInt64?, latency: Double, origin: String) {
        let probe = active.withLock { $0 }
        probe?.append(buffer, host: host, reference: true, latency: latency, origin: origin)
    }
    func captured(_ chunk: AudioChunk) {
        append(chunk.buffer, host: chunk.captureHostTime, reference: false, latency: 0)
    }
    func arm(request: UInt64, token: UInt64) {
        state.withLock { $0.request = request; $0.token = token; $0.firstRendered = nil
            $0.latency = nil; $0.firstOrigin = nil; $0.reference.removeAll(keepingCapacity: true); $0.origins.removeAll() }
    }
    func dropped() { state.withLock { $0.overflow = true } }
    private func append(_ buffer: AVAudioPCMBuffer, host: UInt64?, reference: Bool, latency: Double, origin: String? = nil) {
        guard let host, host > 0, let channel = buffer.floatChannelData?[0],
              buffer.format.sampleRate > 0 else {
            state.withLock { $0.missingTimestamp = true }; return
        }
        let rate = buffer.format.sampleRate
        let count = Int(buffer.frameLength)
        var frames: [Frame] = []
        var first: UInt64?
        // Canonical host-clock 10 ms bins survive partial buffers, conversion
        // block sizes and delivery jitter. Never index by callback count.
        var bin: UInt64?, square = 0.0, binCount = 0
        func closeBin() {
            if let bin, binCount > 0 {
                frames.append(Frame(host: bin, rms: sqrt(square / Double(binCount)), count: binCount))
            }
        }
        for index in 0..<count {
            let sampleHost = host + UInt64(Double(index) / rate * ticks)
            let stamp = UInt64((Double(sampleHost) / ticks * 100).rounded(.down))
            let key = UInt64(Double(stamp) / 100 * ticks)
            if key != bin { closeBin(); bin = key; square = 0; binCount = 0 }
            let value = Double(channel[index])
            square += value * value; binCount += 1
            if reference, first == nil, abs(value) >= 0.001 { first = sampleHost }
        }
        closeBin()
        func appendFrames(_ destination: inout [Frame]) {
            for frame in frames {
                if let last = destination.last, last.host == frame.host {
                    let sum = last.rms * last.rms * Double(last.count) + frame.rms * frame.rms * Double(frame.count)
                    destination[destination.count-1] = Frame(host: frame.host,
                        rms: sqrt(sum / Double(last.count + frame.count)), count: last.count + frame.count)
                } else { destination.append(frame) }
            }
        }
        state.withLock {
            if reference {
                if let request = $0.request, host < request { return }
                if let origin { $0.origins.insert(origin) }
                if $0.reference.count + frames.count > 8_000 { $0.overflow = true; return }
                appendFrames(&$0.reference)
                if $0.firstRendered == nil, let first { $0.firstRendered = first; $0.latency = latency; $0.firstOrigin = origin }
            } else {
                if $0.mic.count + frames.count > 8_000 { $0.overflow = true; return }
                appendFrames(&$0.mic)
            }
        }
    }
    static func selfTest() -> Bool {
        let request = mach_absolute_time() + AVAudioTime.hostTime(forSeconds: 1)
        let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
        func buffer(_ value: Float) -> AVAudioPCMBuffer {
            let b = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 160)!
            b.frameLength = 160
            b.floatChannelData![0].update(repeating: value, count: 160)
            return b
        }
        let probe = TTSOutputProbe(), silent = TTSOutputProbe()
        for index in -70..<250 {
            let host = UInt64(Double(request) + Double(index) / 100 * probe.ticks)
            probe.append(buffer(0.00001), host: host, reference: false, latency: 0)
            silent.append(buffer(0), host: host, reference: false, latency: 0)
        }
        // Replace the post-request mic envelope, preserving a quiet measured baseline.
        probe.state.withLock { $0.mic.removeAll { $0.host >= request } }
        for index in 0..<250 {
            let value: Float = index < 20 ? 0 : Float(0.01 + Double((index * 73 + index * index * 7) % 97) / 2_000)
            let host = request + AVAudioTime.hostTime(forSeconds: Double(index) / 100)
            probe.append(buffer(value), host: host, reference: true, latency: 0)
            let micHost = host + AVAudioTime.hostTime(forSeconds: 0.08)
            probe.append(buffer(value * 0.25), host: micHost, reference: false, latency: 0)
            silent.append(buffer(0), host: host, reference: true, latency: 0)
        }
        let observed = probe.finish(request: request, route: route())
        let missing = silent.finish(request: request, route: route())
        probe.dropped()
        let overflow = probe.finish(request: request, route: route())
        return observed.qualified && abs((observed.acousticOnsetMs ?? 0) - 280) <= 20
            && !missing.qualified && missing.firstRenderedMs == nil
            && !overflow.qualified && overflow.acousticOnsetMs == nil
    }

    static func route() -> [UInt32] {
        [kAudioHardwarePropertyDefaultInputDevice, kAudioHardwarePropertyDefaultOutputDevice].map { selector in
            var address = AudioObjectPropertyAddress(mSelector: selector,
                mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            var device: AudioDeviceID = 0
            var size = UInt32(MemoryLayout<AudioDeviceID>.size)
            guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr else { return 0 }
            return device
        }
    }
    func finish(request: UInt64, route: [UInt32]) -> Evidence {
        let snapshot = state.withLock { $0 }
        func ms(_ host: UInt64) -> Double { (Double(host) - Double(request)) / ticks * 1_000 }
        let baseline = snapshot.mic.filter { $0.host < request }
        let baselineRMS = sqrt(baseline.reduce(0) { $0 + $1.rms * $1.rms } / Double(max(1, baseline.count)))
        let reference = snapshot.reference.filter { $0.host >= request }
        let mic = snapshot.mic.filter { $0.host >= request }
        let first = snapshot.firstRendered
        let latency = snapshot.latency
        // Envelope correlation verifies that the detected mic onset belongs to
        // this rendered sentence. A noise threshold alone cannot establish that.
        var best = -1.0
        var bestLag = 0.0
        let voice = reference.filter { $0.rms > 0.001 }
        if let firstVoice = voice.first {
            let window = reference.filter { $0.host >= firstVoice.host }.prefix(150)
            if window.count >= 40, mic.count >= 40 {
                for lag in 0...50 {
                    var x: [Double] = [], y: [Double] = []
                    for frame in window {
                        let target = Double(frame.host) + ((latency ?? 0) + Double(lag) / 100) * ticks
                        var lower = 0, upper = mic.count
                        while lower < upper {
                            let middle = (lower + upper) / 2
                            if Double(mic[middle].host) < target { lower = middle + 1 } else { upper = middle }
                        }
                        var index = min(lower, mic.count - 1)
                        if index > 0, abs(Double(mic[index-1].host) - target) < abs(Double(mic[index].host) - target) { index -= 1 }
                        // Verify timestamp alignment instead of assuming no lost frames.
                        guard abs(Double(mic[index].host) - target) / ticks < 0.015 else { continue }
                        x.append(frame.rms); y.append(mic[index].rms)
                    }
                    guard x.count >= 40 else { continue }
                    let mx = x.reduce(0,+) / Double(x.count), my = y.reduce(0,+) / Double(y.count)
                    var xy = 0.0, xx = 0.0, yy = 0.0
                    for i in x.indices { let a = x[i]-mx, b = y[i]-my; xy += a*b; xx += a*a; yy += b*b }
                    let r = xy / max(1e-12, sqrt(xx*yy))
                    if r > best { best = r; bestLag = Double(lag) / 100 }
                }
            }
        }
        var onset: Double?
        if let first, let latency {
            let expected = Double(first) + (latency + bestLag) * ticks
            onset = mic.first { $0.host >= request && abs(Double($0.host) - expected) / ticks < 0.080
                && $0.rms > max(0.001, baselineRMS * 4) }.map { ms($0.host) }
        }
        let qualified = first != nil && onset != nil && best >= 0.75 && baseline.count >= 30
            && baselineRMS < 0.01 && !snapshot.overflow && !snapshot.missingTimestamp
            && !route.contains(0) && route == Self.route()
        return Evidence(requestHost: request, callerToken: snapshot.token, renderOrigins: snapshot.origins.sorted(), firstRenderedOrigin: snapshot.firstOrigin, firstRenderedHost: first,
            firstRenderedMs: first.map(ms), presentationLatencyMs: latency.map { $0 * 1_000 },
            estimatedPresentationMs: first.flatMap { host in latency.map { ms(host) + $0 * 1_000 } },
            acousticOnsetMs: qualified ? onset : nil,
            acousticCorrelation: best >= -0.5 ? best : nil, baselineRMS: baselineRMS,
            captureWindows: mic.count, referenceWindows: reference.count, route: route,
            qualified: qualified,
            reason: qualified ? "Correlated microphone onset; 10 ms energy windows, threshold-dependent; physical route only."
                : "Acoustic onset unqualified: missing/quiet echo, noisy baseline, correlation, timestamps, overflow or route change. No audible result accepted.")
    }
}
