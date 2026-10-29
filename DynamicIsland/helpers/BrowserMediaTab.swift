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

/// Brings forward the browser tab that is playing the current track.
///
/// Activating a browser shows whichever window it had in front, not the tab
/// with the music. Through the browser's AppleScript dictionary this finds the
/// tab whose title contains the track title (web players put it there), or
/// failing that the first tab on a known music site, makes it the active tab,
/// raises its window and activates the browser. The first use asks for
/// permission to control the browser.
enum BrowserMediaTab {
    private enum Family {
        case chromium
        case safari
    }

    private static let browsers: [String: Family] = [
        "com.google.Chrome": .chromium,
        "com.google.Chrome.beta": .chromium,
        "com.google.Chrome.canary": .chromium,
        "com.brave.Browser": .chromium,
        "com.microsoft.edgemac": .chromium,
        "com.vivaldi.Vivaldi": .chromium,
        "com.operasoftware.Opera": .chromium,
        "ru.yandex.desktop.yandex-browser": .chromium,
        "com.apple.Safari": .safari,
        "com.apple.SafariTechnologyPreview": .safari,
    ]

    /// Sites whose tabs are the likely source when no title matches.
    private static let musicHosts = [
        "open.spotify.com", "music.youtube.com", "youtube.com", "soundcloud.com",
        "music.yandex", "vk.com/audio", "music.apple.com", "deezer.com",
        "tidal.com", "bandcamp.com", "zvuk.com",
    ]

    static func supports(_ bundleIdentifier: String) -> Bool {
        browsers[bundleIdentifier] != nil
    }

    /// True once the browser was asked to show a tab (or just brought forward
    /// when none matched); false when it could not be scripted, so the caller
    /// can fall back to plain activation.
    static func focus(bundleIdentifier: String, title: String) async -> Bool {
        guard let family = browsers[bundleIdentifier] else { return false }
        let script = family == .chromium
            ? chromiumScript(bundleIdentifier: bundleIdentifier, title: title)
            : safariScript(bundleIdentifier: bundleIdentifier, title: title)
        do {
            try await AppleScriptHelper.executeVoid(script)
            return true
        } catch {
            Logger.log("BrowserMediaTab: could not focus tab in \(bundleIdentifier): \(error)", category: .warning)
            return false
        }
    }

    // MARK: - Scripts

    private static func literal(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    private static var hostsList: String {
        "{" + musicHosts.map(literal).joined(separator: ", ") + "}"
    }

    /// Chromium browsers share Chrome's dictionary: windows have tabs with
    /// `title` and `URL`, and an `active tab index`. Titles and URLs are fetched
    /// per window in one event each rather than tab by tab.
    private static func chromiumScript(bundleIdentifier: String, title: String) -> String {
        """
        set needle to \(literal(title))
        set hosts to \(hostsList)
        tell application id \(literal(bundleIdentifier))
            set targetWindow to 0
            set targetTab to 0
            set windowCount to count of windows
            if needle is not "" then
                repeat with w from 1 to windowCount
                    set titleList to title of tabs of window w
                    repeat with t from 1 to count of titleList
                        if item t of titleList contains needle then
                            set targetWindow to w
                            set targetTab to t
                            exit repeat
                        end if
                    end repeat
                    if targetTab > 0 then exit repeat
                end repeat
            end if
            if targetTab = 0 then
                repeat with w from 1 to windowCount
                    set urlList to URL of tabs of window w
                    repeat with t from 1 to count of urlList
                        repeat with h in hosts
                            if item t of urlList contains (contents of h) then
                                set targetWindow to w
                                set targetTab to t
                                exit repeat
                            end if
                        end repeat
                        if targetTab > 0 then exit repeat
                    end repeat
                    if targetTab > 0 then exit repeat
                end repeat
            end if
            if targetTab > 0 then
                set theWindow to window targetWindow
                if minimized of theWindow then set minimized of theWindow to false
                set active tab index of theWindow to targetTab
                set index of theWindow to 1
            end if
            activate
        end tell
        """
    }

    /// Safari's dictionary: tabs have `name` and `URL`, a window has a `current tab`.
    private static func safariScript(bundleIdentifier: String, title: String) -> String {
        """
        set needle to \(literal(title))
        set hosts to \(hostsList)
        tell application id \(literal(bundleIdentifier))
            set targetWindow to 0
            set targetTab to 0
            set windowCount to count of windows
            if needle is not "" then
                repeat with w from 1 to windowCount
                    set titleList to name of tabs of window w
                    repeat with t from 1 to count of titleList
                        if item t of titleList contains needle then
                            set targetWindow to w
                            set targetTab to t
                            exit repeat
                        end if
                    end repeat
                    if targetTab > 0 then exit repeat
                end repeat
            end if
            if targetTab = 0 then
                repeat with w from 1 to windowCount
                    set urlList to URL of tabs of window w
                    repeat with t from 1 to count of urlList
                        repeat with h in hosts
                            if (item t of urlList as text) contains (contents of h) then
                                set targetWindow to w
                                set targetTab to t
                                exit repeat
                            end if
                        end repeat
                        if targetTab > 0 then exit repeat
                    end repeat
                    if targetTab > 0 then exit repeat
                end repeat
            end if
            if targetTab > 0 then
                set theWindow to window targetWindow
                if miniaturized of theWindow then set miniaturized of theWindow to false
                set current tab of theWindow to tab targetTab of theWindow
                set index of theWindow to 1
            end if
            activate
        end tell
        """
    }
}
