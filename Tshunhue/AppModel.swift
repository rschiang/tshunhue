//
//  AppModel.swift
//  Tshunhue
//
//  Coordinates catalog sources, search state, image transfers, and app persistence.
//

import Combine
import Foundation

/// The main-actor state and command surface shared by Tshunhue's views.
@MainActor
final class AppModel: ObservableObject {
    // MARK: - Published State

    /// Summaries of the configured catalog sources.
    @Published var sources: [SourceSummary] = []
    /// Every frame loaded from enabled categories.
    @Published var allFrames: [CatalogFrame] = []
    /// Frames matching the current scope and search query.
    @Published var displayedFrames: [CatalogFrame] = []
    /// Resolved recent frames in newest-first order for the iOS Recents tab.
    @Published private(set) var recentFrames: [CatalogFrame] = []
    #if os(macOS)
    @Published var selectedScope: CatalogScope = .all {
        didSet { if oldValue != selectedScope { scheduleSearch() } }
    }
    #else
    @Published var selectedScope: CatalogScope = .all {
        didSet { if oldValue != selectedScope { scheduleSearch() } }
    }
    #endif
    /// The frame selected for details or keyboard preview.
    @Published var selectedFrameID: FrameIdentity?
    /// The user's current caption and tag search.
    @Published var query = "" {
        didSet { scheduleSearch() }
    }
    /// Indicates that a user-initiated or lifecycle task is running.
    @Published var isWorking = false
    /// The latest error to present to the user.
    @Published var errorMessage: String?
    /// The current size of the on-disk image cache.
    @Published var cacheByteCount = 0
    /// Controls presentation of the first-run category picker.
    @Published var needsCategorySelection = false
    /// Indicates that persisted sources and recents are ready for initial UI routing.
    @Published private(set) var didFinishInitialLoad = false
    /// The interval used for automatic source refreshes.
    @Published var refreshFrequency: RefreshFrequency {
        didSet { UserDefaults.standard.set(refreshFrequency.rawValue, forKey: Self.refreshKey) }
    }

    private let sourceStore: SourceStore
    private let syncService: CatalogSyncService
    private let searchIndex: SearchIndex
    private let recentStore: RecentStore
    /// The shared image loader and cache used by app views and transfers.
    let imageRepository: ImageRepository
    private var searchTask: Task<Void, Never>?
    /// Desired category values awaiting download, validation, and persistence.
    @Published private var pendingCategorySelections: [CategoryKey: Bool] = [:]

    private static let refreshKey = "refreshFrequency"
    /// The app-group identifier shared with the optional keyboard extension.
    static let appGroupIdentifier = "group.tw.poren.Tshunhue"

    /// Creates the app model, optionally rooted at a caller-supplied directory for tests and previews.
    init(baseDirectory: URL? = nil) {
        let applicationSupport: URL
        if let baseDirectory {
            applicationSupport = baseDirectory
        } else {
            #if os(iOS)
            applicationSupport = FileManager.default.containerURL(
                forSecurityApplicationGroupIdentifier: Self.appGroupIdentifier
            )?.appendingPathComponent("Tshunhue", isDirectory: true)
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
                .appendingPathComponent("Tshunhue", isDirectory: true)
            #else
            applicationSupport = FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first!.appendingPathComponent("Tshunhue", isDirectory: true)
            #endif
        }
        sourceStore = SourceStore(directory: applicationSupport.appendingPathComponent("Sources"))
        syncService = CatalogSyncService()
        searchIndex = SearchIndex()
        recentStore = RecentStore(fileURL: applicationSupport.appendingPathComponent("recent.json"))
        #if os(macOS)
        let budget = 1_024 * 1_024 * 1_024
        #else
        let budget = 256 * 1_024 * 1_024
        #endif
        imageRepository = ImageRepository(
            directory: applicationSupport.appendingPathComponent("Image Cache"),
            byteBudget: budget
        )
        refreshFrequency = RefreshFrequency(
            rawValue: UserDefaults.standard.string(forKey: Self.refreshKey) ?? ""
        ) ?? .weekly
    }

    // MARK: - Lifecycle and Sources

    /// Loads persisted state, restores defaults, and refreshes stale sources.
    func start() async {
        guard sources.isEmpty && allFrames.isEmpty else { return }
        isWorking = true
        defer {
            isWorking = false
            didFinishInitialLoad = true
        }
        do {
            try await sourceStore.load()
            try await recentStore.load()
            try await imageRepository.load()
            await restoreDefaultSources()
            await reloadCatalog()
            needsCategorySelection = !sources.isEmpty
                && sources.allSatisfy { $0.enabledCategoryIDs.isEmpty }
            await refreshCacheSize()
            await refreshIfNeeded()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Validates and adds a custom HTTPS catalog source.
    /// - Returns: `true` when the source was added successfully.
    func addSource(urlString: String) async -> Bool {
        guard let parsedURL = URL(string: urlString), parsedURL.scheme?.lowercased() == "https" else {
            errorMessage = String(localized: "Enter an absolute HTTPS source URL.")
            return false
        }
        let url = canonicalSourceURL(parsedURL)
        if await sourceStore.archive(sourceURL: url) != nil {
            errorMessage = String(localized: "That source has already been added.")
            return false
        }
        isWorking = true
        defer { isWorking = false }
        do {
            let archive = try await syncService.createSource(url: url, isDefault: false)
            try await sourceStore.save(archive)
            await reloadCatalog()
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    /// Removes a custom source and its associated recent items.
    func removeSource(_ source: SourceSummary) async {
        guard !source.isDefault else { return }
        do {
            try await sourceStore.remove(id: source.id)
            try await recentStore.remove(sourceURL: source.sourceURL)
            await reloadCatalog()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Enables or disables a category and downloads or removes its metadata.
    func setCategory(_ descriptor: CategoryDescriptor, in source: SourceSummary, enabled: Bool) async {
        let key = CategoryKey(sourceURL: source.sourceURL, categoryID: descriptor.id)
        guard !isUpdatingCategories(in: source),
              source.enabledCategoryIDs.contains(descriptor.id) != enabled,
              let archive = await sourceStore.archive(id: source.id) else { return }

        // Reflect intent immediately while preventing conflicting writes to this source.
        pendingCategorySelections[key] = enabled
        defer { pendingCategorySelections.removeValue(forKey: key) }
        do {
            let updated = try await syncService.setCategory(descriptor.id, enabled: enabled, in: archive)
            try await sourceStore.save(updated)
            if !enabled {
                try await recentStore.remove(categoryID: descriptor.id, sourceURL: source.sourceURL)
            }
            await reloadCatalog()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Refreshes every source that is forced or due under the current schedule.
    func refreshAll(force: Bool = true) async {
        isWorking = true
        defer { isWorking = false }
        for archive in await sourceStore.allArchives() where force || isRefreshDue(archive) {
            let updated = await syncService.refresh(archive)
            do {
                try await sourceStore.save(updated)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
        await reloadCatalog()
    }

    /// Performs a scheduled refresh when the app becomes active.
    func refreshWhenActive() async {
        guard !isWorking, !hasPendingCategoryUpdates else { return }
        await refreshAll(force: false)
    }

    /// Re-adds sources shipped in the application bundle when they are missing.
    private func restoreDefaultSources() async {
        guard let url = Bundle.main.url(forResource: "DefaultSources", withExtension: "json") else { return }
        do {
            let configuration = try JSONDecoder().decode(
                DefaultSourceConfiguration.self,
                from: Data(contentsOf: url)
            )
            for configuredURL in configuration.sources {
                let sourceURL = canonicalSourceURL(configuredURL)
                guard await sourceStore.archive(sourceURL: sourceURL) == nil else { continue }
                do {
                    let archive = try await syncService.createSource(url: sourceURL, isDefault: true)
                    try await sourceStore.save(archive)
                } catch {
                    errorMessage = error.localizedDescription
                }
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Restores bundled sources and reloads the searchable catalog.
    func restoreBundledSources() async {
        isWorking = true
        defer { isWorking = false }
        await restoreDefaultSources()
        await reloadCatalog()
    }

    // MARK: - Transfers and Storage

    /// Copies a frame as JPEG and records it in recents after a successful transfer.
    func copy(_ frame: CatalogFrame) async {
        isWorking = true
        defer { isWorking = false }
        do {
            let asset = try await imageRepository.asset(for: frame.imageURL)
            try TransferService.copy(asset)
            try await recentStore.record(frame.identity)
            await refreshRecentFrames()
            if isShowingRecents { await updateDisplayedFrames() }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Creates the transferable value used by drag, drop, and share operations.
    func transferItem(for frame: CatalogFrame) -> FrameTransferItem {
        FrameTransferItem(
            frame: frame,
            repository: imageRepository,
            recentStore: recentStore
        ) { [weak self] in
            await self?.recentStoreDidChange()
        }
    }

    /// Removes one frame from the recent-items list.
    func removeRecent(_ frame: CatalogFrame) async {
        do {
            try await recentStore.remove(frame.identity)
            await refreshRecentFrames()
            await updateDisplayedFrames()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Removes all recent items.
    func clearRecents() async {
        do {
            try await recentStore.clear()
            await refreshRecentFrames()
            await updateDisplayedFrames()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Removes all downloaded images from the cache.
    func clearCache() async {
        do {
            try await imageRepository.clear()
            cacheByteCount = 0
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Recalculates the displayed image-cache size.
    func refreshCacheSize() async { cacheByteCount = await imageRepository.cacheSize() }

    // MARK: - Derived View State

    /// The complete frame represented by `selectedFrameID`, when still available.
    var selectedFrame: CatalogFrame? {
        allFrames.first { $0.identity == selectedFrameID }
    }

    /// Resolves a lightweight navigation identity against the current catalog.
    func frame(for identity: FrameIdentity) -> CatalogFrame? {
        allFrames.first { $0.identity == identity }
    }

    /// Returns the requested pending value or the source's persisted category value.
    func isCategoryEnabled(_ descriptor: CategoryDescriptor, in source: SourceSummary) -> Bool {
        let key = CategoryKey(sourceURL: source.sourceURL, categoryID: descriptor.id)
        return pendingCategorySelections[key] ?? source.enabledCategoryIDs.contains(descriptor.id)
    }

    /// Returns whether one category in the source is currently being updated.
    func isUpdatingCategories(in source: SourceSummary) -> Bool {
        pendingCategorySelections.keys.contains { $0.sourceURL == source.sourceURL }
    }

    /// Returns whether this exact category is awaiting persistence.
    func isUpdatingCategory(_ descriptor: CategoryDescriptor, in source: SourceSummary) -> Bool {
        pendingCategorySelections[CategoryKey(
            sourceURL: source.sourceURL,
            categoryID: descriptor.id
        )] != nil
    }

    /// Whether any source has a pending category mutation.
    var hasPendingCategoryUpdates: Bool {
        !pendingCategorySelections.isEmpty
    }

    /// Whether the unfiltered recent-items scope is currently visible.
    var isShowingRecents: Bool {
        selectedScope == .recents && !hasSearchQuery
    }

    /// Whether the query contains any searchable text.
    var hasSearchQuery: Bool {
        !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Whether grouped results should use subsection headings.
    var groupsBySubsection: Bool {
        if case .category = selectedScope { return true }
        return false
    }

    /// Sections for the grouped grid presentation.
    var frameSections: [FrameSection] {
        FrameSectionBuilder.sections(from: displayedFrames, scope: selectedScope, sources: sources)
    }

    /// The localized title for the current browse scope.
    var navigationTitle: String {
        if hasSearchQuery {
            return String(localized: "Results")
        }
        switch selectedScope {
        case .recents:
            return String(localized: "Recents")
        case .all:
            return String(localized: "All Images")
        case .index(let sourceURL):
            return sources.first(where: { $0.sourceURL == sourceURL })?.name ?? String(localized: "Index")
        case .category(let key):
            return sources
                .first(where: { $0.sourceURL == key.sourceURL })?
                .categories.first(where: { $0.id == key.categoryID })?.name
                ?? String(localized: "Category")
        }
    }

    /// Builds a prefilled report URL for a catalog frame.
    func reportURL(for frame: CatalogFrame) -> URL? {
        guard let base = frame.reportURL,
              var components = URLComponents(url: base, resolvingAgainstBaseURL: false) else { return nil }
        var items = components.queryItems ?? []
        items.append(URLQueryItem(name: "title", value: "Report: \(frame.categoryName) / \(frame.effectiveID)"))
        items.append(URLQueryItem(name: "body", value: """
        Source: \(frame.identity.sourceURL.absoluteString)
        Category: \(frame.categoryID)
        Frame: \(frame.effectiveID)
        Image: \(frame.imageURL.absoluteString)
        """))
        components.queryItems = items
        return components.url
    }

    // MARK: - Catalog and Search Internals

    /// Revalidates persisted sources and rebuilds observable catalog state.
    private func reloadCatalog() async {
        var nextSources: [SourceSummary] = []
        var nextFrames: [CatalogFrame] = []
        for archive in await sourceStore.allArchives() {
            do {
                nextSources.append(try await syncService.summary(of: archive))
                nextFrames.append(contentsOf: try await syncService.validatedContents(of: archive).1)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
        sources = nextSources
        allFrames = nextFrames
        if !CatalogScopeResolver.isValid(selectedScope, in: nextSources) {
            selectedScope = Self.defaultScope
        }
        await refreshRecentFrames()
        await searchIndex.replace(with: nextFrames)
        await updateDisplayedFrames()
    }

    /// Runs the automatic refresh policy after startup.
    private func refreshIfNeeded() async {
        guard refreshFrequency != .manual else { return }
        await refreshAll(force: false)
    }

    /// Returns whether an archive has exceeded its configured refresh interval.
    private func isRefreshDue(_ archive: SourceArchive) -> Bool {
        guard let interval = refreshFrequency.interval else { return false }
        guard let lastRefresh = archive.lastSuccessfulRefresh else { return true }
        return Date().timeIntervalSince(lastRefresh) >= interval
    }

    /// Normalizes a source URL for stable duplicate detection.
    private func canonicalSourceURL(_ url: URL) -> URL {
        var components = URLComponents(url: url.absoluteURL, resolvingAgainstBaseURL: true)
        components?.fragment = nil
        let scheme = components?.scheme?.lowercased()
        let host = components?.host?.lowercased()
        components?.scheme = scheme
        components?.host = host
        return components?.url ?? url.absoluteURL
    }

    /// Debounces query and scope changes before searching the actor-backed index.
    private func scheduleSearch() {
        searchTask?.cancel()
        let query = query
        let scope = selectedScope
        let categories = CatalogScopeResolver.categoryFilter(for: scope, in: sources)
        searchTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled, let self else { return }
            if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                await self.updateDisplayedFrames()
            } else {
                let matches = await self.searchIndex.search(query, categoryIDs: categories)
                guard !Task.isCancelled, self.query == query, self.selectedScope == scope else { return }
                self.applyDisplayedFrames(matches)
            }
        }
    }

    /// Rebuilds displayed frames from the current scope and query.
    private func updateDisplayedFrames() async {
        if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let identities = selectedScope == .recents ? await recentStore.all() : []
            let matches = CatalogScopeResolver.frames(
                for: selectedScope,
                in: allFrames,
                recentIdentities: identities
            )
            applyDisplayedFrames(matches)
        } else {
            let categories = CatalogScopeResolver.categoryFilter(for: selectedScope, in: sources)
            applyDisplayedFrames(await searchIndex.search(query, categoryIDs: categories))
        }
    }

    /// Publishes new results while clearing a selection that is no longer visible.
    private func applyDisplayedFrames(_ frames: [CatalogFrame]) {
        displayedFrames = frames
        if let selectedFrameID, !frames.contains(where: { $0.identity == selectedFrameID }) {
            self.selectedFrameID = nil
        }
    }

    /// Resolves persisted recent identities against the currently enabled catalog.
    private func refreshRecentFrames() async {
        let framesByIdentity = Dictionary(uniqueKeysWithValues: allFrames.map { ($0.identity, $0) })
        let identities = await recentStore.all()
        recentFrames = identities.compactMap { framesByIdentity[$0] }
    }

    /// Publishes recents recorded by share and drag transfers outside direct model commands.
    private func recentStoreDidChange() async {
        await refreshRecentFrames()
        if isShowingRecents { await updateDisplayedFrames() }
    }

    /// The platform-appropriate initial browse scope.
    private static var defaultScope: CatalogScope {
        .all
    }
}
    // MARK: - Dependencies
