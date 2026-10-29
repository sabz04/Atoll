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
import AppKit
import Defaults

/// Settings → Claude Code: the tab, notch notifications, and connecting the
/// hooks that give live status.
struct ClaudeCodeSettings: View {
    @ObservedObject private var monitor = ClaudeCodeSessionMonitor.shared
    @Default(.enableClaudeCodeIntegration) private var enableClaudeCodeIntegration
    @State private var errorMessage: String?

    var body: some View {
        Form {
            Section {
                Defaults.Toggle(key: .enableClaudeCodeIntegration) {
                    Text("Show Claude Code tab")
                }
                Defaults.Toggle(key: .claudeCodeNotifications) {
                    Text("Notify under the notch")
                }
                .disabled(!enableClaudeCodeIntegration || !monitor.hooksInstalled)
            } header: {
                Text("Claude Code")
            } footer: {
                Text("Lists the last 7 days of sessions from ~/.claude/projects, from the terminal and the Claude app alike. Notifications appear when a session finishes or needs your permission, and need live status. Nothing leaves this Mac.")
            }

            Section {
                HStack(spacing: 10) {
                    Circle()
                        .fill(monitor.hooksInstalled ? ClaudeCodePalette.done : Color.secondary.opacity(0.5))
                        .frame(width: 8, height: 8)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(statusTitle)
                        Text(statusDetail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    actionButton
                }
                if let errorMessage {
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            } header: {
                Text("Live Status")
            } footer: {
                Text("Connecting adds hooks to ~/.claude/settings.json and keeps the original as settings.json.atoll-backup. On each session event the hook writes only the event name and session ID — never your prompts or code — to ~/Library/Application Support/Atoll/ClaudeCode. Sessions already open pick the hooks up once restarted.")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Claude Code")
    }

    private var statusTitle: String {
        if !monitor.isClaudeCodeInstalled { return String(localized: "Claude Code isn't installed") }
        return monitor.hooksInstalled ? String(localized: "Connected") : String(localized: "Not connected")
    }

    private var statusDetail: String {
        if !monitor.isClaudeCodeInstalled { return String(localized: "Install it, then connect live status here.") }
        return monitor.hooksInstalled
            ? String(localized: "Status updates arrive as Claude works.")
            : String(localized: "Sessions are listed; status is estimated from activity.")
    }

    @ViewBuilder
    private var actionButton: some View {
        if !monitor.isClaudeCodeInstalled {
            Button("Get Claude Code") {
                NSWorkspace.shared.open(URL(string: "https://www.anthropic.com/claude-code")!)
            }
        } else if monitor.hooksInstalled {
            Button("Disconnect") { run { try monitor.disconnectHooks() } }
        } else {
            Button("Connect") { run { try monitor.connectHooks() } }
                .buttonStyle(.borderedProminent)
        }
    }

    private func run(_ action: () throws -> Void) {
        do {
            try action()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
