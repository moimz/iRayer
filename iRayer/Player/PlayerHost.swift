import Observation
import SwiftUI
import UIKit

/// 앱 전체에 하나뿐인 플레이어. 어디서 재생하든 여기로 요청한다.
/// 플레이어는 앱 화면 위의 별도 창에 뜬다. PiP 는 아이폰 기본 PiP (SystemPiP) 이고, 그동안 이 창은 숨는다.
@MainActor
@Observable
final class PlayerHost {
    static let shared = PlayerHost()

    struct Request: Identifiable {
        let id = UUID()
        /// 지금 재생 중인 영상 (대기열에서 다음으로 넘어가면 바뀐다)
        var file: VideoFile
        let resume: Bool
        /// 다 보면 이어서 재생할 영상들 (시리즈 회차·재생목록). 없으면 끝나면 멈춘다
        var queue: PlayQueue?
    }

    /// 지금 열려 있는 재생 (없으면 nil)
    private(set) var request: Request?

    /// 이 영상이 지금 플레이어에 열려 있는지
    func isOpen(_ file: VideoFile) -> Bool {
        request?.file.stateKey == file.stateKey
    }
    /// 아이폰 기본 PiP 로 보는 중 (플레이어 창은 숨어 있다)
    private(set) var inSystemPiP = false

    // MARK: AirPlay 접어 두기 (2026-11-11, 사용자: AirPlay 중에도 우리 앱을 쓰고 싶다)
    // PiP 처럼 플레이어 창만 숨기고, TV 재생은 그대로 둔다. 앱 아래(탭 막대 위)에 작은 재생 막대가 뜬다.

    /// TV 로 보내는 중인 재생 (PlayerView 가 알린다)
    private(set) var airPlay: AirPlaySession?
    /// AirPlay 중 플레이어 창을 접어 두었다
    private(set) var airPlayCollapsed = false
    /// 접어 둔 동안 다른 영상을 눌렀다: TV 영상을 바꿀지 묻는다
    var pendingPlay: Request?
    /// 다음에 여는 영상을 열자마자 TV 로 보낸다 (TV 영상 바꾸기)
    @ObservationIgnored private var sendNextToAirPlay = false

    /// 창이 숨어 있는지 (PiP 또는 AirPlay 접어 둠)
    fileprivate var windowHidden: Bool { inSystemPiP || airPlayCollapsed }

    @ObservationIgnored private var window: PlayerWindow?

    private init() {}

    /// 영상을 전체 화면으로 재생한다. 이미 재생 중이면 그 영상을 닫고 바꾼다.
    /// queue 를 주지 않아도 라이브러리의 시리즈 회차면 다음 회차로 이어진다.
    func play(_ file: VideoFile, resume: Bool, queue: PlayQueue? = nil) {
        let next = Request(file: file, resume: resume, queue: queue ?? PlayQueue.series(for: file))
        // 바뀜 (2026-11-11): AirPlay 를 접어 둔 채 다른 영상을 누르면 바로 바꾸지 않고 묻는다
        if airPlay != nil, request != nil {
            if request?.file.stateKey == file.stateKey { expandAirPlay() } else { pendingPlay = next }
            return
        }
        open(next)
    }

    /// 물어본 영상으로 TV 영상을 바꾼다 (보던 AirPlay 는 플레이어가 닫히며 끝나고, 새 영상을 열자마자 TV 로 보낸다)
    func confirmPendingPlay() {
        guard let next = pendingPlay else { return }
        pendingPlay = nil
        sendNextToAirPlay = AirPlayHandoff.isAirPlayRoute
        airPlayCollapsed = false
        // 보던 플레이어는 사라지며 TV 재생을 끝낸다 (그 플레이어가 알려 주지 못하므로 여기서 지운다)
        airPlay = nil
        open(next)
    }

    /// 새로 연 플레이어가 TV 로 바로 보낼지 (한 번만)
    func takeSendToAirPlay() -> Bool {
        defer { sendNextToAirPlay = false }
        return sendNextToAirPlay
    }

    /// PlayerView 가 AirPlay 시작·끝을 알린다. 끝났는데 접어 두었으면(연결이 끊김 등) 플레이어를 다시 보여준다 (폰에서 이어 본다)
    func setAirPlay(_ session: AirPlaySession?) {
        airPlay = session
        if session == nil, airPlayCollapsed { expandAirPlay() }
    }

    /// AirPlay 재생 화면의 접기: 플레이어 창을 숨기고 앱을 쓴다
    func collapseAirPlay() {
        guard airPlay != nil else { return }
        airPlayCollapsed = true
        window?.isHidden = true
        updateKeyWindow()
    }

    /// 작은 재생 막대를 누르면 다시 펼친다
    func expandAirPlay() {
        airPlayCollapsed = false
        guard request != nil else { return }
        window?.isHidden = false
        updateKeyWindow()
    }

    private func open(_ next: Request) {
        showWindow()
        inSystemPiP = false
        request = next
        updateKeyWindow()
    }

    /// 플레이어 안에서 다른 영상으로 바꿨을 때 (다음·이전, 재생목록 시트). 플레이어는 그대로 두고 지금 영상·대기열만 바꾼다
    func moved(to file: VideoFile) {
        guard var current = request else { return }
        current.queue = current.queue?.moved(to: file) ?? PlayQueue.series(for: file)
        current.file = file
        request = current
    }

    func close() {
        // 정보 화면은 닫는 순간 다시 그려지므로, 플레이어가 마지막 장면을 찍는다는 것을 먼저 알린다
        if let file = request?.file {
            ResumeFrames.shared.begin(file.stateKey)
            // 홈 이어보기 등 바로 재생한 목록이 그 카드를 보여준다
            ReturnHighlight.shared.returned(from: file)
        }
        request = nil
        inSystemPiP = false
        airPlayCollapsed = false
        airPlay = nil
        pendingPlay = nil
        updateKeyWindow()
        // 플레이어 화면이 사라지며(onDisappear) 재생을 멈춘 다음에 창을 숨긴다
        DispatchQueue.main.async { [weak self] in
            if self?.request == nil { self?.window?.isHidden = true }
        }
    }


    /// 아이폰 기본 PiP 로 넘어가면 플레이어 창을 숨긴다 (재생은 PiP 에서 이어진다)
    func hideForSystemPiP() {
        window?.isHidden = true
        inSystemPiP = true
        updateKeyWindow()
    }

    /// PiP 에서 크게 보기로 돌아오거나 PiP 를 닫으면 플레이어를 다시 보여준다
    func showAfterSystemPiP() {
        guard request != nil else { return }
        inSystemPiP = false
        window?.isHidden = windowHidden
        updateKeyWindow()
    }

    /// 재생을 누른 창 (아이패드는 앱 창을 여러 개 띄울 수 있다): 지금 앞에 있는 창, 없으면 첫 번째 창
    private var activeScene: UIWindowScene? {
        let scenes = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .filter { $0.session.role == .windowApplication }
        return scenes.first { $0.activationState == .foregroundActive && $0.windows.contains(where: \.isKeyWindow) }
            ?? scenes.first { $0.activationState == .foregroundActive }
            ?? scenes.first
    }

    private func showWindow() {
        // 플레이어 창이 다른 앱 창에 있으면 지금 창으로 옮긴다
        if let window, let scene = activeScene, window.windowScene !== scene {
            window.windowScene = scene
        }
        if window == nil {
            guard let scene = activeScene else { return }
            let window = PlayerWindow(windowScene: scene)
            // 앱 화면의 시트·알림보다 위, 키보드보다는 아래
            window.windowLevel = .normal + 1
            window.overrideUserInterfaceStyle = AppSettings.shared.appearance.style
            window.backgroundColor = .clear
            let host = UIHostingController(rootView: PlayerOverlay())
            host.view.backgroundColor = .clear
            window.rootViewController = host
            self.window = window
        }
        window?.isHidden = false
    }

    /// 재생 중에는 플레이어 창이, 아니면(PiP 중 포함) 앱 화면이 키 창이 된다 (상태 표시줄·키보드 입력이 그쪽을 따른다)
    private func updateKeyWindow() {
        guard let window else { return }
        if request != nil, !windowHidden {
            window.makeKey()
        } else {
            window.windowScene?.windows.first { !($0 is PlayerWindow) && !$0.isHidden }?.makeKey()
        }
    }
}

/// 플레이어 창
private final class PlayerWindow: UIWindow {
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard let hit = super.hitTest(point, with: event) else { return nil }
        let host = PlayerHost.shared
        return host.request == nil || host.windowHidden ? nil : hit
    }
}

/// 플레이어 창의 내용
private struct PlayerOverlay: View {
    @State private var host = PlayerHost.shared

    var body: some View {
        if let request = host.request {
            PlayerView(file: request.file, resume: request.resume)
                .id(request.id)
        }
    }
}
