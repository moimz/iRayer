import SwiftUI

/// 메뉴 막대: 재생 메뉴. 스페이스·화살표는 재생 창 안에서만 받는다 (검색칸 입력을 가로채지 않게).
struct MacCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        // Dock 아이콘으로 라이브러리 창을 다시 여는 동작 (AppDelegate.applicationShouldHandleReopen).
        // 바뀜 (2026-11-27): 라이브러리 창 안(LibraryReopener)에서 넘기던 것을 메뉴 쪽으로 — 영상 파일로 켜면 라이브러리 창이
        // 한 번도 만들어지지 않아(handlesExternalEvents) 넘겨받지 못했고, 재생 창만 있을 때 Dock 을 눌러도 안 열렸다 (사용자)
        let _ = { [openWindow] in AppDelegate.openLibrary = { openWindow(id: "library") } }()
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
        // 도움말: 저장소 · 문제 신고 (Ai.md "도움말 메뉴", 도움말 책이 없어 기본 "iRayer 도움말" 은 뺀다)
        CommandGroup(replacing: .help) {
            Button("iRayer GitHub 페이지") { NSWorkspace.shared.open(URL(string: "https://github.com/moimz/iRayer")!) }
            Button("문제 신고…") { NSWorkspace.shared.open(issueURL) }
        }
    }

    /// 새 이슈 화면, 본문에 앱 · macOS 버전만 미리 채운다 (개인 정보는 넣지 않는다)
    private var issueURL: URL {
        let os = ProcessInfo.processInfo.operatingSystemVersion
        var c = URLComponents(string: "https://github.com/moimz/iRayer/issues/new")!
        c.queryItems = [URLQueryItem(name: "body", value: "\n\n---\niRayer \(UpdateSection.version) · macOS \(os.majorVersion).\(os.minorVersion).\(os.patchVersion)")]
        return c.url!
    }
}
