import SwiftUI

/// Sheet that tweaks a `NotionAvatarConfig` part-by-part, with randomise — Apple-polished
/// configurator over the same indices as react-notion-avatar / Mayandev.
struct NotionAvatarEditor: View {
    @Binding var config: NotionAvatarConfig
    var onDone: () -> Void

    @State private var selectedPart: NotionAvatarConfig.Part = .face

    var body: some View {
        VStack(spacing: DS.Space.l) {
            NotionAvatarView(config: config, size: DS.Size.agentAvatarHero)
                .padding(.top, DS.Space.m)

            Picker("Part", selection: $selectedPart) {
                ForEach(NotionAvatarConfig.Part.drawOrder) { part in
                    Text(part.displayName).tag(part)
                }
            }
            .pickerStyle(.menu)
            .frame(maxWidth: DS.Size.agentAboutCardIdeal)

            partChooser

            HStack(spacing: DS.Space.m) {
                Button("Randomise", systemImage: "dice") {
                    config = .random()
                }
                .buttonStyle(.bordered)
                Spacer()
                Button("Done") { onDone() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, DS.Space.page)
            .padding(.bottom, DS.Space.m)
        }
        .frame(minWidth: 420, minHeight: 480)
        .background(DS.Color.window)
    }

    private var partChooser: some View {
        let max = selectedPart.maxIndex
        return VStack(alignment: .leading, spacing: DS.Space.s) {
            HStack {
                Text(selectedPart.displayName)
                    .font(DS.Font.sectionLabel)
                Spacer()
                Text("\(config[selectedPart]) / \(max)")
                    .font(DS.Font.caption)
                    .foregroundStyle(DS.Color.textSecondary)
                    .monospacedDigit()
            }
            .padding(.horizontal, DS.Space.page)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: DS.Space.s) {
                    ForEach(0...max, id: \.self) { index in
                        let preview = previewConfig(index: index)
                        Button {
                            config[selectedPart] = index
                        } label: {
                            NotionAvatarView(config: preview, size: DS.Size.agentAvatarThumb)
                                .overlay {
                                    if config[selectedPart] == index {
                                        Circle()
                                            .strokeBorder(DS.Color.accent, lineWidth: DS.Size.voiceChoiceBorder)
                                    }
                                }
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(selectedPart.displayName) \(index)")
                    }
                }
                .padding(.horizontal, DS.Space.page)
            }

            Stepper(
                value: Binding(
                    get: { config[selectedPart] },
                    set: { config[selectedPart] = $0 }
                ),
                in: 0...max
            ) {
                Text("Previous / next \(selectedPart.displayName.lowercased())")
                    .font(DS.Font.callout)
            }
            .padding(.horizontal, DS.Space.page)
        }
    }

    private func previewConfig(index: Int) -> NotionAvatarConfig {
        var copy = config
        copy[selectedPart] = index
        return copy
    }
}
