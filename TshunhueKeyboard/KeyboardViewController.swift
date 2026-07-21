import Combine
import SwiftUI
import UIKit
import UniformTypeIdentifiers

final class KeyboardViewController: UIInputViewController {
    private var host: UIHostingController<KeyboardRootView>?

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

@MainActor
private final class KeyboardCatalog: ObservableObject {
    @Published var query = ""
    @Published var frames: [CatalogFrame] = []
    @Published var copiedFrameID: FrameIdentity?
    @Published var error: String?

    private let repository: ImageRepository?
    private let recentStore: RecentStore?
    var hasFullAccess = false

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

    func copy(_ frame: CatalogFrame) async {
        guard let repository, let recentStore else { return }
        guard hasFullAccess else {
            error = "Enable Full Access in Settings to copy images."
            return
        }
        do {
            let asset = try await repository.asset(for: frame.imageURL)
            UIPasteboard.general.setData(asset.data, forPasteboardType: asset.type.identifier)
            try await recentStore.record(frame.identity)
            copiedFrameID = frame.identity
        } catch {
            self.error = error.localizedDescription
        }
    }

    func thumbnail(for frame: CatalogFrame) async -> UIImage? {
        guard let repository else { return nil }
        guard let thumbnail = try? await repository.thumbnail(for: frame.imageURL, maxPixelSize: 320) else {
            return nil
        }
        return UIImage(cgImage: thumbnail.image)
    }
}

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
