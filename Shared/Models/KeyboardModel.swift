//
//  KeyboardModel.swift
//  Tshunhue
//
//  Defines the reusable state and actions presented by Tshunhue's iOS keyboard UI.
//

import Foundation
import Observation

/// Extracts a useful search query from the host application's text document proxy.
enum KeyboardQueryContext {
    /// Prefers selected text, then joins the portions of the current line around the caret.
    static func query(
        selectedText: String?,
        beforeInput: String?,
        afterInput: String?
    ) -> String {
        if let selected = selectedText?.trimmingCharacters(in: .whitespacesAndNewlines),
           !selected.isEmpty {
            return selected
        }

        let beforeLine = beforeInput?
            .split(separator: "\n", omittingEmptySubsequences: false)
            .last
            .map(String.init) ?? ""
        let afterLine = afterInput?
            .split(separator: "\n", omittingEmptySubsequences: false)
            .first
            .map(String.init) ?? ""
        return (beforeLine + afterLine).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// The permission-dependent behavior exposed by the reusable keyboard view.
enum KeyboardAccessMode: Sendable, Equatable {
    /// Caption results insert ordinary text and never load images.
    case text
    /// Image results may download, preview, copy, and drag JPEG data.
    case images
}

/// One category available to the compact keyboard filter menu.
struct KeyboardCategoryOption: Identifiable, Hashable, Sendable {
    /// The source-scoped category identity used by search.
    let key: CategoryKey
    /// The category's display name.
    let name: String
    /// The source name used to disambiguate duplicate category names.
    let sourceName: String

    var id: CategoryKey { key }
}

/// The catalog metadata published after the keyboard data store loads.
struct KeyboardCatalogSnapshot: Sendable {
    /// Every enabled category in deterministic catalog order.
    let categories: [KeyboardCategoryOption]
}

/// The small data surface required by `KeyboardModel` and its preview fixtures.
protocol KeyboardDataProviding: Sendable {
    /// Loads app-owned catalog state and permission-dependent image services.
    func load(allowsImages: Bool) async throws -> KeyboardCatalogSnapshot
    /// Returns a bounded recent or search result list.
    func results(for query: String, category: CategoryKey?, limit: Int) async -> [CatalogFrame]
    /// Returns a downsampled image when images are available in the current mode.
    func thumbnail(for frame: CatalogFrame, maxPixelSize: Int) async -> ImageThumbnail?
    /// Returns the original cached or session-downloaded image asset.
    func asset(for url: URL) async throws -> ImageAsset
    /// Records a successful image copy or drag in the shared recent store.
    func recordRecent(_ identity: FrameIdentity) async throws
    /// Releases decoded image memory while retaining encoded cache files.
    func releaseImages() async
}

/// Observation-backed state shared by the real keyboard and app-hosted previews.
@MainActor
@Observable
final class KeyboardModel {
    /// The maximum number of choices displayed in the keyboard's single result row.
    static let resultLimit = 4

    /// Text read from the host selection or current line.
    private(set) var query = ""
    /// Enabled categories available to the filter menu.
    private(set) var categories: [KeyboardCategoryOption] = []
    /// The optional source-scoped category filter.
    private(set) var selectedCategory: CategoryKey?
    /// The current recent or search results.
    private(set) var results: [CatalogFrame] = []
    /// Whether shared catalogs are currently loading.
    private(set) var isLoading = false
    /// A recoverable catalog failure shown in the keyboard UI.
    private(set) var loadError: String?
    /// A transient copy or caption-insertion message.
    private(set) var actionMessage: String?
    /// Whether the transient action message represents a failure.
    private(set) var actionMessageIsError = false
    /// The current permission-dependent presentation mode.
    private(set) var accessMode: KeyboardAccessMode = .text
    /// Whether Apple requires the next-keyboard control in the current host.
    private(set) var needsInputModeSwitchKey = false
    /// The frame receiving temporary success feedback.
    private(set) var completedFrameID: FrameIdentity?

    @ObservationIgnored private let dataProvider: any KeyboardDataProviding
    @ObservationIgnored private let persistCategory: (CategoryKey?) -> Void
    @ObservationIgnored private let allowsDragging: Bool
    @ObservationIgnored private let searchDelayNanoseconds: UInt64
    @ObservationIgnored private var searchTask: Task<Void, Never>?
    @ObservationIgnored private var feedbackTask: Task<Void, Never>?
    @ObservationIgnored private var activationID = UUID()
    @ObservationIgnored private var transferItems: [FrameIdentity: FrameTransferItem] = [:]

    /// Creates keyboard state with injectable storage and lightweight preference hooks.
    init(
        dataProvider: any KeyboardDataProviding,
        selectedCategory: CategoryKey? = nil,
        allowsDragging: Bool = true,
        searchDelayNanoseconds: UInt64 = 150_000_000,
        persistCategory: @escaping (CategoryKey?) -> Void = { _ in }
    ) {
        self.dataProvider = dataProvider
        self.selectedCategory = selectedCategory
        self.allowsDragging = allowsDragging
        self.searchDelayNanoseconds = searchDelayNanoseconds
        self.persistCategory = persistCategory
    }

    /// Loads shared catalog state for one keyboard appearance.
    func activate(mode: KeyboardAccessMode, needsInputModeSwitchKey: Bool) async {
        let currentActivationID = UUID()
        activationID = currentActivationID
        searchTask?.cancel()
        accessMode = mode
        self.needsInputModeSwitchKey = needsInputModeSwitchKey
        isLoading = true
        loadError = nil
        transferItems = [:]
        defer {
            if activationID == currentActivationID { isLoading = false }
        }

        do {
            let snapshot = try await dataProvider.load(allowsImages: mode == .images)
            try Task.checkCancellation()
            guard activationID == currentActivationID else { return }
            categories = snapshot.categories
            if let selectedCategory,
               !categories.contains(where: { $0.key == selectedCategory }) {
                self.selectedCategory = nil
                persistCategory(nil)
            }
            await publishResults(for: query, category: self.selectedCategory)
        } catch is CancellationError {
            return
        } catch {
            guard activationID == currentActivationID else { return }
            categories = []
            results = []
            loadError = error.localizedDescription
        }
    }

    /// Cancels view-scoped work and releases decoded thumbnails when the keyboard disappears.
    func deactivate() async {
        activationID = UUID()
        searchTask?.cancel()
        feedbackTask?.cancel()
        searchTask = nil
        feedbackTask = nil
        isLoading = false
        transferItems = [:]
        await dataProvider.releaseImages()
    }

    /// Responds to extension memory pressure without deleting persistent or session image files.
    func handleMemoryWarning() async {
        searchTask?.cancel()
        transferItems = [:]
        await dataProvider.releaseImages()
    }

    /// Replaces the host-derived query and schedules a cancellable search.
    func updateQuery(_ query: String) {
        guard self.query != query else { return }
        self.query = query
        scheduleSearch()
    }

    /// Selects one category, remembers it, and refreshes the result row.
    func selectCategory(_ category: CategoryKey?) {
        guard selectedCategory != category else { return }
        selectedCategory = category
        persistCategory(category)
        scheduleSearch()
    }

    /// Copies one image as JPEG and records it only after pasteboard delivery succeeds.
    func copy(_ frame: CatalogFrame) async {
        guard accessMode == .images else { return }
        do {
            let asset = try await dataProvider.asset(for: frame.imageURL)
            try TransferService.copy(asset)
            publishFeedback("Copied — paste in the app.", frame: frame, isError: false)
            do {
                try await dataProvider.recordRecent(frame.identity)
            } catch {
                // Recent history is ancillary after the pasteboard accepts the JPEG.
            }
        } catch is CancellationError {
            return
        } catch {
            publishFeedback(error.localizedDescription, frame: frame, isError: true)
        }
    }

    /// Records feedback after the controller inserts a caption through the document proxy.
    func didInsertCaption(_ frame: CatalogFrame) {
        publishFeedback("Caption inserted.", frame: frame, isError: false)
    }

    /// Loads a thumbnail without promoting a per-cell failure to a catalog error.
    func thumbnail(for frame: CatalogFrame, maxPixelSize: Int) async -> ImageThumbnail? {
        guard accessMode == .images else { return nil }
        return await dataProvider.thumbnail(for: frame, maxPixelSize: maxPixelSize)
    }

    /// Returns a reusable JPEG transfer value for image-mode drag interactions.
    func transferItem(for frame: CatalogFrame) -> FrameTransferItem? {
        guard accessMode == .images, allowsDragging else { return nil }
        if let existing = transferItems[frame.identity] { return existing }
        let dataProvider = dataProvider
        let item = FrameTransferItem(
            frame: frame,
            assetProvider: { try await dataProvider.asset(for: $0) },
            recentRecorder: { try await dataProvider.recordRecent($0) }
        )
        transferItems[frame.identity] = item
        return item
    }

    /// Returns brief cell-level completion feedback when relevant.
    func feedback(for frame: CatalogFrame) -> String? {
        completedFrameID == frame.identity ? actionMessage : nil
    }

    // MARK: - Search and Feedback

    /// Debounces changes from host text and category selection.
    private func scheduleSearch() {
        searchTask?.cancel()
        let query = query
        let category = selectedCategory
        let delay = searchDelayNanoseconds
        searchTask = Task { [weak self] in
            do {
                if delay > 0 { try await Task.sleep(nanoseconds: delay) }
            } catch {
                return
            }
            guard let self, !Task.isCancelled,
                  self.query == query, self.selectedCategory == category else { return }
            await self.publishResults(for: query, category: category)
        }
    }

    /// Publishes a current, bounded result list returned by the data actor.
    private func publishResults(for query: String, category: CategoryKey?) async {
        let nextResults = await dataProvider.results(
            for: query,
            category: category,
            limit: Self.resultLimit
        )
        guard self.query == query, selectedCategory == category else { return }
        results = nextResults
    }

    /// Displays and later clears one non-blocking keyboard action message.
    private func publishFeedback(_ message: String, frame: CatalogFrame, isError: Bool) {
        feedbackTask?.cancel()
        actionMessage = message
        actionMessageIsError = isError
        completedFrameID = frame.identity
        feedbackTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: 2_000_000_000)
            } catch {
                return
            }
            guard let self else { return }
            self.actionMessage = nil
            self.actionMessageIsError = false
            self.completedFrameID = nil
        }
    }
}
