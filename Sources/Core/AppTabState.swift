import Foundation
import Observation

enum AppTab: String, CaseIterable, Sendable {
    case browse, apps, recent, stash, stats, upload, settings

    var title: String {
        switch self {
        case .browse: "Browse"
        case .apps: "Apps"
        case .recent: "Recent"
        case .stash: "Stash"
        case .stats: "Stats"
        case .upload: "Upload"
        case .settings: "Settings"
        }
    }

    var icon: String {
        switch self {
        case .browse: "folder"
        case .apps: "square.grid.2x2"
        case .recent: "clock"
        case .stash: "doc.richtext"
        case .stats: "chart.bar"
        case .upload: "square.and.arrow.up"
        case .settings: "gear"
        }
    }
}

/// Only selected tabs are created. Previously visited tabs retain their SwiftUI
/// subtree, including navigation paths, selections and last successful rows.
@Observable @MainActor
final class AppTabState {
    private(set) var selected: AppTab
    private(set) var visited: Set<AppTab>

    init(initial: AppTab) { selected = initial;visited = [initial] }
    func select(_ tab: AppTab) { visited.insert(tab);selected = tab }
    func resetForConfiguration() { visited = [selected] }
    var retainedTabs: [AppTab] { AppTab.allCases.filter { visited.contains($0) } }
}
