import Foundation

struct Index: Codable, Hashable, Sendable {
    let version: Int
    let name: String
    let homepage: String?
    let contact: String?
    let report: String?
    let categories: [CategoryDescriptor]
}

struct CategoryDescriptor: Codable, Hashable, Identifiable, Sendable {
    let id: String
    let name: String
    let language: String?
    let url: String
    let frames: Int?
}

struct Category: Codable, Hashable, Identifiable, Sendable {
    let version: Int
    let id: String
    let name: String
    let language: String
    let attribution: Attribution?
    let providers: [Provider]?
    let subsections: [Subsection]?
    let frames: [Frame]
}

struct Attribution: Codable, Hashable, Sendable {
    let text: String
    let url: String?
}

struct Provider: Codable, Hashable, Sendable {
    let name: String
    let url: String

    func destination(for timecode: Timecode?) -> URL? {
        let milliseconds = timecode?.milliseconds ?? 0
        let rendered = url
            .replacingOccurrences(of: "{seconds}", with: String(milliseconds / 1_000))
            .replacingOccurrences(of: "{milliseconds}", with: String(milliseconds))
        return URL(string: rendered)
    }
}

struct Subsection: Codable, Hashable, Identifiable, Sendable {
    let id: String
    let name: String
    let providers: [Provider]?
}

struct Frame: Codable, Hashable, Sendable {
    let id: String?
    let url: String
    let caption: String
    let tags: [String]?
    let subsection: String?
    let timecode: Timecode?
}

struct Timecode: Hashable, Sendable {
    let milliseconds: Int64

    init(milliseconds: Int64) throws {
        guard milliseconds >= 0 else { throw TimecodeError.negative }
        self.milliseconds = milliseconds
    }

    init(seconds: Double) throws {
        guard seconds.isFinite, seconds >= 0,
              seconds <= Double(Int64.max) / 1_000 else {
            throw TimecodeError.invalid
        }
        self.milliseconds = Int64((seconds * 1_000).rounded())
    }

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

extension Timecode: Codable {
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let number = try? container.decode(Double.self) {
            try self.init(seconds: number)
        } else {
            try self.init(parsing: container.decode(String.self))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(displayString)
    }
}

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

struct FrameIdentity: Hashable, Codable, Sendable {
    let sourceURL: URL
    let categoryID: String
    let frameID: String
}

struct CategoryKey: Hashable, Codable, Sendable {
    let sourceURL: URL
    let categoryID: String
}

enum CatalogScope: Hashable, Sendable {
    case recents
    case all
    case index(URL)
    case category(CategoryKey)
}

enum CatalogScopeResolver {
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

struct CatalogFrame: Identifiable, Hashable, Sendable {
    let identity: FrameIdentity
    let sourceName: String
    let categoryID: String
    let categoryName: String
    let language: String
    let subsection: Subsection?
    let frame: Frame
    let effectiveID: String
    let imageURL: URL
    let providers: [Provider]
    let attribution: Attribution?
    let reportURL: URL?
    let categoryOrder: Int
    let subsectionOrder: Int?
    let order: Int

    var id: FrameIdentity { identity }
    var tags: [String] { frame.tags ?? [] }
    var categoryKey: CategoryKey { CategoryKey(sourceURL: identity.sourceURL, categoryID: categoryID) }
}

struct FrameSection: Identifiable, Sendable {
    enum ID: Hashable, Sendable {
        case category(CategoryKey)
        case subsection(CategoryKey, String?)
    }

    let id: ID
    let title: String
    let subtitle: String?
    let frames: [CatalogFrame]
}

enum FrameSectionBuilder {
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

struct ValidatedIndex: Sendable {
    let sourceURL: URL
    let index: Index
    let categories: [(descriptor: CategoryDescriptor, url: URL)]
}

struct ValidatedCategory: Sendable {
    let category: Category
    let frames: [CatalogFrame]
}

struct DefaultSourceConfiguration: Codable, Sendable {
    let sources: [URL]
}
