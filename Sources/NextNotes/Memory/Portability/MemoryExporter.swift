import Foundation

/// "Download your assistant's memory": one folder holding the whole assistant.
///
/// A folder rather than a zip, deliberately. A zip needs a compressor or a shell out to
/// `ditto`, and the thing it buys — one icon instead of two files — is not worth a failure
/// mode on a machine with an unusual `PATH`. A folder is readable in the Finder, the
/// Markdown opens in any editor, and the JSON is the part Next Notes reads back.
///
/// Nothing here touches the network. The export is written where the save panel pointed and
/// nowhere else.
@MainActor
enum MemoryExporter {
    /// What the exporter wrote, for the sentence shown afterwards.
    struct Result: Sendable {
        let folder: URL
        let memoryCount: Int
        let routineCount: Int
    }

    /// The default folder name in the save panel: "Next Notes — Ada's memory 2026-09-19".
    static func suggestedName(assistant: String, date: Date = Date()) -> String {
        let day = DateFormatter()
        day.dateFormat = "yyyy-MM-dd"
        let owner = assistant.trimmingCharacters(in: .whitespacesAndNewlines)
        let safe = (owner.isEmpty ? AgentIdentityStore.defaultName : owner)
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        return "\(safe) memory \(day.string(from: date))"
    }

    /// Builds the package from the live stores. Pure read: nothing is changed by exporting.
    static func package(
        memory: NextMemory = .shared,
        identity: AgentIdentityStore = .shared,
        persona: PersonaStore = .shared,
        includeRoutines: Bool,
        routines: [AgentSchedule]? = nil,
        date: Date = Date()
    ) -> MemoryPackage {
        let included: [MemoryPackage.Routine]? = includeRoutines
            ? (routines ?? ScheduleStore.shared.schedules).map {
                MemoryPackage.Routine(title: $0.title, prompt: $0.prompt,
                                      schedule: $0.plainEnglish, isEnabled: $0.enabled)
            }
            : nil
        return MemoryPackage(
            exportedAt: date,
            assistant: MemoryPackage.Assistant(
                name: identity.name, avatar: identity.avatar, soul: persona.text()),
            memories: memory.packageMemories,
            activity: memory.packageActivity,
            routines: included
        )
    }

    /// Writes `memory.json` and `Memory.md` into a new folder at `folder`.
    ///
    /// Written into a temporary folder first and moved into place, so an interrupted export
    /// never leaves half a package where the person pointed the panel.
    @discardableResult
    static func write(_ package: MemoryPackage, to folder: URL) throws -> Result {
        let manager = FileManager.default
        let staging = manager.temporaryDirectory
            .appendingPathComponent("NextNotesExport-\(UUID().uuidString)", isDirectory: true)
        try manager.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: staging) }

        try package.jsonData().write(to: staging.appendingPathComponent(MemoryPackage.jsonFileName),
                                     options: .atomic)
        try Data(package.markdown().utf8)
            .write(to: staging.appendingPathComponent(MemoryPackage.markdownFileName), options: .atomic)

        // The save panel has already asked about replacing, so an existing folder here is a
        // folder the person chose to overwrite.
        if manager.fileExists(atPath: folder.path) {
            try manager.removeItem(at: folder)
        }
        try manager.createDirectory(at: folder.deletingLastPathComponent(),
                                    withIntermediateDirectories: true)
        try manager.moveItem(at: staging, to: folder)
        return Result(folder: folder, memoryCount: package.memories.count,
                      routineCount: package.routines?.count ?? 0)
    }

    /// Build and write in one step.
    @discardableResult
    static func export(to folder: URL, includeRoutines: Bool, date: Date = Date()) throws -> Result {
        try write(package(includeRoutines: includeRoutines, date: date), to: folder)
    }
}
