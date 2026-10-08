enum SelfTest { static let isRunning = true }
@main struct MaintainedCheck {
    static func main() async {
        let failures = await IncrementalCleanupSession.cancelledLaneFailures()
        for failure in failures { print("FAIL: " + failure) }
        print(failures.isEmpty ? "PRECLEAN_MAINTAINED_OK" : "PRECLEAN_MAINTAINED_FAILED: \(failures.count)")
    }
}
