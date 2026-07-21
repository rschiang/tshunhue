import CryptoKit
import Foundation

enum CatalogLimits {
    static let indexBytes = 2 * 1_024 * 1_024
    static let categoryBytes = 20 * 1_024 * 1_024
    static let framesPerCategory = Int(UInt16.max)
    static let imageBytes = 32 * 1_024 * 1_024
    static let imagePixels = 50_000_000
    static let redirects = 5
}

struct CatalogValidator: Sendable {
    private let decoder = JSONDecoder()
    private let idExpression = try! NSRegularExpression(pattern: "^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$")
    private let languageExpression = try! NSRegularExpression(pattern: "^[A-Za-z]{2,8}(?:-[A-Za-z0-9]{1,8})*$")

    func validateIndex(data: Data, sourceURL: URL) throws -> ValidatedIndex {
        guard data.count <= CatalogLimits.indexBytes else {
            throw CatalogValidationError.tooLarge("Index")
        }
        try requireAbsoluteHTTPS(sourceURL, field: "source URL")

        let index = try decode(Index.self, from: data)
        guard index.version == 1 else { throw CatalogValidationError.unsupportedVersion(index.version) }
        guard !index.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CatalogValidationError.empty("index name")
        }
        try validateExternalURL(index.homepage, field: "homepage")
        try validateExternalURL(index.contact, field: "contact")
        try validateExternalURL(index.report, field: "report")

        var ids = Set<String>()
        let categories = try index.categories.map { descriptor in
            try validateID(descriptor.id, field: "category ID")
            guard ids.insert(descriptor.id).inserted else {
                throw CatalogValidationError.duplicate("category ID \(descriptor.id)")
            }
            guard !descriptor.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw CatalogValidationError.empty("category name")
            }
            if let language = descriptor.language {
                try validateLanguage(language)
            }
            if let frames = descriptor.frames,
               !(0...CatalogLimits.framesPerCategory).contains(frames) {
                throw CatalogValidationError.invalid("frames")
            }
            return (descriptor, try resolveMediaURL(descriptor.url, relativeTo: sourceURL, field: "category URL"))
        }
        return ValidatedIndex(sourceURL: canonicalSourceURL(sourceURL), index: index, categories: categories)
    }

    func validateCategory(
        data: Data,
        documentURL: URL,
        descriptor: CategoryDescriptor,
        source: ValidatedIndex
    ) throws -> ValidatedCategory {
        guard data.count <= CatalogLimits.categoryBytes else {
            throw CatalogValidationError.tooLarge("Category")
        }
        let category = try decode(Category.self, from: data)
        guard category.version == 1 else { throw CatalogValidationError.unsupportedVersion(category.version) }
        guard category.id == descriptor.id else {
            throw CatalogValidationError.invalid("category ID does not match its index descriptor")
        }
        try validateLanguage(category.language)
        guard category.name == descriptor.name else {
            throw CatalogValidationError.invalid("category name does not match its index descriptor")
        }
        if let descriptorLanguage = descriptor.language,
           category.language != descriptorLanguage {
            throw CatalogValidationError.invalid("category language does not match its index descriptor")
        }
        guard category.frames.count <= CatalogLimits.framesPerCategory else {
            throw CatalogValidationError.tooManyFrames
        }

        try validateAttribution(category.attribution)
        try validateProviders(category.providers ?? [])

        var subsectionIDs = Set<String>()
        let subsections = category.subsections ?? []
        for subsection in subsections {
            try validateID(subsection.id, field: "subsection ID")
            guard subsectionIDs.insert(subsection.id).inserted else {
                throw CatalogValidationError.duplicate("subsection ID \(subsection.id)")
            }
            guard !subsection.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw CatalogValidationError.empty("subsection name")
            }
            try validateProviders(subsection.providers ?? [])
        }
        let subsectionsByID = Dictionary(uniqueKeysWithValues: subsections.map { ($0.id, $0) })
        let subsectionOrderByID = Dictionary(uniqueKeysWithValues: subsections.enumerated().map { ($0.element.id, $0.offset) })
        let categoryOrder = source.categories.firstIndex { $0.descriptor.id == category.id } ?? 0

        let reportURL = try source.index.report.map {
            let url = URL(string: $0)!
            try requireAbsoluteHTTPS(url, field: "report")
            return url
        }
        var effectiveIDs = Set<String>()
        var validatedFrames: [CatalogFrame] = []
        validatedFrames.reserveCapacity(category.frames.count)

        for (order, frame) in category.frames.enumerated() {
            guard !frame.caption.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw CatalogValidationError.empty("frame caption")
            }
            if let subsectionID = frame.subsection, subsectionsByID[subsectionID] == nil {
                throw CatalogValidationError.danglingSubsection(subsectionID)
            }
            for tag in frame.tags ?? [] where tag.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                throw CatalogValidationError.empty("frame tag")
            }
            if let explicitID = frame.id { try validateID(explicitID, field: "frame ID") }
            let effectiveID = frame.id ?? derivedFrameID(categoryID: category.id, frame: frame)
            guard effectiveIDs.insert(effectiveID).inserted else {
                throw CatalogValidationError.duplicate("effective frame ID \(effectiveID); add explicit frame IDs")
            }

            let subsection = frame.subsection.flatMap { subsectionsByID[$0] }
            let providers = subsection?.providers ?? category.providers ?? []
            let imageURL = try resolveMediaURL(frame.url, relativeTo: documentURL, field: "url")
            let identity = FrameIdentity(
                sourceURL: source.sourceURL,
                categoryID: category.id,
                frameID: effectiveID
            )
            validatedFrames.append(CatalogFrame(
                identity: identity,
                sourceName: source.index.name,
                categoryID: category.id,
                categoryName: category.name,
                language: category.language,
                subsection: subsection,
                frame: frame,
                effectiveID: effectiveID,
                imageURL: imageURL,
                providers: providers,
                attribution: category.attribution,
                reportURL: reportURL,
                categoryOrder: categoryOrder,
                subsectionOrder: frame.subsection.flatMap { subsectionOrderByID[$0] },
                order: order
            ))
        }
        return ValidatedCategory(category: category, frames: validatedFrames)
    }

    func derivedFrameID(categoryID: String, frame: Frame) -> String {
        let input = [
            categoryID,
            frame.subsection ?? "<none>",
            frame.timecode.map { String($0.milliseconds) } ?? "<none>",
            frame.caption,
        ].joined(separator: "\u{0}")
        let digest = SHA256.hash(data: Data(input.utf8))
        return digest.prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try decoder.decode(type, from: data)
        } catch {
            throw CatalogValidationError.decoding(error.localizedDescription)
        }
    }

    private func validateID(_ value: String, field: String) throws {
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        guard idExpression.firstMatch(in: value, range: range)?.range == range else {
            throw CatalogValidationError.invalid(field)
        }
    }

    private func validateLanguage(_ value: String) throws {
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        guard languageExpression.firstMatch(in: value, range: range)?.range == range else {
            throw CatalogValidationError.invalid("language")
        }
    }

    private func validateAttribution(_ attribution: Attribution?) throws {
        guard let attribution else { return }
        guard !attribution.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CatalogValidationError.empty("attribution text")
        }
        try validateExternalURL(attribution.url, field: "attribution URL")
    }

    private func validateProviders(_ providers: [Provider]) throws {
        for provider in providers {
            guard !provider.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw CatalogValidationError.empty("provider name")
            }
            let withoutSupportedPlaceholders = provider.url
                .replacingOccurrences(of: "{seconds}", with: "")
                .replacingOccurrences(of: "{milliseconds}", with: "")
            guard !withoutSupportedPlaceholders.contains("{"),
                  !withoutSupportedPlaceholders.contains("}") else {
                throw CatalogValidationError.invalid("provider URL placeholder")
            }
            let rendered = provider.url
                .replacingOccurrences(of: "{seconds}", with: "0")
                .replacingOccurrences(of: "{milliseconds}", with: "0")
            guard let url = URL(string: rendered) else {
                throw CatalogValidationError.invalid("provider URL")
            }
            try requireAbsoluteHTTPS(url, field: "provider URL")
        }
    }

    private func validateExternalURL(_ value: String?, field: String) throws {
        guard let value else { return }
        guard let url = URL(string: value) else { throw CatalogValidationError.invalid(field) }
        try requireAbsoluteHTTPS(url, field: field)
    }

    private func resolveMediaURL(_ value: String, relativeTo baseURL: URL, field: String) throws -> URL {
        guard let url = URL(string: value, relativeTo: baseURL)?.absoluteURL else {
            throw CatalogValidationError.invalid(field)
        }
        try requireAbsoluteHTTPS(url, field: field)
        return url
    }

    private func requireAbsoluteHTTPS(_ url: URL, field: String) throws {
        guard url.scheme?.lowercased() == "https", url.host != nil, url.user == nil, url.password == nil else {
            throw CatalogValidationError.invalid(field)
        }
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
}

enum CatalogValidationError: LocalizedError, Equatable {
    case decoding(String)
    case unsupportedVersion(Int)
    case invalid(String)
    case empty(String)
    case duplicate(String)
    case danglingSubsection(String)
    case tooLarge(String)
    case tooManyFrames

    var errorDescription: String? {
        switch self {
        case .decoding(let message): "The JSON could not be decoded: \(message)"
        case .unsupportedVersion(let version): "Version \(version) is not supported."
        case .invalid(let field): "The \(field) is invalid."
        case .empty(let field): "The \(field) cannot be empty."
        case .duplicate(let value): "Duplicate \(value)."
        case .danglingSubsection(let id): "Frame refers to missing subsection \(id)."
        case .tooLarge(let document): "The \(document.lowercased()) exceeds its size limit."
        case .tooManyFrames: "The category contains more than \(CatalogLimits.framesPerCategory) frames."
        }
    }
}
