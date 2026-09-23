import AppKit
import SwiftUI

/// The pieces the map is built out of: the families its filter chips work in, the camera
/// that pans and zooms it, and the thing that runs the layout off the main actor.
///
/// Kept apart from the drawing so the expensive half has no opinion about pixels and the
/// drawing half has no opinion about threads.

// MARK: - Families

/// The ontology has sixteen node types. Nobody filters a map by sixteen checkboxes, so the
/// chips work in the seven families a person would actually name out loud, and the finer
/// type still decides the dot's ink and its glyph.
enum GraphKind: String, CaseIterable, Identifiable, Sendable {
    case people, memories, meetings, decisions, work, life, topics, files

    var id: String { rawValue }

    /// Plain language. These are chip labels a non-technical person reads at a glance.
    var title: String {
        switch self {
        case .people: "People"
        case .memories: "Memories"
        case .meetings: "Meetings"
        case .decisions: "Decisions"
        case .work: "Projects"
        case .life: "Life"
        case .topics: "Topics"
        case .files: "Files"
        }
    }

    var symbol: String {
        switch self {
        case .people: "person.2"
        case .memories: "brain"
        case .meetings: "calendar"
        case .decisions: "checkmark.seal"
        case .work: "briefcase"
        case .life: "figure.walk"
        case .topics: "tag"
        case .files: "folder"
        }
    }

    /// The type whose ink stands for the whole family in the legend and on a chip.
    var representativeType: String {
        switch self {
        case .people: "Person"
        case .memories: "Memory"
        case .meetings: "Meeting"
        case .decisions: "Decision"
        case .work: "Project"
        case .life: "Activity"
        case .topics: "Topic"
        case .files: "Folder"
        }
    }

    var ink: Color { DS.Color.graphNode(representativeType) }

    static func of(_ type: String) -> GraphKind {
        switch type {
        case "Person": .people
        case "Memory": .memories
        case "Meeting": .meetings
        case "Decision", "ActionItem", "OpenQuestion", "Artifact": .decisions
        case "Project", "Organization", "Goal": .work
        case "Activity", "Place", "Event": .life
        case "Folder", "File": .files
        default: .topics
        }
    }
}

// MARK: - Camera

/// Where the map is being looked at from. Zoom about a point, pan by a drag, centre on a
/// node — and nothing else, so the view that owns one can animate it as a single value.
struct GraphCamera: Equatable, Sendable {
    var zoom: CGFloat = 1
    var pan: CGSize = .zero

    var isHome: Bool { abs(zoom - 1) < 0.001 && pan == .zero }

    func project(_ point: CGPoint, in size: CGSize) -> CGPoint {
        CGPoint(x: (point.x - size.width / 2) * zoom + size.width / 2 + pan.width,
                y: (point.y - size.height / 2) * zoom + size.height / 2 + pan.height)
    }

    func unproject(_ point: CGPoint, in size: CGSize) -> CGPoint {
        CGPoint(x: (point.x - pan.width - size.width / 2) / zoom + size.width / 2,
                y: (point.y - pan.height - size.height / 2) / zoom + size.height / 2)
    }

    /// Zoom so that whatever is under `anchor` stays under it. Zooming about the middle
    /// instead is what makes a map feel like it is squirming away from the pointer.
    mutating func setZoom(_ target: CGFloat, around anchor: CGPoint, in size: CGSize) {
        let held = unproject(anchor, in: size)
        let next = min(max(target, DS.Size.graphZoomMin), DS.Size.graphZoomMax)
        zoom = next
        pan = CGSize(width: anchor.x - (held.x - size.width / 2) * next - size.width / 2,
                     height: anchor.y - (held.y - size.height / 2) * next - size.height / 2)
    }

    /// One press of a zoom button. No anchor is needed: with the pan left alone, the point
    /// that stays put is whatever is in the middle of the frame, which is what a button
    /// pressed with no pointer on the map should do.
    mutating func stepZoom(_ factor: CGFloat) {
        zoom = min(max(zoom * factor, DS.Size.graphZoomMin), DS.Size.graphZoomMax)
    }

    /// Bring one layout point to the middle of the frame, keeping the current zoom.
    mutating func centre(on point: CGPoint, in size: CGSize) {
        pan = CGSize(width: -(point.x - size.width / 2) * zoom,
                     height: -(point.y - size.height / 2) * zoom)
    }
}

// MARK: - Layout, off the main actor

/// Runs `ForceLayout` on a background task and publishes the result.
///
/// The views used to build a `ForceLayout` inside `GeometryReader`, which meant an O(n²)
/// simulation ran on the main actor during view evaluation — on every resize, and on every
/// hover, because a hover re-evaluates the body that was building it. At a few hundred
/// nodes that is a window that stops redrawing while the pointer moves. Here it runs once
/// per real change, off the main actor, and the old picture stays on screen until the new
/// one is ready rather than the view going blank.
///
/// The frame is quantised **down** before the layout is asked for, so dragging a window
/// edge does not start a new simulation every frame — and down rather than to the nearest
/// step, because a layout computed for a frame larger than the one it is drawn in would put
/// nodes outside it.
@MainActor
@Observable
final class GraphLayoutModel {
    private(set) var layout = ForceLayout(ids: [], edges: [], size: .zero)
    /// The nodes whose names the map shows without being asked — the busiest handful.
    private(set) var prominent: Set<String> = []
    /// True while the first layout for a new graph is still being computed.
    private(set) var isSettling = false

    private var key: Key?
    private var job: Task<Void, Never>?

    private struct Key: Equatable {
        var nodes: UInt64
        var edges: UInt64
        var count: Int
        var width: CGFloat
        var height: CGFloat
    }

    func update(nodes: [KnowledgeGraphNode], edges: [KnowledgeGraphEdge], size: CGSize) {
        let step = DS.Size.graphLayoutSizeStep
        let frame = CGSize(width: (size.width / step).rounded(.down) * step,
                           height: (size.height / step).rounded(.down) * step)
        guard frame.width > 1, frame.height > 1 else { return }

        let next = Key(nodes: Self.fold(nodes.lazy.map(\.id)),
                       edges: Self.fold(edges.lazy.flatMap { [$0.from, $0.to] }),
                       count: nodes.count,
                       width: frame.width,
                       height: frame.height)
        guard next != key else { return }
        key = next

        job?.cancel()
        let ids = nodes.map(\.id)
        let links = edges.map { GraphLink(from: $0.from, to: $0.to) }
        isSettling = layout.placements.isEmpty
        job = Task { [weak self] in
            let computed = await Task.detached(priority: .userInitiated) {
                ForceLayout(ids: ids, edges: links.map { ($0.from, $0.to) }, size: frame)
            }.value
            guard !Task.isCancelled, let self else { return }
            layout = computed
            prominent = Self.prominentIDs(in: computed)
            isSettling = false
        }
    }

    /// The busiest nodes, by how many things they are joined to. Ties break on the id so
    /// the same map always labels the same dots.
    private static func prominentIDs(in layout: ForceLayout) -> Set<String> {
        let ranked = layout.degree
            .filter { $0.value > 0 }
            .sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .prefix(DS.Size.graphRestingLabels)
        return Set(ranked.map(\.key))
    }

    /// FNV-1a over a sequence of ids. Cheap enough to run on every reload and exact enough
    /// that two different graphs do not share a key.
    private static func fold(_ strings: some Sequence<String>) -> UInt64 {
        var hash: UInt64 = 1_469_598_103_934_665_603
        for string in strings {
            for byte in string.utf8 {
                hash ^= UInt64(byte)
                hash = hash &* 1_099_511_628_211
            }
            hash ^= 0x2F
            hash = hash &* 1_099_511_628_211
        }
        return hash
    }
}

/// An edge reduced to the two ends the layout cares about, and `Sendable` so it can cross
/// to the background task a tuple could not.
struct GraphLink: Sendable, Hashable {
    let from: String
    let to: String
}

// MARK: - Scroll wheel

/// Scroll-wheel pan and zoom over the map.
///
/// There is no SwiftUI modifier for a wheel event on something that is not a `ScrollView`,
/// and an `NSView` laid over the canvas would either swallow the clicks or never see the
/// scroll. A local monitor, installed only while the pointer is actually over the map and
/// removed the moment it leaves, is the narrowest thing that works: it never sees an event
/// meant for anything else on screen.
@MainActor
@Observable
final class GraphScrollMonitor {
    /// Called on the main thread for each wheel event: the delta, and whether the user is
    /// holding a modifier that means "zoom" rather than "pan".
    var handler: ((CGSize, Bool) -> Void)?

    private var monitor: Any?

    var isRunning: Bool { monitor != nil }

    func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel]) { [weak self] event in
            let delta = CGSize(width: event.scrollingDeltaX, height: event.scrollingDeltaY)
            let zooming = event.modifierFlags.contains(.command)
                || event.modifierFlags.contains(.option)
            MainActor.assumeIsolated { self?.handler?(delta, zooming) }
            return nil
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}
