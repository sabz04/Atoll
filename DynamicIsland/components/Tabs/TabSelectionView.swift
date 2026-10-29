/*
 * Atoll (DynamicIsland)
 * Copyright (C) 2024-2026 Atoll Contributors
 *
 * Originally from boring.notch project
 * Modified and adapted for Atoll (DynamicIsland)
 * See NOTICE for details.
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program. If not, see <https://www.gnu.org/licenses/>.
 */

import AtollExtensionKit
import SwiftUI
import Defaults
import AppKit

/// The notch's tab bar. Press and hold a tab to pick it up: drag sideways to
/// reorder, drag it down out of the bar to remove it (Home always stays).
/// Removed tabs come back from Settings → Tabs.
struct TabSelectionView: View {
    @ObservedObject var coordinator = DynamicIslandViewCoordinator.shared
    @ObservedObject private var extensionNotchExperienceManager = ExtensionNotchExperienceManager.shared
    @StateObject private var quickShareService = QuickShareService.shared
    @Default(.quickShareProvider) private var quickShareProvider
    @State private var showQuickSharePopover = false
    // Observed so the bar rebuilds when any of the features behind a tab toggles.
    @Default(.enableTimerFeature) var enableTimerFeature
    @Default(.enableStatsFeature) var enableStatsFeature
    @Default(.enableColorPickerFeature) var enableColorPickerFeature
    @Default(.timerDisplayMode) var timerDisplayMode
    @Default(.enableClipboardManager) private var enableClipboardManager
    @Default(.clipboardDisplayMode) private var clipboardDisplayMode
    @Default(.enableClaudeCodeIntegration) private var enableClaudeCodeIntegration
    @Default(.enableThirdPartyExtensions) private var enableThirdPartyExtensions
    @Default(.enableExtensionNotchExperiences) private var enableExtensionNotchExperiences
    @Default(.enableExtensionNotchTabs) private var enableExtensionNotchTabs
    @Default(.showCalendar) private var showCalendar
    @Default(.showMirror) private var showMirror
    @Default(.showStandardMediaControls) private var showStandardMediaControls
    @Default(.enableMinimalisticUI) private var enableMinimalisticUI
    @Default(.notchTabOrder) private var notchTabOrder
    @Default(.hiddenNotchTabs) private var hiddenNotchTabs
    @Default(.enableHaptics) private var enableHaptics
    @Namespace var animation

    /// Drag-to-reorder state. `liveOrder` is the order shown while a tab is held;
    /// it is written to Defaults only when the drag ends.
    @State private var tabFrames: [String: CGRect] = [:]
    @State private var draggingKey: String?
    @State private var liveOrder: [String]?
    @State private var dragLocation: CGPoint = .zero
    @State private var grabOffset: CGSize?
    @State private var isOverRemoveZone = false

    private static let coordinateSpaceName = "NotchTabBar"
    /// How far below the bar a held tab has to travel before letting go removes it.
    private static let removeDistance: CGFloat = 26

    private var tabs: [TabModel] {
        let arranged = NotchTabCatalog.visibleTabs(
            extensionPayloads: extensionTabsEnabled ? extensionTabPayloads : []
        )
        guard let liveOrder else { return arranged }
        return arranged.sorted {
            (liveOrder.firstIndex(of: $0.id) ?? .max) < (liveOrder.firstIndex(of: $1.id) ?? .max)
        }
    }

    var body: some View {
        let tabs = self.tabs
        HStack(spacing: 24) {
            ForEach(tabs) { tab in
                tabItem(tab)
            }
        }
        .coordinateSpace(name: Self.coordinateSpaceName)
        .onPreferenceChange(TabFramePreferenceKey.self) { tabFrames = $0 }
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: tabs.map(\.id))
        .clipShape(TabBarClipShape(isDragging: draggingKey != nil))
        .onAppear {
            ensureValidSelection(with: tabs)
        }
        .onChange(of: tabs.map(\.id)) { _, _ in
            ensureValidSelection(with: self.tabs)
        }
    }

    // MARK: - Tab item

    @ViewBuilder
    private func tabItem(_ tab: TabModel) -> some View {
        let isSelected = isSelected(tab)
        let isDragging = draggingKey == tab.id
        let isRemoving = isDragging && isOverRemoveZone
        let activeAccent = tab.accentColor ?? .white

        Image(systemName: tab.icon)
            .frame(height: 26)
            .foregroundStyle(isRemoving ? Color.red : (isSelected ? activeAccent : .gray))
            .background {
                if isSelected {
                    Capsule()
                        .fill((tab.accentColor ?? Color(nsColor: .secondarySystemFill)).opacity(0.25))
                        .shadow(color: (tab.accentColor ?? .clear).opacity(0.4), radius: 8)
                        .matchedGeometryEffect(id: "capsule", in: animation)
                } else {
                    Capsule()
                        .fill(Color.clear)
                        .matchedGeometryEffect(id: "capsule", in: animation)
                        .hidden()
                }
            }
            .contentShape(Capsule())
            .background {
                GeometryReader { geo in
                    Color.clear.preference(
                        key: TabFramePreferenceKey.self,
                        value: [tab.id: geo.frame(in: .named(Self.coordinateSpaceName))]
                    )
                }
            }
            .overlay(alignment: .topTrailing) {
                if isRemoving {
                    Image(systemName: "minus.circle.fill")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white, .red)
                        .offset(x: 7, y: -5)
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .scaleEffect(isDragging ? (isRemoving ? 0.9 : 1.22) : 1)
            .shadow(color: .black.opacity(isDragging ? 0.5 : 0), radius: 6, y: 3)
            .opacity(isRemoving ? 0.7 : 1)
            .offset(isDragging ? heldOffset(for: tab.id) : .zero)
            .zIndex(isDragging ? 1 : 0)
            .animation(.spring(response: 0.25, dampingFraction: 0.75), value: isDragging)
            .animation(.easeOut(duration: 0.15), value: isRemoving)
            .onTapGesture { select(tab) }
            .gesture(reorderGesture(for: tab))
            .contextMenu { contextMenu(for: tab) }
            .help(tab.label)
            .accessibilityElement()
            .accessibilityLabel(tab.label)
            .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
            .accessibilityAction { select(tab) }
    }

    @ViewBuilder
    private func contextMenu(for tab: TabModel) -> some View {
        if tab.isRemovable {
            Button("Remove Tab") { remove(tab.id) }
        }
        Button("Customize Tabs…") {
            SettingsWindowController.shared.showWindow()
        }
    }

    // MARK: - Drag to reorder / remove

    private func reorderGesture(for tab: TabModel) -> some Gesture {
        LongPressGesture(minimumDuration: 0.3)
            .sequenced(before: DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.coordinateSpaceName)))
            .onChanged { value in
                guard case .second(true, let drag) = value else { return }
                if draggingKey == nil { beginDrag(tab) }
                if let drag { updateDrag(tab, drag) }
            }
            .onEnded { value in
                guard case .second(true, _) = value else { return }
                endDrag(tab)
            }
    }

    private func beginDrag(_ tab: TabModel) {
        liveOrder = tabs.map(\.id)
        grabOffset = nil
        isOverRemoveZone = false
        withAnimation(.spring(response: 0.25, dampingFraction: 0.75)) { draggingKey = tab.id }
        haptic(.levelChange)
    }

    private func updateDrag(_ tab: TabModel, _ drag: DragGesture.Value) {
        guard let frame = tabFrames[tab.id] else { return }
        if grabOffset == nil {
            grabOffset = CGSize(width: drag.startLocation.x - frame.midX, height: drag.startLocation.y - frame.midY)
        }
        dragLocation = drag.location

        let removing = tab.isRemovable && drag.translation.height > Self.removeDistance
        if removing != isOverRemoveZone {
            isOverRemoveZone = removing
            haptic(.alignment)
        }
        guard !removing, var order = liveOrder, let from = order.firstIndex(of: tab.id) else { return }

        // The held tab belongs before every other tab whose centre is right of it.
        let heldX = drag.location.x - (grabOffset?.width ?? 0)
        let others = order.filter { $0 != tab.id }
        let target = others.filter { (tabFrames[$0]?.midX ?? .infinity) < heldX }.count
        guard target != from else { return }
        order.remove(at: from)
        order.insert(tab.id, at: target)
        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { liveOrder = order }
        haptic(.alignment)
    }

    private func endDrag(_ tab: TabModel) {
        if isOverRemoveZone && tab.isRemovable {
            remove(tab.id)
            haptic(.generic)
        } else if let liveOrder, liveOrder != NotchTabCatalog.visibleTabs(extensionPayloads: extensionTabsEnabled ? extensionTabPayloads : []).map(\.id) {
            NotchTabCatalog.saveOrder(liveOrder)
        }
        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
            draggingKey = nil
            liveOrder = nil
            isOverRemoveZone = false
        }
        grabOffset = nil
    }

    /// Where the held tab is drawn relative to its slot in the (live) order.
    private func heldOffset(for key: String) -> CGSize {
        guard let frame = tabFrames[key], let grabOffset else { return .zero }
        return CGSize(
            width: dragLocation.x - grabOffset.width - frame.midX,
            height: max(-6, dragLocation.y - grabOffset.height - frame.midY)
        )
    }

    private func remove(_ key: String) {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
            NotchTabCatalog.setHidden(key, true)
        }
    }

    private func haptic(_ pattern: NSHapticFeedbackManager.FeedbackPattern) {
        guard enableHaptics else { return }
        NSHapticFeedbackManager.defaultPerformer.perform(pattern, performanceTime: .now)
    }

    // MARK: - Selection

    private func select(_ tab: TabModel) {
        guard draggingKey == nil else { return }
        if tab.view == .extensionExperience {
            coordinator.selectedExtensionExperienceID = tab.experienceID
        }
        coordinator.currentView = tab.view
    }

    private var extensionTabsEnabled: Bool {
        enableThirdPartyExtensions && enableExtensionNotchExperiences && enableExtensionNotchTabs
    }

    private var extensionTabPayloads: [ExtensionNotchExperiencePayload] {
        extensionNotchExperienceManager.activeExperiences.filter { $0.descriptor.tab != nil }
    }

    private func isSelected(_ tab: TabModel) -> Bool {
        if tab.view == .extensionExperience {
            return coordinator.currentView == .extensionExperience
                && coordinator.selectedExtensionExperienceID == tab.experienceID
        }
        return coordinator.currentView == tab.view
    }

    private func ensureValidSelection(with tabs: [TabModel]) {
        guard !tabs.isEmpty else { return }
        if tabs.contains(where: { isSelected($0) }) {
            return
        }
        guard let first = tabs.first else { return }
        if first.view == .extensionExperience {
            coordinator.selectedExtensionExperienceID = first.experienceID
        } else {
            coordinator.selectedExtensionExperienceID = nil
        }
        coordinator.currentView = first.view
    }
}

private struct TabFramePreferenceKey: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}

/// The bar is clipped to its capsule, except while a tab is held: the lifted
/// tab grows and travels below the bar on its way to being removed. One shape
/// type either way — swapping the modifier would rebuild the bar mid-drag and
/// cancel the gesture.
private struct TabBarClipShape: Shape {
    let isDragging: Bool

    func path(in rect: CGRect) -> Path {
        guard isDragging else { return Capsule().path(in: rect) }
        return Path(rect.insetBy(dx: -24, dy: -24).offsetBy(dx: 0, dy: 40))
    }
}

#Preview {
    DynamicIslandHeader().environmentObject(DynamicIslandViewModel())
}
