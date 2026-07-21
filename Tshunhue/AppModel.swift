import Combine
import Foundation

@MainActor
final class AppModel: ObservableObject {
    @Published var sources: [SourceSummary] = []
    @Published var allFrames: [CatalogFrame] = []
    @Published var displayedFrames: [CatalogFrame] = []
    @Published var selectedCategories: Set<CategoryKey> = []
    @Published var selectedFrameID: FrameIdentity?
    @Published var query = "" {
        didSet { scheduleSearch() }
    }
    @Published var isWorking = false
    @Published var errorMessage: String?
    @Published var cacheByteCount = 0
    @Published var needsCategorySelection = false
    @Published var refreshFrequency: RefreshFrequency {
        didSet { UserDefaults.standard.set(refreshFrequency.rawValue, forKey: Self.refreshKey) }
    }

    private let sourceStore: SourceStore
    private let syncService: CatalogSyncService
    private let searchIndex: SearchIndex
    private let recentStore: RecentStore
    let imageRepository: ImageRepository
    private var searchTask: Task<Void, Never>?

    private static let refreshKey = "refreshFrequency"
    static let appGroupIdentifier = "group.tw.poren.Tshunhue"

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

    func start() async {
        guard sources.isEmpty && allFrames.isEmpty else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            try await sourceStore.load()
            try await recentStore.load()
            try await imageRepository.load()
            await restoreDefaultSources()
            await reloadCatalog()
            await refreshIfNeeded()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

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

    func removeSource(_ source: SourceSummary) async {
        guard !source.isDefault else { return }
        do {
            try await sourceStore.remove(id: source.id)
            try await recentStore.remove(sourceURL: source.sourceURL)
            selectedCategories = selectedCategories.filter { $0.sourceURL != source.sourceURL }
            await reloadCatalog()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func setCategory(_ descriptor: CategoryDescriptor, in source: SourceSummary, enabled: Bool) async {
        guard let archive = await sourceStore.archive(id: source.id) else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            let updated = try await syncService.setCategory(descriptor.id, enabled: enabled, in: archive)
            try await sourceStore.save(updated)
            if !enabled {
                try await recentStore.remove(categoryID: descriptor.id, sourceURL: source.sourceURL)
                selectedCategories.remove(CategoryKey(sourceURL: source.sourceURL, categoryID: descriptor.id))
            }
            await reloadCatalog()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

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

    func refreshWhenActive() async {
        guard !isWorking else { return }
        await refreshAll(force: false)
    }

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

    func restoreBundledSources() async {
        isWorking = true
        defer { isWorking = false }
        await restoreDefaultSources()
        await reloadCatalog()
    }

    func toggleFilter(_ key: CategoryKey) {
        if selectedCategories.contains(key) {
            selectedCategories.remove(key)
        } else {
            selectedCategories.insert(key)
        }
        scheduleSearch()
    }

    func showAllCategories() {
        selectedCategories = []
        scheduleSearch()
    }

    func copy(_ frame: CatalogFrame) async {
        isWorking = true
        defer { isWorking = false }
        do {
            let asset = try await imageRepository.asset(for: frame.imageURL)
            try TransferService.copy(asset)
            try await recentStore.record(frame.identity)
            if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { await updateDisplayedFrames() }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func transferFile(for frame: CatalogFrame) async -> TransferFile? {
        do {
            let asset = try await imageRepository.asset(for: frame.imageURL)
            let url = try TransferService.exportFile(for: frame, asset: asset)
            try await recentStore.record(frame.identity)
            if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { await updateDisplayedFrames() }
            return TransferFile(url: url)
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    func transferItem(for frame: CatalogFrame) -> FrameTransferItem {
        FrameTransferItem(frame: frame, repository: imageRepository, recentStore: recentStore)
    }

    func removeRecent(_ frame: CatalogFrame) async {
        do {
            try await recentStore.remove(frame.identity)
            await updateDisplayedFrames()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func clearRecents() async {
        do {
            try await recentStore.clear()
            await updateDisplayedFrames()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func clearCache() async {
        do {
            try await imageRepository.clear()
            cacheByteCount = 0
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func refreshCacheSize() async { cacheByteCount = await imageRepository.cacheSize() }

    var selectedFrame: CatalogFrame? {
        allFrames.first { $0.identity == selectedFrameID }
    }

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
        if nextSources.isEmpty {
            needsCategorySelection = false
        } else if nextSources.allSatisfy({ $0.enabledCategoryIDs.isEmpty }) {
            needsCategorySelection = true
        }
        await searchIndex.replace(with: nextFrames)
        await refreshCacheSize()
        await updateDisplayedFrames()
    }

    private func refreshIfNeeded() async {
        guard refreshFrequency != .manual else { return }
        await refreshAll(force: false)
    }

    private func isRefreshDue(_ archive: SourceArchive) -> Bool {
        guard let interval = refreshFrequency.interval else { return false }
        guard let lastRefresh = archive.lastSuccessfulRefresh else { return true }
        return Date().timeIntervalSince(lastRefresh) >= interval
    }

    private func canonicalSourceURL(_ url: URL) -> URL {
        var components = URLComponents(url: url.absoluteURL, resolvingAgainstBaseURL: true)
        components?.fragment = nil
        let scheme = components?.scheme?.lowercased()
        let host = components?.host?.lowercased()
        components?.scheme = scheme
        components?.host = host
        return components?.url ?? url.absoluteURL
    }

    private func scheduleSearch() {
        searchTask?.cancel()
        let query = query
        let categories = selectedCategories
        searchTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled, let self else { return }
            if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                await self.updateDisplayedFrames()
            } else {
                let matches = await self.searchIndex.search(query, categoryIDs: categories)
                guard !Task.isCancelled, self.query == query, self.selectedCategories == categories else { return }
                self.displayedFrames = matches
            }
        }
    }

    private func updateDisplayedFrames() async {
        if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let identities = await recentStore.all()
            displayedFrames = identities.compactMap { identity in allFrames.first { $0.identity == identity } }
        } else {
            displayedFrames = await searchIndex.search(query, categoryIDs: selectedCategories)
        }
    }
}
