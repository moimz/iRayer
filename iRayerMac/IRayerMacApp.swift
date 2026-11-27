import AppKit
import CoreText
import SwiftUI

@main
struct IRayerMacApp: App {
    @NSApplicationDelegateAdaptor private var delegate: AppDelegate

    init() {
        // 자막 글꼴(나눔): 아이폰은 Info.plist 의 UIAppFonts, 맥은 실행할 때 이 앱에서만 쓰게 등록한다 (VLC 가 그리는 자막도 이 이름으로 찾는다)
        if let urls = Bundle.main.urls(forResourcesWithExtension: "otf", subdirectory: nil), !urls.isEmpty {
            CTFontManagerRegisterFontURLs(urls as CFArray, .process, true, nil)
        }
        // 포스터 이미지 캐시
        URLCache.shared = URLCache(memoryCapacity: 64 << 20, diskCapacity: 512 << 20)
        // iCloud 동기화. 비밀번호·키는 iCloud 키체인으로.
        Keychain.migrateToSynchronizable(except: [AdultFilter.pinAccount])
        SyncEngine.shared.startAll()
    }

    var body: some Scene {
        Window("iRayer", id: "library") {
            // 바뀜 (2026-11-08, 사용자): 최소 폭 760 → 1000 — 좁으면 웹 탐색 주소칸이 도구 막대 넘침 메뉴로 빠졌다 (사이드바 포함, 어림값)
            LibraryView()
                .frame(minWidth: 1000, minHeight: 520)
                .background(LibraryReopener())
        }
        .windowToolbarStyle(.unified)
        // 바뀜 (2026-11-27, 사용자: 라이브러리 창이 떠 있을 때 영상을 두 번 누르면 창이 닫혔다 다시 열리는 듯 깜빡임):
        // SwiftUI 가 파일 열기를 이 창(장면)에 넘기며 다시 띄운다. 파일은 AppDelegate.application(_:open:) 가 받으므로 장면은 받지 않게 한다
        .handlesExternalEvents(matching: [])
        .commands {
            MacCommands()
            // iRayer에 관하여: 기본 정보 창 대신 직접 만든 창 (AboutView, 2026-11-23 사용자: iSQL 처럼)
            CommandGroup(replacing: .appInfo) {
                AboutMenuButton()
                // 자동 업데이트 (Sparkle, 1.0 부터)
                UpdateMenuButton()
            }
        }

        // iRayer 정보 창: 오픈 소스·TMDB 고지
        Window("iRayer 정보", id: AboutView.windowID) {
            AboutView()
        }
        .handlesExternalEvents(matching: [])
        .windowResizability(.contentSize)
        .windowStyle(.hiddenTitleBar)
        .restorationBehavior(.disabled)
        .defaultPosition(.center)

        Settings {
            MacSettingsView()
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var pollTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 켜지는 동안이 끝나면 "파일로 켜짐" 표시도 지운다 — 영상으로 켜면 SwiftUI 가 라이브러리 창을 아예 안 만들어(handlesExternalEvents)
        // 표시가 남아 있다가, 나중에 Dock 으로 연 라이브러리 창을 LibraryReopener 가 닫아 버렸다 (2026-11-27)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            self.startingUp = false
            Self.launchedForFiles = false
        }
        AppSettings.shared.applyAppearance()
        // 받는 중이면 Dock 아이콘에 개수·진행률 (2026-11-15, 사용자)
        DockProgress.shared.start()
        // 자동 업데이트: 하루 한 번 새 버전 확인 (Sparkle, 1.0 부터)
        _ = Updater.shared
        // 맥은 iCloud 의 바뀜 알림이 띄엄띄엄 와서, 앱이 앞에 있는 동안 30초마다 직접 확인한다
        pollTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { _ in
            guard NSApp.isActive else { return }
            Task { await SyncEngine.shared.syncNow() }
        }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        if Self.prewarmWhenActive { DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { Self.prewarmLibrary() } }
        // 오래 떠나 있었으면 지금 화면을 다시 읽는다
        RefreshSignal.shared.sendIfStale()
        // 다른 기기에서 바꾼 것 받기
        Task { await SyncEngine.shared.syncNow() }
    }

    /// Finder 에서 "다음으로 열기 › iRayer" 로 연 영상 (2026-11-27, 사용자: 파일 연결). 앱이 꺼져 있었으면 켜지면서 불린다
    /// 바뀜 (2026-11-27, 사용자: "영상만 바로 열었을 땐 메인 창은 안 켜져도 될 것 같다"): 영상을 열려고 켜진 거면 라이브러리 창을 닫는다.
    /// 켜질 때 이 함수와 라이브러리 창 중 무엇이 먼저 오는지 정해져 있지 않아 양쪽에서 본다 (창이 나중에 뜨면 LibraryReopener 가 닫음).
    /// Dock 아이콘을 누르면 평소처럼 다시 열린다.
    func application(_ application: NSApplication, open urls: [URL]) {
        if startingUp {
            // 창이 이미 떠 있었으면 여기서 닫고 끝, 아직이면 뜰 때 닫게 표시만
            Self.launchedForFiles = !Self.closeLibraryWindows()
            // 라이브러리 창을 보이지 않게 미리 만들어 둔다 (아래 prewarmLibrary)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { Self.prewarmLibrary() }
        }
        OpenedFile.open(urls)
    }

    /// 라이브러리 창을 보이지 않게 미리 만들어 둔다 (2026-11-27, 사용자: 재생 창만 있을 때 Dock 으로 라이브러리를 열면 앱을 새로 켤 때보다 늦다).
    /// 창을 처음 만드는 데 SwiftUI 가 0.6초쯤 쓴다(샘플: 분할 화면·사이드바 크기 계산). 영상으로 켜면 라이브러리 창이 없으니 Dock 을 누를 때
    /// 그걸 다 기다렸다 → 재생 창이 뜬 뒤 미리 만들어 숨겨 두고, Dock 을 누르면 꺼내기만 한다.
    /// 다른 앱을 보고 있을 때 만들면 iRayer 가 앞으로 튀어나오므로 iRayer 가 앞에 있을 때만 (아니면 다음에 앞으로 올 때)
    static func prewarmLibrary() {
        guard libraryWindow == nil else { return }
        guard NSApp.isActive else { prewarmWhenActive = true; return }
        prewarmWhenActive = false
        prewarming = true
        returnFocusTo = NSApp.keyWindow
        openLibrary?()
    }

    /// 미리 만드는 중 (LibraryReopener 가 보고 바로 숨긴다)
    static var prewarming = false
    static var prewarmWhenActive = false
    /// 미리 만든 뒤 키 창을 돌려줄 창 (재생 창)
    static weak var returnFocusTo: NSWindow?

    /// 라이브러리 창 (보이든 숨었든)
    static var libraryWindow: NSWindow? {
        NSApp.windows.first { $0.identifier?.rawValue.hasPrefix("library") == true }
    }

    /// 켜지는 중인지 (켜진 뒤 잠깐까지): 이때 들어온 파일 열기는 "파일을 열려고 켜진 것"
    private var startingUp = true
    /// 영상 파일을 열려고 켜졌는지 → 라이브러리 창을 띄우지 않는다
    static var launchedForFiles = false

    /// 라이브러리 창을 닫는다. 닫은 창이 있었으면 true
    @discardableResult
    static func closeLibraryWindows() -> Bool {
        let windows = NSApp.windows.filter { $0.identifier?.rawValue.hasPrefix("library") == true && $0.isVisible }
        windows.forEach { $0.close() }
        return !windows.isEmpty
    }

    /// 라이브러리 창을 닫아도 재생 창이 남아 있을 수 있으니 앱은 계속 둔다 (Dock 을 누르면 다시 연다)
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// 앱을 끌 때 받는 중인 것이 있으면 묻는다 (2026-11-08, 사용자). 받기는 받던 파일이 남아 다음에 같은 영상을 받으면 이어 받고,
    /// 재생하며 받기는 이어 갈 수 없으므로 받은 데까지 저장(묶기)을 마친 뒤 끈다
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let tabs = WebTabs.shared
        let count = tabs.activeDownloads
        guard count > 0 else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "받는 중인 항목이 \(count)개 있습니다. 끌까요?"
        alert.informativeText = "받기는 받던 곳까지 남아, 다음에 같은 영상을 받으면 이어 받습니다. 재생하며 받기는 받은 데까지 저장한 뒤 끕니다."
        alert.addButton(withTitle: "끄기")
        alert.addButton(withTitle: "취소")
        guard alert.runModal() == .alertFirstButtonReturn else { return .terminateCancel }
        let captures = tabs.busyCaptures
        guard !captures.isEmpty else { return .terminateNow }
        for capture in captures where capture.isOn { capture.stop(save: true) }
        // 묶기가 끝날 때까지 기다렸다가 끈다
        Task { @MainActor in
            while captures.contains(where: { $0.state == .saving }) {
                try? await Task.sleep(for: .milliseconds(300))
            }
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    /// 라이브러리 창을 다시 여는 동작 (MacCommands 가 넣어 둔다)
    static var openLibrary: (() -> Void)?

    /// Dock 아이콘을 누를 때. 재생 창이 떠 있으면 시스템은 창이 있다고 보고 아무것도 열지 않으므로,
    /// 라이브러리 창이 닫혀 있으면 직접 다시 연다.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        let libraryVisible = sender.windows.contains { $0.identifier?.rawValue.hasPrefix("library") == true && $0.isVisible }
        if !libraryVisible {
            // 미리 만들어 숨겨 둔 창이 있으면 꺼내기만 한다 (새로 만드는 0.6초를 건너뛴다)
            if let hidden = Self.libraryWindow, !Self.prewarming {
                hidden.makeKeyAndOrderFront(nil)
            } else {
                Self.prewarming = false
                Self.openLibrary?()
            }
        }
        return true
    }
}

/// 라이브러리 창이 뜰 때: 영상 파일로 켜진 거면 닫는다 (Dock 으로 다시 여는 동작은 MacCommands 가 넘겨 둔다)
private struct LibraryReopener: View {

    var body: some View {
        // 미리 만드는 창(AppDelegate.prewarmLibrary)은 창에 붙는 순간 투명하게 해서 숨긴다 — onAppear 는 창이 보인 뒤라 깜빡였다
        PrewarmHider()
            .onAppear {
                // 영상 파일을 열려고 켜진 거면 처음 뜬 라이브러리 창은 닫는다 (한 번만, 이후 Dock 으로 열면 그대로)
                if AppDelegate.launchedForFiles {
                    AppDelegate.launchedForFiles = false
                    DispatchQueue.main.async { AppDelegate.closeLibraryWindows() }
                }
            }
    }
}

/// 미리 만드는 라이브러리 창을 보이기 전에 숨긴다: 투명하게 → 화면에서 내림 → 원래대로, 키 창은 재생 창에 돌려준다
private struct PrewarmHider: NSViewRepresentable {
    final class Probe: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window, AppDelegate.prewarming else { return }
            window.alphaValue = 0
            DispatchQueue.main.async {
                window.orderOut(nil)
                window.alphaValue = 1
                AppDelegate.prewarming = false
                AppDelegate.returnFocusTo?.makeKeyAndOrderFront(nil)
            }
        }
    }
    func makeNSView(context: Context) -> Probe { Probe() }
    func updateNSView(_ view: Probe, context: Context) {}
}

/// 메뉴 iRayer > iRayer에 관하여 (기본 정보 창 대신 AboutView)
struct AboutMenuButton: View {
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Button("iRayer에 관하여") { openWindow(id: AboutView.windowID) }
    }
}


