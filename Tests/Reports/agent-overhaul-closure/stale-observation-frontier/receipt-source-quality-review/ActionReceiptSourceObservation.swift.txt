import Foundation

/// Historical load snapshot quality; never a completeness or current-file guarantee.
enum ActionReceiptLoadQuality: String, Sendable {
    case harnessMemoryOnly, harnessRefused, missing, readable, partial, unreadable
}

/// LAST fingerprint comparison already performed by write admission, not a new probe.
enum ActionReceiptWriteSourceCheck: String, Sendable {
    case notObserved, matched, mismatch, unavailable
}

/// Metadata only. Missing receipts never prove that no action occurred: record caps
/// retained rows at500, while a load can retain more; neither is complete effect history.
struct ActionReceiptSourceObservation: Equatable, Sendable {
    let loadQuality: ActionReceiptLoadQuality
    let loadedRowCount: Int
    let unreadableRowCount: Int?
    var lastWriteSourceCheck: ActionReceiptWriteSourceCheck = .notObserved
}
