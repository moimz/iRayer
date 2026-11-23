import CommonCrypto
import Foundation

/// HLS 받기: 가장 좋은 화질 목록(+ 따로 있는 소리 트랙)의 조각을 동시에 6개씩 받아 순서대로 트랙 파일에 이어 쓰고,
/// AES-128 이면 키를 받아 풀고, 다 받으면 ffmpeg 로 MP4(안 맞으면 MKV)로 묶는다.
/// 받는 동안은 저장 폴더의 `이름.mp4.irayer/` 폴더에 트랙 파일과 진행(state.json)을 두어, 끊겨도 받은 조각 다음부터 이어 받는다.
/// 라이브·DRM 은 받지 않는다.
final class HLSReceiver: WebTransfer, @unchecked Sendable {
    private let item: WebDownloads.Item
    private let media: WebMedia
    private let folder: URL
    private let cookies: [HTTPCookie]
    private let completion: @MainActor (WebDownloads.TransferOutcome) -> Void
    private var task: Task<Void, Never>?

    @MainActor
    init(item: WebDownloads.Item, cookies: [HTTPCookie], completion: @escaping @MainActor (WebDownloads.TransferOutcome) -> Void) {
        self.item = item
        media = item.media
        folder = item.partial
        self.cookies = cookies
        self.completion = completion
    }

    func start() {
        task = Task {
            let outcome = await run()
            if Task.isCancelled { return }
            await MainActor.run { completion(outcome) }
        }
    }

    func cancel() {
        task?.cancel()
    }

    // MARK: - 진행 저장

    /// 트랙마다 순서대로 다 쓴 조각 수와 그때의 파일 크기
    private struct Progress: Codable {
        var tracks: [String: Track] = [:]
        struct Track: Codable {
            var segments: Int
            var bytes: Int64
            /// 목록의 조각 수·길이 (2026-11-09) — 쿼리만 바뀐 주소로 이어 받을 때 같은 영상인지 본다
            var total: Int?
            var duration: Double?
        }
    }

    private var stateURL: URL { folder.appending(path: "state.json") }

    private func loadProgress() -> Progress {
        guard WebDownloads.meta(folder)?.canResume(media) == true, let data = try? Data(contentsOf: stateURL),
              let progress = try? JSONDecoder().decode(Progress.self, from: data) else { return Progress() }
        return progress
    }

    private func save(_ progress: Progress) {
        try? JSONEncoder().encode(progress).write(to: stateURL, options: .atomic)
    }

    // MARK: - 받기

    private struct Track {
        let name: String
        let list: HLSPlaylist.Media
        let file: URL
    }

    private func run() async -> WebDownloads.TransferOutcome {
        let session = WebFetch.session(cookies: cookies)
        defer { session.finishTasksAndInvalidate() }
        do {
            // 1. 목록: 마스터면 가장 좋은 화질과 그 소리 트랙
            let top = try await playlist(media.url, session: session)
            var lists: [(name: String, url: URL, list: HLSPlaylist.Media)] = []
            switch top {
            case .media(let list):
                lists.append(("video", media.url, list))
            case .master(let variants, let audio):
                guard let best = variants.best else { return .fail("화질별 목록이 없습니다") }
                guard case .media(let list) = try await playlist(best.url, session: session) else { return .fail("목록이 올바르지 않습니다") }
                lists.append(("video", best.url, list))
                if let group = best.audioGroup {
                    let candidates = audio.filter { $0.groupID == group && $0.url != nil }
                    if let rendition = candidates.first(where: \.isDefault) ?? candidates.first, let url = rendition.url,
                       case .media(let audioList) = try await playlist(url, session: session) {
                        lists.append(("audio", url, audioList))
                    }
                }
            }
            if lists.contains(where: { $0.list.hasDRM }) { return .fail("DRM 영상은 받을 수 없습니다") }
            // 키 주소가 http(s) 가 아니면 표준 HLS 가 아니다
            if lists.contains(where: { $0.list.segments.contains { $0.key.map { !["http", "https"].contains($0.url.scheme ?? "") } ?? false } }) {
                return .fail(Self.nonstandardMessage)
            }
            if lists.contains(where: { $0.list.isLive }) { return .fail("라이브 방송은 아직 받을 수 없습니다") }

            // 2. 받던 것이 있으면 이어서
            let manager = FileManager.default
            var progress = Progress()
            // 바뀜 (2026-11-09, 사용자): 영상 목록의 지문(조각 수·조각 길이)이 받던 것과 다르면 다른 영상 — 처음부터
            let print = lists.first.flatMap { WebFingerprint.hls($0.list) }
            let earlier = WebDownloads.meta(folder)?.fingerprint
            // 바뀜 (2026-11-09): 쿼리(서명)만 바뀐 같은 영상도 이어 받는다 — 조각 수·길이가 같아야 하고, 다르면 처음부터
            if manager.fileExists(atPath: folder.path), let meta = WebDownloads.meta(folder), meta.canResume(media) {
                progress = loadProgress()
                let sameContent = lists.allSatisfy { entry in
                    guard let saved = progress.tracks[entry.name] else { return true }
                    // 예전 진행(조각 수·길이를 안 적던 것)은 주소(쿼리 뗀 것)만 보고 믿는다
                    guard let total = saved.total, let duration = saved.duration else { return saved.segments <= entry.list.segments.count }
                    return total == entry.list.segments.count && abs(duration - Self.duration(entry.list)) < 0.5
                }
                if !sameContent || (earlier != nil && print != nil && earlier != print) {
                    WebLog.write("HLS 이어받기: 받던 것과 내용이 달라 처음부터 (\(earlier ?? "-") → \(print ?? "-"))")
                    progress = Progress()
                }
            } else {
                try? manager.removeItem(at: folder)
                try manager.createDirectory(at: folder, withIntermediateDirectories: true)
            }
            var meta = WebDownloads.Meta(media: media)
            meta.fingerprint = print ?? media.fingerprint
            WebDownloads.setMeta(meta, on: folder)
            let tracks = lists.map { entry in
                Track(name: entry.name, list: entry.list, file: folder.appending(path: "\(entry.name).\(Self.fileExtension(entry.list))"))
            }
            let totalSegments = tracks.reduce(0) { $0 + $1.list.segments.count }
            var doneSegments = tracks.reduce(0) { $0 + min(progress.tracks[$1.name]?.segments ?? 0, $1.list.segments.count) }
            var bytes = tracks.reduce(Int64(0)) { $0 + (progress.tracks[$1.name]?.bytes ?? 0) }
            await report(done: doneSegments, total: totalSegments, bytes: bytes, note: nil)

            // 3. 트랙마다 조각을 받아 이어 쓴다
            // 바뀜 (2026-11-11, 사용자: 진행률·속도가 몰려서 한 번에): 진행은 파일에 쓸 때가 아니라 받는 대로 (ReceiveMeter), 0.5초마다 알린다
            var keys: [URL: Data] = [:]
            let meter = ReceiveMeter(bytes: bytes, segments: doneSegments)
            let reporter = Task { [weak self] in
                while !Task.isCancelled {
                    let now = meter.snapshot
                    await self?.report(done: now.segments, total: totalSegments, bytes: now.bytes, speed: meter.speed(at: now.bytes), note: nil)
                    try? await Task.sleep(for: .milliseconds(500))
                }
            }
            defer { reporter.cancel() }
            for track in tracks {
                let resume = progress.tracks[track.name] ?? .init(segments: 0, bytes: 0)
                if !manager.fileExists(atPath: track.file.path) { manager.createFile(atPath: track.file.path, contents: nil) }
                let handle = try FileHandle(forWritingTo: track.file)
                defer { try? handle.close() }
                try handle.truncate(atOffset: UInt64(resume.bytes))
                try handle.seekToEnd()
                var written = resume.bytes
                let segments = track.list.segments
                // 이어 받을 때도 첫 조각이 쓰던 초기화 조각(EXT-X-MAP)은 이미 써 두었다
                var lastMap = resume.segments > 0 ? segments[min(resume.segments, segments.count) - 1].map : nil

                try await withThrowingTaskGroup(of: (Int, Data).self) { group in
                    var next = resume.segments
                    var writeIndex = resume.segments
                    var buffer: [Int: Data] = [:]
                    let window = 6
                    while next < segments.count, next < resume.segments + window {
                        let index = next, request = WebFetch.request(segments[index].url, for: media, range: segments[index].byteRange?.header)
                        group.addTask { (index, try await WebFetch.dataRetrying(request, session: session, meter: meter)) }
                        next += 1
                    }
                    while let (index, data) = try await group.next() {
                        buffer[index] = data
                        // 순서대로 쓸 수 있는 만큼 쓴다
                        while let data = buffer.removeValue(forKey: writeIndex) {
                            let segment = segments[writeIndex]
                            if let map = segment.map, map != lastMap {
                                let initData = try await WebFetch.dataRetrying(
                                    WebFetch.request(map.url, for: media, range: map.byteRange?.header), session: session)
                                try handle.write(contentsOf: initData)
                                written += Int64(initData.count)
                                lastMap = map
                            }
                            // 조각 앞에 영상이 아닌 머리가 붙어 있으면 떼어 낸다 (unwrap)
                            var payload = Self.unwrap(data)
                            if let key = segment.key {
                                if keys[key.url] == nil {
                                    keys[key.url] = try await WebFetch.dataRetrying(WebFetch.request(key.url, for: media), session: session)
                                }
                                payload = Self.unwrap(try Self.decrypt(payload, key: keys[key.url]!, iv: key.iv ?? Self.sequenceIV(segment.sequence)))
                            }
                            try handle.write(contentsOf: payload)
                            written += Int64(payload.count)
                            bytes += Int64(payload.count)
                            writeIndex += 1
                            doneSegments += 1
                            progress.tracks[track.name] = .init(segments: writeIndex, bytes: written,
                                                                total: segments.count, duration: Self.duration(track.list))
                            save(progress)
                        }
                        if next < segments.count {
                            let index = next, request = WebFetch.request(segments[index].url, for: media, range: segments[index].byteRange?.header)
                            group.addTask { (index, try await WebFetch.dataRetrying(request, session: session, meter: meter)) }
                            next += 1
                        }
                    }
                }
            }

            // 4. 묶기
            reporter.cancel()
            await report(done: doneSegments, total: totalSegments, bytes: bytes, speed: 0, note: "영상 묶는 중")
            let output = folder.appending(path: "output.mp4")
            let made = try await FFmpeg.mux(tracks.map(\.file), to: output)
            return .done(made)
        } catch is CancellationError {
            return .fail("멈춤")
        } catch let failure as WebFetch.Failure where failure.isPermanent {
            return .fail(failure.localizedDescription)
        } catch let failure as FFmpeg.Failure {
            return .fail(failure.localizedDescription)
        } catch is DecryptFailure {
            // 키로 풀리지 않음 = 표준 HLS 가 아니다
            return .fail(Self.nonstandardMessage)
        } catch {
            if (error as NSError).code == NSURLErrorCancelled { return .fail("멈춤") }
            return .retry(error.localizedDescription)
        }
    }

    private static func duration(_ list: HLSPlaylist.Media) -> Double {
        list.segments.reduce(0) { $0 + $1.duration }
    }

    private func playlist(_ url: URL, session: URLSession) async throws -> HLSPlaylist {
        let data = try await WebFetch.dataRetrying(WebFetch.request(url, for: media), session: session)
        guard let text = String(data: data, encoding: .utf8), let playlist = HLSPlaylist.parse(text, base: url) else {
            throw WebFetch.Failure.status(0)
        }
        return playlist
    }

    @MainActor
    private func report(done: Int, total: Int, bytes: Int64, speed: Double? = nil, note: String?) {
        item.segmentsDone = done
        item.segmentsTotal = total
        item.received = bytes
        if let speed { item.speed = speed }
        item.note = note
    }

    // MARK: - 도우미

    /// 트랙 파일 확장자: fMP4(EXT-X-MAP)면 mp4, 소리만 있는 조각(aac·mp3)이면 그것, 나머지는 ts
    private static func fileExtension(_ list: HLSPlaylist.Media) -> String {
        if list.segments.first?.map != nil { return "mp4" }
        let ext = list.segments.first?.url.pathExtension.lowercased() ?? ""
        return ["aac", "mp3", "ac3", "ec3"].contains(ext) ? ext : "ts"
    }

    /// IV 가 없으면 미디어 순번을 16바이트 빅엔디언으로
    static func sequenceIV(_ sequence: Int) -> Data {
        var iv = Data(count: 16)
        var value = UInt64(sequence).bigEndian
        withUnsafeBytes(of: &value) { iv.replaceSubrange(8..<16, with: $0) }
        return iv
    }

    /// 표준대로 받을 수 있는 HLS 인지: 키 주소가 http(s) 이고, 첫 조각 앞부분을 (키로 풀어) 보면 영상 조각 모양
    /// (TS 동기 바이트 0x47 이 188 바이트마다, 또는 MP4 상자 ftyp·styp·moof·sidx, 또는 ADTS 소리)인지.
    /// 표준 HLS 가 아니면 받기 단추 대신 재생하며 받기를 쓴다. 확인을 못 하면(네트워크 등) 표준으로 본다
    static func looksStandard(_ list: HLSPlaylist.Media, media: WebMedia, session: URLSession) async -> Bool {
        guard let first = list.segments.first else { return true }
        if let key = first.key, !["http", "https"].contains(key.url.scheme ?? "") { return false }
        let start = first.byteRange?.offset ?? 0
        let range = "bytes=\(start)-\(start + 4095)"
        guard var head = try? await WebFetch.data(WebFetch.request(first.url, for: media, range: range), session: session) else { return true }
        // 조각 앞에 붙은 영상이 아닌 머리는 떼고 본다 (받을 때도 뗀다)
        head = unwrap(head)
        head = head.prefix(head.count / 16 * 16)
        if let key = first.key {
            guard let keyData = try? await WebFetch.data(WebFetch.request(key.url, for: media), session: session),
                  let plain = try? HLSReceiver.decrypt(head.prefix(head.count / 16 * 16), key: keyData,
                                                      iv: key.iv ?? HLSReceiver.sequenceIV(first.sequence), padding: false) else { return false }
            head = plain
        }
        let bytes = [UInt8](head)
        if bytes.count > 376, bytes[0] == 0x47, bytes[188] == 0x47 { return true }
        if bytes.count >= 8, let box = String(bytes: bytes[4..<8], encoding: .ascii), ["ftyp", "styp", "moof", "sidx"].contains(box) { return true }
        if bytes.count >= 2, bytes[0] == 0xFF, bytes[1] & 0xF0 == 0xF0 { return true }
        if bytes.count >= 3, bytes[0] == 0x49, bytes[1] == 0x44, bytes[2] == 0x33 { return true }   // ID3 머리 (소리 조각)
        return first.map != nil   // fMP4 는 조각만으로는 모양이 다를 수 있다
    }

    /// 조각 앞에 영상이 아닌 데이터(작은 PNG 등)가 붙어 있는 경우.
    /// PNG 면 IEND 상자(+CRC)까지 떼고, 그 밖에 0x47 로 시작하지 않으면 앞 64KB 안에서 TS 동기 바이트(188 간격 세 번)를 찾아 그 앞을 뗀다
    static func unwrap(_ data: Data) -> Data {
        let head = [UInt8](data.prefix(65536))
        if head.starts(with: [0x89, 0x50, 0x4E, 0x47]), let end = data.range(of: Data("IEND".utf8)) {
            let cut = data.distance(from: data.startIndex, to: end.upperBound) + 4
            if cut < data.count { return Data(data.dropFirst(cut)) }
        }
        guard head.first != 0x47, head.count > 376 else { return data }
        for index in 0..<(head.count - 376) where head[index] == 0x47 && head[index + 188] == 0x47 && head[index + 376] == 0x47 {
            return Data(data.dropFirst(index))
        }
        return data
    }

    static let nonstandardMessage = "표준이 아닌 방식의 영상입니다 — 재생하며 받기로 받으세요"

    /// AES-128-CBC. padding 이 false 면 앞부분만 풀어 볼 때 (16바이트 배수)
    static func decrypt(_ data: Data, key: Data, iv: Data, padding: Bool = true) throws -> Data {
        guard key.count == kCCKeySizeAES128 else { throw WebFetch.Failure.status(0) }
        var output = Data(count: data.count + kCCBlockSizeAES128)
        var length = 0
        let capacity = output.count
        let status = output.withUnsafeMutableBytes { out in
            data.withUnsafeBytes { input in
                key.withUnsafeBytes { keyBytes in
                    iv.withUnsafeBytes { ivBytes in
                        CCCrypt(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(padding ? kCCOptionPKCS7Padding : 0),
                                keyBytes.baseAddress, key.count, ivBytes.baseAddress,
                                input.baseAddress, data.count, out.baseAddress, capacity, &length)
                    }
                }
            }
        }
        guard status == kCCSuccess else { throw DecryptFailure() }
        output.count = length
        return output
    }

    struct DecryptFailure: LocalizedError {
        var errorDescription: String? { "암호를 풀지 못했습니다 (키가 맞지 않음)" }
    }
}
