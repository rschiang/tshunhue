//
//  CatalogModels.swift
//  Tshunhue
//
//  Defines catalog documents and the resolved models used for browsing and search.
//

import Foundation

// MARK: - Catalog Documents

/// A source's top-level index document.
struct Index: Codable, Hashable, Sendable {
    /// The data-format version.
    let version: Int
    /// The source's display name.
    let name: String
    /// An optional project or community homepage.
    let homepage: String?
    /// An optional contact destination.
    let contact: String?
    /// An optional base URL for content reports.
    let report: String?
    /// The categories published by this source.
    let categories: [CategoryDescriptor]
}

/// A compact category record embedded in an index.
struct CategoryDescriptor: Codable, Hashable, Identifiable, Sendable {
    /// The stable category identifier.
    let id: String
    /// The category's display name.
    let name: String
    /// An optional language identifier repeated by the category document.
    let language: String?
    /// The category document URL, possibly relative to the index.
    let url: String
    /// An optional advertised frame count.
    let frames: Int?
}

/// A category document containing searchable reaction-image frames.
struct Category: Codable, Hashable, Identifiable, Sendable {
    /// The data-format version.
    let version: Int
    /// The stable category identifier.
    let id: String
    /// The category's display name.
    let name: String
    /// The language used by captions and tags.
    let language: String
    /// Optional copyright or source attribution.
    let attribution: Attribution?
    /// Optional category-wide legitimate viewing destinations.
    let providers: [Provider]?
    /// Optional named divisions such as episodes.
    let subsections: [Subsection]?
    /// The reaction-image entries in source order.
    let frames: [Frame]
}

/// Copyright or source credit associated with a category.
struct Attribution: Codable, Hashable, Sendable {
    /// Human-readable attribution text.
    let text: String
    /// An optional HTTPS destination for the attribution.
    let url: String?
}

/// A legitimate viewing destination that may interpolate a frame timecode.
struct Provider: Codable, Hashable, Sendable {
    /// The provider's display name.
    let name: String
    /// An HTTPS URL supporting optional timecode placeholders.
    let url: String

    /// Resolves supported placeholders into a concrete provider destination.
    func destination(for timecode: Timecode?) -> URL? {
        let milliseconds = timecode?.milliseconds ?? 0
        let rendered = url
            .replacingOccurrences(of: "{seconds}", with: String(milliseconds / 1_000))
            .replacingOccurrences(of: "{milliseconds}", with: String(milliseconds))
        return URL(string: rendered)
    }
}

/// A named subdivision of a category, such as an episode or chapter.
struct Subsection: Codable, Hashable, Identifiable, Sendable {
    /// The stable subsection identifier.
    let id: String
    /// The subsection's display name.
    let name: String
    /// Optional destinations overriding category-wide providers.
    let providers: [Provider]?
}

/// One reaction image and its searchable metadata.
struct Frame: Codable, Hashable, Sendable {
    /// An optional author-supplied stable identifier.
    let id: String?
    /// The image URL, possibly relative to its category document.
    let url: String
    /// The spoken line or reaction caption.
    let caption: String
    /// Optional searchable labels such as character names.
    let tags: [String]?
    /// The optional owning subsection identifier.
    let subsection: String?
    /// The optional moment represented by the frame.
    let timecode: Timecode?
}

// MARK: - Timecodes

/// A nonnegative media time normalized to integer milliseconds.
struct Timecode: Hashable, Sendable {
    /// The normalized time offset.
    let milliseconds: Int64

    /// Creates a timecode from a nonnegative millisecond value.
    init(milliseconds: Int64) throws {
        guard milliseconds >= 0 else { throw TimecodeError.negative }
        self.milliseconds = milliseconds
    }

    /// Creates a timecode from a finite, nonnegative second value.
    init(seconds: Double) throws {
        guard seconds.isFinite, seconds >= 0,
              seconds <= Double(Int64.max) / 1_000 else {
            throw TimecodeError.invalid
        }
        self.milliseconds = Int64((seconds * 1_000).rounded())
    }

    /// Parses `MM:SS`, `HH:MM:SS`, and optional millisecond fractions.
    init(parsing value: String) throws {
        let normalized = value.replacingOccurrences(of: ",", with: ".")
        let components = normalized.split(separator: ":", omittingEmptySubsequences: false)
        guard components.count == 2 || components.count == 3 else {
            throw TimecodeError.invalid
        }

        let hours: Int64
        let minutes: Int64
        let secondsComponent: Substring
        if components.count == 3 {
            guard let parsedHours = Int64(components[0]),
                  let parsedMinutes = Int64(components[1]),
                  parsedHours >= 0,
                  parsedMinutes >= 0,
                  components[1].count == 2,
                  parsedMinutes < 60 else {
                throw TimecodeError.invalid
            }
            hours = parsedHours
            minutes = parsedMinutes
            secondsComponent = components[2]
        } else {
            guard let parsedMinutes = Int64(components[0]), parsedMinutes >= 0 else {
                throw TimecodeError.invalid
            }
            hours = 0
            minutes = parsedMinutes
            secondsComponent = components[1]
        }

        let secondParts = secondsComponent.split(separator: ".", omittingEmptySubsequences: false)
        guard secondParts.count <= 2,
              secondParts[0].count == 2,
              let seconds = Int64(secondParts[0]),
              seconds >= 0,
              seconds < 60 else {
            throw TimecodeError.invalid
        }

        var fraction: Int64 = 0
        if secondParts.count == 2 {
            let digits = secondParts[1]
            guard (1...3).contains(digits.count), digits.allSatisfy(\.isNumber) else {
                throw TimecodeError.invalid
            }
            let padded = digits + String(repeating: "0", count: 3 - digits.count)
            guard let parsedFraction = Int64(padded) else { throw TimecodeError.invalid }
            fraction = parsedFraction
        }

        let (hourMilliseconds, hourOverflow) = hours.multipliedReportingOverflow(by: 3_600_000)
        let (minuteMilliseconds, minuteOverflow) = minutes.multipliedReportingOverflow(by: 60_000)
        let (secondMilliseconds, secondOverflow) = seconds.multipliedReportingOverflow(by: 1_000)
        let (hoursAndMinutes, firstAdditionOverflow) = hourMilliseconds.addingReportingOverflow(minuteMilliseconds)
        let (throughSeconds, secondAdditionOverflow) = hoursAndMinutes.addingReportingOverflow(secondMilliseconds)
        let (total, finalAdditionOverflow) = throughSeconds.addingReportingOverflow(fraction)
        guard !hourOverflow, !minuteOverflow, !secondOverflow,
              !firstAdditionOverflow, !secondAdditionOverflow, !finalAdditionOverflow else {
            throw TimecodeError.invalid
        }
        self.milliseconds = total
    }

    /// The normalized clock representation used for display and encoding.
    var displayString: String {
        let totalSeconds = milliseconds / 1_000
        let fraction = milliseconds % 1_000
        let hours = totalSeconds / 3_600
        let minutes = (totalSeconds % 3_600) / 60
        let seconds = totalSeconds % 60
        let base = hours > 0
            ? String(format: "%02lld:%02lld:%02lld", hours, minutes, seconds)
            : String(format: "%02lld:%02lld", totalSeconds / 60, seconds)
        return fraction == 0 ? base : base + String(format: ".%03lld", fraction)
    }
}

/// Decodes timecodes from either numeric seconds or clock strings.
extension Timecode: Codable {
    /// Decodes numeric seconds or a supported clock string.
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let number = try? container.decode(Double.self) {
            try self.init(seconds: number)
        } else {
            try self.init(parsing: container.decode(String.self))
        }
    }

    /// Encodes the normalized clock representation.
    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(displayString)
    }
}

/// Errors produced while normalizing timecodes.
enum TimecodeError: LocalizedError {
    case negative
    case invalid

    var errorDescription: String? {
        switch self {
        case .negative: "Timecodes cannot be negative."
        case .invalid: "The timecode is not a supported number or clock value."
        }
    }
}

// MARK: - Browse Models

/// A stable frame identity scoped to its source and category.
struct FrameIdentity: Hashable, Codable, Sendable {
    /// The canonical index URL.
    let sourceURL: URL
    /// The owning category identifier.
    let categoryID: String
    /// The explicit or derived frame identifier.
    let frameID: String
}

/// A stable category identity scoped to its source.
struct CategoryKey: Hashable, Codable, Sendable {
    /// The canonical index URL.
    let sourceURL: URL
    /// The source-local category identifier.
    let categoryID: String
}

/// The user's current browsing filter.
enum CatalogScope: Hashable, Sendable {
    case recents
    case all
    case index(URL)
    case category(CategoryKey)
}

/// Resolves browse scopes into category filters and ordered frames.
enum CatalogScopeResolver {
    /// Returns the categories searched by a scope, or an empty set for all categories.
    static func categoryFilter(for scope: CatalogScope, in sources: [SourceSummary]) -> Set<CategoryKey> {
        switch scope {
        case .recents, .all:
            return []
        case .index(let sourceURL):
            guard let source = sources.first(where: { $0.sourceURL == sourceURL }) else { return [] }
            return Set(source.enabledCategoryIDs.map {
                CategoryKey(sourceURL: sourceURL, categoryID: $0)
            })
        case .category(let key):
            return [key]
        }
    }

    /// Filters the full catalog into the frames represented by a scope.
    static func frames(
        for scope: CatalogScope,
        in allFrames: [CatalogFrame],
        recentIdentities: [FrameIdentity]
    ) -> [CatalogFrame] {
        switch scope {
        case .recents:
            return recentIdentities.compactMap { identity in
                allFrames.first { $0.identity == identity }
            }
        case .all:
            return allFrames
        case .index(let sourceURL):
            return allFrames.filter { $0.identity.sourceURL == sourceURL }
        case .category(let key):
            return allFrames.filter { $0.categoryKey == key }
        }
    }

    /// Returns whether a persisted scope still exists in the current sources.
    static func isValid(_ scope: CatalogScope, in sources: [SourceSummary]) -> Bool {
        switch scope {
        case .recents, .all:
            return true
        case .index(let sourceURL):
            guard let source = sources.first(where: { $0.sourceURL == sourceURL }) else { return false }
            return !source.enabledCategoryIDs.isEmpty
        case .category(let key):
            guard let source = sources.first(where: { $0.sourceURL == key.sourceURL }) else { return false }
            return source.enabledCategoryIDs.contains(key.categoryID)
        }
    }
}

/// A validated frame enriched with resolved source, ordering, and link metadata.
struct CatalogFrame: Identifiable, Hashable, Sendable {
    /// The frame's stable cross-launch identity.
    let identity: FrameIdentity
    /// The source display name.
    let sourceName: String
    /// The owning category identifier.
    let categoryID: String
    /// The owning category display name.
    let categoryName: String
    /// The language used to normalize search terms.
    let language: String
    /// The resolved subsection, when supplied.
    let subsection: Subsection?
    /// The original frame document value.
    let frame: Frame
    /// The explicit or derived frame identifier.
    let effectiveID: String
    /// The absolute validated image URL.
    let imageURL: URL
    /// The providers effective for this frame.
    let providers: [Provider]
    /// The category's optional attribution.
    let attribution: Attribution?
    /// The source's optional content-report URL.
    let reportURL: URL?
    /// The category's order in its source index.
    let categoryOrder: Int
    /// The subsection's order in its category.
    let subsectionOrder: Int?
    /// The frame's order in its category.
    let order: Int

    /// The identity required by `Identifiable`.
    var id: FrameIdentity { identity }
    /// Search tags with absent metadata normalized to an empty array.
    var tags: [String] { frame.tags ?? [] }
    /// The category identity containing this frame.
    var categoryKey: CategoryKey { CategoryKey(sourceURL: identity.sourceURL, categoryID: categoryID) }
}

/// One category or subsection section in the grouped image grid.
struct FrameSection: Identifiable, Sendable {
    /// A stable section identity for either grouping mode.
    enum ID: Hashable, Sendable {
        case category(CategoryKey)
        case subsection(CategoryKey, String?)
    }

    /// The stable section identity.
    let id: ID
    /// The section's primary heading.
    let title: String
    /// Optional secondary source context.
    let subtitle: String?
    /// Frames displayed in this section.
    let frames: [CatalogFrame]
}

/// Builds deterministic grid sections from validated frame ordering.
enum FrameSectionBuilder {
    /// Groups a category scope by subsection and other scopes by category.
    static func sections(
        from frames: [CatalogFrame],
        scope: CatalogScope,
        sources: [SourceSummary]
    ) -> [FrameSection] {
        if case .category(let categoryKey) = scope {
            return subsectionSections(from: frames, categoryKey: categoryKey)
        }
        return categorySections(from: frames, sources: sources)
    }

    /// Groups frames by category while retaining source and index order.
    private static func categorySections(
        from frames: [CatalogFrame],
        sources: [SourceSummary]
    ) -> [FrameSection] {
        let sourceOrder = Dictionary(uniqueKeysWithValues: sources.enumerated().map { ($0.element.sourceURL, $0.offset) })
        let grouped = Dictionary(grouping: frames, by: \.categoryKey)
        let ordered: [(sourceOrder: Int, categoryOrder: Int, title: String, section: FrameSection)] = grouped.compactMap { key, sectionFrames in
            guard let first = sectionFrames.first else { return nil }
            return (
                sourceOrder[key.sourceURL] ?? .max,
                first.categoryOrder,
                first.categoryName,
                FrameSection(
                    id: .category(key),
                    title: first.categoryName,
                    subtitle: first.sourceName,
                    frames: sectionFrames
                )
            )
        }
        return ordered.sorted { lhs, rhs in
            if lhs.0 != rhs.0 { return lhs.0 < rhs.0 }
            if lhs.1 != rhs.1 { return lhs.1 < rhs.1 }
            return lhs.2 < rhs.2
        }
        .map(\.section)
    }

    /// Groups one category's frames by subsection order.
    private static func subsectionSections(
        from frames: [CatalogFrame],
        categoryKey: CategoryKey
    ) -> [FrameSection] {
        let grouped = Dictionary(grouping: frames) { $0.subsection?.id }
        let ordered: [(subsectionOrder: Int, title: String, section: FrameSection)] = grouped.compactMap { subsectionID, sectionFrames in
            guard let first = sectionFrames.first else { return nil }
            return (
                first.subsectionOrder ?? .max,
                first.subsection?.name ?? String(localized: "No Subsection"),
                FrameSection(
                    id: .subsection(categoryKey, subsectionID),
                    title: first.subsection?.name ?? String(localized: "No Subsection"),
                    subtitle: nil,
                    frames: sectionFrames
                )
            )
        }
        return ordered.sorted { lhs, rhs in
            if lhs.0 != rhs.0 { return lhs.0 < rhs.0 }
            return lhs.1 < rhs.1
        }
        .map(\.section)
    }
}

// MARK: - Validation Results and Configuration

/// An index whose source and category URLs have been validated and resolved.
struct ValidatedIndex: Sendable {
    /// The canonical source URL.
    let sourceURL: URL
    /// The decoded source index.
    let index: Index
    /// Descriptors paired with their absolute category document URLs.
    let categories: [(descriptor: CategoryDescriptor, url: URL)]
}

/// A validated category paired with its application-ready frames.
struct ValidatedCategory: Sendable {
    /// The decoded category document.
    let category: Category
    /// Application-ready frames resolved from the category.
    let frames: [CatalogFrame]
}

/// The bundled list of catalog sources restored on first launch.
struct DefaultSourceConfiguration: Codable, Sendable {
    /// Index URLs shipped as the app's default sources.
    let sources: [URL]
}
