import AppKit
import CryptoKit
import SwiftUI

/// Immutable placeholder input for a visual capture, never a saved onboarding flow.
/// The environment accessor refuses this input outside the isolated self-test process.
struct OnboardingVisualFixture: Sendable {
    let step: OnboardingStep
    let hasPermissions: Bool

    var index: Int { OnboardingFlow.order.firstIndex(of: step) ?? 0 }
    var folders: [URL] {
        ["Desktop", "Documents", "Downloads"].map {
            URL(fileURLWithPath: "/Example/\($0)", isDirectory: true)
        }
    }
    var outcome: OnboardingOutcome {
        OnboardingOutcome(
            hasMicrophone: hasPermissions,
            hasAccessibility: hasPermissions,
            hasCalendar: hasPermissions,
            assistantName: "Next",
            holdKeyName: "Fn",
            handsFreeName: nil
        )
    }
}

private struct OnboardingVisualFixtureKey: EnvironmentKey {
    static let defaultValue: OnboardingVisualFixture? = nil
}

extension EnvironmentValues {
    var onboardingVisualFixture: OnboardingVisualFixture? {
        get { SelfTest.isRunning ? self[OnboardingVisualFixtureKey.self] : nil }
        set { self[OnboardingVisualFixtureKey.self] = newValue }
    }
}

/// Offscreen native-shell capture of all seven actual production step views. No click,
/// task, permission request, focus acquisition, model download, hotkey or audio action.
/// The explicit fixture seam in OnboardingWindow/Steps suppresses runtime effects.
/// OK means PNG output and unchanged watched owner stores, not interaction sign-off.
@MainActor
enum OnboardingSheet {
    static func write(to directory: String, controller: DictationController) -> Bool {
        guard SelfTest.isRunning else {
            SelfTest.diagnostic("ONBOARDING_SHEET_FAILED: isolated self-test harness required")
            return false
        }
        guard !controller.state.isActive, !controller.isCapturingAudio else {
            SelfTest.diagnostic("ONBOARDING_SHEET_FAILED: use an idle isolated controller")
            return false
        }
        let root = URL(fileURLWithPath: directory, isDirectory: true)
            .standardizedFileURL.resolvingSymlinksInPath()
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .standardizedFileURL.resolvingSymlinksInPath()
        guard root.path != support.path, !root.path.hasPrefix(support.path + "/") else {
            SelfTest.diagnostic("ONBOARDING_SHEET_FAILED: output must be outside Application Support")
            return false
        }
        guard verifyDurablePreferenceGuard() else {
            SelfTest.diagnostic("ONBOARDING_SHEET_FAILED: durable preference guard regression")
            return false
        }
        let before = SelfTestStoreGuard.take()
        // The shared guard does not watch onboarding/file-index preference keys.
        // Capture preferences without printing their values; retain the folder file too.
        let mergedBefore = UserDefaults.standard.dictionaryRepresentation()
        let foldersURL = AppIdentity.applicationSupportDirectory.appendingPathComponent(IndexedFoldersStore.fileName)
        let foldersBefore = try? Data(contentsOf: foldersURL)
        let foldersPresentBefore = FileManager.default.fileExists(atPath: foldersURL.path)
        // Retain the original merged-default trace and its unchanged baseline.
        // Owner preference writes are checked in complete persistent domains below;
        // framework registration is volatile process state, not a durable owner store.
        // Only key names, types and file hashes print.
        let domainsBefore = preferenceDomains()
        var reportedFirstChange = false
        var reportedDomainChange = false
        func traceCheckpoint(_ stage: String) {
            let storesAfter = SelfTestStoreGuard.take()
            let mergedAfter = UserDefaults.standard.dictionaryRepresentation()
            let foldersAfter = try? Data(contentsOf: foldersURL)
            let domainsAfter = preferenceDomains()
            // The shared diff can include a newly stored value. This diagnostic
            // emits only names so no owner preference contents enter its log.
            let guardChanges = Set(before.files.keys).union(storesAfter.files.keys).sorted()
                .filter { before.files[$0] != storesAfter.files[$0] }.map { "file=\($0) changed" }
                + Set(before.defaults.keys).union(storesAfter.defaults.keys).sorted()
                .filter { before.defaults[$0] != storesAfter.defaults[$0] }.map { "defaultKey=\($0) changed" }
            let mergedChanges = preferenceChanges(
                mergedBefore, mergedAfter
            )
            let changedDomains = Set(domainsBefore.keys).union(domainsAfter.keys).sorted().filter {
                !NSDictionary(dictionary: domainsBefore[$0] ?? [:])
                    .isEqual(to: domainsAfter[$0] ?? [:])
            }
            let originalGuardChanged = !guardChanges.isEmpty || !mergedChanges.isEmpty
                || foldersBefore != foldersAfter
            let firstGuardChange = originalGuardChanged && !reportedFirstChange
            let firstDomainChange = !changedDomains.isEmpty && !reportedDomainChange
            SelfTest.diagnostic("ONBOARDING_SHEET_TRACE: stage=\(stage) originalGuardChanged=\(!guardChanges.isEmpty || !mergedChanges.isEmpty || foldersBefore != foldersAfter) preferenceDomainChanges=\(changedDomains.count)")
            guard firstGuardChange || firstDomainChange else { return }
            if firstGuardChange {
                reportedFirstChange = true
                SelfTest.diagnostic("ONBOARDING_SHEET_FIRST_GUARD_CHANGE: stage=\(stage)")
            }
            if firstDomainChange {
                reportedDomainChange = true
                SelfTest.diagnostic("ONBOARDING_SHEET_FIRST_DOMAIN_CHANGE: stage=\(stage)")
            }
            for change in guardChanges {
                SelfTest.diagnostic("ONBOARDING_SHEET_GUARD_DIFF: \(change)")
            }
            for change in mergedChanges {
                SelfTest.diagnostic("ONBOARDING_SHEET_DEFAULTS_DIFF: domain=merged \(change)")
            }
            for domain in changedDomains {
                for change in preferenceChanges(domainsBefore[domain] ?? [:], domainsAfter[domain] ?? [:]) {
                    SelfTest.diagnostic("ONBOARDING_SHEET_DEFAULTS_DIFF: domain=\(domain) \(change)")
                }
            }
            SelfTest.diagnostic("ONBOARDING_SHEET_FOLDER_DIFF: before=\(fileIdentity(foldersBefore, isPresent: foldersPresentBefore)) after=\(fileIdentity(foldersAfter, isPresent: FileManager.default.fileExists(atPath: foldersURL.path)))")
        }
        func storesUnchanged() -> Bool {
            before == SelfTestStoreGuard.take()
                && durablePreferencesEqual(domainsBefore, preferenceDomains())
                && foldersBefore == (try? Data(contentsOf: foldersURL))
                && foldersPresentBefore == FileManager.default.fileExists(atPath: foldersURL.path)
        }
        do {
            traceCheckpoint("before-output-directory")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            traceCheckpoint("after-output-directory")
            var count = 0
            // Keep the accessibility axes independent: a combined reduced capture
            // cannot identify which compositor or animation branch differs.
            let variants: [(name: String, reduceMotion: Bool, reduceTransparency: Bool)] = [
                ("standard", false, false),
                ("reduce-motion", true, false),
                ("reduce-transparency", false, true),
                ("reduced", true, true)
            ]
            for hasPermissions in [false, true] {
                for variant in variants {
                    for step in OnboardingFlow.order {
                        let capture = "\(step.rawValue)-\(hasPermissions ? "allowed" : "not-allowed")-\(variant.name)"
                        traceCheckpoint("\(capture)/before-view")
                        let fixture = OnboardingVisualFixture(step: step, hasPermissions: hasPermissions)
                        // This is the actual production full shell and its actual step switch.
                        // The explicit fixture disables runtime side effects, not its layout.
                        let view = OnboardingFlowView(controller: controller, close: {})
                            .environment(\.onboardingVisualFixture, fixture)
                            .allowsHitTesting(false)
                            .environment(\.colorScheme, .light)
                            .environment(\._accessibilityReduceMotion, variant.reduceMotion)
                            .environment(\._accessibilityReduceTransparency, variant.reduceTransparency)
                        traceCheckpoint("\(capture)/after-view-value")
                        guard let image = render(view, trace: { traceCheckpoint("\(capture)/\($0)") }) else {
                            throw SheetError.render(step.rawValue)
                        }
                        let name = "onboarding-\(step.rawValue)-\(hasPermissions ? "allowed" : "not-allowed")-\(variant.name).png"
                        try image.write(to: root.appendingPathComponent(name))
                        SelfTest.diagnostic("ONBOARDING_SHEET_IMAGE: \(name) reduceMotion=\(variant.reduceMotion) reduceTransparency=\(variant.reduceTransparency)")
                        count += 1
                        traceCheckpoint("\(capture)/after-png-write")
                    }
                }
            }
            traceCheckpoint("final-store-check")
            guard storesUnchanged() else {
                SelfTest.diagnostic("ONBOARDING_SHEET_FAILED: owner stores changed")
                return false
            }
            SelfTest.diagnostic("ONBOARDING_SHEET_OK: \(count) full setup shell images generated; visual acceptance unverified; \(root.path)")
            return true
        } catch {
            traceCheckpoint("failed-render-store-check")
            guard storesUnchanged() else {
                SelfTest.diagnostic("ONBOARDING_SHEET_FAILED: owner stores changed during failed render")
                return false
            }
            SelfTest.diagnostic("ONBOARDING_SHEET_FAILED: \(error.localizedDescription)")
            return false
        }
    }

    /// Compare complete owner domains, rather than the merged search list whose
    /// process-local registration defaults can appear during native window creation.
    private static func durablePreferencesEqual(
        _ before: [String: [String: Any]], _ after: [String: [String: Any]]
    ) -> Bool {
        let names = Set(before.keys).union(after.keys).filter { $0.hasPrefix("persistent:") }
        return names.allSatisfy { name in
            guard let left = before[name], let right = after[name] else { return false }
            return NSDictionary(dictionary: left).isEqual(to: right)
        }
    }

    /// Exercise the actual comparator with a real write in the existing isolated
    /// harness domain. The owner app/global domains are never written for this check.
    private static func verifyDurablePreferenceGuard() -> Bool {
        let defaults = SelfTestHarnessDefaults.suite
        let name = SelfTestHarnessDefaults.suiteName
        guard name != AppIdentity.bundleIdentifier,
              name != Bundle.main.bundleIdentifier,
              name != UserDefaults.globalDomain else { return false }
        let original = defaults.persistentDomain(forName: name)
        defer {
            if let original { defaults.setPersistentDomain(original, forName: name) }
            else { defaults.removePersistentDomain(forName: name) }
        }
        let snapshotKey = "persistent:" + name
        let key = "onboardingGuardProbe." + UUID().uuidString
        let before = [snapshotKey: defaults.persistentDomain(forName: name) ?? [:]]
        defaults.set(true, forKey: key)
        let after = [snapshotKey: defaults.persistentDomain(forName: name) ?? [:]]
        guard after[snapshotKey]?[key] as? Bool == true,
              !durablePreferencesEqual(before, after),
              durablePreferencesEqual(before, before) else { return false }
        var registrationOnly = before
        registrationOnly["registration"] = ["fixtureProcessDefault": true]
        guard durablePreferencesEqual(before, registrationOnly) else { return false }
        SelfTest.diagnostic("ONBOARDING_SHEET_GUARD_OK: new isolated persistent key rejected; volatile registration distinguished")
        return true
    }

    private static func preferenceDomains() -> [String: [String: Any]] {
        let defaults = UserDefaults.standard
        // These are the persistent domains behind the owner's standard defaults.
        // Enumerating every persistent domain is unavailable in the current SDK.
        var names = Set([UserDefaults.globalDomain])
        if let name = Bundle.main.bundleIdentifier { names.insert(name) }
        var result: [String: [String: Any]] = [:]
        for name in names.sorted() {
            // The label distinguishes persistent storage from the merged search list.
            result["persistent:" + name] = defaults.persistentDomain(forName: name) ?? [:]
        }
        result["registration"] = defaults.volatileDomain(forName: UserDefaults.registrationDomain)
        result["argument"] = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
        return result
    }

    private static func preferenceChanges(_ before: [String: Any], _ after: [String: Any]) -> [String] {
        Set(before.keys).union(after.keys).sorted().compactMap { key in
            let left = before[key]
            let right = after[key]
            let equal = NSDictionary(dictionary: left.map { [key: $0] } ?? [:])
                .isEqual(to: right.map { [key: $0] } ?? [:])
            guard !equal else { return nil }
            let leftType = left.map { String(reflecting: type(of: $0)) } ?? "absent"
            let rightType = right.map { String(reflecting: type(of: $0)) } ?? "absent"
            return "key=\(key) beforeType=\(leftType) afterType=\(rightType)"
        }
    }

    private static func fileIdentity(_ data: Data?, isPresent: Bool) -> String {
        guard let data else { return isPresent ? "present-unreadable" : "absent" }
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return "present bytes=\(data.count) sha256=\(hash)"
    }

    private enum SheetError: LocalizedError {
        case render(String)
        var errorDescription: String? {
            switch self { case .render(let step): "Could not render \(step)." }
        }
    }

    private static func render(_ view: some View, trace: (String) -> Void) -> Data? {
        // Match OnboardingWindowController's style, content rect and titlebar geometry.
        // Never order the native window on screen or activate it.
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: DS.Onboarding.window),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        defer {
            window.close()
            trace("after-native-close")
        }
        window.title = "Welcome to Next Notes"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.appearance = NSAppearance(named: .aqua)
        trace("after-native-window")
        let hosting = NSHostingView(rootView: view)
        trace("after-host-construction")
        window.contentView = hosting
        trace("after-content-install")
        window.setContentSize(DS.Onboarding.window)
        window.layoutIfNeeded()
        hosting.layoutSubtreeIfNeeded()
        trace("after-host-layout")
        // Include the native titlebar/close-button strip, not just the content leaf.
        guard let shell = window.contentView?.superview else { return nil }
        shell.layoutSubtreeIfNeeded()
        trace("after-shell-layout")
        guard let representation = shell.bitmapImageRepForCachingDisplay(in: shell.bounds) else { return nil }
        shell.cacheDisplay(in: shell.bounds, to: representation)
        trace("after-shell-cache-display")
        return representation.representation(using: .png, properties: [:])
    }
}
