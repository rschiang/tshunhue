//
//  AppInfo.swift
//  Tshunhue
//
//  Application bundle metadata information.
//

import AppKit

/// Provides read-only access to app bundle metadata.
enum AppInfo {

    // MARK: Functions

    /// Returns a raw string value from the main bundle info dictionary.
    static func get(_ key: String) -> String? {
        Bundle.main.infoDictionary?[key] as? String
    }

    /// Returns a localized bundle string with raw value fallback.
    static func getLocalized(_ key: String) -> String? {
        if let localized = Bundle.main.localizedInfoDictionary?[key] as? String {
            return localized
        } else {
            return Bundle.main.infoDictionary?[key] as? String
        }
    }

    // MARK: Properties

    /// The localized application name.
    static var name: String? { Self.getLocalized("CFBundleName")! }

    /// The common version string.
    static var version: String? { Self.get("CFBundleShortVersionString")! }

    /// The build number string.
    static var build: String? {Self.get("CFBundleVersion")! }

    /// The `git` commit hash of the source code version this build compiles from.
    static var commit: String? { Self.get("TshunhueCommitSHA1")! }

    /// The localized copyright notice.
    static var copyright: String? { Self.getLocalized("NSHumanReadableCopyright")! }

    /// The application icon image.
    static var icon: NSImage? {
        guard let iconName = Self.get("CFBundleIconName") else { return nil }
        return NSImage(named: iconName)
    }

    /// The bundled license file URL.
    static var licenseURL: URL? { Bundle.main.url(forResource: "LICENSE", withExtension: "md") }

    /// The bundled license text.
    static var licenseText: String? {
        guard let url = licenseURL else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }

    // MARK: Configuration

    /// Whether this application is compiled with a debug configuration.
    static let isDebugBuild: Bool = DEBUG

}

// MARK: Helper Variables

#if DEBUG
private let DEBUG = true
#else
private let DEBUG = false
#endif
