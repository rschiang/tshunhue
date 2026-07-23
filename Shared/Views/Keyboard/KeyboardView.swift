//
//  KeyboardView.swift
//  Tshunhue
//
//  Presents the reusable SwiftUI interface for Tshunhue's iOS keyboard.
//

#if os(iOS)
import SwiftUI
import UIKit

/// A compact keyboard interface driven entirely by an injected observation model.
struct KeyboardView: View {
    @Bindable var model: KeyboardModel
    /// Returns the real extension controller for Apple's input-mode switch action.
    let inputModeController: () -> UIInputViewController?
    /// Inserts one result caption into the host document.
    let insertCaption: (CatalogFrame) -> Void
    /// Inserts a literal space and refreshes the host-derived query.
    let insertSpace: () -> Void
    /// Deletes one host character and refreshes the host-derived query.
    let deleteBackward: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            header
            status
            resultRow
            editingKeys
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
    }

    // MARK: - Header and Status

    /// Displays the host-derived query and the optional category filter.
    private var header: some View {
        HStack(spacing: 8) {
            Label {
                Text(model.query.isEmpty ? "Type in the app, then switch keyboards." : model.query)
                    .foregroundStyle(model.query.isEmpty ? .secondary : .primary)
                    .lineLimit(1)
            } icon: {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
            }
            .font(.callout)
            .frame(maxWidth: .infinity, alignment: .leading)

            categoryMenu
        }
    }

    /// Filters results to all enabled categories or one source-scoped category.
    private var categoryMenu: some View {
        Menu {
            Button {
                model.selectCategory(nil)
            } label: {
                if model.selectedCategory == nil {
                    Label("All", systemImage: "checkmark")
                } else {
                    Text("All")
                }
            }
            ForEach(model.categories) { category in
                Button {
                    model.selectCategory(category.key)
                } label: {
                    if model.selectedCategory == category.key {
                        Label("\(category.name) — \(category.sourceName)", systemImage: "checkmark")
                    } else {
                        Text("\(category.name) — \(category.sourceName)")
                    }
                }
            }
        } label: {
            Label(selectedCategoryName, systemImage: "line.3.horizontal.decrease.circle")
                .labelStyle(.titleAndIcon)
                .lineLimit(1)
        }
        .disabled(model.categories.isEmpty)
        .accessibilityLabel("Filter Category")
    }

    /// The concise mode explanation or current non-blocking action feedback.
    @ViewBuilder
    private var status: some View {
        if let actionMessage = model.actionMessage {
            Label(
                actionMessage,
                systemImage: model.actionMessageIsError
                    ? "exclamationmark.triangle"
                    : "checkmark.circle"
            )
            .foregroundStyle(model.actionMessageIsError ? Color.red : Color.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
        } else if let loadError = model.loadError, !model.results.isEmpty {
            Label(loadError, systemImage: "exclamationmark.triangle")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            Label(modeDescription, systemImage: modeSymbol)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Results

    /// Displays at most four choices in one horizontally scrollable row.
    @ViewBuilder
    private var resultRow: some View {
        if model.isLoading && model.results.isEmpty {
            ProgressView("Loading Tshunhue…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let loadError = model.loadError, model.results.isEmpty {
            compactUnavailable(message: loadError, systemImage: "exclamationmark.triangle")
        } else if model.results.isEmpty {
            compactUnavailable(
                message: model.query.isEmpty ? "No recent images yet." : "No matching reactions.",
                systemImage: model.query.isEmpty ? "clock" : "magnifyingglass"
            )
        } else {
            ScrollView(.horizontal) {
                LazyHStack(spacing: 8) {
                    ForEach(model.results.prefix(KeyboardModel.resultLimit)) { frame in
                        result(for: frame)
                            .frame(minHeight: 88, idealHeight: 100, maxHeight: 112)
                            .containerRelativeFrame(.horizontal, count: 4, spacing: 8)
                    }
                }
            }
            .scrollIndicators(.hidden)
        }
    }

    /// Selects caption-only or image interactions without hiding Text Mode results.
    @ViewBuilder
    private func result(for frame: CatalogFrame) -> some View {
        switch model.accessMode {
        case .text:
            Button {
                insertCaption(frame)
            } label: {
                Text(model.feedback(for: frame) ?? frame.frame.caption)
                    .font(.caption)
                    .multilineTextAlignment(.leading)
                    .lineLimit(4)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(8)
                    .background(.quaternary, in: .rect(cornerRadius: 8))
            }
            .buttonStyle(.plain)
            .accessibilityHint("Inserts this caption")
        case .images:
            imageResult(for: frame)
        }
    }

    /// Adds drag export only when the host environment enables the shared transfer path.
    @ViewBuilder
    private func imageResult(for frame: CatalogFrame) -> some View {
        if let transferItem = model.transferItem(for: frame) {
            imageButton(for: frame)
                .draggable(transferItem)
        } else {
            imageButton(for: frame)
        }
    }

    /// Provides tap-to-copy and SwiftUI's native long-press preview interaction.
    private func imageButton(for frame: CatalogFrame) -> some View {
        Button {
            Task { await model.copy(frame) }
        } label: {
            ZStack(alignment: .bottom) {
                KeyboardFrameImage(frame: frame, model: model, maxPixelSize: 320)
                Text(model.feedback(for: frame) ?? frame.frame.caption)
                    .font(.caption2)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity)
                    .padding(4)
                    .background(.ultraThinMaterial)
            }
            .clipShape(.rect(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Copy Image", systemImage: "doc.on.doc") {
                Task { await model.copy(frame) }
            }
        } preview: {
            KeyboardFrameImage(frame: frame, model: model, maxPixelSize: 960)
                .aspectRatio(16 / 9, contentMode: .fit)
        }
        .accessibilityLabel(frame.frame.caption)
        .accessibilityHint("Copies this image")
    }

    /// A lightweight empty or failure state sized for a system keyboard.
    private func compactUnavailable(message: String, systemImage: String) -> some View {
        Label(message, systemImage: systemImage)
            .font(.callout)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Host Editing Keys

    /// Provides the minimal host-text refinement and required keyboard-switch controls.
    private var editingKeys: some View {
        HStack(spacing: 8) {
            if model.needsInputModeSwitchKey {
                InputModeSwitchButton(controller: inputModeController)
                    .frame(width: 44, height: 36)
            }
            Button(action: insertSpace) {
                Text("space")
                    .frame(maxWidth: .infinity)
            }
            .accessibilityLabel("Space")
            Button(action: deleteBackward) {
                Image(systemName: "delete.left")
                    .frame(width: 44)
            }
            .accessibilityLabel("Delete")
        }
        .buttonStyle(.bordered)
    }

    /// The currently selected category title used by the compact menu label.
    private var selectedCategoryName: String {
        guard let selectedCategory = model.selectedCategory else { return "All" }
        return model.categories.first(where: { $0.key == selectedCategory })?.name ?? "All"
    }

    /// Explains the primary result action without treating optional Full Access as an error.
    private var modeDescription: String {
        switch model.accessMode {
        case .text: "Text Mode — tap a caption to insert it."
        case .images: "Image Mode — tap to copy or hold to preview."
        }
    }

    /// The neutral symbol paired with the current access mode.
    private var modeSymbol: String {
        model.accessMode == .images ? "photo.on.rectangle" : "text.bubble"
    }
}

/// A thumbnail that owns only its cancellable SwiftUI image-loading task.
private struct KeyboardFrameImage: View {
    let frame: CatalogFrame
    let model: KeyboardModel
    let maxPixelSize: Int
    @State private var thumbnail: ImageThumbnail?
    @State private var finishedLoading = false

    var body: some View {
        Group {
            if let thumbnail {
                Image(decorative: thumbnail.image, scale: 1)
                    .resizable()
                    .scaledToFill()
            } else if finishedLoading {
                Rectangle()
                    .fill(.quaternary)
                    .overlay {
                        Image(systemName: "photo")
                            .foregroundStyle(.secondary)
                    }
            } else {
                Rectangle()
                    .fill(.quaternary)
                    .overlay { ProgressView() }
            }
        }
        .clipped()
        .task(id: frame.identity) {
            thumbnail = nil
            finishedLoading = false
            thumbnail = await model.thumbnail(for: frame, maxPixelSize: maxPixelSize)
            guard !Task.isCancelled else { return }
            finishedLoading = true
        }
    }
}

/// Apple's required next-keyboard control, including its press-and-hold input-mode menu.
private struct InputModeSwitchButton: UIViewRepresentable {
    let controller: () -> UIInputViewController?

    /// Creates the UIKit button required to forward the original touch event.
    func makeUIView(context: Context) -> UIButton {
        var configuration = UIButton.Configuration.plain()
        configuration.image = UIImage(systemName: "globe")
        let button = UIButton(configuration: configuration)
        button.accessibilityLabel = "Next Keyboard"
        if let controller = controller() {
            button.addTarget(
                controller,
                action: #selector(UIInputViewController.handleInputModeList(from:with:)),
                for: .allTouchEvents
            )
        }
        return button
    }

    /// The controller association is stable for the hosted keyboard lifetime.
    func updateUIView(_ uiView: UIButton, context: Context) {}
}

#if DEBUG && TSHUNHUE_APP_TARGET
#Preview("Keyboard — Text Mode") {
    KeyboardPreviewContainer(mode: .text)
        .frame(height: 300)
}

#Preview("Keyboard — Image Mode") {
    KeyboardPreviewContainer(mode: .images)
        .frame(height: 300)
}

#Preview("Keyboard — Search") {
    KeyboardPreviewContainer(mode: .images, query: "normal")
        .frame(height: 300)
}
#endif

#endif
