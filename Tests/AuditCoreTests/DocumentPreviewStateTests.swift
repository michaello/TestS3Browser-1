import Foundation
import Testing
@testable import AuditCore

@Suite("N47 numbered text retains original lines")
@MainActor
struct N47NumberedTextTests {
    @Test("LF, CRLF, mixed, blank and trailing lines preserve numbering", arguments: [
        ("", [""]),
        ("one", ["one"]),
        ("one\n\nthree\n", ["one", "", "three", ""]),
        ("one\r\n\r\nthree\r\n", ["one", "", "three", ""]),
        ("one\r\n\ntwo\n\r\n", ["one", "", "two", "", ""]),
        ("\n\n", ["", "", ""]),
        ("\r\n\r\n", ["", "", ""])
    ])
    func lineEndings(fixture: (String, [String])) {
        let preview = NumberedTextPreview()
        let original = Data(fixture.0.utf8)
        preview.update(PreviewTextInput(text: fixture.0))
        #expect(preview.lines.map { String($0.text) } == fixture.1)
        #expect(preview.lines.map(\.number) == Array(1...fixture.1.count))
        #expect(preview.lines.map(\.id) == Array(1...fixture.1.count))
        #expect(Data(fixture.0.utf8) == original)
    }

    @Test("Changed source updates rows while unchanged progress-style updates reuse derivation")
    func reusesDerivedLines() {
        let preview = NumberedTextPreview()
        let large = String(repeating: "line\r\n\r\n", count: 10_000)
        preview.update(PreviewTextInput(text: large))
        #expect(preview.lines.count == 20_001)
        for _ in 0..<100 { preview.update(PreviewTextInput(text: large)) }
        #expect(preview.derivationCount == 1)
        preview.update(PreviewTextInput(text: "changed\n"))
        #expect(preview.derivationCount == 2)
        #expect(preview.lines.map { String($0.text) } == ["changed", ""])
    }

    @Test("Preview derivation preserves exact Unicode source bytes")
    func unicodeBytes() {
        let preview = NumberedTextPreview()
        preview.update(PreviewTextInput(text: "é\n"))
        preview.update(PreviewTextInput(text: "e\u{301}\n"))
        #expect(preview.derivationCount == 2)
        #expect(Array(preview.lines[0].text.utf8) == Array("e\u{301}".utf8))
    }
}

@Suite("N45 HTML updates preserve document render state")
struct N45HTMLDocumentTests {
    @Test("Initial make and repeated identical updates load once and retain unrelated state")
    func unchangedUpdatesDoNotReload() {
        var gate = HTMLDocumentLoadGate()
        var requests: [String] = []
        var scrollPosition = 42
        #expect(gate.load(documentID: "bucket/report.html", html: "<html>report</html>") {
            requests.append($0)
            scrollPosition = 0
        })
        scrollPosition = 120
        for _ in 0..<100 {
            #expect(gate.load(documentID: "bucket/report.html", html: "<html>report</html>", using: {
                requests.append($0)
                scrollPosition = 0
            }) == false)
        }
        #expect(requests == ["<html>report</html>"])
        #expect(gate.loadCount == 1)
        #expect(scrollPosition == 120)
    }

    @Test("New identity or content loads exactly once and leaves other state untouched")
    func changedDocumentsLoad() {
        var gate = HTMLDocumentLoadGate()
        var requests: [String] = []
        for (identity, html) in [("a", "one"), ("a", "one"), ("b", "one"), ("b", "two"), ("b", "two")] {
            gate.load(documentID: identity, html: html) { requests.append($0) }
        }
        #expect(requests == ["one", "one", "two"])
        #expect(gate.loadCount == 3)
    }

    @Test("Byte-distinct Unicode identity and HTML content changes are not dropped")
    func byteExactChanges() {
        var gate = HTMLDocumentLoadGate()
        var requests: [String] = []
        gate.load(documentID: "é", html: "é") { requests.append($0) }
        gate.load(documentID: "e\u{301}", html: "é") { requests.append($0) }
        gate.load(documentID: "e\u{301}", html: "e\u{301}") { requests.append($0) }
        #expect(gate.loadCount == 3)
        #expect(Array(requests[2].utf8) == Array("e\u{301}".utf8))
    }
}
