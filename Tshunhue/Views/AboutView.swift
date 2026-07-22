//
//  AboutView.swift
//  Tshunhue
//
//  Presents responsive application information and the bundled license.
//

import SwiftUI

/// A cross-platform application identity and license view.
struct AboutView: View {

    var body: some View {
        GeometryReader { proxy in
            ScrollView {
                VStack(spacing: 12) {
                    header.frame(minHeight: proxy.size.height - contentPadding * 2 - 12)
                    Image(systemName: "chevron.down")
                        .foregroundStyle(.tertiary)
                    #if os(iOS)
                        .padding(.bottom, proxy.safeAreaInsets.bottom)
                    #endif
                    Divider()
                    license
                }.padding(contentPadding)
            }
        }
        #if os(macOS)
        .frame(width: 360, height: 480)
        #endif
    }

    // MARK: - Header

    /// The compact identity, version, commit, and build-configuration header.
    private var header: some View {
        VStack(spacing: 6) {
            appIcon
                .padding(.bottom, 12)
                .focusable()
                .focusEffectDisabled()

            Link(AppInfo.name, destination: AppInfo.projectURL)
                .font(nameFont)
                .foregroundStyle(.primary)
                .padding(.bottom, 6)
                .help("Open the project website")
            #if os(macOS)
                .pointerStyle(.link)
            #endif

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
                            .foregroundStyle(.indigo)
                            .accessibilityLabel("Debug build")
                    }
                }
                .font(.subheadline)
                .padding(.bottom, 12)
            }

            if let copyright = AppInfo.copyright {
                Text(copyright)
                    .font(.subheadline)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
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
        }
    }

    // MARK: - License

    /// The styled bundled license with safe plain-text and unavailable fallbacks.
    @ViewBuilder
    private var license: some View {
        VStack(spacing: 6) {
            if let licenseText = AppInfo.licenseText,
               let document = try? AttributedString(styledMarkdown: licenseText) {
                Text(document).textSelection(.enabled)
            }
            Label("Wow, you actually read the license text!", systemImage: "party.popper")
                .font(.callout)
                .foregroundStyle(.accent.opacity(0.33))
                .imageScale(.large)
        }
    }

    // MARK: - Platform Metrics

    /// The title font appropriate for the current platform presentation.
    private var nameFont: Font {
        #if os(macOS)
        .largeTitle.weight(.semibold)
        #else
        .largeTitle.bold()
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
#Preview("About") {
#if os(macOS)
    AboutView()
#else
    NavigationStack {
        AboutView()
    }
#endif
}
#endif
