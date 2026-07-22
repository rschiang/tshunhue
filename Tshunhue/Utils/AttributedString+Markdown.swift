//
//  AttributedString+Markdown.swift
//  Funban
//
//  Extended styles on Markdown.
//

import SwiftUI

extension AttributedString {

    public init?(styledMarkdown: String) throws {
        // Tidy up the document typography and formatting
        let formattedMarkdown = styledMarkdown
            .replacing(/--(?=[^\-])/, with: "—") // Em dash
            .replacing(/\\`([A-Za-z ]+)'/) { "`\($0.1)`" }  // Code formatting
            .replacing(/"([^"\n]+)"/) { "“\($0.1)”" }       // Smart quotes
            .replacing(/([A-Za-z])'([A-Za-z])/) { "\($0.1)’\($0.2)" }   // Smart apostrophes
            .replacing(/([A-Za-z])'(?=\b)/) { "\($0.1)’" }  // Smart apostrophes at the end
            .replacing(/(?:\(|\b)[a-z0-9]\)/) { "**\($0.0)**" }         // List markers

        // Parse the markdown
        try? self.init(markdown: formattedMarkdown,
                       options: .init(allowsExtendedAttributes: true, interpretedSyntax: .full))

        // Set up inline styles
        for (intent, range) in self.runs[AttributeScopes.FoundationAttributes.InlinePresentationIntentAttribute.self] {
            guard let intent else { continue }
            if intent.contains(.code) {
                self[range].font = .subheadline.monospaced()
                self[range].tracking = -0.15
            } else if intent.contains(.stronglyEmphasized) {
                self[range].font = .body.weight(.medium)
            }
        }

        // Iterate over parsed markdown and set relevant styles
        for (block, range) in self.runs[AttributeScopes.FoundationAttributes.PresentationIntentAttribute.self].reversed() {
            guard let block else { continue }
            for intent in block.components {
                switch intent.kind {
                case .header(level: 1):
                    self[range].font = .title2.weight(.bold)
                    self.characters.insert("\n", at: range.upperBound)
                    continue
                case .header(let level):
                    self[range].font = (level == 2) ? .title3.weight(.bold) : .headline.weight(.bold)
                case .codeBlock:
                    self[range].font = .subheadline.monospaced()
                    self[range].tracking = -0.15
                    self.characters.insert("\n", at: range.lowerBound)
                    continue
                case .paragraph:
                    // Turning shouting all-caps to milder representation
                    if !self[range].characters.contains(where: \.isLowercase) {
                        self[range].font = .body.width(.condensed)
                        self[range].tracking = 0.06
                    }
                default: continue
                }
                // Add necessary line breaks
                self.characters.insert("\n", at: range.upperBound)
                self.characters.insert("\n", at: range.lowerBound)
            }
        }
    }
}
