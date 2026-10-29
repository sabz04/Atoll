/*
 * Atoll (DynamicIsland)
 * Copyright (C) 2024-2026 Atoll Contributors
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

/// The notch's built-in tabs. The raw value is the stable key the user's tab
/// order and removed tabs are stored under, so it must never change.
enum NotchTabKind: String, CaseIterable {
    case home
    case shelf
    case timer
    case stats
    case llmUsage
    case notes
    case clipboard
    case claude
    case terminal

    var view: NotchViews {
        switch self {
        case .home: return .home
        case .shelf: return .shelf
        case .timer: return .timer
        case .stats: return .stats
        case .llmUsage: return .llmUsage
        case .notes: return .notes
        case .clipboard: return .clipboard
        case .claude: return .claude
        case .terminal: return .terminal
        }
    }

    var title: String {
        switch self {
        case .home: return String(localized: "Home")
        case .shelf: return String(localized: "Shelf")
        case .timer: return String(localized: "Timer")
        case .stats: return String(localized: "Stats")
        case .llmUsage: return String(localized: "Usage")
        case .notes: return Defaults[.enableNotes] ? String(localized: "Notes") : String(localized: "Clipboard")
        case .clipboard: return String(localized: "Clipboard")
        case .claude: return "Claude Code"
        case .terminal: return String(localized: "Terminal")
        }
    }

    var icon: String {
        switch self {
        case .home: return "house.fill"
        case .shelf: return "tray.fill"
        case .timer: return "timer"
        case .stats: return "chart.xyaxis.line"
        case .llmUsage: return "chart.bar.doc.horizontal"
        case .notes: return Defaults[.enableNotes] ? "note.text" : "doc.on.clipboard"
        case .clipboard: return "list.clipboard"
        case .claude: return "sparkle"
        case .terminal: return "apple.terminal"
        }
    }

    /// Whether the feature behind the tab is switched on. A tab whose feature is
    /// off is not in the bar no matter what the user's tab layout says.
    var isFeatureEnabled: Bool {
        switch self {
        case .home:
            return Defaults[.enableMinimalisticUI]
                || Defaults[.showStandardMediaControls] || Defaults[.showCalendar] || Defaults[.showMirror]
        case .shelf:
            return Defaults[.dynamicShelf]
        case .timer:
            return Defaults[.enableTimerFeature] && Defaults[.timerDisplayMode] == .tab
        case .stats:
            return Defaults[.enableStatsFeature]
        case .llmUsage:
            return Defaults[.enableLLMUsageFeature]
        case .notes:
            return Defaults[.enableNotes]
                || (Defaults[.enableClipboardManager] && Defaults[.clipboardDisplayMode] == .separateTab)
        case .clipboard:
            return Defaults[.enableClipboardManager] && Defaults[.clipboardDisplayMode] == .notchTab
        case .claude:
            return Defaults[.enableClaudeCodeIntegration]
        case .terminal:
            return Defaults[.enableTerminalFeature]
        }
    }

    /// Home is the one tab that cannot be removed.
    var isRemovable: Bool { self != .home }
}

/// Builds the tab bar from the enabled features and the user's layout: the
/// order they dragged tabs into and the tabs they removed. One source for the
/// bar, the minimum notch width and the tab-switch direction, so the three can't
/// disagree about which tabs exist.
enum NotchTabCatalog {
    static let homeKey = NotchTabKind.home.rawValue

    static func extensionKey(for experienceID: String) -> String {
        "extension-\(experienceID)"
    }

    /// Built-in tabs whose feature is on plus extension tabs, in default order,
    /// before the user's layout is applied.
    static func availableTabs(extensionPayloads: [ExtensionNotchExperiencePayload] = []) -> [TabModel] {
        var tabs = NotchTabKind.allCases
            .filter(\.isFeatureEnabled)
            .map(TabModel.init(kind:))
        for payload in extensionPayloads {
            guard let tab = payload.descriptor.tab else { continue }
            tabs.append(
                TabModel(
                    key: extensionKey(for: payload.descriptor.id),
                    label: tab.title,
                    icon: tab.iconSymbolName ?? "puzzlepiece.extension",
                    view: .extensionExperience,
                    experienceID: payload.descriptor.id,
                    accentColor: payload.descriptor.accentColor.swiftUIColor
                )
            )
        }
        return tabs
    }

    /// The tabs the bar shows: removed ones dropped (never Home), the rest in the
    /// user's order. Tabs the saved order doesn't know yet — a feature switched
    /// on later — keep their default place relative to each other at the end.
    static func arrange(_ tabs: [TabModel]) -> [TabModel] {
        let hidden = Set(Defaults[.hiddenNotchTabs])
        let visible = tabs.filter { $0.id == homeKey || !hidden.contains($0.id) }
        return sortedByUserOrder(visible, key: \.id)
    }

    static func visibleTabs(extensionPayloads: [ExtensionNotchExperiencePayload] = []) -> [TabModel] {
        arrange(availableTabs(extensionPayloads: extensionPayloads))
    }

    static func sortedByUserOrder<T>(_ items: [T], key: (T) -> String) -> [T] {
        let order = Defaults[.notchTabOrder]
        guard !order.isEmpty else { return items }
        let rank = Dictionary(order.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        return items.enumerated()
            .sorted { lhs, rhs in
                let left = rank[key(lhs.element)] ?? order.count + lhs.offset
                let right = rank[key(rhs.element)] ?? order.count + rhs.offset
                return left == right ? lhs.offset < rhs.offset : left < right
            }
            .map(\.element)
    }

    /// Stores a new order for the given keys. Keys missing from it — removed
    /// tabs, features that are off — keep their saved positions after them.
    static func saveOrder(_ keys: [String]) {
        let rest = Defaults[.notchTabOrder].filter { !keys.contains($0) }
        let defaults = NotchTabKind.allCases.map(\.rawValue).filter { !keys.contains($0) && !rest.contains($0) }
        Defaults[.notchTabOrder] = keys + rest + defaults
    }

    static func setHidden(_ key: String, _ hidden: Bool) {
        guard key != homeKey else { return }
        var keys = Defaults[.hiddenNotchTabs].filter { $0 != key }
        if hidden { keys.append(key) }
        Defaults[.hiddenNotchTabs] = keys
    }

    static func resetLayout() {
        Defaults[.notchTabOrder] = []
        Defaults[.hiddenNotchTabs] = []
    }
}

struct TabModel: Identifiable {
    /// Stable key: a `NotchTabKind` raw value or `extension-<id>`.
    let id: String
    let label: String
    let icon: String
    let view: NotchViews
    let experienceID: String?
    let accentColor: Color?

    var isRemovable: Bool { id != NotchTabCatalog.homeKey }

    init(key: String, label: String, icon: String, view: NotchViews, experienceID: String? = nil, accentColor: Color? = nil) {
        self.id = key
        self.label = label
        self.icon = icon
        self.view = view
        self.experienceID = experienceID
        self.accentColor = accentColor
    }

    init(kind: NotchTabKind) {
        self.init(key: kind.rawValue, label: kind.title, icon: kind.icon, view: kind.view)
    }
}
