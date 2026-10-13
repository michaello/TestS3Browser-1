import Foundation
import Observation

/// Compares source bytes rather than Swift String's canonical Unicode equivalence.
struct PreviewTextInput: Equatable, Sendable {
    let text: String

    static func == (lhs: Self, rhs: Self) -> Bool {
        // Native strings expose borrowed contiguous UTF-8 storage. Compare it directly,
        // avoiding per-byte iterator work and allocation on unrelated view updates.
        if let result = lhs.text.utf8.withContiguousStorageIfAvailable({ left in
            rhs.text.utf8.withContiguousStorageIfAvailable { right in
                guard left.count == right.count else { return false }
                guard let lhsBase = left.baseAddress, let rhsBase = right.baseAddress else {
                    return left.isEmpty && right.isEmpty
                }
                return lhsBase == rhsBase || memcmp(lhsBase, rhsBase, left.count) == 0
            }
        }), let result {
            return result
        }
        return lhs.text.utf8.elementsEqual(rhs.text.utf8)
    }
}

struct NumberedPreviewLine: Identifiable, Equatable, Sendable {
    let number: Int
    let text: Substring
    var id: Int { number }
}

/// Derives line rows only when source text changes. Original text remains untouched for export.
@MainActor @Observable
final class NumberedTextPreview {
    private(set) var lines: [NumberedPreviewLine] = []
    private(set) var derivationCount = 0
    @ObservationIgnored private var source: PreviewTextInput?

    func update(_ input: PreviewTextInput) {
        guard source != input else { return }
        source = input
        // CRLF is one Swift Character, so isNewline treats it as one separator.
        // Empty subsequences retain blank lines and the line after a terminal newline.
        lines = input.text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
            .enumerated()
            .map { NumberedPreviewLine(number: $0.offset + 1, text: $0.element) }
        derivationCount += 1
    }
}

/// Owns the last document loaded by one WKWebView, preserving web navigation/scroll state
/// when SwiftUI updates an unrelated control or progress value.
struct HTMLDocumentLoadGate {
    private var loadedIdentity: PreviewTextInput?
    private var loadedHTML: PreviewTextInput?
    private(set) var loadCount = 0

    @discardableResult
    mutating func load(documentID: String, html: String, using loadHTML: (String) -> Void) -> Bool {
        let identity = PreviewTextInput(text: documentID)
        let content = PreviewTextInput(text: html)
        guard identity != loadedIdentity || content != loadedHTML else { return false }
        loadedIdentity = identity
        loadedHTML = content
        loadCount += 1
        loadHTML(html)
        return true
    }
}
