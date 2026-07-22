//
//  ContentView+iOS.swift
//  Tshunhue
//
//  Defines the iOS tab roots, navigation paths, and app-level sheets.
//

#if os(iOS)
import SwiftUI

/// The selectable roots of the iOS tab interface.
private enum iOSTab: Hashable {
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
private enum iOSSheet: Hashable, Identifiable {
    case initialCategories
    case settings

    var id: Self { self }
}

/// The iOS tab browser with independent navigation paths and modal flows.
struct iOSContentView: View {
    @ObservedObject var model: AppModel
    @Binding var groupFrames: Bool
    @State private var selectedTab: iOSTab = .browse
    @State private var browsePath: [BrowseRoute] = []
    @State private var recentsPath: [RecentsRoute] = []
    @State private var settingsPath: [SettingsRoute] = []
    @State private var activeSheet: iOSSheet?
    @State private var resolvedInitialPresentation = false
    @FocusState private var searchFocused: Bool

    var body: some View {
        TabView(selection: $selectedTab) {
            Tab("Browse", systemImage: "square.grid.2x2", value: iOSTab.browse) {
                browseNavigation
            }
            Tab("Recents", systemImage: "clock", value: iOSTab.recents) {
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
    private var activeSheetBinding: Binding<iOSSheet?> {
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

#if DEBUG
#Preview("Content - iOS") {
    iOSContentView(model: PreviewData.model(), groupFrames: .constant(false))
}
#endif
#endif
