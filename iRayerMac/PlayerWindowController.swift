import AppKit
import SwiftUI

/// 지금 열린 재생 창의 동작 (메뉴 막대·단축키가 쓴다)
@MainActor
@Observable
final class MacPlayback {
    static private(set) weak var current: MacPlayback?

    let model: PlayerModel
    /// 이 창의 재생 (PlayerHost.Request.id)
    let requestID: UUID
    @ObservationIgnored weak var window: NSWindow?
    /// 다음 영상으로 넘어와 창 크기·위치를 그대로 둔다 (영상 비율만 맞춘다)
    @ObservationIgnored var keepsWindowSize = false
    /// 항상 위에 두기 (다음 영상에도 이어진다)
    var alwaysOnTop = UserDefaults.standard.bool(forKey: "playerAlwaysOnTop") {
        didSet {
            UserDefaults.standard.set(alwaysOnTop, forKey: "playerAlwaysOnTop")
            applyLevel()
        }
    }
    private(set) var isFullScreen = false
    /// 볼륨 0~1.25. 1 이 원래 크기(macOS 볼륨 그대로)라 슬라이더의 80% 자리, 끝은 25% 키운 소리
    /// (VLC 데스크톱의 최대 125% 와 같다). 다음 영상에도 이어진다
    static let maxVolume = 1.25
    var volume = UserDefaults.standard.object(forKey: "playerVolume") as? Double ?? 1 {
        didSet {
            // @Observable 에서는 didSet 안에서 다시 넣어도 didSet 이 또 불린다 → 범위 안이면 그만 (안 그러면 끝없이 불러 강제 종료)
            let clamped = min(max(volume, 0), Self.maxVolume)
            guard clamped == volume else { volume = clamped; return }
            UserDefaults.standard.set(volume, forKey: "playerVolume")
            model.player.audio?.volume = Int32((volume * 100).rounded())
        }
    }

    init(model: PlayerModel, requestID: UUID, window: NSWindow) {
        self.model = model
        self.requestID = requestID
        self.window = window
        Self.current = self
        applyLevel()
        model.player.audio?.volume = Int32((volume * 100).rounded())
    }

    /// 설정한 시간만큼 건너뛴다 (far: 그 5배, ⌘← ⌘→)
    func skip(forward: Bool, far: Bool = false) {
        let seconds = Double(AppSettings.shared.skipSeconds) * (far ? 5 : 1)
        model.skip(by: forward ? seconds : -seconds)
        model.touchControls()
    }

    /// 시리즈 회차·재생목록이면 그 대기열 (한 개뿐이면 없음)
    var queue: PlayQueue? {
        PlayerHost.shared.queue(of: requestID).flatMap { $0.files.count > 1 ? $0 : nil }
    }

    /// 대기열의 다음·이전 영상으로 (같은 창에서). 다음으로 넘기면 보던 영상은 다 본 것으로 한다
    func step(forward: Bool) {
        guard let queue, let file = forward ? queue.next : queue.previous else { return }
        (window?.delegate as? PlayerWindowController)?.advance(to: file, finishing: forward)
    }

    /// 다음 화 버튼을 눌렀거나 끝난 뒤 시간이 다 됐을 때 다음 영상으로
    func playNext() {
        guard let next = queue?.next else { return }
        (window?.delegate as? PlayerWindowController)?.advance(to: next, finishing: false)
    }

    func toggleAlwaysOnTop() {
        alwaysOnTop.toggle()
    }

    func toggleFullScreen() {
        window?.toggleFullScreen(nil)
    }

    fileprivate func fullScreenChanged(_ on: Bool) {
        isFullScreen = on
        applyLevel()
    }

    /// 전체 화면에서는 위에 띄울 필요가 없다
    private func applyLevel() {
        window?.level = alwaysOnTop && !isFullScreen ? .floating : .normal
    }

    /// 영상 크기를 알게 되면 창을 영상 비율로 묶고 원본 크기로 연다 (SD 는 작게 열리고 조작 막대가 간소해진다)
    func fitWindow(to videoSize: CGSize) {
        guard let window, videoSize.width > 0, videoSize.height > 0, !isFullScreen else { return }
        window.contentAspectRatio = videoSize
        if keepsWindowSize {
            // 다음 영상: 폭과 가운데는 그대로 두고 높이만 영상 비율에 맞춘다
            let frame = window.frame
            let height = (frame.width * videoSize.height / videoSize.width).rounded()
            guard abs(height - frame.height) > 1 else { return }
            window.setFrame(NSRect(x: frame.minX, y: frame.midY - height / 2, width: frame.width, height: height), display: true, animate: true)
            return
        }
        resizeWindow(.actual)
    }

    /// 창 크기: 영상 원본(화소 1:1, ⌘1) · 2배(⌘2) · 화면에 꽉 차게 가운데로(⌘3).
    /// 원본·2배는 창 가운데를 두고 키우되 화면을 넘으면 화면 안에 맞춘다.
    enum WindowSize { case actual, double, fitScreen }

    func resizeWindow(_ size: WindowSize) {
        guard let window, let screen = window.screen ?? NSScreen.main, !isFullScreen else { return }
        let video = model.videoSize
        guard video.width > 0, video.height > 0 else { return }
        let visible = screen.visibleFrame
        // 레티나는 점 하나에 화소 둘이라 원본 화소 크기를 점으로 나눈다
        let actual = CGSize(width: video.width / screen.backingScaleFactor, height: video.height / screen.backingScaleFactor)
        var target: CGSize = switch size {
        case .actual: actual
        case .double: CGSize(width: actual.width * 2, height: actual.height * 2)
        case .fitScreen: visible.size
        }
        // 비율을 지키며 화면 안에 들어가게
        let scale = min(1, visible.width / target.width, visible.height / target.height)
        if size == .fitScreen {
            let fit = min(visible.width / video.width, visible.height / video.height)
            target = CGSize(width: video.width * fit, height: video.height * fit)
        } else {
            target = CGSize(width: target.width * scale, height: target.height * scale)
        }
        // 창 최소 크기보다 작으면 비율을 지키며 키운다
        let grow = max(1, window.minSize.width / target.width, window.minSize.height / target.height)
        target = CGSize(width: target.width * grow, height: target.height * grow)
        target = CGSize(width: target.width.rounded(), height: target.height.rounded())
        let center = size == .fitScreen ? CGPoint(x: visible.midX, y: visible.midY) : CGPoint(x: window.frame.midX, y: window.frame.midY)
        var frame = NSRect(x: center.x - target.width / 2, y: center.y - target.height / 2, width: target.width, height: target.height)
        // 화면 밖으로 나가면 안으로 들인다
        frame.origin.x = min(max(frame.minX, visible.minX), visible.maxX - frame.width)
        frame.origin.y = min(max(frame.minY, visible.minY), visible.maxY - frame.height)
        window.setFrame(frame, display: true, animate: true)
    }

    /// 이 창이 앞으로 왔을 때: 메뉴 막대·단축키와 제어 센터·미디어 키가 이 영상을 따른다
    func becameFront() {
        Self.current = self
        NowPlaying.shared.attach(model)
    }

    func didClose() {
        guard Self.current === self else { return }
        // 남은 재생 창 중 맨 앞의 것으로 넘긴다
        Self.current = NSApp.orderedWindows.lazy.compactMap { ($0.delegate as? PlayerWindowController)?.playback }.first { $0 !== self }
    }
}

/// 재생 창: 제목 표시줄 없이 영상만 꽉 차게. 신호등은 마우스를 올리면 조작과 함께 보인다.
@MainActor
final class PlayerWindowController: NSObject, NSWindowDelegate {
    private let window: NSWindow
    private let id: UUID
    fileprivate var playback: MacPlayback?

    init(id: UUID, cascadeFrom previous: PlayerWindowController?) {
        self.id = id
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 540),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                          backing: .buffered, defer: false)
        super.init()
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.backgroundColor = .black
        window.collectionBehavior = [.fullScreenPrimary]
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 320, height: 180)
        window.delegate = self
        if let previous {
            // 두 번째부터: 앞 창 크기로 오른쪽 아래로 비켜서 (위치는 저장하지 않는다)
            window.setFrame(previous.window.frame, display: false)
            window.setFrameTopLeftPoint(window.cascadeTopLeft(from: NSPoint(x: previous.window.frame.minX, y: previous.window.frame.maxY)))
        } else {
            window.setFrameAutosaveName("PlayerWindow")
            if !window.setFrameUsingName("PlayerWindow") { window.center() }
        }
    }

    func bringToFront() {
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    func show(_ request: PlayerHost.Request) {
        let model = PlayerModel(file: request.file, resume: request.resume)
        let playback = MacPlayback(model: model, requestID: id, window: window)
        self.playback = playback
        window.title = request.file.title
        window.contentView = NSHostingView(rootView: MacPlayerView(playback: playback))
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
        model.start()
    }

    /// 같은 창에서 다른 영상으로 바꾼다 (다음·이전). 전체 화면·창 크기와 위치·항상 위는 그대로 이어진다.
    /// finishing: 보던 영상을 끝까지 안 봤어도 다 본 것으로
    func advance(to file: VideoFile, finishing: Bool) {
        guard let old = playback else { return }
        PlayerHost.shared.moved(id, to: file)
        old.model.close()
        if finishing { LibraryData.markWatched(old.model.file) }
        let model = PlayerModel(file: file, resume: true)
        let playback = MacPlayback(model: model, requestID: id, window: window)
        playback.keepsWindowSize = true
        playback.fullScreenChanged(old.isFullScreen)
        self.playback = playback
        window.title = file.title
        window.contentView = NSHostingView(rootView: MacPlayerView(playback: playback))
        model.start()
    }

    func windowWillClose(_ notification: Notification) {
        playback?.model.close()
        playback?.didClose()
        playback = nil
        window.contentView = nil
        PlayerHost.shared.didClose(id)
    }

    func windowDidBecomeKey(_ notification: Notification) { playback?.becameFront() }

    func windowDidEnterFullScreen(_ notification: Notification) { playback?.fullScreenChanged(true) }
    func windowDidExitFullScreen(_ notification: Notification) { playback?.fullScreenChanged(false) }
}
