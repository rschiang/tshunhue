//
//  KeyboardViewController.swift
//  TshunhueKeyboard
//
//  Hosts the SwiftUI keyboard interface and reads shared Tshunhue catalog data.
//

import Combine
import SwiftUI
import UIKit
import UniformTypeIdentifiers

// MARK: - Extension Controller

/// The UIKit entry point that embeds Tshunhue's keyboard SwiftUI hierarchy.
final class KeyboardViewController: UIInputViewController {
    /// The hosted SwiftUI keyboard retained for the controller lifetime.
    private var host: UIHostingController<KeyboardRootView>?

    /// Installs the hosted keyboard view and begins loading shared catalog data.
    override func viewDidLoad() {
        super.viewDidLoad()
        let catalog = KeyboardCatalog()
        catalog.hasFullAccess = hasFullAccess
        let root = KeyboardRootView(
            catalog: catalog,
            hasFullAccess: hasFullAccess,
            advanceKeyboard: { [weak self] in self?.advanceToNextInputMode() },
            insertCaption: { [weak self] caption in self?.textDocumentProxy.insertText(caption) }
        )
        let host = UIHostingController(rootView: root)
        addChild(host)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            host.view.topAnchor.constraint(equalTo: view.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            view.heightAnchor.constraint(greaterThanOrEqualToConstant: 300),
        ])
        host.didMove(toParent: self)
        self.host = host
        Task { await catalog.load() }
    }
}

// MARK: - Shared Catalog

/// Observable catalog and image-transfer state local to the keyboard extension.
@MainActor
private final class KeyboardCatalog: ObservableObject {
    /// The keyboard's current search query.
    @Published var query = ""
    /// Frames loaded from enabled shared source archives.
    @Published var frames: [CatalogFrame] = []
    /// The most recently copied frame, used for transient feedback.
    @Published var copiedFrameID: FrameIdentity?
    /// A loading or permission error shown in the keyboard.
    @Published var error: String?

    private let repository: ImageRepository?
    private let recentStore: RecentStore?
    /// Whether the extension may use networking and the general pasteboard.
    var hasFullAccess = false

    /// Connects to the app-group stores when their container is available.
    init() {
        let root = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: "group.tw.poren.Tshunhue"
        )?.appendingPathComponent("Tshunhue", isDirectory: true)
        if let root {
            repository = ImageRepository(
                directory: root.appendingPathComponent("Image Cache"),
                byteBudget: 256 * 1_024 * 1_024
            )
            recentStore = RecentStore(fileURL: root.appendingPathComponent("recent.json"))
        } else {
            repository = nil
            recentStore = nil
        }
    }

    /// Frames matching all normalized query terms, capped when browsing without a query.
    var results: [CatalogFrame] {
        let terms = query.split(whereSeparator: \.isWhitespace).map {
            String($0).folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
        }
        guard !terms.isEmpty else { return Array(frames.prefix(24)) }
        return frames.filter { frame in
            let values = ([frame.frame.caption] + frame.tags).map {
                $0.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            }
            return terms.allSatisfy { term in values.contains(where: { $0.contains(term) }) }
        }
    }

    /// Loads enabled frames from independently validated shared source archives.
    func load() async {
        guard let repository, let recentStore,
              let root = FileManager.default.containerURL(
                forSecurityApplicationGroupIdentifier: "group.tw.poren.Tshunhue"
              )?.appendingPathComponent("Tshunhue", isDirectory: true) else {
            error = "Open Tshunhue once before using the keyboard."
            return
        }
        do {
            try await repository.load()
            try await recentStore.load()
            let directory = root.appendingPathComponent("Sources")
            let files = try FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ).filter { $0.lastPathComponent.hasPrefix("source-") && $0.pathExtension == "json" }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let validator = CatalogValidator()
            var loaded: [CatalogFrame] = []
            for file in files {
                do {
                    let archive = try decoder.decode(SourceArchive.self, from: Data(contentsOf: file))
                    let index = try validator.validateIndex(data: archive.index.data, sourceURL: archive.sourceURL)
                    for categoryID in archive.enabledCategoryIDs {
                        guard let descriptor = index.categories.first(where: { $0.descriptor.id == categoryID }),
                              let document = archive.categories[categoryID] else { continue }
                        loaded.append(contentsOf: try validator.validateCategory(
                            data: document.data,
                            documentURL: descriptor.url,
                            descriptor: descriptor.descriptor,
                            source: index
                        ).frames)
                    }
                } catch {
                    continue
                }
            }
            frames = loaded
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Copies a frame as JPEG and records it after a successful pasteboard write.
    func copy(_ frame: CatalogFrame) async {
        guard let repository, let recentStore else { return }
        guard hasFullAccess else {
            error = "Enable Full Access in Settings to copy images."
            return
        }
        do {
            let asset = try await repository.asset(for: frame.imageURL)
            let data = try JPEGEncoder.data(for: asset)
            UIPasteboard.general.setData(data, forPasteboardType: UTType.jpeg.identifier)
            try await recentStore.record(frame.identity)
            copiedFrameID = frame.identity
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Loads a compact UIKit thumbnail for a keyboard grid cell.
    func thumbnail(for frame: CatalogFrame) async -> UIImage? {
        guard let repository else { return nil }
        guard let thumbnail = try? await repository.thumbnail(for: frame.imageURL, maxPixelSize: 320) else {
            return nil
        }
        return UIImage(cgImage: thumbnail.image)
    }
}

// MARK: - Keyboard Views

/// The keyboard's search field, state messaging, and compact frame grid.
private struct KeyboardRootView: View {
    @ObservedObject var catalog: KeyboardCatalog
    let hasFullAccess: Bool
    let advanceKeyboard: () -> Void
    let insertCaption: (String) -> Void

    private let columns = [GridItem(.adaptive(minimum: 84), spacing: 8)]

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Button(action: advanceKeyboard) { Image(systemName: "globe") }
                    .accessibilityLabel("Next Keyboard")
                TextField("Search memes", text: $catalog.query)
                    .textFieldStyle(.roundedBorder)
                if !hasFullAccess {
                    Text("Full Access required")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 10)

            if let error = catalog.error {
                ContentUnavailableView("Tshunhue", systemImage: "exclamationmark.triangle", description: Text(error))
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 8) {
                        ForEach(catalog.results) { frame in
                            KeyboardFrameButton(
                                frame: frame,
                                copied: catalog.copiedFrameID == frame.identity,
                                loadImage: { await catalog.thumbnail(for: frame) },
                                copy: { Task { await catalog.copy(frame) } },
                                insertCaption: { insertCaption(frame.frame.caption) }
                            )
                        }
                    }
                    .padding(.horizontal, 8)
                }
            }
        }
        .padding(.vertical, 8)
    }
}

/// A compact frame button supporting image copy and caption insertion.
private struct KeyboardFrameButton: View {
    let frame: CatalogFrame
    let copied: Bool
    let loadImage: () async -> UIImage?
    let copy: () -> Void
    let insertCaption: () -> Void
    @State private var image: UIImage?

    var body: some View {
        Button(action: copy) {
            ZStack(alignment: .bottom) {
                Group {
                    if let image {
                        Image(uiImage: image).resizable().scaledToFill()
                    } else {
                        Rectangle().fill(.quaternary).overlay { ProgressView() }
                    }
                }
                .frame(height: 64)
                .clipped()
                Text(copied ? "Copied — paste" : frame.frame.caption)
                    .font(.caption2)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity)
                    .padding(3)
                    .background(.ultraThinMaterial)
            }
            .clipShape(.rect(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Insert Caption", action: insertCaption)
        }
        .task { image = await loadImage() }
    }
}

// MARK: - Previews

#if DEBUG
/// Minimal catalog fixture used only by keyboard-extension previews.
private enum KeyboardPreviewData {
    /// A representative frame that does not require loading shared app data.
    static let frame = CatalogFrame(
        identity: FrameIdentity(
            sourceURL: URL(string: "https://example.com/index.json")!,
            categoryID: "spring-flowers",
            frameID: "welcome"
        ),
        sourceName: "Tshun-lit-iánn",
        categoryID: "spring-flowers",
        categoryName: "Spring Flowers",
        language: "zh-Hant-TW",
        subsection: nil,
        frame: Frame(
            id: "welcome",
            url: "https://example.com/welcome.jpg",
            caption: "Welcome to Tshunhue!",
            tags: ["welcome"],
            subsection: nil,
            timecode: nil
        ),
        effectiveID: "welcome",
        imageURL: URL(string: "https://example.com/welcome.jpg")!,
        providers: [],
        attribution: nil,
        reportURL: nil,
        categoryOrder: 0,
        subsectionOrder: nil,
        order: 0
    )
}

#Preview("Keyboard") {
    KeyboardRootView(
        catalog: KeyboardCatalog(),
        hasFullAccess: false,
        advanceKeyboard: {},
        insertCaption: { _ in }
    )
    .frame(height: 320)
}

#Preview("Keyboard Frame") {
    KeyboardFrameButton(
        frame: KeyboardPreviewData.frame,
        copied: false,
        loadImage: { nil },
        copy: {},
        insertCaption: {}
    )
    .frame(width: 120)
    .padding()
}
#endif
