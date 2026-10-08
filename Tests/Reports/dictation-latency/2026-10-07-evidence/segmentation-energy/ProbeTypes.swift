import Foundation
// Exact current shared threshold and RMS producer, with proposed shared comparison overload.
enum AudioConversion {
    static func rms(of samples: ArraySlice<Float>) -> Float {
        guard !samples.isEmpty else { return 0 }
        var sum: Float = 0
        for sample in samples { sum += sample * sample }
        return (sum / Float(samples.count)).squareRoot()
    }
}
enum ChunkedTranscriber {
    private static let silenceThreshold: Float = 0.01
    static func frameIsSilent(_ frame: ArraySlice<Float>) -> Bool { AudioConversion.rms(of: frame) < silenceThreshold }
    static func frameIsSilent(rms: Float) -> Bool { rms < silenceThreshold }
}
