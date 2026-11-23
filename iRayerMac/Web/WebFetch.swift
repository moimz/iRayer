import Foundation

/// 감지한 영상을 다시 요청할 때: 페이지가 보낸 헤더(Referer·Origin·토큰 등) + 이 브라우저의 쿠키로 같은 요청을 만든다
enum WebFetch {
    /// 이 브라우저 쿠키를 넣은 연결 (요청마다 새로 — 받는 동안 바뀐 쿠키는 다음 연결부터)
    static func session(cookies: [HTTPCookie], delegate: URLSessionDelegate? = nil, queue: OperationQueue? = nil) -> URLSession {
        let config = configuration(cookies: cookies)
        // 30초 동안 아무것도 안 오면 끊긴 것으로
        config.timeoutIntervalForRequest = 30
        config.httpMaximumConnectionsPerHost = 6
        return URLSession(configuration: config, delegate: delegate, delegateQueue: queue)
    }

    /// 이 브라우저 쿠키를 넣은 임시 설정.
    /// 바뀜 (2026-11-07): HTTPCookieStorage() 로 만든 저장소는 쿠키가 들어가지 않아(빈 껍데기) 쿠키 없이 보내져 403 이 났다 →
    /// ephemeral 설정에 딸린 메모리 저장소(세션마다 따로)에 넣는다.
    static func configuration(cookies: [HTTPCookie]) -> URLSessionConfiguration {
        let config = URLSessionConfiguration.ephemeral
        cookies.forEach { config.httpCookieStorage?.setCookie($0) }
        return config
    }

    static func request(_ url: URL, for media: WebMedia, range: String? = nil) -> URLRequest {
        var request = URLRequest(url: url)
        for (name, value) in media.headers { request.setValue(value, forHTTPHeaderField: name) }
        if request.value(forHTTPHeaderField: "Referer") == nil, let page = media.pageURL {
            request.setValue(page.absoluteString, forHTTPHeaderField: "Referer")
        }
        if let range { request.setValue(range, forHTTPHeaderField: "Range") }
        return request
    }

    enum Failure: LocalizedError {
        case status(Int)
        var errorDescription: String? {
            switch self {
            case .status(let code): "서버 응답 \(code)"
            }
        }
        /// 다시 시도해도 안 될 거절 (401·403·404·410)
        var isPermanent: Bool {
            switch self {
            case .status(let code): [401, 403, 404, 410].contains(code)
            }
        }
    }

    /// 받아서 내용 돌려주기 (2xx 가 아니면 오류)
    static func data(_ request: URLRequest, session: URLSession, delegate: URLSessionTaskDelegate? = nil) async throws -> Data {
        let (data, response) = try await session.data(for: request, delegate: delegate)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if [401, 403].contains(status) {
            let received = (response as? HTTPURLResponse)?.allHeaderFields.reduce(into: [String: String]()) { $0["\($1.key)"] = "\($1.value)" } ?? [:]
            WebLog.write("HLS 받기 거절 \(status)\n요청 \(request.url?.absoluteString ?? "-")\n\(WebLog.headers(request.allHTTPHeaderFields ?? [:]))\n응답\n\(WebLog.headers(received))")
        }
        guard (200..<300).contains(status) else { throw Failure.status(status) }
        return data
    }

    /// 한 조각 받기: 잠깐의 끊김·서버 오류는 1·2·4·8초 뒤 다시 (거절이면 바로 실패)
    static func dataRetrying(_ request: URLRequest, session: URLSession, meter: ReceiveMeter? = nil) async throws -> Data {
        var attempt = 0
        while true {
            do {
                guard let meter else { return try await data(request, session: session) }
                // 바뀜 (2026-11-11): 받는 동안의 바이트를 meter 가 센다 (다 받은 조각은 그 크기로, 실패한 시도는 빼고)
                let watcher = ReceiveMeter.TaskWatcher(meter)
                do {
                    let received = try await data(request, session: session, delegate: watcher)
                    watcher.finished(bytes: received.count)
                    return received
                } catch {
                    watcher.failed()
                    throw error
                }
            } catch let failure as Failure where failure.isPermanent {
                throw failure
            } catch {
                if Task.isCancelled || attempt >= 4 { throw error }
                try await Task.sleep(for: .seconds(1 << attempt))
                attempt += 1
            }
        }
    }
}

/// 웹 받기 진단 기록 (2026-11-07): ~/Library/Logs/iRayer/web.log 에 감지한 요청과 실패한 요청·응답을 적는다.
/// 쿠키는 이름만 (값은 적지 않는다). 1MB 넘으면 처음부터 다시.
enum WebLog {
    nonisolated static let file = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        .appending(path: "Logs/iRayer/web.log")
    nonisolated private static let queue = DispatchQueue(label: "irayer.weblog")

    nonisolated static func write(_ text: String) {
        let line = "[\(Date().formatted(.iso8601))] \(text)\n"
        queue.async {
            let manager = FileManager.default
            try? manager.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let size = (try? manager.attributesOfItem(atPath: file.path))?[.size] as? Int, size > 1_000_000 {
                try? manager.removeItem(at: file)
            }
            if !manager.fileExists(atPath: file.path) { manager.createFile(atPath: file.path, contents: nil) }
            guard let handle = try? FileHandle(forWritingTo: file) else { return }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data(line.utf8))
            try? handle.close()
        }
    }

    nonisolated static func headers(_ headers: [String: String]) -> String {
        headers.sorted { $0.key < $1.key }.map { key, value in
            if key.lowercased() == "cookie" {
                let names = value.split(separator: ";").map { $0.split(separator: "=").first.map { String($0).trimmingCharacters(in: .whitespaces) } ?? "" }
                return "  \(key): (이름만) \(names.joined(separator: ", "))"
            }
            return "  \(key): \(value)"
        }.joined(separator: "\n")
    }

    /// 실패한 요청과 응답
    nonisolated static func failure(_ task: URLSessionTask, response: HTTPURLResponse?, cookies: [HTTPCookie], note: String) {
        let request = task.currentRequest ?? task.originalRequest
        var sent = request?.allHTTPHeaderFields ?? [:]
        // URLSession 이 붙이는 쿠키는 currentRequest 에 안 보일 수 있어, 그 주소에 맞는 저장소 쿠키 이름을 따로 적는다
        let matching = request?.url.map { url in HTTPCookie.requestHeaderFields(with: cookies.filter { cookie in
            guard let host = url.host() else { return false }
            let domain = cookie.domain.hasPrefix(".") ? String(cookie.domain.dropFirst()) : cookie.domain
            return host == domain || host.hasSuffix("." + domain)
        }) } ?? [:]
        if sent["Cookie"] == nil, let cookie = matching["Cookie"] { sent["Cookie (저장소에서 맞는 것)"] = cookie }
        var text = "받기 실패: \(note)\n요청 \(request?.httpMethod ?? "GET") \(request?.url?.absoluteString ?? "-")\n\(headers(sent))"
        if let original = task.originalRequest?.url, original != request?.url { text += "\n처음 주소 \(original.absoluteString)" }
        if let response {
            let received = response.allHeaderFields.reduce(into: [String: String]()) { $0["\($1.key)"] = "\($1.value)" }
            text += "\n응답 \(response.statusCode) \(response.url?.absoluteString ?? "")\n\(headers(received))"
        }
        text += "\n브라우저 저장소 쿠키 \(cookies.count)개 (도메인: \(Set(cookies.map(\.domain)).sorted().joined(separator: ", ")))"
        write(text)
    }
}


/// HLS 받기의 진행 (2026-11-11, 사용자: 진행률·속도가 몰려서 한 번에 반영됨).
/// 전에는 조각을 순서대로 파일에 쓸 때만 셌다 — 느린 조각 하나가 있으면 뒤 조각이 다 와도 멈췄다가 한꺼번에 뛰고,
/// 조각 하나를 다 받아야 그 크기가 더해져 계단처럼 올랐다. 이제 받는 중인 요청의 받은 바이트까지 세고, 조각은 도착하는 대로 센다.
final class ReceiveMeter: @unchecked Sendable {
    private let lock = NSLock()
    /// 이전에 받아 둔 것 + 다 받은 조각
    private var completed: Int64
    private var arrived: Int
    private var live: [ObjectIdentifier: URLSessionTask] = [:]
    private var mark: (time: Date, bytes: Int64)
    private var speed: Double = 0

    init(bytes: Int64, segments: Int) {
        completed = bytes
        arrived = segments
        mark = (Date(), bytes)
    }

    /// 받은 바이트 (받는 중인 것 포함)와 도착한 조각 수
    var snapshot: (bytes: Int64, segments: Int) {
        lock.withLock { (completed + live.values.reduce(0) { $0 + $1.countOfBytesReceived }, arrived) }
    }

    /// 초당 바이트: 1초마다 다시 잰다 (받는 게 멈추면 0 으로 떨어진다)
    func speed(at bytes: Int64) -> Double {
        lock.withLock {
            let now = Date()
            if now.timeIntervalSince(mark.time) >= 1 {
                speed = Double(bytes - mark.bytes) / now.timeIntervalSince(mark.time)
                mark = (now, bytes)
            }
            return speed
        }
    }

    fileprivate func add(_ task: URLSessionTask) {
        lock.withLock { live[ObjectIdentifier(task)] = task }
    }

    fileprivate func finish(_ task: URLSessionTask?, bytes: Int?) {
        lock.withLock {
            if let task { live[ObjectIdentifier(task)] = nil }
            if let bytes {
                completed += Int64(bytes)
                arrived += 1
            }
        }
    }

    /// 요청 하나를 지켜본다 (만들어지면 받는 중으로 넣는다)
    final class TaskWatcher: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        private let meter: ReceiveMeter
        private var task: URLSessionTask?
        init(_ meter: ReceiveMeter) { self.meter = meter }

        func urlSession(_ session: URLSession, didCreateTask task: URLSessionTask) {
            self.task = task
            meter.add(task)
        }

        func finished(bytes: Int) { meter.finish(task, bytes: bytes) }
        func failed() { meter.finish(task, bytes: nil) }
    }
}
