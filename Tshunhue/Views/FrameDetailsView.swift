//
//  FrameDetailsView.swift
//  Tshunhue
//
//  Displays a frame's metadata, destinations, and transfer actions.
//

import SwiftUI

/// The details presentation used by the macOS inspector and iOS navigation.
struct FrameDetailsView: View {
    /// The frame whose metadata is displayed.
    let frame: CatalogFrame
    /// The model used for report links and transfer actions.
    @ObservedObject var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("“\(frame.frame.caption)”")
                    .font(.title.bold())
                    .textSelection(.enabled)
                    .padding(.bottom, -6)

                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(frame.categoryName)
                        .accessibilityLabel("Category")
                    if let subsection = frame.subsection {
                        Text("·")
                        Text(subsection.name)
                    }
                }
                .foregroundStyle(.secondary)

                ZStack(alignment: .bottomLeading) {
                    FrameThumbnailView(frame: frame, repository: model.imageRepository, large: true)

                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        if let timecode = frame.frame.timecode {
                            Text(timecode.displayString)
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.white)
                                .shadow(radius: 2, x: 0, y: 1)
                        }
                        Spacer()
                        if !frame.tags.isEmpty {
                            ForEach(frame.tags, id: \.self) { tag in
                                Text(tag)
                                    .font(.caption.weight(.medium))
                                    .foregroundStyle(.white.opacity(0.85))
                                    .shadow(radius: 2, x: 0, y: 1)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(.white.opacity(0.25))
                                    .clipShape(Capsule())
                            }
                        }
                    }
                    .padding(.vertical, 8)
                    .padding(.horizontal, 12)
                }

                HStack {
                    Button("Copy", systemImage: "doc.on.doc") {
                        Task { await model.copy(frame) }
                    }
                    .buttonStyle(.borderedProminent)

                    shareButton()
                }
                .controlSize(.large)
                .buttonSizing(.flexible)
                .buttonStyle(.bordered)

                if !frame.providers.isEmpty {
                    ForEach(Array(frame.providers.enumerated()), id: \.offset) { _, provider in
                        if let url = provider.destination(for: frame.frame.timecode) {
                            Link(destination: url) {
                                Label(provider.name, systemImage: "play.rectangle")
                            }
                        }
                    }
                    .buttonStyle(.bordered)
                    .buttonSizing(.flexible)
                }

                Divider()
                    .padding(.vertical, 6)

                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    if let attribution = frame.attribution {
                        if let url = attribution.url.flatMap(URL.init(string:)) {
                            Link(destination: url) {
                                Label(attribution.text, systemImage: "arrow.up.forward.square")
                            }
                                .accessibilityLabel("Attribution")
                        } else {
                            Text(attribution.text)
                        }
                    }
                    Spacer()
                    #if os(macOS)
                    if let reportURL = model.reportURL(for: frame) {
                        reportButton(url: reportURL)
                    }
                    #endif
                }
                .foregroundStyle(.secondary)

            }
            .padding()
            #if os(iOS)
            .toolbar {
                if let reportURL = model.reportURL(for: frame) {
                    ToolbarItem(placement: .secondaryAction) {
                        reportButton(url: reportURL)
                    }
                }

                ToolbarItem(placement: .primaryAction) {
                    shareButton()
                }
            }
            #endif
        }
        .navigationTitle("Details")
        #if !os(macOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    private func shareButton() -> some View {
        ShareLink(item: model.transferItem(for: frame), preview: SharePreview(frame.frame.caption))
    }

    private func reportButton(url: URL) -> some View {
        Link(destination: url) {
            Label("Report", systemImage: "exclamationmark.bubble")
                .labelStyle(.iconOnly)
                .help("Report This Item")
        }
    }
}

#if DEBUG
#Preview("Frame Details") {
    FrameDetailsView(frame: PreviewData.frame, model: PreviewData.model())
        .frame(idealWidth: 360, idealHeight: 640)
}
#endif
