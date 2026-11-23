#if os(macOS)
import VLCKit
#else
import MobileVLCKit
#endif
import Observation
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

/// 영상 썸네일과 길이를 만들어 캐시한다. VLC 로 만들기 때문에 MKV 등 모든 포맷을 지원한다.
final class ThumbnailService {
    static let shared = ThumbnailService()

    private var memory: [String: UIImage] = [:]
    private var durations: [String: Double]
    private let directory: URL
    private let durationsURL: URL

    /// 썸네일 생성은 한 번에 하나씩 (VLC 인스턴스를 동시에 많이 띄우지 않도록)
    private var tail: Task<Void, Never>?

    private init() {
        directory = AppPaths.caches.appending(path: "Thumbnails")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        durationsURL = directory.appending(path: "durations.json")
        durations = (try? JSONDecoder().decode([String: Double].self, from: Data(contentsOf: durationsURL))) ?? [:]
    }

    /// 캐시된 영상 길이 (초)
    func duration(for file: VideoFile) -> Double? {
        durations[cacheKey(file)]
    }

    /// 목록용 썸네일
    func thumbnail(for file: VideoFile) async -> UIImage? {
        let key = cacheKey(file)
        if let image = memory[key] { return image }
        let imageURL = directory.appending(path: "\(key).jpg")
        if let image = UIImage(contentsOfFile: imageURL.path), durations[key] != nil {
            memory[key] = image
            return image
        }

        var result = await enqueue { await ThumbnailRequest().run(url: file.url, serverID: file.serverID, position: 0.1) }
        // 우연히 검은(또는 한 가지 색) 장면이면 더 뒤에서 다시 뽑는다. 끝까지 그러면 마지막 것을 쓴다
        for position: Float in [0.25, 0.4] {
            guard let image = result.image, Self.looksBlank(image) else { break }
            let retry = await enqueue { await ThumbnailRequest().run(url: file.url, serverID: file.serverID, position: position) }
            guard let retryImage = retry.image else { break }
            result = (retryImage, result.duration > 0 ? result.duration : retry.duration)
        }
        if result.duration > 0 {
            durations[key] = result.duration
            if let data = try? JSONEncoder().encode(durations) {
                try? data.write(to: durationsURL, options: .atomic)
            }
        }
        guard let cgImage = result.image else { return nil }
        let image = UIImage(cgImage: cgImage)
        memory[key] = image
        try? image.jpegData(compressionQuality: 0.8)?.write(to: imageURL, options: .atomic)
        return image
    }

    /// 검은 화면·한 가지 색 화면인지: 16×16 으로 줄여 밝기를 본다.
    /// 어두운 밤 장면이라도 불빛·자막처럼 밝은 곳이 있으면 살린다 (평균만 보지 않고 가장 밝은 점도 본다)
    nonisolated static func looksBlank(_ image: CGImage) -> Bool {
        let side = 16
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                                          space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        guard drawn else { return false }
        let luma = stride(from: 0, to: pixels.count, by: 4).map {
            0.299 * Double(pixels[$0]) + 0.587 * Double(pixels[$0 + 1]) + 0.114 * Double(pixels[$0 + 2])
        }
        let mean = luma.reduce(0, +) / Double(luma.count)
        let brightest = luma.max() ?? 0, darkest = luma.min() ?? 0
        return (mean < 20 && brightest < 60) || brightest - darkest < 10
    }

    /// 썸네일·영상 길이 캐시를 비운다 (설정 → 캐시)
    func clear() {
        memory = [:]
        durations = [:]
        try? FileManager.default.removeItem(at: directory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    /// 특정 위치(0~1)의 장면. 캐시하지 않는다 (영상 정보 화면의 마지막 재생 위치 표시용).
    func snapshot(of file: VideoFile, at position: Float) async -> UIImage? {
        let result = await enqueue { await ThumbnailRequest().run(url: file.url, serverID: file.serverID, position: position) }
        return result.image.map(UIImage.init(cgImage:))
    }

    private func enqueue<T>(_ operation: @escaping () async -> T) async -> T {
        let previous = tail
        let task = Task {
            await previous?.value
            return await operation()
        }
        tail = Task { _ = await task.value }
        return await task.value
    }

    private func cacheKey(_ file: VideoFile) -> String {
        let source = "\(file.url.absoluteString)|\(file.size)|\(file.modifiedAt.timeIntervalSince1970)"
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in source.utf8 {
            hash = (hash ^ UInt64(byte)) &* 0x100000001b3
        }
        return String(hash, radix: 16)
    }
}

/// VLCMediaThumbnailer 한 번 실행
private final class ThumbnailRequest: NSObject {
    private var thumbnailer: VLCMediaThumbnailer?
    private var continuation: CheckedContinuation<(image: CGImage?, duration: Double), Never>?

    func run(url: URL, serverID: UUID?, position: Float) async -> (image: CGImage?, duration: Double) {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            let thumbnailer = VLCMediaThumbnailer(media: RemoteAccess.media(for: url, serverID: serverID), andDelegate: self)
            thumbnailer.thumbnailWidth = 480
            thumbnailer.thumbnailHeight = 270
            thumbnailer.snapshotPosition = position
            self.thumbnailer = thumbnailer
            thumbnailer.fetchThumbnail()
            // VLC 가 응답 없이 멈추면 뒤의 썸네일이 모두 막히므로 제한 시간을 둔다 (네트워크 파일 고려)
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(20))
                self?.finish(nil)
            }
        }
    }

    private func finish(_ image: CGImage?) {
        guard continuation != nil else { return }
        let milliseconds = thumbnailer?.media.length.intValue ?? 0
        continuation?.resume(returning: (image, Double(milliseconds) / 1000))
        continuation = nil
        thumbnailer = nil
    }
}

extension ThumbnailRequest: VLCMediaThumbnailerDelegate {
    func mediaThumbnailerDidTimeOut(_ mediaThumbnailer: VLCMediaThumbnailer) {
        finish(nil)
    }

    func mediaThumbnailer(_ mediaThumbnailer: VLCMediaThumbnailer, didFinishThumbnail thumbnail: CGImage) {
        finish(thumbnail)
    }
}

/// 재생을 닫을 때 찍어 둔 마지막 장면 (영상 정보 화면 맨 위 그림).
/// 찍을 때의 위치를 같이 기억해, 이어보기 위치가 그대로일 때만 쓴다.
@Observable
final class ResumeFrames {
    static let shared = ResumeFrames()

    /// 지금 찍고 있는 파일 (끝나면 정보 화면이 다시 읽는다)
    private(set) var pending: Set<String> = []

    @ObservationIgnored private let directory = AppPaths.caches.appending(path: "ResumeFrames", directoryHint: .isDirectory)
    @ObservationIgnored private var positions: [String: Double]
    @ObservationIgnored private var memory: [String: UIImage] = [:]

    private var positionsURL: URL { directory.appending(path: "positions.json") }

    private init() {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        positions = (try? JSONDecoder().decode([String: Double].self, from: Data(contentsOf: directory.appending(path: "positions.json")))) ?? [:]
    }

    /// 찍기 시작 (플레이어를 닫자마자 부른다: 정보 화면이 그 사이 다른 장면을 만들지 않게). 2초 안에 끝나지 않으면 기다리지 않는다.
    func begin(_ key: String) {
        pending.insert(key)
        Task {
            try? await Task.sleep(for: .seconds(2))
            pending.remove(key)
        }
    }

    /// 찍지 않기로 했을 때
    func cancel(_ key: String) {
        pending.remove(key)
    }

    /// 찍은 그림을 저장한다 (못 찍었으면 nil — 정보 화면이 그 위치의 장면을 따로 만든다)
    func finish(_ key: String, position: Double, image: UIImage?) {
        if let image, let data = image.jpegData(compressionQuality: 0.8) {
            try? data.write(to: path(key), options: .atomic)
            memory[key] = image
            positions[key] = position
            try? JSONEncoder().encode(positions).write(to: positionsURL, options: .atomic)
        }
        pending.remove(key)
    }

    /// 비운다 (설정 → 캐시)
    func clear() {
        memory = [:]
        positions = [:]
        try? FileManager.default.removeItem(at: directory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func image(for key: String, position: Double) -> UIImage? {
        guard let saved = positions[key], abs(saved - position) < 0.5 else { return nil }
        if let image = memory[key] { return image }
        let image = UIImage(contentsOfFile: path(key).path(percentEncoded: false))
        memory[key] = image
        return image
    }

    private func path(_ key: String) -> URL {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in key.utf8 {
            hash = (hash ^ UInt64(byte)) &* 0x100000001b3
        }
        return directory.appending(path: String(hash, radix: 16) + ".jpg")
    }
}
