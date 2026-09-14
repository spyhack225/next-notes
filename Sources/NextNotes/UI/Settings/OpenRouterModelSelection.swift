import SwiftUI

/// Shared searchable catalog for the independent Agent and meeting choices.
struct OpenRouterModelSelection: View {
    @Binding var modelID: String
    @Binding var contextTokens: Int
    @State private var catalog = OpenRouterCatalog.shared
    @State private var query = ""
    @State private var filter = OpenRouterModelFilter.all
    @State private var provider = "All providers"

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
            if catalog.isLoading { ProgressView("Loading OpenRouter models…") }
            if let problem = catalog.problem {
                Text(problem).foregroundStyle(DS.Color.warning)
            }
            if !catalog.isLoading && catalog.models.isEmpty {
                Button("Load models") { Task { await catalog.refresh() } }
            }
            ForEach(Array(matches.prefix(DS.Size.openRouterVisibleModels))) { model in
                Button {
                    modelID = model.id
                    contextTokens = model.context_length ?? 8_192
                } label: {
                    HStack(alignment: .top, spacing: DS.Space.s) {
                        Image(systemName: modelID == model.id ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(modelID == model.id ? DS.Color.success : DS.Color.textSecondary)
                        VStack(alignment: .leading, spacing: DS.Space.xxs) {
                            Text(model.name).font(DS.Font.callout)
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
        }
        .task {
            if catalog.models.isEmpty && OpenRouterKeyStore.key != nil {
                await catalog.refresh()
            }
        }
    }

    private var providerNames: [String] {
        Array(Set(catalog.models.filter(\.isTextModel).map(\.providerName))).sorted()
    }

    private var matches: [OpenRouterModel] {
        catalog.models.filter { model in
            filter.includes(model)
                && (provider == "All providers" || model.providerName == provider)
                && (query.isEmpty || model.name.localizedCaseInsensitiveContains(query)
                    || model.id.localizedCaseInsensitiveContains(query)
                    || model.description?.localizedCaseInsensitiveContains(query) == true)
        }
    }
}
