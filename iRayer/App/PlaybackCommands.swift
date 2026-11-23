import SwiftUI

/// 키보드 명령 (아이패드): 영상은 스페이스 재생/일시정지·←→ 건너뛰기·esc 닫기, 이미지뷰어는 ←→ 쪽 넘기기·스페이스 다음 쪽·esc 닫기.
/// 메뉴 막대에 "재생"·"이미지뷰어" 메뉴로 보이고, 화면이 열려 있지 않으면 꺼진다 (검색창 등에서 스페이스·화살표를 먹지 않게).
struct PlaybackCommands: Commands {
    @State private var host = PlayerHost.shared
    @State private var external = ExternalDisplay.shared

    var body: some Commands {
        CommandMenu("재생") {
            Group {
                Button("재생/일시정지") { player?.togglePlay() }
                    .keyboardShortcut(.space, modifiers: [])
                Button("뒤로 건너뛰기") { player?.skip(by: -Double(AppSettings.shared.skipSeconds)) }
                    .keyboardShortcut(.leftArrow, modifiers: [])
                Button("앞으로 건너뛰기") { player?.skip(by: Double(AppSettings.shared.skipSeconds)) }
                    .keyboardShortcut(.rightArrow, modifiers: [])
                Button("닫기") { host.close() }
                    .keyboardShortcut(.escape, modifiers: [])
            }
            .disabled(player == nil)
        }
        CommandMenu("이미지뷰어") {
            Group {
                Button("왼쪽 쪽") { ComicReader.current?.turnByKey(left: true) }
                    .keyboardShortcut(.leftArrow, modifiers: [])
                Button("오른쪽 쪽") { ComicReader.current?.turnByKey(left: false) }
                    .keyboardShortcut(.rightArrow, modifiers: [])
                Button("다음 쪽") {
                    if let reader = ComicReader.current { reader.turnByKey(left: reader.settings.rightToLeft) }
                }
                .keyboardShortcut(.space, modifiers: [])
                Button("닫기") { ComicReader.current?.onClose?() }
                    .keyboardShortcut(.escape, modifiers: [])
            }
            .disabled(player != nil || ComicReader.current == nil)
        }
    }

    /// 화면에 떠 있는 플레이어 (PiP 중에는 앱 화면을 조작하므로 끈다)
    private var player: PlayerModel? {
        host.request != nil && !host.inSystemPiP ? external.player : nil
    }
}
