//
//  CategorySidebarView.swift
//  Tshunhue
//
//  Presents recent, index, and category browsing scopes.
//

import SwiftUI

/// A flat browse-scope list shared by the macOS sidebar and iOS filter sheet.
struct CategorySidebarView: View {
    /// The application model whose selected scope this view controls.
    @ObservedObject var model: AppModel

    var body: some View {
        List {
            scopeRow(.recents, title: String(localized: "Recents"), systemImage: "clock")
            scopeRow(.all, title: String(localized: "All"), systemImage: "square.grid.2x2")

            Section("Indices") {
                ForEach(model.sources.filter { !$0.enabledCategoryIDs.isEmpty }) { source in
                    scopeRow(.index(source.sourceURL), title: source.name, systemImage: "movieclapper")
                }
            }

            Section("Categories") {
                ForEach(model.sources) { source in
                    ForEach(source.categories.filter { source.enabledCategoryIDs.contains($0.id) }) { category in
                        let key = CategoryKey(sourceURL: source.sourceURL, categoryID: category.id)
                        let name = category.name.hasPrefix(source.name) ? String(category.name.dropFirst(source.name.count).trimmingCharacters(in: .whitespaces)) : category.name
                        scopeRow(.category(key), title: name, systemImage: "film.stack")
                    }
                }
            }
        }
        .navigationTitle("Browse")
    }

    /// Builds a selectable row for a browse scope.
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

    /// Highlights the active browse scope without changing list structure.
    private func rowBackground(for scope: CatalogScope) -> some View {
        RoundedRectangle(cornerRadius: 6)
            .fill(model.selectedScope == scope ? Color.accentColor.opacity(0.18) : Color.clear)
    }
}

#if DEBUG
#Preview("Browse Scopes") {
    CategorySidebarView(model: PreviewData.model())
        .frame(idealWidth: 280, idealHeight: 520)
}
#endif
