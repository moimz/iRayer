import Foundation

/// 외부 자막 파일 찾기와 인코딩 변환
enum SubtitleLoader {
    static let extensions: Set<String> = ["srt", "smi", "sami", "ass", "ssa", "vtt", "sub"]

    /// 같은 폴더의 파일들 중에서 영상과 같은 이름으로 시작하는 자막 파일을 찾는다 (예: 영화.srt, 영화.ko.smi).
    /// 한국어로 보이는 자막을 앞에 둔다. 로컬·네트워크 모두 폴더 목록을 받아 처리한다.
    static func sidecars(for video: URL, in siblings: [URL]) -> [URL] {
        let base = normalizedName(video)
        return siblings
            .filter { url in
                guard extensions.contains(url.pathExtension.lowercased()) else { return false }
                let name = normalizedName(url)
                return name == base || name.hasPrefix(base + ".")
            }
            .sorted { lhs, rhs in
                let lhsKorean = isKorean(lhs), rhsKorean = isKorean(rhs)
                if lhsKorean != rhsKorean { return lhsKorean }
                return lhs.lastPathComponent.localizedStandardCompare(rhs.lastPathComponent) == .orderedAscending
            }
    }

    /// 자막을 UTF-8 로 변환한 로컬 복사본을 만든다. VLC 가 CP949(EUC-KR) SMI 를 깨뜨리지 않도록.
    static func prepare(_ url: URL, serverID: UUID?) async -> URL? {
        guard let data = try? await RemoteAccess.data(of: url, serverID: serverID), let text = decode(data) else { return nil }
        let directory = AppPaths.caches.appending(path: "Subtitles/\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let output = directory.appending(path: url.subtitleName)
        do {
            try Data(text.utf8).write(to: output, options: .atomic)
            return output
        } catch {
            return nil
        }
    }

    static func decode(_ data: Data) -> String? {
        if data.starts(with: [0xEF, 0xBB, 0xBF]) {
            return String(data: data.dropFirst(3), encoding: .utf8)
        }
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]) {
            return String(data: data, encoding: .utf16)
        }
        if let text = String(data: data, encoding: .utf8) {
            return text
        }
        for encoding in [CFStringEncodings.dosKorean, .EUC_KR] {
            let nsEncoding = CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(encoding.rawValue))
            if let text = String(data: data, encoding: String.Encoding(rawValue: nsEncoding)) {
                return text
            }
        }
        return String(decoding: data, as: UTF8.self)
    }

    /// 확장자를 뺀 이름 (NFC, 소문자). 서버에 따라 한글 파일명이 NFD 로 오기도 해서 맞춰 비교한다.
    private static func normalizedName(_ url: URL) -> String {
        url.deletingPathExtension().lastPathComponent.precomposedStringWithCanonicalMapping.lowercased()
    }

    private static func isKorean(_ url: URL) -> Bool {
        let name = normalizedName(url)
        return name.hasSuffix(".ko") || name.hasSuffix(".kor") || name.hasSuffix(".korean") || name.hasSuffix(".한글")
    }
}

extension URL {
    /// 자막 파일 이름. 주소에 확장자가 없으면 fragment 에 담긴 이름을 쓴다.
    var subtitleName: String { fragment(percentEncoded: false) ?? lastPathComponent }
    var subtitleExtension: String { (subtitleName as NSString).pathExtension }
}
