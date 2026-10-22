import Foundation
import OSLog
enum Warmth: String, Sendable { case staged, warmProcess, cold }
enum Log { static let speech = Logger(subsystem: "DictationStructureFixture", category: "isolated") }
enum CleanupPressureProbe { static func sample() async -> CleanupComputePressure { .idle } }
enum AppleStructurePlanner {
    static func budget(forSentences count: Int) -> Duration { .seconds(min(6.0,max(3.5,0.3*Double(count)))) }
}
