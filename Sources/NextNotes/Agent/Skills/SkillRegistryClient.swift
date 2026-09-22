import Foundation

// Finding and adding a skill, without node, npx, git or a terminal.
//
// The user does not know what a package manager is and must never meet one. Search is one
// HTTPS GET against skills.sh; adding a skill is a handful of HTTPS GETs against GitHub that
// write plain files into our own folder. Nothing is executed, unpacked by a shell, or given
// a chance to write outside `SkillLibrary.installDirectory`.
//
// What skills.sh actually exposes (measured, 2026-09):
//
//     GET https://www.skills.sh/api/search?q=<query>
//     → {"query":"…","searchType":"fuzzy","skills":[
//          {"id":"owner/repo/skill-name","skillId":"skill-name","name":"skill-name",
//           "installs":52239,"source":"owner/repo"}, …]}
//
// That is the whole public API — the richer `/api/skills/…` routes documented by the
// `mastra-ai/skills-api` project belong to a server anyone can host, not to skills.sh, and
// they answer with the website's HTML here. In particular the search rows carry **no
// description**, so a one-line description has to come from the skill's own `SKILL.md` on
// GitHub. `describe` does that for the handful of rows a person is actually looking at.
//
// The registry index also goes stale — `markdown-viewer/skills/mermaid` is listed and no
// longer exists in that repository — so "not found in its repository" is a normal answer and
// is worded for a person, not as a failure.

// MARK: - Rows

/// One search hit from skills.sh.
struct RegistrySkill: Identifiable, Equatable, Sendable {
    /// `owner/repo/skill-name`, the registry's own id and what `skills.install` takes.
    var id: String
    var skillId: String
    var name: String
    var owner: String
    var repo: String
    /// Lifetime installs the registry reports. Shown as "N people added this".
    var installs: Int
    /// Filled in by `describe`; nil until the `SKILL.md` has been read.
    var description: String?

    var source: String { "\(owner)/\(repo)" }

    /// The folder name this would be installed under.
    var installName: String { SkillScanner.normalizedName(skillId) }

    init?(id: String, skillId: String, name: String, source: String, installs: Int) {
        let parts = source.split(separator: "/", omittingEmptySubsequences: true)
        guard parts.count >= 2 else { return nil }
        self.id = id
        self.skillId = skillId
        self.name = name.isEmpty ? skillId : name
        owner = String(parts[0])
        repo = String(parts[1])
        self.installs = installs
    }
}

/// Where a skill's files really are, once GitHub has been asked.
struct RegistryResolution: Equatable, Sendable {
    /// The commit the files were read at, so an install is reproducible and an update is a
    /// comparison rather than a guess.
    var commit: String
    /// The skill's folder inside the repository, e.g. `plugins/trailmark/skills/foo`.
    var folder: String
    /// Paths relative to `folder`, `SKILL.md` first.
    var files: [String]
    var byteCount: Int
}

enum SkillRegistryError: LocalizedError, Equatable {
    case offline
    case badResponse(Int)
    case rateLimited
    case notInRepository(String)
    case tooLarge(String)
    case unsafePath(String)
    case notInstalledByUs(String)
    case emptyQuery

    var errorDescription: String? {
        switch self {
        case .offline:
            "Next Notes could not reach the internet, so it cannot look for new skills right now."
        case .badResponse(let code):
            "The skills directory answered with an error (\(code)). Try again in a moment."
        case .rateLimited:
            "Too many skill lookups in the last hour. Try again later."
        case .notInRepository(let name):
            "\(name) is listed in the directory but is no longer in the project it came from."
        case .tooLarge(let name):
            "\(name) is too big to add — a skill should be a few pages of text, not a download."
        case .unsafePath(let path):
            "\(name(of: path)) tried to write outside its own folder, so it was not added."
        case .notInstalledByUs(let name):
            "\(name) came from another app on this Mac, so Next Notes cannot change or remove it."
        case .emptyQuery:
            "Type what you would like your assistant to be able to do."
        }
    }

    private func name(of path: String) -> String { path.isEmpty ? "That skill" : "“\(path)”" }
}

// MARK: - Path safety

/// The one gate every downloaded path passes through.
///
/// A skill arrives as a list of paths chosen by a stranger. `../../../.zshrc`,
/// `/etc/passwd`, `a/../../b` and a symlink pointing at the home folder are all the same
/// attack — "write me somewhere you did not mean" — and all of them die here rather than at
/// the `write`. This is the zip-slip check; it is written against the *path*, not against any
/// particular archive format, so it holds for the contents API, a codeload zip, or anything
/// we fetch later.
enum SkillPathSafety {
    static let maxComponents = 8
    static let maxLength = 200

    /// The path to use under the destination folder, or nil when it must be refused.
    static func sanitized(_ raw: String) -> String? {
        guard !raw.isEmpty, raw.count <= maxLength else { return nil }
        guard !raw.contains("\\"), !raw.contains("\u{0}"), !raw.contains(":") else { return nil }
        guard !raw.hasPrefix("/"), !raw.hasPrefix("~") else { return nil }
        let components = raw.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard components.count <= maxComponents else { return nil }
        for component in components {
            guard !component.isEmpty, component != ".", component != ".." else { return nil }
            guard !component.hasPrefix("."), !component.hasPrefix("~") else { return nil }
            guard component.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value != 0x7F }) else { return nil }
        }
        return components.joined(separator: "/")
    }

    /// `destination` joined with a sanitized path, proven to still be inside `destination`.
    ///
    /// The belt to the sanitizer's braces: `standardizedFileURL` resolves anything the string
    /// check somehow let through, and the prefix test is on the standardized parent.
    static func destination(_ root: URL, for raw: String) throws -> URL {
        guard let safe = sanitized(raw) else { throw SkillRegistryError.unsafePath(raw) }
        let url = root.appendingPathComponent(safe).standardizedFileURL
        let base = root.standardizedFileURL.path
        guard url.path == base || url.path.hasPrefix(base + "/") else {
            throw SkillRegistryError.unsafePath(raw)
        }
        return url
    }
}

// MARK: - The lock file

/// What we installed, from where, at which commit. Lives beside the skills themselves so a
/// user who copies the folder to another Mac keeps the provenance.
struct SkillLockEntry: Codable, Equatable, Sendable {
    var name: String
    var id: String
    var owner: String
    var repo: String
    var skillId: String
    var repoFolder: String
    var commit: String
    /// SHA-256 of `SKILL.md` as installed — what an update compares against.
    var contentHash: String
    var files: [String]
    var byteCount: Int
    var installedAt: Date
    var updatedAt: Date

    var source: String { "\(owner)/\(repo)" }
}

struct SkillLockFile: Codable, Equatable, Sendable {
    var version = 1
    var skills: [SkillLockEntry] = []
}

/// Reads and writes `skills-lock.json`. A missing or corrupt file is an empty lock, never an
/// error: the skills on disk are the truth, and the lock is how they got there.
struct SkillLockStore: Sendable {
    static let fileName = "skills-lock.json"
    let directory: URL

    var fileURL: URL { directory.appendingPathComponent(Self.fileName) }

    func load() -> SkillLockFile {
        guard let data = FileManager.default.contents(atPath: fileURL.path),
              let file = try? JSONDecoder.skillLock.decode(SkillLockFile.self, from: data)
        else { return SkillLockFile() }
        return file
    }

    func save(_ file: SkillLockFile) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var sorted = file
        sorted.skills.sort { $0.name < $1.name }
        try JSONEncoder.skillLock.encode(sorted).write(to: fileURL, options: .atomic)
    }

    func entry(named name: String) -> SkillLockEntry? {
        load().skills.first { $0.name == name }
    }

    func record(_ entry: SkillLockEntry) throws {
        var file = load()
        file.skills.removeAll { $0.name == entry.name }
        file.skills.append(entry)
        try save(file)
    }

    func forget(name: String) throws {
        var file = load()
        file.skills.removeAll { $0.name == name }
        try save(file)
    }
}

extension JSONDecoder {
    static var skillLock: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

extension JSONEncoder {
    static var skillLock: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }
}

// MARK: - The client

/// Search skills.sh, read a skill's `SKILL.md`, and install, update or remove one.
struct SkillRegistryClient: Sendable {
    /// Bounds on what "a skill" may be. A skill is prose and a few reference files; anything
    /// beyond this is a download pretending to be one.
    static let maxFiles = 64
    static let maxFileBytes = 1024 * 1024
    static let maxTotalBytes = 4 * 1024 * 1024
    static let searchLimit = 25

    static let searchEndpoint = URL(string: "https://www.skills.sh/api/search")!
    static let gitHubAPI = URL(string: "https://api.github.com")!
    static let gitHubRaw = URL(string: "https://raw.githubusercontent.com")!
    /// GitHub refuses an unauthenticated request with no User-Agent.
    static let userAgent = "NextNotes/1 (+https://next-notes.com)"

    var directory: URL
    var session: URLSession = .skillRegistry

    static var shared: SkillRegistryClient {
        SkillRegistryClient(directory: SkillLibrary.defaultInstallDirectory)
    }

    var lock: SkillLockStore { SkillLockStore(directory: directory) }

    // MARK: Search

    /// Skills the directory knows about, best first. Descriptions are not included — the
    /// registry does not carry them — so call `describe` for the few rows being shown.
    func search(_ query: String, limit: Int = SkillRegistryClient.searchLimit) async throws -> [RegistrySkill] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw SkillRegistryError.emptyQuery }
        var components = URLComponents(url: Self.searchEndpoint, resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "q", value: trimmed)]
        let data = try await get(components.url!)
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rows = object["skills"] as? [[String: Any]] else {
            throw SkillRegistryError.badResponse(200)
        }
        return rows.prefix(limit).compactMap { row in
            RegistrySkill(
                id: row["id"] as? String ?? "",
                skillId: row["skillId"] as? String ?? "",
                name: row["name"] as? String ?? "",
                source: row["source"] as? String ?? "",
                installs: row["installs"] as? Int ?? 0
            )
        }
        .filter { !$0.skillId.isEmpty }
    }

    /// The one-line description, read from the skill's own `SKILL.md` on GitHub.
    func describe(_ skill: RegistrySkill) async throws -> RegistrySkill {
        let resolution = try await resolve(skill)
        let text = try await readSkillFile(skill, resolution: resolution)
        var described = skill
        described.description = SkillFrontmatter.parse(text)?.frontmatter.description
        return described
    }

    // MARK: Resolve

    /// Where the skill's folder is inside its repository, and which files it holds.
    ///
    /// One request in the normal case: the full git tree, which is paths and sizes only. A
    /// repository too large for one tree response falls back to asking about the two or three
    /// places a skill is ever kept.
    func resolve(_ skill: RegistrySkill) async throws -> RegistryResolution {
        let url = Self.gitHubAPI.appending(path: "repos/\(skill.owner)/\(skill.repo)/git/trees/HEAD")
            .appending(queryItems: [URLQueryItem(name: "recursive", value: "1")])
        let data = try await get(url)
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SkillRegistryError.badResponse(200)
        }
        let commit = object["sha"] as? String ?? "HEAD"
        let entries = (object["tree"] as? [[String: Any]]) ?? []
        if let resolution = Self.resolution(in: entries, skillId: skill.skillId, commit: commit) {
            return resolution
        }
        if object["truncated"] as? Bool == true {
            return try await resolveByContents(skill, commit: commit)
        }
        throw SkillRegistryError.notInRepository(skill.name)
    }

    /// Picks the skill's folder out of a git tree. Pure, so the self-test can feed it a
    /// tree containing `../` and symlink entries.
    static func resolution(in entries: [[String: Any]], skillId: String, commit: String) -> RegistryResolution? {
        let wanted = SkillScanner.normalizedName(skillId)
        var folder: String?
        for entry in entries {
            guard entry["type"] as? String == "blob", let path = entry["path"] as? String else { continue }
            guard path.hasSuffix("/" + SkillScanner.skillFileName) || path == SkillScanner.skillFileName else {
                continue
            }
            let directory = path == SkillScanner.skillFileName
                ? ""
                : String(path.dropLast(SkillScanner.skillFileName.count + 1))
            let leaf = directory.split(separator: "/").last.map(String.init) ?? ""
            if SkillScanner.normalizedName(leaf) == wanted {
                folder = directory
                break
            }
        }
        guard let folder else { return nil }
        let prefix = folder.isEmpty ? "" : folder + "/"

        var files: [String] = []
        var bytes = 0
        for entry in entries {
            guard entry["type"] as? String == "blob", let path = entry["path"] as? String,
                  path.hasPrefix(prefix) else { continue }
            // 120000 is a symlink. A symlink is a path written by the author, so it is
            // exactly the thing the path gate exists to refuse; drop it rather than fetch it.
            let mode = entry["mode"] as? String ?? "100644"
            guard mode == "100644" || mode == "100755" else { continue }
            let relative = String(path.dropFirst(prefix.count))
            guard let safe = SkillPathSafety.sanitized(relative) else { continue }
            let size = entry["size"] as? Int ?? 0
            guard size <= maxFileBytes else { continue }
            guard files.count < maxFiles, bytes + size <= maxTotalBytes else { break }
            bytes += size
            if safe == SkillScanner.skillFileName { files.insert(safe, at: 0) } else { files.append(safe) }
        }
        guard files.first == SkillScanner.skillFileName else { return nil }
        return RegistryResolution(commit: commit, folder: folder, files: files, byteCount: bytes)
    }

    /// Fallback for a repository whose tree does not fit in one response.
    private func resolveByContents(_ skill: RegistrySkill, commit: String) async throws -> RegistryResolution {
        let candidates = ["skills/\(skill.skillId)", skill.skillId, ".claude/skills/\(skill.skillId)"]
        for candidate in candidates {
            let url = Self.gitHubAPI.appending(path: "repos/\(skill.owner)/\(skill.repo)/contents/\(candidate)")
            guard let data = try? await get(url),
                  let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
            else { continue }
            var files: [String] = []
            var bytes = 0
            for row in rows {
                guard row["type"] as? String == "file", let name = row["name"] as? String,
                      let safe = SkillPathSafety.sanitized(name) else { continue }
                let size = row["size"] as? Int ?? 0
                guard size <= Self.maxFileBytes, files.count < Self.maxFiles,
                      bytes + size <= Self.maxTotalBytes else { continue }
                bytes += size
                if safe == SkillScanner.skillFileName { files.insert(safe, at: 0) } else { files.append(safe) }
            }
            if files.first == SkillScanner.skillFileName {
                return RegistryResolution(commit: commit, folder: candidate, files: files, byteCount: bytes)
            }
        }
        throw SkillRegistryError.notInRepository(skill.name)
    }

    // MARK: Install

    /// Downloads the skill's folder into our own Skills directory and records the lock entry.
    ///
    /// Writes to a staging folder first, so a half-finished download never leaves a skill the
    /// Agent would then read as complete. Nothing is executed and every file is written
    /// non-executable: a script a skill bundles is text until the user approves it through the
    /// gated shell tool.
    @discardableResult
    func install(_ skill: RegistrySkill, resolution: RegistryResolution? = nil) async throws -> SkillLockEntry {
        let resolved: RegistryResolution
        if let resolution {
            resolved = resolution
        } else {
            resolved = try await resolve(skill)
        }
        guard resolved.byteCount <= Self.maxTotalBytes else { throw SkillRegistryError.tooLarge(skill.name) }
        let name = skill.installName
        guard !name.isEmpty else { throw SkillRegistryError.notInRepository(skill.name) }

        let manager = FileManager.default
        let final = try SkillPathSafety.destination(directory, for: name)
        let staging = directory.appendingPathComponent(".staging-\(UUID().uuidString)", isDirectory: true)
        try manager.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: staging) }

        var written: [String] = []
        var bytes = 0
        var skillFileHash = ""
        for relative in resolved.files {
            let target = try SkillPathSafety.destination(staging, for: relative)
            let path = resolved.folder.isEmpty ? relative : resolved.folder + "/" + relative
            let data = try await getRaw(owner: skill.owner, repo: skill.repo, commit: resolved.commit, path: path)
            guard data.count <= Self.maxFileBytes, bytes + data.count <= Self.maxTotalBytes else {
                throw SkillRegistryError.tooLarge(skill.name)
            }
            bytes += data.count
            try manager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: target, options: .atomic)
            // Read/write for the owner, read for everyone else, executable for nobody.
            try? manager.setAttributes([.posixPermissions: 0o644], ofItemAtPath: target.path)
            if relative == SkillScanner.skillFileName { skillFileHash = SkillHash.hex(data) }
            written.append(relative)
        }
        guard !skillFileHash.isEmpty else { throw SkillRegistryError.notInRepository(skill.name) }

        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        if manager.fileExists(atPath: final.path) { try manager.removeItem(at: final) }
        try manager.moveItem(at: staging, to: final)

        let now = Date()
        let existing = lock.entry(named: name)
        let entry = SkillLockEntry(
            name: name, id: skill.id, owner: skill.owner, repo: skill.repo, skillId: skill.skillId,
            repoFolder: resolved.folder, commit: resolved.commit, contentHash: skillFileHash,
            files: written, byteCount: bytes,
            installedAt: existing?.installedAt ?? now, updatedAt: now)
        try lock.record(entry)
        Log.agent.info("skills: added \(name, privacy: .public) from \(skill.source, privacy: .public)")
        return entry
    }

    /// Re-downloads a skill we installed. Returns nil when nothing changed.
    func update(name: String) async throws -> SkillLockEntry? {
        guard let entry = lock.entry(named: name) else { throw SkillRegistryError.notInstalledByUs(name) }
        guard let skill = RegistrySkill(id: entry.id, skillId: entry.skillId, name: entry.name,
                                        source: entry.source, installs: 0) else {
            throw SkillRegistryError.notInstalledByUs(name)
        }
        let resolved = try await resolve(skill)
        guard resolved.commit != entry.commit else { return nil }
        let updated = try await install(skill, resolution: resolved)
        return updated.contentHash == entry.contentHash ? nil : updated
    }

    /// Removes a skill we installed. Another app's folder is never touched.
    func remove(name: String) throws {
        guard lock.entry(named: name) != nil else { throw SkillRegistryError.notInstalledByUs(name) }
        let folder = try SkillPathSafety.destination(directory, for: name)
        if FileManager.default.fileExists(atPath: folder.path) {
            try FileManager.default.removeItem(at: folder)
        }
        try lock.forget(name: name)
        Log.agent.info("skills: removed \(name, privacy: .public)")
    }

    // MARK: Transport

    private func readSkillFile(_ skill: RegistrySkill, resolution: RegistryResolution) async throws -> String {
        let path = resolution.folder.isEmpty
            ? SkillScanner.skillFileName
            : resolution.folder + "/" + SkillScanner.skillFileName
        let data = try await getRaw(owner: skill.owner, repo: skill.repo, commit: resolution.commit, path: path)
        return String(data: data, encoding: .utf8) ?? ""
    }

    private func getRaw(owner: String, repo: String, commit: String, path: String) async throws -> Data {
        let escaped = path.split(separator: "/").map {
            $0.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? String($0)
        }.joined(separator: "/")
        let url = Self.gitHubRaw.appending(path: "\(owner)/\(repo)/\(commit)/\(escaped)")
        return try await get(url)
    }

    private func get(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError where Self.isOffline(error) {
            throw SkillRegistryError.offline
        }
        guard let http = response as? HTTPURLResponse else { throw SkillRegistryError.badResponse(0) }
        switch http.statusCode {
        case 200...299: return data
        case 403, 429: throw SkillRegistryError.rateLimited
        default: throw SkillRegistryError.badResponse(http.statusCode)
        }
    }

    static func isOffline(_ error: URLError) -> Bool {
        switch error.code {
        case .notConnectedToInternet, .cannotFindHost, .cannotConnectToHost, .networkConnectionLost,
             .dnsLookupFailed, .timedOut, .internationalRoamingOff, .dataNotAllowed:
            true
        default:
            false
        }
    }
}

extension URLSession {
    /// Short timeouts: this runs behind a search field and behind an Agent turn, and a stalled
    /// request there reads to the user as a frozen app.
    static let skillRegistry: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 45
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }()
}
