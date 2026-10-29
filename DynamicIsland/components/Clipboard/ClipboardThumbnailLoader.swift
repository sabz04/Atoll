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
import ImageIO
import QuickLookThumbnailing

/// Card-sized previews for clipboard items.
///
/// Cards never decode a full image on the main thread: ImageIO builds a
/// thumbnail at the size the card draws (a 6K screenshot becomes a ~300px
/// bitmap), off the main thread, and the result is cached by item id so
/// scrolling, hovering and filter changes cost nothing after the first load.
/// Concurrent requests for the same preview share one decode.
@MainActor
final class ClipboardThumbnailLoader {
    static let shared = ClipboardThumbnailLoader()

    struct Preview {
        let image: NSImage
        /// Pixel size of the original image; nil for file icons.
        let pixelSize: CGSize?
    }

    private final class Entry {
        let preview: Preview
        init(_ preview: Preview) { self.preview = preview }
    }

    /// Where the bytes for a preview come from, captured on the main actor so
    /// the decode task never touches `ClipboardItem` state.
    private enum Source {
        case imageFile(URL)
        case imageData(Data)
        case file(URL)
    }

    private let cache: NSCache<NSString, Entry> = {
        let cache = NSCache<NSString, Entry>()
        // Comfortably above the largest history size plus favorites.
        cache.countLimit = 160
        return cache
    }()
    private var inFlight: [NSString: Task<Preview?, Never>] = [:]

    func cachedPreview(for item: ClipboardItem, maxPixel: CGFloat) -> Preview? {
        cache.object(forKey: Self.key(item, maxPixel))?.preview
    }

    func preview(for item: ClipboardItem, maxPixel: CGFloat) async -> Preview? {
        await preview(key: Self.key(item, maxPixel), maxPixel: maxPixel) { Self.source(for: item) }
    }

    /// Previews for files on disk (screenshots, screen recordings), keyed by
    /// path: images are downsampled, everything else goes through QuickLook.
    func cachedPreview(forFileAt url: URL, maxPixel: CGFloat) -> Preview? {
        cache.object(forKey: Self.key(url, maxPixel))?.preview
    }

    func preview(forFileAt url: URL, maxPixel: CGFloat) async -> Preview? {
        let isImage = ["png", "jpg", "jpeg", "heic", "tiff", "gif"].contains(url.pathExtension.lowercased())
        return await preview(key: Self.key(url, maxPixel), maxPixel: maxPixel) {
            isImage ? .imageFile(url) : .file(url)
        }
    }

    private func preview(key: NSString, maxPixel: CGFloat, source makeSource: () -> Source?) async -> Preview? {
        if let hit = cache.object(forKey: key) { return hit.preview }
        if let running = inFlight[key] { return await running.value }
        guard let source = makeSource() else { return nil }

        let task = Task.detached(priority: .utility) {
            await Self.render(source, maxPixel: maxPixel)
        }
        inFlight[key] = task
        let result = await task.value
        inFlight[key] = nil
        if let result { cache.setObject(Entry(result), forKey: key) }
        return result
    }

    private static func key(_ item: ClipboardItem, _ maxPixel: CGFloat) -> NSString {
        "\(item.id.uuidString)-\(Int(maxPixel))" as NSString
    }

    private static func key(_ url: URL, _ maxPixel: CGFloat) -> NSString {
        "file:\(url.path)-\(Int(maxPixel))" as NSString
    }

    private static func source(for item: ClipboardItem) -> Source? {
        switch item.type {
        case .image:
            if let url = item.imageFileURL { return .imageFile(url) }
            return item.getImageData().map(Source.imageData)
        case .file:
            guard let first = item.fileURLs?.first, let url = URL(string: first) else { return nil }
            return .file(url)
        case .text, .url, .rtf, .unknown:
            return nil
        }
    }

    private nonisolated static func render(_ source: Source, maxPixel: CGFloat) async -> Preview? {
        // Without `ShouldCache: false` ImageIO keeps the full decoded bitmap
        // alongside the thumbnail, which is exactly the memory this avoids.
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        switch source {
        case .imageFile(let url):
            guard let imageSource = CGImageSourceCreateWithURL(url as CFURL, sourceOptions) else { return nil }
            return downsample(imageSource, maxPixel: maxPixel)
        case .imageData(let data):
            guard let imageSource = CGImageSourceCreateWithData(data as CFData, sourceOptions) else { return nil }
            return downsample(imageSource, maxPixel: maxPixel)
        case .file(let url):
            return await fileThumbnail(url, maxPixel: maxPixel)
        }
    }

    private nonisolated static func downsample(_ imageSource: CGImageSource, maxPixel: CGFloat) -> Preview? {
        let options = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel
        ] as CFDictionary
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(imageSource, 0, options) else { return nil }

        var pixelSize: CGSize?
        if let properties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any],
           let width = properties[kCGImagePropertyPixelWidth] as? Int,
           let height = properties[kCGImagePropertyPixelHeight] as? Int {
            pixelSize = CGSize(width: width, height: height)
        }
        let image = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        return Preview(image: image, pixelSize: pixelSize)
    }

    /// QuickLook renders real content for images, PDFs, videos and documents;
    /// anything it can't preview falls back to the Finder icon.
    private nonisolated static func fileThumbnail(_ url: URL, maxPixel: CGFloat) async -> Preview? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let request = QLThumbnailGenerator.Request(
            fileAt: url,
            size: CGSize(width: maxPixel, height: maxPixel),
            scale: 1,
            representationTypes: .all
        )
        if let representation = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request) {
            return Preview(image: representation.nsImage, pixelSize: nil)
        }
        let icon = await MainActor.run { NSWorkspace.shared.icon(forFile: url.path) }
        return Preview(image: icon, pixelSize: nil)
    }
}
