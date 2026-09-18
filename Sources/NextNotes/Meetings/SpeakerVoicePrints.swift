import Foundation

/// One diarized speaker's voice in one meeting: the duration-weighted mean of FluidAudio's
/// 256-float segment embeddings, unit length.
struct SpeakerVoicePrint: Codable, Equatable, Sendable {
    var meetingID: String
    /// The label diarization gave it, "Speaker 2" — before any rename.
    var label: String
    var vector: [Float]
    /// How much speech it was averaged over.
    var seconds: Double
}

/// `speakers.json` in a meeting folder: a voice print per diarized speaker.
///
/// What lets Phase D link an unnamed *Speaker 2* in one meeting to a named person in another,
/// offline. Written only while the knowledge graph is on — a voice print is the most personal
/// thing this app derives from a recording, and nothing reads it otherwise. It lives in the
/// meeting folder, so deleting the meeting deletes it, switching the graph off deletes them all,
/// and it never leaves the Mac.
struct MeetingVoicePrints: Codable, Equatable, Sendable {
    static let currentVersion = 1
    static let fileName = "speakers.json"
    /// Shorter than this, an embedding is a cough, not a voice.
    static let minimumSeconds: Double = 3

    struct Entry: Codable, Equatable, Sendable {
        var vector: [Float]
        var seconds: Double
    }

    var version = currentVersion
    var speakers: [String: Entry] = [:]

    func prints(meetingID: String) -> [SpeakerVoicePrint] {
        speakers.keys.sorted().compactMap { label in
            guard let entry = speakers[label], !entry.vector.isEmpty else { return nil }
            return SpeakerVoicePrint(meetingID: meetingID, label: label, vector: entry.vector, seconds: entry.seconds)
        }
    }

    /// The labels `MeetingDiarizer.assign` gives, each with its centroid. Runs without an
    /// embedding, or speakers heard for less than `minimumSeconds`, get none.
    static func centroids(of runs: [MeetingDiarizer.SpeakerRun]) -> MeetingVoicePrints {
        let labels = MeetingDiarizer.labelsByCluster(runs)
        var sums: [String: [Float]] = [:]
        var seconds: [String: Double] = [:]
        for run in runs where !run.embedding.isEmpty {
            guard let label = labels[run.speakerID] else { continue }
            let weight = Float(max(0, run.end - run.start))
            guard weight > 0 else { continue }
            var sum = sums[label] ?? [Float](repeating: 0, count: run.embedding.count)
            guard sum.count == run.embedding.count else { continue }
            for index in sum.indices { sum[index] += run.embedding[index] * weight }
            sums[label] = sum
            seconds[label, default: 0] += Double(weight)
        }
        var result = MeetingVoicePrints()
        for (label, sum) in sums where (seconds[label] ?? 0) >= minimumSeconds {
            let norm = sum.reduce(0) { $0 + $1 * $1 }.squareRoot()
            guard norm > 0, norm.isFinite else { continue }
            result.speakers[label] = Entry(vector: sum.map { $0 / norm }, seconds: seconds[label] ?? 0)
        }
        return result
    }

    static func read(directory: URL) -> MeetingVoicePrints? {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent(fileName)) else { return nil }
        return try? JSONDecoder().decode(MeetingVoicePrints.self, from: data)
    }

    static func remove(directory: URL) {
        try? FileManager.default.removeItem(at: directory.appendingPathComponent(fileName))
    }

    /// Every meeting folder's prints under `meetingsRoot`, when the knowledge graph is switched
    /// off: they were derived for the graph alone. Diarized speaker labels stay in transcripts.
    /// - Returns: how many files went.
    @discardableResult
    static func removeAll(meetingsRoot: URL) -> Int {
        let folders = (try? FileManager.default.contentsOfDirectory(
            at: meetingsRoot, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
        var removed = 0
        for folder in folders where FileManager.default.fileExists(atPath: folder.appendingPathComponent(fileName).path) {
            if (try? FileManager.default.removeItem(at: folder.appendingPathComponent(fileName))) != nil { removed += 1 }
        }
        return removed
    }

    /// Atomic: a full disk leaves the previous file whole.
    func write(directory: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(self).write(to: directory.appendingPathComponent(Self.fileName), options: .atomic)
    }
}
