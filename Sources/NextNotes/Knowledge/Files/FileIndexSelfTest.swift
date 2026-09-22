import Foundation

/// `--selftest-file-index`: builds a small tree in a temporary directory, crawls it, and
/// checks the whole round trip — find, tree, the skip rules, an incremental update, and the
/// purge that has to happen the moment a folder leaves the user's list.
///
/// No grants, no model, no network, and nothing outside `FileManager.temporaryDirectory`: the
/// user's own `file-index.sqlite` and their real Desktop are never opened.
///
/// It fails, rather than passing quietly, when:
/// - a purged folder still answers a search (the one thing that must never happen);
/// - the crawl walks into `node_modules`, `.git` or a hidden file;
/// - an incremental update does not see a new file, or still sees a deleted one;
/// - the tools answer for a path outside the folders the user shared;
/// - the sentence the prompt carries names a tool the planner's allow-list would reject, or
///   that the registry cannot resolve — a rejected name abandons the whole tool plan, not
///   just the one call, so this is the assertion that keeps the advertised name honest;
/// - a cloud reader is handed paths without the user's consent;
/// - the folder access verdict is computed while a view reads it rather than cached.
enum FileIndexSelfTest {
    @MainActor
    static func run() async -> Bool {
        var failures: [String] = []
        func check(_ name: String, _ ok: Bool) {
            if !ok { failures.append(name) }
        }

        let manager = FileManager.default
        let root = manager.temporaryDirectory
            .appendingPathComponent("NextNotesSelfTest-file-index-\(ProcessInfo.processInfo.processIdentifier)",
                                    isDirectory: true)
        try? manager.removeItem(at: root)
        defer { try? manager.removeItem(at: root) }

        let alpha = root.appendingPathComponent("Alpha", isDirectory: true)
        let beta = root.appendingPathComponent("Beta", isDirectory: true)

        do {
            // MARK: A tree with every case the crawler has a rule about

            func write(_ url: URL, _ text: String = "x") throws {
                try manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try text.write(to: url, atomically: true, encoding: .utf8)
            }
            // Distinctive contents: the tools must never be able to return them.
            try write(alpha.appendingPathComponent("quarterly-roadmap.md"), "CONTENTSMUSTNOTLEAK")
            try write(alpha.appendingPathComponent("invoice-2026.pdf"), "invoice")
            try write(alpha.appendingPathComponent("Deep/Deeper/buried-notes.txt"), "buried")
            try write(alpha.appendingPathComponent("node_modules/left-pad/index.js"), "skip me")
            try write(alpha.appendingPathComponent(".git/config"), "skip me")
            try write(alpha.appendingPathComponent(".hidden-file.txt"), "skip me")
            try write(beta.appendingPathComponent("beta-report.md"), "beta")

            let store = FileIndexStore(directory: root.appendingPathComponent("db", isDirectory: true))
            defer { store.close() }

            // MARK: Crawl

            let alphaCrawl = FileCrawler.crawl(alpha)
            check("crawl reported a problem: \(alphaCrawl.problem ?? "")", alphaCrawl.problem == nil)
            try store.replaceRoot(alpha.path, records: alphaCrawl.records,
                                  capped: alphaCrawl.capped, note: alphaCrawl.note)
            let betaCrawl = FileCrawler.crawl(beta)
            try store.replaceRoot(beta.path, records: betaCrawl.records,
                                  capped: betaCrawl.capped, note: betaCrawl.note)

            let names = Set(alphaCrawl.records.map(\.name))
            check("crawl missed the roadmap", names.contains("quarterly-roadmap.md"))
            check("crawl missed a file three levels down", names.contains("buried-notes.txt"))
            check("crawl walked into node_modules", !names.contains("index.js") && !names.contains("node_modules"))
            check("crawl walked into .git", !names.contains(".git") && !names.contains("config"))
            check("crawl listed a hidden file", !names.contains(".hidden-file.txt"))

            // MARK: find

            let roadmap = try store.find(query: "roadmap", limit: 10)
            check("find did not return the roadmap", roadmap.contains { $0.name == "quarterly-roadmap.md" })
            check("find returned Beta's file for an Alpha word", !roadmap.contains { $0.root == beta.path })

            let prefix = try store.find(query: "invo", limit: 10)
            check("find does not match a prefix", prefix.contains { $0.name == "invoice-2026.pdf" })

            let pdfs = try store.find(query: "", category: .pdf, limit: 10)
            check("kind filter did not find the PDF, got \(pdfs.map(\.name))",
                  pdfs.count == 1 && pdfs.first?.name == "invoice-2026.pdf")

            let scoped = try store.find(query: "report", folder: alpha.path, limit: 10)
            check("folder filter leaked Beta into an Alpha search", scoped.isEmpty)
            let betaHits = try store.find(query: "report", folder: beta.path, limit: 10)
            check("folder filter lost Beta's own file", betaHits.contains { $0.name == "beta-report.md" })

            let future = try store.find(query: "roadmap", modifiedAfter: Date().addingTimeInterval(86_400), limit: 10)
            check("modifiedAfter matched a file from before it", future.isEmpty)

            // MARK: tree

            let shallow = try store.tree(path: alpha.path, depth: 1)
            check("tree depth 1 returned a grandchild",
                  !shallow.contains { $0.name == "buried-notes.txt" })
            check("tree depth 1 missed a direct child", shallow.contains { $0.name == "quarterly-roadmap.md" })
            let deep = try store.tree(path: alpha.path, depth: 4)
            check("tree depth 4 missed the buried file", deep.contains { $0.name == "buried-notes.txt" })
            check("tree of an unknown path returned rows",
                  (try store.tree(path: "/nowhere/at/all", depth: 2)).isEmpty)

            // MARK: Incremental update — a new file, a deleted one, a new folder

            try write(alpha.appendingPathComponent("brand-new-lease.pdf"), "lease")
            try manager.removeItem(at: alpha.appendingPathComponent("invoice-2026.pdf"))
            try write(alpha.appendingPathComponent("Fresh/inside-fresh.md"), "fresh")

            let listing = FileCrawler.crawl(alpha, startDepth: 0, maxDepth: 1)
            let newDirectories = try store.refreshDirectory(root: alpha.path, directory: alpha.path,
                                                            records: listing.records)
            check("the new sub-folder was not reported as new",
                  newDirectories.contains { ($0 as NSString).lastPathComponent == "Fresh" })
            for path in newDirectories {
                let depth = URL(fileURLWithPath: path).pathComponents.count - alpha.pathComponents.count
                let subtree = FileCrawler.crawl(URL(fileURLWithPath: path), startDepth: depth)
                try store.replaceSubtree(root: alpha.path, subtree: path, records: subtree.records)
            }

            check("incremental update did not see the new file",
                  (try store.find(query: "lease", limit: 10)).contains { $0.name == "brand-new-lease.pdf" })
            check("incremental update still returns the deleted file",
                  (try store.find(query: "invoice", limit: 10)).isEmpty)
            check("incremental update did not crawl into the new folder",
                  (try store.find(query: "inside fresh", limit: 10)).contains { $0.name == "inside-fresh.md" })
            check("a shallow refresh threw away the deeper rows",
                  (try store.find(query: "buried", limit: 10)).contains { $0.name == "buried-notes.txt" })

            // MARK: Purge — the assertion this whole self-test exists for

            check("Beta is not in the index before the purge",
                  !(try store.find(query: "beta report", limit: 10)).isEmpty)
            try store.purgeRoot(beta.path)
            let afterPurge = try store.find(query: "beta report", limit: 10)
            check("a removed folder still returns hits: \(afterPurge.map(\.path))", afterPurge.isEmpty)
            check("a removed folder still appears in the tree",
                  (try store.tree(path: beta.path, depth: 2)).isEmpty)
            check("a removed folder is still listed in Settings",
                  !(try store.rootStates()).contains { $0.root == beta.path })
            check("the purge took Alpha with it",
                  !(try store.find(query: "roadmap", limit: 10)).isEmpty)

            let stale = try store.staleRoots(keeping: [alpha.path])
            check("staleRoots named a folder that is still listed", stale.isEmpty)

            // MARK: The tools refuse what is outside the shared folders

            let retrieval = FixtureFileRetrieval(store: store, roots: [alpha.path])
            let tools = FileToolCatalogue.all
            guard let find = tools.first(where: { $0.name == FileToolCatalogue.findName }),
                  let tree = tools.first(where: { $0.name == FileToolCatalogue.treeName }) else {
                failures.append("the file tools are not in the catalogue")
                throw CancellationError()
            }
            check("files.find is not read-class", find.risk == .read && tree.risk == .read)

            let found = try FileToolExecutor.run(find, arguments: ["query": "roadmap"],
                                                 files: retrieval, mayRead: true)
            check("files.find did not return the roadmap: \(found.summary)",
                  found.summary.contains("quarterly-roadmap.md"))
            check("files.find did not label its output as data",
                  found.summary.hasPrefix(FileToolExecutor.label))
            check("files.find leaked a file's contents", !found.summary.contains("CONTENTSMUSTNOTLEAK"))
            check("the index holds file contents",
                  (try store.find(query: "CONTENTSMUSTNOTLEAK", limit: 10)).isEmpty)

            let listed = try FileToolExecutor.run(tree, arguments: ["path": alpha.path], files: retrieval, mayRead: true)
            check("files.tree listed nothing", listed.summary.contains("quarterly-roadmap.md"))

            var refused = false
            do {
                _ = try FileToolExecutor.run(tree, arguments: ["path": "/etc"], files: retrieval, mayRead: true)
            } catch {
                refused = true
            }
            check("files.tree answered for a path outside the shared folders", refused)

            var refusedFind = false
            do {
                _ = try FileToolExecutor.run(find, arguments: ["query": "x", "folder": "/etc"], files: retrieval, mayRead: true)
            } catch {
                refusedFind = true
            }
            check("files.find answered for a folder outside the shared folders", refusedFind)

            var refusedKind = false
            do {
                _ = try FileToolExecutor.run(find, arguments: ["query": "x", "kind": "wibble"], files: retrieval, mayRead: true)
            } catch {
                refusedKind = true
            }
            check("files.find accepted a kind that means nothing", refusedKind)

            let offline = try FileToolExecutor.run(find, arguments: ["query": "roadmap"],
                                                   files: EmptyFileRetrieval(), mayRead: true)
            check("files.find pretended to search with no folders shared",
                  offline.summary.contains("has not shared any folders"))

            // MARK: The graph overlay

            let overlay = FileGraphOverlay(store: store)
            let map = try overlay.map(expanded: [alpha.path])
            check("the map has no folder node for the shared folder",
                  map.nodes.contains { $0.type == "Folder" && $0.label == "Alpha" })
            check("the map drew every file as a node",
                  map.nodes.filter { $0.type == "File" }.count <= FileGraphOverlay.notableFileLimit)
            check("the map has no sub-folder for an opened folder",
                  map.nodes.contains { $0.type == "Folder" && $0.label == "Fresh" })
            check("a file node id does not resolve back to its path",
                  FileGraphOverlay.path(of: "file:/tmp/a.txt") == "/tmp/a.txt"
                      && FileGraphOverlay.path(of: "person:ana") == nil)
            let around = try overlay.neighbourhood(of: "folder:\(alpha.path)")
            check("neighbourhood of a folder is empty", around.nodes.count > 1)
            check("neighbourhood has no edges", !around.edges.isEmpty)

            // MARK: The one line that goes in the prompt

            check("the prompt summary is not one line",
                  !FileToolExecutor.label.contains("\n"))

            // Every tool name the prompt sentence tells the model to call must be a name the
            // planner will actually accept. The realtime loop checks the emitted name against
            // `RealtimeToolSelection.allowedIDs` *before* the registry resolves an alias, and a
            // miss does not skip that one call — it abandons the whole tool plan. The sentence
            // named `files.find` once, which is an alias, so obeying the prompt killed the turn.
            // Any id-shaped token in the sentence is checked, so rewording it cannot reopen this.
            let summary = FileIndexer.summarySentence(folders: ["Alpha"], files: 12)
            check("the prompt sentence is not one line", !summary.contains("\n"))
            let advertised = FileIndexer.advertisedToolNames(in: summary)
            check("the prompt sentence advertises no tool at all, got \(advertised)",
                  advertised.count == 2)
            for name in advertised {
                check("the prompt tells the model to call \(name), which the planner's allow-list "
                      + "rejects — that abandons the whole tool plan",
                      RealtimeToolSelection.allowedIDs.contains(name))
                check("the prompt tells the model to call \(name), which the registry cannot resolve",
                      AgentToolRegistry.shared.tool(named: name) != nil)
            }
            check("the advertised names are not the tools' own ids",
                  advertised == [find.id, tree.id])
            // The aliases still resolve — they are just never the ones advertised.
            for alias in FileToolCatalogue.aliasIDs {
                check("the \(alias) alias stopped resolving",
                      AgentToolRegistry.shared.tool(named: alias) != nil)
            }

            // MARK: Who may be told what is on this Mac

            check("an on-device reader is refused the file index",
                  FileIndexScope.mayRead(reader: .gemma4E4B, cloudConsent: false)
                      && FileIndexScope.mayRead(reader: .appleFoundation, cloudConsent: false)
                      && FileIndexScope.mayRead(reader: .localServer, cloudConsent: false))
            check("a cloud reader is handed the file index without consent",
                  !FileIndexScope.mayRead(reader: .openRouter, cloudConsent: false))
            check("an unknown reader is treated as on-device",
                  !FileIndexScope.mayRead(reader: nil, cloudConsent: false))
            check("consent does not let a cloud reader in",
                  FileIndexScope.mayRead(reader: .openRouter, cloudConsent: true))

            let refusedCloud = try FileToolExecutor.run(find, arguments: ["query": "roadmap"],
                                                        files: retrieval, mayRead: false)
            check("a tool answered a reader that may not see the file index: \(refusedCloud.summary)",
                  !refusedCloud.summary.contains("quarterly-roadmap.md"))
            check("the refusal does not say which switch to reach for",
                  refusedCloud.summary.contains("Settings"))

            // MARK: The access verdict is cached, not computed while a view waits

            // `accessProblem(for:)` is read from SwiftUI bodies and from the graph's reload, so
            // it must never touch the disk: a network home or an unmounted volume would freeze
            // the window on exactly the folder whose problem the row exists to describe. The
            // proof is that a folder which has just vanished still reads as fine until the
            // background probe has run. A synchronous implementation fails this immediately.
            func settle() async { try? await Task.sleep(for: .milliseconds(250)) }
            let list = IndexedFoldersStore(directory: root.appendingPathComponent("list", isDirectory: true))
            // The switch lives in UserDefaults, which under a self-test is still the user's own.
            // Put it back exactly as it was — including "never set" — when this section is done.
            let savedSwitch = UserDefaults.standard.object(forKey: IndexedFoldersStore.enabledKey)
            defer {
                list.isEnabled = false
                UserDefaults.standard.set(savedSwitch, forKey: IndexedFoldersStore.enabledKey)
            }
            list.isEnabled = true
            let vanishing = root.appendingPathComponent("Vanishing", isDirectory: true)
            try manager.createDirectory(at: vanishing, withIntermediateDirectories: true)
            list.add(vanishing)
            await settle()
            check("a folder that can be read was reported as a problem",
                  list.accessProblem(for: vanishing) == nil)
            try manager.removeItem(at: vanishing)
            check("the access verdict is computed on the spot instead of read from the cache — "
                  + "that blocks the main actor on the file system",
                  list.accessProblem(for: vanishing) == nil)
            list.refreshAccessProblems()
            await settle()
            check("the probe did not notice that a folder had gone",
                  list.accessProblem(for: vanishing) != nil)
            list.remove(vanishing)
            check("removing a folder left its access problem behind",
                  list.accessProblem(for: vanishing) == nil)
            check("probe invented a problem for a folder that can be read",
                  IndexedFoldersStore.probe(alpha.path) == nil)
        } catch is CancellationError {
            // Already recorded.
        } catch {
            failures.append("fixture tree failed: \(error.localizedDescription)")
        }

        if failures.isEmpty {
            print("FILE_INDEX_OK")
            return true
        }
        for failure in failures { print("FILE_INDEX_FAILED: \(failure)") }
        print("FILE_INDEX_FAILED")
        return false
    }
}

/// A retrieval seam over a fixture store, so the tools can be exercised without touching the
/// user's own folder list.
struct FixtureFileRetrieval: FileRetrieving {
    let store: FileIndexStore
    let roots: [String]

    var isAvailable: Bool { !roots.isEmpty }
    var folders: [String] { roots }

    func find(query: String, category: FileCategory?, folder: String?, modifiedAfter: Date?,
              limit: Int) throws -> [FileHit] {
        if let folder, !allows(folder) { return [] }
        return try store.find(query: query, category: category, folder: folder,
                              modifiedAfter: modifiedAfter, limit: limit)
    }

    func tree(path: String, depth: Int, limit: Int) throws -> (hits: [FileHit], total: Int) {
        guard allows(path) else { return ([], 0) }
        return (try store.tree(path: path, depth: depth, limit: limit), try store.subtreeCount(path: path))
    }

    func count(query: String) throws -> Int {
        try store.count(query: query)
    }
}
