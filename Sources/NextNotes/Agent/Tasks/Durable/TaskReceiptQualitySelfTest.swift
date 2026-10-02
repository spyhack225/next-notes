import Foundation

/// P6-05h original nil-scaffold/fixed identical fixture through actual task/runtime producers.
/// Source-quality observations only; existing write refusal is already correct.
@MainActor
enum TaskReceiptQualitySelfTest {
    private enum FixtureError: Error { case unsafeRoot, invalidBacking, missingReceipt, timeout }
    private static func settled(_ manager: AgentTaskManager, id: String) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while ContinuousClock.now < deadline {
            if let state = manager.task(id: id)?.status, state != .queued && state != .running { return true }
            await Task.yield()
        }
        return false
    }

    static func originalCases(root: URL, input: URL, text: String,
                              check: (Bool, String) -> Void) async throws {
        let safe = root.resolvingSymlinksInPath().standardizedFileURL
        let temporary = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().standardizedFileURL
        let safeInput = input.resolvingSymlinksInPath().standardizedFileURL
        guard SelfTest.isRunning, safe.isFileURL, safe.path.hasPrefix(temporary.path + "/"),
              !safe.pathComponents.contains("Application Support"),
              safeInput.isFileURL, safeInput.path.hasPrefix(safe.path + "/") else { throw FixtureError.unsafeRoot }
        let ownerBefore = SelfTestStoreGuard.take()
        let oldFire = AgentToolExecutor.fireOverrideForTesting
        let oldFake = AgentToolExecutor.fakeForTesting
        let oldPolicy = AgentToolExecutor.policyOverrideForTesting
        defer {
            AgentToolExecutor.fireOverrideForTesting = oldFire
            AgentToolExecutor.fakeForTesting = oldFake
            AgentToolExecutor.policyOverrideForTesting = oldPolicy
        }
        AgentToolExecutor.fakeForTesting = nil
        AgentToolExecutor.policyOverrideForTesting = .selfTest
        for mode in ["accepted", "source-changed"] {
            AgentToolExecutor.fireOverrideForTesting = nil
            let directory = safe.appendingPathComponent("receipt-quality-" + mode, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
            let sql = TaskStore(root: directory)
            defer { sql.close() }
            let export = directory.appendingPathComponent("agent-tasks.json")
            let receiptFile = directory.appendingPathComponent("action-receipts.json")
            let primerReceipts = ActionReceiptStore(fileURL: receiptFile)
            let primerStore = AgentTaskStore(fileURL: export, mirror: sql)
            guard primerStore.allowsHarnessPersistence else { throw FixtureError.unsafeRoot }
            let primer = AgentTaskManager(store: primerStore, receiptStore: primerReceipts)
            // A real first read creates the readable source. No invented receipts or seeded owner history.
            let primerTask = primer.submit(objective: "Create actual receipt-quality control", tool: "filesystem.read",
                arguments: ["path": input.path], source: "selftest")
            guard await settled(primer, id: primerTask.id) else {
                primer.cancel(primerTask.id); throw FixtureError.timeout
            }
            check(primer.task(id: primerTask.id)?.status == .completed
                && primer.task(id: primerTask.id)?.result?.contains(text) == true
                && primerReceipts.receipts.count == 1
                && primerReceipts.receipts.first?.status == .completed,
                "receipt quality: real primer did not persist its original read (\(mode))")
            guard primerReceipts.receipts.count == 1 else { throw FixtureError.missingReceipt }
            let receipts = ActionReceiptStore(fileURL: receiptFile)
            let initialObservation = receipts.sourceObservation
            let store = AgentTaskStore(fileURL: export, mirror: sql)
            guard store.allowsHarnessPersistence else { throw FixtureError.unsafeRoot }
            let manager = AgentTaskManager(store: store, receiptStore: receipts)
            var context: TaskJournalContext?
            var effects = 0
            var announcements: [String] = []
            var firedBeforeBacking: ActionReceipt?
            var memoryBeforeBacking: ActionReceipt?
            var firedObservation: ActionReceiptSourceObservation?
            var readerObservationAtFire: ActionReceiptSourceObservation?
            var cachedAfterExternalChange: ActionReceiptSourceObservation?
            var preBackingJoined = false
            var didChangeSource = false
            var changedSourceBytes: Data?
            manager.announcementForTesting = { announcements.append($0) }
            manager.backendEntryForTesting = { context = TaskEventJournal.current }
            AgentToolExecutor.fireOverrideForTesting = { tool, arguments in
                guard let context, tool.id == "filesystem.read", arguments == ["path": input.path],
                      context.receiptStore === receipts else { throw FixtureError.invalidBacking }
                let freshSQL = TaskStore(root: directory)
                defer { freshSQL.close() }
                let row = try freshSQL.load().first { $0.id == context.taskID }
                let fresh = ActionReceiptStore(fileURL: receiptFile)
                guard let fired = fresh.receipts.first(where: { $0.taskID == context.taskID && $0.status == .fired }) else {
                    throw FixtureError.invalidBacking
                }
                firedBeforeBacking = fired
                memoryBeforeBacking = receipts.receipt(for: fired.actionID)
                firedObservation = context.receiptStore?.sourceObservation
                readerObservationAtFire = fresh.sourceObservation
                preBackingJoined = row?.status == .running
                    && row?.durability?.receiptIDs == [fired.actionID.uuidString]
                    && fired.taskAttempt == context.attempt
                    && fired.taskLeaseOwner == row?.durability?.leaseOwner
                    && fired.taskLeaseOwner == String(ProcessInfo.processInfo.processIdentifier)
                    && fired.preparedAction?.id == fired.actionID
                    && fired.preparedAction?.executionPlan.arguments == arguments
                // Original actual temporary file read remains the backing.
                let result = try FilesystemExecutor.run(tool, arguments: arguments)
                effects += 1
                if mode == "source-changed" {
                    guard var rows = try JSONSerialization.jsonObject(with: Data(contentsOf: receiptFile))
                        as? [[String: Any]], rows.count == 2 else { throw FixtureError.invalidBacking }
                    rows.append(["unreadable_future_receipt": true])
                    let changed = try JSONSerialization.data(withJSONObject: rows, options: [.sortedKeys])
                    try changed.write(to: receiptFile, options: .atomic)
                    changedSourceBytes = changed
                    didChangeSource = true
                }
                // Getter must expose only LAST actual observation; it does not rediscover external mutation.
                cachedAfterExternalChange = context.receiptStore?.sourceObservation
                return result
            }
            let submitted = manager.submit(objective: "Read original receipt-quality fixture", tool: "filesystem.read",
                arguments: ["path": input.path], source: "selftest")
            guard await settled(manager, id: submitted.id) else {
                manager.cancel(submitted.id); throw FixtureError.timeout
            }
            let final = manager.task(id: submitted.id)
            let primary = try sql.load().first { $0.id == submitted.id }
            let events = try sql.journal(taskID: submitted.id)
            let linkedIDs = firedBeforeBacking.map { [$0.actionID.uuidString] } ?? []
            let finalObservation = receipts.sourceObservation
            let fresh = ActionReceiptStore(fileURL: receiptFile)
            let freshObservation = fresh.sourceObservation
            let retainedReceipt = firedBeforeBacking.flatMap { fresh.receipt(for: $0.actionID) }
            check(initialObservation?.loadQuality == .readable && initialObservation?.loadedRowCount == 1
                && initialObservation?.unreadableRowCount == 0 && initialObservation?.lastWriteSourceCheck == .notObserved,
                "receipt quality: actual readable writer load lacks typed provenance (\(mode))")
            check(effects == 1 && preBackingJoined && manager.backendStartsForTesting == 1,
                "receipt quality: real target read lost exact admitted receipt/attempt binding (\(mode))")
            check(!linkedIDs.isEmpty && primary?.durability?.receiptIDs == linkedIDs
                && final?.durability?.receiptIDs == primary?.durability?.receiptIDs,
                "receipt quality: terminal task lost original actual receipt link (\(mode))")
            check(firedObservation?.loadQuality == .readable && firedObservation?.loadedRowCount == 1
                && firedObservation?.unreadableRowCount == 0 && firedObservation?.lastWriteSourceCheck == .matched,
                "receipt quality: real runtime fired writer lacks historical load/existing matched-check provenance (\(mode))")
            check(readerObservationAtFire?.loadQuality == .readable && readerObservationAtFire?.loadedRowCount == 2
                && readerObservationAtFire?.unreadableRowCount == 0
                && readerObservationAtFire?.lastWriteSourceCheck == .notObserved,
                "receipt quality: actual fresh fired reader invented write or missing-row provenance (\(mode))")
            check(firedObservation != nil && cachedAfterExternalChange == firedObservation,
                "receipt quality: cached getter did not preserve historical observation before next real write (\(mode))")
            check(finalObservation?.loadQuality == .readable && finalObservation?.loadedRowCount == 1
                && finalObservation?.unreadableRowCount == 0,
                "receipt quality: later write outcome erased the actual original load snapshot (\(mode))")
            if mode == "accepted" {
                check(finalObservation?.lastWriteSourceCheck == .matched
                    && freshObservation?.loadQuality == .readable && freshObservation?.loadedRowCount == 2
                    && freshObservation?.unreadableRowCount == 0 && freshObservation?.lastWriteSourceCheck == .notObserved,
                    "receipt quality: actual accepted terminal writer/fresh reader lacks separate typed check facts")
                check(final?.status == .completed && primary?.status == .completed
                    && final?.result?.contains(text) == true && retainedReceipt?.status == .completed,
                    "receipt quality: accepted original read/receipt did not reach actual task")
                check(announcements.contains { $0.contains(text) }
                    && events.contains { $0.draft.kind == .jobCompleted },
                    "receipt quality: accepted original result delivery changed")
            } else {
                let retainedBytes = try Data(contentsOf: receiptFile)
                check(didChangeSource && retainedBytes == changedSourceBytes,
                    "receipt quality: existing refused writer changed exact unreadable source bytes")
                check(finalObservation?.lastWriteSourceCheck == .mismatch,
                    "receipt quality: actual refused terminal writer failed to expose its existing fingerprint mismatch")
                check(freshObservation?.loadQuality == .partial && freshObservation?.loadedRowCount == 2
                    && freshObservation?.unreadableRowCount == 1 && freshObservation?.lastWriteSourceCheck == .notObserved,
                    "receipt quality: actual fresh reader concealed partial/unsafe load as absent receipts")
                let memoryReceipt = firedBeforeBacking.flatMap { receipts.receipt(for: $0.actionID) }
                check(retainedReceipt == firedBeforeBacking && memoryReceipt == memoryBeforeBacking
                    && retainedReceipt?.status == .fired && memoryReceipt?.status == .fired
                    && retainedReceipt?.result.isEmpty == true,
                    "receipt quality: actual refusal erased real fired evidence or invented terminal result")
                check(final?.status == .failed && primary?.status == .failed && final?.result == nil
                    && !announcements.contains { $0.contains(text) }
                    && !events.contains { $0.draft.kind == .jobCompleted }
                    && events.contains { $0.draft.kind == .jobFailed },
                    "receipt quality: quality observation altered original refused-write task delivery")
                let failure = "The action ran, but its result could not be saved. Check it before trying again."
                check(final?.failure == failure && primary?.failure == failure && announcements.contains(failure),
                    "receipt quality: original result-not-saved failure changed")
            }
            let reloadSQL = TaskStore(root: directory)
            defer { reloadSQL.close() }
            let reloaded = AgentTaskManager(store: AgentTaskStore(fileURL: export, mirror: reloadSQL), receiptStore: fresh)
            for _ in 0..<16 { await Task.yield() }
            let afterReload = try reloadSQL.load().first { $0.id == submitted.id }
            check(reloaded.backendStartsForTesting == 0 && effects == 1 && afterReload == primary,
                "receipt quality: fresh actual manager replayed original target or changed terminal history (\(mode))")
            check(fresh.sourceObservation == freshObservation,
                "receipt quality: actual fresh manager altered cached source observation without a receipt write (\(mode))")
            SelfTest.diagnostic("TASK_RECEIPT_QUALITY_TRACE: mode=\(mode) effects=\(effects) terminal=\(final?.status.rawValue ?? "absent") load=\(finalObservation?.loadQuality.rawValue ?? "unobserved") writeCheck=\(finalObservation?.lastWriteSourceCheck.rawValue ?? "unobserved") freshLoad=\(freshObservation?.loadQuality.rawValue ?? "unobserved")")
        }
        check(SelfTestStoreGuard.diff(ownerBefore, SelfTestStoreGuard.take()).isEmpty,
            "receipt quality: isolated actual runtime changed owner stores/defaults")
    }
}
