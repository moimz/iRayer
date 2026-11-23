import Foundation
import ImageIO
import CoreGraphics
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

/// 만화로 보는 책 하나 (압축 파일)
struct ComicBook: Identifiable {
    let id = UUID()
    let file: VideoFile
    let archive: any ComicArchive
    let password: String?
    /// 같은 폴더의 압축 파일들 ("다음 권")
    var siblings: [VideoFile] = []
    /// 그림 파일 (경로를 사람이 읽는 순서로: 2 < 10)
    let pages: [ZipEntry]

    init(file: VideoFile, archive: any ComicArchive, password: String?, siblings: [VideoFile]) {
        self.file = file
        self.archive = archive
        self.password = password
        self.siblings = siblings
        pages = archive.pages
    }

    var nextVolume: VideoFile? {
        guard let index = siblings.firstIndex(where: { $0.url == file.url }), siblings.indices.contains(index + 1) else { return nil }
        return siblings[index + 1]
    }
}

/// 책마다 기억하는 보기 설정
struct ComicSettings: Codable, Equatable {
    /// 오른쪽에서 왼쪽으로 넘긴다 (일본 만화)
    var rightToLeft = true
    /// 펼친 두 쪽짜리 그림을 반으로 잘라 한 쪽씩 본다
    var split = false
    /// 반 자를 때 먼저 볼 쪽을 넘기는 방향과 반대로 (스캔이 특이한 책)
    var swapHalves = false
}

/// 보기 설정 저장: 책마다 기억한다 (iCloud 로 다른 기기에도). 같은 폴더라도 권마다 스캔이 달라 폴더 기본값은 두지 않는다.
final class ComicSettingsStore {
    static let shared = ComicSettingsStore()

    fileprivate var files: [String: ComicSettings] = [:]
    fileprivate let defaults = UserDefaults.standard

    private init() {
        if let data = defaults.data(forKey: "comicSettings.files"), let decoded = try? JSONDecoder().decode([String: ComicSettings].self, from: data) {
            files = decoded
        }
        // 예전 폴더 기본값은 쓰지 않는다
        defaults.removeObject(forKey: "comicSettings.folders")
    }

    /// 그 책에 직접 정한 설정 (폴더에서 물려받은 것 빼고). 표지를 자를지 정할 때 쓴다.
    func fileSettings(for file: VideoFile) -> ComicSettings? {
        files[file.stateKey]
    }

    func settings(for file: VideoFile) -> ComicSettings {
        files[file.stateKey] ?? ComicSettings()
    }

    func save(_ settings: ComicSettings, for file: VideoFile) {
        files[file.stateKey] = settings
        defaults.set(try? JSONEncoder().encode(files), forKey: "comicSettings.files")
        SyncEngine.shared.changed(Self.fileKind, key: file.stateKey)
    }
}

extension ComicSettingsStore {
    static let fileKind = "comicFile"

    /// 책마다 정한 읽는 방향·반 자르기 등
    var syncKinds: [SyncEngine.Kind] {
        [
            SyncEngine.Kind(name: Self.fileKind) { [unowned self] in
                Array(files.keys)
            } payload: { [unowned self] key in
                files[key].flatMap { try? syncEncoder.encode($0) }
            } apply: { [unowned self] key, data in
                // 바뀜 (2026-11-09): 못 읽으면 지우지 않고 false (SyncEngine 이 나중에 다시 받는다)
                guard let value = try? JSONDecoder().decode(ComicSettings.self, from: data) else { return false }
                files[key] = value
                defaults.set(try? JSONEncoder().encode(files), forKey: "comicSettings.files")
                return true
            } delete: { [unowned self] key in
                files[key] = nil
                defaults.set(try? JSONEncoder().encode(files), forKey: "comicSettings.files")
            },
        ]
    }
}

/// 화면 한 장에 보이는 것: 그림 한 장, 반쪽, 또는 펼친 두 장
struct ComicUnit: Hashable {
    enum Half: Hashable {
        /// 읽는 순서로 앞쪽 반
        case first
        case second
    }

    var pages: [Int]
    var half: Half?

    /// 그림 크기를 아는 만큼으로 화면 순서를 만든다 (모르는 그림은 한 쪽짜리로 본다)
    static func layout(count: Int, isWide: (Int) -> Bool?, split: Bool, spread: Bool) -> [ComicUnit] {
        var units: [ComicUnit] = []
        if spread {
            // 가로 화면: 표지는 혼자, 그다음부터 두 장씩. 펼친 그림(가로로 긴 그림)은 혼자.
            var index = 0
            while index < count {
                if index == 0 || index == count - 1 || isWide(index) == true || isWide(index + 1) == true {
                    units.append(ComicUnit(pages: [index]))
                    index += 1
                } else {
                    units.append(ComicUnit(pages: [index, index + 1]))
                    index += 2
                }
            }
        } else {
            for index in 0..<count {
                if split, isWide(index) == true {
                    units.append(ComicUnit(pages: [index], half: .first))
                    units.append(ComicUnit(pages: [index], half: .second))
                } else {
                    units.append(ComicUnit(pages: [index]))
                }
            }
        }
        return units
    }
}

/// 읽어서 화면 크기에 맞게 줄인 그림들 (지금 쪽 근처만 기억한다)
actor ComicPageCache {
    private let archive: any ComicArchive
    private let pages: [ZipEntry]
    private let password: String?
    private let maxPixel: Int

    private var images: [Int: CGImage] = [:]
    private var loading: [Int: Task<CGImage, Error>] = [:]

    init(book: ComicBook, maxPixel: Int) {
        archive = book.archive
        pages = book.pages
        password = book.password
        self.maxPixel = maxPixel
    }

    func image(_ index: Int) async throws -> CGImage {
        if let image = images[index] { return image }
        if let task = loading[index] { return try await task.value }
        let entry = pages[index]
        let task = Task { [archive, password, maxPixel] in
            let data = try await archive.data(of: entry, password: password)
            return try await Self.decode(data, maxPixel: maxPixel)
        }
        loading[index] = task
        defer { loading[index] = nil }
        let image = try await task.value
        images[index] = image
        return image
    }

    /// 쪽 모아보기용 작은 그림 (따로 기억한다. 보이는 칸만 그때그때 읽는다)
    private var thumbnails: [Int: CGImage] = [:]

    func thumbnail(_ index: Int) async throws -> CGImage {
        if let thumbnail = thumbnails[index] { return thumbnail }
        let entry = pages[index]
        let data = try await archive.data(of: entry, password: password)
        let thumbnail = try await Self.decode(data, maxPixel: 360)
        thumbnails[index] = thumbnail
        return thumbnail
    }

    /// 이미 읽은 그림이면 가로로 긴지 (모르면 nil)
    func isWide(_ index: Int) -> Bool? {
        images[index].map { $0.width > $0.height }
    }

    func knownWide() -> [Int: Bool] {
        images.mapValues { $0.width > $0.height }
    }

    /// 지금 쪽에서 먼 그림은 버린다
    func keep(_ range: ClosedRange<Int>) {
        for index in images.keys where !range.contains(index) { images[index] = nil }
    }

    @concurrent
    private static func decode(_ data: Data, maxPixel: Int) async throws -> CGImage {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: maxPixel,
                  kCGImageSourceShouldCacheImmediately: true,
              ] as CFDictionary) else { throw ZipError.corrupted }
        return image
    }

    /// 화면 한 장에 보일 그림 (반쪽은 잘라서, 두 장은 나란히 붙여서)
    func render(_ unit: ComicUnit, rightToLeft: Bool, swapHalves: Bool) async throws -> CGImage {
        if unit.pages.count == 2 {
            let first = try await image(unit.pages[0])
            let second = try await image(unit.pages[1])
            return try await Self.join(rightToLeft ? [second, first] : [first, second])
        }
        let image = try await image(unit.pages[0])
        guard let half = unit.half else { return image }
        // 오른쪽에서 왼쪽으로 읽으면 앞쪽 반이 오른쪽
        let rightFirst = rightToLeft != swapHalves
        let takeRight = (half == .first) == rightFirst
        let width = image.width / 2
        let rect = CGRect(x: takeRight ? image.width - width : 0, y: 0, width: width, height: image.height)
        return image.cropping(to: rect) ?? image
    }

    @concurrent
    private static func join(_ images: [CGImage]) async throws -> CGImage {
        let height = images.map(\.height).max() ?? 1
        let widths = images.map { Int(Double($0.width) * Double(height) / Double($0.height)) }
        let size = CGSize(width: widths.reduce(0, +), height: height)
        // 아이폰·맥 공통으로 CGContext 에 그린다 (CG 좌표는 아래가 0 이지만 높이를 맞춰 나란히 놓으므로 상관없다)
        guard let context = CGContext(data: nil, width: Int(size.width), height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
            throw ZipError.corrupted
        }
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.fill(CGRect(origin: .zero, size: size))
        context.interpolationQuality = .high
        var x = 0
        for (image, width) in zip(images, widths) {
            context.draw(image, in: CGRect(x: x, y: 0, width: width, height: height))
            x += width
        }
        guard let cgImage = context.makeImage() else { throw ZipError.corrupted }
        return cgImage
    }
}
