//
//  AboutView.swift
//  Tshunhue
//
//  Displays application information and version.
//

import SwiftUI

/// A compact, presentation-independent application identity view.
struct AboutView: View {

    private let icon: NSImage = AppInfo.icon!
    private let name = AppInfo.name!
    private let version = AppInfo.version!
    private let build = AppInfo.build!
    private let commit = AppInfo.commit!
    private let copyright = AppInfo.copyright!

    @State private var showLicense: Bool

    init(showLicense: Bool = false) {
        self.showLicense = showLicense
    }

    var body: some View {
        VStack(spacing: 0) {
            Image(nsImage: icon)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 128, height: 128)
                .focusable()
                .focusEffectDisabled()
                .padding(.bottom, 6)

            Text(name)
                .font(.largeTitle)
            Text("Version \(version) (\(build))")
                .font(.headline.weight(.light))
                .foregroundStyle(.secondary)
                .padding(.bottom, 12)

            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text("Commit")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                Button(commit.prefix(7), action: openProjectCommit)
                .controlSize(.small)
                .buttonStyle(.link)
                .font(.subheadline.monospaced())
                .pointerStyle(.link)
                .help("View the commit of this build")

                if (AppInfo.isDebugBuild) {
                    Image(systemName: "ladybug.circle.fill")
                        .font(.subheadline)
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(.mint)
                }
            }

            Divider()
                .padding(.vertical, 12)

            if (showLicense) {
                let document = try? AttributedString(styledMarkdown: AppInfo.licenseText!)
                ScrollView {
                    Text(document!)
                }
                .frame(maxWidth: .infinity, idealHeight: 240)
                .padding(.bottom, 12)
            } else {
                Text(copyright)
                    .font(.subheadline)
                    .foregroundStyle(.tertiary)
                    .padding(.bottom, 12)
            }

            HStack(spacing: showLicense ? 8 : 6) {
                Button(action: openProjectWebsite) {
                    Label("Project Website", systemImage: "globe.asia.australia")
                        .frame(minWidth: 80, maxWidth: .infinity)
                }
                .controlSize(showLicense ? .regular : .small)

                Button(action: toggleLicense) {
                    Label("View License", systemImage: showLicense ? "scroll.fill" : "scroll")
                        .frame(minWidth: 80, maxWidth: .infinity)
                        .foregroundStyle(showLicense ? .accent : .primary)
                }
                .controlSize(showLicense ? .regular : .small)
            }
        }
        .padding(20)
        .frame(maxWidth: showLicense ? 512 : 256)
        .animation(.default, value: showLicense)
        .fixedSize()
        .navigationTitle("About Tshunhue")
    }

    private func openProjectCommit() {
        let url = URL(string: "https://github.com/rschiang/tshunhue/commit/\(commit)")!
        NSWorkspace.shared.open(url)
    }

    private func openProjectWebsite() { NSWorkspace.shared.open(URL(string: "https://github.com/rschiang/tshunhue")!)
    }

    private func toggleLicense() {
        showLicense = !showLicense
    }
}

#if DEBUG
#Preview("About") {
    AboutView()
}

#Preview("Show License") {
    AboutView(showLicense: true)
}
#endif
