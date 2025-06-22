//
//  CachedAsyncImage.swift
//
//
//  Created by Peter Murín on 22/06/2025.
//

import SwiftUI

// MARK: - MemoryUsageTracker

/// Actor responsible for tracking current memory usage.
private actor MemoryUsageTracker {
    private var total = 0

    func add(_ value: Int) {
        total += value
    }

    func subtract(_ value: Int) {
        total -= value
    }

    func current() -> Int {
        total
    }
}

// MARK: - ImageCacheManager

/// A singleton responsible for caching images both in-memory and on disk.
private final class ImageCacheManager {
    static let shared = ImageCacheManager()

    private let memoryCache = NSCache<NSURL, CacheImageWrapper>() // In-memory cache
    private let fileManager = FileManager.default
    private let diskCacheURL: URL // Directory where images will be stored on disk
    private let memoryUsageTracker = MemoryUsageTracker()

    /// Wrapper class to allow deinit logging and memory tracking when NSCache evicts the object.
    /// In Swift 6 we must make sure the `deinit` body does **not** capture `self` in any escaping/async closure.
    private final class CacheImageWrapper {
        let image: UIImage
        let cost: Int

        private let onEvictCallback: @Sendable (Int) async -> Void

        init(image: UIImage, cost: Int, onEvict: @escaping @Sendable (Int) async -> Void) {
            self.image = image
            self.cost = cost
            onEvictCallback = onEvict // store independently to avoid `self` capture later
        }

        deinit {
            // Copy primitives & the callback into local constants so the async closure
            // does **not** implicitly capture `self`, which Swift 6 forbids in deinit.
            let costValue = cost
            let callback = onEvictCallback

            Task.detached(priority: nil) {
                await callback(costValue)
            }

            // debugPrint("🧹 Image was evicted from memory cache, cost: \(costValue) bytes")
        }
    }

    private init() {
        // Locate the system caches directory and create a subdirectory for image caching
        let cacheDirs = fileManager.urls(for: .cachesDirectory, in: .userDomainMask)

        diskCacheURL = cacheDirs[0].appendingPathComponent("ImageCache", isDirectory: true)

        // Create the cache directory if it doesn't exist
        if !fileManager.fileExists(atPath: diskCacheURL.path) {
            do {
                try fileManager.createDirectory(at: diskCacheURL, withIntermediateDirectories: true)
            } catch {
                debugPrint("❌ Failed to create disk cache directory: \(error.localizedDescription)")
            }
        }

        memoryCache.totalCostLimit = 50 * 1_024 * 1_024 // 50 MB memory cache limit
    }

    /// Attempts to retrieve a cached image for the given URL.
    /// Checks memory first, then disk.
    func image(for url: URL) -> UIImage? {
        let key = url as NSURL

        // Return from memory cache if available
        if let wrapped = memoryCache.object(forKey: key) {
            return wrapped.image
        }

        // If not in memory, try loading from disk
        let fileURL = diskCacheURL.appendingPathComponent(fileName(for: url))

        do {
            let data = try Data(contentsOf: fileURL)

            if let image = UIImage(data: data) {
                let cost = data.count

                let wrapper = CacheImageWrapper(
                    image: image,
                    cost: cost,
                    onEvict: { [memoryUsageTracker] evictedCost in
                        await memoryUsageTracker.subtract(evictedCost)
                    }
                )

                Task {
                    await memoryUsageTracker.add(cost)
                }

                memoryCache.setObject(wrapper, forKey: key, cost: cost) // Promote to memory cache

                return image
            } else {
                debugPrint("⚠️ Failed to create UIImage from disk data for URL: \(url)")
            }
        } catch {
            debugPrint("❌ Error reading image data from disk: \(error.localizedDescription)")
        }

        return nil
    }

    /// Stores an image in both memory and disk caches.
    func store(_ image: UIImage, for url: URL) {
        let key = url as NSURL
        let imageData = image.pngData()
        let cost = imageData?.count ?? 1
        let wrapper = CacheImageWrapper(
            image: image,
            cost: cost,
            onEvict: { [memoryUsageTracker] evictedCost in
                await memoryUsageTracker.subtract(evictedCost)
            }
        )

        Task {
            await memoryUsageTracker.add(cost)
        }

        memoryCache.setObject(wrapper, forKey: key, cost: cost)

        let fileURL = diskCacheURL.appendingPathComponent(fileName(for: url))

        if let data = imageData {
            do {
                try data.write(to: fileURL)
            } catch {
                debugPrint("❌ Error writing image to disk: \(error.localizedDescription)")
            }
        } else {
            debugPrint("⚠️ Failed to generate PNG data for image from URL: \(url)")
        }

        //        Task {
        //            let memoryUsed = await currentMemoryUsageValue()
        //
        //            debugPrint("📦 Disk cache usage: \(formattedBytes(currentDiskUsage()))")
        //            debugPrint(
        //                "🧠 Memory cache usage: \(formattedBytes(memoryUsed)) /
        //                \(formattedBytes(memoryCache.totalCostLimit))"
        //            )
        //        }
    }

    /// Creates a sanitized file name for a given URL to use in disk caching.
    private func fileName(for url: URL) -> String {
        let fileName = url.absoluteString.addingPercentEncoding(withAllowedCharacters: .alphanumerics)
            ?? UUID().uuidString

        return fileName + ".png"
    }

    /// Returns total size of files stored in disk cache directory.
    func currentDiskUsage() -> UInt64 {
        let files = try? fileManager.contentsOfDirectory(at: diskCacheURL, includingPropertiesForKeys: [.fileSizeKey])

        return files?.reduce(0) {
            let size = (try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) ?? 0
            return $0 + UInt64(size)
        } ?? 0
    }

    /// Returns the configured memory limit of the NSCache (approximate usage).
    func currentMemoryLimit() -> Int {
        return memoryCache.totalCostLimit
    }

    /// Returns the current tracked memory usage value.
    func currentMemoryUsageValue() async -> Int {
        await memoryUsageTracker.current()
    }

    /// Formats byte count to a readable string (e.g., "1.2 MB").
    private func formattedBytes(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    /// Overload for Int version.
    private func formattedBytes(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}

// MARK: - ImageLoader

/// Responsible for downloading and publishing images, with deduplication and caching support.
private final class ImageLoader: ObservableObject {
    @Published var image: UIImage?
    @Published var didFail = false // Tracks download failure state

    private static var loaders: [URL: ImageLoader] = [:] // Ensures one loader per URL

    private init(url: URL) {
        guard isValidURLUsingDetector(url.absoluteString) else {
            return
        }

        // Attempt to load from cache immediately
        if let cached = ImageCacheManager.shared.image(for: url) {
            image = cached
        } else {
            // Otherwise, start downloading
            load(url: url)
        }
    }

    /// Shared instance per URL to avoid redundant fetches and publishers
    static func shared(for url: URL) -> ImageLoader {
        if let existing = loaders[url] {
            return existing
        } else {
            let new = ImageLoader(url: url)

            loaders[url] = new

            return new
        }
    }

    /// Downloads image from the network and caches it
    private func load(url: URL) {
        Task { @MainActor in
            do {
                let (data, _) = try await URLSession.shared.data(from: url)

                guard let uiImage = UIImage(data: data) else {
                    didFail = true // Set failure flag if request fails

                    return
                }

                ImageCacheManager.shared.store(uiImage, for: url)

                self.image = uiImage
            } catch {
                didFail = true // Set failure flag if image data is corrupted
            }
        }
    }

    private func isValidURLUsingDetector(_ urlString: String) -> Bool {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else {
            return false
        }

        let range = NSRange(location: 0, length: urlString.utf16.count)
        let matches = detector.matches(in: urlString, options: [], range: range)

        return matches.count == 1 && matches.first?.range.length == urlString.utf16.count
    }
}

// MARK: - CachedAsyncImage

/// A SwiftUI view that displays an image with memory + disk caching.
/// Falls back to a placeholder while loading or a fallback view on failure.
struct CachedAsyncImage<Content: View, Placeholder: View>: View {
    @ObservedObject private var loader: ImageLoader

    private let content: (Image) -> Content
    private let placeholder: Placeholder

    /// - Parameters:
    ///   - url: The image URL to load. If nil, placeholder will be shown.
    ///   - content: A closure to render the loaded image.
    ///   - placeholder: A view shown while the image is loading.
    ///   - failure: A view shown if the image fails to load.
    init(
        url: URL,
        @ViewBuilder content: @escaping (Image) -> Content,
        @ViewBuilder placeholder: @escaping () -> Placeholder
    ) {
        loader = ImageLoader.shared(for: url)
        self.content = content
        self.placeholder = placeholder()
    }

    var body: some View {
        Group {
            if let image = loader.image {
                // Render successfully loaded image
                content(Image(uiImage: image))
            } else if loader.didFail {
                // Show placeholder view if loading failed
                placeholder
            } else {
                // Show placeholder while loading
                placeholder
                    .redacted(reason: .placeholder)
            }
        }
    }
}
