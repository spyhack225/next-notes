import Foundation

/// The conversational frontend may do something itself only when it takes <2s,
/// is one call, reads or changes only the frontend's own state, and is low risk.
/// Everything else is a task (spawn_task). These are control schemas, not a
/// second external-tool registry. Future cheap reads use the canonical manifest.
enum FrontendToolContract {
    enum Name: String, Codable, Sendable, CaseIterable {
        case spawn = "spawn_task", status = "task_status", cancel = "cancel_task", approval = "respond_approval"
    }
    struct Property: Codable, Sendable, Equatable {
        let type: String
        let description: String
        var values: [String]? = nil
        enum CodingKeys: String, CodingKey { case type, description; case values = "enum" }
    }
    struct Parameters: Codable, Sendable, Equatable {
        let type = "object"
        let properties: [String: Property]
        let required: [String]
        let additionalProperties = false
    }
    struct Schema: Codable, Sendable, Equatable {
        let name: Name
        let description: String
        let parameters: Parameters
    }
    struct Arguments: Codable, Sendable, Equatable {
        var objective: String? = nil
        var task: Int? = nil
        var decision: String? = nil
        var change: String? = nil
    }
    static func schemas(approvalOffered: Bool) -> [Schema] {
        let task = Property(type: "integer", description: "The exact task number in the supplied current work status. Leave absent for all status or the newest running task.")
        var result = [
            Schema(name: .spawn, description: "Start external work and return its saved receipt immediately. The worker has no chat history: provide a faithful, complete, self-contained objective. Speak only one short acknowledgement after the receipt. Mail, calendar, files and writes are tasks.", parameters: .init(properties: ["objective": .init(type: "string", description: "The person's complete request with references resolved and every name, date, number and condition preserved.")], required: ["objective"])),
            Schema(name: .status, description: "Read progress or completion only from the supplied current task records, never conversation history. Do not start the work again.", parameters: .init(properties: ["task": task], required: [])),
            Schema(name: .cancel, description: "Request cancellation of the selected current task, or the newest running task. Do not speak first. Say stopping until the retained task actually returns.", parameters: .init(properties: ["task": task], required: []))
        ]
        if approvalOffered {
            result.append(Schema(name: .approval, description: "Answer only the exact current offered approval. Approve only on explicit yes; yes plus a change is denial plus a correction, never approval of the old action. The application checks the heard prompt, recipient, request and reviewed payload before continuing.", parameters: .init(properties: ["decision": .init(type: "string", description: "The person's explicit answer.", values: ["approve", "deny"]), "change": .init(type: "string", description: "The requested correction, only when they change the proposal.")], required: ["decision"])))
        }
        return result
    }
    /// The on-device route and a future tool-call transport use this same adapter.
    /// It owns neither authority nor task-number resolution; the Bridge does both.
    static func payload(_ name: Name, arguments: Arguments, acknowledgement: String? = nil) -> FrontendDecisionPayload? {
        let value = FrontendDecisionPayload(intent: name.rawValue, objective: arguments.objective,
            acknowledgement: acknowledgement, task: arguments.task, decision: arguments.decision, change: arguments.change)
        guard normalized(value) != nil else { return nil }
        return value
    }
    static func normalized(_ value: FrontendDecisionPayload) -> FrontendDecisionPayload? {
        guard let name = Name(rawValue: value.intent), value.taskNumber == nil,
              value.approval == nil, value.amendment == nil,
              value.task.map({ $0 > 0 }) != false else { return nil }
        switch name {
        case .spawn:
            guard let objective = value.objective, !objective.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  value.task == nil, value.decision == nil, value.change == nil else { return nil }
            return .init(intent: "spawn", objective: objective, acknowledgement: value.acknowledgement)
        case .status, .cancel:
            guard value.objective == nil, value.acknowledgement == nil, value.decision == nil, value.change == nil else { return nil }
            return .init(intent: name == .status ? "status" : "cancel", taskNumber: value.task)
        case .approval:
            guard value.objective == nil, value.acknowledgement == nil, value.task == nil,
                  let decision = value.decision, ["approve", "deny"].contains(decision),
                  value.change.map({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) != false else { return nil }
            return .init(intent: "approval", approval: value.change == nil ? decision : "deny", amendment: value.change)
        }
    }
    /// A closed control argument boundary. Legacy envelopes retain their original
    /// decoder; tool controls cannot silently ignore an extra effect argument.
    private struct CheckedPayload: Decodable {
        let value: FrontendDecisionPayload
        private struct Key: CodingKey {
            let stringValue: String
            let intValue: Int? = nil
            init?(stringValue: String) { self.stringValue = stringValue }
            init?(intValue: Int) { return nil }
        }
        init(from decoder: Decoder) throws {
            let decoded = try FrontendDecisionPayload(from: decoder)
            let container = try decoder.container(keyedBy: Key.self)
            let allowed: Set<String>
            switch Name(rawValue: decoded.intent) {
            case .spawn: allowed = ["intent", "objective", "acknowledgement"]
            case .status, .cancel: allowed = ["intent", "task"]
            case .approval: allowed = ["intent", "decision", "change"]
            case nil: throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Unknown frontend control"))
            }
            guard Set(container.allKeys.map(\.stringValue)).isSubset(of: allowed),
                  let value = normalized(decoded) else {
                throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Invalid frontend control arguments"))
            }
            self.value = value
        }
    }
    static func decode(_ data: Data) -> FrontendDecisionPayload? {
        (try? JSONDecoder().decode(CheckedPayload.self, from: data))?.value
    }
    static func prompt(approvalOffered: Bool) -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(schemas(approvalOffered: approvalOffered)) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }
}

// A future transport decodes the SAME value rather than passing [String:Any].
// Unknown argument keys are refused here as well as at the streamed boundary.
extension FrontendToolContract.Arguments {
    private enum Keys: String, CodingKey { case objective, task, decision, change }
    private struct AnyKey: CodingKey {
        let stringValue: String
        let intValue: Int? = nil
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }
    init(from decoder: Decoder) throws {
        let keys = try decoder.container(keyedBy: AnyKey.self)
        guard Set(keys.allKeys.map(\.stringValue)).isSubset(of: ["objective", "task", "decision", "change"]) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Unknown frontend control argument"))
        }
        let values = try decoder.container(keyedBy: Keys.self)
        objective = try values.decodeIfPresent(String.self, forKey: .objective)
        task = try values.decodeIfPresent(Int.self, forKey: .task)
        decision = try values.decodeIfPresent(String.self, forKey: .decision)
        change = try values.decodeIfPresent(String.self, forKey: .change)
    }
}
