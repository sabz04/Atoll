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
import Combine
import Defaults

/// What the clipboard tab shows. Type filters span history and favorites alike,
/// so a pinned screenshot still shows up under Photos.
enum ClipboardFilter: CaseIterable, Identifiable {
    case all
    case text
    case links
    case photos
    case files
    case favorites

    var id: Self { self }

    var title: String {
        switch self {
        case .all: return String(localized: "All")
        case .text: return String(localized: "Text")
        case .links: return String(localized: "Links")
        case .photos: return String(localized: "Photos")
        case .files: return String(localized: "Files")
        case .favorites: return String(localized: "Favorites")
        }
    }

    var icon: String {
        switch self {
        case .all: return "square.grid.2x2"
        case .text: return "text.alignleft"
        case .links: return "link"
        case .photos: return "photo"
        case .files: return "doc"
        case .favorites: return "heart"
        }
    }

    var selectedIcon: String {
        switch self {
        case .all: return "square.grid.2x2.fill"
        case .photos: return "photo.fill"
        case .files: return "doc.fill"
        case .favorites: return "heart.fill"
        case .text, .links: return icon
        }
    }

    func matches(_ item: ClipboardItem) -> Bool {
        switch self {
        case .all: return true
        case .text: return item.type == .text || item.type == .rtf || item.type == .unknown
        case .links: return item.type == .url
        case .photos: return item.type == .image
        case .files: return item.type == .file
        case .favorites: return item.isPinned
        }
    }
}

extension ClipboardItemType {
    /// Accent for the type glyph on cards; kept muted so the content stays the focus.
    var cardTint: Color {
        switch self {
        case .text: return Color(red: 0.42, green: 0.68, blue: 1.0)
        case .rtf: return Color(red: 0.62, green: 0.56, blue: 1.0)
        case .url: return Color(red: 0.35, green: 0.85, blue: 0.75)
        case .image: return Color(red: 1.0, green: 0.48, blue: 0.62)
        case .file: return Color(red: 1.0, green: 0.66, blue: 0.3)
        case .unknown: return .gray
        }
    }
}

extension ClipboardItem {
    func matchesSearch(_ query: String) -> Bool {
        if preview.localizedCaseInsensitiveContains(query) { return true }
        if let stringData, stringData.localizedCaseInsensitiveContains(query) { return true }
        if let fileURLs {
            return fileURLs.contains { URL(string: $0)?.lastPathComponent.localizedCaseInsensitiveContains(query) ?? false }
        }
        return false
    }
}

/// Where the clipboard tab was, kept outside the view: the notch tears its tab
/// content down on every close, and reopening should land on the same filter,
/// search and scroll position instead of a fresh tab.
final class ClipboardTabState: ObservableObject {
    static let shared = ClipboardTabState()

    @Published private(set) var filter: ClipboardFilter = .all
    @Published private(set) var query = ""
    /// Leading card of the strip; the scroll view writes it as you scroll.
    @Published var scrolledItemID: UUID?
    /// Whether the tab is on screen, so a copy made meanwhile can reset the strip.
    var isVisible = false

    private var copyCancellable: AnyCancellable?

    private init() {
        // A copy made while the notch was closed should be the first thing you
        // see on reopening, not hidden off to the left of the remembered card.
        copyCancellable = ClipboardManager.shared.$lastCopiedItemDate
            .dropFirst()
            .sink { [weak self] _ in
                guard let self, !self.isVisible else { return }
                self.scrolledItemID = nil
            }
    }

    // Changing what the strip lists starts it from the newest item; the reset has
    // to land in the same update, before the rebuilt scroll view reads the binding.
    func select(_ newFilter: ClipboardFilter) {
        scrolledItemID = nil
        filter = newFilter
    }

    func search(_ newQuery: String) {
        scrolledItemID = nil
        query = newQuery
    }
}

/// The clipboard as a notch tab: filter chips and search on top, a horizontal
/// strip of content cards below — photos render as real thumbnails, text as a
/// readable snippet, links by host, files by their QuickLook preview. Tap a
/// card to copy it back, drag it out to drop it into another app.
///
/// Also used, `compact`, as the clipboard half of the `.separateTab` split view.
struct NotchClipboardView: View {
    @EnvironmentObject var vm: DynamicIslandViewModel
    @ObservedObject var clipboardManager = ClipboardManager.shared
    @ObservedObject private var state = ClipboardTabState.shared
    /// Narrow layout for the split panel: icon-only filters and no search field.
    var compact: Bool = false

    @State private var justCopiedId: UUID?
    @State private var suppressionToken = UUID()
    @State private var isSuppressing = false
    @State private var showClearHistoryAlert = false
    @State private var autoCloseToken = UUID()
    @Namespace private var filterNamespace

    /// History and favorites together, newest first.
    private var allItems: [ClipboardItem] {
        (clipboardManager.pinnedItems + clipboardManager.clipboardHistory)
            .sorted { $0.timestamp > $1.timestamp }
    }

    var body: some View {
        let all = allItems
        let needle = state.query.trimmingCharacters(in: .whitespacesAndNewlines)
        let items = all.filter { state.filter.matches($0) && (needle.isEmpty || $0.matchesSearch(needle)) }

        VStack(alignment: .leading, spacing: 10) {
            toolbar(all: all)

            if all.isEmpty {
                emptyState(icon: "doc.on.clipboard", title: "No copies yet", subtitle: "Copy something to see it here")
            } else if items.isEmpty {
                emptyState(icon: "magnifyingglass", title: "No results", subtitle: nil)
            } else {
                strip(items)
            }
        }
        .padding(.horizontal, compact ? 10 : 20)
        .padding(.top, 4)
        .padding(.bottom, compact ? 10 : 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onHover { updateSuppression(for: $0) }
        .onDisappear {
            state.isVisible = false
            updateSuppression(for: false)
            // Release the alert-driven suppression too: if the view is torn down while
            // the clear-history alert is open, onChange never fires false and it leaks.
            vm.setAutoCloseSuppression(false, token: autoCloseToken)
        }
        .alert("Clear Clipboard History?", isPresented: $showClearHistoryAlert) {
            Button("Clear History", role: .destructive) { clipboardManager.clearHistory() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes every saved clipboard item from the notch tab.")
        }
        .onChange(of: showClearHistoryAlert) { _, isShowing in
            vm.setAutoCloseSuppression(isShowing, token: autoCloseToken)
        }
        .onAppear {
            state.isVisible = true
            if Defaults[.enableClipboardManager], !clipboardManager.isMonitoring {
                clipboardManager.startMonitoring()
            }
        }
    }

    // MARK: - Toolbar

    private func toolbar(all: [ClipboardItem]) -> some View {
        HStack(spacing: 8) {
            HStack(spacing: 2) {
                ForEach(ClipboardFilter.allCases) { candidate in
                    ClipboardFilterChip(
                        filter: candidate,
                        count: all.reduce(0) { $0 + (candidate.matches($1) ? 1 : 0) },
                        isSelected: state.filter == candidate,
                        showsTitle: !compact && state.filter == candidate,
                        namespace: filterNamespace
                    ) {
                        withAnimation(.smooth(duration: 0.25)) { state.select(candidate) }
                    }
                }
            }

            Spacer(minLength: 0)

            if !compact {
                ClipboardSearchField(text: Binding(get: { state.query }, set: { state.search($0) }))
            }

            if !clipboardManager.clipboardHistory.isEmpty {
                Button { showClearHistoryAlert = true } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.red.opacity(0.9))
                        .frame(width: 26, height: 26)
                        .background(Circle().fill(Color.white.opacity(0.08)))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help("Clear History")
            }
        }
        .frame(height: 26)
    }

    // MARK: - Cards

    private func strip(_ items: [ClipboardItem]) -> some View {
        GeometryReader { geo in
            let side = max(96, geo.size.height)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 10) {
                    ForEach(items) { item in
                        ClipboardCard(
                            item: item,
                            justCopied: justCopiedId == item.id,
                            onCopy: { copy(item) },
                            onTogglePin: { withAnimation(.smooth(duration: 0.25)) { clipboardManager.togglePin(for: item) } },
                            onDelete: { withAnimation(.smooth(duration: 0.25)) { clipboardManager.deleteItem(item) } }
                        )
                        .frame(width: side, height: side)
                        .clipboardDraggable(item)
                    }
                }
                .scrollTargetLayout()
            }
            // Restores the remembered card when the notch reopens.
            .scrollPosition(id: $state.scrolledItemID, anchor: .leading)
            // A new filter or search starts from the newest item instead of a stale offset.
            .id("\(state.filter)|\(state.query)")
        }
    }

    private func emptyState(icon: String, title: LocalizedStringKey, subtitle: LocalizedStringKey?) -> some View {
        VStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 26))
                .foregroundStyle(.secondary.opacity(0.35))
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
            if let subtitle {
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary.opacity(0.7))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func copy(_ item: ClipboardItem) {
        clipboardManager.copyToClipboard(item)
        withAnimation { justCopiedId = item.id }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            if justCopiedId == item.id {
                withAnimation { justCopiedId = nil }
            }
        }
    }

    private func updateSuppression(for hovering: Bool) {
        guard hovering != isSuppressing else { return }
        isSuppressing = hovering
        vm.setScrollGestureSuppression(hovering, token: suppressionToken)
    }
}

// MARK: - Filter chip

private struct ClipboardFilterChip: View {
    let filter: ClipboardFilter
    let count: Int
    let isSelected: Bool
    let showsTitle: Bool
    let namespace: Namespace.ID
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: isSelected ? filter.selectedIcon : filter.icon)
                    .font(.system(size: 11, weight: .semibold))
                if showsTitle {
                    Text(filter.title)
                        .font(.system(size: 11.5, weight: .semibold))
                        .lineLimit(1)
                        .fixedSize()
                }
                if count > 0 {
                    Text(count, format: .number)
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .opacity(0.65)
                }
            }
            .foregroundStyle(isSelected ? Color.white : Color.gray)
            .padding(.horizontal, 9)
            .frame(height: 26)
            .background {
                if isSelected {
                    Capsule()
                        .fill(Color.white.opacity(0.16))
                        .matchedGeometryEffect(id: "clipboard-filter", in: namespace)
                }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .opacity(count == 0 && !isSelected ? 0.45 : 1)
        .help(filter.title)
        .accessibilityLabel(filter.title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

// MARK: - Search field

private struct ClipboardSearchField: View {
    @Binding var text: String
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.gray)
            TextField("Search clipboard...", text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(.white)
                .focused($isFocused)
                .onExitCommand {
                    text = ""
                    isFocused = false
                }
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.gray)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .frame(minWidth: 110, maxWidth: 200)
        .frame(height: 26)
        .background(Capsule().fill(Color.white.opacity(isFocused ? 0.14 : 0.08)))
        .overlay(Capsule().strokeBorder(Color.white.opacity(isFocused ? 0.2 : 0), lineWidth: 1))
        .animation(.easeOut(duration: 0.15), value: isFocused)
    }
}

// MARK: - Card

/// One clipboard entry rendered by what it holds rather than as a generic row.
struct ClipboardCard: View {
    let item: ClipboardItem
    let justCopied: Bool
    let onCopy: () -> Void
    let onTogglePin: () -> Void
    let onDelete: () -> Void

    /// Decode size shared by every card so all of them hit the same cache entry.
    private static let thumbnailPixels: CGFloat = 320
    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()

    @State private var isHovered = false
    @State private var preview: ClipboardThumbnailLoader.Preview?

    private let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)

    init(
        item: ClipboardItem,
        justCopied: Bool,
        onCopy: @escaping () -> Void,
        onTogglePin: @escaping () -> Void,
        onDelete: @escaping () -> Void
    ) {
        self.item = item
        self.justCopied = justCopied
        self.onCopy = onCopy
        self.onTogglePin = onTogglePin
        self.onDelete = onDelete
        // Seed from the cache so a card scrolled back into view never flashes a placeholder.
        _preview = State(initialValue: ClipboardThumbnailLoader.shared.cachedPreview(for: item, maxPixel: Self.thumbnailPixels))
    }

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(item.type == .image ? Color.black : Color.white.opacity(isHovered ? 0.11 : 0.07))
            .overlay(alignment: .bottom) { footer }
            .clipShape(shape)
            .overlay(shape.strokeBorder(Color.white.opacity(isHovered ? 0.28 : 0.08), lineWidth: 1))
            .overlay(alignment: .topLeading) {
                if item.isPinned && !isHovered { pinBadge }
            }
            .overlay(alignment: .topTrailing) {
                if isHovered { actions }
            }
            .overlay {
                if justCopied { copiedOverlay }
            }
            .contentShape(shape)
            .onHover { isHovered = $0 }
            .onTapGesture(perform: onCopy)
            .animation(.easeOut(duration: 0.15), value: isHovered)
            .animation(.easeOut(duration: 0.2), value: justCopied)
            .task(id: item.id) {
                guard preview == nil, item.type == .image || item.type == .file else { return }
                preview = await ClipboardThumbnailLoader.shared.preview(for: item, maxPixel: Self.thumbnailPixels)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(item.type.displayName): \(item.preview)")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { onCopy() }
            .accessibilityAction(named: Text("Delete")) { onDelete() }
    }

    // MARK: Content per type

    @ViewBuilder
    private var content: some View {
        switch item.type {
        case .image:
            imageContent
        case .url:
            linkContent
        case .file:
            fileContent
        case .text, .rtf, .unknown:
            textContent
        }
    }

    @ViewBuilder
    private var imageContent: some View {
        if let preview {
            Color.clear
                .overlay {
                    Image(nsImage: preview.image)
                        .resizable()
                        .interpolation(.medium)
                        .aspectRatio(contentMode: .fill)
                }
                .clipped()
        } else {
            placeholder(icon: "photo")
        }
    }

    private var textContent: some View {
        Text(String((item.stringData ?? item.preview).prefix(400)))
            .font(.system(size: 11.5))
            .foregroundStyle(.white.opacity(0.9))
            .lineSpacing(1.5)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(EdgeInsets(top: 10, leading: 10, bottom: 26, trailing: 10))
    }

    private var linkContent: some View {
        let url = item.stringData.flatMap(URL.init(string:))
        let host = url?.host.map { $0.hasPrefix("www.") ? String($0.dropFirst(4)) : $0 } ?? item.preview
        let path = url.map { url -> String in
            let query = url.query.map { "?\($0)" } ?? ""
            return url.path + query
        } ?? ""

        return VStack(alignment: .leading, spacing: 3) {
            Image(systemName: "globe")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(item.type.cardTint)
                .frame(width: 32, height: 32)
                .background(Circle().fill(item.type.cardTint.opacity(0.15)))
            Spacer(minLength: 0)
            Text(host)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
            if !path.isEmpty && path != "/" {
                Text(path)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.white.opacity(0.55))
                    .lineLimit(2)
                    .truncationMode(.middle)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(EdgeInsets(top: 10, leading: 10, bottom: 26, trailing: 10))
    }

    private var fileContent: some View {
        let count = item.fileURLs?.count ?? 0
        return VStack(spacing: 6) {
            Group {
                if let preview {
                    Image(nsImage: preview.image)
                        .resizable()
                        .interpolation(.medium)
                        .aspectRatio(contentMode: .fit)
                        .shadow(color: .black.opacity(0.35), radius: 4, y: 2)
                } else {
                    Image(systemName: "doc")
                        .font(.system(size: 28, weight: .light))
                        .foregroundStyle(item.type.cardTint)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(alignment: .bottomTrailing) {
                if count > 1 {
                    Text(verbatim: "+\(count - 1)")
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(item.type.cardTint.opacity(0.85)))
                }
            }
            Text(item.preview)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.9))
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .truncationMode(.middle)
        }
        .padding(EdgeInsets(top: 12, leading: 10, bottom: 26, trailing: 10))
    }

    private func placeholder(icon: String) -> some View {
        Image(systemName: icon)
            .font(.system(size: 24, weight: .light))
            .foregroundStyle(item.type.cardTint.opacity(0.6))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Chrome

    private var footer: some View {
        HStack(spacing: 4) {
            Image(systemName: item.type.icon)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(item.type.cardTint)
            Text(detail)
                .lineLimit(1)
            Spacer(minLength: 4)
            Text(relativeTime)
                .lineLimit(1)
                .layoutPriority(1)
        }
        .font(.system(size: 9.5, weight: .medium))
        .foregroundStyle(.white.opacity(item.type == .image ? 0.9 : 0.5))
        .padding(.horizontal, 9)
        .padding(.top, 10)
        .padding(.bottom, 6)
        .background {
            if item.type == .image {
                LinearGradient(colors: [.clear, .black.opacity(0.75)], startPoint: .top, endPoint: .bottom)
            }
        }
    }

    private var detail: String {
        if item.type == .image, let size = preview?.pixelSize {
            return "\(Int(size.width))×\(Int(size.height))"
        }
        return item.type.displayName
    }

    private var relativeTime: String {
        if Date().timeIntervalSince(item.timestamp) < 60 { return String(localized: "Just now") }
        return Self.relativeFormatter.localizedString(for: item.timestamp, relativeTo: Date())
    }

    private var pinBadge: some View {
        Image(systemName: "heart.fill")
            .font(.system(size: 8, weight: .bold))
            .foregroundStyle(.pink)
            .frame(width: 18, height: 18)
            .background(Circle().fill(Color.black.opacity(0.55)))
            .padding(6)
    }

    private var actions: some View {
        HStack(spacing: 4) {
            ClipboardCardActionButton(
                icon: item.isPinned ? "heart.fill" : "heart",
                tint: item.isPinned ? .pink : .white,
                help: item.isPinned ? "Remove from Favorites" : "Add to Favorites",
                action: onTogglePin
            )
            ClipboardCardActionButton(icon: "xmark", tint: .white, help: "Delete", action: onDelete)
        }
        .padding(6)
        .transition(.opacity)
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
}

private struct ClipboardCardActionButton: View {
    let icon: String
    let tint: Color
    let help: LocalizedStringKey
    let action: () -> Void

    var body: some View {
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
}
