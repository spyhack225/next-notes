import AppKit
import SwiftUI

/// The glass that floats over the map: the zoom controls, the filter chips that double as
/// the legend, the hint line, and the card describing whatever is selected.
///
/// All of it sits **on** the canvas rather than beside it. A map in a box with a control
/// strip underneath is a chart; a map you can see under your controls is a place. Each
/// piece is its own glass surface inside a `GlassGroup`, so two that touch resolve as one
/// pane instead of shearing along the seam.

// MARK: - Zoom controls

struct GraphToolbar: View {
    @Binding var camera: GraphCamera

    var body: some View {
        GlassGroup(spacing: DS.Space.xs) {
            HStack(spacing: DS.Space.xxs) {
                control("minus.magnifyingglass", "Zoom out") {
                    camera.stepZoom(1 / DS.Size.graphZoomStep)
                }
                .disabled(camera.zoom <= DS.Size.graphZoomMin)

                control("plus.magnifyingglass", "Zoom in") {
                    camera.stepZoom(DS.Size.graphZoomStep)
                }
                .disabled(camera.zoom >= DS.Size.graphZoomMax)

                Divider().frame(height: DS.Size.iconMedium)

                control("arrow.up.left.and.down.right.magnifyingglass", "Show the whole map") {
                    camera = GraphCamera()
                }
                .disabled(camera.isHome)
            }
            .padding(.horizontal, DS.Space.xs)
            .padding(.vertical, DS.Space.xxs)
            .glassSurface(cornerRadius: DS.Radius.graphChrome)
        }
    }

    private func control(_ symbol: String, _ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: DS.Size.graphChromeIcon, weight: .medium))
                .frame(width: DS.Size.iconLarge, height: DS.Size.iconLarge)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(DS.Color.text)
        .accessibilityLabel(title)
        .help(title)
    }
}

// MARK: - Filter chips, which are also the legend

/// One chip per family, with its colour and how many of it are on the map. Switching one
/// off fades that family rather than removing it — you can still see the shape it left.
struct GraphFilterChips: View {
    let counts: [GraphKind: Int]
    @Binding var muted: Set<GraphKind>

    var body: some View {
        GlassGroup(spacing: DS.Space.xs) {
            FlowLayout(spacing: DS.Space.xs) {
                ForEach(present) { kind in
                    chip(kind, count: counts[kind] ?? 0)
                }
            }
            .padding(DS.Space.xs)
            .glassSurface(cornerRadius: DS.Radius.graphChrome)
        }
    }

    private var present: [GraphKind] {
        GraphKind.allCases.filter { (counts[$0] ?? 0) > 0 }
    }

    private func chip(_ kind: GraphKind, count: Int) -> some View {
        let isOn = !muted.contains(kind)
        return Button {
            withAnimation(DS.Motion.graphHover) {
                if isOn { muted.insert(kind) } else { muted.remove(kind) }
            }
        } label: {
            HStack(spacing: DS.Space.xs) {
                Circle()
                    .fill(kind.ink.opacity(isOn ? 1 : DS.Opacity.disabled))
                    .frame(width: DS.Size.graphLegendSwatch, height: DS.Size.graphLegendSwatch)
                Text(kind.title)
                    .font(DS.Font.chip)
                Text(count.formatted())
                    .font(DS.Font.caption2)
                    .foregroundStyle(DS.Color.textTertiary)
                    .monospacedDigit()
            }
            .foregroundStyle(isOn ? DS.Color.text : DS.Color.textTertiary)
            .padding(.horizontal, DS.Space.s)
            .padding(.vertical, DS.Space.xxs)
            .background(
                isOn ? kind.ink.opacity(DS.Opacity.chipFill) : Color.clear,
                in: Capsule()
            )
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(kind.title), \(count) on the map")
        .accessibilityValue(isOn ? "Shown" : "Faded")
        .accessibilityAddTraits(isOn ? .isSelected : [])
        .help(isOn ? "Fade \(kind.title.lowercased())" : "Bring \(kind.title.lowercased()) back")
    }
}

// MARK: - How to move around

/// One quiet line. The map has no scroll bars and no handles, so the only thing telling
/// somebody it moves is this — and it says it in the words they would use.
struct GraphHint: View {
    var body: some View {
        Text("Drag to move it. Pinch, or hold Command and scroll, to zoom.")
            .font(DS.Font.caption2)
            .foregroundStyle(DS.Color.textSecondary)
            .padding(.horizontal, DS.Space.s)
            .padding(.vertical, DS.Space.xxs)
            .glassSurface(cornerRadius: DS.Radius.graphChrome)
            .accessibilityHidden(true)
    }
}

// MARK: - The selected node

/// What one dot is, floating over the map instead of pushing it aside.
///
/// Selecting on the map used to throw the whole pane over to a different screen, which is a
/// lot to spend on a click somebody may have meant as a look. Now the click centres the map
/// and this arrives; opening the neighbourhood is a button on it, taken deliberately.
struct GraphNodeCard: View {
    let node: KnowledgeGraphNode
    /// How many things it is joined to, straight off the layout's degree count.
    let connections: Int
    var onOpen: () -> Void
    var onDismiss: () -> Void

    var body: some View {
        GlassGroup(spacing: DS.Space.xs) {
            VStack(alignment: .leading, spacing: DS.Space.s) {
                HStack(alignment: .top, spacing: DS.Space.xs) {
                    Image(systemName: GraphNodeStyle.symbol(for: node.type))
                        .font(DS.Font.caption)
                        .foregroundStyle(DS.Color.graphNode(node.type))
                        .frame(width: DS.Size.iconMedium, height: DS.Size.iconMedium)
                    VStack(alignment: .leading, spacing: DS.Space.xxs) {
                        Text(node.label)
                            .font(DS.Font.headline)
                            .foregroundStyle(DS.Color.text)
                            .lineLimit(3)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(summary)
                            .font(DS.Font.caption)
                            .foregroundStyle(DS.Color.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                    Button(action: onDismiss) {
                        Image(systemName: "xmark")
                            .font(DS.Font.caption2.weight(.semibold))
                            .frame(width: DS.Size.iconMedium, height: DS.Size.iconMedium)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(DS.Color.textTertiary)
                    .accessibilityLabel("Close")
                }

                HStack(spacing: DS.Space.xs) {
                    Button("Open what's around it", action: onOpen)
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    if let path = FileGraphOverlay.path(of: node.id) {
                        Button("Show in Finder") {
                            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
            }
            .padding(DS.Space.cardTight)
            .frame(width: DS.Size.graphDetailCardWidth, alignment: .leading)
            .glassSurface(cornerRadius: DS.Radius.graphChrome)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(node.label), \(GraphNodeStyle.singular(for: node.type))")
    }

    /// Plain language, and it counts rather than claims: "joined to 6 other things" is
    /// something the map can be checked against.
    private var summary: String {
        let kind = Self.sentenceCase(GraphNodeStyle.singular(for: node.type))
        switch connections {
        case 0: return "\(kind) · nothing joined to it yet"
        case 1: return "\(kind) · joined to one other thing"
        default: return "\(kind) · joined to \(connections) other things"
        }
    }

    /// The ontology hands over lower-cased words; a card starts with a capital.
    private static func sentenceCase(_ word: String) -> String {
        guard let first = word.first else { return word }
        return first.uppercased() + word.dropFirst()
    }
}
