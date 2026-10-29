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

/// Recent screenshots and screen recordings as a notch tab. Click copies a
/// capture, dragging drops the file into any app, hover offers open / show in
/// Finder / move to Trash. The toolbar shows and changes where macOS saves them.
struct NotchScreenshotsView: View {
    @EnvironmentObject var vm: DynamicIslandViewModel
    @ObservedObject private var monitor = ScreenshotsMonitor.shared
    @State private var justCopied: URL?
    @State private var suppressionToken = UUID()
    @State private var isSuppressing = false

    private static let privacySettingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_FilesAndFolders")!

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            toolbar

            if monitor.accessDenied {
                accessDenied
            } else if !monitor.hasLoaded {
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if monitor.items.isEmpty {
                emptyState
            } else {
                strip
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 4)
        .padding(.bottom, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onHover { updateSuppression(for: $0) }
        .onDisappear { updateSuppression(for: false) }
        .onAppear { monitor.start() }
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "camera.viewfinder")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.white.opacity(0.85))
                Text("Screenshots")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                if !monitor.items.isEmpty {
                    Text(monitor.items.count, format: .number)
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.white.opacity(0.5))
                }
            }

            Spacer(minLength: 0)

            if let missing = monitor.missingConfiguredFolder {
                Button {
                    withAnimation(.smooth(duration: 0.25)) { monitor.createMissingFolder() }
                } label: {
                    Label("Create “\(missing.lastPathComponent)”", systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(Color(red: 1.0, green: 0.72, blue: 0.2))
                        .padding(.horizontal, 9)
                        .frame(height: 24)
                        .background(Capsule().fill(Color(red: 1.0, green: 0.72, blue: 0.2).opacity(0.14)))
                }
                .buttonStyle(.plain)
                .help("The save folder set in macOS doesn't exist, so screenshots go to the Desktop. Create it to save there.")
            }

            folderMenu
        }
        .frame(height: 26)
    }

    private var folderMenu: some View {
        Menu {
            Button("Choose Folder…") { monitor.chooseSaveFolder() }
            if monitor.saveFolder.standardizedFileURL != ScreenshotLocation.desktop.standardizedFileURL {
                Button("Save to Desktop") { monitor.setSaveFolder(nil) }
            }
            Divider()
            Button("Show in Finder") { monitor.revealSaveFolder() }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "folder.fill")
                    .font(.system(size: 10))
                Text(folderName)
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .opacity(0.6)
            }
            .foregroundStyle(.white.opacity(0.85))
            .padding(.horizontal, 10)
            .frame(height: 24)
            .background(Capsule().fill(Color.white.opacity(0.1)))
            .contentShape(Capsule())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Where macOS saves new screenshots")
    }

    private var folderName: String {
        monitor.saveFolder.standardizedFileURL == ScreenshotLocation.desktop.standardizedFileURL
            ? String(localized: "Desktop")
            : monitor.saveFolder.lastPathComponent
    }

    // MARK: - Content

    private var strip: some View {
        GeometryReader { geo in
            let height = geo.size.height
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 10) {
                    ForEach(monitor.items) { item in
                        ScreenshotCard(
                            item: item,
                            justCopied: justCopied == item.url,
                            onCopy: { copy(item) },
                            onOpen: { monitor.open(item) },
                            onReveal: { monitor.reveal(item) },
                            onTrash: { monitor.trash(item) }
                        )
                        .frame(width: (height * 1.5).rounded(), height: height)
                        .onDrag {
                            // Keeps the notch open for the drop (see ClipboardManager.isDraggingItem).
                            ClipboardManager.shared.markDragStart()
                            return NSItemProvider(contentsOf: item.url) ?? NSItemProvider()
                        }
                        .transition(.scale(scale: 0.92).combined(with: .opacity))
                    }
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "camera.viewfinder")
                .font(.system(size: 24, weight: .light))
                .foregroundStyle(.secondary.opacity(0.5))
            Text("No screenshots yet")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
            Text("⇧⌘4 captures part of the screen, ⇧⌘5 opens all options")
                .font(.caption)
                .foregroundStyle(.secondary.opacity(0.7))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var accessDenied: some View {
        VStack(spacing: 8) {
            Image(systemName: "lock.fill")
                .font(.system(size: 20))
                .foregroundStyle(.secondary.opacity(0.6))
            Text("Atoll can't see the screenshot folder")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
            Button("Open Privacy Settings") {
                NSWorkspace.shared.open(Self.privacySettingsURL)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func copy(_ item: ScreenshotItem) {
        monitor.copy(item)
        withAnimation(.easeOut(duration: 0.2)) { justCopied = item.url }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            if justCopied == item.url {
                withAnimation(.easeOut(duration: 0.2)) { justCopied = nil }
            }
        }
    }

    private func updateSuppression(for hovering: Bool) {
        guard hovering != isSuppressing else { return }
        isSuppressing = hovering
        vm.setScrollGestureSuppression(hovering, token: suppressionToken)
    }
}

// MARK: - Card

private struct ScreenshotCard: View {
    let item: ScreenshotItem
    let justCopied: Bool
    let onCopy: () -> Void
    let onOpen: () -> Void
    let onReveal: () -> Void
    let onTrash: () -> Void

    private static let thumbnailPixels: CGFloat = 400
    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()

    @State private var isHovered = false
    @State private var preview: ClipboardThumbnailLoader.Preview?
    private let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)

    init(
        item: ScreenshotItem,
        justCopied: Bool,
        onCopy: @escaping () -> Void,
        onOpen: @escaping () -> Void,
        onReveal: @escaping () -> Void,
        onTrash: @escaping () -> Void
    ) {
        self.item = item
        self.justCopied = justCopied
        self.onCopy = onCopy
        self.onOpen = onOpen
        self.onReveal = onReveal
        self.onTrash = onTrash
        // Seed from the cache so a card scrolled back into view never flashes empty.
        _preview = State(initialValue: ClipboardThumbnailLoader.shared.cachedPreview(forFileAt: item.url, maxPixel: Self.thumbnailPixels))
    }

    var body: some View {
        Color.black
            .overlay {
                if let preview {
                    Image(nsImage: preview.image)
                        .resizable()
                        .interpolation(.medium)
                        .aspectRatio(contentMode: .fill)
                } else {
                    Image(systemName: item.isRecording ? "video" : "photo")
                        .font(.system(size: 22, weight: .light))
                        .foregroundStyle(.white.opacity(0.3))
                }
            }
            .overlay {
                if item.isRecording {
                    Image(systemName: "play.circle.fill")
                        .font(.system(size: 26))
                        .foregroundStyle(.white.opacity(0.9), .black.opacity(0.4))
                }
            }
            .overlay(alignment: .bottom) { footer }
            .clipShape(shape)
            .overlay(shape.strokeBorder(Color.white.opacity(isHovered ? 0.3 : 0.08), lineWidth: 1))
            .overlay(alignment: .topTrailing) {
                if isHovered && !justCopied { actions }
            }
            .overlay {
                if justCopied { copiedOverlay }
            }
            .contentShape(shape)
            .onHover { isHovered = $0 }
            .onTapGesture(perform: onCopy)
            .animation(.easeOut(duration: 0.15), value: isHovered)
            .task(id: item.url) {
                guard preview == nil else { return }
                preview = await ClipboardThumbnailLoader.shared.preview(forFileAt: item.url, maxPixel: Self.thumbnailPixels)
            }
            .contextMenu {
                Button("Copy", action: onCopy)
                Button("Open", action: onOpen)
                Button("Show in Finder", action: onReveal)
                Divider()
                Button("Move to Trash", role: .destructive, action: onTrash)
            }
            .help(item.url.lastPathComponent)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(item.url.lastPathComponent)
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { onCopy() }
    }

    private var footer: some View {
        HStack(spacing: 4) {
            if item.isRecording {
                Image(systemName: "record.circle")
                    .font(.system(size: 9, weight: .bold))
            }
            Text(relativeTime)
            Spacer(minLength: 4)
            if let size = preview?.pixelSize {
                Text(verbatim: "\(Int(size.width))×\(Int(size.height))")
                    .monospacedDigit()
            }
        }
        .font(.system(size: 9.5, weight: .medium))
        .foregroundStyle(.white.opacity(0.9))
        .padding(.horizontal, 9)
        .padding(.top, 12)
        .padding(.bottom, 6)
        .background(LinearGradient(colors: [.clear, .black.opacity(0.75)], startPoint: .top, endPoint: .bottom))
    }

    private var actions: some View {
        HStack(spacing: 4) {
            actionButton("arrow.up.forward.app", help: "Open", action: onOpen)
            actionButton("folder", help: "Show in Finder", action: onReveal)
            actionButton("trash", help: "Move to Trash", tint: .red, action: onTrash)
        }
        .padding(6)
        .transition(.opacity)
    }

    private func actionButton(_ icon: String, help: LocalizedStringKey, tint: Color = .white, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 9.5, weight: .bold))
                .foregroundStyle(tint)
                .frame(width: 22, height: 22)
                .background(Circle().fill(Color.black.opacity(0.6)))
                .overlay(Circle().strokeBorder(Color.white.opacity(0.15), lineWidth: 0.5))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private var copiedOverlay: some View {
        ZStack {
            shape.fill(Color.black.opacity(0.55))
            VStack(spacing: 4) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(.green)
                Text("Copied")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white)
            }
        }
        .transition(.opacity)
        .allowsHitTesting(false)
    }

    private var relativeTime: String {
        if Date().timeIntervalSince(item.created) < 60 { return String(localized: "Just now") }
        return Self.relativeFormatter.localizedString(for: item.created, relativeTo: Date())
    }
}
