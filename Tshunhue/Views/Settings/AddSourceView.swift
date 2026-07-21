//
//  AddSourceView.swift
//  Tshunhue
//
//  Collects and validates a custom catalog source URL.
//

import SwiftUI

/// A sheet for validating and adding a custom HTTPS index URL.
struct AddSourceView: View {
    /// The model used to create the source.
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var sourceURL = ""

    var body: some View {
        NavigationStack {
            Form {
                TextField("https://example.com/index.json", text: $sourceURL)
                    .textContentType(.URL)
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                    #endif
                Text("Tshunhue validates default and custom sources using the same rules. Images download only when displayed or transferred.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .formStyle(.grouped)
            .navigationTitle("Add Source")
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
        #if os(macOS)
        .frame(idealWidth: 440, idealHeight: 240)
        #endif
    }
}

#if DEBUG
#Preview("Add Source") {
    AddSourceView(model: PreviewData.model())
}
#endif
