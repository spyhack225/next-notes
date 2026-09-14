import SwiftUI

/// Shared searchable catalog for the independent Agent and meeting choices.
struct OpenRouterModelSelection: View {
    @Binding var modelID: String
    @Binding var contextTokens: Int
    @State private var catalog = OpenRouterCatalog.shared
    @State private var query = ""
    @State private var filter = OpenRouterModelFilter.all
    @State private var provider = "All providers"
    @State private var sort = ModelSort.fastest

    private enum ModelSort: String, CaseIterable, Identifiable {
        case fastest = "OpenRouter speed rank"
        case alphabetical = "Name A–Z"
        var id: String { rawValue }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            LabeledContent("Selected model") {
                Text(catalog.model(id: modelID)?.name ?? (modelID.isEmpty ? "Choose a model" : modelID))
                    .foregroundStyle(modelID.isEmpty ? DS.Color.warning : DS.Color.textSecondary)
            }
            HStack(spacing: DS.Space.s) {
                TextField("Search OpenRouter models", text: $query)
                    .textFieldStyle(.roundedBorder)
                Picker("Capability", selection: $filter) {
                    ForEach(OpenRouterModelFilter.allCases) { option in
                        Text(option.rawValue).tag(option)
                    }
                }
                .labelsHidden()
            }
            Picker("Provider", selection: $provider) {
                Text("All providers").tag("All providers")
                ForEach(providerNames, id: \.self) { name in Text(name).tag(name) }
            }
            Picker("Sort", selection: $sort) {
                ForEach(ModelSort.allCases) { option in
                    Text(option.rawValue).tag(option)
                }
            }
            if catalog.isLoading { ProgressView("Loading OpenRouter models…") }
            if let problem = catalog.problem {
                Text(problem).foregroundStyle(DS.Color.warning)
            }
            if !catalog.isLoading && catalog.models.isEmpty {
                Button("Load models") { Task { await catalog.refresh() } }
            }
            ForEach(visibleModels) { model in
                Button {
                    modelID = model.id
                    contextTokens = model.context_length ?? 8_192
                } label: {
                    HStack(alignment: .top, spacing: DS.Space.s) {
                        Image(systemName: modelID == model.id ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(modelID == model.id ? DS.Color.success : DS.Color.textSecondary)
                        VStack(alignment: .leading, spacing: DS.Space.xxs) {
                            HStack(spacing: DS.Space.s) {
                                Text(model.name).font(DS.Font.callout)
                                Spacer(minLength: DS.Space.s)
                                Text(speedLabel(for: model.id))
                                    .font(DS.Font.caption)
                                    .foregroundStyle(DS.Color.textSecondary)
                                    .help(speedHelp(for: model.id))
                            }
                            Text(model.id)
                                .font(DS.Font.caption)
                                .foregroundStyle(DS.Color.textSecondary)
                            Text(model.tags.joined(separator: " · ") + " · "
                                 + "\((model.context_length ?? 0) / 1_000)K context · "
                                 + model.priceLabel)
                                .font(DS.Font.caption)
                                .foregroundStyle(DS.Color.textSecondary)
                        }
                    }
                }
                .buttonStyle(.plain)
            }
            if matches.count > DS.Size.openRouterVisibleModels {
                Text("Showing \(DS.Size.openRouterVisibleModels) of \(matches.count). Search or narrow the filters to see more.")
                    .font(DS.Font.caption)
                    .foregroundStyle(DS.Color.textSecondary)
            }
            Text("Rates are the fastest provider’s recent median output tok/s. OpenRouter’s speed rank uses its routing estimates, so it may differ from these rates. Actual speed varies with load; a dash means no rate was reported.")
                .font(DS.Font.caption)
                .foregroundStyle(DS.Color.textSecondary)
        }
        .task {
            if !SelfTest.isRunning && catalog.models.isEmpty {
                let hasKey = await OpenRouterKeyStore.hasKeyAsync()
                if hasKey { await catalog.refresh() }
            }
        }
        .task(id: visibleModels.map(\.id)) {
            if !SelfTest.isRunning {
                await catalog.loadSpeeds(for: visibleModels.map(\.id))
            }
        }
    }

    private var providerNames: [String] {
        Array(Set(catalog.models.filter(\.isTextModel).map(\.providerName))).sorted()
    }

    private var matches: [OpenRouterModel] {
        let filtered = catalog.models.filter { model in
            filter.includes(model)
                && (provider == "All providers" || model.providerName == provider)
                && (query.isEmpty || model.name.localizedCaseInsensitiveContains(query)
                    || model.id.localizedCaseInsensitiveContains(query)
                    || model.description?.localizedCaseInsensitiveContains(query) == true)
        }
        if sort == .alphabetical {
            return filtered.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        }
        return filtered
    }

    private var visibleModels: [OpenRouterModel] {
        Array(matches.prefix(DS.Size.openRouterVisibleModels))
    }

    private func speedLabel(for id: String) -> String {
        if let speed = catalog.speeds[id] {
            return String(format: "%.0f tok/s", speed.tokensPerSecond)
        }
        if catalog.failedSpeedIDs.contains(id) { return "Speed error" }
        return catalog.checkedSpeedIDs.contains(id) ? "— tok/s" : "Checking…"
    }

    private func speedHelp(for id: String) -> String {
        if let speed = catalog.speeds[id] {
            return "\(speed.provider) · p50 output tokens per second over the last 30 minutes"
        }
        if catalog.failedSpeedIDs.contains(id) {
            return "Could not load recent throughput. Change the filter or refresh models to try again."
        }
        return catalog.checkedSpeedIDs.contains(id)
            ? "OpenRouter did not report a recent throughput rate for this model."
            : "Loading recent throughput from OpenRouter."
    }
}
