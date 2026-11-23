import SwiftUI

/// 메뉴 막대: 재생 메뉴. 스페이스·화살표는 재생 창 안에서만 받는다 (검색칸 입력을 가로채지 않게).
struct MacCommands: Commands {
    var body: some Commands {
        // 보기 메뉴: 지금 화면을 다시 읽는다 (맥은 당겨서 새로 고침이 없다)
        CommandGroup(before: .toolbar) {
            Button("새로 고침") { RefreshSignal.shared.send() }
                .keyboardShortcut("r")
            Divider()
        }
        CommandMenu("재생") {
            Button("재생/일시 정지 (스페이스)") { MacPlayback.current?.model.togglePlay() }
            Button("앞으로 건너뛰기 (→)") { MacPlayback.current?.skip(forward: true) }
            Button("뒤로 건너뛰기 (←)") { MacPlayback.current?.skip(forward: false) }
            Button("앞으로 많이 건너뛰기 (⌘→)") { MacPlayback.current?.skip(forward: true, far: true) }
            Button("뒤로 많이 건너뛰기 (⌘←)") { MacPlayback.current?.skip(forward: false, far: true) }
            Divider()
            Button("원본 크기") { MacPlayback.current?.resizeWindow(.actual) }
                .keyboardShortcut("1")
            Button("2배 크기") { MacPlayback.current?.resizeWindow(.double) }
                .keyboardShortcut("2")
            Button("화면에 맞추기") { MacPlayback.current?.resizeWindow(.fitScreen) }
                .keyboardShortcut("3")
            Divider()
            Button("항상 위에 두기") { MacPlayback.current?.toggleAlwaysOnTop() }
                .keyboardShortcut("t", modifiers: [.command, .option])
            Button("전체 화면") { MacPlayback.current?.toggleFullScreen() }
                .keyboardShortcut("f", modifiers: [.command, .control])
        }
    }
}
