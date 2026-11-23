#if os(iOS)
import Foundation
import Network

/// AirPlay 중계 서버.
/// AirPlay 로 영상을 보내면 TV 가 그 주소에 직접 접속해 받아 가므로, 폰이 같은 Wi-Fi 에 작은 HTTP 서버를 열고
/// 폰이 다시 압축해 만든 HLS(재생목록·조각)를 내보낸다 (HLSStream).
/// 연결 처리는 모두 메인 큐에서 한다 (앱 전체가 MainActor 기준).
final class LocalStreamServer {
    static let shared = LocalStreamServer()

    private var listener: NWListener?
    /// 다시 압축해 보내는 HLS (토큰별)
    private var streams: [String: HLSSegmenter] = [:]

    private init() {}

    /// HLS 재생목록 주소
    func url(for stream: HLSStream) async -> URL? {
        guard let address = Self.wifiAddress(), let port = await startIfNeeded() else { return nil }
        streams[stream.token] = stream.segmenter
        return URL(string: "http://\(address):\(port)/\(stream.token)/index.m3u8")
    }

    func remove(_ stream: HLSStream) {
        streams[stream.token] = nil
    }

    /// HLS 요청: 재생목록이나 조각 파일을 한 번에 보낸다
    private func respondHLS(_ connection: NWConnection, segmenter: HLSSegmenter, name: String, method: String) async {
        let body: Data?
        let type: String
        if name == "index.m3u8" {
            body = Data(segmenter.playlist().utf8)
            type = "application/vnd.apple.mpegurl"
        } else {
            // 아직 없는 조각은 만들어질 때까지 기다린다
            body = await segmenter.data(named: name)
            type = "video/mp4"
        }
        guard let body else {
            await send(connection, Data("HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8))
            return
        }
        let head = "HTTP/1.1 200 OK\r\nContent-Type: \(type)\r\nContent-Length: \(body.count)\r\nCache-Control: no-cache\r\nConnection: close\r\n\r\n"
        guard await send(connection, Data(head.utf8)), method != "HEAD" else { return }
        await send(connection, body)
    }

    // MARK: - 서버

    private func startIfNeeded() async -> UInt16? {
        if let port = listener?.port?.rawValue { return port }
        guard let listener = try? NWListener(using: .tcp, on: .any) else { return nil }
        self.listener = listener
        listener.newConnectionHandler = { [weak self] connection in
            MainActor.assumeIsolated { self?.accept(connection) }
        }
        listener.start(queue: .main)
        // 포트가 정해질 때까지 잠깐 기다린다
        for _ in 0..<20 {
            if let port = listener.port?.rawValue, port != 0 { return port }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return nil
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: .main)
        receiveHeader(connection, buffer: Data())
    }

    /// 요청 헤더(빈 줄까지)를 다 받으면 응답한다
    private func receiveHeader(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16 << 10) { [weak self] data, _, isComplete, error in
            MainActor.assumeIsolated {
                guard let self else { return }
                var buffer = buffer
                if let data { buffer.append(data) }
                if let end = buffer.range(of: Data("\r\n\r\n".utf8)) {
                    let header = String(decoding: buffer[..<end.lowerBound], as: UTF8.self)
                    Task { await self.respond(connection, header: header) }
                } else if isComplete || error != nil || buffer.count > 64 << 10 {
                    connection.cancel()
                } else {
                    self.receiveHeader(connection, buffer: buffer)
                }
            }
        }
    }

    private func respond(_ connection: NWConnection, header: String) async {
        defer { connection.cancel() }
        let lines = header.components(separatedBy: "\r\n")
        let request = lines.first?.split(separator: " ") ?? []
        guard request.count >= 2 else { return }
        let method = String(request[0])
        let parts = request[1].split(separator: "/").map(String.init)
        guard parts.count >= 2, let segmenter = streams[parts[0]] else {
            await send(connection, Data("HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8))
            return
        }
        await respondHLS(connection, segmenter: segmenter, name: parts[1], method: method)
    }

    /// 보낸 뒤 성공했는지
    @discardableResult
    private func send(_ connection: NWConnection, _ data: Data) async -> Bool {
        await withCheckedContinuation { continuation in
            connection.send(content: data, completion: .contentProcessed { error in
                continuation.resume(returning: error == nil)
            })
        }
    }

    /// 폰의 Wi-Fi IPv4 주소 (TV 가 접속할 주소)
    static func wifiAddress() -> String? {
        var pointer: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&pointer) == 0, let first = pointer else { return nil }
        defer { freeifaddrs(pointer) }
        var fallback: String?
        for entry in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let interface = entry.pointee
            guard let address = interface.ifa_addr, address.pointee.sa_family == UInt8(AF_INET) else { continue }
            let name = String(cString: interface.ifa_name)
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let ip = String(decoding: host.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            if name == "en0" { return ip }
            // 시뮬레이터 등 en0 가 없을 때를 위해 다른 사설 주소도 기억해 둔다
            if fallback == nil, !ip.hasPrefix("127."), name.hasPrefix("en") { fallback = ip }
        }
        return fallback
    }
}
#endif
