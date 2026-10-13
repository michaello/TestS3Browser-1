import SwiftUI

/// Individual tab control with native button action and explicit selection semantics.
struct TabBarButton: View {
    let tab: AppTab
    let isSelected: Bool
    let onTap: () -> Void
    let onSelectTab: (AppTab) -> Void
    var selectionTraits: AccessibilityTraits { isSelected ? .isSelected : [] }
    var selectionValue: String { isSelected ? "Selected" : "" }
    var identifier: String { "tab." + tab.rawValue }

    var body: some View {
        Button(action: onTap) {
            VStack(spacing: 4) {
                Image(systemName: tab.icon).font(.title3)
                Text(tab.title).font(.caption2)
            }
            .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
            .frame(maxWidth: .infinity, minHeight: 44)
        }
        .accessibilityLabel(tab.title)
        .accessibilityValue(selectionValue)
        .accessibilityAddTraits(selectionTraits)
        .accessibilityIdentifier(identifier)
        .contextMenu {
            ForEach(AppTab.allCases, id: \.self) { menuTab in
                Button { onSelectTab(menuTab) } label: { Label(menuTab.title, systemImage: menuTab.icon) }
            }
        }
    }
}
