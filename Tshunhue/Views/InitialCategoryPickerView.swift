//
//  InitialCategoryPickerView.swift
//  Tshunhue
//
//  Guides first-run users through choosing searchable categories.
//

import SwiftUI

/// The navigation-neutral content of the first-run category selection sheet.
struct InitialCategoryPickerView: View {
    /// The model used to enable categories.
    @ObservedObject var model: AppModel
    /// Dismisses the app-level onboarding sheet.
    var onDismiss: () -> Void

    var body: some View {
        List {
            Section {
                Text("Choose the categories whose captions you want to search. Only metadata downloads now; images remain on demand.")
                    .foregroundStyle(.secondary)
            }
            ForEach(model.sources) { source in
                Section(source.name) {
                    CategorySelectionRows(model: model, source: source)
                }
            }
        }
        .navigationTitle("Choose Categories")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Later", action: onDismiss)
                    .disabled(model.hasPendingCategoryUpdates)
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Done", action: onDismiss)
                    .disabled(!hasEnabledCategory || model.hasPendingCategoryUpdates)
            }
        }
        #if os(macOS)
        .frame(idealWidth: 520, idealHeight: 480)
        #endif
    }

    /// Whether persisted or pending selections contain at least one enabled category.
    private var hasEnabledCategory: Bool {
        model.sources.contains { source in
            source.categories.contains { model.isCategoryEnabled($0, in: source) }
        }
    }
}

#if DEBUG
#Preview("Initial Category Picker") {
    NavigationStack {
        InitialCategoryPickerView(model: PreviewData.model(), onDismiss: {})
    }
}
#endif
