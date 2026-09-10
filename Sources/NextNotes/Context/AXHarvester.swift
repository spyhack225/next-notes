import ApplicationServices
import Foundation

/// Reads the names visible in another app's window, once, on a clock.
///
/// This is `TextInjector`'s failure mode in the mirror. Writing to Electron gets `.success`
/// and does nothing; reading it gets either a stub with no children or a tree with thirty
/// thousand nodes in it, and no attribute distinguishes the two up front. So the walk is
/// budgeted rather than complete, and every exit is recorded in `ScreenContext.Truncation`
/// instead of being retried — a partial list of real names is the whole product here, and a
/// second attempt costs the user the start of their sentence.
///
/// `harvest` is deliberately synchronous and nonisolated. `AXUIElement` is not `Sendable`,
/// and the way to satisfy that honestly rather than with `@unchecked` is for no element to
/// exist outside this one call: elements are created, read and dropped inside it, and the
/// only thing that crosses an isolation boundary is the `ScreenContext` of strings it
/// returns. Call it from `Task.detached` — a plain `Task {}` started on the main actor
/// inherits the main actor and would spend the whole budget stalling the HUD.
enum AXHarvester {
    /// Every ceiling in one value so a caller can shrink them all for a self-test.
    struct Budget: Sendable, Hashable {
        /// Wall clock for the entire walk. 120 ms is the number the design is priced at: the
        /// user is holding a key and recording has already started, so this is free — but
        /// only while it stays this size.
        var deadline: Duration = .milliseconds(120)
        /// Per-AX-call ceiling, via `AXUIElementSetMessagingTimeout`. Without this the
        /// deadline above is decorative: one wedged Electron renderer blocks a single
        /// `AXUIElementCopyAttributeValue` for the process default — measured at about 1.5 s on
        /// this machine — and no amount of clock-checking between calls can interrupt it. It has
        /// to be applied to every element the walk touches, not once to the app; see the note at
        /// the call site.
        var perCallTimeout: Float = 0.025
        var maxNodes = 1_500
        var maxDepth = 12
        var maxCandidates = 200
        static let `default` = Budget()
    }

    /// Harvests the frontmost window of `processID`.
    ///
    /// - Parameters:
    ///   - bundleID: used for the adapter lookup and the deny list, not for finding the app.
    ///   - processID: `pid_t` rather than `NSRunningApplication` because that class is not
    ///     `Sendable` and this runs off the main actor. The caller reads the pid on the main
    ///     actor at key-down and passes the number.
    /// - Returns: always a value, never a throw. A denied app, a missing adapter, a stub tree
    ///   and a blown deadline are all "here is what I got, and here is what stopped me" — the
    ///   caller's job is to carry on with fewer names, never to handle an error.
    nonisolated static func harvest(
        bundleID: String,
        processID: pid_t,
        budget: Budget = .default
    ) -> ScreenContext {
        let clock = ContinuousClock()
        let started = clock.now

        func outcome(
            _ truncation: ScreenContext.Truncation,
            appName: String = "",
            candidates: [CandidateName] = [],
            projectRoot: String? = nil
        ) -> ScreenContext {
            ScreenContext(
                bundleID: bundleID,
                appName: appName,
                candidates: candidates,
                projectRoot: projectRoot,
                truncation: truncation,
                elapsed: clock.now - started
            )
        }

        guard !ContextPrivacyFilter.isDenied(bundleID: bundleID) else {
            return outcome(.denied)
        }
        guard let adapter = AXAppAdapters.adapter(for: bundleID) else {
            return outcome(.noAdapter)
        }
        // The same `.denied` for a refusal from the other direction: without the
        // Accessibility grant every call below returns nothing at all, and a harvest that
        // reported that as an empty tree would send whoever debugs it into VS Code's settings
        // instead of into System Settings.
        guard AXIsProcessTrusted() else {
            return outcome(.denied, appName: adapter.displayName)
        }

        let app = AXUIElementCreateApplication(processID)
        // The timeout has to be set on *every* element this walk sends a message to, and that
        // is the whole reason `boundedElements` sets it again on each child it hands back.
        // `AXUIElementSetMessagingTimeout` is documented as per-object — the system-wide
        // element is the only one whose timeout is global to the process — so an application
        // element's 25 ms covers the two `focusedWindow` reads below and nothing else.
        // Measured against a SIGSTOPped app: with the timeout on the app element alone, a read
        // of the app answered in 30 ms while a read of its window took 1504 ms, which is this
        // machine's process default. Since `isOutOfTime` is only consulted *between* calls, one
        // wedged renderer would then blow a 120 ms budget by ten seconds over the eight or so
        // attribute reads a single `visit` makes.
        //
        // Setting it per element is not the round trip the previous comment here claimed:
        // 10,000 calls measured at 0.10 ms in total, because it writes into the local element
        // reference rather than asking the app anything.
        AXUIElementSetMessagingTimeout(app, budget.perCallTimeout)

        guard let window = focusedWindow(of: app, timeout: budget.perCallTimeout) else {
            // No focused window with the grant in hand is the shape of an app that is
            // launching, or of a tree that is not there yet. Reported as a stub rather than
            // as nothing, because the remediation text is the useful answer either way.
            return outcome(.stubTree, appName: adapter.displayName)
        }

        var walker = Walker(adapter: adapter, budget: budget, clock: clock, deadline: started + budget.deadline)
        walker.walk(window)
        let candidates = walker.harvest()

        var truncation = walker.truncation
        // A stub tree has no single attribute to test for, so it is inferred from the shape
        // of what came back: an editor window that answered with a handful of nodes, or with
        // no names at all, is the "editor.accessibilitySupport" symptom rather than an empty
        // project. A false positive costs one hint in Settings; a false negative costs a
        // feature that silently does nothing, which is why the floor is set generously.
        if adapter.needsAccessibilitySupportSetting,
           walker.nodes < stubNodeFloor || candidates.isEmpty {
            truncation.insert(.stubTree)
        }

        return outcome(
            truncation,
            appName: adapter.displayName,
            candidates: candidates,
            projectRoot: walker.projectRoot
        )
    }

    /// Whether this app has a hand-tested adapter. False is the answer for almost everything,
    /// and it is the right answer: this feature is a short list of editors somebody actually
    /// verified, not a general capability.
    nonisolated static func supports(bundleID: String) -> Bool {
        !ContextPrivacyFilter.isDenied(bundleID: bundleID)
            && AXAppAdapters.adapter(for: bundleID) != nil
    }

    /// Below this many visited nodes an editor window is treated as a stub. Twelve would be
    /// enough for a window that really is empty; twenty-four is chosen because a VS Code
    /// window with accessibility support off still answers with its title bar and its window
    /// chrome, and those alone come to more than a dozen nodes.
    private static let stubNodeFloor = 24

    /// How many children of one element are ever asked for.
    ///
    /// This is the specific place the thirty-thousand-node tree arrives: a virtualized list
    /// that reports every row it *could* show, not the ones it is showing. The ranged copy
    /// below refuses the rest without having asked for it first, which a plain
    /// `kAXChildrenAttribute` read cannot do — by the time that call returns, the whole array
    /// has already been built and the budget is gone.
    private static let childLimit = 160

    /// How much of one element's text is scanned for file names. See `fileTokens(in:)`.
    private static let editorScanLimit = 2_000

    // MARK: - The walk

    /// One name found in the tree, plus the one thing about where it was found that the
    /// ranking cannot express: whether it came from a region the adapter table named.
    private struct Found {
        var candidate: CandidateName
        var insideNamedRegion: Bool
    }

    /// Which part of the window the walk is currently inside. Carried down rather than
    /// recomputed, because the element that says "this is the file tree" is a container eight
    /// levels above the row that holds the file name.
    private enum Zone {
        case chrome
        case tabs
        case sidebar
        case sidebarRow(isFolder: Bool)
        case breadcrumb
        case editor

        var isBreadcrumb: Bool {
            if case .breadcrumb = self { true } else { false }
        }
    }

    /// Roles that count as one item in a list of items, and so start a position counting.
    private static func isItemRole(_ role: String) -> Bool {
        role == kAXRowRole || role == kAXCellRole || role == kAXRadioButtonRole || role == "AXTab"
    }

    private struct Walker {
        let adapter: AXAppAdapter
        let budget: Budget
        let clock: ContinuousClock
        let deadline: ContinuousClock.Instant

        var truncation: ScreenContext.Truncation = []
        var nodes = 0
        var projectRoot: String?

        /// Keyed by lower-cased text so the same file name found as a tab and as a sidebar row
        /// is one candidate, keeping whichever sighting ranked better.
        private var found: [String: Found] = [:]
        private var perKind: [CandidateKind: Int] = [:]
        private var sawNamedRegion = false
        private var breadcrumbParts: [String] = []
        /// True once a breadcrumb strip has been entered, so a second one can be told apart
        /// from the first. See `flushBreadcrumb` for why only the first is used.
        private var sawBreadcrumbStrip = false
        private var breadcrumbClosed = false

        /// Spelled out because the synthesized memberwise initializer inherits the visibility
        /// of the private state above it, and `harvest` could not then create one.
        init(adapter: AXAppAdapter, budget: Budget, clock: ContinuousClock, deadline: ContinuousClock.Instant) {
            self.adapter = adapter
            self.budget = budget
            self.clock = clock
            self.deadline = deadline
        }

        mutating func walk(_ window: AXUIElement) {
            visit(window, depth: 0, siblingIndex: 0, position: 0, zone: .chrome, insideNamedRegion: false)
            flushBreadcrumb()
        }

        /// The candidates, after the one filter that cannot be applied as they are found.
        ///
        /// When the tree exposed the identifiers the adapter names, everything outside those
        /// regions is dropped — that is what the table is for, and it is how the status bar's
        /// "Prettier: ✓" stays out of the prompt. When it exposed none of them, the whole
        /// window is kept instead. That asymmetry is deliberate: AX identifiers in Electron
        /// come from DOM ids and the three forks do not agree on them release to release, so
        /// requiring one would make this feature depend on the least stable thing in the
        /// window. Degrading to a noisier list is survivable; degrading to nothing is not.
        func harvest() -> [CandidateName] {
            found.values
                .filter { !sawNamedRegion || $0.insideNamedRegion }
                .map(\.candidate)
        }

        private var isOutOfTime: Bool { clock.now >= deadline }

        /// - Parameter position: the rank position names found here are attributed to, which is
        ///   *not* this element's own index. A file name in a sidebar lives in a static text
        ///   inside a row inside the outline, and it is the row's position in the outline that
        ///   says how far down the list the user would have to look — the static text is
        ///   always child zero of its row, so using its own index would rank every row alike.
        private mutating func visit(
            _ element: AXUIElement,
            depth: Int,
            siblingIndex: Int,
            position: Int,
            zone: Zone,
            insideNamedRegion: Bool
        ) {
            if isOutOfTime { truncation.insert(.timeBudget); return }
            if nodes >= budget.maxNodes { truncation.insert(.nodeCap); return }
            if depth > min(budget.maxDepth, adapter.maxDepth) { truncation.insert(.depthCap); return }
            nodes += 1

            let role = string(element, kAXRoleAttribute) ?? ""
            let subrole = string(element, kAXSubroleAttribute)
            let identifier = string(element, kAXIdentifierAttribute)

            if let identifier, adapter.ignoredIdentifiers.contains(where: { identifier.contains($0) }) {
                return
            }
            guard ContextPrivacyFilter.allows(role: role, subrole: subrole, identifier: identifier) else {
                return
            }

            var insideNamedRegion = insideNamedRegion
            if let identifier,
               adapter.interestingIdentifiers.contains(where: { identifier.contains($0) }) {
                insideNamedRegion = true
                sawNamedRegion = true
            }

            let previousZone = zone
            let zone = refined(zone, role: role, identifier: identifier, element: element)
            // An item — a row, a tab — is where a position starts counting; everything below
            // it inherits that position rather than its own place among its siblings.
            let position = AXHarvester.isItemRole(role) ? siblingIndex : position

            if case .breadcrumb = zone, !previousZone.isBreadcrumb {
                if sawBreadcrumbStrip { breadcrumbClosed = true }
                sawBreadcrumbStrip = true
            }

            collect(from: element, role: role, zone: zone, position: position, insideNamedRegion: insideNamedRegion)

            for (index, child) in AXHarvester.children(of: element, timeout: budget.perCallTimeout).enumerated() {
                visit(
                    child,
                    depth: depth + 1,
                    siblingIndex: index,
                    position: position,
                    zone: zone,
                    insideNamedRegion: insideNamedRegion
                )
                if isOutOfTime { truncation.insert(.timeBudget); return }
                if nodes >= budget.maxNodes { truncation.insert(.nodeCap); return }
            }
        }

        /// Narrows the zone at a container. Identifier first because it is the reliable
        /// signal when it exists, role second because it is the only one when it does not.
        private func refined(
            _ zone: Zone,
            role: String,
            identifier: String?,
            element: AXUIElement
        ) -> Zone {
            if let identifier {
                let lowered = identifier.lowercased()
                if lowered.contains("breadcrumb") { return .breadcrumb }
                if lowered.contains("sidebar") || lowered.contains("explorer") { return .sidebar }
                if lowered.contains("tabs") || lowered.contains("tabscontainer") { return .tabs }
                if lowered.contains("editor") { return .editor }
            }

            switch role {
            case kAXTabGroupRole:
                return .tabs
            case kAXOutlineRole, kAXTableRole, kAXListRole:
                return .sidebar
            case kAXRowRole:
                // A row that can be expanded is a folder. This is the only reliable
                // file-versus-folder signal in the tree: the row's text is just a word, and
                // "src" and "src.ts" being different kinds of thing is not something the
                // string can be asked about.
                let disclosing = AXHarvester.flag(element, kAXDisclosingAttribute)
                return .sidebarRow(isFolder: disclosing != nil)
            default:
                return zone
            }
        }

        // MARK: Turning one element into names

        private mutating func collect(
            from element: AXUIElement,
            role: String,
            zone: Zone,
            position: Int,
            insideNamedRegion: Bool
        ) {
            if role == kAXWindowRole {
                collectWindow(element)
                return
            }

            switch zone {
            case .tabs:
                guard let name = label(of: element) else { return }
                let kind: CandidateKind = AXHarvester.isSelected(element) ? .activeTab : .inactiveTab
                add(name, path: nil, kind: kind, position: position, insideNamedRegion: insideNamedRegion)

            case .sidebarRow(let isFolder):
                guard let name = label(of: element) else { return }
                // A row with an extension is a file whatever the disclosure attribute says —
                // a collapsed folder and a file both answer the same way in some builds, and
                // "login.ts" is not a directory.
                let kind: CandidateKind = (isFolder && !CandidateName.hasFileExtension(name))
                    ? .sidebarFolder
                    : .sidebarFile
                add(name, path: nil, kind: kind, position: position, insideNamedRegion: insideNamedRegion)

            case .sidebar:
                guard let name = label(of: element) else { return }
                let kind: CandidateKind = CandidateName.hasFileExtension(name) ? .sidebarFile : .sidebarFolder
                add(name, path: nil, kind: kind, position: position, insideNamedRegion: insideNamedRegion)

            case .breadcrumb:
                guard !breadcrumbClosed, breadcrumbParts.count < 12, let name = label(of: element) else {
                    return
                }
                breadcrumbParts.append(name)

            case .editor:
                guard let text = label(of: element, allowingLongValues: true) else { return }
                // Only file-shaped tokens, never the prose. The privacy filter would let a
                // short line of source through, and it has no business in a prompt: what this
                // feature needs from the visible pane is the import line's "./auth/login",
                // not the line of code around it.
                for token in AXHarvester.fileTokens(in: text).prefix(4) {
                    add(token, path: nil, kind: .editorText, position: position, insideNamedRegion: insideNamedRegion)
                }

            case .chrome:
                return
            }
        }

        /// The window's own two gifts: its title, which usually carries the project name, and
        /// `AXDocument`, which is the one place in the tree that names the open file
        /// unambiguously.
        private mutating func collectWindow(_ window: AXUIElement) {
            let parts = string(window, kAXTitleAttribute).map(AXHarvester.titleComponents) ?? []
            // The project is the tail of "login.ts — myproject", which is how all three
            // editors title their windows. Taken from the title rather than from the open
            // file's path because the title is what the app decided to display, and a path we
            // walked up ourselves would be a filesystem claim this feature does not make.
            if parts.count >= 2 { projectRoot = parts.last }
            for (index, part) in parts.prefix(2).enumerated() {
                add(part, path: nil, kind: .windowTitle, position: index, insideNamedRegion: true)
            }

            guard let document = string(window, kAXDocumentAttribute),
                  let path = AXHarvester.filePath(fromDocument: document)
            else { return }
            let name = path.split(separator: "/").last.map(String.init) ?? path
            add(
                name,
                path: AXHarvester.relativePath(of: path, under: projectRoot),
                kind: .activeTab,
                position: 0,
                insideNamedRegion: true
            )
        }

        /// The displayed text of an element, refused if the privacy filter says so.
        ///
        /// Title before value because a tab's title is its file name while its value is
        /// whether it is selected. `allowingLongValues` exists for the editor pane, where the
        /// value is a run of source that gets tokenized rather than kept — everything else
        /// wants a name and a name is short.
        private func label(of element: AXUIElement, allowingLongValues: Bool = false) -> String? {
            let placeholder = string(element, kAXPlaceholderValueAttribute)
            for attribute in [kAXTitleAttribute, kAXValueAttribute, kAXDescriptionAttribute] {
                guard let text = string(element, attribute) else { continue }
                guard !ContextPrivacyFilter.isPlaceholder(value: text, placeholder: placeholder) else { continue }
                if allowingLongValues {
                    guard !text.isEmpty else { continue }
                    return text
                }
                guard ContextPrivacyFilter.allows(value: text) else { continue }
                return text
            }
            return nil
        }

        private mutating func add(
            _ text: String,
            path: String?,
            kind: CandidateKind,
            position: Int,
            insideNamedRegion: Bool
        ) {
            guard ContextPrivacyFilter.allows(value: text) else { return }

            // The position is clamped before it is added, because the gaps between kinds are
            // only ten wide: unclamped, a sidebar row thirty rows down would score worse than
            // a token scraped off the editor pane, and arithmetic would have silently
            // reordered the kinds this ranking exists to keep apart. Past the tenth row the
            // position has stopped carrying much anyway — a name that far down a virtualized
            // list is barely on screen.
            let candidate = CandidateName(
                text: text,
                path: path,
                kind: kind,
                rank: kind.baseRank + min(position, 9)
            )

            let key = text.lowercased()
            if let existing = found[key] {
                // The same name sighted twice — as a tab and again as a sidebar row — is one
                // file. Keep the better sighting, and let either sighting's named region vouch
                // for the other, because it is the region that decides whether this name is
                // part of the editor's own furniture or part of the project.
                //
                // The path is merged rather than travelling with the winner, and without that
                // the breadcrumb strip's whole purpose was unreachable. Rank alone always
                // decided this, `.breadcrumb` is rank 20 and above while `.activeTab` and
                // `.windowTitle` are 11 and below, and `flushBreadcrumb` runs after the walk —
                // so the active file's path arrived last, lost on rank, and every candidate came
                // out with `path: nil`. The prompt then listed a bare "login.ts" and
                // `PathReferenceStyle.atRelative` duly wrote `@login.ts` instead of
                // `@src/auth/login.ts`, for the one file the user is most likely to name.
                //
                // Safe because both sightings describe one file — that is the assumption this
                // whole branch already makes — and because `breadcrumbClosed` is what keeps a
                // split editor from ever offering a joined path that does not exist.
                let better = candidate.rank < existing.candidate.rank ? candidate : existing.candidate
                found[key] = Found(
                    candidate: CandidateName(
                        text: better.text,
                        path: better.path ?? candidate.path ?? existing.candidate.path,
                        kind: better.kind,
                        rank: better.rank
                    ),
                    insideNamedRegion: existing.insideNamedRegion || insideNamedRegion
                )
                return
            }

            // Both caps are checked only for a genuinely new name, so that re-sighting a name
            // already held can never be what reports the harvest as truncated.
            guard found.count < budget.maxCandidates else {
                truncation.insert(.candidateCap)
                return
            }
            guard perKind[kind, default: 0] < AXHarvester.candidateLimit(for: kind) else {
                truncation.insert(.candidateCap)
                return
            }

            found[key] = Found(candidate: candidate, insideNamedRegion: insideNamedRegion)
            perKind[kind, default: 0] += 1
        }

        /// Turns the collected breadcrumb strip into candidates, once, at the end of the walk.
        ///
        /// Deferred to the end because a path is the whole strip and the walk sees one
        /// component at a time. Only the first strip is used — `visit` stops collecting as
        /// soon as a second one is entered — because a split editor shows two, and joining
        /// them produces a path that does not exist. That is worse than the bare name this
        /// degrades to: a wrong path is one the receiving app will go and try to open.
        private mutating func flushBreadcrumb() {
            guard !breadcrumbParts.isEmpty else { return }

            var pathSoFar: [String] = []
            var passedTheFile = false
            for (index, part) in breadcrumbParts.enumerated() {
                if passedTheFile {
                    // Everything after the file component is a symbol inside it — VS Code's
                    // strip reads folder › folder › file.ts › ClassName › method — and a
                    // symbol name is worth having but is not a file.
                    add(part, path: nil, kind: .editorSymbol, position: index, insideNamedRegion: true)
                    continue
                }
                pathSoFar.append(part)
                let isFile = CandidateName.hasFileExtension(part)
                add(
                    part,
                    path: isFile ? pathSoFar.joined(separator: "/") : nil,
                    kind: .breadcrumb,
                    position: index,
                    insideNamedRegion: true
                )
                passedTheFile = isFile
            }
        }

        private func string(_ element: AXUIElement, _ attribute: String) -> String? {
            AXHarvester.string(element, attribute)
        }
    }

    // MARK: - Attribute reads

    private static func focusedWindow(of app: AXUIElement, timeout: Float) -> AXUIElement? {
        // Focused first, main second. They differ exactly when a sheet or a palette is up,
        // and the focused one is the window whose names the user is looking at.
        for attribute in [kAXFocusedWindowAttribute, kAXMainWindowAttribute] {
            var value: CFTypeRef?
            if AXUIElementCopyAttributeValue(app, attribute as CFString, &value) == .success,
               let value {
                let window = unsafeDowncast(value as AnyObject, to: AXUIElement.self)
                // The window arrives carrying the process default, not the app element's
                // timeout — see the note at the `SetMessagingTimeout` call in `harvest`.
                AXUIElementSetMessagingTimeout(window, timeout)
                return window
            }
        }
        return nil
    }

    private static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let text = value as? String
        else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Nil when the attribute is absent, which is the answer the caller wants: for
    /// `AXDisclosing`, *having* the attribute is what says "this row can be expanded", and its
    /// value only says whether it currently is.
    private static func flag(_ element: AXUIElement, _ attribute: String) -> Bool? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let value
        else { return nil }
        return (value as? Bool) ?? (value as? Int).map { $0 != 0 }
    }

    /// Whether a tab is the one in front. Two mechanisms because the three editors do not
    /// agree: some expose the strip as radio buttons, whose selected state is the value 1,
    /// and some expose `AXSelected` on the tab itself.
    private static func isSelected(_ element: AXUIElement) -> Bool {
        if flag(element, kAXSelectedAttribute) == true { return true }
        return flag(element, kAXValueAttribute) == true
    }

    private static func children(of element: AXUIElement, timeout: Float) -> [AXUIElement] {
        // Visible children first: for a virtualized file tree this is the difference between
        // the forty rows the user can see and every row in the project, and the forty are
        // also the better ranked ones.
        if let visible = boundedElements(
            of: element,
            attribute: kAXVisibleChildrenAttribute,
            timeout: timeout
        ), !visible.isEmpty {
            return visible
        }
        return boundedElements(of: element, attribute: kAXChildrenAttribute, timeout: timeout) ?? []
    }

    private static func boundedElements(
        of element: AXUIElement,
        attribute: String,
        timeout: Float
    ) -> [AXUIElement]? {
        var count: CFIndex = 0
        guard AXUIElementGetAttributeValueCount(element, attribute as CFString, &count) == .success,
              count > 0
        else { return nil }

        var array: CFArray?
        let wanted = min(count, CFIndex(childLimit))
        guard AXUIElementCopyAttributeValues(element, attribute as CFString, 0, wanted, &array) == .success,
              let array
        else { return nil }

        var result: [AXUIElement] = []
        result.reserveCapacity(CFArrayGetCount(array))
        for index in 0..<CFArrayGetCount(array) {
            guard let pointer = CFArrayGetValueAtIndex(array, index) else { continue }
            let child = Unmanaged<AXUIElement>.fromOpaque(pointer).takeUnretainedValue()
            // Every element is stamped here, and this is the only place elements enter the
            // walk, so it is the one place that can guarantee it. A child created by the API a
            // moment ago carries the process-wide default of about a second and a half, which
            // is twelve times the budget for the entire walk.
            AXUIElementSetMessagingTimeout(child, timeout)
            result.append(child)
        }
        return result
    }

    // MARK: - String work

    /// How many names of one kind are ever kept.
    ///
    /// `editorText` is held to two dozen for the reason the whole design is asymmetric: it is
    /// the lowest-value kind and the most abundant one, and a file open on a long import block
    /// would otherwise fill the candidate budget with tokens before the walk ever reaches the
    /// sidebar.
    private static func candidateLimit(for kind: CandidateKind) -> Int {
        switch kind {
        case .editorText: 24
        case .sidebarFile, .sidebarFolder: 120
        case .inactiveTab: 24
        case .activeTab, .windowTitle, .breadcrumb, .editorSymbol: 12
        }
    }

    /// Splits a window title into its parts. Every dash the three editors use, because they
    /// do not agree and the em dash is invisible in a diff.
    private static func titleComponents(_ title: String) -> [String] {
        let separators = [" — ", " – ", " - ", " · "]
        var parts = [title]
        for separator in separators {
            parts = parts.flatMap { $0.components(separatedBy: separator) }
        }
        return parts
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// `AXDocument` is a file URL string. Decoded through `URL` rather than by trimming the
    /// scheme, because a project with a space in its name arrives percent-encoded and a name
    /// reading "My%20Project" is a name that matches nothing the user says.
    private static func filePath(fromDocument document: String) -> String? {
        if let url = URL(string: document), url.isFileURL { return url.path }
        return document.hasPrefix("/") ? document : nil
    }

    /// The part of an absolute path below the displayed project name.
    ///
    /// Nil rather than the absolute path when the project name is not in it. That is the
    /// contract `ScreenContext.projectRoot` documents — this feature never hands out a
    /// filesystem path it resolved itself — and it is also the safer failure: a mention that
    /// degrades to a bare file name is one the receiving app resolves or ignores, while an
    /// absolute path pasted into a shared channel is somebody's home directory.
    private static func relativePath(of path: String, under projectRoot: String?) -> String? {
        guard let projectRoot, !projectRoot.isEmpty else { return nil }
        let components = path.split(separator: "/").map(String.init)
        guard let index = components.lastIndex(of: projectRoot), index + 1 < components.count else {
            return nil
        }
        return components[(index + 1)...].joined(separator: "/")
    }

    /// The file-shaped tokens in a run of visible text.
    ///
    /// Scanned scalar by scalar rather than with `NSRegularExpression`: this runs inside a
    /// 120 ms budget on strings that can be a whole line of source, and compiling a pattern
    /// per element is the kind of cost that turns a free harvest into a stalled one.
    private static func fileTokens(in text: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        // Only the head of the value. Some apps hand back the whole document rather than the
        // visible lines, and scanning a hundred kilobytes of source for file names would spend
        // the entire deadline on the least valuable kind of candidate there is.
        for character in text.prefix(editorScanLimit) {
            if character.isLetter || character.isNumber || "._-/".contains(character) {
                current.append(character)
            } else {
                if let token = fileToken(current) { tokens.append(token) }
                current = ""
            }
        }
        if let token = fileToken(current) { tokens.append(token) }
        return tokens
    }

    /// One scanned run as a candidate, or nil.
    ///
    /// The hostname test is not decoration. `ContextPrivacyFilter.allows(value:)` rejects
    /// anything containing "://" — a URL is browsing history, never a file name — but the scan
    /// set above has no colon in it, so `https:` terminates its own run and the filter is
    /// handed `internal.acme.com/q3/board-deck.pdf` with the scheme already gone. It says yes,
    /// and an internal host and a path like `private/salary-bands.xlsx` are then offered to the
    /// model as a name it may write into whatever the user is dictating into — under a Settings
    /// note promising that only names are read.
    ///
    /// So a multi-segment token whose first segment carries a dot is dropped: that is the
    /// hostname shape, and it also catches the scheme-less `github.com/acme/repo/src/login.ts`
    /// that a "was it preceded by ://" test would miss. Deliberately conditioned on the slash.
    /// A single segment with a dot in it is `next.config.js` or `tailwind.config.ts`, two of the
    /// most commonly spoken names in exactly these editors, and rejecting those would cost far
    /// more than the URLs it saves. `.github/workflows/macos.yml` survives because the leading
    /// dot is trimmed off before the test.
    private static func fileToken(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: CharacterSet(charactersIn: "./-_"))
        guard trimmed.count >= 3, CandidateName.hasFileExtension(trimmed) else { return nil }
        if let firstSegment = trimmed.split(separator: "/").first,
           trimmed.contains("/"),
           firstSegment.contains(".") {
            return nil
        }
        return trimmed
    }
}
