import CryptoKit
import SwiftUI

/// 받은 이미지를 디코딩한 채로 메모리에 둔다.
/// 스크롤로 칸이 다시 만들어질 때 빈 칸부터 그렸다가 채우며 깜박이지 않도록, 캐시에 있으면 첫 프레임부터 바로 그린다.
/// 받은 원본은 디스크(Caches/Images)에도 기한 없이 둔다: 서버가 짧은 유효 기간을 주면(reader 1시간) URLCache 는 기한이 지나
/// 서버에 다시 묻는데, 밖에서 서버에 닿지 않으면 저장된 그림이 있어도 못 띄운다. 포스터는 주소가 같으면 그림도 같다.
final class ImageCache {
    static let shared = ImageCache()

    private let cache = NSCache<NSURL, UIImage>()
    /// 같은 이미지를 여러 칸이 동시에 요청하면 한 번만 받는다
    private var loading: [URL: Task<UIImage?, Never>] = [:]

    private let directory = AppPaths.caches.appending(path: "Images", directoryHint: .isDirectory)

    private init() {
        // 요즘 아이폰은 메모리가 넉넉하다. 포스터 수백 장이 들어갈 만큼 잡는다.
        cache.totalCostLimit = 300 << 20
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    /// 디스크에 둘 파일 (주소에서 서버를 뺀 키의 해시)
    private func file(for url: URL) -> URL {
        let digest = SHA256.hash(data: Data((Self.key(url).absoluteString ?? url.absoluteString).utf8))
        return directory.appending(path: digest.map { String(format: "%02x", $0) }.joined())
    }

    /// 포스터·인물 사진을 모두 비운다 (설정 → 캐시 → 모두 비우기)
    func clear() {
        cache.removeAllObjects()
        URLCache.shared.removeAllCachedResponses()
        try? FileManager.default.removeItem(at: directory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func cached(_ url: URL) -> UIImage? {
        cache.object(forKey: Self.key(url))
    }

    /// 캐시 키는 서버 주소(호스트·포트)를 뺀 경로+쿼리. 네트워크가 바뀌어 서버 주소가 내부망 → 외부로 바뀌어도
    /// 이미 받은 이미지를 그대로 쓴다.
    private static func key(_ url: URL) -> NSURL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url as NSURL }
        components.scheme = nil
        components.host = nil
        components.port = nil
        return (components.url ?? url) as NSURL
    }

    func image(for url: URL) async -> UIImage? {
        if let image = cached(url) { return image }
        if let task = loading[url] { return await task.value }
        let file = file(for: url)
        let task = Task<UIImage?, Never> {
            // 디스크에 있으면 서버에 묻지 않는다
            var data = await Task.detached { try? Data(contentsOf: file) }.value
            if data == nil, let (fetched, response) = try? await URLSession.shared.data(from: url),
               (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? true, UIImage(data: fetched) != nil {
                data = fetched
                Task.detached { try? fetched.write(to: file, options: .atomic) }
            }
            guard let data, let image = UIImage(data: data) else { return nil }
            // 그릴 때 메인 스레드에서 디코딩하지 않도록 미리 풀어 둔다
            return await image.byPreparingForDisplay() ?? image
        }
        loading[url] = task
        let image = await task.value
        loading[url] = nil
        if let image {
            let cost = Int(image.size.width * image.size.height * image.scale * image.scale * 4)
            cache.setObject(image, forKey: Self.key(url), cost: cost)
        }
        return image
    }
}

/// 메모리 캐시를 쓰는 이미지 (AsyncImage 대신)
struct CachedImage: View {
    let url: URL?

    /// 받아 온 이미지와 그 주소. 같은 칸이 다른 주소로 다시 쓰이면 옛 이미지를 보여주지 않도록 주소까지 기억한다.
    @State private var loaded: (url: URL, image: UIImage)?

    var body: some View {
        if let image = (loaded?.url == url ? loaded?.image : nil) ?? url.flatMap(ImageCache.shared.cached) {
            Image(uiImage: image).resizable().scaledToFill()
        } else {
            Rectangle().fill(.quaternary)
                .task(id: url) {
                    guard let url, let image = await ImageCache.shared.image(for: url) else { return }
                    loaded = (url, image)
                }
        }
    }
}
