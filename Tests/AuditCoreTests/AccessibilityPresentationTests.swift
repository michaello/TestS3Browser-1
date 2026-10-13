import SwiftUI
import Testing
@testable import AuditCore

@Suite("N08 semantic card text and accessible list layout")
@MainActor
struct N08FileCardAccessibilityTests {
    @Test("Card filename, metadata and chip styles are actual SwiftUI semantic fonts")
    func semanticFonts() {
        #expect(FileCardPresentation.filenameFont == Font.caption)
        #expect(FileCardPresentation.metadataFont == Font.caption2)
        #expect(FileCardPresentation.tagFont == Font.caption2)
    }

    @Test("Every accessibility category gets full filename wrapping and list alternative", arguments: DynamicTypeSize.allCases)
    func adaptiveCategories(_ category: DynamicTypeSize) {
        #expect(FileCardPresentation.prefersList(requestedGrid: true, isAccessibilitySize: category.isAccessibilitySize) == category.isAccessibilitySize)
        #expect(FileCardPresentation.prefersList(requestedGrid: false, isAccessibilitySize: category.isAccessibilitySize))
        #expect(FileCardPresentation.filenameLineLimit(isAccessibilitySize: category.isAccessibilitySize) == (category.isAccessibilitySize ? nil : 2))
    }

    @Test("Actual shared label view grows vertically for long names at accessibility sizes")
    func actualLabelLayout() throws {
        let name = "A long Unicode filename with spaces and repeated descriptive words 漢字.filename.jpg"
        let regular = ImageRenderer(content: FileCardLabels(name: name, detail: "12.3 MB")
            .environment(\.dynamicTypeSize, .large).frame(width: 100))
        let accessible = ImageRenderer(content: FileCardLabels(name: name, detail: "12.3 MB")
            .environment(\.dynamicTypeSize, .accessibility5).frame(width: 100))
        let normalSize = try #require(regular.nsImage?.size)
        let largeSize = try #require(accessible.nsImage?.size)
        #expect(normalSize.width == 100)
        #expect(largeSize.width == 100)
        #expect(largeSize.height > normalSize.height)
        // This executes the actual SwiftUI label layout on macOS. iOS VoiceOver traversal
        // and on-device glyph rendering remain the real app's E01 accessibility checks.
    }
}

@Suite("N09 actual custom tab selection semantics")
@MainActor
struct N09TabAccessibilityTests {
    @Test("Exactly the current tab exposes selected trait/value while labels and identifiers remain meaningful", arguments: AppTab.allCases)
    func exactlyOneSelection(_ selected: AppTab) {
        let state = AppTabState(initial: selected)
        let controls = AppTab.allCases.map { tab in
            TabBarButton(tab: tab, isSelected: state.selected == tab, onTap: { state.select(tab) }, onSelectTab: { state.select($0) })
        }
        #expect(controls.filter { $0.selectionTraits.contains(.isSelected) }.count == 1)
        #expect(controls.filter { $0.selectionValue == "Selected" }.count == 1)
        #expect(controls.first { $0.selectionTraits.contains(.isSelected) }?.tab == selected)
        #expect(Set(controls.map(\.identifier)).count == AppTab.allCases.count)
        #expect(controls.allSatisfy { !$0.tab.title.isEmpty })
    }

    @Test("Native tab action and context selection retain their production state transitions")
    func actions() {
        let state = AppTabState(initial: .recent)
        let browse = TabBarButton(tab: .browse, isSelected: false, onTap: { state.select(.browse) }, onSelectTab: { state.select($0) })
        browse.onTap()
        #expect(state.selected == .browse)
        browse.onSelectTab(.stats)
        #expect(state.selected == .stats)
        #expect(state.visited == [.recent, .browse, .stats])
    }
}
