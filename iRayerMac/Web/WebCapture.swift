import Foundation
import Observation
import WebKit

/// 재생하며 받기: 플레이어가 브라우저 재생 버퍼(MSE)에 넣는 데이터를 그대로 모아 영상 파일로 만든다.
/// 받기 단추로 받을 수 없는 비표준 플레이어도 브라우저가 재생하는 데이터를 그대로 저장한다.
/// DRM 은 버퍼에 들어가는 데이터도 암호화돼 있어 안 된다. MSE 를 쓰지 않는 플레이어(<video src> 직접 재생)는 해당 없음.
///
/// 켤 때만 페이지(모든 프레임, page world)에 스크립트를 넣고 새로고침한다. 받는 속도 = 재생 속도라 끝까지 재생해야 하고,
/// 중간에 건너뛰면 그 부분이 빠지거나 순서가 꼬일 수 있다. 영상이 끝나면 저절로 저장한다.
/// 데이터는 base64 로 넘어온다 (ArrayBuffer 는 메시지로 안 넘어가고, 앱 전용 주소는 https 페이지에서 막힘 — wk-probe 시험).
/// 바뀜 (2026-11-09, 사용자): 스크립트는 탭을 만들 때부터 모든 페이지에 늘 넣어 두고, 켤 때 새로고침하지 않는다.
///   꺼져 있는 동안 스크립트는 재생 버퍼마다 마지막 초기화 조각(몇 KB)만 들고 있다가, 켜면 그것부터 넘기고 이어서 들어오는 데이터를 넘긴다.
///   켜기 전에 버퍼에 들어가 있던 것은 못 받았으므로 버퍼를 비워 플레이어가 지금 자리부터 다시 받게 하고, 앞부분은 빈 구간으로 남겨 나중에 채운다.
///   받는 중에 페이지를 새로고침하면 새 플레이어가 길이가 같고 (같은 주소이거나 초기화 조각 바이트가 같으면) 앞서 받은 것과 같은 영상으로 보아 이어받는다
@MainActor
@Observable
final class WebCapture: NSObject {
    /// 바뀜 (2026-11-08): 앱에 하나 → 탭마다 하나 (그 탭의 웹뷰에서 모은다)
    @ObservationIgnored unowned let browser: WebBrowser

    init(browser: WebBrowser) {
        self.browser = browser
        super.init()
        // 바뀜 (2026-11-09, 사용자): 처음부터 늘 넣어 둔다 (켤 때 새로고침하지 않게). 꺼져 있으면 초기화 조각만 들고 아무것도 넘기지 않는다
        let controller = browser.webView.configuration.userContentController
        controller.add(WeakCaptureHandler(self), name: Self.handlerName)
        controller.addUserScript(Self.hookScript)
    }

    private static var hookScript: WKUserScript {
        WKUserScript(source: hook, injectionTime: .atDocumentStart, forMainFrameOnly: false)
    }
    /// 받는 중에 새로 열리는 페이지·프레임은 처음부터 켠 채로 (새로고침해도 이어서 받게)
    private static var autoOnScript: WKUserScript {
        WKUserScript(source: "window.__irayerAutoOn = true;", injectionTime: .atDocumentStart, forMainFrameOnly: false)
    }

    static let handlerName = "irayerCapture"
    /// 한 트랙 최대 (넘으면 그 트랙은 더 쓰지 않는다)
    static let trackLimit: Int64 = 8 << 30

    enum State: Equatable {
        case off
        /// 스크립트를 넣고 페이지를 다시 불렀다 — 플레이어가 버퍼를 만들기를 기다림
        case waiting
        case capturing
        case saving
        case saved([URL])
        case failed(String)
    }

    struct Track: Identifiable {
        /// 스크립트가 붙인 SourceBuffer 번호 (프레임마다 겹치지 않게 "프레임-번호")
        let id: String
        /// 같은 MediaSource (플레이어 하나) 의 트랙끼리 한 파일로 묶는다
        let source: String
        let mime: String
        let file: URL
        /// 들어온 fMP4 의 상자 색인 (쓰기 큐에서만 고친다). 저장할 때 시각 순 정렬·중복 빼기에 쓴다
        let index = FMP4Index()
        var bytes: Int64 = 0
        var chunks = 0
        var isVideo: Bool { mime.hasPrefix("video/") }
    }

    private(set) var state = State.off
    private(set) var tracks: [Track] = []
    /// 재생 버퍼로 재생 중인 영상의 지금 위치·전체 길이·받아 둔 끝 (iframe·shadow DOM 안이어도 — 가로채기 스크립트가 그 프레임에서 보고)
    struct Playback: Equatable {
        var time: Double
        /// 모르면(라이브·아직 안 정해짐) nil
        var duration: Double?
        /// 지금 위치가 든 buffered 구간의 끝
        var bufferedEnd: Double
        var paused: Bool
        var updatedAt: Date
        /// 지금 붙어 있는 재생 버퍼(MediaSource) — 모르면 nil
        var source: String? = nil
    }

    /// 영상마다 (프레임-번호). 패널에는 가장 그럴듯한 하나(재생 중, 긴 것)를 보인다
    private(set) var players: [String: Playback] = [:]
    /// 영상마다 붙었던 재생 버퍼(MediaSource)들 — 플레이어가 이동(빈 구간 채우기)할 때 재생 버퍼를 새로 만들면
    /// 같은 영상의 데이터가 새 트랙으로 들어온다. 이것들을 한 영상으로 보고 받은 구간·저장을 합친다 (2026-11-07)
    @ObservationIgnored private var playerSources: [String: Set<String>] = [:]
    /// 영상마다 처음 보였을 때의 탭 주소 (새로고침한 뒤의 같은 영상 알아보기, 2026-11-09)
    @ObservationIgnored private var playerPages: [String: String] = [:]
    /// 이 초 넘게 소식이 없는 영상은 사라진 것으로 (새로고침 전 페이지의 영상이 남아 이동 명령이 그리로 가던 것, 2026-11-09)
    private static let staleAfter: TimeInterval = 5
    /// 새로고침 뒤 앞서 받은 것을 이어받았다 — 받은 끝으로 한 번 건너뛴다
    @ObservationIgnored private var resumeJump = false
    /// 영상(플레이어)마다 마지막으로 받던 끝 — 새로고침 뒤 그 자리로 돌아간다 (2026-11-09, 사용자)
    @ObservationIgnored private var playerFrontiers: [String: Double] = [:]
    /// 새로고침 전에 받던 끝 (이어받을 때 건너뛸 곳)
    @ObservationIgnored private var resumeAt: Double?
    /// 스크립트가 들어간 프레임들 (켜고 끌 때 알린다). 큰 페이지가 새로 열리면 비운다
    @ObservationIgnored private var knownFrames: [String: WKFrameInfo] = [:]

    private var livePlayers: [String: Playback] {
        let now = Date()
        return players.filter { now.timeIntervalSince($0.value.updatedAt) < Self.staleAfter }
    }

    var playback: Playback? {
        let live = livePlayers
        return (live.isEmpty ? players : live).values.max { a, b in
            if a.paused != b.paused { return a.paused }
            return (a.duration ?? 0) < (b.duration ?? 0)
        }
    }
    private(set) var title = ""

    // MARK: 당겨 받기 (통통통)

    /// 받기 속도: 받기 시작한 뒤 흐른 시간 × 이 배수 분량까지 미리 받는다 (화면 재생 속도는 그대로).
    /// 받은 끝이 한도에 못 미치고 플레이어가 받기를 쉬면, 받은 끝 바로 뒤로 이동시켜 다음 조각을 받게 한다
    static let speeds: [Double] = [1, 1.5, 2, 3, 4, 6, 8]
    var speed: Double = UserDefaults.standard.object(forKey: "captureSpeed") as? Double ?? 1.5 {
        didSet {
            UserDefaults.standard.set(speed, forKey: "captureSpeed")
            anchor = nil   // 바꾼 때부터 새로 센다
        }
    }
    /// 로딩 멈춤 감지: 재생 중인데 위치가 이 초 넘게 그대로면 5초 건너뛴다 (0 은 안 씀). 기본 20초 (사용자, 2026-11-08)
    static let stallLimits: [Int] = [0, 10, 20, 30, 60]
    var stallLimit: Int = UserDefaults.standard.object(forKey: "captureStallLimit") as? Int ?? 20 {
        didSet { UserDefaults.standard.set(stallLimit, forKey: "captureStallLimit") }
    }
    /// 재생 오류 시 자동 새로고침 (2026-11-09, 사용자): 끄면 멈춤이 이어져도 건너뛰기만 하고, 저장 전 새로고침도 하지 않는다. 기본 켬
    var autoReload: Bool = UserDefaults.standard.object(forKey: "captureAutoReload") as? Bool ?? true {
        didSet { UserDefaults.standard.set(autoReload, forKey: "captureAutoReload") }
    }
    /// 첫 조각이 들어온 때 (패널의 경과 시간)
    private(set) var receivedSince: Date?
    /// 지금 위치부터 끊김 없이 받은 끝 (모든 트랙 중 가장 짧은 것)
    private(set) var frontier: Double?
    /// 받지 못한 구간 (0 ~ 전체 길이 중, 아직 안 받은 뒷부분 포함)
    private(set) var gaps: [ClosedRange<Double>] = []
    /// 화면에 보일 진짜 빈 구간: 지금 받고 있는 끝(끊김 없이 받은 곳)부터 영상 끝까지인 남은 뒷부분은 뺀다 (건너뛰어 생긴 구멍만.
    /// 구멍을 채우는 중이면 그 구멍은 끝이 영상 끝이 아니라 그대로 센다)
    var holes: [ClosedRange<Double>] {
        guard let frontier, let duration = playback?.duration else { return gaps }
        return gaps.filter { !(abs($0.lowerBound - frontier) <= 1 && $0.upperBound >= duration - 0.5) }
    }
    /// 저장할 때 남아 있던 빈 구간 (저장한 뒤에도 패널·다운로드 목록에 보인다, 2026-11-09 사용자)
    private(set) var savedHoles: [ClosedRange<Double>] = []
    /// 빈 구간을 채우는 중
    private(set) var fillingGaps = false
    /// 채우러 간 구간 모두 (새로고침해 한 번 더 가도 지우지 않는다) — 패널의 "재시도 1/3" (2026-11-09, 사용자)
    @ObservationIgnored private var allTries: [ClosedRange<Double>] = []

    /// 그 빈 구간을 채우러 간 횟수 (지금 가 있는 것 포함)
    func attempts(at gap: ClosedRange<Double>) -> Int { allTries.filter { $0.overlaps(gap) }.count }
    /// 한 빈 구간에 가 보는 최대 횟수: 두 번 + 자동 새로고침이 켜져 있으면 새로고침 뒤 한 번
    var attemptLimit: Int { 2 + (autoReload ? 1 : 0) }

    @ObservationIgnored private var anchor: (wall: Date, content: Double)?
    /// 빈 구간(시작 초)마다 채우러 간 횟수 — 두 번 가도 안 채워지면(낮은 화질만 오면) 포기하고 있는 것으로 저장
    /// 바뀜 (2026-11-09): 시작 초로 세면 조금 채워지거나 쪼개져 시작이 바뀔 때마다 0 부터 다시 세어 끝없이 돌았다 (수 GB) →
    ///   채우러 간 구간들을 적어 두고, 빈 구간과 겹치는 것의 개수로 센다. 모두 합쳐 maxGapTries 번이면 그만
    @ObservationIgnored private var gapTries: [ClosedRange<Double>] = []
    /// 구간마다 채우러 가는 횟수 (새로고침한 뒤 한 번 더 갈 때는 1, 2026-11-09)
    @ObservationIgnored private var triesPerGap = 2
    private static let maxGapTries = 30
    /// 멈춤이 이어지면 저절로 새로고침 (2026-11-09, 사용자): 로딩 멈춤으로 건너뛴 횟수(연달아)·마지막 건너뛴 때·마지막 새로고침
    @ObservationIgnored private var stallStreak = 0
    @ObservationIgnored private var lastStallSkip = Date.distantPast
    @ObservationIgnored private var lastReload = Date.distantPast
    private static let reloadAfterStalls = 3
    private static let reloadInterval: TimeInterval = 180
    /// 빈 구간이 안 채워져 저장 전에 새로고침했다 (한 번만)
    @ObservationIgnored private var reloadedForFill = false
    /// 새로고침하고 같은 영상을 이어받기를 기다리는 중 (그동안은 새 플레이어의 받은 구간만 보고 판단하지 않게)
    @ObservationIgnored private var waitingReload: Date?
    /// 끝까지 한 번 받았다 (이제부터는 빈 구간 채우기 — 로딩 멈춤 감지로 건너뛰지 않는다)
    @ObservationIgnored private var reachedEnd = false
    /// 지금 채우러 간 빈 구간
    /// 바뀜 (2026-11-09, 사용자): 패널에 "14:23 채우는 중" 으로 보이게 밖에서 읽는다
    private(set) var fillTarget: ClosedRange<Double>?
    /// 트랙마다 마지막으로 들어온 데이터 (멈춘 플레이어가 같은 조각을 되풀이해 넣는 것은 쓰지 않는다, 2026-11-09)
    @ObservationIgnored private var lastChunks: [String: String] = [:]
    @ObservationIgnored private var repeatedChunks = 0
    @ObservationIgnored private var lastSeek = Date.distantPast
    @ObservationIgnored private var lastBuffered: (end: Double, changedAt: Date) = (0, .distantPast)
    /// 재생 위치가 마지막으로 바뀐 때 (멈춘 채 오래 있으면 건너뛰려고)
    @ObservationIgnored private var lastTime: (time: Double, changedAt: Date) = (-1, .distantPast)
    @ObservationIgnored private var controller: Timer?
    /// 영상(프레임-번호)마다 그 프레임 — 이동 명령을 그 프레임에 보낸다 (iframe 안 플레이어도)
    @ObservationIgnored private var frames: [String: WKFrameInfo] = [:]

    /// 트랙 파일을 모으는 곳: 저장 폴더/제목.mp4.irayer/
    @ObservationIgnored private var folder: URL?
    @ObservationIgnored private var handles: [String: FileHandle] = [:]
    /// base64 풀기·파일 쓰기는 메인 밖에서 순서대로
    @ObservationIgnored private let writer = DispatchQueue(label: "iRayer.capture.writer")

    var isOn: Bool {
        switch state {
        case .waiting, .capturing: true
        default: false
        }
    }

    // MARK: - 켜고 끄기

    /// 켜기: 스크립트를 넣고 지금 페이지를 다시 부른다 (처음 조각·초기화 조각부터 모으려고)
    /// 바뀜 (2026-11-09, 사용자): 새로고침하지 않고, 늘 들어가 있는 스크립트에 켜라고 알린다 (지금 보던 자리부터)
    func start() {
        guard !isOn, browser.url != nil else { return }
        title = Self.safe(browser.title ?? browser.url?.host() ?? "영상")
        let base = WebDownloadSettings.shared.folder
        let folder = Self.uniqueFolder(base.appending(path: "\(title).mp4.\(WebDownloads.partialExtension)"))
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            state = .failed("저장 폴더를 만들지 못했습니다: \(error.localizedDescription)")
            return
        }
        self.folder = folder
        tracks = []
        handles = [:]
        players = [:]
        playerSources = [:]
        playerPages = [:]
        resumeJump = false
        playerFrontiers = [:]
        resumeAt = nil
        frames = [:]
        frontier = nil
        gaps = []
        savedHoles = []
        fillingGaps = false
        anchor = nil
        gapTries = []
        allTries = []
        triesPerGap = 2
        stallStreak = 0
        lastStallSkip = .distantPast
        lastReload = .distantPast
        reloadedForFill = false
        waitingReload = nil
        reachedEnd = false
        fillTarget = nil
        lastChunks = [:]
        repeatedChunks = 0
        lastSeek = .distantPast
        lastTime = (-1, .distantPast)
        receivedSince = nil
        state = .waiting
        browser.webView.configuration.userContentController.addUserScript(Self.autoOnScript)
        WebLog.write("재생하며 받기: 시작 (\(browser.url?.absoluteString ?? "-"), 스크립트가 든 프레임 \(knownFrames.count)개)")
        tell("window.__irayerStart && window.__irayerStart()")
        self.controller = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    /// 그만 모으고 (save 면) 모은 것을 영상 파일로
    func stop(save: Bool) {
        guard isOn else { return }
        // 바뀜 (2026-11-09, 사용자): 남은 빈 구간을 기억해 저장한 뒤에도 보여 준다 (끄고 나면 재생 위치를 몰라 지금 계산해 둔다)
        savedHoles = save ? holes : []
        detach()
        guard save, tracks.contains(where: { $0.bytes > 0 }) else {
            discardFolder()
            state = .off
            return
        }
        state = .saving
        let tracks = tracks, folder = folder, title = title
        writer.async { [weak self] in
            // 쓰던 것을 다 쓴 뒤
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.closeHandles() }
                Task { await self?.save(tracks: tracks, folder: folder, title: title) }
            }
        }
    }

    /// 저장 결과를 지우고 처음 상태로
    func reset() {
        if case .saving = state { return }
        if isOn { stop(save: false) }
        state = .off
        tracks = []
        savedHoles = []
    }

    /// 바뀜 (2026-11-09): 스크립트는 그대로 두고 끄라고만 알린다 (받는 중에 넣은 "처음부터 켜기" 스크립트만 뺀다)
    private func detach() {
        self.controller?.invalidate()
        self.controller = nil
        let controller = browser.webView.configuration.userContentController
        controller.removeAllUserScripts()
        controller.addUserScript(Self.hookScript)
        tell("window.__irayerStop && window.__irayerStop()")
    }

    /// 스크립트가 든 모든 프레임에 (없어진 프레임은 저절로 실패)
    private func tell(_ script: String) {
        for frame in knownFrames.values {
            browser.webView.callAsyncJavaScript(script, arguments: [:], in: frame, in: .page) { _ in }
        }
    }

    /// 원격 (2026-11-10, 사용자): 스크립트가 든 프레임에서 돌려 결과 글을 모은다.
    /// frameURL 이 있으면 그 주소(# 뒤 빼고)의 프레임, 없으면 같은 호스트의 프레임, 그래도 없으면 모든 프레임
    func run(_ script: String, arguments: [String: Any] = [:], frameURL: String? = nil) async -> [String] {
        var frames = Array(knownFrames.values)
        if let frameURL, let wanted = URL(string: frameURL) {
            let strip = { (url: URL?) in url.map { $0.absoluteString.components(separatedBy: "#")[0] } }
            let exact = frames.filter { strip($0.request.url) == strip(wanted) }
            let sameHost = frames.filter { $0.request.url?.host() == wanted.host() }
            frames = !exact.isEmpty ? exact : !sameHost.isEmpty ? sameHost : frames
        }
        var results: [String] = []
        for frame in frames {
            if let result = try? await browser.webView.callAsyncJavaScript(script, arguments: arguments, in: frame, contentWorld: .page) as? String {
                results.append(result)
            }
        }
        return results
    }

    private func closeHandles() {
        handles.values.forEach { try? $0.close() }
        handles = [:]
    }

    private func discardFolder() {
        let handles = handles, folder = folder
        self.handles = [:]
        writer.async {
            handles.values.forEach { try? $0.close() }
            if let folder { try? FileManager.default.removeItem(at: folder) }
        }
        self.folder = nil
    }

    // MARK: - 저장

    private func save(tracks: [Track], folder: URL?, title: String) async {
        guard let folder else { return }
        // 플레이어(MediaSource)마다 한 파일: 데이터가 있는 트랙만, 영상 먼저
        // 바뀜 (2026-11-07): 같은 영상에 붙었던 재생 버퍼들은 한 파일로, 같은 종류 트랙은 합쳐서 (빈 구간을 채운 데이터가 따로 저장되던 것)
        let playerSources = playerSources
        let groups = Dictionary(grouping: tracks.filter { $0.bytes > 0 }, by: { (track: Track) -> String in
            let player: String? = playerSources.first { $0.value.contains(track.source) }?.key
            return player ?? track.source
        })
        let ordered = groups.values.sorted { ($0.map(\.bytes).reduce(0, +)) > ($1.map(\.bytes).reduce(0, +)) }
        var made: [URL] = []
        do {
            for (index, group) in ordered.enumerated() {
                // 트랙마다: fMP4 면 시각 순으로 정렬하고 겹친 조각을 뺀 파일로 (화질이 바뀐 구간이 있으면 이어 붙여), 아니면 들어온 그대로
                var inputs: [URL] = []
                for video in [true, false] {
                    let same = group.filter { $0.isVideo == video }
                    if same.count > 1, same.allSatisfy({ !$0.index.unreadable && !$0.index.fragments.isEmpty }) {
                        inputs.append(try await Self.mergedTrack(same, folder: folder))
                    } else {
                        for track in same { inputs.append(try await Self.orderedTrack(track, folder: folder)) }
                    }
                }
                let output = folder.appending(path: "output-\(index).mp4")
                let file = try await FFmpeg.mux(inputs, to: output)
                let name = ordered.count == 1 ? title : "\(title) \(index + 1)"
                let target = Self.uniqueFile(folder.deletingLastPathComponent().appending(path: "\(name).\(file.pathExtension)"))
                try FileManager.default.moveItem(at: file, to: target)
                made.append(target)
            }
            try? FileManager.default.removeItem(at: folder)
            state = .saved(made)
            // 바뀜 (2026-11-13, 사용자): 알림 제목은 "다운로드 완료"
            Notice.send(title: "다운로드 완료", body: made.map(\.lastPathComponent).joined(separator: ", "))
            // 다 저장했으면 페이지 영상은 멈춘다 (2026-11-10, 사용자: 저장이 끝나도 계속 재생되고 있었다)
            await browser.webView.pauseAllMediaPlayback()
        } catch {
            // 원본 트랙은 지우지 않고 남겨 둔다 (직접 살펴볼 수 있게)
            state = .failed("\(error.localizedDescription) — 모은 트랙은 \(folder.lastPathComponent) 에 남겨 두었습니다")
            Notice.send(title: "다운로드 실패", body: "\(title) — \(error.localizedDescription)")
        }
    }

    /// 같은 종류 트랙 여럿을 하나로 합쳐 다시 쓴 파일
    private static func mergedTrack(_ tracks: [Track], folder: URL) async throws -> URL {
        let name = (tracks.first?.isVideo == true ? "video" : "audio") + "-merged"
        let runs = try FMP4Index.writeMerged(tracks.map { ($0.index, $0.file) }, into: folder, name: name)
        guard runs.count > 1 else { return runs.first ?? tracks[0].file }
        return try await FFmpeg.concat(runs, to: folder.appending(path: "\(name)-joined.mp4"))
    }

    /// 색인대로 다시 쓴 트랙 파일 (fMP4 가 아니거나 색인이 비면 원래 파일)
    private static func orderedTrack(_ track: Track, folder: URL) async throws -> URL {
        let index = track.index
        guard !index.unreadable, !index.fragments.isEmpty else { return track.file }
        let name = track.file.deletingPathExtension().lastPathComponent + "-sorted"
        let runs = try index.writeOrdered(from: track.file, into: folder, name: name)
        guard runs.count > 1 else { return runs.first ?? track.file }
        return try await FFmpeg.concat(runs, to: folder.appending(path: "\(name)-joined.mp4"))
    }

    // MARK: - 페이지에서 오는 데이터

    fileprivate func receive(_ message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let type = body["t"] as? String else { return }
        // 스크립트가 들어간 프레임 (꺼져 있어도 받는다). 큰 페이지가 새로 열리면 앞 페이지의 프레임들은 버린다
        if type == "hello" {
            guard let frame = body["frame"] as? String else { return }
            if message.frameInfo.isMainFrame { knownFrames = [:] }
            if knownFrames.count > 300 { knownFrames = [:] }
            knownFrames[frame] = message.frameInfo
            return
        }
        // 바뀜 (2026-11-12): 재생 버퍼가 생김 (꺼져 있어도) — 받을 주소를 못 찾은 페이지면 감지 목록에 올린다
        if type == "mse" {
            browser.noteMSEPlayer(mime: body["mime"] as? String ?? "")
            return
        }
        guard isOn else { return }
        switch type {
        case "add":
            guard let id = body["id"] as? String, let source = body["ms"] as? String, let folder,
                  !tracks.contains(where: { $0.id == id }) else { return }
            let mime = (body["mime"] as? String ?? "").lowercased()
            let kind = mime.hasPrefix("audio/") ? "audio" : "video"
            let file = folder.appending(path: "\(kind)-\(tracks.count + 1).\(Self.fileExtension(mime))")
            FileManager.default.createFile(atPath: file.path, contents: nil)
            if let handle = try? FileHandle(forWritingTo: file) { handles[id] = handle }
            tracks.append(Track(id: id, source: source, mime: mime, file: file))
            state = .capturing
        case "data":
            guard let id = body["id"] as? String, let text = body["b64"] as? String,
                  let index = tracks.firstIndex(where: { $0.id == id }), let handle = handles[id] else { return }
            // 바뀜 (2026-11-09): 바로 앞과 똑같은 데이터면 쓰지 않는다 (멈춘 플레이어가 같은 조각을 수천 번 넣어 용량이 불었다)
            if lastChunks[id] == text {
                repeatedChunks += 1
                return
            }
            lastChunks[id] = text
            // 크기는 base64 길이로 미리 셈 (풀기는 쓰기 큐에서)
            let size = Int64(text.utf8.count / 4 * 3)
            guard tracks[index].bytes + size <= Self.trackLimit else { return }
            tracks[index].bytes += size
            if receivedSince == nil { receivedSince = Date() }
            tracks[index].chunks += 1
            let fragments = tracks[index].index
            writer.async {
                guard let data = Data(base64Encoded: text) else { return }
                try? handle.write(contentsOf: data)
                fragments.feed(data)
            }
        case "time":
            guard let key = body["key"] as? String, let time = body["time"] as? Double else { return }
            frames[key] = message.frameInfo
            let duration = body["duration"] as? Double
            let source = body["ms"] as? String
            players[key] = Playback(time: time, duration: duration.flatMap { $0.isFinite && $0 > 0 ? $0 : nil },
                                    bufferedEnd: body["buffered"] as? Double ?? time,
                                    paused: body["paused"] as? Bool ?? true, updatedAt: Date(), source: source)
            if let source { playerSources[key, default: []].insert(source) }
            if playerPages[key] == nil { playerPages[key] = Self.pageKey(browser.url) }
        case "ended":
            // 끝까지 재생했으면: 빈 구간이 있으면 채우고, 없으면 저장 (tick 이 판단)
            tick()
        default:
            break
        }
    }

    // MARK: - 당겨 받기·빈 구간 채우기

    /// 1초마다: 받은 구간을 보고 받기 속도 한도까지 앞으로 이동시키거나, 끝까지 받았으면 빈 구간을 채우고, 다 받았으면 저장
    private func tick() {
        // 새로고침 뒤 1분이 지나도 같은 영상이 안 나타나면 기다리지 않는다 (채우는 중이었으면 있는 것으로 저장)
        if let since = waitingReload, Date().timeIntervalSince(since) > 60, state == .capturing {
            waitingReload = nil
            WebLog.write("재생하며 받기: 새로고침 뒤 1분 안에 같은 영상이 나타나지 않음")
            if reachedEnd {
                stop(save: true)
                return
            }
        }
        guard state == .capturing, let key = mainPlayerKey, let player = players[key], let duration = player.duration else { return }
        // 바뀜 (2026-11-07): 그 영상에 붙었던 재생 버퍼들의 트랙을 모두 (빈 구간을 채우러 이동하면 플레이어가 재생 버퍼를 새로 만들어
        //   채운 데이터가 새 트랙으로 들어와, 가장 큰 재생 버퍼만 보던 때는 빈 구간이 줄지 않았다). 모르면 예전처럼 가장 많이 받은 재생 버퍼
        adoptEarlier(into: key, duration: duration)
        if waitingReload != nil { return }
        let main = mainTracks(of: key)
        guard !main.isEmpty else { return }
        // 종류(영상·소리)마다 받은 구간을 합친다
        let coverage = [true, false].compactMap { video -> [ClosedRange<Double>]? in
            let same = main.filter { $0.isVideo == video }
            return same.isEmpty ? nil : Self.union(same.map { $0.index.covered })
        }
        guard !coverage.contains(where: \.isEmpty) else { return }
        // 지금 위치가 든 구간의 끝 (트랙 중 가장 짧은 것)
        let ends = coverage.map { ranges in
            ranges.first { $0.lowerBound <= player.time + 0.5 && player.time <= $0.upperBound + 0.5 }?.upperBound ?? player.time
        }
        let frontier = ends.min() ?? player.time
        self.frontier = frontier
        playerFrontiers[key] = frontier
        let gaps = Self.gaps(in: coverage, duration: duration)
        self.gaps = gaps

        // 플레이어가 받기를 쉬는지 (받아 둔 끝이 1.5초 넘게 그대로)
        if player.bufferedEnd != lastBuffered.end { lastBuffered = (player.bufferedEnd, Date()) }
        let idle = Date().timeIntervalSince(lastBuffered.changedAt) > 1.5
        let now = Date()
        if player.time != lastTime.time || player.paused { lastTime = (player.time, now) }

        if !reachedEnd, frontier >= duration - 0.5 {
            reachedEnd = true
            WebLog.write("재생하며 받기: 끝까지 받음 — 빈 구간 \(gaps.count)곳 채우기 시작 \(Self.describe(gaps))")
        }
        if !reachedEnd {
            fillingGaps = false
            // 새로고침 뒤 앞서 받은 구간 안에서 재생 중이면 그 받은 끝으로 (받기 속도와 상관없이 한 번)
            // 바뀜 (2026-11-09, 사용자): 지금 자리의 받은 끝이 아니라 새로고침 전에 받던 끝으로 (페이지가 0초부터 다시 틀면
            //   첫 빈 구간으로 가 버렸다. 앞쪽 빈 구간은 끝까지 받은 뒤 채우기에서 간다)
            let target = max(frontier, resumeAt ?? 0)
            if resumeJump, target > player.time + 3, now.timeIntervalSince(lastSeek) > 2 {
                resumeJump = false
                resumeAt = nil
                WebLog.write("재생하며 받기: 앞서 받은 곳이라 \(Self.clock(player.time)) → \(Self.clock(target)) 로 건너뜀")
                seek(key, to: target + 0.05)
                return
            }
            // 바뀜 (2026-11-08): 기다리는 시간은 패널의 "로딩 멈춤 감지" 설정 (0 이면 안 함, 사용자)
            // 바뀜 (2026-11-08, 사용자): 재생 중인데 위치가 20초 넘게 그대로면(로딩이 안 끝남) 5초 건너뛰어 다시 받아 본다.
            //   건너뛴 곳은 빈 구간이 되고, 끝까지 받은 뒤 빈 구간 채우기에서 다시 가 본다
            if stallLimit > 0, now.timeIntervalSince(lastTime.changedAt) > Double(stallLimit), player.time + 5 < duration,
               now.timeIntervalSince(lastSeek) > Double(stallLimit) {
                lastTime = (player.time, now)
                // 바뀜 (2026-11-09, 사용자): 건너뛰어도 곧 또 멈추기를 3번 하면 (요청이 걸려 안 끝나는 CDN) 건너뛰지 않고 페이지를 새로고침 —
                //   새로고침하면 앞서 받은 것을 이어받아 받은 끝으로 간다. 너무 자주 하지 않게 3분에 한 번까지
                stallStreak = now.timeIntervalSince(lastStallSkip) < Double(stallLimit) * 2 + 15 ? stallStreak + 1 : 1
                lastStallSkip = now
                if autoReload, stallStreak >= Self.reloadAfterStalls, now.timeIntervalSince(lastReload) > Self.reloadInterval {
                    WebLog.write("재생하며 받기: \(Self.clock(player.time)) 에서 멈춤이 이어져 (\(stallStreak)번) 페이지 새로고침")
                    reloadPage()
                    return
                }
                WebLog.write("재생하며 받기: \(Self.clock(player.time)) 에서 로딩 멈춤 → 5초 건너뜀")
                seek(key, to: player.time + 5)
                return
            }
            if anchor == nil { anchor = (now, frontier) }
            guard speed > 1, let anchor else { return }
            let limit = anchor.content + now.timeIntervalSince(anchor.wall) * speed
            // 한도 안이고, 플레이어가 쉬고 있고, 받은 끝이 지금 위치보다 앞이면 그 끝 바로 뒤로 (통!)
            if frontier < limit, idle, frontier > player.time + 1, now.timeIntervalSince(lastSeek) > 2 {
                seek(key, to: frontier + 0.05)
            }
            return
        }

        // 바뀜 (2026-11-09, 사용자): 빈 구간 채우기를 다시 짰다 (끝없이 돌며 앞뒤를 수 GB 다시 받던 것).
        //   - 횟수는 채우러 간 구간과 겹치는 것으로 센다 (구간마다 두 번, 모두 합쳐 maxGapTries 번)
        //   - 채우는 중엔 5초 건너뛰기를 하지 않는다 (못 받는 구간을 잘게 쪼개 조각마다 다시 가던 것) — 멈추면 그 구간은 포기하고 다음으로
        //   - 채운 구간을 지나면 플레이어가 버퍼를 다 채울 때까지 기다리지 않고 바로 다음 구간으로 (이미 받은 뒤쪽을 다시 받지 않게)
        fillingGaps = true
        let tries = { (gap: ClosedRange<Double>) in self.gapTries.filter { $0.overlaps(gap) }.count }
        let candidates = gaps.filter { tries($0) < triesPerGap }
        // 바뀜 (2026-11-09, 사용자): 한 구간을 두 번 연달아 가지 않고 한 바퀴씩 (A → B → C → 다시 A …) — 덜 가 본 구간 먼저, 같으면 앞의 것.
        //   같은 곳을 실패하자마자 다시 가면 CDN 이 그대로 막혀 있어 또 실패하기 쉬워, 다시 갈 때까지 시간을 벌린다
        guard let next = candidates.min(by: { (tries($0), $0.lowerBound) < (tries($1), $1.lowerBound) }),
              gapTries.count < Self.maxGapTries else {
            // 바뀜 (2026-11-09, 사용자): 저장하기 전에 한 번만 — 페이지를 새로고침해(새 접속·새 주소) 남은 빈 구간을 한 번씩 더
            if autoReload, !gaps.isEmpty, !reloadedForFill {
                reloadedForFill = true
                gapTries = []
                triesPerGap = 1
                WebLog.write("재생하며 받기: 빈 구간 \(gaps.count)곳이 안 채워져 페이지를 새로고침하고 한 번씩 더 가 봄")
                reloadPage()
                return
            }
            // 다 받았거나, 남은 빈 구간은 두 번씩 가 봐도 안 채워짐 (있는 것으로 저장 — 낮은 화질 조각이 있으면 그것으로)
            WebLog.write("재생하며 받기: 저장 — 남은 빈 구간 \(gaps.count)곳 \(Self.describe(gaps)), 채우러 간 횟수 \(gapTries.count), 되풀이라 버린 데이터 \(repeatedChunks)번")
            stop(save: true)
            return
        }
        guard now.timeIntervalSince(lastSeek) > 3 else { return }
        let move: String?
        if let target = fillTarget {
            let stillEmpty = gaps.contains { $0.overlaps(target) }
            let stallWait = Double(stallLimit > 0 ? stallLimit : 20)
            if !stillEmpty {
                move = "채움"
            } else if player.time > target.upperBound + 1 {
                move = "지나감"
            } else if now.timeIntervalSince(lastTime.changedAt) > stallWait {
                move = "멈춤"
            } else if idle, player.time >= duration - 0.5 || player.paused {
                move = "쉼"
            } else {
                move = nil
            }
        } else {
            move = "처음"
        }
        guard let move else { return }
        if let target = fillTarget { WebLog.write("재생하며 받기: \(Self.clock(target.lowerBound))~\(Self.clock(target.upperBound)) \(move)") }
        gapTries.append(next)
        allTries.append(next)
        fillTarget = next
        lastTime = (player.time, now)
        WebLog.write("재생하며 받기: 빈 구간 \(Self.clock(next.lowerBound))~\(Self.clock(next.upperBound)) 채우러 감 (\(tries(next))번째, 모두 \(gapTries.count)번)")
        seek(key, to: next.lowerBound + 0.05)
    }

    private static func clock(_ seconds: Double) -> String {
        let total = Int(seconds)
        return total >= 3600 ? String(format: "%d:%02d:%02d", total / 3600, total / 60 % 60, total % 60)
                             : String(format: "%d:%02d", total / 60, total % 60)
    }

    private static func describe(_ gaps: [ClosedRange<Double>]) -> String {
        gaps.prefix(12).map { "\(clock($0.lowerBound))~\(clock($0.upperBound))" }.joined(separator: " ")
    }

    /// 새로고침(또는 플레이어를 새로 만든) 뒤의 영상이 앞서 받던 영상과 같으면 앞의 재생 버퍼들을 이 영상 것으로 합친다 (2026-11-09, 사용자).
    /// 앞 영상은 소식이 끊겼고(새로고침 전 페이지), 길이가 0.5초 안으로 같고, 탭 주소가 같거나 초기화 조각 바이트가 같은 트랙이 있을 때.
    /// 합치면 앞서 받은 구간도 받은 것으로 쳐서 받은 끝으로 건너뛰고, 저장할 때 한 파일로 (겹친 조각은 시각으로 뺀다)
    private func adoptEarlier(into key: String, duration: Double) {
        guard let mine = playerSources[key], !mine.isEmpty else { return }
        let now = Date()
        for (other, sources) in playerSources where other != key {
            guard let earlier = players[other], now.timeIntervalSince(earlier.updatedAt) >= Self.staleAfter,
                  let length = earlier.duration, abs(length - duration) < 0.5 else { continue }
            let samePage = playerPages[other] != nil && playerPages[other] == playerPages[key]
            let sameBytes = sharesInit(mine, sources)
            guard samePage || sameBytes else { continue }
            playerSources[key] = mine.union(sources)
            playerSources[other] = nil
            playerPages[other] = nil
            players[other] = nil
            frames[other] = nil
            anchor = nil
            resumeJump = true
            resumeAt = playerFrontiers[other]
            playerFrontiers[other] = nil
            waitingReload = nil
            WebLog.write("재생하며 받기: 앞서 받던 영상과 같아 이어받음 (같은 주소 \(samePage ? "예" : "아니오"), 같은 초기화 조각 \(sameBytes ? "예" : "아니오"))")
            return
        }
    }

    /// 페이지를 새로고침하고 같은 영상을 이어받기를 기다린다 (스크립트는 받는 중이라 처음부터 켜진 채로 들어간다)
    private func reloadPage() {
        lastReload = Date()
        stallStreak = 0
        fillTarget = nil
        waitingReload = Date()
        lastSeek = Date()
        browser.webView.reload()
    }

    /// 두 재생 버퍼 묶음에 바이트가 똑같은 초기화 조각이 있는지
    private func sharesInit(_ a: Set<String>, _ b: Set<String>) -> Bool {
        let bodies = { (sources: Set<String>) in Set(self.tracks.filter { sources.contains($0.source) }.flatMap { $0.index.initBodies }) }
        return !bodies(a).isDisjoint(with: bodies(b))
    }

    /// 탭 주소 (# 뒤는 뺀다)
    private static func pageKey(_ url: URL?) -> String? {
        guard let url, var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        parts.fragment = nil
        return parts.string
    }

    /// 그 영상의 트랙들: 그 영상에 붙었던 재생 버퍼의 트랙 (모르면 가장 많이 받은 재생 버퍼 하나)
    private func mainTracks(of key: String) -> [Track] {
        let filled = tracks.filter { $0.bytes > 0 }
        if let sources = playerSources[key] {
            let mine = filled.filter { sources.contains($0.source) }
            if !mine.isEmpty { return mine }
        }
        let groups = Dictionary(grouping: filled, by: \.source)
        return groups.values.max { $0.map(\.bytes).reduce(0, +) < $1.map(\.bytes).reduce(0, +) } ?? []
    }

    /// 여러 트랙의 받은 구간을 합친다
    private static func union(_ lists: [[ClosedRange<Double>]]) -> [ClosedRange<Double>] {
        var result: [ClosedRange<Double>] = []
        for range in lists.flatMap({ $0 }).sorted(by: { $0.lowerBound < $1.lowerBound }) {
            if let last = result.last, range.lowerBound <= last.upperBound + 0.1 {
                result[result.count - 1] = last.lowerBound ... max(last.upperBound, range.upperBound)
            } else {
                result.append(range)
            }
        }
        return result
    }

    /// 빈 구간을 보러 그 앞으로 이동 (패널의 빈 구간 목록에서)
    func show(_ gap: ClosedRange<Double>) {
        guard let key = mainPlayerKey else { return }
        seek(key, to: gap.lowerBound + 0.05)
    }

    /// 패널에 보이는 영상 = 이동시킬 영상 (재생 중, 긴 것)
    /// 바뀜 (2026-11-09): 소식이 끊긴 영상(새로고침 전 페이지)은 빼고
    private var mainPlayerKey: String? {
        livePlayers.max { a, b in
            if a.value.paused != b.value.paused { return a.value.paused }
            return (a.value.duration ?? 0) < (b.value.duration ?? 0)
        }?.key
    }

    /// 그 영상의 프레임에 이동 명령 (멈춰 있으면 재생도)
    private func seek(_ key: String, to time: Double) {
        guard let frame = frames[key], let index = Int(key.split(separator: "v").last ?? "") else { return }
        lastSeek = Date()
        browser.webView.callAsyncJavaScript("return window.__irayerSeek ? window.__irayerSeek(index, time) : false",
                                                      arguments: ["index": index, "time": time], in: frame, in: .page) { _ in }
    }

    /// 트랙마다 받은 구간을 보고, 0 ~ 전체 길이 중 어느 트랙이든 빠진 곳 (0.5초 넘는 것)
    /// 바뀜 (2026-11-07): 첫 조각이 맨 앞 2초 안에서 시작하면 그 앞은 빈 구간으로 치지 않는다 — 스트리밍 영상은 첫 조각 시각이
    ///   0.8초처럼 0 이 아닌 경우가 흔해, 0:00~0:01 이 늘 빈 구간으로 남고 처음으로 가 봐도 채워지지 않았다 (사용자)
    private static func gaps(in coverage: [[ClosedRange<Double>]], duration: Double) -> [ClosedRange<Double>] {
        var result: [ClosedRange<Double>] = []
        for ranges in coverage {
            let first = ranges.map(\.lowerBound).min() ?? 0
            var cursor = first <= 2 ? first : 0.0
            for range in ranges.sorted(by: { $0.lowerBound < $1.lowerBound }) {
                if range.lowerBound - cursor > 0.5 { result.append(cursor ... range.lowerBound) }
                cursor = max(cursor, range.upperBound)
            }
            if duration - cursor > 0.5 { result.append(cursor ... duration) }
        }
        // 겹치는 빈 구간은 합친다
        var merged: [ClosedRange<Double>] = []
        for gap in result.sorted(by: { $0.lowerBound < $1.lowerBound }) {
            if let last = merged.last, gap.lowerBound <= last.upperBound {
                merged[merged.count - 1] = last.lowerBound ... max(last.upperBound, gap.upperBound)
            } else {
                merged.append(gap)
            }
        }
        return merged
    }

    // MARK: - 도우미

    private static func fileExtension(_ mime: String) -> String {
        if mime.contains("webm") { return "webm" }
        if mime.contains("mp2t") { return "ts" }
        if mime.hasPrefix("audio/mpeg") { return "mp3" }
        if mime.hasPrefix("audio/aac") { return "aac" }
        return "mp4"
    }

    private static func safe(_ name: String) -> String {
        let bad = CharacterSet(charactersIn: "/\\:?%*|\"<>\n\r")
        let cleaned = name.components(separatedBy: bad).joined(separator: " ").trimmingCharacters(in: .whitespaces)
        return cleaned.isEmpty ? "영상" : String(cleaned.prefix(120))
    }

    private static func uniqueFolder(_ url: URL) -> URL {
        guard FileManager.default.fileExists(atPath: url.path) else { return url }
        let name = url.lastPathComponent.replacingOccurrences(of: ".mp4.\(WebDownloads.partialExtension)", with: "")
        for number in 2... {
            let candidate = url.deletingLastPathComponent().appending(path: "\(name) \(number).mp4.\(WebDownloads.partialExtension)")
            if !FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        }
        return url
    }

    private static func uniqueFile(_ url: URL) -> URL {
        guard FileManager.default.fileExists(atPath: url.path) else { return url }
        let base = url.deletingPathExtension().lastPathComponent, ext = url.pathExtension
        for number in 2... {
            let candidate = url.deletingLastPathComponent().appending(path: "\(base) \(number).\(ext)")
            if !FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        }
        return url
    }

    /// 모든 프레임에 문서 시작 전에 넣는 스크립트: MediaSource·ManagedMediaSource.addSourceBuffer 와
    /// SourceBuffer.appendBuffer 를 감싸 데이터를 앱에 넘긴다. ManagedMediaSource 는 MediaSource 를 물려받으므로
    /// 자기 것으로 가진 함수만 한 번씩 감싼다 (둘 다 감싸면 데이터가 두 번 들어온다 — wk-probe 에서 겪음).
    /// 바뀜 (2026-11-09, 사용자): 늘 들어가 있다. 꺼져 있으면 재생 버퍼마다 마지막 초기화 조각만 들고 아무것도 넘기지 않는다.
    ///   __irayerStart: 아는 재생 버퍼와 초기화 조각을 넘기고 버퍼를 비워(켜기 전에 들어간 것은 못 받았으므로) 지금 자리부터 다시 받게 한다.
    ///   버퍼를 비우는 동안 플레이어가 넣는 데이터는 끝난 뒤에 차례로 넣는다 (바쁠 때 넣으면 플레이어에 오류가 난다)
    private static let hook = """
    (() => {
      const handler = window.webkit?.messageHandlers?.\(handlerName);
      if (!handler || window.__irayerCapture) return;
      window.__irayerCapture = true;
      const frame = Math.random().toString(36).slice(2, 8);
      handler.postMessage({ t: 'hello', frame });
      let next = 1;
      let on = false;
      // 받는 중에 열린 페이지는 처음부터 켠 채로 (앱이 넣는 window.__irayerAutoOn)
      const isOn = () => {
        if (!on && window.__irayerAutoOn === true) { window.__irayerAutoOn = false; on = true; }
        return on;
      };
      const sources = new WeakMap(), buffers = new WeakMap();
      // 재생 버퍼들 (켤 때 알리려고). 버퍼가 없어지면 저절로 빠지게 WeakRef
      const entries = [];
      const reported = new Set();
      const sourceID = (ms) => { if (!sources.has(ms)) sources.set(ms, frame + '-ms' + next++); return sources.get(ms); };
      const encode = (view) => {
        let text = '';
        for (let i = 0; i < view.length; i += 0x8000) text += String.fromCharCode.apply(null, view.subarray(i, i + 0x8000));
        return btoa(text);
      };
      const announce = (entry) => {
        entry.announced = true;
        handler.postMessage({ t: 'add', id: entry.id, ms: entry.ms, mime: entry.mime });
      };
      const type = (view, at) => String.fromCharCode(view[at + 4], view[at + 5], view[at + 6], view[at + 7]);
      // 초기화 조각만 떼어 둔다: fMP4 는 ftyp 부터 moov 끝까지, WebM 은 처음 넣은 덩어리 (4 MB 까지)
      const initOf = (view) => {
        if (view.length >= 4 && view[0] === 0x1A && view[1] === 0x45 && view[2] === 0xDF && view[3] === 0xA3) {
          return view.length <= (4 << 20) ? view.slice() : null;
        }
        if (view.length < 8 || !['ftyp', 'moov'].includes(type(view, 0))) return null;
        let at = 0;
        while (at + 8 <= view.length) {
          let size = ((view[at] << 24) >>> 0) + (view[at + 1] << 16) + (view[at + 2] << 8) + view[at + 3];
          if (size === 1 && at + 16 <= view.length) size = ((view[at + 12] << 24) >>> 0) + (view[at + 13] << 16) + (view[at + 14] << 8) + view[at + 15];
          if (size === 0) size = view.length - at;
          if (size < 8) break;
          if (type(view, at) === 'moov') return view.slice(0, Math.min(at + size, view.length));
          at += size;
        }
        return view.length <= (4 << 20) ? view.slice() : null;
      };
      // 버퍼를 비우는 동안 들어온 일은 차례로
      const idle = (sb) => sb.updating ? new Promise((done) => sb.addEventListener('updateend', done, { once: true })) : Promise.resolve();
      const later = (entry, task) => {
        entry.pending = (entry.pending || 0) + 1;
        entry.queue = (entry.queue || Promise.resolve()).then(task).catch(() => {})
          .finally(() => { if (--entry.pending === 0) entry.queue = null; });
      };
      // blob: 주소 → 재생 버퍼 (영상에 어느 재생 버퍼가 붙었는지 앱이 알게. 이동하면 재생 버퍼를 새로 만드는 플레이어가 있다)
      const urlSources = new Map();
      if (!URL.createObjectURL.__irayer) {
        const create = URL.createObjectURL;
        URL.createObjectURL = function (obj) {
          const url = create.call(this, obj);
          if (obj && typeof obj.addSourceBuffer === 'function') urlSources.set(url, sourceID(obj));
          return url;
        };
        URL.createObjectURL.__irayer = true;
      }
      for (const MS of [window.MediaSource, window.ManagedMediaSource].filter(Boolean)) {
        if (!Object.prototype.hasOwnProperty.call(MS.prototype, 'addSourceBuffer') || MS.prototype.addSourceBuffer.__irayer) continue;
        const add = MS.prototype.addSourceBuffer;
        MS.prototype.addSourceBuffer = function (mime) {
          const sb = add.call(this, mime);
          const entry = { id: frame + '-sb' + next++, ms: sourceID(this), mime: String(mime), sb: new WeakRef(sb), init: null, announced: false };
          buffers.set(sb, entry);
          entries.push(entry);
          if (isOn()) announce(entry);
          // 바뀜 (2026-11-12): 꺼져 있어도 재생 버퍼가 생겼다고 한 번 알린다 (감지 목록에 재생하며 받기 줄)
          if (!entry.mime.startsWith('audio') && !reported.has(entry.ms)) { reported.add(entry.ms); handler.postMessage({ t: 'mse', mime: entry.mime }); }
          return sb;
        };
        MS.prototype.addSourceBuffer.__irayer = true;
      }
      for (const SB of [window.SourceBuffer, window.ManagedSourceBuffer].filter(Boolean)) {
        if (!Object.prototype.hasOwnProperty.call(SB.prototype, 'appendBuffer') || SB.prototype.appendBuffer.__irayer) continue;
        const append = SB.prototype.appendBuffer;
        SB.prototype.appendBuffer = function (data) {
          const entry = buffers.get(this);
          if (!entry) return append.call(this, data);
          const view = data instanceof ArrayBuffer ? new Uint8Array(data) : new Uint8Array(data.buffer, data.byteOffset, data.byteLength);
          const init = initOf(view);
          if (init) entry.init = init;
          const send = () => {
            if (!isOn()) return;
            if (!entry.announced) announce(entry);
            handler.postMessage({ t: 'data', id: entry.id, b64: encode(view) });
          };
          if (entry.queue) {
            later(entry, async () => { await idle(this); send(); append.call(this, data); });
            return;
          }
          send();
          return append.call(this, data);
        };
        SB.prototype.appendBuffer.__irayer = true;
      }
      // 켜기: 아는 재생 버퍼와 그 초기화 조각을 넘기고, 버퍼를 비워 지금 자리부터 다시 받게 한다
      window.__irayerStart = () => {
        if (on) return true;
        on = true;
        for (const entry of entries) {
          const sb = entry.sb.deref();
          if (!sb) continue;
          announce(entry);
          if (entry.init) handler.postMessage({ t: 'data', id: entry.id, b64: encode(entry.init) });
          later(entry, async () => { await idle(sb); try { if (sb.buffered.length) sb.remove(0, Infinity); } catch (e) {} await idle(sb); });
        }
        return true;
      };
      window.__irayerStop = () => { on = false; window.__irayerAutoOn = false; return true; };
      // 재생 버퍼에 연결되는 <video> 를 기억한다 (플레이어가 src = blob:… 이나 srcObject = MediaSource 로 넣는 순간).
      // iframe·닫힌 shadow DOM 안이어도 그 프레임의 이 스크립트가 직접 보므로 찾을 수 있다
      const players = [];
      const track = (el) => {
        if (players.includes(el)) return;
        players.push(el);
        // 끝까지 재생하면 저장 (페이지 안 다른 <video src> 영상이 끝난 것으로는 저장하지 않는다)
        el.addEventListener('ended', () => { if (isOn() && el.duration > 0) handler.postMessage({ t: 'ended' }); });
      };
      const P = HTMLMediaElement.prototype;
      for (const name of ['src', 'srcObject']) {
        const desc = Object.getOwnPropertyDescriptor(P, name);
        if (!desc || !desc.set || desc.set.__irayer) continue;
        const set = desc.set;
        const wrapped = function (value) {
          if (name === 'src' && String(value).startsWith('blob:')) { this.__irayerMS = urlSources.get(String(value)) || this.__irayerMS; track(this); }
          if (name === 'srcObject' && value && typeof value.addSourceBuffer === 'function') { this.__irayerMS = sourceID(value); track(this); }
          return set.call(this, value);
        };
        wrapped.__irayer = true;
        Object.defineProperty(P, name, { ...desc, set: wrapped });
      }
      // <source src=blob:…> 로 넣는 플레이어도 있다 (hls.js 가 ManagedMediaSource 를 쓸 때)
      const sdesc = Object.getOwnPropertyDescriptor(HTMLSourceElement.prototype, 'src');
      if (sdesc && sdesc.set && !sdesc.set.__irayer) {
        const set = sdesc.set;
        const wrapped = function (value) {
          if (String(value).startsWith('blob:')) queueMicrotask(() => {
            if (this.parentElement instanceof HTMLMediaElement) {
              this.parentElement.__irayerMS = urlSources.get(String(value)) || this.parentElement.__irayerMS;
              track(this.parentElement);
            }
          });
          return set.call(this, value);
        };
        wrapped.__irayer = true;
        Object.defineProperty(HTMLSourceElement.prototype, 'src', { ...sdesc, set: wrapped });
      }
      // 그 밖의 경우를 위해: 만들어지는 shadow DOM 을 (닫힌 것까지) 기억해 두고 1초마다 그 안까지 훑어 재생 버퍼(blob:)로 재생 중인 영상을 찾는다
      const roots = [];
      const attach = Element.prototype.attachShadow;
      if (attach && !attach.__irayer) {
        Element.prototype.attachShadow = function (options) { const root = attach.call(this, options); roots.push(root); return root; };
        Element.prototype.attachShadow.__irayer = true;
      }
      const scan = () => {
        for (const scope of [document, ...roots]) {
          scope.querySelectorAll('video, audio').forEach((el) => { if (String(el.currentSrc).startsWith('blob:')) track(el); });
        }
      };
      // 앱이 시키는 이동 (당겨 받기·빈 구간 채우기): 그 영상의 위치를 옮기고, 멈춰 있으면 재생
      window.__irayerSeek = (index, time) => {
        const el = players[index];
        if (!el) return false;
        el.currentTime = time;
        if (el.paused) el.play().catch(() => {});
        return true;
      };
      // 켜져 있으면 1초마다 지금 위치·전체 길이·받아 둔 끝 (지금 위치가 든 buffered 구간의 끝)
      setInterval(() => {
        if (!isOn()) return;
        scan();
        players.forEach((el, index) => {
          if (!el.isConnected && el.readyState === 0) return;
          let end = el.currentTime;
          for (let i = 0; i < el.buffered.length; i++) {
            if (el.buffered.start(i) <= el.currentTime + 0.5 && el.buffered.end(i) > end) end = el.buffered.end(i);
          }
          handler.postMessage({ t: 'time', key: frame + '-v' + index, time: el.currentTime,
                                duration: Number.isFinite(el.duration) ? el.duration : -1, buffered: end, paused: el.paused,
                                ms: el.__irayerMS || null });
        });
      }, 1000);
    })();
    """
}

/// 바뀜 (2026-11-09): 늘 붙여 두므로 약하게 잡는다 (웹뷰 설정이 받기를 붙잡아 두지 않게)
private final class WeakCaptureHandler: NSObject, WKScriptMessageHandler {
    weak var target: WebCapture?

    init(_ target: WebCapture) { self.target = target }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.receive(message)
    }
}
