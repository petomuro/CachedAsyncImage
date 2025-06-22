# CachedAsyncImage

## 🔍 Overview

`CachedAsyncImage` is a SwiftUI view that loads and displays an image from a URL, using both in-memory and disk-based caching. It's optimized for performance and memory efficiency, designed to prevent unnecessary image reloads across sessions.

It is designed to work seamlessly with [`CustomImage`](https://github.com/petomuro/CustomImage/tree/main), providing a robust image pipeline.

## 🧱 Structure

### 🔄 ImageCacheManager
- Singleton class managing image caching
- Two-tier caching: memory (via `NSCache`) and disk (via `FileManager`)
- Uses a custom `CacheImageWrapper` to track memory cost and log evictions

### 🧠 MemoryUsageTracker
- Swift actor responsible for tracking memory usage asynchronously
- Ensures accurate cost accounting when images are evicted

### 📥 ImageLoader
- Deduplicates fetches for the same URL
- Publishes the image state and failure flags
- Supports loading images via `URLSession` and promotes disk images into memory cache

### 🖼️ View: CachedAsyncImage
```swift
struct CachedAsyncImage<Content: View, Placeholder: View>: View {
    init(
        url: URL,
        @ViewBuilder content: @escaping (Image) -> Content,
        @ViewBuilder placeholder: @escaping () -> Placeholder
    )
}
```

## 🔄 Image Fetch Flow

1. Try to fetch from in-memory cache
2. Fallback to disk cache if not found
3. If not on disk, download via `URLSession`
4. On success, store in both memory and disk
5. If it fails, show placeholder

## 📦 Features

- 🧠 **Memory usage tracking** with total size limits
- 💾 **Disk cache** for persistence across launches
- 🔄 **Automatic promotion** of disk image to memory cache
- 🧪 **Remote image validation** using `NSDataDetector`

## 💡 Usage Example

```swift
CachedAsyncImage(url: URL(string: "https://example.com/image.png")!) { image in
    image
        .resizable()
} placeholder: {
    ProgressView()
}
```

## 🌉 Integration with `CustomImage`

`CachedAsyncImage` is the backend renderer for remote images used in the `CustomImage` component:

```swift
CustomImage.remote(
    url: ...,
    imageColor: ...,
    placeholder: ...,
    placeholderColor: ...
).view()
```

👉 See the `CustomImage` Documentation for recommended usage and API details.

## 🧭 Navigation

See also: [CustomImage](https://github.com/petomuro/CustomImage/tree/main)
