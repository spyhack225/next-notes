import CryptoKit
import Foundation

// Skills — "things your assistant knows how to do".
//
// A skill is a folder holding `SKILL.md`: YAML frontmatter with a `name` and a `description`,
// a Markdown body, and any number of bundled reference files. The format is shared across
// Claude Code, Codex, Cursor, Gemini CLI and OpenCode, which is the whole point of this file:
// the dozens of skills already sitting in the user's home folder are ours to read, and the
// user should never have to install anything twice.
//
// Three rules hold everything here together:
//
// 1. **Other apps' folders are read-only.** We scan them and we never write, move, rename or
//    delete anything inside them. Only `~/Library/Application Support/Next Notes/Skills` is
//    ours, and that is the only place `SkillRegistryClient` installs into.
// 2. **Skill text is untrusted.** It was written by a stranger on the internet. It is data the
//    model may read, never an instruction that can change what the Agent is allowed to do.
//    `SkillPromptIndex` labels it as such, and nothing here consults or edits permissions.
// 3. **Nothing is ever executed.** Discovery reads bytes. Install writes bytes. A script a
//    skill bundles is just a file until the user approves it through the gated shell tool.

/// The app a skill was found in. The user sees `badge`; nothing else about the app matters.
enum SkillSourceApp: String, Codable, Sendable, CaseIterable {
    /// `~/Library/Application Support/Next Notes/Skills` — the ones we installed.
    case nextNotes
    case claudeCode
    case claudePlugin
    case codex
    case agents
    case openCode
    case cursor
    case gemini

    /// What the badge in Settings says. Plain names a non-technical person recognises.
    var badge: String {
        switch self {
        case .nextNotes: "Added by you"
        case .claudeCode: "Claude"
        case .claudePlugin: "Claude plug-in"
        case .codex: "Codex"
        case .agents: "Shared folder"
        case .openCode: "OpenCode"
        case .cursor: "Cursor"
        case .gemini: "Gemini"
        }
    }

    /// Ours, so it may be updated or removed. Everything else is somebody else's folder.
    var isOurs: Bool { self == .nextNotes }
}

// MARK: - SKILL.md

/// The frontmatter of a `SKILL.md`, as much of it as anyone here needs.
///
/// Deliberately tolerant. These files are hand-written by thousands of people; a strict YAML
/// parser that refuses a tab or a stray colon would drop skills that every other agent reads
/// happily. Anything we cannot understand is ignored rather than fatal, and a file with no
/// usable `name` is the only thing that fails.
struct SkillFrontmatter: Equatable, Sendable {
    var name: String
    var description: String
    /// Everything else, flattened to strings, kept so the UI can show `license` or `version`
    /// if it ever wants to. Never consulted for permission decisions.
    var extras: [String: String] = [:]

    static let fence = "---"

    /// Splits `SKILL.md` into frontmatter and body. Returns nil when there is no frontmatter
    /// block at all, which is what makes a stray Markdown file not a skill.
    static func parse(_ text: String) -> (frontmatter: SkillFrontmatter, body: String)? {
        // A BOM and CRLF line endings both show up in the wild.
        let normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .trimmingCharacters(in: CharacterSet(charactersIn: "\u{FEFF}"))
        var lines = normalized.components(separatedBy: "\n")
        // Leading blank lines before the fence are common enough to allow.
        while let first = lines.first, first.trimmingCharacters(in: .whitespaces).isEmpty {
            lines.removeFirst()
        }
        guard let first = lines.first, first.trimmingCharacters(in: .whitespaces) == fence else { return nil }
        lines.removeFirst()
        guard let close = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == fence }) else {
            return nil
        }
        let block = Array(lines[..<close])
        let body = lines[(close + 1)...].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)

        var values = parseBlock(block)
        let name = values.removeValue(forKey: "name")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let description = values.removeValue(forKey: "description")?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !name.isEmpty else { return nil }
        return (SkillFrontmatter(name: name, description: description, extras: values), body)
    }

    /// Top-level `key: value` pairs. Block scalars (`|`, `>`), wrapped plain scalars and
    /// simple lists all collapse to one string, because that is all a badge or a prompt line
    /// can use anyway.
    private static func parseBlock(_ lines: [String]) -> [String: String] {
        var values: [String: String] = [:]
        var index = 0
        while index < lines.count {
            let line = lines[index]
            index += 1
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            // Top-level keys only: an indented line belongs to the key above it.
            guard line.first?.isWhitespace != true,
                  let colon = line.firstIndex(of: ":") else { continue }
            let key = String(line[line.startIndex..<colon]).trimmingCharacters(in: .whitespaces).lowercased()
            guard !key.isEmpty, key.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }) else {
                continue
            }
            var rest = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            var folded = rest == ">" || rest == ">-" || rest == ">+"
            let literal = rest == "|" || rest == "|-" || rest == "|+"
            if folded || literal { rest = "" }

            var continuation: [String] = []
            if rest.isEmpty || folded || literal {
                // Everything indented under the key, be it a block scalar or a list.
                while index < lines.count {
                    let next = lines[index]
                    if next.trimmingCharacters(in: .whitespaces).isEmpty {
                        if !continuation.isEmpty { continuation.append("") }
                        index += 1
                        continue
                    }
                    guard next.first?.isWhitespace == true else { break }
                    var item = next.trimmingCharacters(in: .whitespaces)
                    if item.hasPrefix("- ") { item = String(item.dropFirst(2)) }
                    continuation.append(unquote(item))
                    index += 1
                }
                if !literal { folded = true }
            } else {
                // A plain scalar wrapped over several indented lines — very common for the
                // long `description` line that decides whether a skill is relevant.
                while index < lines.count {
                    let next = lines[index]
                    guard next.first?.isWhitespace == true,
                          !next.trimmingCharacters(in: .whitespaces).isEmpty,
                          !next.trimmingCharacters(in: .whitespaces).hasPrefix("- ") else { break }
                    continuation.append(next.trimmingCharacters(in: .whitespaces))
                    index += 1
                }
                folded = true
            }

            var value = unquote(rest)
            if !continuation.isEmpty {
                let joined = folded
                    ? continuation.filter { !$0.isEmpty }.joined(separator: " ")
                    : continuation.joined(separator: "\n")
                value = value.isEmpty ? joined : value + " " + joined
            }
            values[key] = value.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return values
    }

    private static func unquote(_ raw: String) -> String {
        var value = raw.trimmingCharacters(in: .whitespaces)
        if value.count >= 2,
           (value.hasPrefix("\"") && value.hasSuffix("\"")) || (value.hasPrefix("'") && value.hasSuffix("'")) {
            value = String(value.dropFirst().dropLast())
        }
        return value
    }
}

// MARK: - One skill

/// One skill folder as the app sees it.
struct Skill: Identifiable, Equatable, Sendable {
    /// Stable across rescans: the app it came from plus the folder name, both of which are
    /// fixed on disk. The display name can repeat across apps; this cannot.
    var id: String
    var name: String
    var description: String
    var source: SkillSourceApp
    /// The folder holding `SKILL.md`.
    var folder: URL
    /// SHA-256 of `SKILL.md`, hex. Two copies of the same skill in two apps share this.
    var contentHash: String
    /// Paths of the bundled files, relative to `folder`, `SKILL.md` first. Bounded by
    /// `SkillScanner.maxBundledFiles`.
    var files: [String]
    var byteCount: Int
    var modifiedAt: Date?
    /// The other apps the identical skill was also found in, for the "also in Codex" line.
    var alsoIn: [SkillSourceApp] = []
    /// A different skill of the same name won, so this one is not offered to the model.
    var isShadowed = false

    var skillFile: URL { folder.appendingPathComponent(SkillScanner.skillFileName) }

    /// One line for a list row or a prompt entry. Never more than a sentence or two.
    ///
    /// Whitespace is collapsed first, and that is load-bearing rather than cosmetic: a
    /// description written as a literal block scalar (`description: |`) keeps its newlines
    /// through the parser, and this string is interpolated straight into the planner's system
    /// prompt as one bullet. Without the collapse, whoever wrote the `SKILL.md` — a stranger
    /// on the internet — gets to place arbitrary *lines* into the prompt's structure, which is
    /// exactly the thing the "untrusted text" header promises the model is impossible. One
    /// line in, one line out.
    func summary(limit: Int = 160) -> String {
        let flattened = description.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let text = flattened.isEmpty ? "No description." : flattened
        guard text.count > limit else { return text }
        return String(text.prefix(limit - 1)) + "…"
    }
}

// MARK: - Where skills live

/// The folders other agents keep skills in, in the order they are trusted to name a skill.
///
/// Ours is first so a skill the user added here keeps the "Added by you" badge even when a
/// byte-identical copy also sits in `~/.claude/skills`.
enum SkillRoots {
    struct Root: Sendable {
        let url: URL
        let source: SkillSourceApp
        /// Scan this folder's children only (`<root>/<skill>/SKILL.md`), or walk deeper
        /// looking for nested `skills/` folders.
        let isNested: Bool
    }

    /// Plugin trees hold downloaded marketplace *catalogues* beside actually-installed
    /// plugins. A catalogue is a list of things the user has not added, so it is not a
    /// source of skills — including it put 56 uninstalled skills in front of the user.
    static let excludedPluginFolders: Set<String> = ["marketplaces"]

    static func all(home: URL = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true),
                    ours: URL = SkillLibrary.defaultInstallDirectory) -> [Root] {
        [
            Root(url: ours, source: .nextNotes, isNested: false),
            Root(url: home.appendingPathComponent(".claude/skills", isDirectory: true),
                 source: .claudeCode, isNested: false),
            Root(url: home.appendingPathComponent(".claude/plugins", isDirectory: true),
                 source: .claudePlugin, isNested: true),
            Root(url: home.appendingPathComponent(".codex/skills", isDirectory: true),
                 source: .codex, isNested: false),
            Root(url: home.appendingPathComponent(".agents/skills", isDirectory: true),
                 source: .agents, isNested: false),
            Root(url: home.appendingPathComponent(".config/opencode/skills", isDirectory: true),
                 source: .openCode, isNested: false),
            Root(url: home.appendingPathComponent(".config/opencode/skill", isDirectory: true),
                 source: .openCode, isNested: false),
            Root(url: home.appendingPathComponent(".cursor/skills", isDirectory: true),
                 source: .cursor, isNested: false),
            Root(url: home.appendingPathComponent(".gemini/skills", isDirectory: true),
                 source: .gemini, isNested: false),
        ]
    }
}

// MARK: - Discovery

/// Reads skill folders off the disk. Pure: give it roots, get skills. Never writes.
enum SkillScanner {
    static let skillFileName = "SKILL.md"
    /// A skill is prose. Anything past this is not a skill we can put in a prompt.
    static let maxSkillFileBytes = 512 * 1024
    /// Bundled files listed per skill; the rest are on disk but not advertised.
    static let maxBundledFiles = 64
    /// How deep a nested root (`~/.claude/plugins`) is walked looking for `skills/`.
    static let maxNestedDepth = 6
    /// A hard stop so a pathological home folder cannot hang a launch.
    static let maxSkillsPerRoot = 500

    /// Every skill under `roots`, de-duplicated by name and content.
    ///
    /// Two passes on purpose. The first collects candidates in root order; the second decides
    /// which of several same-named candidates the Agent actually gets, because a model told
    /// about two different skills called `mermaid` cannot name the one it meant.
    static func scan(roots: [SkillRoots.Root]) -> [Skill] {
        var candidates: [Skill] = []
        for root in roots {
            candidates.append(contentsOf: scan(root: root))
        }
        return resolve(candidates)
    }

    static func scan(root: SkillRoots.Root) -> [Skill] {
        let manager = FileManager.default
        var isDirectory: ObjCBool = false
        guard manager.fileExists(atPath: root.url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return []
        }
        var folders: [URL] = []
        if root.isNested {
            folders = nestedSkillFolders(under: root.url)
        } else {
            let children = (try? manager.contentsOfDirectory(
                at: root.url, includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles])) ?? []
            folders = children.filter { manager.fileExists(atPath: $0.appendingPathComponent(skillFileName).path) }
        }
        var skills: [Skill] = []
        for folder in folders.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            guard skills.count < maxSkillsPerRoot else { break }
            if let skill = read(folder: folder, source: root.source) { skills.append(skill) }
        }
        return skills
    }

    /// `<root>/**/skills/<skill>/SKILL.md`, bounded in depth and skipping catalogues.
    private static func nestedSkillFolders(under root: URL) -> [URL] {
        let manager = FileManager.default
        var found: [URL] = []
        var queue: [(url: URL, depth: Int)] = [(root, 0)]
        while let entry = queue.first {
            queue.removeFirst()
            guard entry.depth <= maxNestedDepth else { continue }
            let children = (try? manager.contentsOfDirectory(
                at: entry.url, includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants])) ?? []
            for child in children {
                guard (try? child.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { continue }
                let name = child.lastPathComponent
                if entry.depth == 0, SkillRoots.excludedPluginFolders.contains(name) { continue }
                if name == "skills" || name == "skill" {
                    let leaves = (try? manager.contentsOfDirectory(
                        at: child, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
                    found.append(contentsOf: leaves.filter {
                        manager.fileExists(atPath: $0.appendingPathComponent(skillFileName).path)
                    })
                    continue
                }
                queue.append((child, entry.depth + 1))
            }
        }
        return found
    }

    /// One folder, or nil when it is not a skill we can use.
    static func read(folder: URL, source: SkillSourceApp) -> Skill? {
        let manager = FileManager.default
        let file = folder.appendingPathComponent(skillFileName)
        guard let attributes = try? manager.attributesOfItem(atPath: file.path),
              let size = attributes[.size] as? Int, size <= maxSkillFileBytes,
              let data = manager.contents(atPath: file.path),
              let text = String(data: data, encoding: .utf8),
              let parsed = SkillFrontmatter.parse(text)
        else { return nil }

        // The folder name is what every agent actually addresses a skill by; frontmatter
        // `name` sometimes drifts from it. Prefer the folder, keep the other as the title.
        let folderName = folder.lastPathComponent
        let name = normalizedName(folderName.isEmpty ? parsed.frontmatter.name : folderName)
        guard !name.isEmpty else { return nil }

        var files = [skillFileName]
        var bytes = size
        // Enumerate the folder by its *canonical* path, and measure relative paths against
        // that same string. Two separate things go wrong otherwise, and both of them end with
        // a skill that looks like a lone `SKILL.md`:
        //
        // 1. Almost every skill folder on a real Mac is a symlink — `~/.claude/skills/x ->
        //    ../../.agents/skills/x` is how these tools share one copy, 158 of the 162 here —
        //    and `FileManager.enumerator(at:)` yields *nothing at all* when the root URL it is
        //    handed is a symlink to a directory.
        // 2. The enumerator reports children by their fully-resolved path, so a prefix taken
        //    from the unresolved folder never matches and every nested file collapses to its
        //    bare filename (`rules.md` instead of `reference/rules.md`). `URL.resolvingSymlinks\
        //    InPath()` is not enough to paper over this: it leaves `/var/folders/…` alone while
        //    the enumerator says `/private/var/folders/…`. `realpath` agrees with the
        //    enumerator, which is the only thing that matters here.
        //
        // Reading these paths back through `skill.folder` still works: the symlink resolves on
        // open, so the rest of the app keeps addressing the skill where the user's agent put it.
        let basePath = canonicalPath(folder)
        let basePrefix = basePath.hasSuffix("/") ? basePath : basePath + "/"
        let enumerator = manager.enumerator(
            at: URL(fileURLWithPath: basePath, isDirectory: true),
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles])
        while let next = enumerator?.nextObject() as? URL, files.count < maxBundledFiles {
            let values = try? next.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values?.isRegularFile == true else { continue }
            bytes += values?.fileSize ?? 0
            let relative = next.path.hasPrefix(basePrefix)
                ? String(next.path.dropFirst(basePrefix.count))
                : next.lastPathComponent
            if relative != skillFileName { files.append(relative) }
        }
        files.sort { left, right in
            if left == skillFileName { return true }
            if right == skillFileName { return false }
            return left < right
        }

        return Skill(
            id: "\(source.rawValue)/\(name)",
            name: name,
            description: parsed.frontmatter.description.isEmpty
                ? String(parsed.body.prefix(200)).replacingOccurrences(of: "\n", with: " ")
                : parsed.frontmatter.description,
            source: source,
            folder: folder,
            contentHash: SkillHash.hex(data),
            files: files,
            byteCount: bytes,
            modifiedAt: attributes[.modificationDate] as? Date
        )
    }

    /// A path with every symlink and `..` resolved, exactly as `FileManager`'s enumerator
    /// reports its children. Falls back to the path as given when the folder cannot be
    /// resolved, which only happens when it has just been deleted underneath us.
    static func canonicalPath(_ url: URL) -> String {
        guard let resolved = realpath(url.path, nil) else { return url.path }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    /// A skill name as the model will type it: lower case, no spaces.
    static func normalizedName(_ raw: String) -> String {
        let allowed = raw.lowercased().map { character -> Character in
            character.isLetter || character.isNumber || character == "-" || character == "_" ? character : "-"
        }
        return String(allowed).trimmingCharacters(in: CharacterSet(charactersIn: "-_"))
    }

    /// Collapses identical copies and marks same-name conflicts.
    ///
    /// `~/.agents/skills` on this machine is a near-complete copy of `~/.claude/skills`, so
    /// without this the user is shown every skill twice.
    static func resolve(_ candidates: [Skill]) -> [Skill] {
        var byHash: [String: Int] = [:]
        var resolved: [Skill] = []
        for candidate in candidates {
            let key = candidate.name + "\u{0}" + candidate.contentHash
            if let existing = byHash[key] {
                // Root order decides the badge, but never at the cost of content: if the copy
                // we already kept can see fewer files than this one, the kept copy is degraded
                // (an unreadable folder, a permission we lack) and would make `skills.read`
                // refuse bundled files that plainly exist. Take the richer record, keeping the
                // displaced app in `alsoIn` so the user still sees where else it lives.
                if candidate.files.count > resolved[existing].files.count {
                    var promoted = candidate
                    promoted.alsoIn = resolved[existing].alsoIn
                    if !promoted.alsoIn.contains(resolved[existing].source) {
                        promoted.alsoIn.append(resolved[existing].source)
                    }
                    promoted.alsoIn.removeAll { $0 == promoted.source }
                    resolved[existing] = promoted
                } else if !resolved[existing].alsoIn.contains(candidate.source) {
                    resolved[existing].alsoIn.append(candidate.source)
                }
                continue
            }
            byHash[key] = resolved.count
            resolved.append(candidate)
        }
        // A second, different skill of the same name is kept and shown, but shadowed: only
        // the first can be named unambiguously.
        var seenNames = Set<String>()
        for index in resolved.indices {
            if !seenNames.insert(resolved[index].name).inserted {
                resolved[index].isShadowed = true
            }
        }
        return resolved
    }
}

/// SHA-256, hex. The identity of a skill's text: two copies in two apps share it, and an
/// update is "the hash changed".
enum SkillHash {
    static func hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func hex(_ text: String) -> String { hex(Data(text.utf8)) }
}

// MARK: - The library

/// Every skill on this Mac, what the user switched off, and the folder we install into.
///
/// Feature-local on purpose: one `@Observable` class plus two `UserDefaults` keys, rather than
/// new properties on `Settings`.
@MainActor
@Observable
final class SkillLibrary {
    static let shared = SkillLibrary()

    /// Master switch. Skills cost prompt space, so the user can turn the whole thing off.
    static let enabledDefaultsKey = "agentSkillsEnabled"
    /// Ids of skills the user switched off individually.
    static let disabledDefaultsKey = "agentSkillsDisabledIDs"

    private(set) var skills: [Skill] = []
    private(set) var lastScan: Date?
    private(set) var isScanning = false
    /// Set when the last scan could not read something the user would expect to see.
    private(set) var scanNote: String?

    private let defaults: UserDefaults
    private let roots: [SkillRoots.Root]
    let installDirectory: URL

    /// `~/Library/Application Support/Next Notes/Skills`, or a per-process temporary folder
    /// under a self-test so the user's own installs are never touched.
    nonisolated static var defaultInstallDirectory: URL {
        if SelfTest.isRunning {
            return FileManager.default.temporaryDirectory
                .appendingPathComponent("NextNotesSelfTest-skills-\(ProcessInfo.processInfo.processIdentifier)",
                                        isDirectory: true)
        }
        return AppIdentity.applicationSupportDirectory.appendingPathComponent("Skills", isDirectory: true)
    }

    init(installDirectory: URL = SkillLibrary.defaultInstallDirectory,
         roots: [SkillRoots.Root]? = nil,
         defaults: UserDefaults = .standard) {
        self.installDirectory = installDirectory
        self.roots = roots ?? SkillRoots.all(ours: installDirectory)
        self.defaults = defaults
        isEnabled = defaults.object(forKey: Self.enabledDefaultsKey) as? Bool ?? true
        disabledIDs = Set(defaults.stringArray(forKey: Self.disabledDefaultsKey) ?? [])
    }

    /// Stored rather than computed off `UserDefaults`, so `@Observable` sees the change and
    /// the pane redraws; the defaults write is the durable half of the same assignment.
    var isEnabled: Bool {
        didSet { defaults.set(isEnabled, forKey: Self.enabledDefaultsKey) }
    }

    private var disabledIDs: Set<String> {
        didSet { defaults.set(Array(disabledIDs).sorted(), forKey: Self.disabledDefaultsKey) }
    }

    func isOn(_ skill: Skill) -> Bool { !disabledIDs.contains(skill.id) }

    /// The switch takes effect on the Agent's next turn: the prompt index is rebuilt per
    /// request, and the executor re-checks before it runs anything.
    func setOn(_ skill: Skill, _ on: Bool) {
        if on { disabledIDs.remove(skill.id) } else { disabledIDs.insert(skill.id) }
    }

    /// Skills the Agent may actually use: the master switch on, not switched off, not shadowed.
    var active: [Skill] {
        guard isEnabled else { return [] }
        return skills.filter { isOn($0) && !$0.isShadowed }
    }

    /// The ones we installed, which are the only ones that can be updated or removed.
    var installed: [Skill] { skills.filter { $0.source.isOurs } }

    /// Everything found in another app's folder.
    var fromOtherApps: [Skill] { skills.filter { !$0.source.isOurs } }

    func skill(named name: String) -> Skill? {
        let wanted = SkillScanner.normalizedName(name)
        return active.first { $0.name == wanted } ?? skills.first { $0.name == wanted }
    }

    /// Re-read every root. Cheap enough for launch and for the Rescan button: it stats a few
    /// hundred small files. Off the main actor because it touches the disk.
    func rescan() async {
        guard !isScanning else { return }
        isScanning = true
        defer { isScanning = false }
        let roots = self.roots
        let found = await Task.detached(priority: .utility) { SkillScanner.scan(roots: roots) }.value
        skills = found
        lastScan = Date()
        scanNote = found.isEmpty ? "No skills found on this Mac yet." : nil
        Log.agent.info("skills: \(found.count, privacy: .public) found across \(roots.count, privacy: .public) folders")
    }

    /// Called after an install or a remove, which only ever changes our own folder.
    func refreshInstalled() async {
        await rescan()
    }
}
