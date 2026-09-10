import AppKit
import SwiftUI

/// The window the island lives in.
///
/// The same rule as `HUDPanel`, and for a stronger reason: **this panel never becomes key**.
/// It appears while the user is dictating into someone else's text field and while they are
/// talking in a video call, and a window that took focus at either moment would break the
/// thing it is reporting on.
///
/// Two decisions are worth knowing before changing anything here.
///
/// **The panel never resizes.** Its frame is always the *expanded* bounds; collapsing and
/// expanding is done entirely by the SwiftUI view inside it. A window animating its own
/// frame while its content animates its own layout produces two curves fighting over the
/// same pixels, and the seam is visible. The cost is that most of the window is transparent
/// most of the time, which is what `IslandContainerView.hitTest` exists to answer.
///
/// **Hover is found with event monitors, not an `NSTrackingArea`.** A collapsed island
/// ignores mouse events so the menu bar either side of the notch keeps working — and a
/// window that ignores mouse events gets no tracking-area callbacks either. Monitors see
/// the pointer without taking it. They also answer "which display is the user on", which
/// the island needs anyway.
@MainActor
final class IslandPanel: NSPanel {
    private let state: IslandState
    private var metrics: IslandGeometry.Metrics?
    private var screenID: CGDirectDisplayID?
    private let container = IslandContainerView()
    private var hosting: NSHostingView<IslandView>?
    /// The last state written to the log, so a level change doesn't repeat it.
    private var lastLoggedKind: String?
    private var monitors: [Any] = []
    private var screenObserver: NSObjectProtocol?

    init(state: IslandState = .shared) {
        self.state = state
        super.init(
            contentRect: NSRect(origin: .zero, size: DS.Size.hud),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        isFloatingPanel = true
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        hidesOnDeactivate = false
        isMovableByWindowBackground = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        // Mouse-moved events are delivered to the window only when it asks; the expanded
        // island needs them so a pointer leaving it is noticed without waiting for a click.
        acceptsMouseMovedEvents = true
        ignoresMouseEvents = true

        container.autoresizingMask = [.width, .height]
        contentView = container

        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor [weak self] in self?.place(force: true) }
        }

        observe()
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    // MARK: - Following the state

    /// Re-arms after every change to what the island is saying, exactly like the app
    /// delegate's own tracking loop. Re-registering has to happen after a hop: the callback
    /// runs while the change is still being applied.
    private func observe() {
        withObservationTracking {
            _ = state.kind
            _ = state.isExpanded
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.apply()
                self.observe()
            }
        }
        apply()
    }

    private func apply() {
        if state.kind.isHidden {
            dismiss()
            return
        }
        place(force: false)

        // Logged on entry to a state rather than on every level tick, or dictating would
        // write a line per audio buffer. This is the line that answers "the island never
        // appeared": it names the state, the screen it landed on, and whether that screen
        // had a notch to hug.
        if lastLoggedKind != state.kind.identity {
            lastLoggedKind = state.kind.identity
            let screen = screenID.map(String.init) ?? "none"
            let hugs = metrics?.hugsNotch == true
            Log.island.info("\(self.state.kind.identity, privacy: .public) on screen \(screen, privacy: .public), hugsNotch \(hugs, privacy: .public)")
        }

        // False only while expanded, so that a collapsed island hanging over the menu bar
        // never eats a click meant for the menu next to the notch.
        ignoresMouseEvents = !state.isExpanded
        container.islandRect = metrics?.islandRect(expanded: state.isExpanded) ?? .zero
        present()
    }

    // MARK: - Placement

    /// Puts the panel on the screen the pointer is on, rebuilding its contents when that
    /// screen's measurements differ from the last one's.
    private func place(force: Bool) {
        guard let screen = IslandGeometry.screenUnderMouse() else {
            Log.island.error("no screen available to place the island")
            return
        }
        let id = Self.displayID(of: screen)
        guard force || id != screenID || metrics == nil else { return }
        screenID = id

        let metrics = IslandGeometry.metrics(for: screen)
        self.metrics = metrics
        setFrame(metrics.bounds, display: true)
        // A shadow under a shape that is flush with the top of the screen draws a grey halo
        // around the bezel. A floating capsule wants one.
        hasShadow = !metrics.hugsNotch

        let root = IslandView(state: state, metrics: metrics)
        if let hosting {
            hosting.rootView = root
        } else {
            let view = NSHostingView(rootView: root)
            view.frame = container.bounds
            view.autoresizingMask = [.width, .height]
            container.addSubview(view)
            hosting = view
        }
        container.islandRect = metrics.islandRect(expanded: state.isExpanded)
    }

    /// A screen's stable identity. `NSScreen` instances are recreated on every display
    /// change, so comparing the objects themselves says "different" when nothing moved.
    private static func displayID(of screen: NSScreen) -> CGDirectDisplayID? {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        return (screen.deviceDescription[key] as? NSNumber)?.uint32Value
    }

    // MARK: - Showing

    private func present() {
        startWatchingPointer()
        guard !isVisible || alphaValue < 1 else { return }
        alphaValue = 0
        orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = DS.Motion.islandFade
            animator().alphaValue = 1
        }
    }

    private func dismiss() {
        stopWatchingPointer()
        state.isHovered = false
        guard isVisible else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = DS.Motion.islandFade
            animator().alphaValue = 0
        } completionHandler: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.state.kind.isHidden else { return }
                self.orderOut(nil)
            }
        }
    }

    // MARK: - Hover

    /// Watches the pointer while the island is on screen — and only while it is.
    ///
    /// Two monitors because they see different things: the global one gets moves delivered
    /// to every other app, which is where the pointer is nearly all the time, and the local
    /// one gets the ones delivered to Next Notes' own windows.
    private func startWatchingPointer() {
        guard monitors.isEmpty else { return }
        let events: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged]
        let notice: @Sendable () -> Void = { [weak self] in
            Task { @MainActor in self?.pointerMoved() }
        }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: events, handler: { _ in notice() }) {
            monitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: events, handler: { event in
            notice()
            return event
        }) {
            monitors.append(local)
        }
        pointerMoved()
    }

    private func stopWatchingPointer() {
        for monitor in monitors { NSEvent.removeMonitor(monitor) }
        monitors.removeAll()
    }

    private func pointerMoved() {
        guard isVisible, let metrics else { return }
        // The display the pointer is on can change without any screen parameter changing,
        // which is the only way the island learns to follow it onto a second monitor.
        if let screen = IslandGeometry.screenUnderMouse(),
           Self.displayID(of: screen) != screenID {
            place(force: true)
        }
        let local = metrics.islandRect(expanded: state.isExpanded)
        let onScreen = NSRect(
            x: frame.minX + local.minX,
            y: frame.minY + local.minY,
            width: local.width,
            height: local.height
        )
        // A little slack around the shape: the collapsed island is a few points tall, and
        // an exact rectangle makes it flicker as the pointer crosses its edge.
        state.isHovered = onScreen.insetBy(dx: -DS.Space.s, dy: -DS.Space.s)
            .contains(NSEvent.mouseLocation)
    }
}

/// The panel's content view, which exists to answer one question: is this click for the
/// island, or for whatever is behind the transparent rest of the window?
///
/// Without it the panel's full expanded rectangle — four hundred points of nothing either
/// side of the card — would swallow clicks meant for the app underneath for as long as a
/// notice was up.
private final class IslandContainerView: NSView {
    /// The island's own rectangle, in this view's coordinates. Set by the panel.
    var islandRect: NSRect = .zero

    override func hitTest(_ point: NSPoint) -> NSView? {
        // `point` arrives in the superview's coordinates; for a window's content view that
        // is the window's own base coordinate system, which is what `from: nil` converts.
        let local = convert(point, from: superview)
        guard islandRect.contains(local) else { return nil }
        return super.hitTest(point)
    }
}
