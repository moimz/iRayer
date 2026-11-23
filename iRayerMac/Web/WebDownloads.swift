import AppKit
import Observation

/// 웹에서 받는 영상들 (다운로드 화면·감지 패널이 같이 본다). 앱을 끄면 목록은 사라지고 받은 파일만 남는다.
///
/// 받는 동안은 저장 폴더에 `이름.mp4.irayer` 로 바로 써서 Finder 에서 보이고, 다 받으면 `.irayer` 를 뗀다.
/// 끊기면 몇 번 저절로 이어 받고, 중지·실패하면 부분 파일을 남겨 [이어받기] 로 남은 곳만 받는다.
/// 부분 파일에는 원본이 같은지 가릴 정보(감지 키·ETag·Last-Modified·전체 크기)를 확장 속성으로 붙여 둔다 —
/// 앱을 다시 켜고 같은 영상을 받아도 이어 받고, 원본이 바뀌었으면 처음부터 받는다. 쿠키·요청 헤더는 남기지 않는다.
@MainActor
@Observable
final class WebDownloads {
    static let shared = WebDownloads()

    static let partialExtension = "irayer"

    /// 한 번의 받기 결과
    enum TransferOutcome {
        /// 다 받음: 만든 파일 (이것을 최종 이름으로 옮긴다)
        case done(URL)
        /// 다시 시도해 볼 만한 실패
        case retry(String)
        case fail(String)
    }

    @MainActor
    @Observable
    final class Item: Identifiable {
        enum State: Equatable {
            case running
            /// 연결이 끊겨 잠시 뒤 다시 시도 (몇 번째)
            case retrying(Int)
            /// 사용자가 멈춤 (부분 파일은 남는다)
            case stopped
            case done
            case failed(String)
        }

        @ObservationIgnored let id = UUID()
        @ObservationIgnored let media: WebMedia
        /// 다 받은 뒤의 파일
        var file: URL
        var state = State.running
        var received: Int64 = 0
        var total: Int64?
        /// 초당 바이트 (받는 중에만)
        var speed: Double = 0
        /// HLS·DASH: 받은 조각 수 / 전체 조각 수
        var segmentsDone = 0
        var segmentsTotal = 0
        /// 지금 하는 일 ("영상 묶는 중" 등)
        var note: String?
        @ObservationIgnored var receiver: (any WebTransfer)?

        init(media: WebMedia, file: URL) {
            self.media = media
            self.file = file
            total = media.size
        }

        /// 받는 동안의 파일
        var partial: URL { file.appendingPathExtension(WebDownloads.partialExtension) }

        var progress: Double? {
            if segmentsTotal > 0 { return Double(segmentsDone) / Double(segmentsTotal) }
            guard let total, total > 0 else { return nil }
            return min(Double(received) / Double(total), 1)
        }

        var isActive: Bool {
            switch state {
            case .running, .retrying: true
            default: false
            }
        }
    }

    private(set) var items: [Item] = []

    /// 이 영상을 받는 중이거나 받은 것 (감지 패널의 단추 상태)
    func item(for media: WebMedia) -> Item? {
        items.first { $0.media.id == media.id }
    }

    /// 받기 시작. 같은 영상의 부분 파일이 저장 폴더에 있으면 거기서 이어 받는다
    func start(_ media: WebMedia) {
        guard media.isDownloadable else { return }
        if let item = item(for: media), !item.isActive, item.state != .done {
            resume(item)
            return
        }
        // 바뀜 (2026-11-09): 페이지를 다시 열어 주소의 서명 쿼리만 바뀐 같은 영상이면, 멈춰 있던 줄을 빼고 새 주소로 이어 받는다
        // 바뀜 (2026-11-09, 사용자): 지문이 둘 다 있으면 지문으로 (WebDownloads.Meta.canResume 과 같은 기준)
        items.removeAll { item in
            guard !item.isActive, item.state != .done, item.media.id != media.id else { return false }
            if let mine = item.media.fingerprint, let theirs = media.fingerprint { return mine == theirs }
            return item.media.resumeKey == media.resumeKey
        }
        let folder = WebDownloadSettings.shared.folder
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let item = Item(media: media, file: Self.destination(for: media, in: folder))
        items.insert(item, at: 0)
        run(item, attempt: 0)
    }

    /// 멈춘·실패한 것을 이어 받기
    func resume(_ item: Item) {
        guard !item.isActive else { return }
        run(item, attempt: 0)
    }

    /// 멈춤 (부분 파일은 남겨 이어 받을 수 있게)
    func stop(_ item: Item) {
        item.receiver?.cancel()
        item.receiver = nil
        item.state = .stopped
        item.speed = 0
    }

    /// 끝났거나 멈춘 것을 목록에서 뺀다 (파일·부분 파일은 그대로)
    func clearFinished() {
        items.removeAll { !$0.isActive }
        // 바뀜 (2026-11-09): iCloud 로 올린 지난 기록도 (아이폰·아이패드에서 보이는 것)
        WebDownloadStatus.shared.clearHistory()
    }

    /// 다른 기기에서 끝난 항목을 지웠을 때 그 항목만 목록에서 뺀다 (받는 중이면 둔다, 2026-11-09)
    func removeFinished(id: UUID) {
        items.removeAll { $0.id == id && !$0.isActive }
    }

    /// 부분 파일을 지우고 목록에서도 뺀다
    func discard(_ item: Item) {
        stop(item)
        try? FileManager.default.removeItem(at: item.partial)
        items.removeAll { $0.id == item.id }
    }

    func reveal(_ item: Item) {
        let target = item.state == .done ? item.file : item.partial
        NSWorkspace.shared.activateFileViewerSelecting([target])
    }

    // MARK: - 받기

    private func run(_ item: Item, attempt: Int) {
        item.state = attempt == 0 ? .running : .retrying(attempt)
        Task {
            let cookies = await WebBrowser.cookies()
            guard item.isActive else { return }
            item.state = .running
            item.note = nil
            let done: @MainActor (TransferOutcome) -> Void = { [weak self] outcome in
                self?.finished(item, outcome: outcome, attempt: attempt)
            }
            let receiver: any WebTransfer = item.media.kind == .hls
                ? HLSReceiver(item: item, cookies: cookies, completion: done)
                : Receiver(item: item, cookies: cookies, completion: done)
            item.receiver = receiver
            receiver.start()
        }
    }

    private func finished(_ item: Item, outcome: TransferOutcome, attempt: Int) {
        guard item.receiver != nil else { return }   // 사용자가 멈춤
        item.receiver = nil
        item.speed = 0
        item.note = nil
        switch outcome {
        case .done(let made):
            // 다 받았으면 최종 이름으로 (.irayer 를 뗀다, MKV 로 묶였으면 확장자도. 그사이 같은 이름이 생겼으면 피해서)
            var target = item.file
            // 묶으면서 만든 파일(HLS)만 확장자를 따른다 (파일 그대로 받은 것은 받는 중 이름이 .irayer 라 따르면 안 된다)
            if made != item.partial, made.pathExtension != target.pathExtension {
                target = target.deletingPathExtension().appendingPathExtension(made.pathExtension)
            }
            let final = FileManager.default.fileExists(atPath: target.path) ? Self.unique(target) : target
            do {
                try FileManager.default.moveItem(at: made, to: final)
                Self.clearMeta(final)
                // HLS 는 조각을 모으던 .irayer 폴더를 지운다
                if made != item.partial { try? FileManager.default.removeItem(at: item.partial) }
                item.file = final
                item.state = .done
                // 바뀜 (2026-11-13, 사용자): 알림 제목은 "다운로드 완료" / "다운로드 실패"
                Notice.send(title: "다운로드 완료", body: final.lastPathComponent)
            } catch {
                item.state = .failed(error.localizedDescription)
                Self.noticeFailure(item, error.localizedDescription)
            }
        case .retry(let message):
            // 일시적인 끊김·408·429·5xx: 1·2·4·8초 뒤 최대 4번
            if attempt < 4 {
                item.state = .retrying(attempt + 1)
                Task {
                    try? await Task.sleep(for: .seconds(1 << attempt))
                    if case .retrying = item.state { run(item, attempt: attempt + 1) }
                }
            } else {
                item.state = .failed(message)
                Self.noticeFailure(item, message)
            }
        case .fail(let message):
            item.state = .failed(message)
            Self.noticeFailure(item, message)
        }
    }

    /// 바뀜 (2026-11-12, 사용자): 받기가 끝나거나 실패하면 아이폰·아이패드에 알림 (Notice)
    private static func noticeFailure(_ item: Item, _ message: String) {
        Notice.send(title: "다운로드 실패", body: "\(item.file.lastPathComponent) — \(message)")
    }

    // MARK: - 파일 이름·부분 파일

    /// 다 받은 뒤의 이름. 같은 영상의 부분 파일이 있으면 그 이름을 쓰고(이어받기), 없으면 겹치지 않는 이름
    private static func destination(for media: WebMedia, in folder: URL) -> URL {
        let first = folder.appending(path: media.fileName)
        let base = first.deletingPathExtension().lastPathComponent, ext = first.pathExtension
        for number in 1... {
            let name = number == 1 ? first.lastPathComponent : (ext.isEmpty ? "\(base) \(number)" : "\(base) \(number).\(ext)")
            let candidate = folder.appending(path: name)
            let partial = candidate.appendingPathExtension(partialExtension)
            if FileManager.default.fileExists(atPath: partial.path) {
                // 바뀜 (2026-11-09): 쿼리만 바뀐 같은 영상도 (canResume)
                if let meta = meta(partial), meta.canResume(media) { return candidate }
                continue
            }
            if !FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        }
        return first
    }

    private static func unique(_ url: URL) -> URL {
        let base = url.deletingPathExtension().lastPathComponent, ext = url.pathExtension
        let folder = url.deletingLastPathComponent()
        for number in 2... {
            let candidate = folder.appending(path: ext.isEmpty ? "\(base) \(number)" : "\(base) \(number).\(ext)")
            if !FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        }
        return url
    }

    /// 부분 파일에 붙여 두는 원본 정보 (쿠키·요청 헤더는 넣지 않는다)
    nonisolated struct Meta: Codable, Equatable {
        var key: String
        var total: Int64?
        var etag: String?
        var lastModified: String?
        /// 쿼리를 뗀 주소 (WebMedia.resumeKey, 2026-11-09 부터)
        var loose: String?
        /// 내용 지문 (WebFingerprint, 2026-11-09 부터, 사용자) — HLS 는 받는 쪽이 목록에서 만들어 적는다
        var fingerprint: String?

        init(media: WebMedia) {
            key = media.id
            total = media.size
            loose = media.resumeKey
            fingerprint = media.fingerprint
        }

        /// 이 부분 파일을 이 영상으로 이어 받아도 되는지: 주소가 같거나, 쿼리만 다른데 크기가 같거나 (HLS 는 크기가 없어 받는 쪽에서 조각 수·길이로 한 번 더 본다)
        /// 바뀜 (2026-11-09, 사용자): 지문이 둘 다 있으면 지문이 같은지로만 가른다 (주소 모양으로 짐작하지 않는다).
        ///   한쪽이라도 없으면(예전 부분 파일, 지문을 못 만든 영상) 예전대로
        func canResume(_ media: WebMedia) -> Bool {
            if key == media.id { return true }
            if let fingerprint, let theirs = media.fingerprint { return fingerprint == theirs }
            // 예전 표시(loose 없음)는 key 에서 쿼리를 떼어 본다
            let loose = loose ?? URLComponents(string: key).flatMap { parts -> String? in
                var parts = parts
                parts.query = nil
                return parts.url?.absoluteString
            }
            guard let loose, loose == media.resumeKey else { return false }
            if media.kind == .hls { return true }
            return total != nil && total == media.size
        }
    }

    nonisolated private static let metaName = "com.moimz.irayer.partial"

    nonisolated static func meta(_ url: URL) -> Meta? {
        let size = getxattr(url.path, metaName, nil, 0, 0, 0)
        guard size > 0 else { return nil }
        var data = Data(count: size)
        let read = data.withUnsafeMutableBytes { getxattr(url.path, metaName, $0.baseAddress, size, 0, 0) }
        guard read == size else { return nil }
        return try? JSONDecoder().decode(Meta.self, from: data)
    }

    nonisolated static func setMeta(_ meta: Meta, on url: URL) {
        guard let data = try? JSONEncoder().encode(meta) else { return }
        _ = data.withUnsafeBytes { setxattr(url.path, metaName, $0.baseAddress, data.count, 0, 0) }
    }

    nonisolated static func clearMeta(_ url: URL) {
        removexattr(url.path, metaName, 0)
    }

    // MARK: - 한 번의 요청 (Range 로 이어 받기)

    /// 부분 파일 끝에서부터 요청해 이어 쓴다. 파일 쓰기는 자기 큐에서, 화면 갱신은 0.25초마다 메인에서
    final class Receiver: NSObject, URLSessionDataDelegate, WebTransfer, @unchecked Sendable {
        typealias Outcome = TransferOutcome

        private let item: Item
        private let media: WebMedia
        private let partial: URL
        private let cookies: [HTTPCookie]
        private let completion: @MainActor (Outcome) -> Void
        private let queue = OperationQueue()
        private var session: URLSession?
        private var handle: FileHandle?
        /// 이어 받기 시작 위치와 지금까지 쓴 끝
        private var offset: Int64 = 0
        private var written: Int64 = 0
        private var total: Int64?
        private var failure: Outcome?
        private var lastReport = Date.distantPast
        private var speedMark = (time: Date(), bytes: Int64(0))
        private var speed: Double = 0

        @MainActor
        init(item: Item, cookies: [HTTPCookie], completion: @escaping @MainActor (Outcome) -> Void) {
            self.item = item
            media = item.media
            partial = item.partial
            self.cookies = cookies
            self.completion = completion
            queue.maxConcurrentOperationCount = 1
        }

        func start() {
            let manager = FileManager.default
            let meta = WebDownloads.meta(partial)
            // 바뀜 (2026-11-09): 쿼리만 바뀐 같은 영상도 이어 받고, 표시를 새 주소로 바꿔 둔다
            if manager.fileExists(atPath: partial.path), var meta, meta.canResume(media) {
                offset = (try? manager.attributesOfItem(atPath: partial.path)[.size] as? Int64) ?? 0
                if meta.key != media.id || (meta.fingerprint == nil && media.fingerprint != nil) {
                    meta.key = media.id
                    meta.loose = media.resumeKey
                    meta.fingerprint = meta.fingerprint ?? media.fingerprint
                    WebDownloads.setMeta(meta, on: partial)
                }
            } else {
                try? manager.removeItem(at: partial)
                manager.createFile(atPath: partial.path, contents: nil)
                WebDownloads.setMeta(Meta(media: media), on: partial)
                offset = 0
            }
            written = offset
            speedMark = (Date(), offset)

            let config = WebFetch.configuration(cookies: cookies)
            // 30초 동안 아무것도 안 오면 끊긴 것으로
            config.timeoutIntervalForRequest = 30
            var request = URLRequest(url: media.url)
            for (name, value) in media.headers { request.setValue(value, forHTTPHeaderField: name) }
            if request.value(forHTTPHeaderField: "Referer") == nil, let page = media.pageURL {
                request.setValue(page.absoluteString, forHTTPHeaderField: "Referer")
            }
            if offset > 0 {
                request.setValue("bytes=\(offset)-", forHTTPHeaderField: "Range")
                // 원본이 그대로일 때만 이어 받는다 (바뀌었으면 서버가 전체를 200 으로 준다)
                if let validator = meta?.etag ?? meta?.lastModified { request.setValue(validator, forHTTPHeaderField: "If-Range") }
            }
            session = URLSession(configuration: config, delegate: self, delegateQueue: queue)
            session?.dataTask(with: request).resume()
        }

        func cancel() {
            session?.invalidateAndCancel()
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
            guard let http = response as? HTTPURLResponse else {
                failure = .fail("응답이 올바르지 않습니다")
                return completionHandler(.cancel)
            }
            switch http.statusCode {
            case 206 where offset > 0:
                // 요청한 곳부터 왔는지 (bytes 시작-끝/전체)
                let range = http.value(forHTTPHeaderField: "Content-Range") ?? ""
                let start = Int64(String(range.drop(while: { !$0.isNumber }).prefix(while: \.isNumber))) ?? -1
                guard start == offset else {
                    failure = .fail("서버가 다른 구간을 보냈습니다")
                    return completionHandler(.cancel)
                }
                total = WebMediaClassifier.totalSize(http) ?? media.size
            case 200, 206:
                // 처음부터 (이어 받기를 안 받아 주거나 원본이 바뀜): 부분 파일을 비운다
                offset = 0
                written = 0
                speedMark = (Date(), 0)
                try? FileHandle(forWritingTo: partial).truncate(atOffset: 0)
                total = WebMediaClassifier.totalSize(http) ?? (http.expectedContentLength > 0 ? http.expectedContentLength : nil)
            case 401, 403, 404, 410:
                failure = .fail("서버가 거절했습니다 (\(http.statusCode))")
                WebLog.failure(dataTask, response: http, cookies: cookies, note: "\(http.statusCode)")
                return completionHandler(.cancel)
            case 408, 429, 500...599:
                failure = .retry("서버 응답 \(http.statusCode)")
                return completionHandler(.cancel)
            default:
                failure = .fail("서버 응답 \(http.statusCode)")
                return completionHandler(.cancel)
            }
            var meta = WebDownloads.meta(partial) ?? Meta(media: media)
            meta.total = total
            meta.etag = http.value(forHTTPHeaderField: "ETag")
            meta.lastModified = http.value(forHTTPHeaderField: "Last-Modified")
            WebDownloads.setMeta(meta, on: partial)
            handle = try? FileHandle(forWritingTo: partial)
            _ = try? handle?.seekToEnd()
            completionHandler(.allow)
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
            do {
                try handle?.write(contentsOf: data)
            } catch {
                failure = .fail("파일에 쓰지 못했습니다: \(error.localizedDescription)")
                dataTask.cancel()
                return
            }
            written += Int64(data.count)
            let now = Date()
            if now.timeIntervalSince(speedMark.time) >= 1 {
                speed = Double(written - speedMark.bytes) / now.timeIntervalSince(speedMark.time)
                speedMark = (now, written)
            }
            if now.timeIntervalSince(lastReport) >= 0.25 {
                lastReport = now
                report()
            }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            try? handle?.close()
            handle = nil
            report()
            let outcome: Outcome
            if let failure {
                outcome = failure
            } else if let error {
                // 사용자가 멈춘 것은 알리지 않는다
                if (error as NSError).code == NSURLErrorCancelled { return session.finishTasksAndInvalidate() }
                outcome = .retry(error.localizedDescription)
            } else if let total, written < total {
                outcome = .retry("다 받기 전에 끊겼습니다")
            } else {
                outcome = .done(partial)
            }
            session.finishTasksAndInvalidate()
            let completion = completion
            DispatchQueue.main.async { MainActor.assumeIsolated { completion(outcome) } }
        }

        private func report() {
            let written = written, total = total, speed = speed, item = item
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    item.received = written
                    if let total { item.total = total }
                    if item.isActive { item.speed = speed }
                }
            }
        }
    }
}

/// 받기 한 번 (파일 그대로·HLS): 시작하고, 멈출 수 있다. 끝나면 만들 때 받은 completion 을 부른다
protocol WebTransfer: AnyObject {
    func start()
    func cancel()
}
