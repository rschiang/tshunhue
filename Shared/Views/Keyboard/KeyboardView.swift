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
        VStack(spacing: 0) {
            header
            resultRow
            editingKeys
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Header and Status

    /// Displays the host-derived query and the optional category filter.
    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            HStack(spacing: 10) {
                if !model.query.isEmpty {
                    Image(systemName: "magnifyingglass")
                    Text(model.query)
                        .lineLimit(1)
                        .foregroundStyle(.primary)
                } else {
                    Image(systemName: "character.cursor.ibeam")
                    Text("Type or Select a Keyword Above")
                }
                Spacer()
            }
            .padding(10)
            .font(.callout)
            .foregroundStyle(.secondary)
            .font(.body)
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
                Label("All", systemImage: (model.selectedCategory == nil) ? "checkmark" : "")
            }
            ForEach(model.categories) { category in
                Button {
                    model.selectCategory(category.key)
                } label: {
                    Label(category.name, systemImage: (model.selectedCategory == category.key) ? "checkmark" : "")
                }
            }
        } label: {
            Label(selectedCategoryName, systemImage: (model.selectedCategory == nil) ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
                .labelStyle(.iconOnly)
                .lineLimit(1)
                .padding(10)
        }
        .disabled(model.categories.isEmpty)
        .accessibilityLabel("Filter Category")
    }

    // MARK: - Results

    /// Displays at most four choices in one horizontally scrollable row.
    @ViewBuilder
    private var resultRow: some View {
        if model.isLoading && model.results.isEmpty {
            ProgressView("Loading…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let loadError = model.loadError, model.results.isEmpty {
            compactUnavailable(message: loadError, systemImage: "exclamationmark.triangle")
        } else if model.results.isEmpty {
            compactUnavailable(
                message: model.query.isEmpty ? "No recent images yet." : "No matching reactions.",
                systemImage: model.query.isEmpty ? "clock" : "magnifyingglass"
            )
        } else {
            let candidates = model.results.prefix(KeyboardModel.resultLimit)
            if model.accessMode == .images {
                ScrollView(.horizontal) {
                    LazyHStack(spacing: 6) {
                        ForEach(candidates) { frame in
                            result(for: frame)
                        }
                    }
                    .padding(.vertical, 10)
                }
            } else {
                ScrollView(.vertical) {
                    LazyVStack(spacing: 6) {
                        ForEach(candidates) { frame in
                            result(for: frame)
                        }
                    }
                    .padding(.vertical, 10)
                }
            }
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
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(10)
                    .background(.thickMaterial, in: .rect(cornerRadius: 8))
            }
            .buttonStyle(.plain)
            .buttonSizing(.flexible)
            .accessibilityHint("Inserts this caption")
        case .images:
            if let transferItem = model.transferItem(for: frame) {
                imageButton(for: frame)
                    .draggable(transferItem)
            } else {
                imageButton(for: frame)
            }
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
        HStack(spacing: 6) {
            if model.needsInputModeSwitchKey {
                InputModeSwitchButton(controller: inputModeController)
                    .frame(width: 44, height: 36)
            }

            Button(action: insertSpace) {
                Image(systemName: "space")
                    .frame(maxWidth: .infinity, minHeight: 16)
                    .foregroundStyle(.secondary.opacity(0))
                    .padding(10)
            }
            .background(.thickMaterial, in: .rect(cornerRadius: 8))
            .shadow(color: .black.opacity(0.15), radius: 1, y: 1)
            .accessibilityLabel("Space")

            Button(action: deleteBackward) {
                Image(systemName: "delete.left")
                    .padding(10)
            }
            .foregroundStyle(.primary)
            .accessibilityLabel("Delete")
        }
        .font(.headline)
    }

    /// The currently selected category title used by the compact menu label.
    private var selectedCategoryName: String {
        guard let selectedCategory = model.selectedCategory else { return "All" }
        return model.categories.first(where: { $0.key == selectedCategory })?.name ?? "All"
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
        .frame(height: 360)
}

#Preview("Keyboard — Image Mode") {
    KeyboardPreviewContainer(mode: .images)
        .frame(height: 360)
}
#endif

#endif
