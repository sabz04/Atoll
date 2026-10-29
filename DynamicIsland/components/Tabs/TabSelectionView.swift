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
    /// Between letting go and the held tab landing in its slot (or vanishing).
    @State private var isSettling = false
    /// True only while the hold gesture is live. Unlike `onEnded` it also resets
    /// when the system cancels the gesture (the notch closing mid-drag), which
    /// would otherwise leave a tab stuck in the air.
    @GestureState private var isHoldingTab = false

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
        .clipShape(Capsule())
        // The held tab floats above the bar, unclipped, exactly under the cursor;
        // its slot in the bar stays as an invisible placeholder the others make room for.
        .overlay(alignment: .topLeading) { floatingTab(in: tabs) }
        .onAppear {
            ensureValidSelection(with: tabs)
        }
        .onChange(of: tabs.map(\.id)) { _, _ in
            ensureValidSelection(with: self.tabs)
        }
        .onChange(of: isHoldingTab) { _, holding in
            guard !holding else { return }
            // A normal release has already started settling by now; only a
            // cancelled gesture gets here with the tab still held.
            DispatchQueue.main.async {
                if draggingKey != nil && !isSettling { cancelDrag() }
            }
        }
        .onDisappear { cancelDrag() }
    }

    // MARK: - Tab item

    @ViewBuilder
    private func tabItem(_ tab: TabModel) -> some View {
        let isSelected = isSelected(tab)
        let isDragging = draggingKey == tab.id
        let activeAccent = tab.accentColor ?? .white

        Image(systemName: tab.icon)
            .frame(height: 26)
            .foregroundStyle(isSelected ? activeAccent : .gray)
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
            .opacity(isDragging ? 0 : 1)
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

    @ViewBuilder
    private func floatingTab(in tabs: [TabModel]) -> some View {
        if let key = draggingKey, let tab = tabs.first(where: { $0.id == key }), let slot = tabFrames[key] {
            let removing = isOverRemoveZone
            let vanishing = removing && isSettling
            Image(systemName: tab.icon)
                .foregroundStyle(removing ? Color.red : (isSelected(tab) ? (tab.accentColor ?? .white) : .white))
                .frame(width: slot.width + 16, height: 28)
                .background(Capsule().fill(removing ? Color.red.opacity(0.2) : Color.white.opacity(0.18)))
                .overlay(alignment: .topTrailing) {
                    if removing {
                        Image(systemName: "minus.circle.fill")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(.white, .red)
                            .offset(x: 4, y: -4)
                            .transition(.scale.combined(with: .opacity))
                    }
                }
                .scaleEffect(vanishing ? 0.3 : (removing ? 0.92 : 1.12))
                .opacity(vanishing ? 0 : 1)
                .shadow(color: .black.opacity(0.5), radius: 8, y: 4)
                .animation(.spring(response: 0.25, dampingFraction: 0.75), value: removing)
                .position(heldCenter(slot: slot))
                .allowsHitTesting(false)
                .transition(.opacity)
        }
    }

    /// Follows the cursor sideways within the bar, and only ever downwards —
    /// above the bar is the top edge of the notch.
    private func heldCenter(slot: CGRect) -> CGPoint {
        guard let grabOffset else { return CGPoint(x: slot.midX, y: slot.midY) }
        let minX = tabFrames.values.map(\.minX).min() ?? slot.minX
        let maxX = tabFrames.values.map(\.maxX).max() ?? slot.maxX
        let x = min(max(dragLocation.x - grabOffset.width, minX), maxX)
        let y = slot.midY + max(0, dragLocation.y - grabOffset.height - slot.midY)
        return CGPoint(x: x, y: y)
    }

    private func reorderGesture(for tab: TabModel) -> some Gesture {
        LongPressGesture(minimumDuration: 0.3)
            .sequenced(before: DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.coordinateSpaceName)))
            .updating($isHoldingTab) { value, holding, _ in
                if case .second(true, _) = value { holding = true }
            }
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
        guard !isSettling else { return }
        liveOrder = tabs.map(\.id)
        grabOffset = nil
        isOverRemoveZone = false
        draggingKey = tab.id
        haptic(.levelChange)
    }

    private func updateDrag(_ tab: TabModel, _ drag: DragGesture.Value) {
        guard !isSettling, let frame = tabFrames[tab.id] else { return }
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

    /// Lands the held tab: it flies into its slot (or shrinks away when being
    /// removed), and only then hands back to the real tab in the bar.
    private func endDrag(_ tab: TabModel) {
        guard draggingKey != nil, !isSettling else { return }
        let removing = isOverRemoveZone && tab.isRemovable
        if !removing, let liveOrder,
           liveOrder != NotchTabCatalog.visibleTabs(extensionPayloads: extensionTabsEnabled ? extensionTabPayloads : []).map(\.id) {
            NotchTabCatalog.saveOrder(liveOrder)
        }
        withAnimation(.spring(response: 0.25, dampingFraction: 0.85)) {
            isSettling = true
            if !removing, let slot = tabFrames[tab.id], let grabOffset {
                dragLocation = CGPoint(x: slot.midX + grabOffset.width, y: slot.midY + grabOffset.height)
            }
        }
        haptic(removing ? .generic : .alignment)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) {
            if removing { remove(tab.id) }
            draggingKey = nil
            liveOrder = nil
            isOverRemoveZone = false
            grabOffset = nil
            isSettling = false
        }
    }

    /// Drops a drag without applying it: the bar goes back to the saved order.
    private func cancelDrag() {
        guard draggingKey != nil else { return }
        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
            draggingKey = nil
            liveOrder = nil
            isOverRemoveZone = false
        }
        grabOffset = nil
        isSettling = false
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

#Preview {
    DynamicIslandHeader().environmentObject(DynamicIslandViewModel())
}
