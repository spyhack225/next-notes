import Foundation
import FoundationModels
import OSLog
import Darwin
// Only logging/output sinks are supplied. Native model, source plan validator,
// corroboration, rendering, corpus and assertions are the actual implementation.
enum Log { static let speech = Logger(subsystem: "dictation-layout-check", category: "fixture") }
enum SelfTest { static var outputPath: String? { nil } }
@main struct Check {
    static func main() async throws {
        let watchdog = Task {
            try? await Task.sleep(for: .seconds(150))
            if !Task.isCancelled { print("LAYOUT_NATIVE_TIMEOUT"); fflush(stdout); Darwin.exit(124) }
        }
        defer { watchdog.cancel() }
        let variant = CommandLine.arguments.contains("--typed")
        var failures = 0
        for test in CleanupEvalCases.planCases {
            let sentences = SpokenStructure.sentenceSplit(test.input)
            let session = LanguageModelSession(instructions: StructurePlanPrompt.system)
            let began = ContinuousClock.now
            let plan: StructurePlan
            do {
                if variant {
                    plan = try await session.respond(to: StructurePlanPrompt.user(sentences: sentences), generating: TypedDraft.self, options: .init(temperature: 0.1, maximumResponseTokens: 500)).content.plan
                } else {
                    plan = try await session.respond(to: StructurePlanPrompt.user(sentences: sentences), generating: StructurePlanDraft.self, options: .init(temperature: 0.1, maximumResponseTokens: 500)).content.plan
                }
                let reason = plan.rejection(sentenceCount: sentences.count) ?? plan.corroborationFailure(sentences: sentences)
                let rendered = reason == nil ? plan.rendered(sentences: sentences, target: CleanupEvalCases.target)?.text : nil
                let errors = CleanupEvalCases.planFailures(for: test, rendered: rendered ?? sentences.joined(separator: " "))
                failures += errors.count
                let d = ContinuousClock.now-began
                let row:[String:Any] = ["variant":variant ? "typed":"full", "case":test.id, "seconds":Double(d.components.seconds)+Double(d.components.attoseconds)/1e18, "rejection":reason as Any? ?? NSNull(), "assertions":errors, "plan":try JSONSerialization.jsonObject(with:JSONEncoder().encode(plan))]
                print(String(data:try JSONSerialization.data(withJSONObject:row,options:[.sortedKeys]),encoding:.utf8)!)
            } catch { failures += 1;print("ERROR \(test.id): \(error)") }
        }
        print("LAYOUT_NATIVE_RESULT failures=\(failures)")
    }
}
