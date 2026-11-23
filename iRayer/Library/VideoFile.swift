import Foundation

/// 탐색 위치 안의 영상 파일
struct VideoFile: Identifiable, Hashable, Codable {
    /// 재생할 주소 (file://, http(s):// WebDAV, smb://)
    let url: URL
    let size: Int64
    let modifiedAt: Date
    /// 같은 폴더에 있는 같은 이름의 자막 파일들
    var subtitles: [URL] = []
    /// 네트워크 서버 안의 파일이면 그 서버 (접속 정보를 찾는 데 쓴다)
    var serverID: UUID?
    /// 화면에 보여줄 제목 (라이브러리 메타데이터 제목). 없으면 파일명.
    var displayTitle: String?
    /// 라이브러리에 든 파일이면 그 해시 (OpenSubtitles). 이름을 바꾸거나 옮겨도 같은 값이라 이어보기 키로 쓴다.
    var hash: String?

    var id: URL { url }
    var name: String { url.lastPathComponent }
    var title: String { displayTitle ?? (name as NSString).deletingPathExtension }

    /// 영상별 상태를 기억할 때 쓰는 키. 기기마다 경로가 달라도 같은 영상으로 보도록 파일명 + 크기를 쓴다.
    /// 파일 시스템이나 서버에 따라 한글 파일명이 NFD(자모 분리)로 올 수 있어 NFC 로 통일한다.
    /// 2.0: 해시를 아는 파일(라이브러리)은 "#해시|크기" — 이름을 바꾸거나 옮겨도 이어보기가 이어진다.
    var stateKey: String {
        if let hash { return "#\(hash)|\(size)" }
        return "\(name.precomposedStringWithCanonicalMapping)|\(size)"
    }

    static let extensions: Set<String> = [
        "mp4", "m4v", "mov", "mkv", "avi", "wmv", "asf", "flv", "webm", "ts", "m2ts", "mts",
        "mpg", "mpeg", "vob", "3gp", "rm", "rmvb", "divx", "ogv",
    ]

    /// WMV·ASF (Windows Media)
    var isWindowsMedia: Bool {
        ["wmv", "asf"].contains((name as NSString).pathExtension.lowercased())
    }

    /// MP4·MOV 계열 (VLC 의 mp4 해석기가 여는 것)
    var isMP4Family: Bool {
        ["mp4", "m4v", "mov", "3gp"].contains((name as NSString).pathExtension.lowercased())
    }

    static func isVideo(_ url: URL) -> Bool {
        extensions.contains(url.pathExtension.lowercased())
    }

    /// 압축 파일 (만화책으로 보거나 풀 수 있다)
    static let archiveExtensions: Set<String> = ["zip", "cbz", "rar", "cbr"]

    static func isArchive(_ url: URL) -> Bool {
        archiveExtensions.contains(url.pathExtension.lowercased())
    }

    var isArchive: Bool { Self.isArchive(url) }
}

extension Int64 {
    /// 파일 크기 표시 (예: 1.4 GB)
    var fileSizeText: String {
        ByteCountFormatter.string(fromByteCount: self, countStyle: .file)
    }
}

extension Double {
    /// 재생 시간 표시 (예: 1:05:20, 3:07)
    var durationText: String {
        guard isFinite, self >= 0 else { return "--:--" }
        let total = Int(self)
        let hours = total / 3600
        let minutes = total % 3600 / 60
        let seconds = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, seconds)
            : String(format: "%d:%02d", minutes, seconds)
    }
}
