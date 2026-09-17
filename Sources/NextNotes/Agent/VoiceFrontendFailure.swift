import Foundation

/// Failure classes for the local conversational control stream. These are kept
/// separate so an internal response-contract failure is never presented as an
/// ASR failure or as a request to rephrase correctly recognized speech.
enum VoiceFrontendFailureCode: String, Equatable, Sendable {
    case modelError
    case malformedEnvelope
    case emptyCompletion
    case incompleteCompletion
    case deadline
    case cancelled
    case inputUncertain
}

enum VoiceFrontendOutputShape: String, Equatable, Sendable {
    case empty
    case answer
    case answerPrefix
    case tools
    case capabilities
    case revise
    case cancel
    case controlPrefix
    case malformedTag
    case plainText

    static func classify(_ output: String) -> Self {
        let text = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return .empty }
        if text.hasPrefix("<answer/>") || text.hasPrefix("<answer>") { return .answer }
        if text.hasPrefix("<use_tools/>") { return .tools }
        if text == "<capabilities/>" { return .capabilities }
        if text.hasPrefix("<revise id=\"") { return .revise }
        if text.hasPrefix("<cancel id=\"") { return .cancel }
        if "<answer/>".hasPrefix(text) || "<answer>".hasPrefix(text) { return .answerPrefix }
        if "<use_tools/>".hasPrefix(text) { return .controlPrefix }
        if text.hasPrefix("<") || text.hasPrefix("{") { return .malformedTag }
        return .plainText
    }
}

struct VoiceFrontendFailure: Equatable, Sendable {
    let code: VoiceFrontendFailureCode
    let shape: VoiceFrontendOutputShape
    let outputLength: Int
    let errorCode: String?

    static func modelError(shape: String, length: Int, errorCode: String) -> Self {
        Self(code: .modelError, shape: VoiceFrontendOutputShape(rawValue: shape) ?? .plainText,
             outputLength: boundedLength(length), errorCode: boundedCode(errorCode))
    }

    static func malformedEnvelope(shape: String, length: Int) -> Self {
        Self(code: .malformedEnvelope, shape: VoiceFrontendOutputShape(rawValue: shape) ?? .malformedTag,
             outputLength: boundedLength(length), errorCode: nil)
    }

    static func emptyCompletion(shape: String, length: Int) -> Self {
        Self(code: .emptyCompletion, shape: VoiceFrontendOutputShape(rawValue: shape) ?? .empty,
             outputLength: boundedLength(length), errorCode: nil)
    }

    static func incompleteCompletion(shape: String, length: Int) -> Self {
        Self(code: .incompleteCompletion, shape: VoiceFrontendOutputShape(rawValue: shape) ?? .controlPrefix,
             outputLength: boundedLength(length), errorCode: nil)
    }

    static func deadline(shape: String, length: Int) -> Self {
        Self(code: .deadline, shape: VoiceFrontendOutputShape(rawValue: shape) ?? .empty,
             outputLength: boundedLength(length), errorCode: nil)
    }

    static func cancelled(shape: String = VoiceFrontendOutputShape.empty.rawValue, length: Int = 0) -> Self {
        Self(code: .cancelled, shape: VoiceFrontendOutputShape(rawValue: shape) ?? .empty,
             outputLength: boundedLength(length), errorCode: nil)
    }

    static func inputUncertain(shape: String, length: Int) -> Self {
        Self(code: .inputUncertain, shape: VoiceFrontendOutputShape(rawValue: shape) ?? .empty,
             outputLength: boundedLength(length), errorCode: nil)
    }

    var auditDetail: String {
        let error = errorCode.map { " error=\($0)" } ?? ""
        return "voice_frontend_failure code=\(code.rawValue) shape=\(shape.rawValue) length=\(outputLength)\(error)"
    }

    private static func boundedLength(_ length: Int) -> Int { min(max(length, 0), 4_096) }

    private static func boundedCode(_ code: String) -> String {
        let safe = code.unicodeScalars.filter { $0.value >= 0x20 && $0.value != 0x7F }
        return String(String.UnicodeScalarView(safe).prefix(64))
    }
}

enum VoiceFrontendStreamTermination: Equatable, Sendable {
    case completed
    case modelError(String)
    case cancelled
    case deadline
}

struct VoiceFrontendStreamResult: Equatable, Sendable {
    let snapshot: String
    let termination: VoiceFrontendStreamTermination
}

/// Keeps a bounded-wait diagnostic useful even after the generation task is
/// abandoned at its deadline. It stores only the generated response shape/size
/// at the call site; the snapshot itself is never persisted.
actor VoiceFrontendStreamProgress {
    private var snapshot = ""

    func update(_ snapshot: String) { self.snapshot = snapshot }

    func value() -> String { snapshot }
}

/// Converts a bounded stream result into a safe coordinator action. Tool and
/// correction controls are accepted only as complete envelopes; malformed
/// output is always a failure and can never reach an effect path.
enum VoiceFrontendResponseOutcome: Equatable, Sendable {
    case answer(String)
    case newWork
    case capabilities
    case revise(Int)
    case cancel(Int)
    case failure(VoiceFrontendFailure)

    static func resolve(snapshot: String, termination: VoiceFrontendStreamTermination) -> Self {
        let shape = VoiceFrontendOutputShape.classify(snapshot)
        let length = min(snapshot.count, 4_096)
        switch termination {
        case .cancelled:
            return .failure(.cancelled(shape: shape.rawValue, length: length))
        case .modelError(let code):
            return .failure(.modelError(shape: shape.rawValue, length: length, errorCode: code))
        case .deadline:
            return .failure(.deadline(shape: shape.rawValue, length: length))
        case .completed:
            break
        }

        if snapshot.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .failure(.emptyCompletion(shape: shape.rawValue, length: length))
        }
        let parsed = VoiceFrontendEnvelope.parse(snapshot)
        switch parsed {
        case .pending:
            return .failure(.incompleteCompletion(shape: shape.rawValue, length: length))
        case .invalid:
            return .failure(.malformedEnvelope(shape: shape.rawValue, length: length))
        case .answer(let answer):
            let trimmed = answer.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                return .failure(.emptyCompletion(shape: shape.rawValue, length: length))
            }
            return .answer(answer)
        case .newWork:
            guard snapshot.trimmingCharacters(in: .whitespacesAndNewlines) == "<use_tools/>" else {
                return .failure(.malformedEnvelope(shape: shape.rawValue, length: length))
            }
            return .newWork
        case .capabilities: return .capabilities
        case .revise(let index): return .revise(index)
        case .cancel(let index): return .cancel(index)
        }
    }
}
