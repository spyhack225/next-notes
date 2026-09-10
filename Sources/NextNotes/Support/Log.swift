import OSLog

enum Log {
    static let audio = Logger(subsystem: AppIdentity.bundleIdentifier, category: "audio")
    static let systemAudio = Logger(subsystem: AppIdentity.bundleIdentifier, category: "systemAudio")
    static let speech = Logger(subsystem: AppIdentity.bundleIdentifier, category: "speech")
    static let hotkey = Logger(subsystem: AppIdentity.bundleIdentifier, category: "hotkey")
    static let inject = Logger(subsystem: AppIdentity.bundleIdentifier, category: "inject")
    static let app = Logger(subsystem: AppIdentity.bundleIdentifier, category: "app")
    static let meeting = Logger(subsystem: AppIdentity.bundleIdentifier, category: "meeting")
    static let calendar = Logger(subsystem: AppIdentity.bundleIdentifier, category: "calendar")
    static let calls = Logger(subsystem: AppIdentity.bundleIdentifier, category: "calls")
    static let llm = Logger(subsystem: AppIdentity.bundleIdentifier, category: "llm")
    static let island = Logger(subsystem: AppIdentity.bundleIdentifier, category: "island")
    static let agent = Logger(subsystem: AppIdentity.bundleIdentifier, category: "agent")
}
