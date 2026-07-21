import SwiftUI

struct FrameDetailsView: View {
    let frame: CatalogFrame
    @ObservedObject var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                FrameThumbnailView(frame: frame, repository: model.imageRepository, large: true)
                Text(frame.frame.caption)
                    .font(.title2.weight(.semibold))
                    .textSelection(.enabled)
                LabeledContent("Source", value: frame.sourceName)
                LabeledContent("Category", value: frame.categoryName)
                if let subsection = frame.subsection {
                    LabeledContent("Subsection", value: subsection.name)
                }
                if let timecode = frame.frame.timecode {
                    LabeledContent("Timecode", value: timecode.displayString)
                }
                if !frame.tags.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Tags").foregroundStyle(.secondary)
                        Text(frame.tags.joined(separator: " · "))
                            .textSelection(.enabled)
                    }
                }
                if let attribution = frame.attribution {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Attribution").foregroundStyle(.secondary)
                        if let url = attribution.url.flatMap(URL.init(string:)) {
                            Link(attribution.text, destination: url)
                        } else {
                            Text(attribution.text)
                        }
                    }
                }
                if !frame.providers.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Watch").foregroundStyle(.secondary)
                        ForEach(Array(frame.providers.enumerated()), id: \.offset) { _, provider in
                            if let url = provider.destination(for: frame.frame.timecode) {
                                Link(destination: url) {
                                    Label(provider.name, systemImage: "play.rectangle")
                                }
                            }
                        }
                    }
                }
                Link(destination: frame.imageURL) {
                    Label("Open Image URL", systemImage: "link")
                }
                if let reportURL = model.reportURL(for: frame) {
                    Link(destination: reportURL) {
                        Label("Report This Item", systemImage: "exclamationmark.bubble")
                    }
                    .foregroundStyle(.secondary)
                }
                HStack {
                    Button("Copy", systemImage: "doc.on.doc") { Task { await model.copy(frame) } }
                    ShareLink(item: model.transferItem(for: frame), preview: SharePreview(frame.frame.caption))
                }
                .buttonStyle(.bordered)
            }
            .padding()
        }
        .navigationTitle("Details")
    }
}
