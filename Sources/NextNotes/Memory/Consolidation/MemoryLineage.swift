import Foundation

/// Where a checked memory came from. Source utterances and tool output stay in the
/// ephemeral `MemoryProvenance` gate; this historical descriptor grants no authority.
struct MemoryProvenanceRecord: Codable, Sendable, Equatable {
    var source: MemoryProvenance.Origin
    var trustedSource: MemoryProvenance.TrustedSource
    var sourceLabel: String?
    var occurredAt: Date
    var sessionID: UUID?
    var confidence: Double?
    /// The replaced memory, when this descriptor belongs to a correction.
    var entryID: UUID?

    init(source: MemoryProvenance.Origin, trustedSource: MemoryProvenance.TrustedSource,
         sourceLabel: String? = nil, occurredAt: Date, sessionID: UUID? = nil,
         confidence: Double? = nil, entryID: UUID? = nil) {
        self.source = source
        self.trustedSource = trustedSource
        self.sourceLabel = sourceLabel
        self.occurredAt = occurredAt
        self.sessionID = sessionID
        self.confidence = confidence
        self.entryID = entryID
    }

    private enum CodingKeys: String, CodingKey {
        case source, trustedSource, sourceLabel, occurredAt, sessionID, confidence, entryID
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        // Never turn an absent or unfamiliar channel into "the user said it".
        source = try values.decode(MemoryProvenance.Origin.self, forKey: .source)
        trustedSource = try values.decode(MemoryProvenance.TrustedSource.self, forKey: .trustedSource)
        occurredAt = try values.decode(Date.self, forKey: .occurredAt)
        guard occurredAt.timeIntervalSinceReferenceDate.isFinite else {
            throw DecodingError.dataCorruptedError(forKey: .occurredAt, in: values,
                                                   debugDescription: "Invalid provenance date")
        }
        sourceLabel = try values.decodeIfPresent(String.self, forKey: .sourceLabel)
        sessionID = try values.decodeIfPresent(UUID.self, forKey: .sessionID)
        confidence = try values.decodeIfPresent(Double.self, forKey: .confidence)
        if let confidence, !confidence.isFinite || !(0...1).contains(confidence) {
            throw DecodingError.dataCorruptedError(forKey: .confidence, in: values,
                                                   debugDescription: "Invalid provenance confidence")
        }
        entryID = try values.decodeIfPresent(UUID.self, forKey: .entryID)
    }
}

struct MemoryLineage: Codable, Sendable, Equatable {
    var records: [MemoryProvenanceRecord]
    /// Empty until a consolidation actually absorbs other entries.
    var consolidatedFrom: [UUID]
    /// Absent until a consolidation actually runs.
    var consolidationRunID: UUID?

    init(records: [MemoryProvenanceRecord], consolidatedFrom: [UUID] = [],
         consolidationRunID: UUID? = nil) {
        self.records = records
        self.consolidatedFrom = consolidatedFrom
        self.consolidationRunID = consolidationRunID
    }

    private enum CodingKeys: String, CodingKey { case records, consolidatedFrom, consolidationRunID }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        records = try values.decodeIfPresent([MemoryProvenanceRecord].self, forKey: .records) ?? []
        consolidatedFrom = try values.decodeIfPresent([UUID].self, forKey: .consolidatedFrom) ?? []
        consolidationRunID = try values.decodeIfPresent(UUID.self, forKey: .consolidationRunID)
    }
}
