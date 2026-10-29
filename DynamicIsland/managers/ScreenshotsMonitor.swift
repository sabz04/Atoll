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
import SwiftUI

/// A screenshot or screen recording macOS saved to disk.
struct ScreenshotItem: Identifiable, Equatable {
    let url: URL
    let created: Date

    var id: URL { url }
    var isRecording: Bool { ["mov", "mp4"].contains(url.pathExtension.lowercased()) }
}

/// Where macOS saves screenshots: the `location` key of `com.apple.screencapture`
/// (what Screenshot.app's Options → Save To writes), Desktop when unset.
enum ScreenshotLocation {
    private static let domain = "com.apple.screencapture"

    static var desktop: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop", isDirectory: true)
    }

    /// The folder set in the system, existing or not.
    static var configured: URL? {
        guard let raw = UserDefaults(suiteName: domain)?.string(forKey: "location"), !raw.isEmpty else { return nil }
        return URL(fileURLWithPath: (raw as NSString).expandingTildeInPath, isDirectory: true)
    }

    /// Where the next screenshot actually lands: the configured folder, or the
    /// Desktop when it is unset or missing — macOS falls back to it then.
    static var effective: URL {
        guard let configured else { return desktop }
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: configured.path, isDirectory: &isDirectory) && isDirectory.boolValue
            ? configured : desktop
    }

    /// Sets the save folder for new screenshots; nil goes back to the Desktop.
    static func set(_ folder: URL?) {
        let defaults = UserDefaults(suiteName: domain)
        if let folder {
            defaults?.set(folder.path, forKey: "location")
        } else {
            defaults?.removeObject(forKey: "location")
        }
        defaults?.synchronize()
    }
}

/// The newest screenshots and screen recordings, newest first.
///
/// Files are recognised by the `kMDItemIsScreenCapture` attribute macOS stamps
/// on every capture, so names in any language and renamed files still count.
/// Watches the save folder and the Desktop (older captures stay where they
/// were) with FSEvents; starts the first time the tab is shown, which is when
/// macOS asks for access to those folders.
@MainActor
final class ScreenshotsMonitor: ObservableObject {
    static let shared = ScreenshotsMonitor()

    @Published private(set) var items: [ScreenshotItem] = []
    @Published private(set) var hasLoaded = false
    /// The system refused to list a folder (Files & Folders privacy setting).
    @Published private(set) var accessDenied = false
    @Published private(set) var saveFolder = ScreenshotLocation.effective
    /// The folder set in the system when it doesn't exist (captures go to the Desktop instead).
    @Published private(set) var missingConfiguredFolder: URL?

    private nonisolated static let maxItems = 60
    private var watcher: FileEventStream?
    private var refreshTask: Task<Void, Never>?
    private var refreshPending = false
    private var isRunning = false

    private init() {}

    func start() {
        guard !isRunning else { return }
        isRunning = true
        reloadLocation()
    }

    // MARK: - Save folder

    func chooseSaveFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = saveFolder
        panel.prompt = String(localized: "Save Screenshots Here")
        NSApp.activate(ignoringOtherApps: true)
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in self?.setSaveFolder(url) }
        }
    }

    func setSaveFolder(_ folder: URL?) {
        ScreenshotLocation.set(folder)
        reloadLocation()
    }

    /// Creates the configured folder that doesn't exist, so captures stop
    /// falling back to the Desktop.
    func createMissingFolder() {
        guard let folder = missingConfiguredFolder else { return }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        reloadLocation()
    }

    private func reloadLocation() {
        saveFolder = ScreenshotLocation.effective
        missingConfiguredFolder = ScreenshotLocation.configured.flatMap { $0 == saveFolder ? nil : $0 }
        watcher = FileEventStream(paths: Self.folders(saveFolder: saveFolder).map(\.path)) { [weak self] in
            Task { @MainActor in self?.scheduleRefresh() }
        }
        scheduleRefresh()
    }

    private nonisolated static func folders(saveFolder: URL) -> [URL] {
        let desktop = ScreenshotLocation.desktop
        return saveFolder.standardizedFileURL == desktop.standardizedFileURL ? [desktop] : [saveFolder, desktop]
    }

    // MARK: - Actions

    func open(_ item: ScreenshotItem) {
        NSWorkspace.shared.open(item.url)
    }

    func reveal(_ item: ScreenshotItem) {
        NSWorkspace.shared.activateFileViewerSelecting([item.url])
    }

    func revealSaveFolder() {
        NSWorkspace.shared.open(saveFolder)
    }

    /// Puts the capture on the clipboard as a file and, for images, as PNG data
    /// too, so both Finder and chat/image apps can paste it.
    func copy(_ item: ScreenshotItem) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        let entry = NSPasteboardItem()
        entry.setString(item.url.absoluteString, forType: .fileURL)
        if !item.isRecording, let data = try? Data(contentsOf: item.url) {
            entry.setData(data, forType: .png)
        }
        pasteboard.writeObjects([entry])
    }

    /// Moves the capture to the Trash (recoverable from there).
    func trash(_ item: ScreenshotItem) {
        do {
            try FileManager.default.trashItem(at: item.url, resultingItemURL: nil)
            withAnimation(.smooth(duration: 0.3)) { items.removeAll { $0.id == item.id } }
        } catch {
            Logger.log("Screenshots: could not move \(item.url.lastPathComponent) to the Trash: \(error)", category: .warning)
        }
    }

    // MARK: - Refresh

    private func scheduleRefresh() {
        guard isRunning else { return }
        guard refreshTask == nil else {
            refreshPending = true
            return
        }
        let folders = Self.folders(saveFolder: saveFolder)
        refreshTask = Task { [weak self] in
            let result = await Task.detached(priority: .utility) { Self.scan(folders) }.value
            guard let self else { return }
            if result.items != self.items {
                withAnimation(.smooth(duration: 0.35)) { self.items = result.items }
            }
            self.accessDenied = result.denied && result.items.isEmpty
            self.hasLoaded = true
            try? await Task.sleep(for: .milliseconds(500))
            self.refreshTask = nil
            if self.refreshPending {
                self.refreshPending = false
                self.scheduleRefresh()
            }
        }
    }

    private nonisolated static func scan(_ folders: [URL]) -> (items: [ScreenshotItem], denied: Bool) {
        let keys: [URLResourceKey] = [.creationDateKey, .isRegularFileKey]
        var denied = false
        var found: [ScreenshotItem] = []
        for folder in folders {
            let entries: [URL]
            do {
                entries = try FileManager.default.contentsOfDirectory(
                    at: folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]
                )
            } catch {
                if (error as NSError).code == NSFileReadNoPermissionError { denied = true }
                continue
            }
            for url in entries where isScreenCapture(url) {
                guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
                found.append(ScreenshotItem(url: url, created: values.creationDate ?? .distantPast))
            }
        }
        let items = found.sorted { $0.created > $1.created }.prefix(maxItems)
        return (Array(items), denied)
    }

    /// macOS stamps every capture with this extended attribute.
    private nonisolated static func isScreenCapture(_ url: URL) -> Bool {
        getxattr(url.path, "com.apple.metadata:kMDItemIsScreenCapture", nil, 0, 0, 0) > 0
    }
}
