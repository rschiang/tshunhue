//
//  ContentView.swift
//  Tshunhue
//
//  Composes the platform-specific browsing interface and shared presentation state.
//

import SwiftUI
#if os(macOS)
import QuickLook
#endif

/// The adaptive root view for Tshunhue's macOS and iOS experiences.
struct ContentView: View {
    /// The shared application state and command model.
    @ObservedObject var model: AppModel
    @AppStorage("groupFrames") private var groupFrames = false

    var body: some View {
        #if os(macOS)
        MacContentView(model: model, groupFrames: $groupFrames)
        #else
        IOSContentView(model: model, groupFrames: $groupFrames)
        #endif
    }
}

#if os(macOS)
/// The macOS split-view browser with an independent details inspector.
private struct MacContentView: View {
    @ObservedObject var model: AppModel
    @Binding var groupFrames: Bool
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var inspectorPresented = true
    @State private var quickLookURL: URL?
    @FocusState private var searchFocused: Bool

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            CategorySidebarView(model: model)
                .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 280)
        } detail: {
            FrameGridView(
                model: model,
                frames: model.displayedFrames,
                scope: model.selectedScope,
                hasSearchQuery: model.hasSearchQuery,
                groupFrames: groupFrames,
                onPreview: showPreview
            )
                .navigationTitle(model.navigationTitle)
                .searchable(text: $model.query, prompt: "Search captions and tags")
                .searchFocused($searchFocused)
        }
        .inspector(isPresented: $inspectorPresented) {
            Group {
                if let frame = model.selectedFrame {
                    FrameDetailsView(frame: frame, model: model)
                }
            }
            .inspectorColumnWidth(min: 240, ideal: 250, max: 320)
        }
        .toolbar {
            if let frame = model.selectedFrame {
                ToolbarItem(id: "copy") {
                    Button("Copy", systemImage: "doc.on.doc") { Task { await model.copy(frame) } }
                        .keyboardShortcut("c", modifiers: .command)
                }
                
                ToolbarItem(id: "share") {
                    ShareLink(item: model.transferItem(for: frame), preview: SharePreview(frame.frame.caption))
                }
            }
            ToolbarItemGroup {
                Button(groupingLabel, systemImage: groupFrames ? "rectangle.3.group.fill" : "rectangle.3.group") {
                    groupFrames.toggle()
                }
                .help(groupingLabel)
                .accessibilityValue(groupFrames ? "On" : "Off")

                Button("Toggle Inspector", systemImage: "sidebar.right") {
                    inspectorPresented.toggle()
                }
                .help(inspectorPresented ? "Hide Inspector" : "Show Inspector")
            }
        }
        .overlay(alignment: .top) {
            if model.isWorking { ProgressView().padding(8) }
        }
        .sheet(isPresented: $model.needsCategorySelection) {
            NavigationStack {
                InitialCategoryPickerView(model: model) {
                    model.needsCategorySelection = false
                }
            }
        }
        .quickLookPreview($quickLookURL)
        .onAppear { searchFocused = true }
        .alert("Tshunhue", isPresented: errorBinding) {
            Button("OK") { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
    }

    private var errorBinding: Binding<Bool> {
        Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })
    }

    private var groupingLabel: LocalizedStringKey {
        model.groupsBySubsection ? "Group by Subsection" : "Group by Category"
    }

    /// Downloads an image if needed, then presents its cached file with Quick Look.
    private func showPreview(_ frame: CatalogFrame) {
        Task {
            do {
                let asset = try await model.imageRepository.asset(for: frame.imageURL)
                quickLookURL = asset.localURL
            } catch is CancellationError {
                return
            } catch {
                model.errorMessage = error.localizedDescription
            }
        }
    }
}
#else
/// The selectable roots of the iOS tab interface.
private enum IOSTab: Hashable {
    case browse
    case recents
}

/// Lightweight destinations owned by the Browse navigation stack.
private enum BrowseRoute: Hashable {
    case details(FrameIdentity)
    case scopePicker
}

/// Lightweight destinations owned by the Recents navigation stack.
private enum RecentsRoute: Hashable {
    case details(FrameIdentity)
}

/// Mutually exclusive app-level sheets presented above the tab interface.
private enum IOSSheet: Hashable, Identifiable {
    case initialCategories
    case settings

    var id: Self { self }
}

/// The iOS tab browser with independent navigation paths and modal flows.
private struct IOSContentView: View {
    @ObservedObject var model: AppModel
    @Binding var groupFrames: Bool
    @State private var selectedTab: IOSTab = .browse
    @State private var browsePath: [BrowseRoute] = []
    @State private var recentsPath: [RecentsRoute] = []
    @State private var settingsPath: [SettingsRoute] = []
    @State private var activeSheet: IOSSheet?
    @State private var resolvedInitialPresentation = false
    @FocusState private var searchFocused: Bool

    var body: some View {
        TabView(selection: $selectedTab) {
            Tab("Browse", systemImage: "square.grid.2x2", value: IOSTab.browse) {
                browseNavigation
            }
            Tab("Recents", systemImage: "clock", value: IOSTab.recents) {
                recentsNavigation
            }
        }
        .sheet(item: activeSheetBinding) { sheet in
            switch sheet {
            case .initialCategories:
                NavigationStack {
                    InitialCategoryPickerView(model: model, onDismiss: dismissActiveSheet)
                }
                .interactiveDismissDisabled(model.hasPendingCategoryUpdates)
            case .settings:
                settingsNavigation
            }
        }
        .onChange(of: model.didFinishInitialLoad, initial: true) { _, finished in
            guard finished, !resolvedInitialPresentation else { return }
            resolvedInitialPresentation = true
            selectedTab = model.recentFrames.isEmpty ? .browse : .recents
            if model.needsCategorySelection {
                activeSheet = .initialCategories
            }
        }
        .overlay(alignment: .top) {
            if model.isWorking { ProgressView().padding(8) }
        }
        .alert("Tshunhue", isPresented: errorBinding) {
            Button("OK") { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
    }

    // MARK: - Tab Roots

    /// Browse content, scope selection, and details within one bound stack.
    private var browseNavigation: some View {
        NavigationStack(path: $browsePath) {
            FrameGridView(
                model: model,
                frames: model.displayedFrames,
                scope: model.selectedScope,
                hasSearchQuery: model.hasSearchQuery,
                groupFrames: groupFrames,
                onShowDetails: showBrowseDetails,
                onPreview: showBrowseDetails
            )
            .navigationTitle(model.navigationTitle)
            .navigationBarTitleDisplayMode(.automatic)
            .searchable(text: $model.query, prompt: "Search captions and tags")
            .searchFocused($searchFocused)
            .toolbar {
                ToolbarItem(placement: .navigation) {
                    Button("Filter", systemImage: "line.3.horizontal.decrease.circle") {
                        browsePath.append(.scopePicker)
                    }
                }

                ToolbarItem {
                    Button(
                        groupingLabel(for: model.selectedScope),
                        systemImage: groupFrames ? "rectangle.3.group.fill" : "rectangle.3.group"
                    ) {
                        groupFrames.toggle()
                    }
                    .accessibilityValue(groupFrames ? "On" : "Off")
                }

                ToolbarItem(placement: .secondaryAction) {
                    Button("Settings", systemImage: "gear", action: showSettings)
                }
            }
            .navigationDestination(for: BrowseRoute.self) { route in
                switch route {
                case .details(let identity):
                    frameDestination(identity)
                case .scopePicker:
                    CategorySidebarView(
                        model: model,
                        includesRecents: false,
                        onSelect: { browsePath.removeAll() }
                    )
                }
            }
        }
        .onAppear { searchFocused = true }
    }

    /// Recent transfers and their details within an independent bound stack.
    private var recentsNavigation: some View {
        NavigationStack(path: $recentsPath) {
            FrameGridView(
                model: model,
                frames: model.recentFrames,
                scope: .recents,
                hasSearchQuery: false,
                groupFrames: groupFrames,
                onShowDetails: showRecentDetails,
                onPreview: showRecentDetails
            )
            .navigationTitle("Recents")
            .toolbar {
                ToolbarItem {
                    Button(
                        groupingLabel(for: .recents),
                        systemImage: groupFrames ? "rectangle.3.group.fill" : "rectangle.3.group"
                    ) {
                        groupFrames.toggle()
                    }
                    .accessibilityValue(groupFrames ? "On" : "Off")
                }

                ToolbarItem(placement: .secondaryAction) {
                    Button("Settings", systemImage: "gear", action: showSettings)
                }
            }
            .navigationDestination(for: RecentsRoute.self) { route in
                switch route {
                case .details(let identity):
                    frameDestination(identity)
                }
            }
        }
    }

    // MARK: - Modal Flow

    /// Settings and all of its destinations within the active app-level sheet.
    private var settingsNavigation: some View {
        NavigationStack(path: $settingsPath) {
            SettingsView(model: model)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done", action: dismissActiveSheet)
                    }
                }
                .navigationDestination(for: SettingsRoute.self) { route in
                    switch route {
                    case .addSource:
                        AddSourceView(model: model)
                    case .privacyPolicy:
                        PolicyView()
                    case .about:
                        AboutView()
                            .navigationTitle("About Tshunhue")
                    }
                }
        }
    }

    /// Intercepts interactive sheet dismissal to retire onboarding state once.
    private var activeSheetBinding: Binding<IOSSheet?> {
        Binding(
            get: { activeSheet },
            set: { nextSheet in
                let dismissedInitialPicker = activeSheet == .initialCategories && nextSheet == nil
                activeSheet = nextSheet
                if dismissedInitialPicker {
                    model.needsCategorySelection = false
                }
            }
        )
    }

    // MARK: - Actions and Destinations

    /// Opens the selected frame on the Browse path.
    private func showBrowseDetails(_ frame: CatalogFrame) {
        browsePath.append(.details(frame.identity))
    }

    /// Opens the selected frame on the Recents path.
    private func showRecentDetails(_ frame: CatalogFrame) {
        recentsPath.append(.details(frame.identity))
    }

    /// Opens a fresh Settings flow above either tab.
    private func showSettings() {
        settingsPath.removeAll()
        activeSheet = .settings
    }

    /// Closes the current modal flow and records onboarding dismissal when needed.
    private func dismissActiveSheet() {
        if activeSheet == .initialCategories {
            model.needsCategorySelection = false
        }
        activeSheet = nil
    }

    /// Resolves a lightweight frame route without carrying catalog models in a path.
    @ViewBuilder
    private func frameDestination(_ identity: FrameIdentity) -> some View {
        if let frame = model.frame(for: identity) {
            FrameDetailsView(frame: frame, model: model)
        } else {
            ContentUnavailableView("No Images", systemImage: "photo")
        }
    }

    private var errorBinding: Binding<Bool> {
        Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })
    }

    /// Returns the grouping action appropriate for a root's explicit scope.
    private func groupingLabel(for scope: CatalogScope) -> LocalizedStringKey {
        if case .category = scope { return "Group by Subsection" }
        return "Group by Category"
    }
}
#endif

#if DEBUG
#Preview("Content") { ContentView(model: PreviewData.model()) }
#endif
