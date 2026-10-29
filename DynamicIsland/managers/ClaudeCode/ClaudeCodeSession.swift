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

/// One Claude Code session, read from the transcript Claude Code keeps in
/// `~/.claude/projects/<project>/<session-id>.jsonl` — the CLI and the desktop
/// app write there alike.
struct ClaudeCodeSession: Identifiable, Equatable {
    enum Status: Equatable {
        case working
        case needsPermission
        case waitingForInput
        case finished
        case idle

        /// Shown under the Active filter: anything still running or waiting on you.
        var isActive: Bool { self != .idle }
    }

    let id: String
    let transcriptURL: URL
    var title: String?
    var lastPrompt: String?
    var cwd: String?
    var gitBranch: String?
    var entrypoint: String?
    var costUSD: Double?
    var lastActivity: Date
    var status: Status = .idle
    var statusMessage: String?

    var isDesktop: Bool { entrypoint == "claude-desktop" }

    /// Folder the session works in, or nil for desktop sessions started without
    /// a folder (those run in an app-managed scratch directory).
    var projectName: String? {
        guard let cwd, !cwd.contains("/scratch-workspaces/") else { return nil }
        return URL(fileURLWithPath: cwd).lastPathComponent
    }

    var displayTitle: String {
        title ?? projectName ?? lastPrompt ?? String(localized: "Untitled session")
    }

    /// `cd` into the session's folder and resume it in the CLI.
    var resumeCommand: String {
        let resume = "claude --resume \(id)"
        guard let cwd else { return resume }
        return "cd '\(cwd.replacingOccurrences(of: "'", with: "'\\''"))' && \(resume)"
    }
}

/// Reads what the notch shows about a session from the end of its transcript.
///
/// Claude Code keeps appending `custom-title`, `last-prompt` and `cost-state`
/// records, so the newest of each sits near the end; reading only the tail
/// keeps this cheap on multi-megabyte transcripts. Only lines carrying one of
/// those markers are decoded.
enum ClaudeCodeTranscriptReader {
    struct Snapshot: Equatable {
        var title: String?
        var lastPrompt: String?
        var cwd: String?
        var gitBranch: String?
        var entrypoint: String?
        var costUSD: Double?

        var isEmpty: Bool { title == nil && lastPrompt == nil }
    }

    static func read(_ url: URL) -> Snapshot {
        let snapshot = readTail(of: url, bytes: 128 * 1024)
        // One huge record (a pasted image, a long tool result) can push every
        // marker out of a small tail; look further back once before giving up.
        if snapshot.cwd == nil || snapshot.isEmpty {
            return readTail(of: url, bytes: 2 * 1024 * 1024)
        }
        return snapshot
    }

    private static func readTail(of url: URL, bytes: UInt64) -> Snapshot {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return Snapshot() }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return Snapshot() }
        let offset = size > bytes ? size - bytes : 0
        guard (try? handle.seek(toOffset: offset)) != nil,
              let data = try? handle.readToEnd() else { return Snapshot() }

        // Decoding repairs a UTF-8 sequence the tail cut in half.
        var lines = String(decoding: data, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: true)
        if offset > 0, !lines.isEmpty { lines.removeFirst() } // partial record

        var snapshot = Snapshot()
        var userPrompt: String?
        for line in lines.reversed() {
            if snapshot.title == nil, line.contains("\"type\":\"custom-title\"") {
                snapshot.title = clean(decode(line)?["customTitle"] as? String)
            } else if snapshot.lastPrompt == nil, line.contains("\"type\":\"last-prompt\"") {
                snapshot.lastPrompt = clean(decode(line)?["lastPrompt"] as? String)
            } else if snapshot.costUSD == nil, line.contains("\"type\":\"cost-state\"") {
                snapshot.costUSD = decode(line)?["totalCostUSD"] as? Double
            } else if userPrompt == nil, snapshot.lastPrompt == nil,
                      line.contains("\"type\":\"user\""), !line.contains("\"tool_result\""),
                      let record = decode(line), record["isMeta"] as? Bool != true {
                // CLI builds that write no `last-prompt` record: the newest typed message.
                userPrompt = clean(promptText(record["message"]))
            }
            if snapshot.cwd == nil, line.contains("\"cwd\":"), let record = decode(line) {
                snapshot.cwd = record["cwd"] as? String
                snapshot.gitBranch = record["gitBranch"] as? String
                snapshot.entrypoint = record["entrypoint"] as? String
            }
            if snapshot.title != nil, snapshot.lastPrompt != nil, snapshot.costUSD != nil, snapshot.cwd != nil {
                break
            }
        }
        if snapshot.lastPrompt == nil { snapshot.lastPrompt = userPrompt }
        return snapshot
    }

    private static func decode(_ line: Substring) -> [String: Any]? {
        guard let data = line.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private static func promptText(_ message: Any?) -> String? {
        guard let message = message as? [String: Any] else { return nil }
        if let text = message["content"] as? String { return text }
        let parts = (message["content"] as? [[String: Any]]) ?? []
        return parts.first { $0["type"] as? String == "text" }?["text"] as? String
    }

    /// One line of display text: collapsed whitespace, trimmed, capped, and nil
    /// for the bracketed command/caveat wrappers Claude Code stores as messages.
    private static func clean(_ text: String?) -> String? {
        guard let text else { return nil }
        let collapsed = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !collapsed.isEmpty, !collapsed.hasPrefix("<") else { return nil }
        return collapsed.count > 280 ? String(collapsed.prefix(280)) + "…" : collapsed
    }
}
