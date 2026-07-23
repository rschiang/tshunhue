//
//  CategorySelectionRows.swift
//  Tshunhue
//
//  Presents reusable category toggles with localized catalog metadata.
//

import SwiftUI

/// Category-selection rows shared by onboarding and source settings.
struct CategorySelectionRows: View {
    /// The model that persists category selections.
    @ObservedObject var model: AppModel
    /// The source whose categories the rows represent.
    let source: SourceSummary

    @Environment(\.locale) private var locale

    var body: some View {
        ForEach(source.categories) { category in
            Toggle(isOn: Binding(
                get: { model.isCategoryEnabled(category, in: source) },
                set: { enabled in
                    Task { await model.setCategory(category, in: source, enabled: enabled) }
                }
            )) {
                HStack {
                    VStack(alignment: .leading) {
                        Text(category.name)
                        if let details = details(for: category) {
                            Text(verbatim: details)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    if model.isUpdatingCategory(category, in: source) {
                        Spacer()
                        ProgressView()
                    }
                }
            }
            .disabled(model.isWorking || model.isUpdatingCategory(category, in: source))
        }
    }

    /// Joins independently localized metadata without localizing its separator.
    private func details(for category: CategoryDescriptor) -> String? {
        let language = category.language.map {
            locale.localizedString(forIdentifier: $0) ?? $0
        }
        let frames = category.frames.map {
            String(localized: "\($0) frames", locale: locale)
        }
        let parts = [language, frames].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

#if DEBUG
#Preview("Category Selection Rows") {
    Form {
        Section(PreviewData.source.name) {
            CategorySelectionRows(model: PreviewData.model(), source: PreviewData.source)
        }
    }
    .formStyle(.grouped)
}
#endif
