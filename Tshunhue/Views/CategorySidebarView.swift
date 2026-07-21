import SwiftUI

struct CategorySidebarView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        List {
            Button {
                model.showAllCategories()
            } label: {
                Label("All Enabled", systemImage: model.selectedCategories.isEmpty ? "checkmark.circle.fill" : "circle")
            }
            .buttonStyle(.plain)

            ForEach(model.sources) { source in
                let enabled = source.categories.filter { source.enabledCategoryIDs.contains($0.id) }
                if !enabled.isEmpty {
                    Section(source.name) {
                        ForEach(enabled) { category in
                            let key = CategoryKey(sourceURL: source.sourceURL, categoryID: category.id)
                            Button {
                                model.toggleFilter(key)
                            } label: {
                                HStack {
                                    Image(systemName: model.selectedCategories.contains(key) ? "checkmark.circle.fill" : "circle")
                                    VStack(alignment: .leading) {
                                        Text(category.name)
                                        if let language = category.language {
                                            Text(language)
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
        .navigationTitle("Categories")
    }
}
