import SwiftUI

struct InitialCategoryPickerView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("Choose the categories whose captions you want to search. Only metadata downloads now; images remain on demand.")
                        .foregroundStyle(.secondary)
                }
                ForEach(model.sources) { source in
                    Section(source.name) {
                        ForEach(source.categories) { category in
                            Toggle(isOn: Binding(
                                get: { source.enabledCategoryIDs.contains(category.id) },
                                set: { enabled in
                                    Task { await model.setCategory(category, in: source, enabled: enabled) }
                                }
                            )) {
                                VStack(alignment: .leading) {
                                    Text(category.name)
                                    HStack {
                                        if let language = category.language {
                                            Text(language)
                                        }
                                        if let count = category.frames {
                                            if category.language == nil {
                                                Text("\(count) frames")
                                            } else {
                                                Text("· \(count) frames")
                                            }
                                        }
                                    }
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                }
                            }
                            .disabled(model.isWorking)
                        }
                    }
                }
            }
            .navigationTitle("Choose Categories")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Later") { model.needsCategorySelection = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { model.needsCategorySelection = false }
                        .disabled(model.sources.allSatisfy { $0.enabledCategoryIDs.isEmpty })
                }
            }
        }
        .frame(minWidth: 520, minHeight: 480)
    }
}
