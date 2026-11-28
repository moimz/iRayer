#if os(macOS)
import VLCKit
#else
import MobileVLCKit
#endif
import Observation
import os
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

/// 자막·오디오 트랙
struct MediaTrack: Identifiable, Hashable {
    let id: Int32
    let name: String
}

/// 자막 선택: 끄기 / 영상 안의 자막(VLC 트랙) / 외부 자막 파일
enum SubtitleChoice: Hashable {
    case off
    case embedded(Int32)
    case external(URL)
}

/// 메뉴에 보여줄 자막 항목
struct SubtitleOption: Identifiable, Hashable {
    let choice: SubtitleChoice
    let name: String
    var id: SubtitleChoice { choice }
}

/// VLC 플레이어를 감싸고 재생 상태를 화면에 전달한다
@Observable
final class PlayerModel {
    let file: VideoFile

    var isPlaying = false
    /// 현재 재생 위치 (초)
    var currentTime: Double = 0
    /// 영상 길이 (초)
    var duration: Double = 0
    /// 탐색 중인 위치 (초). 탐색 중이 아니면 nil
    var scrubTime: Double?
    var controlsVisible = false
    /// 조작에 붙은 창(맥 재생 설정 팝오버)이 열려 있다: 그동안 조작을 숨기지 않는다 (숨기면 팝오버도 같이 닫힌다)
    var holdsControls = false
    var errorMessage: String?
    /// 첫 장면이 그려졌다 (그 전까지는 화면 가운데 "불러오는 중")
    var hasFirstFrame = false
    /// 10초가 지나도 첫 장면이 없다
    var isSlowToLoad = false
    /// 재생 중인데 시간이 흐르지 않는다 (네트워크가 느려 기다리는 중)
    var isBuffering = false
    /// 직접 읽기로 받아 둔 끝 위치 (영상 전체에 대한 비율, 진행바에 옅게 표시). 직접 읽지 않으면 nil.
    var bufferedFraction: Double?
    /// 버퍼 막대용 바이트→시간 표 (VLC 가 읽어 간 목차로 만든다, ByteTimeline). 없으면 평균 비트레이트로
    @ObservationIgnored private var timeline: ByteTimeline?
    @ObservationIgnored private var timelineLoading = false
    @ObservationIgnored private var timelineAttempts = 0
    @ObservationIgnored private var timelineAttemptAt = Date.distantPast
    /// 재생 화면에 띄울 디버그 정보 줄 (설정의 디버그 정보 보기가 켜졌을 때만, 1초마다)
    var debugLines: [String] = []
    @ObservationIgnored private var debugSampledAt = Date.distantPast
    @ObservationIgnored private var debugPrevious: (at: Date, total: Int64, lines: [Int: Int64], vlcRead: Int64)?
    @ObservationIgnored private var smbSessions: Int?
    /// 재생 자체를 못 함 (화면 가운데 안내 + 다시 시도)
    var playbackError: String?
    /// 화면을 위아래로 끌어 밝기·볼륨을 바꾸는 중 (오른쪽 위에 표시)
    var level: Level?

    struct Level: Equatable {
        enum Kind { case brightness, volume }
        let kind: Kind
        /// 0~1
        let value: Float
    }

    var subtitleOptions: [SubtitleOption] = []
    var selectedSubtitle = SubtitleChoice.off
    var audioTracks: [MediaTrack] = []
    var selectedAudioID: Int32 = -1
    /// 앱이 직접 그리는 자막의 지금 표시할 내용 (SRT·SMI·VTT)
    var subtitleText: String? {
        didSet {
            #if os(iOS)
            systemPiP?.subtitleChanged(subtitleText)
            #endif
        }
    }

    /// 자막 싱크 (밀리초)
    var subtitleDelay: Int = 0 {
        didSet {
            player.currentVideoSubTitleDelay = subtitleDelay * 1000
            remember { $0.subtitleDelay = subtitleDelay }
        }
    }

    /// 오디오 싱크 (밀리초)
    var audioDelay: Int = 0 {
        didSet {
            player.currentAudioPlaybackDelay = audioDelay * 1000
            remember { $0.audioDelay = audioDelay }
        }
    }

    /// 재생 배속 (매번 1배속으로 시작)
    var rate: Float = 1 {
        didSet { player.rate = rate }
    }

    /// 끝까지 재생했다 (다음 영상으로 이어 갈 때 쓴다)
    private(set) var reachedEnd = false

    /// 영상 원본 크기 (화면 크기 상태 계산용)
    var videoSize: CGSize = .zero
    /// 화면 아래에서 보이는 영상 아래쪽 가장자리까지의 거리 (자막 위치용)
    var videoBottomInset: CGFloat = 0
    /// 화면(영상 뷰) 안에서 보이는 영상의 위치와 화면 크기. 레터박스 채우기에 쓴다.
    var videoFrame = CGRect.zero
    var surfaceSize = CGSize.zero {
        didSet {
            // 바뀜 (2026-11-28, 사용자: 재생 중 회전하면 앰비언트가 영상 위에 잠깐 보였다가 제자리를 잡음): 가로·세로가 바뀌면
            // 영상 위치와 화면 크기가 따로 바뀌는 동안 앰비언트가 엉뚱한 자리에 그려지므로, 바로 숨기고 크기가 자리 잡은 뒤 다시 보인다
            let wasLandscape = oldValue.width > oldValue.height
            let isLandscape = surfaceSize.width > surfaceSize.height
            if oldValue != .zero, wasLandscape != isLandscape {
                ambientHidden = true
            }
            if ambientHidden { surfaceChangedAt = Date() }
        }
    }
    /// 레터박스를 채울 영상의 작은 스냅숏 (흐리게 늘려 깐다)
    var ambientImage: UIImage?
    /// 회전하는 동안 앰비언트를 숨긴다 (updateAmbient 가 크기가 0.5초 그대로면 푼다)
    var ambientHidden = false
    @ObservationIgnored private var surfaceChangedAt = Date.distantPast
    /// 아래쪽 컨트롤(제목·버튼·진행률 바)의 화면(window) 좌표. 이 위의 터치는 화면 제스처가 가져가지 않는다.
    @ObservationIgnored var bottomControlsFrame = CGRect.zero
    /// 위쪽 버튼(✕ · AirPlay · PiP)의 화면 좌표 (위와 같은 이유)
    @ObservationIgnored var topControlsFrame = CGRect.zero

    @ObservationIgnored let player = VLCMediaPlayer()
    /// 직접 읽기 중이면 그 리더 (받아 둔 범위, 기다리는 중인지)
    @ObservationIgnored private(set) var directReader: DirectReader?
    /// MP4 목차로 잰 소리·영상 어긋남 (첫 장면 전에 나오면 saveMediaInfo 가 같이 남긴다)
    @ObservationIgnored private var interleaveSkew: Double?
    @ObservationIgnored private let store = PlaybackStateStore.shared
    @ObservationIgnored private let resume: Bool
    /// 바뀜 (2026-11-25, 사용자: 파일 앱에서 "iRayer로 열기"): 라이브러리·추가한 폴더 밖에서 연 파일이면 false →
    /// 재생 위치·자막·오디오 설정·이어보기를 남기지 않는다 (동기화·장면 캡처도 위치가 없으니 따라서 안 생긴다)
    @ObservationIgnored private let keepsRecords: Bool
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var openedAt = Date()
    /// VLC 가 마지막으로 알려 준 재생 시간과 그때. VLC 3 는 파일을 읽어 들이는 쪽에서 시간을 갱신하므로, 네트워크가 잠깐 느려
    /// 읽기가 멈추면 화면·소리는 버퍼로 계속 나오는데 시간만 멈춘다. 그동안은 여기서부터 실제 흐른 시간으로 이어 센다.
    /// vlc 는 바뀌었는지 비교하는 원래 값 (탐색 직후에는 VLC 가 아직 옛 값을 주므로 그 값을 두고 시간만 목표로 바꿔 둔다).
    @ObservationIgnored private var timeAnchor = (vlc: Int32(-1), time: 0.0, at: Date())
    /// 사용자가 재생을 원하는 상태 (일시 정지 중이면 버퍼링 표시를 하지 않는다)
    @ObservationIgnored private var wantsPlay = true
    @ObservationIgnored private var started = false
    @ObservationIgnored private var lastSavedAt = Date.distantPast
    /// 탐색 중 보낸 마지막 이동: 목표 위치, 보낸 시각, 그때까지 화면에 그린 프레임 수
    @ObservationIgnored private var scrubSeek: (target: Double, at: Date, pictures: Int32)?
    @ObservationIgnored private var scrubTask: Task<Void, Never>?
    /// 레터박스 색: 마지막으로 스냅숏을 요청한 시각과, 결과를 아직 읽지 않았는지
    @ObservationIgnored private var ambientRequestedAt = Date.distantPast
    @ObservationIgnored private var ambientPending = false
    @ObservationIgnored private let ambientPath = FileManager.default.temporaryDirectory
        .appending(path: "ambient-\(UUID().uuidString).png").path
    @ObservationIgnored private var scrubWasMuted = false
    @ObservationIgnored private var lastInteractionAt = Date()
    @ObservationIgnored private var subtitleAccessURL: URL?
    /// 고를 수 있는 외부 자막 파일 (같은 이름의 자막 + 직접 불러온 자막)
    @ObservationIgnored private var externalSubtitles: [URL] = []
    /// 앱이 직접 그리는 외부 자막의 내용
    @ObservationIgnored private(set) var cues: [SubtitleCue] = []
    /// VLC 에 붙인 외부 자막(ASS 등) 파일명 (붙인 순서대로). VLC 는 이름을 "Track 1" 처럼만 알려주므로 대신 표시한다.
    @ObservationIgnored private var vlcExternalNames: [String] = []

    init(file: VideoFile, resume: Bool) {
        self.file = file
        self.resume = resume
        self.keepsRecords = OpenedFile.keepsRecords(file.url)
        #if DEBUG
        // 테스트용 실행 인자 `-showControls YES`: 컨트롤을 계속 보여준다 (시뮬레이터 테스트 도구의 탭이 늦게 전달돼서)
        if UserDefaults.standard.bool(forKey: "showControls") { controlsVisible = true }
        #endif
    }

    #if os(iOS)
    /// PiP 단추를 누른 뒤 PiP 창이 뜰 때까지 (그동안 화면에 PiP 안내)
    var isOpeningPiP = false
    /// 아이폰 기본 PiP (PiP 단추를 눌렀을 때만 장면 받기로 바꾼다)
    @ObservationIgnored private var systemPiP: SystemPiP?

    /// PiP 단추: 기본 PiP 를 쓸 수 없으면 false (앱 안 작은 플레이어로)
    func startSystemPiP() -> Bool {
        guard SystemPiP.isSupported, let phoneView, externalView == nil else { return false }
        if systemPiP == nil { systemPiP = SystemPiP(model: self, player: player) }
        isOpeningPiP = true
        systemPiP?.start(in: phoneView)
        return true
    }
    #endif

    // MARK: - 재생 제어

    func attach(to view: UIView) {
        phoneView = view
        // TV 에 그리고 있으면 TV 쪽을 유지한다
        if externalView == nil { player.drawable = view }
        startIfWaiting()
    }

    /// 재생목록에서 영상을 바꾸면 새 모델이 먼저 만들어지고 영상 뷰는 그다음에 붙는다.
    /// 그릴 뷰가 없을 때 시작하면 VLC 가 영상 출력을 만들지 못하므로, 뷰가 붙을 때까지 시작을 미룬다.
    @ObservationIgnored private var waitingForView = false

    private func startIfWaiting() {
        guard waitingForView else { return }
        waitingForView = false
        start()
    }

    /// 폰 화면의 영상 뷰와, 화면 미러링으로 연결된 TV 의 영상 뷰
    @ObservationIgnored private weak var phoneView: UIView?
    @ObservationIgnored private weak var externalView: UIView?

    /// TV 에 영상을 그린다 (폰에는 조작 화면만 남는다)
    func attachExternal(_ view: UIView) {
        externalView = view
        moveVideo(to: view)
        startIfWaiting()
    }

    /// TV 연결이 끊기면 폰 화면으로 되돌린다
    func detachExternal(_ view: UIView) {
        guard externalView === view else { return }
        externalView = nil
        if let phoneView { moveVideo(to: phoneView) }
    }

    /// VLC 3 은 재생 중에 drawable 만 바꾸면 영상 출력이 따라가지 않는다 (TV 가 까맣게 남음).
    /// 영상 트랙을 잠깐 껐다 켜서 새 뷰에 영상 출력을 다시 만든다.
    private func moveVideo(to view: UIView) {
        player.drawable = view
        let track = player.currentVideoTrackIndex
        guard player.media != nil, track >= 0 else { return }
        player.currentVideoTrackIndex = -1
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            self?.player.currentVideoTrackIndex = track
        }
    }

    func start() {
        guard phoneView != nil || externalView != nil else {
            waitingForView = true
            return
        }
        let media: VLCMedia
        // NAS(WebDAV·SMB)는 앱이 직접 받아 VLC 에 넘긴다 (DirectReader). 비교 시험용 실행 인자 -directRead NO 면 VLC 가 직접 받는다.
        let source: DirectReader.Source? = switch file.url.scheme {
        case "http", "https": .http(RemoteAccess.request(file.url, serverID: file.serverID))
        case "smb": .smb(file.url, serverID: file.serverID)
        default: nil
        }
        if UserDefaults.standard.object(forKey: "directRead") as? Bool ?? true, let source, file.size > 0,
           let reader = Optional(DirectReader(source: source, size: file.size)),
           let direct = reader.makeMedia() {
            directReader = reader
            media = direct
            // 길이를 알면(이어보기 기록) 바로 버퍼 설정만큼, 모르면 길이가 나온 뒤에 맞춘다
            let saved = store.state(for: file.stateKey).duration
            if saved > 0 { reader.setReadAhead(readAheadBytes(duration: saved)) }
        } else {
            media = RemoteAccess.media(for: file.url, serverID: file.serverID)
        }
        Self.configure(media, for: file, direct: directReader != nil)
        externalSubtitles = file.subtitles
        if file.subtitles.isEmpty { findSidecarSubtitles() }
        // 이어보기는 재생 시작 위치로 지정한다
        let saved = store.state(for: file.stateKey)
        if resume, saved.position > 5, saved.duration == 0 || saved.position < saved.duration - 10 {
            media.addOption(":start-time=\(saved.position)")
        }
        player.media = media
        player.play()
        measureInterleave()
        AppSettings.shared.applyIdleTimer(playing: true)
        // 첫 장면이 나올 때까지는 조작을 보여 둔다 (닫을 수 있고, 멈춘 게 아님을 알 수 있게)
        openedAt = Date()
        hasFirstFrame = false
        isSlowToLoad = false
        playbackError = nil
        wantsPlay = true
        controlsVisible = true
        touchControls()

        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.poll()
                try? await Task.sleep(for: .milliseconds(200))
            }
        }
        NowPlaying.shared.attach(self)
    }

    func close() {
        pollTask?.cancel()
        pollTask = nil
        NowPlaying.shared.detach(self)
        saveProgress()
        captureResumeFrameAndStop()
        try? FileManager.default.removeItem(atPath: ambientPath)
        subtitleAccessURL?.stopAccessingSecurityScopedResource()
        // 재생이 끝나면 설정대로 (앱 사용 중 자동 잠금 끄기)
        AppSettings.shared.applyIdleTimer(playing: false)
    }

    func togglePlay() {
        if player.isPlaying {
            player.pause()
            saveProgress()
        } else {
            player.play()
        }
        isPlaying = !isPlaying
        wantsPlay = isPlaying
        touchControls()
    }

    /// 재생하지 못했을 때 다시 시도
    func retry() {
        pollTask?.cancel()
        pollTask = nil
        directReader?.cancel()
        directReader = nil
        player.stop()
        started = false
        start()
    }

    /// 이어폰(블루투스·유선)이 끊기면 멈춘다 — 스피커로 소리가 새지 않게 (애플 가이드, 2026-11-09 사용자).
    /// AVPlayer 는 스스로 멈추지만 VLC 는 아니라서 직접. 다시 연결돼도 저절로 재생하지 않는다
    func pauseForLostRoute() {
        guard isPlaying else { return }
        player.pause()
        isPlaying = false
        wantsPlay = false
        saveProgress()
        touchControls()
    }

    /// AirPlay 로 넘길 때 폰 재생을 멈춘다
    func pauseForHandoff() {
        player.pause()
        isPlaying = false
        saveProgress()
    }

    /// AirPlay 재생을 마치고 돌아오면 그 위치부터 다시 재생한다
    func resume(at seconds: Double) {
        seek(to: seconds)
        currentTime = clampTime(seconds)
        player.play()
        isPlaying = true
        // 오래 멈춰 있던 네트워크 영상은 VLC 가 멈춘 동안 받은 이동을 버리기도 한다 (멈췄던 자리부터 재생된다):
        // 몇 초 동안 VLC 위치를 보고 어긋나면 다시 옮긴다
        resumeTarget = (clampTime(seconds), Date().addingTimeInterval(6))
    }

    /// AirPlay 로 보는 동안 TV 의 재생 위치 (시청 기록·이어보기를 그 위치로. 폰 재생은 멈춘 채)
    func externalProgress(_ seconds: Double) {
        guard seconds > 0 else { return }
        currentTime = clampTime(seconds)
        timeAnchor.time = currentTime
        timeAnchor.at = Date()
        saveProgress()
    }

    /// 다시 재생한 뒤 VLC 위치가 목표와 맞는지 보는 중 (목표, 그만 볼 때)
    @ObservationIgnored private var resumeTarget: (time: Double, until: Date)?
    @ObservationIgnored private var resumeRetriedAt = Date.distantPast

    /// AirPlay 에서 돌아온 뒤: VLC 가 이동을 버리고 멈췄던 자리부터 재생하면 다시 옮긴다
    private func checkResumeTarget() {
        guard let target = resumeTarget else { return }
        guard Date() < target.until else {
            resumeTarget = nil
            return
        }
        guard player.isPlaying, Date().timeIntervalSince(resumeRetriedAt) > 1 else { return }
        let vlc = Double(player.time.intValue) / 1000
        if abs(vlc - target.time) <= 3 {
            resumeTarget = nil
        } else {
            resumeRetriedAt = Date()
            seek(to: target.time)
            currentTime = target.time
        }
    }

    /// 처음 장면이 나오면 해상도·코덱을 재생 기록에 남긴다 (한 번만, iCloud 로 다른 기기에도)
    private func saveMediaInfo() {
        guard store.state(for: file.stateKey).media == nil else { return }
        let tracks = (player.media?.tracksInformation as? [[String: Any]]) ?? []
        let fourCC = { (track: [String: Any]) -> String? in
            guard let codec = (track[VLCMediaTracksInformationCodec] as? NSNumber)?.uint32Value, codec != 0 else { return nil }
            return String(bytes: (0..<4).map { UInt8((codec >> ($0 * 8)) & 0xFF) }, encoding: .ascii)?
                .trimmingCharacters(in: .whitespaces).lowercased()
        }
        let video = tracks.first { $0[VLCMediaTracksInformationType] as? String == VLCMediaTracksInformationTypeVideo }
        let audios = tracks.filter { $0[VLCMediaTracksInformationType] as? String == VLCMediaTracksInformationTypeAudio }
        // 지금 듣는 오디오 트랙 (없으면 첫 트랙)
        let audio = audios.first { ($0[VLCMediaTracksInformationId] as? NSNumber)?.int32Value == player.currentAudioTrackIndex } ?? audios.first
        let width = (video?[VLCMediaTracksInformationVideoWidth] as? NSNumber)?.intValue ?? Int(player.videoSize.width)
        let height = (video?[VLCMediaTracksInformationVideoHeight] as? NSNumber)?.intValue ?? Int(player.videoSize.height)
        guard width > 0 || audio != nil else { return }
        let info = MediaInfo(width: width, height: height, videoCodec: video.flatMap(fourCC), audioCodec: audio.flatMap(fourCC),
                             audioChannels: (audio?[VLCMediaTracksInformationAudioChannelsNumber] as? NSNumber)?.intValue,
                             interleaveSkew: interleaveSkew)
        remember { $0.media = info }
    }

    /// MP4·MOV 면 목차만 따로 읽어 소리·영상이 얼마나 떨어져 저장됐는지 잰다 (한 번만, 2026-11-10 사용자: 파일 정보에 * 표시)
    private func measureInterleave() {
        let key = file.stateKey
        guard file.isMP4Family, file.size > 0, store.state(for: key).media?.interleaveSkew == nil else { return }
        let url = file.url, serverID = file.serverID, size = file.size
        let read: MP4Interleave.Reader
        switch url.scheme {
        case "http", "https":
            let request = RemoteAccess.request(url, serverID: serverID)
            read = { range in
                var request = request
                request.setValue("bytes=\(range.lowerBound)-\(range.upperBound - 1)", forHTTPHeaderField: "Range")
                let (data, response) = try await URLSession.shared.data(for: request)
                guard (response as? HTTPURLResponse)?.statusCode == 206 else { throw RemoteAccess.AccessError.unreachable }
                return data
            }
        case "smb":
            read = { range in try await SMBClient.shared.read(url, range: range, serverID: serverID) }
        case "file":
            read = { range in
                let handle = try FileHandle(forReadingFrom: url)
                defer { try? handle.close() }
                try handle.seek(toOffset: UInt64(range.lowerBound))
                return try handle.read(upToCount: range.count) ?? Data()
            }
        default:
            return
        }
        Task.detached(priority: .utility) { [weak self] in
            guard let skew = await MP4Interleave.skew(size: size, read: read) else { return }
            await MainActor.run {
                self?.interleaveSkew = skew
                PlaybackStateStore.shared.update(key) { state in
                    if state.media != nil { state.media?.interleaveSkew = skew }
                }
            }
        }
    }

    /// 더블탭 건너뛰기
    func skip(by seconds: Double) {
        seek(to: currentTime + seconds)
        currentTime = clampTime(currentTime + seconds)
    }

    func seek(to seconds: Double) {
        timeAnchor = (player.time.intValue, clampTime(seconds), Date())
        player.time = VLCTime(int: Int32(clampTime(seconds) * 1000))
    }

    // MARK: - 탐색 (드래그 중 화면 자체가 미리보기, 소리 없음)

    func beginScrub() {
        scrubWasMuted = player.audio?.isMuted ?? false
        player.audio?.isMuted = true
        scrubTime = currentTime
        scrubSeek = nil
        touchControls()
        // 손가락이 멈춰도 마지막 위치가 화면에 나오도록 계속 확인한다
        scrubTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.seekForPreview()
                try? await Task.sleep(for: .milliseconds(40))
            }
        }
    }

    func updateScrub(to seconds: Double) {
        scrubTime = clampTime(seconds)
        updateSubtitleText()
        seekForPreview()
    }

    func endScrub() {
        scrubTask?.cancel()
        scrubTask = nil
        guard let target = scrubTime else { return }
        if scrubSeek?.target != target { seek(to: target) }
        scrubSeek = nil
        currentTime = target
        scrubTime = nil
        player.audio?.isMuted = scrubWasMuted
        touchControls()
    }

    /// 탐색 중 미리보기. VLC 는 정확한 위치로 갈 때 앞쪽 키프레임부터 디코딩하는데,
    /// 그 사이 새 이동을 보내면 처음부터 다시 하느라 손을 뗄 때까지 화면이 안 바뀐다.
    /// 그래서 앞 이동의 프레임이 화면에 나온 뒤에(또는 너무 오래 걸리면) 다음 이동을 보낸다.
    private func seekForPreview() {
        guard let target = scrubTime else { return }
        let pictures = player.media?.statistics.displayedPictures ?? 0
        if let last = scrubSeek {
            guard last.target != target else { return }
            let elapsed = Date().timeIntervalSince(last.at)
            let shown = pictures > last.pictures && elapsed > 0.05
            guard shown || elapsed > 0.6 else { return }
        }
        scrubSeek = (target, Date(), pictures)
        seek(to: target)
    }

    // MARK: - 트랙

    /// 메뉴에서 자막을 고르면 적용하고 영상별로 기억한다
    func selectSubtitle(_ choice: SubtitleChoice) {
        Task { await applySubtitle(choice) }
        remember {
            switch choice {
            case .off:
                $0.subtitleTrackID = -1
                $0.subtitleBookmark = nil
            case .embedded(let id):
                $0.subtitleTrackID = id
                $0.subtitleBookmark = nil
            case .external(let url):
                $0.subtitleTrackID = nil
                $0.subtitleBookmark = try? url.bookmarkData()
            }
        }
    }

    func selectAudio(_ id: Int32) {
        player.currentAudioTrackIndex = id
        selectedAudioID = id
        // 영상별로 기억한다 (다른 기기에도 iCloud 로)
        remember { $0.audioTrackID = id }
    }

    /// 자막 불러오기로 고른 파일을 적용하고 영상별로 기억한다
    func loadSubtitle(from url: URL) {
        if url.startAccessingSecurityScopedResource() {
            subtitleAccessURL?.stopAccessingSecurityScopedResource()
            subtitleAccessURL = url
        }
        if !externalSubtitles.contains(url) { externalSubtitles.append(url) }
        selectSubtitle(.external(url))
    }

    /// 자막 적용. SRT·SMI·VTT 는 앱이 직접 그리고(VLC 자막은 끔), 나머지 외부 자막은 VLC 에 붙인다.
    private func applySubtitle(_ choice: SubtitleChoice) async {
        cues = []
        subtitleText = nil
        switch choice {
        case .off:
            player.currentVideoSubTitleIndex = -1
        case .embedded(let id):
            player.currentVideoSubTitleIndex = id
        case .external(let url):
            if SubtitleParser.canParse(url) {
                // 직접 불러온 로컬 자막은 serverID 가 없어도 file:// 이라 그대로 읽힌다
                guard let parsed = await SubtitleParser.parse(url, serverID: file.serverID) else {
                    errorMessage = "자막 파일을 읽지 못했습니다."
                    return
                }
                cues = parsed
                player.currentVideoSubTitleIndex = -1
            } else {
                guard let prepared = await SubtitleLoader.prepare(url, serverID: file.serverID),
                      player.addPlaybackSlave(prepared, type: .subtitle, enforce: true) == 0 else {
                    errorMessage = "자막 파일을 읽지 못했습니다."
                    return
                }
                vlcExternalNames.append(url.subtitleName)
            }
        }
        selectedSubtitle = choice
        updateSubtitleText()
    }

    // MARK: - UI 표시

    func toggleControls() {
        controlsVisible.toggle()
        touchControls()
    }

    /// 조작이 있었음을 기록 (UI 자동 숨김 타이머 초기화)
    func touchControls() {
        lastInteractionAt = Date()
    }

    // MARK: - 내부

    private var keepControls: Bool {
        #if DEBUG
        UserDefaults.standard.bool(forKey: "showControls")
        #else
        false
        #endif
    }

    private func poll() {
        #if os(iOS)
        if systemPiP?.isActive == true { systemPiP?.playbackChanged() }
        #endif
        let state = player.state
        if state == .error, playbackError == nil {
            playbackError = hasFirstFrame ? "재생 중 연결이 끊겼거나 영상을 읽지 못했습니다." : "이 영상을 열 수 없습니다. 서버 연결이나 파일을 확인해 주세요."
            isBuffering = false
        }
        if !started, player.isPlaying {
            started = true
            didStart()
        }

        isPlaying = player.isPlaying
        checkResumeTarget()
        if scrubTime == nil {
            updateCurrentTime()
        }
        updateSubtitleText()
        let length = Double(player.media?.length.intValue ?? 0) / 1000
        if length > 0 {
            if duration == 0 { directReader?.setReadAhead(readAheadBytes(duration: length)) }
            duration = length
        }
        loadTimelineIfNeeded()
        updateBufferedFraction()
        updateDebugInfo()
        if player.videoSize != .zero, player.videoSize != videoSize {
            videoSize = player.videoSize
        }
        #if os(iOS)
        // 바뀜 (2026-11-28, 사용자: 기기 안 영상이 1~2초 작게 나왔다 커짐): 영상 뷰 크기가 화면을 못 따라간 채 남는 경우를 바로잡는다
        (phoneView?.superview as? PlayerSurfaceView)?.syncVideoViewSize()
        #endif
        updateLoading(state)
        // 바뀜 (2026-11-07): 맥에서 끝까지 보고도 다음 화로 안 넘어감 (사용자, 빌드 283) — 끝에서 VLC 가 ended·stopped 가 아닌 상태로
        // 멈춰 있는 것으로 보여, 끝 2초 안에서 재생을 원하는데(일시 정지 안 함) 재생이 멈췄거나 VLC 시간이 1.5초 넘게 그대로면 끝난 것으로 본다.
        // 그때 VLC 상태는 로그로 남긴다 (log show --predicate 'subsystem == "com.moimz.iRayer"')
        let nearEnd = duration > 0 && currentTime > duration - 2
        let stuckAtEnd = nearEnd && wantsPlay && (!player.isPlaying || Date().timeIntervalSince(vlcTimeChangedAt) > 1.5)
        if !reachedEnd, hasFirstFrame, state == .ended || (state == .stopped && nearEnd) || stuckAtEnd {
            Self.log.notice("끝남: state=\(state.rawValue, privacy: .public) playing=\(self.player.isPlaying, privacy: .public) time=\(self.currentTime, privacy: .public)/\(self.duration, privacy: .public)")
            reachedEnd = true
            saveProgress()
        }
        refreshTracks()

        // 재생 중 UI 는 4초 동안 조작이 없으면 숨긴다 (첫 장면이 나온 뒤부터)
        if controlsVisible, isPlaying, hasFirstFrame, scrubTime == nil, Date().timeIntervalSince(lastInteractionAt) > 4, !keepControls, !holdsControls {
            controlsVisible = false
        }
        if isPlaying, Date().timeIntervalSince(lastSavedAt) > 5 {
            saveProgress()
        }
        NowPlaying.shared.update()
        updateAmbient()
    }

    /// VLC 시간이 멈춰도 재생이 이어진다고 볼 시간. VLC 3 는 지금 버퍼에 얼마나 남았는지 알려주지 않으므로 버퍼 설정을 다 믿지 않는다:
    /// 네트워크 속도가 영상 비트레이트와 비슷하면 버퍼가 거의 비어 있어, 10초를 이어 세면 재생이 실제로 멈춘 뒤에도 시간이 앞서 가다가
    /// 다시 받기 시작할 때 10초 뒤로 돌아갔다 (시뮬레이터 측정). 그래서 최대 3초, 기기 안 파일은 1.5초.
    private var bufferedSeconds: Double {
        file.url.scheme == "file" ? 1.5 : min(3, Double(AppSettings.shared.networkBufferSeconds))
    }

    /// VLC 시간이 마지막으로 바뀐 때
    @ObservationIgnored private var vlcTimeChangedAt = Date()
    private static let log = Logger(subsystem: "com.moimz.iRayer", category: "player")
    /// 화면에 그린 장면 수와 마지막으로 늘어난 때 (장면이 나오고 있으면 로딩 표시를 바로 내린다)
    @ObservationIgnored private var displayedPictures: Int32 = 0
    @ObservationIgnored private var pictureShownAt = Date.distantPast

    /// 직접 읽기에서 버퍼가 바닥나 실제로 멈췄다: VLC 가 데이터를 기다리고(탐색 직후 잠깐 기다리는 것은 빼고) VLC 시간도 멈췄다.
    /// 기다리기만 해서는 모른다: VLC 3 는 앞에 prefetch 필터(16MB)를 두고 우리 리더에서 받는 대로 미리 읽어 가므로,
    /// 리더가 비어도 그 안에 남은 것으로 한참(초당 1MB 영상이면 10초 넘게) 더 재생한다 (시뮬레이터 측정).
    private var isStalled: Bool {
        (directReader?.starvedFor ?? 0) > 0.5 && Date().timeIntervalSince(vlcTimeChangedAt) > 0.5
    }

    /// 버퍼 설정 시간만큼의 바이트 (파일 크기 / 길이로 평균 비트레이트를 셈)
    /// 영상을 열 때 붙이는 VLC 설정 (폰 재생과 AirPlay 로 보내는 HLS 가 같이 쓴다). direct: 앱이 직접 받아 넘긴다 (DirectReader)
    static func configure(_ media: VLCMedia, for file: VideoFile, direct: Bool) {
        if !AppSettings.shared.hardwareDecoding {
            media.addOption(":avcodec-hw=none")
        }
        // NAS 대역이 잠깐 떨어져도 끊기지 않게 미리 받아 둔다 (VLC 기본은 1초). 직접 읽으면 앱이 받아 두므로 VLC 는 쓰지 않는다.
        if file.url.scheme != "file" {
            if !direct {
                media.addOption(":network-caching=\(AppSettings.shared.networkBufferSeconds * 1000)")
            }
            // VLC 3 의 mp4 해석기는 네트워크 파일을 '빨리 건너뛸 수 없는 파일'로 보고, 열거나 탐색할 때마다 한 트랙을 15초어치씩
            // 한 번에 읽는다 (DEMUX_TRACK_MAX_PRELOAD). 그동안 탐색 화면이 안 바뀌고(초당 6MB 에서 3~5초) 재생 시간도 멈춰 로딩 표시가 뜬다.
            // FFmpeg 해석기(avformat)는 이렇게 읽지 않는다 (같은 조건에서 0.3~0.4초, 트랙 번호·언어도 같다).
            if file.isMP4Family {
                media.addOption(":demux=avformat")
            }
        }
        // WMV(VC-1)는 VLC 의 직접 렌더링(디코더가 화면 버퍼에 바로 그림)을 쓰면 탐색 직후 버퍼를 못 받아
        // (`[wmv3] get_buffer() failed (-12)`) 화면이 깨지거나 재생이 멈춘다. 디코더가 자기 버퍼를 쓰게 한다.
        // 또 WMV(ASF)는 색인이 없는 파일이 많아 탐색하면 키프레임이 아닌 곳부터 디코딩하게 되는데,
        // 그 앞 데이터가 없어 깨진 화면을 다음 키프레임까지 보여준다. 깨진 프레임은 보여주지 않고 직전 화면을 유지한다.
        if file.isWindowsMedia {
            media.addOption(":no-avcodec-dr")
            media.addOption(":no-avcodec-corrupted")
        }
        // 외부 자막은 앱이 직접 고르고 UTF-8 로 변환해서 넘기므로, VLC 가 원본 자막 파일을 직접 찾아 붙이지 않게 하고 인코딩을 고정한다
        media.addOption(":no-sub-autodetect-file")
        media.addOption(":subsdec-encoding=UTF-8")
        // VLC 가 그리는 자막(영상 안의 자막, ASS 등)도 설정의 글꼴·크기를 따른다 (영상을 열 때 적용)
        let settings = AppSettings.shared
        if settings.subtitleFont != .system {
            media.addOption(":freetype-font=\(settings.subtitleFont.vlcFamily)")
        }
        media.addOption(":sub-text-scale=\(Int((settings.subtitleScale * 100).rounded()))")
        switch settings.subtitleEdge {
        case .outlineShadow:
            break
        case .outline:
            media.addOption(":freetype-shadow-opacity=0")
        case .dropShadow:
            // 테두리 없이, 그림자는 오른쪽 아래(-45도)
            media.addOption(":freetype-outline-thickness=0")
            media.addOption(":freetype-shadow-opacity=200")
            media.addOption(":freetype-shadow-angle=-45")
            media.addOption(":freetype-shadow-distance=0.08")
        }
    }

    /// VLC 가 목차를 읽은 뒤(첫 장면 뒤) 받아 둔 것에서 바이트→시간 표를 만든다. 못 만들면 몇 번 더 (MKV 는 VLC 가 Cues 를 늦게 읽기도 한다)
    private func loadTimelineIfNeeded() {
        guard timeline == nil, !timelineLoading, hasFirstFrame, let reader = directReader, timelineAttempts < 5,
              Date().timeIntervalSince(timelineAttemptAt) > 3, let kind = ByteTimeline.kind(for: file) else { return }
        timelineAttempts += 1
        timelineAttemptAt = Date()
        timelineLoading = true
        let size = file.size
        Task.detached(priority: .utility) { [weak self] in
            let loaded = await ByteTimeline.load(kind, size: size) { range in
                guard let data = reader.cached(range) else { throw RemoteAccess.AccessError.unreachable }
                return data
            }
            await MainActor.run {
                self?.timeline = loaded
                self?.timelineLoading = false
            }
        }
    }

    /// 디버그 정보 (2026-11-28, 사용자: 예전 NAS 연결이 수백 개 열리던 버그처럼, 느리거나 NAS 가 시끄러울 때 재생 중에 보려고)
    private func updateDebugInfo() {
        guard AppSettings.shared.playerDebugInfo else {
            if !debugLines.isEmpty { debugLines = [] }
            debugPrevious = nil
            return
        }
        let now = Date()
        guard now.timeIntervalSince(debugSampledAt) >= 1 else { return }
        debugSampledAt = now
        func mb(_ bytes: Int64) -> String {
            bytes >= 1 << 30 ? String(format: "%.2fGB", Double(bytes) / 1_073_741_824) : String(format: "%.1fMB", Double(bytes) / 1_048_576)
        }
        func speed(_ bytes: Int64, _ seconds: Double) -> String {
            seconds > 0 ? String(format: "%.1fMB/s", Double(max(bytes, 0)) / seconds / 1_048_576) : "-"
        }
        var lines: [String] = []
        let stats = player.media?.statistics
        if let reader = directReader {
            let s = reader.stats
            let elapsed = debugPrevious.map { now.timeIntervalSince($0.at) } ?? 0
            let active = s.lines.filter(\.active).count
            var head = "직접 읽기 (\(s.kind)) · 파일 \(mb(s.size)) · 받는 연결 \(active)개 / 줄 \(s.lines.count)개 · 보낸 요청 \(s.requestsStarted)번"
            if s.kind == "SMB", let smbSessions { head += " · SMB 세션 \(smbSessions)개" }
            lines.append(head)
            lines.append("받는 속도 \(speed(s.bytesReceived - (debugPrevious?.total ?? s.bytesReceived), elapsed)) · 받은 양 \(mb(s.bytesReceived)) · 메모리 \(mb(s.cachedBytes)) / 미리 받기 \(mb(s.readAhead))"
                         + (s.starvedFor > 0.2 ? String(format: " · VLC 기다림 %.1f초", s.starvedFor) : "") + (s.failing ? " · 끊김" : ""))
            for line in s.lines {
                let before = debugPrevious?.lines[line.id] ?? line.received
                lines.append("  줄 \(line.id) \(line.active ? "받는 중" : "쉼") @\(mb(line.next)) (읽은 곳보다 \(mb(max(0, line.next - line.cursor))) 앞) \(speed(line.received - before, elapsed))")
            }
            debugPrevious = (now, s.bytesReceived, Dictionary(uniqueKeysWithValues: s.lines.map { ($0.id, $0.received) }), stats.map { Int64($0.readBytes) } ?? 0)
            let ahead = (bufferedFraction ?? 0) * duration - currentTime
            let barSource = (interleaveSkew ?? 0) > MP4Interleave.threshold ? "소리·영상 떨어진 파일(평균)" : (timeline?.kind.name ?? "평균 비트레이트")
            lines.append(String(format: "버퍼 앞으로 %.0f초 (막대: %@)", max(0, ahead), barSource))
            if s.kind == "SMB" {
                Task { [weak self] in
                    let count = await SMBClient.shared.connectionCount
                    self?.smbSessions = count
                }
            }
        } else {
            let scheme = file.url.scheme ?? ""
            lines.append(scheme == "file" ? "기기 안 파일 · \(mb(file.size))" : "VLC 가 직접 받음 (\(scheme)) · \(mb(file.size))")
            let elapsed = debugPrevious.map { now.timeIntervalSince($0.at) } ?? 0
            if let stats {
                let read = Int64(stats.readBytes) - (debugPrevious?.vlcRead ?? Int64(stats.readBytes))
                lines.append("VLC 읽는 속도 \(speed(read, elapsed)) · 읽은 양 \(mb(Int64(stats.readBytes)))")
            }
            debugPrevious = (now, 0, [:], stats.map { Int64($0.readBytes) } ?? 0)
        }
        if let stats {
            let rates = String(format: "VLC 입력 %.0fkb/s · 해석 %.0fkb/s", Double(stats.inputBitrate) * 8000, Double(stats.demuxBitrate) * 8000)
            lines.append(rates + " · 그린 장면 \(stats.displayedPictures) · 놓친 장면 \(stats.lostPictures) · 깨진 묶음 \(stats.demuxCorrupted)")
        }
        lines.append("영상 \(Int(videoSize.width))×\(Int(videoSize.height)) · 하드웨어 디코딩 \(AppSettings.shared.hardwareDecoding ? "켬" : "끔")\(isBuffering ? " · 버퍼링 중" : "")")
        debugLines = lines
    }

    private func readAheadBytes(duration: Double) -> Int64 {
        Int64(Double(file.size) / duration * Double(AppSettings.shared.networkBufferSeconds))
    }

    /// 바뀜 (2026-11-11): 받아 둔 바이트를 평균 비트레이트로 시간으로 바꿔 재생 위치 앞에 붙인다 (소리·영상이 떨어진 파일, 탐색 직후에도 맞게)
    /// 바뀜 (2026-11-28, 사용자: 앞으로 계속 탐색하다 보면 버퍼 막대가 안 보임): 보통 파일은 받아 둔 끝 바이트를 파일 크기로 나눠 그렸는데,
    ///   버퍼는 바이트·재생 막대는 시간이라 지나온 부분이 평균보다 가벼운(가변 비트레이트) 영상은 바이트 비율이 시간 비율보다 뒤처져
    ///   막대가 재생 위치 밑에 묻혔다. 이제 파일 목차(MP4 moov·MKV Cues)로 받아 둔 끝 바이트를 정확한 시각으로 바꾼다.
    ///   목차가 없는 형식(AVI·TS 등)이나 아직 못 꺼냈으면 받아 둔 양을 평균 비트레이트로 나눈 시간을 재생 위치 앞에 붙인다.
    private func updateBufferedFraction() {
        guard let directReader, file.size > 0, duration > 0 else { return }
        let buffered = directReader.buffered
        let shown: Double
        if let interleaveSkew, interleaveSkew > MP4Interleave.threshold {
            let seconds = Double(buffered.ahead) / (Double(file.size) / duration)
            shown = min(1, (currentTime + seconds) / duration)
        } else if let timeline {
            let end = buffered.end >= file.size ? duration : timeline.time(atByte: buffered.end)
            shown = min(1, max(currentTime, end) / duration)
        } else {
            let seconds = Double(buffered.ahead) / (Double(file.size) / duration)
            shown = min(1, (currentTime + seconds) / duration)
        }
        if bufferedFraction.map({ abs($0 - shown) > 0.0005 }) ?? true { bufferedFraction = shown }
    }

    /// 재생 시간: VLC 시간이 바뀌면 그대로, 재생 중인데 멈춰 있으면 버퍼만큼까지 실제 흐른 시간으로 이어 센다
    private func updateCurrentTime() {
        let vlc = player.time.intValue
        if vlc != timeAnchor.vlc {
            timeAnchor = (vlc, Double(vlc) / 1000, Date())
            vlcTimeChangedAt = timeAnchor.at
            currentTime = timeAnchor.time
        } else if isStalled {
            // 직접 읽기에서 데이터를 기다리는 중이면 실제로 멈춘 것이므로 지금 보이는 시간에 세워 둔다
            timeAnchor.time = currentTime
            timeAnchor.at = Date()
        } else if wantsPlay, player.isPlaying, hasFirstFrame {
            let elapsed = Date().timeIntervalSince(timeAnchor.at) * Double(player.rate)
            currentTime = clampTime(timeAnchor.time + min(elapsed, bufferedSeconds))
        } else {
            // 일시 정지 중(AirPlay 로 넘긴 동안, 전화 등으로 끊긴 동안 포함)에는 흐른 시간을 세지 않는다
            timeAnchor.at = Date()
            currentTime = timeAnchor.time
        }
    }

    /// 불러오는 중·버퍼링 표시
    private func updateLoading(_ state: VLCMediaPlayerState) {
        if !hasFirstFrame {
            // 실제로 화면에 한 장이라도 그려졌는지로 본다 (영상 앞부분이 원래 검은 화면이어도 구분된다). 소리만 있는 파일은 시간이 흐르면.
            let pictures = player.media?.statistics.displayedPictures ?? 0
            if pictures > 0 || (currentTime > 0.5 && player.videoSize == .zero) {
                hasFirstFrame = true
                isSlowToLoad = false
                saveMediaInfo()
                timeAnchor.at = Date()
            } else {
                let waited = Date().timeIntervalSince(openedAt)
                if waited > 10 { isSlowToLoad = true }
                // 연결이 안 되면 VLC 는 오류가 아니라 끝남·멈춤으로 끝나기도 한다. 30초가 지나도 아무것도 없으면 포기한다.
                if playbackError == nil, (waited > 1 && (state == .ended || state == .stopped)) || waited > 30 {
                    playbackError = "영상을 불러오지 못했습니다. 서버가 켜져 있는지, 네트워크가 연결돼 있는지 확인해 주세요."
                }
            }
            return
        }
        guard wantsPlay, scrubTime == nil, state != .ended, state != .stopped, state != .error else {
            isBuffering = false
            return
        }
        // 장면이 계속 나오고 있으면 멈춘 게 아니다. VLC 는 재생이 다시 시작된 뒤에도 앞쪽 미리 읽기(16MB)를 채우느라
        // 우리 리더를 계속 기다리고, VLC 시간은 띄엄띄엄 바뀌어서 그 둘만 보면 로딩 표시가 늦게 사라졌다.
        let pictures = player.media?.statistics.displayedPictures ?? 0
        if pictures != displayedPictures {
            displayedPictures = pictures
            pictureShownAt = Date()
        }
        if player.videoSize != .zero, Date().timeIntervalSince(pictureShownAt) < 0.5 {
            isBuffering = false
            return
        }
        // 직접 읽기면 VLC 가 데이터를 기다리는지 안다
        if directReader != nil {
            isBuffering = isStalled
            return
        }
        // VLC 시간이 버퍼로 버틸 시간보다 오래 멈춰 있으면 버퍼가 바닥나 실제로 멈춘 것으로 본다
        isBuffering = Date().timeIntervalSince(timeAnchor.at) > bufferedSeconds
    }

    /// 처음 재생이 시작됐을 때: 영상별 싱크, 자막 적용
    private func didStart() {
        let saved = store.state(for: file.stateKey)
        subtitleDelay = saved.subtitleDelay
        audioDelay = saved.audioDelay
        if let audio = saved.audioTrackID, (player.audioTrackIndexes as? [NSNumber])?.contains(where: { $0.int32Value == audio }) == true {
            player.currentAudioTrackIndex = audio
            selectedAudioID = audio
        }
        if let choice = initialSubtitle() {
            Task { await applySubtitle(choice) }
        } else {
            selectedSubtitle = .embedded(player.currentVideoSubTitleIndex)
        }
    }

    /// 라이브러리·홈·검색에서 연 영상은 폴더 목록 없이 오므로, 같은 폴더에서 같은 이름의 자막 파일을 찾는다
    private func findSidecarSubtitles() {
        let file = file
        Task { [weak self] in
            guard let items = try? await DirectoryLister.items(in: file.url.deletingLastPathComponent(), serverID: file.serverID) else { return }
            let found = SubtitleLoader.sidecars(for: file.url, in: items.filter { !$0.isDirectory }.map(\.url))
            guard let self, !found.isEmpty else { return }
            let hadNone = externalSubtitles.isEmpty
            externalSubtitles += found.filter { !externalSubtitles.contains($0) }
            refreshTracks()
            // 재생이 먼저 시작돼 자막을 이미 정했으면: 따로 고른 적이 없을 때만 찾은 자막을 켠다
            let saved = store.state(for: file.stateKey)
            if started, hadNone, saved.subtitleBookmark == nil, saved.subtitleTrackID == nil, let first = found.first {
                await applySubtitle(.external(first))
            }
        }
    }

    /// 처음 적용할 자막: 영상별로 기억한 선택 → 같은 이름의 자막 파일 순. nil 이면 VLC 기본 선택(영상 안의 자막)을 따른다.
    private func initialSubtitle() -> SubtitleChoice? {
        let saved = store.state(for: file.stateKey)
        if let bookmark = saved.subtitleBookmark {
            var stale = false
            if let url = try? URL(resolvingBookmarkData: bookmark, bookmarkDataIsStale: &stale) {
                if url.startAccessingSecurityScopedResource() { subtitleAccessURL = url }
                if !externalSubtitles.contains(url) { externalSubtitles.append(url) }
                return .external(url)
            }
        }
        if let trackID = saved.subtitleTrackID {
            return trackID == -1 ? .off : .embedded(trackID)
        }
        return externalSubtitles.first.map { .external($0) }
    }

    private func updateSubtitleText() {
        guard !cues.isEmpty else { return }
        let time = (scrubTime ?? currentTime) - Double(subtitleDelay) / 1000
        let text = SubtitleParser.text(in: cues, at: time)
        if text != subtitleText { subtitleText = text }
    }

    private func refreshTracks() {
        var vlcExternal = vlcExternalNames.makeIterator()
        let embedded = tracks(names: player.videoSubTitlesNames, ids: player.videoSubTitlesIndexes)
            .filter { $0.id != -1 }
            .compactMap { track -> SubtitleOption? in
                // VLC 에 붙인 외부 자막은 외부 자막 항목으로 이미 보이므로 뺀다
                if track.name.range(of: #"^Track \d+$"#, options: .regularExpression) != nil, vlcExternal.next() != nil {
                    return nil
                }
                return SubtitleOption(choice: .embedded(track.id), name: track.name)
            }
        let external = externalSubtitles.map { SubtitleOption(choice: .external($0), name: $0.subtitleName) }
        let options = [SubtitleOption(choice: .off, name: "끄기")] + external + embedded
        if options != subtitleOptions { subtitleOptions = options }
        audioTracks = tracks(names: player.audioTrackNames, ids: player.audioTrackIndexes)
        selectedAudioID = player.currentAudioTrackIndex
    }

    private func tracks(names: [Any], ids: [Any]) -> [MediaTrack] {
        zip(names, ids).compactMap { name, id in
            guard let id = (id as? NSNumber)?.int32Value else { return nil }
            let title = (name as? String) ?? "트랙 \(id)"
            return MediaTrack(id: id, name: id == -1 ? "끄기" : title)
        }
    }

    /// 레터박스를 영상 색으로 채우기: 2초마다 영상을 아주 작게(폭 48px) 스냅숏으로 찍어 화면이 흐리게 늘려 깐다.
    /// VLC 3 에서 프레임을 꺼낼 방법은 스냅숏 파일뿐이라, 요청하고 잠시 뒤 파일을 읽는다.
    private func updateAmbient() {
        // 화면을 끄거나 다른 앱으로 가서 소리만 나는 동안에는 찍지 않는다 (VLC 가 그리지 않는다)
        #if os(iOS)
        guard UIApplication.shared.applicationState == .active else { return }
        #else
        guard NSApp.occlusionState.contains(.visible) || NSApp.isActive else { return }
        #endif
        if ambientHidden, Date().timeIntervalSince(surfaceChangedAt) > 0.5 { ambientHidden = false }
        let hasLetterbox = videoFrame.width < surfaceSize.width - 4 || videoFrame.height < surfaceSize.height - 4
        guard AppSettings.shared.ambientLetterbox, hasLetterbox, videoSize != .zero else {
            if ambientImage != nil { ambientImage = nil }
            return
        }
        let elapsed = Date().timeIntervalSince(ambientRequestedAt)
        if ambientPending, elapsed > 0.4 {
            ambientPending = false
            if let image = UIImage(contentsOfFile: ambientPath) { ambientImage = image }
            try? FileManager.default.removeItem(atPath: ambientPath)
        } else if isPlaying || ambientImage == nil, scrubTime == nil, elapsed > 2, player.hasVideoOut {
            // 영상 출력이 아직 없을 때 스냅숏을 찍으면 VLC 가 예외를 던져 앱이 죽는다 (느린 망에서 재생 시작 직후)
            ambientRequestedAt = Date()
            ambientPending = true
            // 바뀜 (2026-11-07): 가장자리 띠(약 1%)를 쓰므로 48px → 192px
            player.saveVideoSnapshot(at: ambientPath, withWidth: 192, andHeight: 0)
        }
    }

    /// 닫을 때 지금 장면을 찍어 정보 화면 그림으로 남긴 다음 멈춘다.
    /// VLC 는 다음 프레임에서 찍으므로 소리만 끄고 잠깐(최대 1초) 더 돌린다.
    private func captureResumeFrameAndStop() {
        let key = file.stateKey
        let position = store.state(for: key).position
        let frames = ResumeFrames.shared
        guard started, position > 0, player.hasVideoOut else {
            frames.cancel(key)
            directReader?.cancel()
            player.stop()
            // 바뀜 (2026-11-12, 사용자: 닫을 때 앱이 굳어 죽음): 마지막 해제는 뒤쪽 스레드에서 (VLCRelease)
            VLCRelease.later(player)
            return
        }
        let player = player
        let path = FileManager.default.temporaryDirectory.appending(path: "resume-\(UUID().uuidString).png").path
        frames.begin(key)
        player.audio?.isMuted = true
        player.saveVideoSnapshot(at: path, withWidth: 960, andHeight: 0)
        Task {
            var image: UIImage?
            for _ in 0..<20 {
                try? await Task.sleep(for: .milliseconds(50))
                if FileManager.default.fileExists(atPath: path) {
                    // 다 쓸 때까지 조금 더 기다린다
                    try? await Task.sleep(for: .milliseconds(100))
                    image = UIImage(contentsOfFile: path)
                    break
                }
            }
            self.directReader?.cancel()
            player.stop()
            VLCRelease.later(player)
            try? FileManager.default.removeItem(atPath: path)
            frames.finish(key, position: position, image: image)
        }
    }

    /// 이 영상의 재생 기록 바꾸기 (밖에서 연 파일이면 남기지 않는다)
    private func remember(_ change: (inout VideoPlaybackState) -> Void) {
        guard keepsRecords else { return }
        store.update(file.stateKey, change)
    }

    private func saveProgress() {
        lastSavedAt = Date()
        // 첫 장면이 나오기 전에는 재생 시간이 아직 0 이라, 저장하면 이어보기에서 빠진다
        guard started, hasFirstFrame, duration > 0 else { return }
        // 바뀜 (2026-11-25): 밖에서 연 파일은 위치도 이어보기도 남기지 않는다
        guard keepsRecords else { return }
        // 바뀜 (2026-11-11, 사용자): 다 본 것으로 표시된 영상은 다시 봐도 위치·이어보기를 남기지 않는다 (정보 화면에서 표시를 지우면 다시 남긴다)
        guard !store.isWatched(file.stateKey) else { return }
        let position = currentTime
        // 엔딩 크레딧까지 보지 않아도 90% 넘게 봤으면 다 본 것 (Plex 기본값과 같다)
        let finished = position > duration * 0.9
        remember {
            $0.position = finished ? 0 : position
            $0.duration = duration
            if finished { $0.watchedAt = .now }
        }
        // 홈의 이어보기에 쓴다 (몇 초 보다 만 영상은 남기지 않는다)
        if position > 30 || finished {
            WatchHistory.shared.record(file, finished: finished)
        }
    }

    private func clampTime(_ seconds: Double) -> Double {
        let upper = duration > 0 ? duration - 0.5 : seconds
        return min(max(seconds, 0), max(upper, 0))
    }
}
