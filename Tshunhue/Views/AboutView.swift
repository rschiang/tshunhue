//
//  AboutView.swift
//  Tshunhue
//
//  Presents responsive application information and the bundled license.
//

import SwiftUI

/// A cross-platform application identity and license view.
struct AboutView: View {
    @State private var showsLicense: Bool

    /// Creates an About view with an optionally expanded macOS license section.
    init(showLicense: Bool = false) {
        _showsLicense = State(initialValue: showLicense)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                header

                #if os(macOS)
                macContent
                #else
                iosContent
                #endif
            }
            .frame(maxWidth: 640)
            .frame(maxWidth: .infinity)
            .padding(contentPadding)
        }
        #if os(macOS)
        .animation(.default, value: showsLicense)
        #endif
    }

    // MARK: - Header

    /// The compact identity, version, commit, and build-configuration header.
    private var header: some View {
        VStack(spacing: 4) {
            appIcon
                .padding(.bottom, 2)

            Text(AppInfo.name)
                .font(nameFont)

            Text("Version \(AppInfo.version) (\(AppInfo.build))")
                .font(.headline.weight(.light))
                .foregroundStyle(.secondary)

            if let shortCommit = AppInfo.shortCommit, let commitURL = AppInfo.commitURL {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text("Commit")
                        .foregroundStyle(.secondary)

                    Link(shortCommit, destination: commitURL)
                        .font(.subheadline.monospaced())
                        .accessibilityLabel("Commit \(shortCommit)")
                        .help("View the commit of this build")

                    if AppInfo.isDebugBuild {
                        Image(systemName: "ladybug.circle.fill")
                            .symbolRenderingMode(.hierarchical)
                            .foregroundStyle(.mint)
                            .accessibilityLabel("Debug build")
                    }
                }
                .font(.subheadline)
            } else if AppInfo.isDebugBuild {
                Label("Debug build", systemImage: "ladybug.circle.fill")
                    .font(.subheadline)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.mint)
            }
        }
        .multilineTextAlignment(.center)
    }

    /// The native application icon or a platform-neutral fallback.
    @ViewBuilder
    private var appIcon: some View {
        if let icon = AppInfo.icon {
            #if os(macOS)
            Image(nsImage: icon)
                .resizable()
                .scaledToFit()
                .frame(width: 96, height: 96)
                .accessibilityLabel("\(AppInfo.name) app icon")
            #else
            Image(uiImage: icon)
                .resizable()
                .scaledToFit()
                .frame(width: 96, height: 96)
                .accessibilityLabel("\(AppInfo.name) app icon")
            #endif
        } else {
            Image(systemName: "camera.macro")
                .resizable()
                .scaledToFit()
                .foregroundStyle(.tint)
                .frame(width: 72, height: 72)
                .padding(12)
                .accessibilityLabel("\(AppInfo.name) app icon")
        }
    }

    // MARK: - Platform Content

    #if os(macOS)
    /// The compact macOS footer with a collapsible inline license.
    private var macContent: some View {
        VStack(spacing: 12) {
            Divider()
                .padding(.top, 12)

            if !showsLicense, let copyright = AppInfo.copyright {
                Text(copyright)
                    .font(.subheadline)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
            }

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { macActions }
                VStack(spacing: 8) { macActions }
            }
            .buttonStyle(.bordered)

            if showsLicense {
                Divider()
                license
            }
        }
    }

    /// The project and license actions displayed in the macOS About window.
    @ViewBuilder
    private var macActions: some View {
        if let projectURL = AppInfo.projectURL {
            Link(destination: projectURL) {
                Label("Project Website", systemImage: "globe.asia.australia")
                    .frame(minWidth: 120, maxWidth: .infinity)
            }
        }

        Button {
            showsLicense.toggle()
        } label: {
            Label(showsLicense ? "Hide License" : "View License", systemImage: showsLicense ? "scroll.fill" : "scroll")
                .frame(minWidth: 120, maxWidth: .infinity)
        }
        .accessibilityValue(showsLicense ? "Expanded" : "Collapsed")
    }
    #else
    /// The full iOS About document with the bundled license always visible.
    private var iosContent: some View {
        VStack(spacing: 16) {
            if let copyright = AppInfo.copyright {
                Text(copyright)
                    .font(.subheadline)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
            }

            if let projectURL = AppInfo.projectURL {
                Link(destination: projectURL) {
                    Label("Project Website", systemImage: "globe.asia.australia")
                }
                .buttonStyle(.bordered)
            }

            Divider()
            license
        }
        .padding(.top, 16)
    }
    #endif

    // MARK: - License

    /// The styled bundled license with safe plain-text and unavailable fallbacks.
    @ViewBuilder
    private var license: some View {
        if let licenseText = AppInfo.licenseText {
            Group {
                if let document = try? AttributedString(styledMarkdown: licenseText) {
                    Text(document)
                } else {
                    Text(licenseText)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
        } else {
            ContentUnavailableView(
                "License Unavailable",
                systemImage: "doc.badge.ellipsis",
                description: Text("The bundled license could not be loaded.")
            )
        }
    }

    // MARK: - Platform Metrics

    /// The title font appropriate for the current platform presentation.
    private var nameFont: Font {
        #if os(macOS)
        .largeTitle
        #else
        .title.bold()
        #endif
    }

    /// The outer content padding appropriate for the current platform.
    private var contentPadding: CGFloat {
        #if os(macOS)
        20
        #else
        24
        #endif
    }
}

#if DEBUG
#if os(macOS)
#Preview("About") {
    AboutView()
        .frame(idealWidth: 420, idealHeight: 300)
}

#Preview("About with License") {
    AboutView(showLicense: true)
        .frame(idealWidth: 520, idealHeight: 640)
}
#else
#Preview("About") {
    NavigationStack {
        AboutView()
            .navigationTitle("About Tshunhue")
    }
    .frame(width: 320, height: 640)
}
#endif
#endif
