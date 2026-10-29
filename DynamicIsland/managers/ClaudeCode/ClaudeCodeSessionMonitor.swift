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

import AppKit
import CoreServices
import Defaults
import SwiftUI

/// Recent Claude Code sessions and what each is doing right now.
///
/// Sessions come from the transcripts in `~/.claude/projects` (last 7 days,
/// newest first). Status comes from hook events when the hooks are connected,
/// otherwise from how recently the transcript was written. Everything is driven
/// by FSEvents — nothing polls the disk — and a refresh re-reads only the
/// transcripts whose size or date changed.
@MainActor
final class ClaudeCodeSessionMonitor: ObservableObject {
    static let shared = ClaudeCodeSessionMonitor()

    @Published private(set) var sessions: [ClaudeCodeSession] = []
    @Published private(set) var isClaudeCodeInstalled = ClaudeCodeHooks.isClaudeCodeInstalled
    @Published private(set) var hooksInstalled = ClaudeCodeHooks.isInstalled()
    @Published private(set) var hasLoaded = false

    private struct HookState {
        var status: ClaudeCodeSession.Status
        var message: String?
        var updated: Date
    }

    private struct CachedSnapshot {
        let modified: Date
        let size: Int
        let snapshot: ClaudeCodeTranscriptReader.Snapshot
    }

    private struct ScanResult {
        var sessions: [ClaudeCodeSession]
        var cache: [URL: CachedSnapshot]
    }

    private nonisolated static let maxSessions = 24
    private nonisolated static let lookback: TimeInterval = 7 * 24 * 3600

    private var hookStates: [String: HookState] = [:]
    private var snapshotCache: [URL: CachedSnapshot] = [:]
    private var scannedSessions: [ClaudeCodeSession] = []
    private var watcher: FileEventStream?
    private var refreshTask: Task<Void, Never>?
    private var refreshPending = false
    private var statusTimer: Timer?
    private var isRunning = false

    private nonisolated static var projectsDirectory: URL {
        ClaudeCodeHooks.claudeDirectory.appendingPathComponent("projects", isDirectory: true)
    }

    private init() {}

    func start() {
        guard !isRunning else { return }
        isRunning = true
        try? FileManager.default.createDirectory(at: ClaudeCodeHooks.eventsDirectory, withIntermediateDirectories: true)
        startWatching()
        // Statuses age without any file changing ("finished" fades to idle, a
        // session that stopped writing is no longer "working").
        statusTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.periodicCheck() }
        }
        scheduleRefresh()
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        watcher = nil
        statusTimer?.invalidate()
        statusTimer = nil
        refreshTask?.cancel()
        refreshTask = nil
    }

    // MARK: - Hooks

    func connectHooks() throws {
        try ClaudeCodeHooks.install()
        hooksInstalled = true
        isClaudeCodeInstalled = true
        startWatching()
    }

    func disconnectHooks() throws {
        try ClaudeCodeHooks.uninstall()
        hooksInstalled = false
        hookStates.removeAll()
        publish()
    }

    // MARK: - Refresh

    private func startWatching() {
        // FSEvents needs an existing path; until Claude Code is installed the
        // periodic check looks for ~/.claude instead.
        var paths = [ClaudeCodeHooks.eventsDirectory.path]
        if FileManager.default.fileExists(atPath: Self.projectsDirectory.path) {
            paths.append(Self.projectsDirectory.path)
        }
        watcher = FileEventStream(paths: paths) { [weak self] in
            Task { @MainActor in self?.scheduleRefresh() }
        }
    }

    private func periodicCheck() {
        let installed = ClaudeCodeHooks.isClaudeCodeInstalled
        if installed != isClaudeCodeInstalled {
            isClaudeCodeInstalled = installed
            startWatching()
            scheduleRefresh()
        }
        let hooks = ClaudeCodeHooks.isInstalled()
        if hooks != hooksInstalled { hooksInstalled = hooks }
        publish()
    }

    /// Coalesces bursts: a streaming session rewrites its transcript many times a
    /// second, but the notch refreshes at most once per second.
    private func scheduleRefresh() {
        guard isRunning else { return }
        guard refreshTask == nil else {
            refreshPending = true
            return
        }
        refreshTask = Task { [weak self] in
            await self?.refresh()
            try? await Task.sleep(for: .seconds(1))
            guard let self, !Task.isCancelled else { return }
            self.refreshTask = nil
            if self.refreshPending {
                self.refreshPending = false
                self.scheduleRefresh()
            }
        }
    }

    private func refresh() async {
        let cache = snapshotCache
        let (events, result) = await Task.detached(priority: .utility) {
            (ClaudeCodeHookEvents.drain(), Self.scan(cache: cache))
        }.value
        snapshotCache = result.cache
        scannedSessions = result.sessions
        apply(events)
        publish()
        hasLoaded = true
    }

    private nonisolated static func scan(cache: [URL: CachedSnapshot]) -> ScanResult {
        let fm = FileManager.default
        guard let projects = try? fm.contentsOfDirectory(
            at: projectsDirectory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ) else { return ScanResult(sessions: [], cache: [:]) }

        let cutoff = Date().addingTimeInterval(-lookback)
        let keys: Set<URLResourceKey> = [.contentModificationDateKey, .fileSizeKey]
        var files: [(url: URL, modified: Date, size: Int)] = []
        for project in projects {
            guard let entries = try? fm.contentsOfDirectory(
                at: project, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles]
            ) else { continue }
            for url in entries where url.pathExtension == "jsonl"
                && UUID(uuidString: url.deletingPathExtension().lastPathComponent) != nil {
                guard let values = try? url.resourceValues(forKeys: keys),
                      let modified = values.contentModificationDate, modified > cutoff else { continue }
                files.append((url, modified, values.fileSize ?? 0))
            }
        }
        files.sort { $0.modified > $1.modified }

        var result = ScanResult(sessions: [], cache: [:])
        for file in files {
            guard result.sessions.count < maxSessions else { break }
            let snapshot: ClaudeCodeTranscriptReader.Snapshot
            if let hit = cache[file.url], hit.modified == file.modified, hit.size == file.size {
                snapshot = hit.snapshot
            } else {
                snapshot = ClaudeCodeTranscriptReader.read(file.url)
            }
            result.cache[file.url] = CachedSnapshot(modified: file.modified, size: file.size, snapshot: snapshot)
            // A transcript with neither a title nor a prompt is an empty session.
            guard !snapshot.isEmpty else { continue }
            result.sessions.append(ClaudeCodeSession(
                id: file.url.deletingPathExtension().lastPathComponent,
                transcriptURL: file.url,
                title: snapshot.title,
                lastPrompt: snapshot.lastPrompt,
                cwd: snapshot.cwd,
                gitBranch: snapshot.gitBranch,
                entrypoint: snapshot.entrypoint,
                costUSD: snapshot.costUSD,
                lastActivity: file.modified
            ))
        }
        return result
    }

    // MARK: - Status

    private func apply(_ events: [ClaudeCodeHookEvents.Event]) {
        for event in events {
            let previous = hookStates[event.sessionID]?.status
            let next: ClaudeCodeSession.Status?
            switch event.name {
            case "SessionStart": next = .idle
            case "UserPromptSubmit", "PostToolUse": next = .working
            case "Notification":
                next = event.message?.localizedCaseInsensitiveContains("permission") == true ? .needsPermission : .waitingForInput
            case "Stop": next = .finished
            case "SessionEnd": next = nil
            default: continue
            }
            if let next {
                hookStates[event.sessionID] = HookState(status: next, message: event.message, updated: event.date)
                announce(sessionID: event.sessionID, from: previous, to: next, at: event.date)
            } else {
                hookStates[event.sessionID] = nil
            }
        }
    }

    private func publish() {
        let now = Date()
        let resolved = scannedSessions.map { session -> ClaudeCodeSession in
            var session = session
            let quiet = now.timeIntervalSince(session.lastActivity)
            if let hook = hookStates[session.id] {
                switch hook.status {
                case .working:
                    // A killed session never sends Stop; trust a quiet transcript after a while.
                    session.status = quiet < 600 ? .working : .idle
                case .needsPermission, .waitingForInput:
                    session.status = hook.status
                case .finished:
                    session.status = now.timeIntervalSince(hook.updated) < 15 * 60 ? .finished : .idle
                case .idle:
                    session.status = quiet < 20 ? .working : .idle
                }
                session.statusMessage = hook.message
            } else {
                // No hooks: a transcript still being written means Claude is at it.
                session.status = quiet < 20 ? .working : .idle
            }
            return session
        }
        if resolved != sessions {
            withAnimation(.smooth(duration: 0.35)) { sessions = resolved }
        }
    }

    /// Sneak peek under the closed notch when a session needs you or is done.
    private func announce(sessionID: String, from previous: ClaudeCodeSession.Status?, to next: ClaudeCodeSession.Status, at date: Date) {
        guard Defaults[.claudeCodeNotifications], Date().timeIntervalSince(date) < 30 else { return }
        let subtitle: String
        let icon: String
        let accent: Color
        switch next {
        case .needsPermission where previous != .needsPermission:
            subtitle = String(localized: "Needs your permission")
            icon = "hand.raised.fill"
            accent = ClaudeCodePalette.attention
        case .finished where previous == .working:
            subtitle = String(localized: "Done")
            icon = "checkmark.circle.fill"
            accent = ClaudeCodePalette.done
        default:
            return
        }
        let session = scannedSessions.first { $0.id == sessionID }
        let title = session?.projectName ?? session?.title ?? "Claude Code"
        DynamicIslandViewCoordinator.shared.toggleSneakPeek(
            status: true,
            type: .claudeCode,
            duration: 4,
            icon: icon,
            title: title,
            subtitle: subtitle,
            accentColor: accent
        )
    }

    // MARK: - Opening sessions

    /// Desktop sessions open their own chat in the Claude app; CLI sessions
    /// resume in Terminal.
    func open(_ session: ClaudeCodeSession) {
        if session.isDesktop || session.cwd == nil {
            let cliSessionID = session.id
            Task {
                let desktopID = await Task.detached(priority: .userInitiated) {
                    Self.desktopSessionID(forCLISession: cliSessionID)
                }.value
                if let desktopID, let url = URL(string: "claude://code/continue?session=\(desktopID)&source=atoll") {
                    NSWorkspace.shared.open(url)
                } else {
                    Self.activateClaudeApp()
                }
            }
            return
        }
        // A `.command` file opens in the user's Terminal without asking Atoll for
        // automation access.
        let script = FileManager.default.temporaryDirectory
            .appendingPathComponent("atoll-resume-\(session.id).command")
        let body = "#!/bin/sh\n\(session.resumeCommand)\n"
        do {
            try body.write(to: script, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
            NSWorkspace.shared.open(script)
        } catch {
            Logger.log("ClaudeCode: could not open session \(session.id): \(error)", category: .warning)
        }
    }

    /// Brings a CLI session into the Claude app, which imports it and opens it.
    func openInClaudeApp(_ session: ClaudeCodeSession) {
        guard let url = URL(string: "claude://resume?session=\(session.id)") else { return }
        NSWorkspace.shared.open(url)
    }

    private static func activateClaudeApp() {
        guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.anthropic.claudefordesktop") else { return }
        NSWorkspace.shared.openApplication(at: app, configuration: .init())
    }

    /// The Claude app keeps one record per Code session,
    /// `claude-code-sessions/<org>/<account>/local_<id>.json`, which opens with its
    /// own id and the Claude Code session id; the first bytes are enough to match.
    private nonisolated static func desktopSessionID(forCLISession cliSessionID: String) -> String? {
        let root = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Claude/claude-code-sessions", isDirectory: true)
        guard let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ) else { return nil }

        let needle = "\"cliSessionId\":\"\(cliSessionID)\""
        for case let url as URL in enumerator {
            let name = url.lastPathComponent
            if name.hasPrefix("deleted_") {
                enumerator.skipDescendants()
                continue
            }
            guard name.hasPrefix("local_"), url.pathExtension == "json",
                  let handle = try? FileHandle(forReadingFrom: url) else { continue }
            let head = (try? handle.read(upToCount: 512)) ?? Data()
            try? handle.close()
            guard String(decoding: head, as: UTF8.self).contains(needle) else { continue }
            let id = url.deletingPathExtension().lastPathComponent
            // The app only accepts `local_` ids of this shape in the link.
            guard id.range(of: "^local_[A-Za-z0-9-]{1,64}$", options: .regularExpression) != nil else { return nil }
            return id
        }
        return nil
    }

    func revealFolder(of session: ClaudeCodeSession) {
        guard let cwd = session.cwd else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: cwd)])
    }
}

/// Colours of the Claude tab and its notifications.
enum ClaudeCodePalette {
    static let brand = Color(red: 0.85, green: 0.47, blue: 0.34)
    static let attention = Color(red: 1.0, green: 0.72, blue: 0.2)
    static let waiting = Color(red: 0.45, green: 0.68, blue: 1.0)
    static let done = Color(red: 0.4, green: 0.85, blue: 0.5)

    static func color(for status: ClaudeCodeSession.Status) -> Color {
        switch status {
        case .working: return brand
        case .needsPermission: return attention
        case .waitingForInput: return waiting
        case .finished: return done
        case .idle: return .gray
        }
    }
}

/// Minimal FSEvents wrapper: calls back (on the main queue) when anything under
/// the watched paths changes, with the system's own coalescing latency.
final class FileEventStream {
    private var stream: FSEventStreamRef?
    private let onChange: () -> Void

    init(paths: [String], latency: CFTimeInterval = 0.3, onChange: @escaping () -> Void) {
        self.onChange = onChange
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil
        )
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            Unmanaged<FileEventStream>.fromOpaque(info).takeUnretainedValue().onChange()
        }
        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault, callback, &context, paths as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency,
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer)
        ) else { return }
        FSEventStreamSetDispatchQueue(stream, DispatchQueue.main)
        FSEventStreamStart(stream)
        self.stream = stream
    }

    deinit {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
    }
}
