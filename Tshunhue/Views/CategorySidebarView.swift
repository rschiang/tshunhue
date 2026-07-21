import SwiftUI

struct CategorySidebarView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        List {
            scopeRow(.recents, title: String(localized: "Recents"), systemImage: "clock")
            scopeRow(.all, title: String(localized: "All"), systemImage: "square.grid.2x2")

            Section("Indices") {
                ForEach(model.sources.filter { !$0.enabledCategoryIDs.isEmpty }) { source in
                    scopeRow(.index(source.sourceURL), title: source.name, systemImage: "books.vertical")
                }
            }

            Section("Categories") {
                ForEach(model.sources) { source in
                    ForEach(source.categories.filter { source.enabledCategoryIDs.contains($0.id) }) { category in
                        let key = CategoryKey(sourceURL: source.sourceURL, categoryID: category.id)
                        Button {
                            model.selectedScope = .category(key)
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(category.name)
                                Text(categoryDescription(category, source: source))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        .listRowBackground(rowBackground(for: .category(key)))
                        .accessibilityAddTraits(model.selectedScope == .category(key) ? .isSelected : [])
                    }
                }
            }
        }
        .navigationTitle("Browse")
    }

    private func scopeRow(_ scope: CatalogScope, title: String, systemImage: String) -> some View {
        Button {
            model.selectedScope = scope
        } label: {
            Label {
                Text(title)
            } icon: {
                Image(systemName: systemImage)
            }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .listRowBackground(rowBackground(for: scope))
        .accessibilityAddTraits(model.selectedScope == scope ? .isSelected : [])
    }

    private func rowBackground(for scope: CatalogScope) -> some View {
        RoundedRectangle(cornerRadius: 6)
            .fill(model.selectedScope == scope ? Color.accentColor.opacity(0.18) : Color.clear)
    }

    private func categoryDescription(_ category: CategoryDescriptor, source: SourceSummary) -> String {
        guard let language = category.language else { return source.name }
        return "\(source.name) · \(language)"
    }
}
