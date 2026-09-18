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
        VStack(alignment: .leading, spacing: DS.Space.m) {
            Text(personLabel)
                .font(DS.Font.headline)
            if moments.isEmpty {
                Text("No meetings attended yet in the extracted graph.")
                    .font(DS.Font.caption)
                    .foregroundStyle(DS.Color.textSecondary)
            } else {
                ForEach(moments) { moment in
                    momentCard(moment)
                }
            }
        }
        .frame(maxWidth: DS.Size.timelineRowMaxWidth, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Timeline for \(personLabel)")
    }

    private func momentCard(_ moment: PersonMeetingMoment) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            Button {
                onOpenMeeting(moment.meetingID)
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: DS.Space.s) {
                    Text(moment.title)
                        .font(DS.Font.callout)
                        .foregroundStyle(DS.Color.text)
                        .multilineTextAlignment(.leading)
                    Spacer(minLength: DS.Space.xs)
                    Text(moment.at.formatted(date: .abbreviated, time: .omitted))
                        .font(DS.Font.caption)
                        .foregroundStyle(DS.Color.textTertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

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
        .padding(DS.Space.cardTight)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassSurface(cornerRadius: DS.Radius.card)
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
