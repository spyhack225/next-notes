import SwiftUI

/// People: who resolution decided is one person, and the pairs it could not decide.
///
/// Resolution will be wrong sometimes, and a wrong merge the user cannot see or undo is how
/// trust in the whole feature ends. So every merge is listed with how it was decided and why,
/// and *Split* undoes it — one row's update, nothing restored from anywhere. Pairs in the
/// ambiguous band are asked as questions: *Same person* or *Different people*, both kept so a
/// rebuilt index agrees. A merge resolution missed is made by hand with *Merge into…*. The
/// last action has an *Undo*.
struct MergePeopleSheet: View {
    @State private var service = PersonResolutionService.shared
    @State private var showEveryone = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if service.people.isEmpty && service.candidates.isEmpty {
                    OrbUnavailableView(
                        service.isResolving ? .searching : .connecting,
                        title: service.isResolving ? "Resolving people…" : "No people yet",
                        message: "People come from meeting attendees, named speakers and action item owners, "
                            + "once decisions and action items have been extracted."
                    ) {
                        Button("Resolve now") { Task { await service.resolve() } }
                            .disabled(service.isResolving || !service.isEnabled)
                    }
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: DS.Space.l) {
                            header
                            if !service.candidates.isEmpty { suggestionSection }
                            if !merged.isEmpty { mergedSection }
                            if !unmerged.isEmpty { everyoneSection }
                            Text("Voices link only for meetings whose speakers were detected while this was on. "
                                + "Run speaker detection again on an older meeting to include it.")
                                .font(DS.Font.caption)
                                .foregroundStyle(DS.Color.textTertiary)
                                .frame(maxWidth: DS.Size.readingWidth, alignment: .leading)
                            if let problem = service.problem {
                                Text(problem)
                                    .font(DS.Font.caption)
                                    .foregroundStyle(DS.Color.warning)
                            }
                        }
                        .padding(DS.Space.page)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .navigationTitle("People")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .frame(minWidth: 520, idealWidth: 620, minHeight: 440, idealHeight: 620)
        .task {
            service.reload()
            if !service.hasLoaded || (service.people.isEmpty && service.isEnabled) {
                await service.resolve(useModel: false)
            }
        }
    }

    private var merged: [ResolvedPerson] { service.people.filter { !$0.members.isEmpty } }
    private var unmerged: [ResolvedPerson] { service.people.filter { $0.members.isEmpty } }

    private var names: [String: String] { service.displayNames }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: DS.Space.s) {
            if let report = service.lastReport {
                Text("\(report.people) people from \(report.mentions) mentions")
                    .font(DS.Font.caption)
                    .foregroundStyle(DS.Color.textSecondary)
            }
            Spacer()
            if let action = service.lastAction {
                Text(describe(action))
                    .font(DS.Font.caption)
                    .foregroundStyle(DS.Color.textSecondary)
                    .lineLimit(1)
                Button("Undo") { service.undo() }
            }
            Button(service.isResolving ? "Resolving…" : "Resolve again") { Task { await service.resolve() } }
                .disabled(service.isResolving)
        }
    }

    private func describe(_ action: PersonResolutionService.Action) -> String {
        switch action {
        case .merged(let id, let into, _): "Merged \(names[id] ?? id) into \(names[into] ?? into)"
        case .split(let id, let from): "Split \(names[id] ?? id) from \(names[from] ?? from)"
        case .keptApart(let pair): "Kept \(names[pair.a] ?? pair.a) and \(names[pair.b] ?? pair.b) apart"
        }
    }

    // MARK: - Suggestions

    private var suggestionSection: some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            Text("Same person?").font(DS.Font.sectionLabel)
            ForEach(service.candidates) { candidate in
                let first = names[candidate.pair.a] ?? candidate.pair.a
                let second = names[candidate.pair.b] ?? candidate.pair.b
                VStack(alignment: .leading, spacing: DS.Space.xs) {
                    Text("\(first) and \(second)")
                        .font(DS.Font.callout)
                    Text("\(percent(candidate.score)) · \(candidate.reasons)"
                        + (candidate.verdict == true ? " · the on-device model thinks so" : ""))
                        .font(DS.Font.caption)
                        .foregroundStyle(DS.Color.textSecondary)
                    HStack(spacing: DS.Space.s) {
                        Button("Same person") { service.merge(candidate.pair.b, into: candidate.pair.a) }
                            .buttonStyle(.borderedProminent)
                        Button("Different people") { service.keepApart(candidate.pair) }
                    }
                }
                .padding(DS.Space.cardTight)
                .frame(maxWidth: DS.Size.readingWidth, alignment: .leading)
                .glassSurface(cornerRadius: DS.Radius.card)
            }
        }
    }

    // MARK: - Merged

    private var mergedSection: some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            Text("Merged").font(DS.Font.sectionLabel)
            ForEach(merged) { person in
                VStack(alignment: .leading, spacing: DS.Space.s) {
                    HStack(spacing: DS.Space.s) {
                        Text(person.name).font(DS.Font.headline)
                        Spacer()
                        Text("\(person.meetings) meeting\(person.meetings == 1 ? "" : "s")")
                            .font(DS.Font.chip)
                            .foregroundStyle(DS.Color.textTertiary)
                        mergeMenu(person)
                    }
                    ForEach(person.members) { member in memberRow(member) }
                }
                .padding(DS.Space.cardTight)
                .frame(maxWidth: DS.Size.readingWidth, alignment: .leading)
                .glassSurface(cornerRadius: DS.Radius.card)
            }
        }
    }

    // MARK: - Everyone else

    private var everyoneSection: some View {
        DisclosureGroup("Not merged with anyone (\(unmerged.count))", isExpanded: $showEveryone) {
            VStack(alignment: .leading, spacing: DS.Space.xs) {
                ForEach(unmerged) { person in
                    HStack(spacing: DS.Space.s) {
                        Text(person.name).font(DS.Font.body)
                        if person.kind == .speaker {
                            StatusChip(text: "Voice", systemImage: "waveform")
                        }
                        Spacer()
                        mergeMenu(person)
                    }
                }
            }
            .padding(.top, DS.Space.xs)
        }
        .font(DS.Font.sectionLabel)
        .frame(maxWidth: DS.Size.readingWidth, alignment: .leading)
    }

    /// "Same person as…", for a merge resolution missed ("S.K." is never suggested on initials alone).
    private func mergeMenu(_ person: ResolvedPerson) -> some View {
        Menu("Merge into…") {
            ForEach(service.people.filter { $0.id != person.id && $0.kind == .person }) { other in
                Button(other.name) { service.merge(person.id, into: other.id) }
            }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("The same person as someone else. Undo, or Split later, reverses it.")
    }

    private func memberRow(_ member: ResolvedPersonMember) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: DS.Space.s) {
            VStack(alignment: .leading, spacing: DS.Space.xxs) {
                HStack(spacing: DS.Space.s) {
                    Text(member.label).font(DS.Font.body)
                    StatusChip(text: member.method.displayName, systemImage: icon(member.method))
                }
                if let reasons = member.reasons, !reasons.isEmpty {
                    Text([member.score.map(percent), reasons].compactMap { $0 }.joined(separator: " · "))
                        .font(DS.Font.caption)
                        .foregroundStyle(DS.Color.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer()
            Button("Split") { service.split(member.id) }
                .help("Not the same person. They will not be merged again.")
        }
        .padding(.vertical, DS.Space.xs)
    }

    private func icon(_ method: ResolutionMethod) -> String {
        switch method {
        case .user: "person.fill.checkmark"
        case .email: "envelope"
        case .voice: "waveform"
        case .name: "person.text.rectangle"
        case .model: "cpu"
        }
    }

    private func percent(_ score: Double) -> String {
        "\(Int((score * 100).rounded()))%"
    }
}
