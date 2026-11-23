import AVFoundation
import SwiftUI

@main
struct IRayerApp: App {
    /// 화면 미러링으로 연결된 TV 에 영상만 보여주는 장면을 만든다
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        // 무음 모드에서도 영상 소리가 나도록
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        // 포스터 이미지 캐시
        URLCache.shared = URLCache(memoryCapacity: 64 << 20, diskCapacity: 512 << 20)
        // iCloud 동기화: 비밀번호·토큰은 iCloud 키체인으로, 나머지는 CloudKit
        Keychain.migrateToSynchronizable(except: [AdultFilter.pinAccount, AppLock.passcodeAccount])  // 바뀜 (2026-11-12): 앱 잠금 암호도 이 기기에만
        SyncEngine.shared.startAll()
    }

    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
        }
        // 키보드(아이패드): 메뉴 막대와 ⌘ 를 길게 눌렀을 때 나오는 단축키 목록에 보인다
        .commands { PlaybackCommands() }
        // 바뀜 (2026-11-12, 사용자): 앱 잠금 — 앱 전환 화면에서 흐리게, 돌아오면 Face ID (처음 켤 때도)
        .onChange(of: scenePhase, initial: true) { _, phase in AppLock.shared.scenePhaseChanged(phase) }
        .onChange(of: scenePhase) { _, phase in
            // 앱으로 돌아올 때마다 자동 잠금 설정을 다시 적용한다 (재생 중이면 플레이어가 다시 끈다)
            if phase == .active {
                AppSettings.shared.applyIdleTimer(playing: ExternalDisplay.shared.player != nil)
                // 다른 기기에서 바꾼 것 받기
                Task { await SyncEngine.shared.syncNow() }
            }
        }
    }
}
