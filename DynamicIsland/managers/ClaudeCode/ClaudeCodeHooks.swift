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

import Foundation

/// Live session status through Claude Code hooks.
///
/// Connecting adds one command per session event to `~/.claude/settings.json`
/// (a copy of the original is kept as `settings.json.atoll-backup`). The command
/// is a small script that drops a file with the event name and session id into
/// Atoll's events folder; `ClaudeCodeHookEvents` picks those up. No sockets, no
/// network: a hook that runs while Atoll is closed writes nothing and exits.
enum ClaudeCodeHooks {
    /// Claude Code events Atoll listens to. `PostToolUse` moves a session back to
    /// "working" once a permission prompt has been answered.
    static let events = ["SessionStart", "UserPromptSubmit", "PostToolUse", "Notification", "Stop", "SessionEnd"]

    static var claudeDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude", isDirectory: true)
    }
    static var settingsURL: URL { claudeDirectory.appendingPathComponent("settings.json") }
    static var backupURL: URL { claudeDirectory.appendingPathComponent("settings.json.atoll-backup") }

    static var supportDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Atoll/ClaudeCode", isDirectory: true)
    }
    static var scriptURL: URL { supportDirectory.appendingPathComponent("atoll-hook.sh") }
    static var eventsDirectory: URL { supportDirectory.appendingPathComponent("events", isDirectory: true) }

    /// Identifies Atoll's own entries among whatever hooks the user already has.
    private static let commandMarker = "Atoll/ClaudeCode/atoll-hook.sh"

    enum HookError: LocalizedError {
        case unreadableSettings
        case unexpectedLayout

        var errorDescription: String? {
            switch self {
            case .unreadableSettings:
                return String(localized: "~/.claude/settings.json isn't valid JSON, so Atoll left it untouched.")
            case .unexpectedLayout:
                return String(localized: "The hooks section of ~/.claude/settings.json has an unexpected layout, so Atoll left it untouched.")
            }
        }
    }

    static var isClaudeCodeInstalled: Bool {
        FileManager.default.fileExists(atPath: claudeDirectory.path)
    }

    static func isInstalled() -> Bool {
        guard FileManager.default.isExecutableFile(atPath: scriptURL.path),
              let text = try? String(contentsOf: settingsURL, encoding: .utf8) else { return false }
        return text.contains(commandMarker)
    }

    static func install() throws {
        try writeScript()
        var settings = try loadSettings()
        var hooks = try hooksSection(of: settings)
        for event in events {
            var groups = try groups(in: hooks, for: event).filter { !isAtollGroup($0) }
            var group: [String: Any] = [
                "hooks": [["type": "command", "command": command(for: event), "timeout": 5]]
            ]
            if event == "PostToolUse" { group["matcher"] = "*" }
            groups.append(group)
            hooks[event] = groups
        }
        settings["hooks"] = hooks
        try backUpSettingsOnce()
        try save(settings)
    }

    static func uninstall() throws {
        var settings = try loadSettings()
        var hooks = try hooksSection(of: settings)
        for event in events {
            let groups = try groups(in: hooks, for: event).filter { !isAtollGroup($0) }
            hooks[event] = groups.isEmpty ? nil : groups
        }
        settings["hooks"] = hooks.isEmpty ? nil : hooks
        try save(settings)
        try? FileManager.default.removeItem(at: scriptURL)
    }

    // MARK: - Settings file

    private static func loadSettings() throws -> [String: Any] {
        guard FileManager.default.fileExists(atPath: settingsURL.path) else { return [:] }
        let data = try Data(contentsOf: settingsURL)
        if data.isEmpty { return [:] }
        guard let settings = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw HookError.unreadableSettings
        }
        return settings
    }

    private static func hooksSection(of settings: [String: Any]) throws -> [String: Any] {
        guard let raw = settings["hooks"] else { return [:] }
        guard let hooks = raw as? [String: Any] else { throw HookError.unexpectedLayout }
        return hooks
    }

    private static func groups(in hooks: [String: Any], for event: String) throws -> [[String: Any]] {
        guard let raw = hooks[event] else { return [] }
        guard let groups = raw as? [[String: Any]] else { throw HookError.unexpectedLayout }
        return groups
    }

    private static func isAtollGroup(_ group: [String: Any]) -> Bool {
        let commands = (group["hooks"] as? [[String: Any]]) ?? []
        return commands.contains { ($0["command"] as? String)?.contains(commandMarker) == true }
    }

    private static func command(for event: String) -> String {
        "\"\(scriptURL.path)\" \(event)"
    }

    private static func backUpSettingsOnce() throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: settingsURL.path), !fm.fileExists(atPath: backupURL.path) else { return }
        try fm.copyItem(at: settingsURL, to: backupURL)
    }

    private static func save(_ settings: [String: Any]) throws {
        try FileManager.default.createDirectory(at: claudeDirectory, withIntermediateDirectories: true)
        let data = try JSONSerialization.data(
            withJSONObject: settings,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        try data.write(to: settingsURL, options: .atomic)
    }

    // MARK: - Hook script

    private static func writeScript() throws {
        let fm = FileManager.default
        try fm.createDirectory(at: eventsDirectory, withIntermediateDirectories: true)
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
    }

    private static let script = #"""
    #!/bin/sh
    # Atoll: forwards a Claude Code hook event to the notch.
    #
    # Added by Atoll (Settings > Claude Code) and run by Claude Code on session
    # events. Writes one small file with the event name, the session id and, for
    # notifications, Claude's one-line message, then exits 0 so it can never
    # block or fail a session. Prompts and tool input/output arrive on stdin and
    # are only scanned for the session id, never stored.
    events_dir="$HOME/Library/Application Support/Atoll/ClaudeCode/events"
    payload=$(cat)
    pgrep -xq Atoll || exit 0
    session=$(printf '%s' "$payload" | grep -o '"session_id"[[:space:]]*:[[:space:]]*"[0-9A-Za-z-]*"' | head -n 1 | sed 's/.*"\([0-9A-Za-z-]*\)"$/\1/')
    [ -n "$session" ] || exit 0
    message=""
    if [ "$1" = "Notification" ]; then
        message=$(printf '%s' "$payload" | grep -o '"message"[[:space:]]*:[[:space:]]*"[^"\\]*"' | head -n 1 | sed 's/^"message"[[:space:]]*:[[:space:]]*"//; s/"$//')
    fi
    mkdir -p "$events_dir" 2>/dev/null || exit 0
    tmp=$(mktemp "$events_dir/.event.XXXXXX" 2>/dev/null) || exit 0
    printf '{"event":"%s","session":"%s","message":"%s","time":%s}\n' "$1" "$session" "$message" "$(date +%s)" > "$tmp" 2>/dev/null
    mv "$tmp" "$events_dir/$(date +%s)-${tmp##*.}.json" 2>/dev/null || rm -f "$tmp"
    exit 0

    """#
}

/// Hook events the script dropped into the events folder, consumed oldest first.
enum ClaudeCodeHookEvents {
    struct Event {
        let name: String
        let sessionID: String
        let message: String?
        let date: Date
    }

    /// Reads and deletes every pending event. Runs off the main thread.
    static func drain() -> [Event] {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(
            at: ClaudeCodeHooks.eventsDirectory,
            includingPropertiesForKeys: [.creationDateKey],
            options: [.skipsHiddenFiles] // half-written `.event.*` temp files
        ) else { return [] }

        var events: [(event: Event, created: Date)] = []
        for url in files where url.pathExtension == "json" {
            defer { try? fm.removeItem(at: url) }
            guard let data = try? Data(contentsOf: url),
                  let record = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let name = record["event"] as? String,
                  let session = record["session"] as? String, !session.isEmpty else { continue }
            let seconds = (record["time"] as? NSNumber)?.doubleValue ?? Date().timeIntervalSince1970
            let message = (record["message"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            let created = (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
            events.append((Event(name: name, sessionID: session, message: message, date: Date(timeIntervalSince1970: seconds)), created))
        }
        // The script's timestamp has one-second resolution; creation time orders
        // events from the same second (a quick prompt-then-stop).
        return events.sorted { ($0.event.date, $0.created) < ($1.event.date, $1.created) }.map(\.event)
    }
}
