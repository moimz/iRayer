import Foundation
import os

/// WebDAV 폴더 목록 조회 (PROPFIND Depth: 1)
enum WebDAVClient {
    struct Entry {
        let url: URL
        let name: String
        let isDirectory: Bool
        let size: Int64
        let modifiedAt: Date
    }

    static func list(_ directory: URL, serverID: UUID?) async throws -> [Entry] {
        var request = RemoteAccess.request(directory, serverID: serverID, method: "PROPFIND")
        request.setValue("1", forHTTPHeaderField: "Depth")
        request.setValue("application/xml; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data("""
            <?xml version="1.0" encoding="utf-8"?>
            <D:propfind xmlns:D="DAV:"><D:prop>
            <D:resourcetype/><D:getcontentlength/><D:getlastmodified/><D:displayname/>
            </D:prop></D:propfind>
            """.utf8)

        // 걸린 시간을 기록한다 (콘솔 앱: 하위 시스템 com.moimz.iRayer, 분류 WebDAV) — 줄 서기·연결·서버 응답을 나눠서
        let (data, response) = try await URLSession.shared.data(for: request, delegate: ListTimer(path: directory.path(percentEncoded: false)))
        try RemoteAccess.check(response)

        let parser = MultistatusParser()
        let xml = XMLParser(data: data)
        xml.shouldProcessNamespaces = true
        xml.delegate = parser
        xml.parse()

        let selfPath = normalizedPath(directory)
        return parser.responses.compactMap { response in
            guard let url = URL(string: response.href, relativeTo: directory)?.absoluteURL,
                  normalizedPath(url) != selfPath else { return nil }
            let name = url.lastPathComponent.removingPercentEncoding ?? url.lastPathComponent
            return Entry(
                url: url,
                name: name,
                isDirectory: response.isCollection,
                size: response.size,
                modifiedAt: response.modifiedAt ?? .distantPast
            )
        }
    }

    // MARK: - 읽기·쓰기 (파일 관리·압축 풀기·만화 보기)

    /// 파일의 일부 읽기 (Range 요청)
    static func read(_ url: URL, range: Range<Int64>, serverID: UUID?) async throws -> Data {
        var request = RemoteAccess.request(url, serverID: serverID)
        request.setValue("bytes=\(range.lowerBound)-\(range.upperBound - 1)", forHTTPHeaderField: "Range")
        let (data, response) = try await URLSession.shared.data(for: request)
        try RemoteAccess.check(response)
        // Range 를 무시하고 전체를 보내는 서버면 필요한 부분만 잘라 쓴다
        if (response as? HTTPURLResponse)?.statusCode == 200, data.count > range.count {
            let start = Int(range.lowerBound)
            return data.subdata(in: start..<min(start + range.count, data.count))
        }
        return data
    }

    /// 있으면 그 정보 (폴더인지, 크기), 없으면 nil
    static func item(at url: URL, serverID: UUID?) async throws -> (isDirectory: Bool, size: Int64)? {
        var request = RemoteAccess.request(url, serverID: serverID, method: "PROPFIND")
        request.setValue("0", forHTTPHeaderField: "Depth")
        let (data, response) = try await URLSession.shared.data(for: request)
        if (response as? HTTPURLResponse)?.statusCode == 404 { return nil }
        try RemoteAccess.check(response)
        let parser = MultistatusParser()
        let xml = XMLParser(data: data)
        xml.shouldProcessNamespaces = true
        xml.delegate = parser
        xml.parse()
        guard let first = parser.responses.first else { return nil }
        return (first.isCollection, first.size)
    }

    static func createDirectory(_ url: URL, serverID: UUID?) async throws {
        let (_, response) = try await URLSession.shared.data(for: RemoteAccess.request(directoryURL(url), serverID: serverID, method: "MKCOL"))
        try RemoteAccess.check(response)
    }

    /// 파일 또는 폴더(안의 내용까지) 삭제
    static func remove(_ url: URL, serverID: UUID?) async throws {
        let (_, response) = try await URLSession.shared.data(for: RemoteAccess.request(url, serverID: serverID, method: "DELETE"))
        try RemoteAccess.check(response)
    }

    /// 같은 서버 안에서 옮기기(MOVE)·복사(COPY). 서버가 직접 처리한다.
    static func transfer(_ url: URL, to destination: URL, isDirectory: Bool, copy: Bool, overwrite: Bool, serverID: UUID?) async throws {
        let source = isDirectory ? directoryURL(url) : url
        let target = isDirectory ? directoryURL(destination) : destination
        var request = RemoteAccess.request(source, serverID: serverID, method: copy ? "COPY" : "MOVE")
        request.setValue(target.absoluteString, forHTTPHeaderField: "Destination")
        request.setValue(overwrite ? "T" : "F", forHTTPHeaderField: "Overwrite")
        if isDirectory { request.setValue("infinity", forHTTPHeaderField: "Depth") }
        let (_, response) = try await URLSession.shared.data(for: request)
        try RemoteAccess.check(response)
    }

    /// 같은 서버인지 (서버가 직접 옮기거나 복사할 수 있는지)
    static func sameServer(_ lhs: URL, _ rhs: URL) -> Bool {
        lhs.scheme == rhs.scheme && lhs.host() == rhs.host() && lhs.port == rhs.port
    }

    /// 폴더 주소는 / 로 끝나야 하는 서버가 있다
    static func directoryURL(_ url: URL) -> URL {
        url.absoluteString.hasSuffix("/") ? url : URL(string: url.absoluteString + "/") ?? url
    }

    private static func normalizedPath(_ url: URL) -> String {
        var path = url.path(percentEncoded: false)
        while path.hasSuffix("/") { path.removeLast() }
        return path
    }
}

/// PROPFIND 응답(multistatus) 파서. 서버마다 네임스페이스 접두어가 달라서 로컬 이름으로만 비교한다.
private final class MultistatusParser: NSObject, XMLParserDelegate {
    struct Response {
        var href = ""
        var isCollection = false
        var size: Int64 = 0
        var modifiedAt: Date?
    }

    private(set) var responses: [Response] = []
    private var current: Response?
    private var text = ""

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter
    }()

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName: String?, attributes: [String: String] = [:]) {
        text = ""
        switch elementName.lowercased() {
        case "response": current = Response()
        case "collection": current?.isCollection = true
        default: break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        text += string
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName: String?) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch elementName.lowercased() {
        case "href": current?.href = value
        case "getcontentlength": current?.size = Int64(value) ?? 0
        case "getlastmodified": current?.modifiedAt = Self.dateFormatter.date(from: value)
        case "response":
            if let current { responses.append(current) }
            current = nil
        default: break
        }
        text = ""
    }
}

/// 폴더 목록 요청이 어디서 시간을 쓰는지 기록: 기다림(연결 묶음이 비기를), 연결, 서버가 첫 바이트를 줄 때까지, 받기
private final class ListTimer: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private static let log = Logger(subsystem: "com.moimz.iRayer", category: "WebDAV")
    let path: String

    init(path: String) {
        self.path = path
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
        let total = metrics.taskInterval.duration
        for transaction in metrics.transactionMetrics {
            guard let fetch = transaction.fetchStartDate, let end = transaction.responseEndDate else { continue }
            let wait = (transaction.connectStartDate ?? transaction.requestStartDate).map { $0.timeIntervalSince(fetch) } ?? 0
            let connect = transaction.connectEndDate.flatMap { end in transaction.connectStartDate.map { end.timeIntervalSince($0) } } ?? 0
            let server = transaction.responseStartDate.flatMap { start in transaction.requestEndDate.map { start.timeIntervalSince($0) } } ?? 0
            let receive = transaction.responseStartDate.map { end.timeIntervalSince($0) } ?? 0
            let status = (transaction.response as? HTTPURLResponse)?.statusCode ?? 0
            Self.log.info("목록 \(self.path, privacy: .public) \(status) 전체 \(total, format: .fixed(precision: 2))s 기다림 \(wait, format: .fixed(precision: 2))s 연결 \(connect, format: .fixed(precision: 2))s 서버 \(server, format: .fixed(precision: 2))s 받기 \(receive, format: .fixed(precision: 2))s 재사용 \(transaction.isReusedConnection)")
        }
    }
}
