import SwiftUI

nonisolated(unsafe) private let _chatImageMemCache = NSCache<NSString, UIImage>()
private let _chatImageDiskSession: URLSession = {
    let cfg = URLSessionConfiguration.default
    cfg.urlCache = URLCache(
        memoryCapacity: 50 * 1024 * 1024,
        diskCapacity: 200 * 1024 * 1024,
        diskPath: "ChatImageCache"
    )
    cfg.requestCachePolicy = .returnCacheDataElseLoad
    return URLSession(configuration: cfg)
}()

struct CachedAsyncImage: View {
    let url: URL

    @State private var image: UIImage?
    @State private var failed = false

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
            } else if failed {
                Label("Image unavailable", systemImage: "photo.badge.exclamationmark")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(8)
            } else {
                ProgressView().padding(20)
            }
        }
        .task(id: url.absoluteString) { await load() }
    }

    private func load() async {
        let key = url.absoluteString as NSString
        if let cached = _chatImageMemCache.object(forKey: key) {
            image = cached; return
        }
        guard let (data, _) = try? await _chatImageDiskSession.data(from: url),
              let img = UIImage(data: data) else { failed = true; return }
        _chatImageMemCache.setObject(img, forKey: key)
        image = img
    }
}
