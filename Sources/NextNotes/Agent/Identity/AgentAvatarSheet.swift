import AppKit
import SwiftUI

/// `--avatar-sheet [path]` — every avatar state, at three instants, rendered to one PNG.
///
/// A diagnostic rather than a self-test: a self-test answers a yes/no question from a
/// terminal, and this one produces something to *look* at. It exists because the redesigned
/// UI cannot be screenshotted here — that needs a Screen Recording grant — while
/// `ImageRenderer` needs nothing, so this is how the character's vocabulary gets reviewed
/// by eye before it is trusted on the island.
///
/// Each state is drawn twice: as the window draws it (semantic ink on the window colour)
/// and as the island draws it (white ink on the bezel's black), because a prop that
/// disappears against one substrate is the mistake a single-column sheet would hide.
@MainActor
enum AgentAvatarSheet {
    private static let times: [(title: String, value: Double)] = [
        ("still", AgentAvatarChoreography.stillFrame),
        ("mid", AgentAvatarChoreography.stillFrame + 0.9),
        ("late", AgentAvatarChoreography.stillFrame + 2.6),
    ]

    static func write(to path: String) -> Bool {
        let config = AgentIdentityStore.shared.avatar
        let content = VStack(alignment: .leading, spacing: DS.Space.m) {
            Text("Avatar states — \(config.face)/\(config.eyes)/\(config.hair) · \(path)")
                .font(.system(size: 13, weight: .semibold))
            HStack(alignment: .top, spacing: DS.Space.l) {
                panel(title: "window", ink: DS.Color.text, config: config) {
                    DS.Color.window
                }
                panel(title: "island", ink: .white, config: config) {
                    DS.Color.island
                }
            }
        }
        .padding(DS.Space.l)
        .background(DS.Color.window)

        let renderer = ImageRenderer(content: content)
        renderer.scale = 2
        guard let image = renderer.nsImage,
              let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else {
            print("AVATAR_SHEET_FAILED: could not render")
            return false
        }
        do {
            try png.write(to: URL(fileURLWithPath: path))
        } catch {
            print("AVATAR_SHEET_FAILED: \(error.localizedDescription)")
            return false
        }
        print("AVATAR_SHEET_OK \(path)")
        return true
    }

    private static func panel(
        title: String,
        ink: Color,
        config: NotionAvatarConfig,
        background: @escaping () -> Color
    ) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(title == "window" ? DS.Color.text : Color.white)
            ForEach(AgentAvatarState.allCases, id: \.self) { state in
                HStack(spacing: DS.Space.m) {
                    VStack(alignment: .leading) {
                        Text(state.rawValue)
                            .font(.system(size: 11, weight: .medium))
                        Text(AgentAvatarChoreography.prop(state)?.rawValue ?? "no gadget")
                            .font(.system(size: 9))
                            .opacity(0.6)
                    }
                    .frame(width: 72, alignment: .leading)
                    ForEach(times, id: \.title) { time in
                        AgentAvatarView(
                            config: config,
                            state: state,
                            size: DS.Size.agentAvatarHero,
                            ink: ink,
                            showsProp: true,
                            frozenAt: time.value
                        )
                    }
                }
                .foregroundStyle(title == "window" ? DS.Color.text : Color.white)
            }

            // The sizes the app actually draws at, in the state the island shows most:
            // 24 is the notch badge, where the gadget is deliberately absent and the face
            // has to carry it alone.
            HStack(spacing: DS.Space.m) {
                Text("sizes")
                    .font(.system(size: 11, weight: .medium))
                    .frame(width: 72, alignment: .leading)
                ForEach([DS.Size.islandAvatar, DS.Size.agentAvatar, DS.Size.avatarOnboarding], id: \.self) { side in
                    VStack(spacing: DS.Space.xs) {
                        AgentAvatarView(config: config, state: .thinking, size: side, ink: ink)
                        Text("\(Int(side))")
                            .font(.system(size: 9))
                            .opacity(0.6)
                    }
                }
            }
            .foregroundStyle(title == "window" ? DS.Color.text : Color.white)
        }
        .padding(DS.Space.s)
        .background(background(), in: RoundedRectangle(cornerRadius: DS.Radius.glass))
    }
}
