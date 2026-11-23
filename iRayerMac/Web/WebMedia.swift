import Foundation

/// 웹 페이지에서 감지한 영상 하나 (감지 패널의 한 줄)
struct WebMedia: Identifiable, Equatable {
    enum Kind: String {
        /// 파일 자체 (MP4 등을 그대로 준다)
        case file = "FILE"
        case hls = "HLS"
        case dash = "DASH"
        /// 바뀜 (2026-11-12, 사용자): 받을 주소는 못 찾았지만 페이지가 재생 버퍼(MSE)로 재생 중 — 재생하며 받기로만
        case mse = "MSE"
    }

    /// 받기 단추를 켤 수 있는지
    var isDownloadable: Bool { (kind == .file || kind == .hls) && unsupported == nil }

    /// 같은 영상인지 가리는 키 (부분 요청 값을 뗀 주소)
    let id: String
    /// 이어받기용 느슨한 키: 쿼리를 다 뗀 주소 (2026-11-09).
    /// 서명·만료 쿼리(t·n·s, sgn.token 등)가 페이지를 열 때마다 바뀌어 id 로는 같은 영상을 못 알아보므로,
    /// 이것이 같고 내용(크기·조각 수·길이)도 같으면 같은 영상으로 보고 이어 받는다
    nonisolated var resumeKey: String {
        guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return id }
        parts.query = nil
        parts.fragment = nil
        return parts.url?.absoluteString ?? id
    }
    let url: URL
    let kind: Kind
    let mimeType: String
    /// 전체 크기 (모르면 nil)
    var size: Int64?
    /// 영상을 찾은 페이지 (받을 때 Referer 가 없으면 이것을 쓴다)
    let pageURL: URL?
    let pageTitle: String?
    /// 페이지가 이 영상을 요청할 때 보낸 헤더 중 다시 보낼 것 (Referer·Origin·Authorization·X-* 등. 쿠키는 저장소에서 따로)
    let headers: [String: String]
    let foundAt: Date
    /// 목록을 해석해 알게 된 것 (HLS·DASH): 최고 화질 이름("1080p")
    var quality: String?
    /// 받을 수 없는 이유 ("라이브", "DRM") — 있으면 받기 단추를 끈다
    var unsupported: String?
    /// HLS 마스터 목록이면 딸린 화질별·소리 목록 주소 (감지 목록에서 숨긴다)
    var children: Set<String> = []
    /// 표준대로 받을 수 없는 HLS — 받기 단추가 재생하며 받기를 시작한다
    var needsCapture = false
    /// HLS·DASH 목록을 살펴보는 중 (표준인지·DRM·라이브를 아직 모른다) — 폰에서 받기 단추 대신 "확인 중" (2026-11-10, 사용자)
    var inspecting = false
    /// 내용으로 만든 지문 (WebFingerprint) — 같으면 같은 영상 (2026-11-09, 사용자). 만들기 전·못 만들면 nil
    var fingerprint: String?
    /// DASH 목록에 딸린 조각 주소가 시작하는 곳 (이것으로 시작하는 파일은 감지 목록에서 숨긴다)
    var segmentPrefixes: Set<String> = []

    /// 받기 단추가 재생하며 받기를 시작하는 영상: 비표준 HLS, DASH (DASH 는 조각을 직접 받지 않고 재생하며 받는다)
    var capturesOnly: Bool { (needsCapture || kind == .dash || kind == .mse) && unsupported == nil }

    /// 이 영상에 딸린 것인지 (HLS 화질별 목록·조각 파일, DASH 조각)
    func owns(_ key: String) -> Bool {
        children.contains(key) || segmentPrefixes.contains { key.hasPrefix($0) }
    }

    /// 받을 때 쓸 파일 이름: 주소의 파일 이름, 확장자가 없으면 페이지 제목 + 종류에 맞는 확장자.
    /// HLS·DASH 는 목록 이름(index.m3u8 등)이 뜻이 없으므로 페이지 제목 + .mp4
    var fileName: String {
        if kind != .file {
            let base = pageTitle.map(Self.safe).flatMap { $0.isEmpty ? nil : $0 }
                ?? Self.safe((url.deletingPathExtension().lastPathComponent.removingPercentEncoding ?? "video"))
            return base + ".mp4"
        }
        let last = url.lastPathComponent.removingPercentEncoding ?? url.lastPathComponent
        if !(last as NSString).pathExtension.isEmpty, last.count > 3 { return Self.safe(last) }
        let base = pageTitle.map(Self.safe).flatMap { $0.isEmpty ? nil : $0 } ?? "video"
        return base + "." + Self.fileExtension(for: mimeType)
    }

    static func fileExtension(for mime: String) -> String {
        switch mime {
        case "video/webm": "webm"
        case "video/quicktime": "mov"
        case "video/x-matroska": "mkv"
        case "audio/mpeg": "mp3"
        case "audio/mp4", "audio/aac", "audio/x-m4a": "m4a"
        default: "mp4"
        }
    }

    private static func safe(_ name: String) -> String {
        let bad = CharacterSet(charactersIn: "/\\:?%*|\"<>\n\r")
        return name.components(separatedBy: bad).joined(separator: " ").trimmingCharacters(in: .whitespaces)
    }
}

/// 응답을 보고 영상인지 가린다 (사이트별 규칙 없이 응답 종류·확장자로)
enum WebMediaClassifier {
    /// 조각 파일 (HLS·DASH 의 한 토막) — 목록에 올리지 않는다
    private static let segmentExtensions: Set<String> = ["ts", "m4s", "m4f", "cmfv", "cmfa", "aac"]
    private static let fileExtensions: Set<String> = ["mp4", "m4v", "mov", "webm", "mkv", "m4a", "mp3"]
    /// 부분 요청으로 붙는 쿼리 이름 (떼어 전체 파일 주소로)
    private static let rangeQueryNames: Set<String> = ["range", "bytestart", "byteend", "bytes"]

    /// resourceType: WebKit 의 _WKResourceLoadInfo 값 (7 = 미디어 요소가 직접 받은 것). 시험에서 본 값 기준
    static func kind(url: URL, mimeType: String, resourceType: Int) -> WebMedia.Kind? {
        let mime = mimeType.lowercased()
        let ext = url.pathExtension.lowercased()
        if mime.contains("mpegurl") || ext == "m3u8" { return .hls }
        if mime.contains("dash+xml") || ext == "mpd" { return .dash }
        if segmentExtensions.contains(ext) || mime == "video/mp2t" || mime.contains("iso.segment") { return nil }
        if mime.hasPrefix("video/") || mime.hasPrefix("audio/") || (fileExtensions.contains(ext) && mime == "application/octet-stream") {
            return .file
        }
        return nil
    }

    /// 같은 영상 키: 부분 요청 쿼리를 뗀 주소 (조각 하나하나가 따로 오르지 않게)
    /// 바뀜 (2026-11-07): 쿼리를 다시 만들면서 값의 "=" 가 "%3D" 로 바뀌어 서명 주소(CDN77 secure=…==)가 403 이었다 →
    /// 쿼리는 받은 글자 그대로 두고 부분 요청 항목만 뺀다.
    static func key(for url: URL) -> String {
        guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url.absoluteString }
        parts.fragment = nil
        if let query = parts.percentEncodedQuery {
            let kept = query.split(separator: "&", omittingEmptySubsequences: false).filter { item in
                let name = item.split(separator: "=", maxSplits: 1).first.map(String.init) ?? ""
                return !rangeQueryNames.contains((name.removingPercentEncoding ?? name).lowercased())
            }
            parts.percentEncodedQuery = kept.isEmpty ? nil : kept.joined(separator: "&")
        }
        return parts.url?.absoluteString ?? url.absoluteString
    }

    /// 다시 보낼 요청 헤더만 고른다 (쿠키·구간·압축 등은 뺀다)
    static func replayHeaders(_ headers: [String: String]) -> [String: String] {
        let drop: Set<String> = ["cookie", "range", "accept-encoding", "content-length", "host", "connection",
                                 "if-range", "if-none-match", "if-modified-since"]
        return headers.filter { !drop.contains($0.key.lowercased()) }
    }

    /// 응답에서 전체 크기: 부분 응답이면 Content-Range 의 "/전체", 아니면 Content-Length
    static func totalSize(_ response: HTTPURLResponse) -> Int64? {
        if let range = response.value(forHTTPHeaderField: "Content-Range"), let slash = range.lastIndex(of: "/"),
           let total = Int64(range[range.index(after: slash)...]) {
            return total
        }
        if response.statusCode == 200, response.expectedContentLength > 0 { return response.expectedContentLength }
        return nil
    }
}
