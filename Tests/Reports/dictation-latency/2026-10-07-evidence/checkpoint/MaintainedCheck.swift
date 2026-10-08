import Foundation

enum SelfTest { static let isRunning = true }

final class LockedBox<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value
    init(_ value: Value) { stored = value }
    var value: Value {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); stored = newValue; lock.unlock() }
    }
}

@main struct MaintainedCheck { static func main() async { _ = await ComputeScheduler.runSelfTest() } }
