//
//  SearchIndex.swift
//  Tshunhue
//
//  Indexes normalized captions and tags for asynchronous local search.
//

import Foundation

/// An actor-isolated in-memory search index for catalog frames.
actor SearchIndex {
    /// A frame paired with its normalized searchable values.
    private struct Entry: Sendable {
        let frame: CatalogFrame
        let caption: String
        let tags: [String]
    }

    private var entries: [Entry] = []

    /// Replaces the entire index with the current enabled catalog frames.
    func replace(with frames: [CatalogFrame]) {
        entries = frames.map { frame in
            let locale = Locale(identifier: frame.language)
            return Entry(
                frame: frame,
                caption: Self.normalize(frame.frame.caption, locale: locale),
                tags: frame.tags.map { Self.normalize($0, locale: locale) }
            )
        }
    }

    /// Finds frames containing every query term and ranks caption matches first.
    func search(_ query: String, categoryIDs: Set<CategoryKey>) -> [CatalogFrame] {
        let rawTerms = query.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !rawTerms.isEmpty else { return [] }

        return entries.compactMap { entry -> (CatalogFrame, Int)? in
            guard categoryIDs.isEmpty || categoryIDs.contains(entry.frame.categoryKey) else { return nil }
            let locale = Locale(identifier: entry.frame.language)
            let terms = rawTerms.map { Self.normalize($0, locale: locale) }
            guard terms.allSatisfy({ term in
                entry.caption.contains(term) || entry.tags.contains(where: { $0.contains(term) })
            }) else { return nil }

            let normalizedQuery = Self.normalize(query, locale: locale)
            let score: Int
            if entry.caption == normalizedQuery {
                score = 400
            } else if entry.caption.hasPrefix(normalizedQuery) {
                score = 300
            } else if terms.allSatisfy({ entry.caption.contains($0) }) {
                score = 200
            } else {
                score = 100
            }
            return (entry.frame, score)
        }
        .sorted { lhs, rhs in
            if lhs.1 != rhs.1 { return lhs.1 > rhs.1 }
            if lhs.0.sourceName != rhs.0.sourceName { return lhs.0.sourceName < rhs.0.sourceName }
            if lhs.0.categoryName != rhs.0.categoryName { return lhs.0.categoryName < rhs.0.categoryName }
            return lhs.0.order < rhs.0.order
        }
        .map(\.0)
    }

    /// Folds case, diacritics, and width using the frame's language locale.
    private static func normalize(_ value: String, locale: Locale) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: locale)
    }
}
