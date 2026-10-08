import Foundation
@main struct UnicodeCheck {
    static func main() {
        print("UNICODE_ACTUAL_RULES_BEGIN")
        fflush(stdout)
        var failures = RuleBasedFormatter.selfTestFailures()
        for (raw, expected) in [("ßeta", "SSeta."), ("ﬃle", "FFIle."), ("one. ßeta", "One. SSeta.")] {
            if RuleBasedFormatter().apply(raw) != expected { failures.append(raw) }
            if RuleBasedFormatter().apply(raw, isFinal: false) != String(expected.dropLast()) { failures.append("partial " + raw) }
        }
        print(failures.isEmpty ? "UNICODE_OK" : "UNICODE_FAILED: \(failures)")
    }
}
