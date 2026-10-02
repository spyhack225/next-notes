import Foundation

/// Additional actual-writer boundaries, separate from the unchanged original runtime case.
@MainActor
enum TaskReceiptSourceBoundarySelfTest {
    private enum FixtureError: Error { case unsafeRoot }

    static func run(root: URL, check: (Bool, String) -> Void) throws {
        let resolved = root.resolvingSymlinksInPath().standardizedFileURL
        let temporary = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().standardizedFileURL
        guard SelfTest.isRunning, resolved.path.hasPrefix(temporary.path + "/"),
              !resolved.pathComponents.contains("Application Support") else { throw FixtureError.unsafeRoot }
        let intent = ActionIntent(source: .agent, authority: .user, verb: "filesystem.read", risk: .read)
        let original = ActionReceipt(actionID: UUID(), intent: intent, source: .agent,
            authority: .user, toolID: "filesystem.read")
        var updated = original
        updated.status = .completed
        for mode in ["appeared", "deleted", "replaced", "in-place", "directory", "symlink"] {
            let file = resolved.appendingPathComponent("receipt-boundary-" + mode + ".json")
            let store = ActionReceiptStore(fileURL: file)
            if mode != "appeared" {
                check(store.record(original), "receipt boundary: initial real commit refused (\(mode))")
            }
            let memoryBefore = store.receipts
            var retained: Data?
            switch mode {
            case "appeared":
                retained = Data("[{\"unreadable_future_receipt\":true}]".utf8)
                try retained!.write(to: file, options: .atomic)
            case "deleted":
                try FileManager.default.removeItem(at: file)
            case "replaced":
                retained = try Data(contentsOf: file)
                // Even byte-identical replacement is not this instance's admitted file.
                try retained!.write(to: file, options: .atomic)
            case "in-place":
                retained = try Data(contentsOf: file) + Data(" ".utf8)
                let handle = try FileHandle(forWritingTo: file)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: Data(" ".utf8))
            case "directory":
                try FileManager.default.removeItem(at: file)
                try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
            default:
                let target = resolved.appendingPathComponent("receipt-boundary-symlink-target.json")
                retained = try Data(contentsOf: file)
                try retained!.write(to: target, options: .atomic)
                try FileManager.default.removeItem(at: file)
                try FileManager.default.createSymbolicLink(at: file, withDestinationURL: target)
            }
            check(!store.record(updated) && store.receipts == memoryBefore,
                "receipt boundary: changed source admitted or changed memory (\(mode))")
            if let retained {
                check(try Data(contentsOf: file) == retained,
                    "receipt boundary: rejected writer changed retained bytes (\(mode))")
            } else {
                var isDirectory: ObjCBool = false
                let exists = FileManager.default.fileExists(atPath: file.path, isDirectory: &isDirectory)
                check(mode == "directory" ? (exists && isDirectory.boolValue) : !exists,
                    "receipt boundary: rejected writer recreated/replaced the changed source (\(mode))")
            }
        }
        // Each own atomic replacement refreshes admission for the same live writer.
        let controlFile = resolved.appendingPathComponent("receipt-boundary-own.json")
        let control = ActionReceiptStore(fileURL: controlFile)
        check(control.record(original) && control.record(updated)
            && ActionReceiptStore(fileURL: controlFile).receipt(for: original.actionID)?.status == .completed,
            "receipt boundary: own sequential commits did not refresh the real writer")
    }
}
