import Foundation

/// Where an import came from. The list is the one on the "Bring memory in" sheet.
///
/// What each assistant actually lets a person take out today (checked September 2026, and
/// worth re-checking, because all four keep changing it):
///
/// - **ChatGPT** — *Settings ▸ Data controls ▸ Export data* mails a zip of
///   `conversations.json`, `chat.html` and `user.json`. It does **not** contain the
///   "Memory" entries shown in the app; `user.json` holds the custom instructions and
///   nothing else. Asking ChatGPT to list what it remembers is the only route to those.
/// - **Claude** — *Settings ▸ Privacy ▸ Export data* gives `conversations.json` and account
///   data. Memory is likewise not in it; Claude's own memory import is a paste box, which is
///   exactly the shape of our paste route.
/// - **Grok** — `accounts.x.ai/data` prepares a zip of conversations. Memories can be seen
///   and deleted one at a time in the app but not downloaded.
/// - **Muse (Meta)** — *Data controls ▸ Download your agent data*.
/// - **Gemini** — Google Takeout, as *My Activity* HTML or JSON.
///
/// So the file route has to be tolerant rather than clever, and the paste route is the one
/// that reliably carries memory. Both end in the same review step.
enum MemoryImportSource: String, CaseIterable, Identifiable, Sendable {
    case muse
    case grok
    case chatGPT
    case claude
    case gemini
    case other

    var id: String { rawValue }

    /// What the person calls it.
    var displayName: String {
        switch self {
        case .muse: "Muse"
        case .grok: "Grok"
        case .chatGPT: "ChatGPT"
        case .claude: "Claude"
        case .gemini: "Gemini"
        case .other: "Another assistant"
        }
    }

    /// The name stored beside each imported fact: "Imported from Grok, 19 Sep 2026".
    var storedName: String {
        self == .other ? "another assistant" : displayName
    }

    /// One plain sentence telling the person where to go.
    var openingStep: String {
        switch self {
        case .muse: "Open Muse and start a new chat."
        case .grok: "Open Grok — grok.com, or the X app — and start a new chat."
        case .chatGPT: "Open ChatGPT and start a new chat."
        case .claude: "Open Claude and start a new chat."
        case .gemini: "Open Gemini and start a new chat."
        case .other: "Open the other assistant and start a new conversation."
        }
    }

    /// What is worth knowing before they try the file route instead.
    var fileNote: String? {
        switch self {
        case .chatGPT:
            "ChatGPT's own data download does not include what it remembers about you — only "
                + "your conversations. Pasting works much better."
        case .claude:
            "Claude's data export does not include what it remembers about you — only your "
                + "conversations. Pasting works much better."
        case .grok:
            "Grok lets you see what it remembers but not download it, so pasting is the way in."
        case .muse, .gemini, .other:
            nil
        }
    }
}

/// The message the person pastes into the other assistant.
///
/// Written to produce exactly what the review step wants: one fact per line, already in the
/// third person, nothing temporary, and no secrets. Every word of it is aimed at a language
/// model, so it is kept off the screen except inside the copy button's own box.
enum MemoryImportPrompt {
    static let text = """
        List everything you remember about me.

        - One fact per line, each line starting with "- ".
        - Write each fact as a plain statement about me in the third person, beginning with \
        "The user" — for example "- The user prefers short answers."
        - Cover who I am and what I do, the people, places and projects I bring up, how I \
        like you to answer, and anything else you have kept about me across conversations.
        - Leave out anything that only mattered for one conversation, anything you are \
        guessing at, and any password, key, card or account number.
        - No headings, no numbering, no explanation before or after. Just the list.
        """
}

/// What a file or a paste turned out to contain.
struct MemoryImportContent: Sendable {
    /// One of our own exports, ready to restore rather than distil.
    var package: MemoryPackage?
    /// Everything else, as plain text for the extractor.
    var text: String
    /// What the reader will call this in the receipt.
    var origin: String
    /// A plain sentence about what was read, shown above the review list.
    var note: String?

    var isOurOwnExport: Bool { package != nil }
}

enum MemoryImportError: LocalizedError, Equatable {
    case unreadable(String)
    case tooLarge(String)
    case empty(String)

    var errorDescription: String? {
        switch self {
        case .unreadable(let name): "\(name) isn't a kind of file this can read."
        case .tooLarge(let name): "\(name) is too big to read."
        case .empty(let name): "There was no text in \(name)."
        }
    }
}

/// Turns a file, a folder, a zip or a pasted block into something the extractor can chew.
///
/// Tolerant on purpose: the shapes on the other side change without notice, so anything
/// unrecognised falls through to "treat it as text", which still works because the
/// extraction step downstream reads sentences rather than schemas.
enum MemoryImportReader {
    /// A single file this will open. Bigger than this and the answer is no, rather than
    /// several minutes of a beachball.
    static let maxFileBytes = 64 * 1024 * 1024
    /// How much harvested text reaches the extractor.
    static let maxHarvestedCharacters = 250_000
    /// How many files inside a folder or a zip are read.
    static let maxFilesRead = 400

    static let readableExtensions: Set<String> = [
        "json", "md", "markdown", "txt", "text", "csv", "tsv", "html", "htm", "zip",
    ]

    // MARK: - Entry points

    /// A block the person pasted. Never a package — a package arrives as a file.
    static func read(pasted text: String, from source: MemoryImportSource) -> MemoryImportContent {
        MemoryImportContent(package: nil, text: text, origin: source.storedName, note: nil)
    }

    /// A file, a folder, or a zip.
    static func read(fileAt url: URL) throws -> MemoryImportContent {
        let name = url.lastPathComponent
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            throw MemoryImportError.unreadable(name)
        }
        if isDirectory.boolValue {
            return try readFolder(url)
        }
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size <= maxFileBytes else { throw MemoryImportError.tooLarge(name) }

        if url.pathExtension.lowercased() == "zip" {
            return try readZip(url)
        }
        guard let data = try? Data(contentsOf: url) else { throw MemoryImportError.unreadable(name) }
        if let package = MemoryPackage.decode(data) {
            return content(for: package)
        }
        let harvest = harvest(data: data, name: name)
        guard !harvest.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw MemoryImportError.empty(name)
        }
        return MemoryImportContent(package: nil, text: harvest.text,
                                   origin: originName(url), note: harvest.note)
    }

    // MARK: - Containers

    private static func readFolder(_ folder: URL) throws -> MemoryImportContent {
        // Our own export, handed back as the folder rather than the file inside it.
        let inner = folder.appendingPathComponent(MemoryPackage.jsonFileName)
        if let data = try? Data(contentsOf: inner), let package = MemoryPackage.decode(data) {
            return content(for: package)
        }
        let files = readableFiles(in: folder)
        guard !files.isEmpty else { throw MemoryImportError.empty(folder.lastPathComponent) }
        for file in files {
            if let data = try? Data(contentsOf: file), let package = MemoryPackage.decode(data) {
                return content(for: package)
            }
        }
        var text = ""
        var notes: [String] = []
        for file in files {
            guard let data = try? Data(contentsOf: file) else { continue }
            let harvest = harvest(data: data, name: file.lastPathComponent)
            if let note = harvest.note { notes.append(note) }
            text += harvest.text + "\n"
            if text.count >= maxHarvestedCharacters { break }
        }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw MemoryImportError.empty(folder.lastPathComponent)
        }
        return MemoryImportContent(package: nil, text: String(text.prefix(maxHarvestedCharacters)),
                                   origin: originName(folder), note: notes.first)
    }

    /// Unzips into a temporary folder with the system's own `unzip`, then reads the folder.
    ///
    /// Shelling out rather than adding an archive dependency: this is one read of one file
    /// the person picked, and `/usr/bin/unzip` has been on every Mac for twenty years. Only
    /// files that land *inside* the temporary folder are read afterwards, so an archive with
    /// `../` in its entries cannot reach anything.
    private static func readZip(_ url: URL) throws -> MemoryImportContent {
        let manager = FileManager.default
        let staging = manager.temporaryDirectory
            .appendingPathComponent("NextNotesImport-\(UUID().uuidString)", isDirectory: true)
        try manager.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: staging) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-o", "-qq", url.path, "-d", staging.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            throw MemoryImportError.unreadable(url.lastPathComponent)
        }
        process.waitUntilExit()
        // `unzip` exits 1 on warnings (a skipped entry) and still extracts the rest.
        guard process.terminationStatus <= 1 else {
            throw MemoryImportError.unreadable(url.lastPathComponent)
        }
        var content = try readFolder(staging)
        content.origin = originName(url)
        return content
    }

    /// Every readable file inside, deepest paths last, bounded in count and confined to the
    /// folder itself.
    private static func readableFiles(in folder: URL) -> [URL] {
        let root = folder.standardizedFileURL.path
        guard let walker = FileManager.default.enumerator(
            at: folder, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
        var found: [URL] = []
        for case let url as URL in walker {
            guard found.count < maxFilesRead else { break }
            guard url.standardizedFileURL.path.hasPrefix(root) else { continue }
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values?.isRegularFile == true else { continue }
            guard (values?.fileSize ?? 0) <= maxFileBytes else { continue }
            guard readableExtensions.contains(url.pathExtension.lowercased()) else { continue }
            found.append(url)
        }
        // `memory.json` and anything with "memor" in its name first: a folder holding both a
        // memory file and a year of conversations should be read as the memory file.
        return found.sorted { lhs, rhs in
            let left = lhs.lastPathComponent.lowercased().contains("memor")
            let right = rhs.lastPathComponent.lowercased().contains("memor")
            if left != right { return left }
            return lhs.lastPathComponent < rhs.lastPathComponent
        }
    }

    // MARK: - One file's text

    /// The readable text inside one file, whatever shape it came in.
    static func harvest(data: Data, name: String) -> (text: String, note: String?) {
        guard let raw = String(data: data, encoding: .utf8)
                ?? String(data: data, encoding: .isoLatin1) else { return ("", nil) }
        switch name.split(separator: ".").last.map({ $0.lowercased() }) ?? "" {
        case "json":
            return harvestJSON(data: data, raw: raw, name: name)
        case "html", "htm":
            return (strippingHTML(raw), nil)
        case "csv", "tsv":
            return (harvestSeparated(raw, separator: name.hasSuffix("tsv") ? "\t" : ","), nil)
        default:
            return (String(raw.prefix(maxHarvestedCharacters)), nil)
        }
    }

    private static func harvestJSON(data: Data, raw: String, name: String) -> (text: String, note: String?) {
        guard let object = try? JSONSerialization.jsonObject(with: data) else {
            return (String(raw.prefix(maxHarvestedCharacters)), nil)
        }
        // ChatGPT and Claude both call their export `conversations.json`, and both are a
        // list of conversations. Only what the person themselves wrote is harvested — an
        // assistant's own replies are not facts about them.
        let userTurns = conversationTurns(object)
        if !userTurns.isEmpty {
            let note = "Read \(userTurns.count) of your own messages out of \(name). A "
                + "conversation download doesn't contain what the assistant remembers about "
                + "you, so this is a guess from what you said — check every line below."
            return (userTurns.joined(separator: "\n"), note)
        }
        let strings = memoryLikeStrings(object)
        if !strings.isEmpty {
            return (strings.joined(separator: "\n"), nil)
        }
        return (String(raw.prefix(maxHarvestedCharacters)), nil)
    }

    /// The person's own messages out of a ChatGPT or Claude conversation export.
    ///
    /// Longest first and capped: a year of chat is far more than a 4B model will read, and
    /// the long messages are where the durable facts are.
    static func conversationTurns(_ object: Any, limit: Int = 150) -> [String] {
        var found: [String] = []
        func walk(_ value: Any, depth: Int) {
            guard depth < 10, found.count < 4_000 else { return }
            if let dictionary = value as? [String: Any] {
                // Claude: { "sender": "human", "text": "…" }
                if let sender = dictionary["sender"] as? String, sender == "human" {
                    if let text = dictionary["text"] as? String { found.append(text) }
                    if let parts = dictionary["content"] as? [[String: Any]] {
                        found += parts.compactMap { $0["text"] as? String }
                    }
                }
                // ChatGPT: { "author": { "role": "user" }, "content": { "parts": [ … ] } }
                if let author = dictionary["author"] as? [String: Any],
                   author["role"] as? String == "user",
                   let content = dictionary["content"] as? [String: Any],
                   let parts = content["parts"] as? [Any] {
                    found += parts.compactMap { $0 as? String }
                }
                for (_, nested) in dictionary { walk(nested, depth: depth + 1) }
            } else if let array = value as? [Any] {
                for nested in array { walk(nested, depth: depth + 1) }
            }
        }
        walk(object, depth: 0)
        var total = 0
        return found
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.count > 20 }
            .sorted { $0.count > $1.count }
            // Clipped before the running total, not after: one 300 KB message would
            // otherwise blow the budget on its own and leave the harvest empty.
            .map { String($0.prefix(maxMessageCharacters)) }
            .prefix(limit)
            .filter { text in
                total += text.count
                return total <= maxHarvestedCharacters
            }
    }

    /// How much of one message is kept. A long one is a wall of context with a fact or two
    /// in it, and the distiller reads sentences rather than essays.
    static let maxMessageCharacters = 4_000

    /// Strings under a key that sounds like memory, out of any JSON at all. This is what
    /// catches a shape nobody here has seen.
    static func memoryLikeStrings(_ object: Any, limit: Int = 400) -> [String] {
        let interesting = ["memor", "fact", "profile", "about", "instruction", "preference",
                           "note", "persona", "summary", "bio"]
        var found: [String] = []
        func walk(_ value: Any, key: String, depth: Int) {
            guard depth < 10, found.count < limit else { return }
            let keyMatters = interesting.contains { key.lowercased().contains($0) }
            if let text = value as? String {
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if keyMatters, trimmed.count >= 8, trimmed.count <= 4_000 { found.append(trimmed) }
                return
            }
            if let dictionary = value as? [String: Any] {
                for (nestedKey, nested) in dictionary.sorted(by: { $0.key < $1.key }) {
                    // A key that matters carries down, so `memories: [{ "content": … }]` works.
                    walk(nested, key: keyMatters ? key : nestedKey, depth: depth + 1)
                }
            } else if let array = value as? [Any] {
                for nested in array { walk(nested, key: key, depth: depth + 1) }
            }
        }
        walk(object, key: "", depth: 0)
        return found
    }

    /// One row per line, the longest cell of each: enough for the table shapes people
    /// actually export, without pretending to be a CSV library.
    static func harvestSeparated(_ raw: String, separator: Character) -> String {
        raw.split(whereSeparator: \.isNewline)
            .prefix(2_000)
            .compactMap { line -> String? in
                let cells = line.split(separator: separator, omittingEmptySubsequences: false)
                    .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " \"\t")) }
                return cells.max { $0.count < $1.count }
            }
            .filter { $0.count >= 8 }
            .joined(separator: "\n")
    }

    /// Enough HTML stripping for a Takeout page: script and style out, tags out, entities
    /// back, `<br>` and block ends as newlines.
    static func strippingHTML(_ raw: String) -> String {
        var text = raw
        for pattern in ["<script[^>]*>[\\s\\S]*?</script>", "<style[^>]*>[\\s\\S]*?</style>",
                        "<!--[\\s\\S]*?-->"] {
            text = text.replacingOccurrences(of: pattern, with: " ", options: .regularExpression)
        }
        text = text.replacingOccurrences(of: "<br[^>]*>", with: "\n", options: .regularExpression)
        text = text.replacingOccurrences(of: "</(p|div|li|tr|h[1-6])>", with: "\n",
                                         options: .regularExpression)
        text = text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        for (entity, character) in ["&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"",
                                    "&#39;": "'", "&apos;": "'", "&nbsp;": " "] {
            text = text.replacingOccurrences(of: entity, with: character)
        }
        return String(text.prefix(maxHarvestedCharacters))
    }

    // MARK: - Naming

    private static func content(for package: MemoryPackage) -> MemoryImportContent {
        let day = DateFormatter()
        day.dateStyle = .long
        return MemoryImportContent(
            package: package, text: "", origin: package.assistant.name,
            note: "This is a Next Notes memory file, saved on \(day.string(from: package.exportedAt)). "
                + "It holds \(package.memories.count) "
                + (package.memories.count == 1 ? "memory" : "memories") + ".")
    }

    /// What an imported fact says it came from when the person picked a file: the file's own
    /// name, which is what they will recognise a month later.
    private static func originName(_ url: URL) -> String {
        let name = url.deletingPathExtension().lastPathComponent
        return name.isEmpty ? "a file" : name
    }
}
