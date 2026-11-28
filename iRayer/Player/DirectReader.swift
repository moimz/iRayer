import Foundation
#if os(macOS)
import VLCKit
#else
import MobileVLCKit
#endif

/// NAS(WebDAV·SMB) 영상을 VLC 대신 앱이 직접 받아 메모리에 쌓아 두고, VLC 는 여기서 읽어 간다 (libvlc_media_new_callbacks).
/// VLC 3 는 지금 얼마나 받아 두었는지 알려주지 않고, 버퍼(network-caching)를 크게 잡으면 탐색할 때마다 그만큼 기다린다.
/// 직접 읽으면 받아 둔 범위를 알 수 있고, 큰 버퍼는 우리가 뒤에서 채우므로 VLC 는 짧게만 기다린다.
/// 바뀜 (2026-11-10, 사용자: Non-Interleaved MP4 가 끊기고 탐색하다 죽음): 이어진 한 구간만 들고 있으면, 소리를 몇 분 앞서 저장한 파일은
/// 소리 자리와 영상 자리를 오갈 때마다 받아 둔 것을 버리고 다시 받는다. 이제 파일을 256KB 블록으로 나눠 따로따로 들고 있고(스파스 캐시),
/// 떨어진 자리마다 받는 줄(Fetcher)을 따로 두어 각자 앞으로 이어 받는다 (nPlayer·Infuse 처럼).
nonisolated final class DirectReader: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    /// 어디서 받는지: WebDAV 는 접속 정보를 붙인 요청, SMB 는 주소와 서버
    enum Source {
        case http(URLRequest)
        case smb(URL, serverID: UUID?)

        var kind: String {
            switch self {
            case .http: "WebDAV"
            case .smb: "SMB"
            }
        }
    }

    let size: Int64
    private let source: Source
    /// 앞으로 미리 받아 둘 양 (영상 길이를 알면 버퍼 설정 시간만큼으로 바꾼다). 받는 줄이 여럿이면 나눠 쓴다
    private var readAhead: Int64 = 32 << 20
    /// 읽는 자리 뒤로 남겨 둘 양 (조금 뒤로 돌아가는 탐색은 다시 받지 않는다)
    private let keepBehind: Int64 = 16 << 20
    /// 받는 줄 수 상한 (소리·영상 두 자리 + 탐색한 자리)
    private static let maxFetchers = 4
    /// 이 안쪽 앞이면 새 줄을 열지 않고 받는 줄이 닿을 때까지 기다린다
    private static let joinGap: Int64 = 2 << 20
    /// 이만큼 안 쓰인 줄은 미리 받기 몫을 나눌 때 세지 않는다
    private static let recent: TimeInterval = 5

    private let condition = NSCondition()
    // 탐색하면 그 블록 처음부터 받으므로 작게 (1MB 면 10MB/s 에서 탐색마다 0.1초 더 기다린다)
    private static let blockSize: Int64 = 256 << 10
    /// 다 받은 블록 (블록 번호 → 256KB, 파일 끝 블록만 짧다)
    private var blocks: [Int64: Data] = [:]
    /// 블록을 마지막으로 쓴 차례 (메모리가 넘치면 오래 안 쓴 것부터 버린다)
    private var blockUsed: [Int64: Int] = [:]
    private var useCounter = 0
    private var fetchers: [Fetcher] = []
    private var nextFetcherID = 0
    /// VLC 가 다음에 읽을 위치
    private var position: Int64 = 0
    /// 다시 받을 수 없는 오류 (인증 실패, 서버가 Range 를 무시함, 오래 끊김). VLC 에 읽기 실패를 알린다.
    private var failed = false
    private var cancelled = false
    /// 처음 끊긴 시각 (받는 게 오면 지운다)
    private var failingSince: Date?
    /// VLC 가 데이터를 기다리기 시작한 때 (기다리는 중이 아니면 nil)
    private var starvedSince: Date?
    /// 디버그 정보 (2026-11-28, 사용자: 재생 중 연결·속도를 보려고): 보낸 요청 수, 받은 양
    private var requestsStarted = 0
    private var bytesReceived: Int64 = 0
    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.default
        // 데이터가 오다 멈추면 기본 60초를 기다리지 않고 다시 연결한다
        configuration.timeoutIntervalForRequest = 10
        configuration.httpMaximumConnectionsPerHost = Self.maxFetchers + 1
        return URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }()

    /// 파일의 한 자리부터 앞으로 이어 받는 줄
    private final class Fetcher {
        let id: Int
        /// 처음 받기 시작한 곳 (이 줄이 맡은 구간의 시작)
        var origin: Int64
        /// 다음에 받을 바이트
        var next: Int64
        /// 이 줄 구간에서 VLC 가 읽은 가장 앞 (여기서부터 미리 받기를 센다).
        /// 소리·영상이 떨어진 파일은 한 줄 안에서 두 자리를 번갈아 읽으므로, 마지막 자리로 세면 받다 멈추다를 되풀이한다
        var cursor: Int64
        /// 최근(3~6초) 읽은 가장 뒤 (여기서부터 뒤로 keepBehind 를 남긴다)
        var low: Int64
        var previousLow: Int64
        var epochStart = Date()
        /// 다 차지 않은 블록 (시작은 next - pending.count, 블록 경계)
        var pending = Data()
        var task: URLSessionDataTask?
        var smbTask: Task<Void, Never>?
        /// 받는 중인지 (미리 받기 상한에 닿으면 끊었다가 읽는 대로 다시 받는다)
        var active = false
        /// 받기를 새로 시작할 때마다 늘린다 (멈춘 앞 SMB 작업이 늦게 가져온 것은 버린다)
        var generation = 0
        var lastUsed = Date()
        var retryAt = Date.distantPast
        /// 이 줄이 받은 양 (디버그 정보: 줄마다 속도)
        var received: Int64 = 0
        init(id: Int, at offset: Int64) {
            self.id = id
            origin = offset
            next = offset
            cursor = offset
            low = offset
            previousLow = offset
        }
        /// VLC 가 이 줄 구간을 읽었다
        func read(at offset: Int64) {
            cursor = max(cursor, offset)
            let now = Date()
            if now.timeIntervalSince(epochStart) > 3 {
                previousLow = low
                low = offset
                epochStart = now
            } else {
                low = min(low, offset)
            }
            lastUsed = now
        }
        /// 뒤로 남겨 둘 곳의 기준
        var trail: Int64 { min(low, previousLow) }
        /// 뒤로 탐색해 받아 둔 곳 안으로 들어왔다 (앞쪽은 이미 받아 두었으니 거기서부터 다시 센다)
        func jumped(to offset: Int64) {
            cursor = offset
            low = offset
            previousLow = offset
            epochStart = Date()
            lastUsed = epochStart
        }
        var pendingStart: Int64 { next - Int64(pending.count) }
    }

    init(source: Source, size: Int64) {
        self.source = source
        self.size = size
        super.init()
        log("열기 \(Self.mb(size)) (\(source.kind))")
    }

    // MARK: - 기록 (2026-11-11, 사용자: 받는 줄이 예상대로 움직였는지 보려고)

    /// 맥: ~/Library/Logs/iRayer/reader.log, 아이폰·아이패드: 앱 저장 공간의 Library/Logs/iRayer/reader.log (2MB 넘으면 새로)
    static let logFile = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        .appending(path: "Logs/iRayer/reader.log")
    private static let logQueue = DispatchQueue(label: "irayer.readerlog")
    private static var nextLogID = 0
    private lazy var logID: Int = { Self.nextLogID += 1; return Self.nextLogID }()
    private var lastStatusAt = Date.distantPast

    private func log(_ text: String) {
        let line = "[\(Date().formatted(.iso8601.time(includingFractionalSeconds: true)))] #\(logID) \(text)\n"
        Self.logQueue.async {
            let manager = FileManager.default
            let file = Self.logFile
            try? manager.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let size = (try? manager.attributesOfItem(atPath: file.path))?[.size] as? Int, size > 2_000_000 {
                try? manager.removeItem(at: file)
            }
            if !manager.fileExists(atPath: file.path) { manager.createFile(atPath: file.path, contents: nil) }
            guard let handle = try? FileHandle(forWritingTo: file) else { return }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data(line.utf8))
            try? handle.close()
        }
    }

    private static func mb(_ bytes: Int64) -> String { String(format: "%.1fMB", Double(bytes) / 1_048_576) }

    /// 2초마다 줄들의 상태 (잠근 상태에서 부른다)
    private func logStatus(ahead: Int64) {
        let now = Date()
        guard now.timeIntervalSince(lastStatusAt) >= 2 else { return }
        lastStatusAt = now
        let lines = fetchers.map { f in
            "[\(f.id)\(f.active ? "▶" : "■") \(Self.mb(f.origin))~\(Self.mb(f.next)) 읽음 \(Self.mb(f.trail))..\(Self.mb(f.cursor)) \(Int(now.timeIntervalSince(f.lastUsed)))초전]"
        }.joined(separator: " ")
        log("상태 위치 \(Self.mb(position)) 블록 \(Self.mb(Int64(blocks.count) * Self.blockSize)) 앞으로 \(Self.mb(ahead)) 몫 \(Self.mb(share())) \(lines)")
    }

    /// 읽는 자리 앞으로 이어 받아 둔 양 (진행바 표시용). 받는 줄이 여럿이면 가장 덜 받은 줄 — 소리·영상 둘 다 있어야 재생된다.
    /// 바뀜 (2026-11-11, 사용자: 버퍼 막대가 이상하게 움직임): 바이트 위치 그대로 막대에 올리면, 소리·영상이 떨어진 파일은 실제보다 덜 받은 것처럼,
    /// 탐색 직후에는 앞 자리 줄이 5초 동안 섞여 재생 위치 뒤에 보였다. 이제 방금(1초 안) 읽은 줄만, 읽는 자리에서 앞으로 얼마나인지로 준다
    /// 바뀜 (2026-11-12, 사용자: 앞으로 탐색하면 버퍼 표시가 줄었다 늘고, 끝 무렵엔 아예 없었다):
    ///   ahead — 위와 같지만 파일 끝까지 받은 줄은 "끝까지 다 받음"(size)으로 센다 (VLC 가 끝까지 미리 읽으면 0 이 되었다.
    ///           파일 끝 목차를 읽느라 연 줄도 끝에 닿아 있으니 막대를 깎지 않는다)
    ///   end   — 방금 읽은 줄들이 이어 받아 둔 끝 중 가장 앞 (바이트 위치 그대로, 소리·영상이 섞인 보통 파일의 막대용)
    var buffered: (ahead: Int64, end: Int64) {
        condition.lock()
        defer { condition.unlock() }
        let now = Date()
        let used = fetchers.filter { now.timeIntervalSince($0.lastUsed) < 1 }
        let reads = used.isEmpty ? [position] : used.map(\.cursor)
        var ahead = Int64.max, end = Int64.max
        for read in reads {
            let upper = contiguous(from: read).upperBound
            ahead = min(ahead, upper >= size ? size : max(0, upper - read))
            end = min(end, max(upper, read))
        }
        logStatus(ahead: ahead)
        return (ahead, end)
    }

    /// 디버그 정보에 보일 지금 상태 (2026-11-28)
    struct Stats: Sendable {
        struct Line: Sendable {
            let id: Int
            let active: Bool
            /// 다음에 받을 곳, VLC 가 읽은 곳 (바이트)
            let next: Int64
            let cursor: Int64
            let received: Int64
        }
        let kind: String
        let size: Int64
        let requestsStarted: Int
        let bytesReceived: Int64
        let cachedBytes: Int64
        let readAhead: Int64
        let starvedFor: TimeInterval
        let failing: Bool
        let lines: [Line]
    }

    var stats: Stats {
        condition.lock()
        defer { condition.unlock() }
        return Stats(
            kind: source.kind, size: size, requestsStarted: requestsStarted, bytesReceived: bytesReceived,
            cachedBytes: blocks.values.reduce(0) { $0 + Int64($1.count) }, readAhead: readAhead,
            starvedFor: starvedSince.map { Date().timeIntervalSince($0) } ?? 0,
            failing: failingSince != nil || failed,
            lines: fetchers.map { Stats.Line(id: $0.id, active: $0.active, next: $0.next, cursor: $0.cursor, received: $0.received) }
        )
    }

    /// 받아 둔 범위를 그대로 꺼낸다 (모두 받아 두었을 때만). VLC 가 읽고 간 목차(MP4 moov·MKV Cues)를
    /// NAS 에 다시 요청하지 않고 버퍼 막대용 바이트→시간 표로 쓰려고 (2026-11-28, ByteTimeline)
    func cached(_ range: Range<Int64>) -> Data? {
        condition.lock()
        defer { condition.unlock() }
        guard range.lowerBound >= 0, range.upperBound <= size, !range.isEmpty else { return nil }
        var out = Data(capacity: range.count)
        var offset = range.lowerBound
        while offset < range.upperBound {
            let index = offset / Self.blockSize
            guard let block = blocks[index] else { return nil }
            let inner = Int(offset - index * Self.blockSize)
            let length = min(block.count - inner, Int(range.upperBound - offset))
            guard length > 0 else { return nil }
            out.append(block[block.startIndex + inner..<block.startIndex + inner + length])
            offset += Int64(length)
        }
        return out
    }

    /// VLC 가 데이터를 기다린 시간 (기다리는 중이 아니면 0). 로딩 표시용.
    var starvedFor: TimeInterval {
        condition.lock()
        defer { condition.unlock() }
        return starvedSince.map { Date().timeIntervalSince($0) } ?? 0
    }

    /// 미리 받아 둘 양을 바꾼다 (기기 메모리에 맞춰 상한을 둔다)
    func setReadAhead(_ bytes: Int64) {
        let limit = min(Int64(256 << 20), Int64(ProcessInfo.processInfo.physicalMemory / 24))
        condition.lock()
        readAhead = min(max(bytes, 16 << 20), limit)
        condition.unlock()
    }

    func cancel() {
        condition.lock()
        if !cancelled { log("닫기 (줄 \(fetchers.count)개, 블록 \(Self.mb(Int64(blocks.count) * Self.blockSize)))") }
        cancelled = true
        for fetcher in fetchers { stop(fetcher) }
        fetchers = []
        blocks = [:]
        blockUsed = [:]
        condition.broadcast()
        condition.unlock()
        session.invalidateAndCancel()
    }

    // MARK: - VLC 쪽 (VLC 의 입력 스레드에서 불린다)

    fileprivate func read(into buffer: UnsafeMutablePointer<UInt8>, count wanted: Int) -> Int {
        condition.lock()
        defer { condition.unlock() }
        if position >= size { return 0 }
        while !cancelled, !failed {
            if let length = copy(at: position, into: buffer, count: wanted) {
                if let starvedSince, Date().timeIntervalSince(starvedSince) > 0.2 {
                    log(String(format: "기다림 %.2f초 @%@", Date().timeIntervalSince(starvedSince), Self.mb(position)))
                }
                starvedSince = nil
                touch(position)
                position += Int64(length)
                return length
            }
            if starvedSince == nil { starvedSince = Date() }
            ensureFetcher(for: position)
            // 30초 넘게 다시 연결하지 못하면 포기한다 (VLC 가 재생 오류로 끝낸다)
            if let failingSince, Date().timeIntervalSince(failingSince) > 30 { failed = true }
            condition.wait(until: Date().addingTimeInterval(0.2))
        }
        return -1
    }

    fileprivate func seek(to offset: Int64) -> Int32 {
        condition.lock()
        defer { condition.unlock() }
        // 받아 둔 블록은 그대로 둔다. 없는 자리면 읽을 때 그 자리 줄을 연다
        position = offset
        return 0
    }

    // MARK: - 블록 (잠근 상태에서 부른다)

    /// 받아 둔 것에서 한 블록 안만큼 복사한다 (덜 읽으면 VLC 가 다시 부른다). 없으면 nil
    private func copy(at offset: Int64, into buffer: UnsafeMutablePointer<UInt8>, count wanted: Int) -> Int? {
        let index = offset / Self.blockSize
        let inner = Int(offset - index * Self.blockSize)
        let data: Data
        if let block = blocks[index], inner < block.count {
            data = block
            useCounter += 1
            blockUsed[index] = useCounter
        } else if let fetcher = fetchers.first(where: { $0.pendingStart == index * Self.blockSize && inner < $0.pending.count }) {
            data = fetcher.pending
        } else {
            return nil
        }
        let length = min(wanted, data.count - inner)
        data.withUnsafeBytes { raw in
            buffer.update(from: raw.baseAddress!.assumingMemoryBound(to: UInt8.self) + inner, count: length)
        }
        return length
    }

    private func has(_ index: Int64) -> Bool { blocks[index] != nil }

    /// offset 이 든 블록부터 이어 받아 둔 구간
    private func contiguous(from offset: Int64) -> Range<Int64> {
        var first = offset / Self.blockSize
        guard has(first) || fetchers.contains(where: { $0.pendingStart == first * Self.blockSize && !$0.pending.isEmpty }) else {
            return offset..<offset
        }
        while first > 0, has(first - 1) { first -= 1 }
        var last = offset / Self.blockSize
        while has(last + 1) { last += 1 }
        var end = min((last + 1) * Self.blockSize, size)
        if let fetcher = fetchers.first(where: { $0.pendingStart == (has(last) ? last + 1 : last) * Self.blockSize }) {
            end = max(end, fetcher.next)
        }
        return first * Self.blockSize..<min(end, size)
    }

    /// VLC 가 읽은 자리를 맡은 줄에 알리고, 그 줄이 더 받아야 하면 다시 받게 한다
    private func touch(_ offset: Int64) {
        // 겹치면 가장 가까이서 시작한 줄 (다른 줄 블록을 건너뛴 줄은 구간이 넓다)
        guard let fetcher = fetchers.filter({ $0.origin <= offset && offset <= $0.next + Self.blockSize })
            .max(by: { $0.origin < $1.origin }) else { return }
        fetcher.read(at: offset)
        resume(fetcher)
    }

    /// 이 줄이 앞으로 받아 둘 양 (최근에 쓰인 줄끼리 나눈다)
    private func share() -> Int64 {
        let now = Date()
        let used = max(1, fetchers.filter { now.timeIntervalSince($0.lastUsed) < Self.recent }.count)
        return max(readAhead / Int64(used), 8 << 20)
    }

    /// 없는 자리를 읽으려 할 때: 곧 닿을 줄이 있으면 기다리고, 없으면 그 자리에서 새 줄을 연다
    private func ensureFetcher(for offset: Int64) {
        guard !cancelled, !failed else { return }
        if let fetcher = fetchers.first(where: { $0.next <= offset + Self.blockSize && offset - $0.next < Self.joinGap && $0.pendingStart <= offset }) {
            fetcher.read(at: min(offset, fetcher.next))
            resume(fetcher)
            return
        }
        // 그 자리의 블록 경계부터 (이미 받아 둔 블록은 건너뛴다)
        var index = offset / Self.blockSize
        // 바뀜 (2026-11-13): 읽을 자리 블록이 있는데도 못 읽었으면(짧은 블록) 그 블록을 버리고 다시 받는다 — 줄을 끝없이 여닫지 않게
        if let block = blocks[index], Int(offset - index * Self.blockSize) >= block.count {
            log("짧은 블록 버림 @\(Self.mb(index * Self.blockSize)) (\(block.count)바이트)")
            blocks[index] = nil
            blockUsed[index] = nil
        }
        while has(index) { index += 1 }
        let start = index * Self.blockSize
        guard start < size else { return }
        if fetchers.count >= Self.maxFetchers, let oldest = fetchers.min(by: { $0.lastUsed < $1.lastUsed }) {
            stop(oldest)
            fetchers.removeAll { $0 === oldest }
            log("줄 \(oldest.id) 닫음 (줄이 많아서)")
        }
        nextFetcherID += 1
        let fetcher = Fetcher(id: nextFetcherID, at: start)
        log("줄 \(nextFetcherID) 엶 @\(Self.mb(start)) (읽을 곳 \(Self.mb(offset)), 줄 \(fetchers.count + 1)개)")
        fetcher.jumped(to: offset)
        fetchers.append(fetcher)
        resume(fetcher)
    }

    /// 받은 것을 줄에 쌓는다. 블록이 차면 블록으로 옮기고, 이미 받아 둔 블록에 닿으면 그 줄을 멈춘다
    private func append(_ chunk: Data, to fetcher: Fetcher) {
        bytesReceived += Int64(chunk.count)
        fetcher.received += Int64(chunk.count)
        var rest = chunk[...]
        while !rest.isEmpty {
            let index = fetcher.pendingStart / Self.blockSize
            let blockEnd = min((index + 1) * Self.blockSize, size)
            let room = Int(blockEnd - fetcher.next)
            // 바뀜 (2026-11-13): 덜 찬 것이 블록 경계에서 시작하지 않으면(어긋남) 버리고 다음 경계부터 받게 한다 — 엉뚱한 데이터를 블록으로 두지 않는다
            guard room > 0, fetcher.pendingStart % Self.blockSize == 0 else {
                log("줄 \(fetcher.id) 어긋남 버림 @\(Self.mb(fetcher.next))")
                stop(fetcher)
                fetcher.pending = Data()
                fetcher.next = (fetcher.next / Self.blockSize + 1) * Self.blockSize
                break
            }
            fetcher.pending.append(rest.prefix(room))
            fetcher.next += Int64(min(room, rest.count))
            rest = rest.dropFirst(room)
            if fetcher.next == blockEnd {
                // 바뀜 (2026-11-13): 이미 있는 블록은 덮어쓰지 않는다
                if blocks[index] == nil { blocks[index] = fetcher.pending }
                useCounter += 1
                blockUsed[index] = useCounter
                fetcher.pending = Data()
                // 다른 줄이 받아 둔 곳에 닿았다: 그 뒤 빈 곳부터 다시 받는다 (요청을 새로)
                if has(index + 1) {
                    log("줄 \(fetcher.id) 받아 둔 곳에 닿음 @\(Self.mb(fetcher.next))")
                    stop(fetcher)
                    var skip = index + 1
                    while has(skip) { skip += 1 }
                    fetcher.next = skip * Self.blockSize
                    break
                }
            }
        }
        evict()
    }

    /// 메모리 상한을 넘으면, 어떤 줄의 읽는 자리 근처(뒤 keepBehind ~ 앞 미리 받기)에도 없는 블록부터, 오래 안 쓴 것부터 버린다
    private func evict() {
        // 줄마다 뒤 keepBehind, 미리 받기 넘침(8MB), 덜 찬 블록만큼 더
        let budget = readAhead + Int64(max(1, fetchers.count)) * (keepBehind + (10 << 20))
        guard Int64(blocks.count) * Self.blockSize > budget else { return }
        let ahead = share()
        let now = Date()
        let windows = fetchers.filter { now.timeIntervalSince($0.lastUsed) < Self.recent }
            .map { ($0.trail - keepBehind)..<($0.cursor + ahead + Self.blockSize) }
        let ordered = blocks.keys.sorted { (blockUsed[$0] ?? 0) < (blockUsed[$1] ?? 0) }
        let outside = ordered.filter { index in
            let start = index * Self.blockSize
            return !windows.contains { $0.contains(start) }
        }
        var dropped = 0, droppedInside = 0
        let outsideSet = Set(outside)
        for index in outside + ordered where Int64(blocks.count) * Self.blockSize > budget {
            guard blocks[index] != nil else { continue }
            blocks[index] = nil
            blockUsed[index] = nil
            dropped += 1
            if !outsideSet.contains(index) { droppedInside += 1 }
        }
        // 읽는 자리 근처까지 버렸으면 상한이 모자란 것 (드물어야 한다)
        if droppedInside > 0 { log("읽는 자리 근처 블록 \(droppedInside)개 버림 (모두 \(dropped)개, 상한 \(Self.mb(budget)))") }
    }

    // MARK: - 받기 (잠근 상태에서 부른다)

    /// 줄이 멈춰 있고 앞으로 더 받아야 하면 다시 받는다
    private func resume(_ fetcher: Fetcher) {
        guard !cancelled, !failed, !fetcher.active, Date() >= fetcher.retryAt else { return }
        guard fetcher.next < size, fetcher.next - fetcher.cursor < share() else { return }
        // 덜 찬 블록은 받은 곳부터 이어 받는다. 다 받은 블록은 건너뛴다
        // 바뀜 (2026-11-13, 사용자: 재생·닫기가 엄청 느려진다): 쉬는 사이 다른 줄이 그 블록을 다 받았으면 덜 찬 것(pending)도 버린다.
        // 안 버리면 다음 블록 자리에 앞 블록 조각을 짧은 블록으로 덮어써서(받기 직후 '받아 둔 곳에 닿음'), 그 자리를 영영 못 읽고
        // 1초에 200번씩 줄을 열고 닫았다 (아이폰 11-12 기록: 27초에 5천 번). 그 블록의 데이터도 엉뚱한 자리 것이었다
        while has(fetcher.next / Self.blockSize) {
            fetcher.pending = Data()
            fetcher.next = (fetcher.next / Self.blockSize + 1) * Self.blockSize
        }
        guard fetcher.next < size else { return }
        log("줄 \(fetcher.id) 받기 @\(Self.mb(fetcher.next)) (읽은 곳 \(Self.mb(fetcher.cursor)))")
        start(fetcher)
    }

    private func stop(_ fetcher: Fetcher) {
        fetcher.task?.cancel()
        fetcher.task = nil
        fetcher.smbTask?.cancel()
        fetcher.smbTask = nil
        fetcher.active = false
    }

    private func start(_ fetcher: Fetcher) {
        // 닫은 뒤에는 새로 받지 않는다 (닫은 세션에 작업을 만들면 앱이 죽는다)
        guard !cancelled else { return }
        fetcher.active = true
        requestsStarted += 1
        fetcher.generation += 1
        let generation = fetcher.generation
        let offset = fetcher.next
        switch source {
        case .http(var request):
            request.setValue("bytes=\(offset)-", forHTTPHeaderField: "Range")
            let task = session.dataTask(with: request)
            task.taskDescription = String(fetcher.id)
            fetcher.task = task
            task.resume()
        case .smb(let url, let serverID):
            fetcher.smbTask = Task.detached { [weak self] in
                await self?.fetchSMB(url, serverID: serverID, fetcher: fetcher, generation: generation, from: offset)
            }
        }
    }

    /// 미리 받기 상한에 닿았는지 (끊었다가 읽는 대로 이어 받는다)
    private func isFull(_ fetcher: Fetcher) -> Bool {
        fetcher.next - fetcher.cursor >= share() + (8 << 20)
    }

    private func failedFetch(_ fetcher: Fetcher) {
        log("줄 \(fetcher.id) 끊김 @\(Self.mb(fetcher.next))")
        fetcher.active = false
        // 잠깐 끊긴 것일 수 있으니 1초 뒤 받은 곳부터 이어 받는다 (30초 넘게 안 되면 read 에서 포기)
        if failingSince == nil { failingSince = Date() }
        fetcher.retryAt = Date().addingTimeInterval(1)
    }

    // MARK: - SMB 받기 (SMB 는 이어 받는 요청이 없어 조각씩 읽는다)

    /// 처음엔 작게(빨리 첫 장면), 이어지면 4MB 까지 키워 읽는다
    private func fetchSMB(_ url: URL, serverID: UUID?, fetcher: Fetcher, generation: Int, from start: Int64) async {
        var offset = start
        var chunk: Int64 = 256 << 10
        while let end = nextSMBRange(fetcher, generation: generation, at: offset, chunk: chunk) {
            do {
                let data = try await SMBClient.shared.read(url, range: offset..<end, serverID: serverID)
                guard !data.isEmpty else { throw RemoteAccess.AccessError.unreachable }
                guard deliverSMB(data, to: fetcher, generation: generation, at: offset) else { return }
                offset += Int64(data.count)
                chunk = min(chunk * 2, 4 << 20)
            } catch {
                failSMB(error, fetcher: fetcher, generation: generation, at: offset)
                return
            }
        }
    }

    /// 더 받을 범위 (닫혔거나, 그 줄이 멈췄거나 다른 곳을 받게 됐거나, 끝까지 받았거나, 미리 받기 상한이면 nil)
    private func nextSMBRange(_ fetcher: Fetcher, generation: Int, at offset: Int64, chunk: Int64) -> Int64? {
        condition.lock()
        defer { condition.unlock() }
        guard !cancelled, fetcher.active, fetcher.generation == generation, fetcher.next == offset, fetchers.contains(where: { $0 === fetcher }) else { return nil }
        if offset >= size || isFull(fetcher) {
            log("줄 \(fetcher.id) 쉼 @\(Self.mb(offset))")
            fetcher.smbTask = nil
            fetcher.active = false
            return nil
        }
        // 다른 줄이 받아 둔 블록 앞에서 끊는다
        var end = min(offset + chunk, size)
        var index = offset / Self.blockSize + 1
        while index * Self.blockSize < end {
            if has(index) { end = index * Self.blockSize; break }
            index += 1
        }
        return end
    }

    private func deliverSMB(_ data: Data, to fetcher: Fetcher, generation: Int, at offset: Int64) -> Bool {
        condition.lock()
        defer { condition.unlock() }
        guard !cancelled, fetcher.active, fetcher.generation == generation, fetcher.next == offset else { return false }
        append(data, to: fetcher)
        failingSince = nil
        condition.broadcast()
        return true
    }

    private func failSMB(_ error: Error, fetcher: Fetcher, generation: Int, at offset: Int64) {
        condition.lock()
        defer { condition.unlock() }
        guard fetcher.active, fetcher.generation == generation, fetcher.next == offset else { return }
        fetcher.smbTask = nil
        if case RemoteAccess.AccessError.unauthorized = error {
            fetcher.active = false
            failed = true
        } else {
            failedFetch(fetcher)
        }
        condition.broadcast()
    }

    // MARK: - URLSessionDataDelegate

    private func fetcher(for task: URLSessionTask) -> Fetcher? {
        fetchers.first { $0.task === task }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        condition.lock()
        // 206 이 아닌 200 은 Range 를 무시하고 처음부터 보내는 것이다 (처음부터 받을 때만 쓸 수 있다)
        let fetcher = fetcher(for: dataTask)
        let usable = status == 206 || (status == 200 && fetcher?.next == 0)
        if fetcher != nil, !usable {
            failed = true
            condition.broadcast()
        }
        condition.unlock()
        completionHandler(usable ? .allow : .cancel)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive chunk: Data) {
        condition.lock()
        defer { condition.unlock() }
        guard let fetcher = fetcher(for: dataTask) else { return }
        append(chunk, to: fetcher)
        failingSince = nil
        condition.broadcast()
        if fetcher.task === dataTask, isFull(fetcher) {
            log("줄 \(fetcher.id) 쉼 @\(Self.mb(fetcher.next)) (미리 받기 다 참)")
            stop(fetcher)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        condition.lock()
        defer { condition.unlock() }
        guard let fetcher = fetcher(for: task) else { return }
        fetcher.task = nil
        if let error = error as? URLError, error.code != .cancelled {
            failedFetch(fetcher)
        } else {
            fetcher.active = false
        }
        condition.broadcast()
    }

    // MARK: - VLC 미디어 만들기

    /// 이 리더에서 읽는 VLC 미디어. 리더는 VLC 가 닫을 때(close 콜백)까지 살아 있다.
    func makeMedia() -> VLCMedia? {
        guard let api = Callbacks.shared, let instance = Callbacks.libraryInstance() else { return nil }
        let opaque = Unmanaged.passRetained(self).toOpaque()
        guard let md = api.newCallbacks(instance, { opaque, datap, sizep in
            guard let opaque else { return -1 }
            let reader = Unmanaged<DirectReader>.fromOpaque(opaque).takeUnretainedValue()
            datap?.pointee = opaque
            sizep?.pointee = UInt64(reader.size)
            return 0
        }, { opaque, buffer, count in
            guard let opaque, let buffer else { return -1 }
            return Unmanaged<DirectReader>.fromOpaque(opaque).takeUnretainedValue().read(into: buffer, count: count)
        }, { opaque, offset in
            guard let opaque else { return -1 }
            return Unmanaged<DirectReader>.fromOpaque(opaque).takeUnretainedValue().seek(to: Int64(offset))
        }, { opaque in
            guard let opaque else { return }
            let reader = Unmanaged<DirectReader>.fromOpaque(opaque)
            reader.takeUnretainedValue().cancel()
            reader.release()
        }, opaque) else {
            Unmanaged<DirectReader>.fromOpaque(opaque).release()
            return nil
        }
        let media = Callbacks.media(md)
        api.release(md)
        return media
    }
}

/// libvlc_media_new_callbacks (MobileVLCKit 안에 있지만 헤더가 없어 이름으로 찾는다)
nonisolated private final class Callbacks {
    typealias Open = @convention(c) (UnsafeMutableRawPointer?, UnsafeMutablePointer<UnsafeMutableRawPointer?>?, UnsafeMutablePointer<UInt64>?) -> Int32
    typealias Read = @convention(c) (UnsafeMutableRawPointer?, UnsafeMutablePointer<UInt8>?, Int) -> Int
    typealias Seek = @convention(c) (UnsafeMutableRawPointer?, UInt64) -> Int32
    typealias Close = @convention(c) (UnsafeMutableRawPointer?) -> Void

    static let shared = Callbacks()
    let newCallbacks: @convention(c) (OpaquePointer, Open?, Read?, Seek?, Close?, UnsafeMutableRawPointer?) -> OpaquePointer?
    let release: @convention(c) (OpaquePointer) -> Void

    private init?() {
        let handle = UnsafeMutableRawPointer(bitPattern: -2) // RTLD_DEFAULT
        guard let new = dlsym(handle, "libvlc_media_new_callbacks"), let rel = dlsym(handle, "libvlc_media_release") else { return nil }
        newCallbacks = unsafeBitCast(new, to: (@convention(c) (OpaquePointer, Open?, Read?, Seek?, Close?, UnsafeMutableRawPointer?) -> OpaquePointer?).self)
        release = unsafeBitCast(rel, to: (@convention(c) (OpaquePointer) -> Void).self)
    }

    /// VLCLibrary 의 libvlc_instance_t (비공개 속성 instance)
    static func libraryInstance() -> OpaquePointer? {
        let library = VLCLibrary.shared()
        let selector = NSSelectorFromString("instance")
        guard let method = class_getInstanceMethod(VLCLibrary.self, selector) else { return nil }
        typealias Getter = @convention(c) (AnyObject, Selector) -> OpaquePointer?
        return unsafeBitCast(method_getImplementation(method), to: Getter.self)(library, selector)
    }

    /// libvlc_media_t 로 VLCMedia 만들기 (비공개 +mediaWithLibVLCMediaDescriptor:, 미디어를 retain 한다)
    static func media(_ md: OpaquePointer) -> VLCMedia? {
        let selector = NSSelectorFromString("mediaWithLibVLCMediaDescriptor:")
        guard let method = class_getClassMethod(VLCMedia.self, selector) else { return nil }
        typealias Factory = @convention(c) (AnyClass, Selector, OpaquePointer) -> Unmanaged<VLCMedia>?
        return unsafeBitCast(method_getImplementation(method), to: Factory.self)(VLCMedia.self, selector, md)?.takeUnretainedValue()
    }
}
