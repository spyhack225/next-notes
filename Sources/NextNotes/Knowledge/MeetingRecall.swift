import Foundation

/// One earlier meeting, and the sentence that says why it is in the list.
///
/// `why` is the whole point of this slice. A row of meetings with nothing to explain them
/// reads exactly like a confident answer, and a person mid-meeting has no way to tell the
/// two apart — so every row carries one plain sentence ("3 of the same people", "Nico M.
/// was in both", "Same topic: Decisions") and it is never empty.
struct MeetingRecallHit: Identifiable, Equatable, Sendable {
    var id: UUID { meetingID }
    let meetingID: UUID
    let title: String
    let at: Date
    /// Why this meeting is in the list. Never empty: a filter that cannot say why a
    /// meeting is here has no business showing the meeting.
    let why: String
    /// The people both meetings had, in the current meeting's own spelling and order.
    /// Empty for the filters that are not about people.
    let people: [String]
    /// How many things matched — one person's overlap, the passages that hit, or the ways
    /// two meetings are connected. The UI re-sorts on it when it wants its own order.
    var matchCount: Int
}

/// Which question about earlier meetings the person is asking.
enum MeetingRecallFilter: String, CaseIterable, Identifiable, Sendable {
    /// The most recent meetings other than this one.
    case recent
    /// Meetings that shared at least one of this meeting's people.
    case samePeople
    /// Meetings whose notes and transcripts talk about the same words.
    case sameTopic
    /// Meetings the map already connects to this one.
    case related

    var id: String { rawValue }

    var title: String {
        switch self {
        case .recent: "Earlier"
        case .samePeople: "Same people"
        case .sameTopic: "Same topic"
        case .related: "Related"
        }
    }

    var symbol: String {
        switch self {
        case .recent: "clock"
        case .samePeople: "person.2"
        case .sameTopic: "tag"
        case .related: "point.3.connected.trianglepath.dotted"
        }
    }

    /// The question, in the person's own words — what a person is asking when they pick
    /// this, rather than what the code calls it.
    var question: String {
        switch self {
        case .recent: "What else did we record?"
        case .samePeople: "Who else was in the room with them?"
        case .sameTopic: "What did we already say about this?"
        case .related: "What else is connected to this meeting?"
        }
    }

    /// The one-line `.help()` for the control. For the two filters with a switch, it says
    /// what they need, so a person finds out before the list comes back empty.
    var help: String {
        switch self {
        case .recent: "Your most recent meetings, newest first."
        case .samePeople: "Meetings with at least one of the same people. Always available."
        case .sameTopic: "Looks through the words your meetings said. Needs searching turned on."
        case .related: "Follows the map of people, projects and topics. Needs the map turned on."
        }
    }
}

/// The query behind the panel that opens during a meeting: which earlier meetings are
/// worth looking at, and why.
///
/// Four filters, three sources, and a hard rule underneath all of them — **a filter that
/// cannot answer says so instead of answering a different question.** `.recent` and
/// `.samePeople` are a pass over the user's own meeting folders and answer on a Mac with
/// every switch off. `.sameTopic` needs the search index, `.related` needs the map, and
/// each returns nothing when its switch is off: `samePeople` standing in for `related`
/// would put a confidently-labelled row in front of somebody who asked about a project.
///
/// The order `hits` returns is each filter's own answer to its own question — newest first
/// for `.recent`, most shared people first for `.samePeople`, strongest passage first for
/// `.sameTopic`, strongest connection first for `.related` — with the date and
/// `matchCount` breaking ties. The caller is free to re-sort.
struct MeetingRecall: Sendable {
    enum Availability: Equatable, Sendable {
        case ready
        /// The knowledge index is switched off.
        case needsIndex
        /// This filter needs the map, which is switched off.
        case needsGraph
    }

    /// Can this filter answer at all right now? Pure, and it reads no store: the switches
    /// are the whole answer, so a view can ask before it searches and grey a control out
    /// rather than pressing it and being told nothing came back.
    ///
    /// It is the switches and not the state of the library, so `.ready` is a claim about
    /// this filter's *prerequisites*, never about there being anything to find — a filter
    /// whose prerequisite is on but whose index has not been built yet still answers `[]`,
    /// and the empty state is the honest thing to show in both cases.
    static func availability(indexEnabled: Bool, graphEnabled: Bool, filter: MeetingRecallFilter) -> Availability {
        switch filter {
        case .recent, .samePeople:
            // The honest floor: `MeetingStore` is the user's own folder list, so these two
            // need nothing switched on and nothing downloaded.
            return .ready
        case .sameTopic:
            return indexEnabled ? .ready : .needsIndex
        case .related:
            // The map is only built while the index is on, so "the map is off" and "the
            // index is off" are different sentences and the index is the first one to fix.
            guard indexEnabled else { return .needsIndex }
            return graphEnabled ? .ready : .needsGraph
        }
    }

    /// Passages fetched per row of the list. A transcript is dozens of passages long, so a
    /// limit of one row's worth would rank by whichever meeting owned the single best
    /// passage and never mention the other four.
    static let topicOverFetch = 4

    /// How many people a `.related` answer follows. `personMeetings` is pure SQL and
    /// expands entity merges, but it also loads each meeting's decisions and action items,
    /// which this answer never shows — and somebody in a meeting is waiting for the list.
    static let relatedPeopleCap = 6

    /// How many project, organization and topic nodes a `.related` answer expands, in
    /// total, for both the meeting's own nodes and the ones its title matches.
    static let relatedThingCap = 8

    /// The list. `async` because `prepare` may wait on an embedder actor; the SQL itself
    /// runs off the main actor, which is where this is called from.
    ///
    /// Never includes `meeting` itself, and never crashes on a meeting whose folder was
    /// deleted between the read and the row: a row that opens nothing is skipped.
    static func hits(meeting: Meeting, filter: MeetingRecallFilter, indexer: KnowledgeIndexer,
                     store: MeetingStore, limit: Int) async -> [MeetingRecallHit] {
        guard limit > 0 else { return [] }
        let cap = min(limit, 200)
        switch filter {
        case .recent, .samePeople:
            // `MeetingStore` keeps its list newest first, and both answers are a pass over
            // an in-memory array: no index, no model, no SQL, nothing to wait for.
            let meetings = await store.meetings
            return filter == .recent
                ? recentHits(in: meetings, current: meeting, limit: cap, now: Date())
                : samePeopleHits(in: meetings, current: meeting, limit: cap)
        case .sameTopic:
            // The switch, not the searcher's existence: `indexer.searcher` answers whether
            // the index is switched on, and searching an index the person has turned off
            // would answer a question they declined to ask.
            guard await indexer.settings.enabled else { return [] }
            let searcher = await indexer.searcher
            let meetings = await store.meetings
            return await topicHits(title: meeting.title, meetings: meetings, current: meeting.id,
                                   searcher: searcher, limit: cap)
        case .related:
            // `graph` is nil unless the map is switched on *and* built, which is the
            // answer to "can this filter run" that no pair of switches can give.
            guard let graph = await indexer.graph else { return [] }
            let meetings = await store.meetings
            return await relatedHits(graph: graph, current: meeting, meetings: meetings, limit: cap)
        }
    }

    /// A short sentence naming why the list is short, in words a person can act on. The UI
    /// renders this verbatim in the empty state, so it is written to be read rather than
    /// to be debugged: no switch's internal name, and no word the Settings pane does not
    /// put in front of them.
    nonisolated static func reasonUnavailable(_ availability: Availability) -> String {
        switch availability {
        case .ready: "Nothing earlier shows up yet."
        case .needsIndex:
            "Looking through what your meetings said is switched off. Turn it on in Settings, under Agent."
        case .needsGraph:
            "The map of your meetings is switched off. Turn it on in Settings, under Agent."
        }
    }

    // MARK: - Earlier

    /// The newest meetings other than this one, each carrying when it happened.
    private static func recentHits(in meetings: [Meeting], current: Meeting, limit: Int,
                                   now: Date) -> [MeetingRecallHit] {
        meetings
            .filter { $0.id != current.id }
            .prefix(limit)
            .map { meeting in
                MeetingRecallHit(meetingID: meeting.id, title: meeting.title, at: meeting.start,
                                 why: whyEarlier(meeting.start, now: now), people: [], matchCount: 0)
            }
    }

    /// A meeting's date the way a person would say it out loud.
    ///
    /// `RelativeDateTimeFormatter` is what the app already uses for relative time —
    /// `AgentInspectorWording.relativeAge` is its abbreviated sibling for a 340pt row —
    /// read here at full width, because `why` is prose and "2d ago" is not a thing anybody
    /// says out loud.
    ///
    /// A meeting that has not happened yet gets the plain date instead, and so does one
    /// that has only just: M-11 lets a recording begin early when a call is detected before
    /// the calendar's start, and the formatter rounds to its own units, so both can read
    /// "in 3 days" and "in 0 seconds" — a time away, in a list of meetings that already
    /// happened.
    private static func whyEarlier(_ start: Date, now: Date) -> String {
        let plain = start.formatted(date: .abbreviated, time: .omitted)
        guard start <= now else { return plain }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        let phrase = formatter.localizedString(for: start, relativeTo: now)
        guard !phrase.lowercased().hasPrefix("in "), let first = phrase.first else { return plain }
        return first.uppercased() + phrase.dropFirst()
    }

    // MARK: - Same people

    /// Meetings that shared at least one of this meeting's people, most shared first.
    private static func samePeopleHits(in meetings: [Meeting], current: Meeting,
                                      limit: Int) -> [MeetingRecallHit] {
        var rows: [(hit: MeetingRecallHit, shared: Int)] = []
        for meeting in meetings where meeting.id != current.id {
            let shared = sharedPeople(in: current, and: meeting)
            guard !shared.isEmpty else { continue }
            rows.append((MeetingRecallHit(meetingID: meeting.id, title: meeting.title, at: meeting.start,
                                          why: whySamePeople(shared), people: shared,
                                          matchCount: shared.count), shared.count))
        }
        return rows
            .sorted { $0.shared != $1.shared ? $0.shared > $1.shared : $0.hit.at > $1.hit.at }
            .prefix(limit)
            .map(\.hit)
    }

    /// The attendees both meetings had, in the current meeting's own spelling and order.
    ///
    /// A name reaches a meeting from a calendar, from a speaker rename and from a typed
    /// dialog, so "Nico M." and "nico  m." are the same person here. Trimmed, whitespace
    /// folded and case-insensitive — and nothing more, because a looser match would put a
    /// stranger in a row that claims they were in the room.
    private static func sharedPeople(in current: Meeting, and other: Meeting) -> [String] {
        let theirs = Set(other.attendees.map(Self.normalizedName).filter { !$0.isEmpty })
        guard !theirs.isEmpty else { return [] }
        var seen = Set<String>()
        return current.attendees.filter { attendee in
            let key = Self.normalizedName(attendee)
            guard !key.isEmpty, theirs.contains(key), seen.insert(key).inserted else { return false }
            return true
        }
    }

    private static func normalizedName(_ name: String) -> String {
        name.split(whereSeparator: \.isWhitespace).joined(separator: " ").lowercased()
    }

    /// "3 of the same people" — and the one-person case in words, because "1 of the same
    /// people" is arithmetic, not a sentence.
    private static func whySamePeople(_ people: [String]) -> String {
        people.count == 1 ? "\(people[0]) was in both" : "\(people.count) of the same people"
    }

    // MARK: - Same topic

    /// One meeting's passages, collapsed: the strongest passage and how many matched.
    struct TopicSignal: Sendable {
        var best: KnowledgeHit
        var count: Int
    }

    /// One search pass, collapsed to one entry per meeting: the best passage's `score` is
    /// the rank (BM25 reports lower as better) and the count is what the list sorts on.
    ///
    /// Empty whenever the search throws, and empty for a query with no words or no other
    /// meeting to look in. Both are answers, not failures — the caller renders the honest
    /// empty state, which is the whole reason this returns a dictionary and not a guess.
    static func topicSignals(text: String, sourceIDs: Set<String>, searcher: any KnowledgeSearching,
                             limit: Int) async -> [String: TopicSignal] {
        guard !sourceIDs.isEmpty, !KnowledgeFTSQuery.tokens(text).isEmpty else { return [:] }
        let query = KnowledgeQuery(
            text: text,
            filter: KnowledgeFilter(kinds: [.transcript, .notes], sourceIDs: sourceIDs),
            limit: max(1, limit) * topicOverFetch
        )
        // The two-step shape is deliberate and is `KnowledgeSearchView.runSearch`'s: the
        // embedding may wait on a model actor, the SQL must not run on the main actor.
        let prepared = await searcher.prepare(query)
        let found = await Task.detached(priority: .userInitiated) { () -> [KnowledgeHit] in
            (try? searcher.search(prepared)) ?? []
        }.value

        var signals: [String: TopicSignal] = [:]
        for hit in found {
            guard let existing = signals[hit.sourceID] else {
                signals[hit.sourceID] = TopicSignal(best: hit, count: 1)
                continue
            }
            signals[hit.sourceID] = TopicSignal(
                best: hit.score < existing.best.score ? hit : existing.best,
                count: existing.count + 1
            )
        }
        return signals
    }

    /// The meetings whose own words match this meeting's title.
    private static func topicHits(title: String, meetings: [Meeting], current: UUID,
                                  searcher: any KnowledgeSearching, limit: Int) async -> [MeetingRecallHit] {
        let others = meetings.filter { $0.id != current }
        let signals = await topicSignals(text: title, sourceIDs: Set(others.map { $0.id.uuidString }),
                                         searcher: searcher, limit: limit)
        guard !signals.isEmpty else { return [] }
        let known = Dictionary(others.map { ($0.id.uuidString, $0) }, uniquingKeysWith: { first, _ in first })
        var rows: [(hit: MeetingRecallHit, score: Double)] = []
        for (sourceID, signal) in signals {
            // A passage belonging to a meeting whose folder has since been deleted: the
            // store, not the index, says a meeting exists, so the row is skipped rather
            // than offered and unopenable.
            guard let meeting = known[sourceID] else { continue }
            rows.append((MeetingRecallHit(meetingID: meeting.id, title: meeting.title, at: meeting.start,
                                          why: whySameTopic(signal), people: [],
                                          matchCount: signal.count), signal.best.score))
        }
        return rows
            .sorted { $0.score != $1.score ? $0.score < $1.score
                : ($0.hit.matchCount != $1.hit.matchCount ? $0.hit.matchCount > $1.hit.matchCount
                    : $0.hit.at > $1.hit.at) }
            .prefix(limit)
            .map(\.hit)
    }

    /// The strongest passage's own section when it has one: "Same topic: Decisions" is a
    /// reason somebody can check, where a bare "Same topic" only asserts that the words
    /// appeared somewhere.
    private static func whySameTopic(_ signal: TopicSignal) -> String {
        let heading = signal.best.heading?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return heading.isEmpty ? "Same topic" : "Same topic: \(heading)"
    }

    // MARK: - Related

    /// How two meetings are connected, strongest first. Somebody who was in the room is a
    /// stronger claim than a project both mention, and the row says which one it is.
    ///
    /// `Hashable` because the same connection is reached by more than one route — a topic
    /// the meeting's own nodes name, and the same topic its title matches — and a meeting
    /// connected two ways must not read as four.
    private enum Connection: Hashable, Sendable {
        case person(String)
        case project(String)
        case organization(String)
        case topic(String)

        var strength: Int {
            switch self {
            case .person: 0
            case .project: 1
            case .organization: 2
            case .topic: 3
            }
        }

        var phrase: String {
            switch self {
            case .person(let name): "\(name) was in both"
            case .project(let name): "Same project: \(name)"
            case .organization(let name): "Same organization: \(name)"
            case .topic(let label): "Same topic: \(label)"
            }
        }
    }

    /// The map, in two hops and with no model: the meeting's own node, then the people,
    /// projects, organizations and topics it touches. Each person's meetings are one SQL
    /// read over their `attended` edges (`GraphStore.personMeetings`, which expands entity
    /// merges), and each thing's meetings are one more expansion. The title then finds the
    /// topics that share a word with it (`relatedNodes(matching:)`), which is the only way a
    /// meeting nobody annotated with topics connects to anything.
    private static func relatedHits(graph: GraphStore, current: Meeting, meetings: [Meeting],
                                    limit: Int) async -> [MeetingRecallHit] {
        let currentID = current.id.uuidString
        // The store, not the graph, says a meeting exists: a graph row outlives the folder
        // it came from until the next backfill, and a row that opens nothing is worse than
        // a missing one.
        var known: [String: Meeting] = [:]
        for meeting in meetings where meeting.id != current.id { known[meeting.id.uuidString] = meeting }

        let signals = await Task.detached(priority: .userInitiated) { () -> [String: [Connection]] in
            var found: [String: [Connection]] = [:]
            func note(_ nodeID: String, _ connection: Connection) {
                guard let meetingID = Self.meetingID(fromNode: nodeID), meetingID != currentID else { return }
                var existing = found[meetingID] ?? []
                guard !existing.contains(connection) else { return }
                existing.append(connection)
                found[meetingID] = existing
            }
            do {
                let expansion = try graph.expand(nodeID: GraphIDs.meeting(currentID), edgeTypes: [], depth: 1)
                // The people in this meeting's room first, then whoever else its transcript
                // named: "Nico M. was in both" is the connection the person is looking for.
                let inRoom = Set(current.attendees.map(GraphIDs.person))
                let people = expansion.nodes
                    .filter { $0.id.hasPrefix("person:") }
                    .sorted { lhs, rhs in
                        let left = inRoom.contains(lhs.id), right = inRoom.contains(rhs.id)
                        return left == right ? lhs.id < rhs.id : left
                    }
                    .prefix(relatedPeopleCap)
                for node in people {
                    for moment in try graph.personMeetings(personID: node.id) {
                        note(GraphIDs.meeting(moment.meetingID), .person(node.label))
                    }
                }
                var things = 0
                for node in expansion.nodes {
                    guard things < relatedThingCap, let connection = Self.connection(for: node) else { continue }
                    // A person is the loop above; expanding one here would ask the same
                    // question of the same node twice.
                    if case .person = connection { continue }
                    things += 1
                    for other in try graph.expand(nodeID: node.id, edgeTypes: [], depth: 1).nodes {
                        note(other.id, connection)
                    }
                }
                for node in try graph.relatedNodes(matching: current.title, limit: relatedThingCap) {
                    // Only a topic. A person or project the title merely shares a word with is
                    // `samePeople` and `sameTopic`'s question, and answering it here would
                    // make this filter claim something it never looked for.
                    guard let connection = Self.connection(for: node), case .topic = connection else { continue }
                    for other in try graph.expand(nodeID: node.id, edgeTypes: [], depth: 1).nodes {
                        note(other.id, connection)
                    }
                }
            } catch {
                // A read that failed is not a connection. Half a list of claimed
                // relationships this slice could not finish checking is the one answer it
                // must never give, so the whole answer goes.
                return [:]
            }
            return found
        }.value

        var rows: [(hit: MeetingRecallHit, strength: Int)] = []
        for (sourceID, connections) in signals {
            guard let meeting = known[sourceID], let strongest = connections.min(by: { $0.strength < $1.strength })
            else { continue }
            var seen = Set<String>()
            rows.append((MeetingRecallHit(
                meetingID: meeting.id, title: meeting.title, at: meeting.start, why: strongest.phrase,
                people: connections.compactMap { connection in
                    guard case .person(let name) = connection else { return nil }
                    return seen.insert(name).inserted ? name : nil
                },
                matchCount: connections.count
            ), strongest.strength))
        }
        return rows
            .sorted { $0.strength != $1.strength ? $0.strength < $1.strength
                : ($0.hit.matchCount != $1.hit.matchCount ? $0.hit.matchCount > $1.hit.matchCount
                    : $0.hit.at > $1.hit.at) }
            .prefix(limit)
            .map(\.hit)
    }

    /// Which connection a node is, from the id prefix `GraphIDs` writes. The *label* is the
    /// name to show, never the slug: `person:nicola-moretti` is not something to put in
    /// front of a person.
    private static func connection(for node: KnowledgeGraphNode) -> Connection? {
        let label = node.label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !label.isEmpty else { return nil }
        switch node.id.split(separator: ":", maxSplits: 1).first.map(String.init) {
        case "person": return .person(label)
        case "project": return .project(label)
        case "org": return .organization(label)
        case "topic": return .topic(label)
        default: return nil
        }
    }

    /// The meeting a `meeting:<uuid>` node names, or nil for any other node — including a
    /// decision, an action item and the meeting the expansion started from.
    private static func meetingID(fromNode nodeID: String) -> String? {
        guard nodeID.hasPrefix("meeting:") else { return nil }
        let raw = String(nodeID.dropFirst("meeting:".count))
        return UUID(uuidString: raw) != nil ? raw : nil
    }
}
