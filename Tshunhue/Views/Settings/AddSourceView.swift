//
//  AddSourceView.swift
//  Tshunhue
//
//  Collects and validates a custom catalog source URL.
//

import SwiftUI

/// A navigation-neutral form for validating and adding a custom HTTPS index URL.
struct AddSourceView: View {
    /// The model used to create the source.
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var sourceURL = ""

    var body: some View {
        Form {
            TextField("URL", text: $sourceURL)
                .textContentType(.URL)
                #if os(iOS)
                .textInputAutocapitalization(.never)
                .keyboardType(.URL)
                #endif
            Text("Only add sources you trust. Images are downloaded only when displayed or transferred.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
        .navigationTitle("Add Source")
        .navigationBarBackButtonHidden()
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Add") {
                    Task {
                        if await model.addSource(urlString: sourceURL) { dismiss() }
                    }
                }
                .disabled(sourceURL.isEmpty || model.isWorking)
            }
        }
    }
}

#if DEBUG
#Preview("Add Source") {
    NavigationStack {
        AddSourceView(model: PreviewData.model())
    }
}
#endif
