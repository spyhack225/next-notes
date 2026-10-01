    static func lineageFailures(directory: URL) -> [String] {
        var failures: [String] = []
        func check(_ name: String, _ condition: Bool) {
            if !condition { failures.append("lineage: " + name) }
        }
        let date = Date(timeIntervalSince1970: 1_700_000_200)
        let session = UUID(uuidString: "00000000-0000-0000-0000-000000000091")!
        let facts = ["The user prefers fountain pens.", "The user collects ceramic cups.",
                     "The user plays acoustic guitar.", "The user reads historical novels."]
        func json(_ url: URL) throws -> [String: Any] {
            try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        }
        do {
            for (index, channel) in MemoryProvenance.TrustedSource.allCases.enumerated() {
                let folder = directory.appendingPathComponent("channel-\(index)", isDirectory: true)
                let store = NextMemory(directory: folder, now: { date })
                let fact = facts[index]
                let provenance = MemoryProvenance(
                    origin: index.isMultiple(of: 2) ? .userConversation : .memoryReview,
                    source: channel, sourceLabel: "on 1 Oct", occurredAt: date,
                    sessionID: session,
                    userText: [fact + " DISTINCT_SOURCE_UTTERANCE_DO_NOT_STORE"],
                    untrustedText: ["DISTINCT_EXTERNAL_CONTENT_DO_NOT_STORE"])
                let tool = MemoryToolCatalogue.all.first { $0.name == "remember" }!
                _ = try MemoryToolExecutor.run(tool, arguments: ["kind": "profile", "text": fact],
                                               provenance: provenance, store: store)
                let payload = try json(store.fileURL!)
                let row = (payload["entries"] as? [[String: Any]])?.first ?? [:]
                let lineage = row["lineage"] as? [String: Any] ?? [:]
                let records = lineage["records"] as? [[String: Any]] ?? []
                let record = records.first ?? [:]
                check("checked writer dropped descriptor for channel \(index)", records.count == 1
                      && record["trustedSource"] as? String == channel.rawValue
                      && record["source"] as? String == (index.isMultiple(of: 2) ? "userConversation" : "memoryReview")
                      && record["confidence"] as? Double == channel.confidence
                      && record["sourceLabel"] as? String == "on 1 Oct"
                      && record["sessionID"] as? String == session.uuidString
                      && record["occurredAt"] as? String == "2023-11-14T22:16:40Z")
                check("new write lacks empty consolidation descriptor", (lineage["consolidatedFrom"] as? [String]) == []
                      && lineage["consolidationRunID"] == nil)
                check("descriptor replaced fast channel fields", row["origin"] as? String == channel.rawValue
                      && row["confidence"] as? Double == channel.confidence
                      && row["sourceLabel"] as? String == "on 1 Oct")
                let text = try String(contentsOf: store.fileURL!, encoding: .utf8)
                check("raw source content reached the file", !text.contains("DISTINCT_SOURCE_UTTERANCE_DO_NOT_STORE")
                      && !text.contains("DISTINCT_EXTERNAL_CONTENT_DO_NOT_STORE")
                      && !text.contains("userText") && !text.contains("untrustedText"))
                let reopened = NextMemory(directory: folder)
                check("version-3 entry did not round-trip", reopened.entries == store.entries)
                check("writer did not persist version 3", payload["version"] as? Int == 3)
                if index == 0 {
                    let previous = store.entries[0]
                    let replacement = "The user prefers ballpoint pens."
                    let correction = MemoryProvenance(origin: .userConversation, source: .userDictated,
                        occurredAt: date, sessionID: session, userText: [replacement], untrustedText: [])
                    _ = try MemoryToolExecutor.run(MemoryToolCatalogue.all.first { $0.name == "update" }!,
                        arguments: ["match": "fountain pens", "text": replacement],
                        provenance: correction, store: store)
                    let replaced = try json(store.fileURL!)
                    let current = (replaced["entries"] as? [[String: Any]])?.first ?? [:]
                    let currentLineage = current["lineage"] as? [String: Any] ?? [:]
                    let currentRecord = (currentLineage["records"] as? [[String: Any]])?.first ?? [:]
                    check("correction lost its recorded parent", current["supersedes"] as? String == previous.id.uuidString
                          && currentRecord["entryID"] as? String == previous.id.uuidString
                          && currentRecord["trustedSource"] as? String == "userDictated")
                    check("correction lost old provenance", (replaced["superseded"] as? [[String: Any]])?.first?["lineage"] != nil)
                    check("correction did not reopen exactly", NextMemory(directory: folder).entries == store.entries
                          && NextMemory(directory: folder).superseded == store.superseded)
                }
            }

            // Exact pre-change v2 shape, including its old correction and three activity rows.
            let legacyFolder = directory.appendingPathComponent("legacy", isDirectory: true)
            try FileManager.default.createDirectory(at: legacyFolder, withIntermediateDirectories: true)
            func entry(_ id: String, _ kind: String, _ text: String, _ created: String) -> [String: Any] {
                ["id": id, "kind": kind, "text": text, "source": "manual", "createdAt": created, "updatedAt": created]
            }
            let legacyEntries = [
                entry("00000000-0000-0000-0000-000000000001", "profile", "The user drinks tea.", "2023-11-14T22:13:20Z"),
                entry("00000000-0000-0000-0000-000000000002", "profile", "The user prefers short answers.", "2023-11-14T22:15:00Z"),
                entry("00000000-0000-0000-0000-000000000003", "note", "Standup notes go to the team folder.", "2023-11-14T22:16:40Z")]
            let activity: [[String: Any]] = (0..<3).map { index in
                ["kind": "person", "key": "Fixture Person \(index)", "value": "Fixture Person \(index)",
                 "source": "fixture", "updatedAt": "2023-11-14T22:13:20Z", "useCount": index + 1]
            }
            let old: [String: Any] = ["version": 2, "entries": legacyEntries,
                "superseded": [entry("00000000-0000-0000-0000-000000000004", "profile", "The user likes coffee.", "2023-11-14T22:13:20Z")],
                "activity": activity]
            let file = legacyFolder.appendingPathComponent(NextMemory.fileName)
            try JSONSerialization.data(withJSONObject: old, options: [.sortedKeys]).write(to: file)
            let cache = MemorySnapshotCache(isEnabled: { true })
            let legacy = NextMemory(directory: legacyFolder, snapshotCache: cache, now: { date })
            check("legacy migration lost entries or activity", legacy.entries.count == 3
                  && legacy.superseded.count == 1 && legacy.items.count == 3
                  && legacy.items.map(\.useCount) == [1, 2, 3])
            let golden = "profile: [\"The user prefers short answers.\",\"The user drinks tea.\"]\nnotes: [\"Standup notes go to the team folder.\"]"
            check("legacy snapshot bytes changed", Data(cache.text(for: .toolLoop).utf8) == Data(golden.utf8))
            print("MEMORY_LINEAGE_LEGACY_SNAPSHOT_BYTES=\(Data(cache.text(for: .toolLoop).utf8).count)")
            let migrated = try json(file)
            check("version-2 migration did not write version 3", migrated["version"] as? Int == 3)
            let rows = (migrated["entries"] as? [[String: Any]] ?? [])
                + (migrated["superseded"] as? [[String: Any]] ?? [])
            check("legacy migration invented provenance", rows.count == 4 && rows.allSatisfy { $0["lineage"] == nil })
            let manual = try legacy.remember(kind: .profile, text: "The user grows tomatoes.", source: .manual)
            let manualRow = (try json(file)["entries"] as? [[String: Any]])?.first { $0["id"] as? String == manual.entry.id.uuidString }
            check("handwritten memory invented consolidation or provenance", manualRow?["lineage"] == nil)
            check("new file cannot reopen legacy and manual rows", NextMemory(directory: legacyFolder).entries == legacy.entries)
            check("memory budgets changed", MemoryEntry.Kind.profile.budget == 2_400
                  && MemoryEntry.Kind.note.budget == 4_000 && NextMemory.maxEntryLength == 300)

            // A successful structural decode is not permission to downgrade a future file.
            let futureFolder = directory.appendingPathComponent("future", isDirectory: true)
            try FileManager.default.createDirectory(at: futureFolder, withIntermediateDirectories: true)
            let futureFile = futureFolder.appendingPathComponent(NextMemory.fileName)
            var future = old
            future["version"] = 999
            future["futureMetadata"] = ["keep": "fixture metadata"]
            let retained = try JSONSerialization.data(withJSONObject: future, options: [.sortedKeys])
            try retained.write(to: futureFile)
            let unsupported = NextMemory(directory: futureFolder)
            var rejected = false
            do { try unsupported.remember(kind: .note, text: "The user enjoys birdwatching.", source: .manual) }
            catch MemoryWriteError.storage { rejected = true }
            let retainedAfter = try Data(contentsOf: futureFile)
            check("unsupported future history was silently downgraded", rejected && retainedAfter == retained)
        } catch { failures.append("lineage fixture threw: \(error.localizedDescription)") }
        return failures
    }

