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

import SwiftUI
import Defaults

/// Settings → Tabs: the order of the notch's tabs, which ones are shown, and
/// the way back for tabs removed by dragging them out of the bar.
struct NotchTabsSettings: View {
    @Default(.notchTabOrder) private var notchTabOrder
    @Default(.hiddenNotchTabs) private var hiddenNotchTabs

    private var kinds: [NotchTabKind] {
        NotchTabCatalog.sortedByUserOrder(NotchTabKind.allCases, key: \.rawValue)
    }

    var body: some View {
        let kinds = self.kinds
        Form {
            Section {
                ForEach(Array(kinds.enumerated()), id: \.element) { index, kind in
                    row(kind, index: index, count: kinds.count)
                }
                .onMove { source, destination in
                    var keys = kinds.map(\.rawValue)
                    keys.move(fromOffsets: source, toOffset: destination)
                    NotchTabCatalog.saveOrder(keys)
                }
            } header: {
                Text("Notch Tabs")
            } footer: {
                Text("In the notch, press and hold a tab to move it, or drag it down out of the bar to remove it. Home always stays.")
            }

            Section {
                Button("Restore Default Tabs") {
                    withAnimation { NotchTabCatalog.resetLayout() }
                }
                .disabled(notchTabOrder.isEmpty && hiddenNotchTabs.isEmpty)
            } footer: {
                Text("Brings back every removed tab, extension tabs included, in the default order.")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Tabs")
    }

    private func row(_ kind: NotchTabKind, index: Int, count: Int) -> some View {
        let available = kind.isFeatureEnabled
        let shown = kind == .home || !hiddenNotchTabs.contains(kind.rawValue)

        return HStack(spacing: 10) {
            Image(systemName: kind.icon)
                .frame(width: 22)
                .foregroundStyle(available ? Color.accentColor : .secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(kind.title)
                if kind == .home {
                    Text("Always shown")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if !available {
                    Text("Its feature is turned off")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            HStack(spacing: 2) {
                moveButton("chevron.up", disabled: index == 0) { move(kind, by: -1) }
                moveButton("chevron.down", disabled: index == count - 1) { move(kind, by: 1) }
            }
            Toggle("", isOn: Binding(
                get: { shown },
                set: { NotchTabCatalog.setHidden(kind.rawValue, !$0) }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .disabled(kind == .home)
        }
        .opacity(available ? 1 : 0.6)
    }

    private func moveButton(_ icon: String, disabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .semibold))
                .frame(width: 18, height: 18)
        }
        .buttonStyle(.borderless)
        .disabled(disabled)
    }

    private func move(_ kind: NotchTabKind, by step: Int) {
        var keys = kinds.map(\.rawValue)
        guard let from = keys.firstIndex(of: kind.rawValue) else { return }
        let to = from + step
        guard keys.indices.contains(to) else { return }
        keys.swapAt(from, to)
        withAnimation { NotchTabCatalog.saveOrder(keys) }
    }
}
