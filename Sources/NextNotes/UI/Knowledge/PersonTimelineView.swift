import SwiftUI

/// One person's meetings against time (Part 4, Phase F).
///
/// The same edges as the local graph, drawn chronologically: what someone has been involved
/// in lately, not their betweenness. Each meeting lists the decisions and action items it
/// produced; ones that person owns are marked. Shares focus with `LocalGraphView`.
struct PersonTimelineView: View {
    let personLabel: String
    let moments: [PersonMeetingMoment]
    var onOpenMeeting: (String) -> Void
    var onFocusNode: ((String) -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.l) {
            SectionHeading(
                title: personLabel,
                eyebrow: "Timeline",
                subtitle: moments.isEmpty
                    ? "Meetings appear here once this person is linked in the extracted graph."
                    : "\(moments.count) meeting\(moments.count == 1 ? "" : "s") in the life map."
            )

            if moments.isEmpty {
                Text("No meetings attended yet in the extracted graph.")
                    .font(DS.Font.callout)
                    .foregroundStyle(DS.Color.textSecondary)
                    .padding(.leading, DS.Size.timelineGutter)
            } else {
                VStack(alignment: .leading, spacing: DS.Space.m) {
                    ForEach(Array(moments.enumerated()), id: \.element.id) { index, moment in
                        timelineRow(moment, isLast: index == moments.count - 1)
                    }
                }
            }
        }
        .frame(maxWidth: DS.Size.timelineRowMaxWidth, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Timeline for \(personLabel)")
    }

    private func timelineRow(_ moment: PersonMeetingMoment, isLast: Bool) -> some View {
        HStack(alignment: .top, spacing: DS.Space.m) {
            timelineRail(isLast: isLast)

            VStack(alignment: .leading, spacing: DS.Space.s) {
                Text(moment.at.formatted(date: .abbreviated, time: .omitted))
                    .font(DS.Font.eyebrow)
                    .tracking(DS.Font.eyebrowTracking)
                    .textCase(.uppercase)
                    .foregroundStyle(DS.Color.textSecondary)

                momentCard(moment)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func timelineRail(isLast: Bool) -> some View {
        VStack(spacing: 0) {
            Circle()
                .fill(DS.Color.accent)
                .frame(width: DS.Size.timelineMarker, height: DS.Size.timelineMarker)
                .overlay {
                    Circle()
                        .strokeBorder(
                            DS.Color.accent.opacity(DS.Opacity.graphFocusRing),
                            lineWidth: DS.Border.hairline
                        )
                        .frame(
                            width: DS.Size.timelineMarker + DS.Space.xs,
                            height: DS.Size.timelineMarker + DS.Space.xs
                        )
                }
                .padding(.top, DS.Space.xxs)

            if !isLast {
                Rectangle()
                    .fill(DS.Color.separator.opacity(DS.Opacity.timelineSpine))
                    .frame(width: DS.Size.timelineSpineWidth)
                    .frame(maxHeight: .infinity)
            }
        }
        .frame(width: DS.Size.timelineGutter)
    }

    private func momentCard(_ moment: PersonMeetingMoment) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            Button {
                onOpenMeeting(moment.meetingID)
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: DS.Space.s) {
                    Text(moment.title)
                        .font(DS.Font.callout.weight(.medium))
                        .foregroundStyle(DS.Color.text)
                        .multilineTextAlignment(.leading)
                    Spacer(minLength: DS.Space.xs)
                    Image(systemName: "arrow.up.right")
                        .font(DS.Font.caption2)
                        .foregroundStyle(DS.Color.textTertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Open meeting")

            if !moment.decisions.isEmpty {
                itemList("Decisions", items: moment.decisions, owned: [])
            }
            if !moment.actionItems.isEmpty {
                itemList("Action items", items: moment.actionItems, owned: moment.ownedIDs)
            }
            if moment.decisions.isEmpty && moment.actionItems.isEmpty {
                Text("Attended — nothing extracted yet for this meeting.")
                    .font(DS.Font.caption)
                    .foregroundStyle(DS.Color.textTertiary)
            }
        }
        .padding(DS.Space.card)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassSurface(cornerRadius: DS.Radius.glass)
    }

    private func itemList(_ title: String, items: [PersonTimelineItem], owned: Set<String>) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            Text(title)
                .font(DS.Font.sectionLabel)
                .foregroundStyle(DS.Color.textSecondary)
            ForEach(items) { item in
                HStack(alignment: .firstTextBaseline, spacing: DS.Space.s) {
                    Button {
                        onFocusNode?(item.id)
                    } label: {
                        Text(item.text)
                            .font(DS.Font.body)
                            .foregroundStyle(DS.Color.text)
                            .multilineTextAlignment(.leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                    if owned.contains(item.id) {
                        StatusChip(text: "Owns", systemImage: "person.fill")
                    }
                }
            }
        }
    }
}
