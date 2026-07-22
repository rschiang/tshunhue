//
//  AppInfo.swift
//  Tshunhue
//
//  Provides cross-platform access to application bundle metadata and resources.
//

import Foundation
#if os(macOS)
import AppKit

/// The native image type used for the macOS application icon.
typealias AppIconImage = NSImage
#elseif os(iOS)
import UIKit

/// The native image type used for the iOS application icon.
typealias AppIconImage = UIImage
#endif

/// Provides read-only access to app bundle metadata and supporting links.
enum AppInfo {
    // MARK: - Bundle Values

    /// Returns a raw string value from the main bundle info dictionary.
    static func get(_ key: String) -> String? {
        Bundle.main.infoDictionary?[key] as? String
    }

    /// Returns a localized bundle string with a raw-value fallback.
    static func getLocalized(_ key: String) -> String? {
        Bundle.main.localizedInfoDictionary?[key] as? String ?? get(key)
    }

    /// The localized application name.
    static var name: String {
        getLocalized("CFBundleName") ?? "Tshunhue"
    }

    /// The common version string.
    static var version: String {
        Self.get("CFBundleShortVersionString") ?? "—"
    }

    /// The build number string.
    static var build: String {
        Self.get("CFBundleVersion") ?? "—"
    }

    /// The Git commit hash supplied by the existing build configuration.
    static var commit: String? {
        Self.get("TshunhueCommitSHA1")
    }

    /// The abbreviated Git commit displayed in About.
    static var shortCommit: String? {
        commit.map { String($0.prefix(7)) }
    }

    /// The localized copyright notice.
    static var copyright: String? {
        getLocalized("NSHumanReadableCopyright")
    }

    // MARK: - Links and Resources

    /// The public source repository for Tshunhue.
    static let projectURL = URL(string: "https://github.com/rschiang/tshunhue")

    /// The repository page for the commit represented by this build.
    static var commitURL: URL? {
        guard let projectURL, let commit else { return nil }
        return projectURL.appending(path: "commit").appending(path: commit)
    }

    /// The application icon resolved using the current platform's bundle conventions.
    static var icon: AppIconImage? {
        #if os(macOS)
        NSImage(named: NSImage.applicationIconName)
        #elseif os(iOS)
        guard let icons = Bundle.main.infoDictionary?["CFBundleIcons"] as? [String: Any],
              let primary = icons["CFBundlePrimaryIcon"] as? [String: Any],
              let filename = (primary["CFBundleIconFiles"] as? [String])?.last else {
            return nil
        }
        return UIImage(named: filename)
        #endif
    }

    /// The bundled license file URL.
    static var licenseURL: URL? {
        Bundle.main.url(forResource: "LICENSE", withExtension: "md")
    }

    /// The bundled license text.
    static var licenseText: String? {
        guard let licenseURL else { return nil }
        return try? String(contentsOf: licenseURL, encoding: .utf8)
    }

    // MARK: - Configuration

    /// Whether this application is compiled with a debug configuration.
    static let isDebugBuild: Bool = {
        #if DEBUG
        true
        #else
        false
        #endif
    }()
}
