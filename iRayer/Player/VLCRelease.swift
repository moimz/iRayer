import Foundation
#if os(macOS)
import VLCKit
#else
import MobileVLCKit
#endif

/// 다 쓴 VLC 재생기를 메인 스레드가 아닌 곳에서 놓아 준다 (2026-11-12, 사용자).
/// VLC 3 은 닫을 때 가끔 안쪽 스레드끼리 서로 기다리다 영원히 멈춘다 (libvlc_media_player_destroy → 디코더 스레드 join).
/// 마지막 해제가 메인 스레드에서 일어나면 앱 화면이 통째로 굳고 시스템이 앱을 죽였다 (8BADF00D).
/// 여기서 붙잡아 두었다가 다른 곳(SwiftUI·PiP·VLC 가 메인으로 보낸 알림 등)이 모두 놓으면 뒤쪽 스레드에서 마지막으로 놓는다.
/// 거기서 멈추면 그 스레드만 멈춘 채 남는다 (앱을 끌 때까지 메모리를 조금 차지).
nonisolated enum VLCRelease {
    private final class Holder: @unchecked Sendable {
        var player: VLCMediaPlayer?
        var others: [AnyObject?]
        init(_ player: VLCMediaPlayer, _ others: [AnyObject?]) {
            self.player = player
            self.others = others
        }
    }

    /// player 는 멈춘(stop) 뒤에 넘긴다. others 는 VLC 가 닫힐 때까지 살아 있어야 하는 것 (소리·장면 콜백 등) — 재생기를 놓은 뒤에 놓는다
    static func later(_ player: VLCMediaPlayer, keeping others: [AnyObject?] = []) {
        let holder = Holder(player, others)
        // 멈추면 그 스레드를 영영 쥐고 있으므로 GCD 일꾼 대신 따로 스레드를 연다
        let thread = Thread {
            // 다른 곳(재생 화면 모델 등)이 다 놓을 때까지 (최대 10분). 꺼내 보는 동안 하나 더 붙으므로 릴리스 빌드는 2, 디버그는 3 이하면 여기만 쥔 것 (맥에서 재어 봄)
            #if DEBUG
            let alone = 3
            #else
            let alone = 2
            #endif
            for _ in 0..<1200 {
                guard let player = holder.player else { break }
                if CFGetRetainCount(player) <= alone { break }
                Thread.sleep(forTimeInterval: 0.5)
            }
            holder.player = nil
            holder.others = []
        }
        thread.name = "iRayer.vlc-release"
        thread.qualityOfService = .utility
        thread.start()
    }
}
