#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif
import ImageIO
import CryptoKit

/// 압축 파일 카드에 보일 것: 표지 그림과 안을 보고 내린 판단
struct CoverInfo {
    var image: UIImage?
    /// nil: 안을 볼 수 없었음 (받지 않은 RAR 등)
    var kind: ArchiveKind?
}

/// 만화책(압축 파일) 표지와 포스터형 폴더 표지.
/// 압축 파일은 끝의 목록과 표지 그림만 읽고, 줄인 그림과 판단(만화책인지, 암호인지)을 Caches 에 저장해 둔다.
/// 표지 그림: 이름에 cover 가 든 그림, 없으면 첫 쪽. 가로로 길면 반으로 잘라 왼쪽
/// (그 책에 반 자르기·읽는 방향을 직접 정했으면 그에 따라: 자르기 켬이면 보기 화면에서 처음 나오는 반쪽, 끔이면 자르지 않는다).
actor CoverService {
    static let shared = CoverService()

    private let directory = AppPaths.caches.appending(path: "Covers2", directoryHint: .isDirectory)
    private var memory: [String: UIImage] = [:]
    private var kinds: [String: ArchiveKind] = [:]
    private var running: [String: Task<CoverInfo, Never>] = [:]
    /// 폴더 → 표지를 빌려올 책 (없으면 nil 로 기억)
    private var folderBooks: [String: VideoFile?] = [:]
    /// 폴더 → 썸네일을 빌려올 영상 (썸네일형 폴더 카드, 없으면 nil 로 기억)
    private var folderVideos: [String: VideoFile?] = [:]
    /// NAS 에 한꺼번에 몰리지 않게 동시에 3개까지
    private var slots = 3
    private var waiting: [CheckedContinuation<Void, Never>] = []

    private var kindsURL: URL { directory.appending(path: "kinds.json") }

    private init() {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // 예전 규칙으로 만든 표지는 버린다
        try? FileManager.default.removeItem(at: AppPaths.caches.appending(path: "Covers"))
        if let data = try? Data(contentsOf: directory.appending(path: "kinds.json")),
           let decoded = try? JSONDecoder().decode([String: ArchiveKind].self, from: data) {
            kinds = decoded
        }
    }

    // MARK: - 압축 파일 표지

    /// 이미 알고 있는 것 (모르면 nil — 화면이 먼저 그릴 수 있게 바로 돌려준다)
    func cached(_ file: VideoFile) -> CoverInfo? {
        let key = file.stateKey
        let image = memory[key] ?? UIImage(contentsOfFile: path(key).path(percentEncoded: false))
        if let image { memory[key] = image }
        guard image != nil || kinds[key] != nil else { return nil }
        return CoverInfo(image: image, kind: kinds[key])
    }

    func cover(for file: VideoFile) async -> CoverInfo {
        let key = file.stateKey
        if let info = cached(file) { return info }
        if let task = running[key] { return await task.value }
        let task = Task<CoverInfo, Never> {
            await acquire()
            defer { release() }
            return await makeCover(file)
        }
        running[key] = task
        let info = await task.value
        running[key] = nil
        return info
    }

    private func makeCover(_ file: VideoFile) async -> CoverInfo {
        // 큰 RAR 을 표지 하나 때문에 받지는 않는다 (한 번 열어 받아 두면 그때 만든다)
        if ComicArchives.isRar(file.url), !RarCache.isLocal(file) { return CoverInfo(image: nil, kind: nil) }
        guard let archive = try? await ComicArchives.open(file) else {
            remember(.unreadable, for: file)
            return CoverInfo(image: nil, kind: .unreadable)
        }
        let kind = archive.kind
        remember(kind, for: file)
        guard kind == .comic, let entry = archive.coverEntry, let data = try? await archive.data(of: entry, password: nil) else {
            return CoverInfo(image: nil, kind: kind)
        }
        return CoverInfo(image: await save(data, for: file), kind: kind)
    }

    /// 보기 화면에서 다시 만든다: 암호가 걸려 목록에서 만들지 못한 책, 또는 읽는 방향·반 자르기를 바꾼 책
    func rebuild(_ file: VideoFile, archive: any ComicArchive, password: String?, onlyIfMissing: Bool) async {
        if onlyIfMissing, cached(file)?.image != nil { return }
        guard let entry = archive.coverEntry, let data = try? await archive.data(of: entry, password: password) else { return }
        if kinds[file.stateKey] == nil { remember(archive.kind, for: file) }
        _ = await save(data, for: file)
    }

    private func remember(_ kind: ArchiveKind, for file: VideoFile) {
        kinds[file.stateKey] = kind
        try? JSONEncoder().encode(kinds).write(to: kindsURL)
    }

    /// 줄이고 (가로로 길면 반으로 잘라) 파일로 저장
    private func save(_ data: Data, for file: VideoFile) async -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              var image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: 900,
              ] as CFDictionary) else { return nil }
        if image.width > image.height {
            let settings = await MainActor.run { ComicSettingsStore.shared.fileSettings(for: file) }
            // 그 책에 정한 것이 없으면 왼쪽 (앞표지가 왼쪽인 왼쪽으로 읽기 책의 겉표지 스캔)
            var takeRight: Bool? = false
            if let settings {
                // 보기 화면에서 처음 나오는 반쪽: 왼쪽으로 읽으면 오른쪽 반이 먼저
                takeRight = settings.split ? (settings.rightToLeft != settings.swapHalves) : nil
            }
            if let takeRight {
                let width = image.width / 2
                image = image.cropping(to: CGRect(x: takeRight ? image.width - width : 0, y: 0, width: width, height: image.height)) ?? image
            }
        }
        let cover = UIImage(cgImage: image)
        try? cover.jpegData(compressionQuality: 0.8)?.write(to: path(file.stateKey))
        memory[file.stateKey] = cover
        return cover
    }

    private func path(_ key: String) -> URL {
        let hash = SHA256.hash(data: Data(key.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
        return directory.appending(path: hash + ".jpg")
    }

    // MARK: - 폴더 표지

    /// 폴더 바로 안의 cover.jpg 같은 그림, 없으면 바로 안의 첫 만화책 표지 (하위 폴더까지는 찾지 않는다)
    func cover(forFolder folder: FolderRoute) async -> UIImage? {
        let key = "folder|" + FolderOptionsStore.key(folder.url, serverID: folder.serverID)
        if let image = memory[key] { return image }
        if let book = folderBooks[key] {
            guard let book else { return nil }
            return await cover(for: book).image
        }

        await acquire()
        let items = try? await DirectoryLister.items(in: folder.url, serverID: folder.serverID)
        release()
        guard let items else { return nil }
        let files = items.filter { !$0.isDirectory && !$0.url.lastPathComponent.hasPrefix(".") }
        if let cover = await namedCover(in: files, folder: folder, key: key) { return cover }
        // 앞에서부터 몇 권만 본다: 그림이 든(만화책) 첫 권의 표지
        let archives = files.filter { VideoFile.isArchive($0.url) }
            .sorted { $0.url.lastPathComponent.localizedStandardCompare($1.url.lastPathComponent) == .orderedAscending }
            .prefix(5)
        for item in archives {
            let file = VideoFile(url: item.url, size: item.size, modifiedAt: item.modifiedAt, serverID: folder.serverID)
            let info = await cover(for: file)
            if let image = info.image {
                folderBooks[key] = file
                return image
            }
        }
        folderBooks[key] = .some(nil)
        return nil
    }

    /// 표지 캐시를 모두 비운다 (설정 → 캐시)
    func clear() {
        memory = [:]
        kinds = [:]
        folderBooks = [:]
        folderVideos = [:]
        try? FileManager.default.removeItem(at: directory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    /// 폴더 표지를 다시 찾게 한다 (새로고침, 파일 작업 뒤: 표지로 쓰던 책이 지워졌거나 더 이상 첫 권이 아닐 수 있다)
    func forgetFolders(_ folders: [FolderRoute]) {
        for folder in folders {
            let key = "folder|" + FolderOptionsStore.key(folder.url, serverID: folder.serverID)
            memory[key] = nil
            folderBooks[key] = nil
            folderVideos[key] = nil
        }
    }

    /// 폴더 바로 안의 cover.jpg 같은 그림 (포스터형 표지와 썸네일형 폴더 그림이 같이 쓴다)
    private func namedCover(in files: [DirectoryLister.Item], folder: FolderRoute, key: String) async -> UIImage? {
        let names = ["cover", "folder", "poster", "표지"]
        guard let image = files.first(where: { names.contains($0.url.deletingPathExtension().lastPathComponent.lowercased())
            && ZipEntry.imageExtensions.contains($0.url.pathExtension.lowercased()) }) else { return nil }
        await acquire()
        let data = try? await FileOperations.read(image.url, range: 0..<image.size, serverID: folder.serverID)
        release()
        guard let data, let source = CGImageSourceCreateWithData(data as CFData, nil),
              let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: 900,
              ] as CFDictionary) else { return nil }
        let cover = UIImage(cgImage: thumbnail)
        memory[key] = cover
        return cover
    }

    // MARK: - 썸네일형 폴더 그림

    /// 썸네일형 폴더 카드에 보일 것
    enum FolderPreview {
        case image(UIImage)
        /// 이 영상의 썸네일 (화면이 ThumbnailService 로 만든다: 영상 카드와 캐시를 같이 쓴다)
        case video(VideoFile)
    }

    /// 폴더 바로 안의 cover.jpg 같은 그림, 없으면 이름순 첫 영상 (하위 폴더까지는 찾지 않는다)
    func preview(forFolder folder: FolderRoute) async -> FolderPreview? {
        let key = "folder|" + FolderOptionsStore.key(folder.url, serverID: folder.serverID)
        if let image = memory[key] { return .image(image) }
        if let video = folderVideos[key] { return video.map { .video($0) } }

        await acquire()
        let items = try? await DirectoryLister.items(in: folder.url, serverID: folder.serverID)
        release()
        guard let items else { return nil }
        let files = items.filter { !$0.isDirectory && !$0.url.lastPathComponent.hasPrefix(".") }
        if let cover = await namedCover(in: files, folder: folder, key: key) { return .image(cover) }
        let video = files.filter { VideoFile.isVideo($0.url) }
            .min { $0.url.lastPathComponent.localizedStandardCompare($1.url.lastPathComponent) == .orderedAscending }
            .map { VideoFile(url: $0.url, size: $0.size, modifiedAt: $0.modifiedAt, serverID: folder.serverID) }
        folderVideos[key] = .some(video)
        return video.map { .video($0) }
    }

    // MARK: - 동시에 도는 수

    private func acquire() async {
        if slots > 0 {
            slots -= 1
            return
        }
        await withCheckedContinuation { waiting.append($0) }
    }

    private func release() {
        if waiting.isEmpty {
            slots += 1
        } else {
            waiting.removeFirst().resume()
        }
    }
}
