import Foundation
import Observation

/// 웹 탐색 탭 (2026-11-08, 사용자): 웹뷰(WebBrowser) + 그 페이지의 감지 목록·재생하며 받기(WebCapture) 가 한 세트.
/// 여러 사이트를 동시에 열어 각자 받을 수 있다. 뒤에 있는 탭도 웹뷰를 창에 투명하게 깔아 두어(WebPageLayer) 재생·받기가 이어진다.
/// 쿠키·로그인 저장소, 보기 비율, 즐겨찾기, 받기 목록(WebDownloads)은 모든 탭이 같이 쓴다. 소리 끄기는 탭마다.
@MainActor
@Observable
final class WebTab: Identifiable {
    let id = UUID()
    let browser: WebBrowser
    let capture: WebCapture

    init() {
        browser = WebBrowser()
        capture = WebCapture(browser: browser)
    }

    /// 탭 목록에 보일 이름
    var title: String {
        if let title = browser.title, !title.isEmpty { return title }
        return browser.url?.host() ?? "새 탭"
    }
}

@MainActor
@Observable
final class WebTabs {
    static let shared = WebTabs()

    private(set) var tabs: [WebTab]
    /// 지금 보이는 탭
    var currentID: UUID

    var current: WebTab { tabs.first { $0.id == currentID } ?? tabs[0] }

    /// 웹 탐색의 오른쪽 감지 패널이 열려 있는지 — 열리면 지금 탭의 웹뷰를 그만큼 좁힌다 (사용자 2026-11-07)
    /// 바뀜 (2026-11-08): WebBrowser 에서 옮김 (탭과 상관없는 화면 상태)
    var sidePanelOpen = false

    /// 페이지 보기 비율 (모든 탭 같이). 바뀜 (2026-11-08): WebBrowser 에서 옮김
    var zoom: Double = WebBrowser.savedZoom {
        didSet {
            UserDefaults.standard.set(zoom, forKey: WebBrowser.zoomKey)
            for tab in tabs { tab.browser.webView.pageZoom = zoom }
        }
    }

    private init() {
        let first = WebTab()
        tabs = [first]
        currentID = first.id
    }

    /// 받는 중인 것의 수: 받기(멈춘 것 빼고) + 재생하며 받기(기다림·받는 중·묶는 중). 사이드바 [다운로드] 배지·앱 끌 때 물음 (2026-11-08, 사용자)
    var activeDownloads: Int {
        WebDownloads.shared.items.filter(\.isActive).count + busyCaptures.count
    }

    /// 재생하며 받기가 켜져 있거나 저장(묶기) 중인 탭들
    var busyCaptures: [WebCapture] {
        tabs.map(\.capture).filter { $0.isOn || $0.state == .saving }
    }

    /// 보기 비율을 10% 씩 크게(+1)·작게(-1)
    func stepZoom(_ direction: Int) {
        let next = ((zoom + 0.1 * Double(direction)) * 10).rounded() / 10
        zoom = min(max(next, WebBrowser.zoomRange.lowerBound), WebBrowser.zoomRange.upperBound)
    }

    /// 새 탭을 열고 그리로 간다
    func add() {
        let tab = WebTab()
        tabs.append(tab)
        currentID = tab.id
    }

    /// 탭 닫기 (받는 중인지는 부르는 쪽이 묻는다). 마지막 하나는 닫지 않고 사이트만 닫는다
    func close(_ id: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        let tab = tabs[index]
        if tab.capture.isOn { tab.capture.stop(save: false) }
        guard tabs.count > 1 else {
            tab.browser.close()
            return
        }
        tab.browser.close()
        tabs.remove(at: index)
        if currentID == id { currentID = tabs[min(index, tabs.count - 1)].id }
    }
}
