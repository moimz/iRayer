import Foundation

/// 만화 보기·압축 풀기에서 다루는 압축 파일 (zip / rar). 안의 파일 목록과 꺼내기.
protocol ComicArchive: AnyObject, Sendable {
    var entries: [ZipEntry] { get }
    var isEncrypted: Bool { get }
    func check(password: String) async -> Bool
    func data(of entry: ZipEntry, password: String?) async throws -> Data
    /// 파일 하나를 조금씩 풀어 넘긴다 (큰 파일을 풀 때)
    func extract(_ entry: ZipEntry, password: String?, output: (Data) async throws -> Void) async throws
}

extension ZipArchive: ComicArchive {
    func extract(_ entry: ZipEntry, password: String?, output: (Data) async throws -> Void) async throws {
        try await extract(entry, password: password, chunkSize: 1 << 20, output: output)
    }
}

/// 압축 파일 안을 보고 내린 판단 (표지 대신 보일 아이콘을 고를 때)
enum ArchiveKind: String, Codable {
    /// 그림만 있는 만화책
    case comic
    /// 그림만 있는 것 같은데 암호가 걸려 표지를 못 읽음
    case lockedComic
    /// 파일 목록까지 암호로 감춰 안을 알 수 없음 (RAR)
    case locked
    /// 그림 말고 다른 파일도 있음
    case other
    /// 읽을 수 없음 (손상 등)
    case unreadable
}

extension ComicArchive {
    /// 만화로 볼 그림들 (경로를 사람이 읽는 순서로: 2 < 10)
    var pages: [ZipEntry] {
        entries.filter { !$0.isDirectory && !$0.isJunk && $0.isImage }
            .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    /// 그림만 있으면 만화책 (설명 파일 같은 군더더기는 괜찮다)
    var kind: ArchiveKind {
        if (self as? RarArchive)?.isHeaderEncrypted == true, entries.isEmpty { return .locked }
        let files = entries.filter { !$0.isDirectory && !$0.isJunk }
        let hasImages = files.contains(where: \.isImage)
        guard hasImages, files.allSatisfy({ $0.isImage || $0.isNote }) else { return .other }
        return isEncrypted ? .lockedComic : .comic
    }

    /// 표지로 쓸 그림: 이름에 cover·표지가 든 그림, 없으면 첫 쪽
    var coverEntry: ZipEntry? {
        let pages = self.pages
        return pages.first { entry in
            let name = (entry.name as NSString).deletingPathExtension.lowercased()
            return name.contains("cover") || name.contains("표지")
        } ?? pages.first
    }
}

enum ComicArchives {
    static func isRar(_ url: URL) -> Bool {
        ["rar", "cbr"].contains(url.pathExtension.lowercased())
    }

    /// 압축 파일 열기. RAR 은 파일 전체가 이 기기에 있어야 하므로 받아 둔다 (progress: 받은 비율).
    static func open(_ file: VideoFile, progress: (@Sendable (Double) -> Void)? = nil) async throws -> any ComicArchive {
        if isRar(file.url) {
            return try await RarArchive.open(file, progress: progress)
        }
        return try await ZipArchive.open(ArchiveSource(url: file.url, serverID: file.serverID, size: file.size))
    }
}
