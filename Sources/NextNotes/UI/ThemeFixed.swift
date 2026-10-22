import AppKit
import CoreText
import SwiftUI

/// Fixed-light appearance forcing for the site theme (UX-11).
///
/// The theme is set by the app, never inherited from the Mac: one call pins every
/// surface — main window, island, HUD, onboarding, Settings, sheets and file
/// pickers unless they override it themselves — to light Aqua. Dark mode and the
/// user's accent colour stop applying in-app (owner decision 2026-10-01).
///
/// This file also registers the bundled theme fonts (`Resources/ThemeFonts`,
/// populated by the Makefile resource-copy stanza owned by the UI root). Fonts are
/// app-local (`.process` scope), never installed in the user's Fonts folder.
/// Registration runs once at launch on the main thread — synchronous, ~344 KB, never
/// on a conversational or voice path. A missing bundle, a bare self-test binary, or
/// a failed file degrades to system type with the failure recorded, never a pass.
///
/// Thread contract: launch-thread only. The registration state below is plain static
/// storage (no lock, no actor) because exactly one call site writes it before any
/// window appears and every other reader only reads. Do not call `registerThemeFonts`
/// from anywhere else.
///
/// Registration (for the serial build — this file must NOT wire itself up beyond
/// `apply()`): `ThemeFixed.apply()` is already called at the top of
/// `AppDelegate.applicationDidFinishLaunching`. Root-host tint callers belong to the
/// UI root and read `ThemeFixed.controlTint`.
enum ThemeFixed {
    @MainActor static func apply() {
        NSApp.appearance = NSAppearance(named: .aqua)
        registerThemeFonts()
    }

    /// Fixed control tint for root hosts (the theme's control ink). UI-root-owned
    /// callers apply `.tint(ThemeFixed.controlTint)` at each SwiftUI root/host.
    /// Native AppKit-owned menu/file-picker highlights may resist it — that is
    /// tested explicitly, never claimed here.
    static var controlTint: SwiftUI.Color { DS.Color.accent }

    /// PostScript names that registered AND resolved to that exact identity this
    /// launch (see `registerThemeFonts`). Read by `DS.Theme.Typography` (real face
    /// vs system fallback) and by the root isolated check. Empty with failures
    /// recorded means absent, never a pass.
    ///
    /// `nonisolated(unsafe)` by contract, not by oversight: exactly one call site
    /// (`apply()`, launch thread, before any window) ever writes, and every other
    /// reader only reads. No lock, no actor hop, no second writer — the smallest
    /// sound seam for launch-only state. Do not write from anywhere else.
    nonisolated(unsafe) static private(set) var registeredPostScriptNames: Set<String> = []
    /// One line per font file that was missing, failed, or registered without its
    /// exact PostScript identity resolving. Empty means nothing failed.
    nonisolated(unsafe) static private(set) var fontFailures: [String] = []
    /// True once `registerThemeFonts` has run. `apply()` is re-entered by diagnostics
    /// (ExperienceSheet calls it per render), so registration is once-only: later
    /// calls keep the first outcome instead of re-registering and re-recording.
    nonisolated(unsafe) static private var didAttemptFontRegistration = false

    /// Exact registration status for the root isolated check. Sorted, deterministic.
    static func fontStatus() -> (registered: [String], failures: [String]) {
        (registeredPostScriptNames.sorted(), fontFailures.sorted())
    }

    /// Registers the six bundled TTFs. Writes `registeredPostScriptNames` and
    /// `fontFailures` only; throws nothing, invents nothing. Once-only: repeat
    /// calls (diagnostic re-entry) keep the first outcome.
    ///
    /// `@MainActor` enforces the launch-single-writer contract at compile time:
    /// the only caller is `apply()` on the main thread, and no hop, lock, or
    /// preference is involved. Storage stays `nonisolated(unsafe)` so lock-free
    /// readers (`Typography`, the root check) need no extra hop either.
    ///
    /// A name is claimed ONLY when a `CTFont` created for it resolves back to
    /// that exact PostScript identity. Registration acceptance alone never claims:
    /// a benign re-registration and a broken file both pass through the verifier,
    /// and only a resolved identity lands in `registeredPostScriptNames`.
    @MainActor
    static func registerThemeFonts() {
        guard !didAttemptFontRegistration else { return }
        didAttemptFontRegistration = true
        registeredPostScriptNames = []
        fontFailures = []
        for name in DS.Theme.Typography.FontResources.bundledPostScriptNames {
            guard let url = Bundle.main.url(
                forResource: name, withExtension: "ttf",
                subdirectory: DS.Theme.Typography.FontResources.subdirectory)
            else {
                fontFailures.append("missing \(DS.Theme.Typography.FontResources.subdirectory)/\(name).ttf")
                continue
            }
            var error: Unmanaged<CFError>?
            let accepted = CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error)
            if !accepted, let error = error?.takeRetainedValue() {
                let ns = error as NSError
                let alreadyRegistered =
                    ns.domain == (kCTFontManagerErrorDomain as String)
                    && ns.code == CTFontManagerError.alreadyRegistered.rawValue
                if !alreadyRegistered {
                    fontFailures.append("\(name).ttf: \(ns.localizedDescription)")
                    continue
                }
            }
            let probe = CTFontCreateWithName(name as CFString, 12, nil)
            if (CTFontCopyPostScriptName(probe) as String) == name {
                registeredPostScriptNames.insert(name)
            } else {
                fontFailures.append("\(name).ttf: registered but PostScript identity unresolved")
            }
        }
    }
}
