import Foundation

// Only the self-test guard/diagnostic boundary is substituted. The production
// census wrapper below is compiled directly from its unchanged source file.
enum SelfTest {
    static let isRunning = true
    static func diagnostic(_ value: String) { print(value) }
}
@main struct CensusWrapperProbe {
    @MainActor static func main() {
        let failures = AgentVoicePolicySelfTest.run()
        failures.forEach { print($0) }
        print(failures.isEmpty ? "VOICE_POLICY_CENSUS_WRAPPER_OK" : "VOICE_POLICY_CENSUS_WRAPPER_FAILED")
        exit(failures.isEmpty ? 0 : 1)
    }
}
