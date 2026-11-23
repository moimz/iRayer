import AVKit
import Observation
import SwiftUI
import UserNotifications
import UIKit

/// 화면 미러링(AirPlay)이나 케이블로 연결된 TV.
/// 재생 중이면 TV 에는 영상과 자막만 꽉 차게 보여주고, 폰에는 조작 화면을 그대로 둔다.
/// (VLC 는 영상을 직접 그리므로 AirPlay 로 영상 주소를 넘기는 방식은 쓸 수 없다)
@Observable
final class ExternalDisplay {
    static let shared = ExternalDisplay()

    /// TV 가 연결돼 있다
    fileprivate(set) var isConnected = false
    /// 지금 재생 중인 플레이어 (PlayerView 가 열려 있는 동안)
    var player: PlayerModel?

    private init() {}
}

/// 외부 화면 장면을 만든다. 앱 본 화면은 SwiftUI 가 그대로 만든다.
final class AppDelegate: NSObject, UIApplicationDelegate {
    // 바뀜 (2026-11-12, 사용자): 맥에서 오는 알림 — 앱을 보고 있을 때도 배너로, 켜 둔 구독을 다시 단다
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = Notice.Presenter.shared
        Notice.refresh()
        return true
    }

    func application(
        _ application: UIApplication,
        configurationForConnecting connectingSceneSession: UISceneSession,
        options: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(name: nil, sessionRole: connectingSceneSession.role)
        if connectingSceneSession.role == .windowExternalDisplayNonInteractive {
            configuration.delegateClass = ExternalSceneDelegate.self
        }
        return configuration
    }
}

/// TV 화면 장면. Info.plist 에서 이름(문자열)으로 찾으므로 Objective-C 이름을 고정한다.
@objc(ExternalSceneDelegate)
final class ExternalSceneDelegate: NSObject, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        guard let windowScene = scene as? UIWindowScene else { return }
        let window = UIWindow(windowScene: windowScene)
        let host = UIHostingController(rootView: ExternalDisplayView())
        host.view.backgroundColor = .black
        window.rootViewController = host
        window.isHidden = false
        self.window = window
        ExternalDisplay.shared.isConnected = true
    }

    func sceneDidDisconnect(_ scene: UIScene) {
        ExternalDisplay.shared.isConnected = false
        window = nil
    }
}

/// iOS 27 부터는 Info.plist 선언만으로는 TV 화면 장면이 만들어지지 않는다.
/// 화면 안의 뷰 컨트롤러가 "외부 화면에 보여줄 내용이 있다"고 직접 등록해야 한다 (`registerSceneAccessory`).
/// 재생 화면에 붙여 두면, 재생하는 동안만 TV 에 영상 전용 화면이 나오고 그 밖에는 평소처럼 미러링된다.
struct ExternalDisplayRegistrar: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> UIViewController {
        if #available(iOS 27.0, *) {
            return ExternalDisplayRegistrarController()
        }
        return UIViewController()
    }

    func updateUIViewController(_ controller: UIViewController, context: Context) {}
}

@available(iOS 27.0, *)
private final class ExternalDisplayRegistrarController: UIViewController {
    private var registration: UISceneAccessoryRegistration?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        view.isUserInteractionEnabled = false
        let configuration = UISceneConfiguration(name: nil, sessionRole: .windowExternalDisplayNonInteractive)
        configuration.delegateClass = ExternalSceneDelegate.self
        registration = registerSceneAccessory(.externalNonInteractive(sceneConfiguration: configuration))
    }

    deinit {
        if let registration { unregisterSceneAccessory(registration) }
    }
}

/// TV 화면: 재생 중이면 영상 + 자막, 아니면 검은 화면에 앱 이름
private struct ExternalDisplayView: View {
    @State private var display = ExternalDisplay.shared

    var body: some View {
        ZStack {
            Color.black
            if let model = display.player {
                GeometryReader { geometry in
                    ZStack {
                        ExternalVideoView(model: model)
                            // 재생목록에서 영상을 바꾸면 새 플레이어가 TV 뷰에 다시 붙도록 새로 만든다
                            .id(ObjectIdentifier(model))
                        SubtitleOverlay(text: model.subtitleText, videoBottomInset: videoBottomInset(model, in: geometry.size), raised: false)
                    }
                }
            } else {
                Text("iRayer")
                    .font(.largeTitle.bold())
                    .foregroundStyle(.white.opacity(0.3))
            }
        }
        .ignoresSafeArea()
    }

    /// 화면에 맞춘(contain) 영상의 아래쪽 가장자리까지의 거리. 자막을 영상 안쪽 아래에 붙인다.
    private func videoBottomInset(_ model: PlayerModel, in size: CGSize) -> CGFloat {
        guard model.videoSize.width > 0, model.videoSize.height > 0 else { return 0 }
        let scale = min(size.width / model.videoSize.width, size.height / model.videoSize.height)
        return (size.height - model.videoSize.height * scale) / 2
    }
}

/// TV 쪽 VLC 영상 뷰. 나타나면 VLC 가 이 뷰에 그리고, 사라지면 폰 화면으로 돌려준다.
private struct ExternalVideoView: UIViewRepresentable {
    let model: PlayerModel

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .black
        view.isUserInteractionEnabled = false
        model.attachExternal(view)
        return view
    }

    func updateUIView(_ view: UIView, context: Context) {}

    static func dismantleUIView(_ view: UIView, coordinator: ()) {
        // 어느 플레이어였는지는 뷰만으로 모르므로, 지금 플레이어가 이 뷰에 그리고 있을 때만 되돌린다
        ExternalDisplay.shared.player?.detachExternal(view)
    }
}
