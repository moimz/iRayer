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
        .commands {
            MacCommands()
            // iRayer에 관하여: 기본 정보 창 대신 직접 만든 창 (AboutView, 2026-11-23 사용자: iSQL 처럼)
            CommandGroup(replacing: .appInfo) { AboutMenuButton() }
        }

        // iRayer 정보 창: 오픈 소스·TMDB 고지
        Window("iRayer 정보", id: AboutView.windowID) {
            AboutView()
        }
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
        AppSettings.shared.applyAppearance()
        // 받는 중이면 Dock 아이콘에 개수·진행률 (2026-11-15, 사용자)
        DockProgress.shared.start()
        // 맥은 iCloud 의 바뀜 알림이 띄엄띄엄 와서, 앱이 앞에 있는 동안 30초마다 직접 확인한다
        pollTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { _ in
            guard NSApp.isActive else { return }
            Task { await SyncEngine.shared.syncNow() }
        }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        // 오래 떠나 있었으면 지금 화면을 다시 읽는다
        RefreshSignal.shared.sendIfStale()
        // 다른 기기에서 바꾼 것 받기
        Task { await SyncEngine.shared.syncNow() }
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

    /// 라이브러리 창을 다시 여는 동작 (LibraryReopener 가 넣어 둔다)
    static var openLibrary: (() -> Void)?

    /// Dock 아이콘을 누를 때. 재생 창이 떠 있으면 시스템은 창이 있다고 보고 아무것도 열지 않으므로,
    /// 라이브러리 창이 닫혀 있으면 직접 다시 연다.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        let libraryVisible = sender.windows.contains { $0.identifier?.rawValue.hasPrefix("library") == true && $0.isVisible }
        if !libraryVisible { Self.openLibrary?() }
        return true
    }
}

/// 라이브러리 창의 openWindow 동작을 앱 델리게이트에 넘겨 둔다 (창이 닫힌 뒤에도 Dock 에서 다시 열 수 있게)
private struct LibraryReopener: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Color.clear
            .onAppear {
                let open = openWindow
                AppDelegate.openLibrary = { open(id: "library") }
            }
    }
}

/// 메뉴 iRayer > iRayer에 관하여 (기본 정보 창 대신 AboutView)
struct AboutMenuButton: View {
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Button("iRayer에 관하여") { openWindow(id: AboutView.windowID) }
    }
}
