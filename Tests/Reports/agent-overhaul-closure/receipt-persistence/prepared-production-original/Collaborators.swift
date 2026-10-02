
import Foundation
import OSLog
enum SelfTest { nonisolated(unsafe) static var isRunning = true }
@MainActor enum AppIdentity {
    static var applicationSupportDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("NextNotesReceiptDeclaredSupport")
}
enum Log { static let agent = Logger(subsystem: "fixture.receipt-persistence", category: "store") }
