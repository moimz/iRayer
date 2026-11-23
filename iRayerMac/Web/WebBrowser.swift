import AppKit
import Observation
import WebKit

/// 웹 탐색 화면의 브라우저 (맥). 웹뷰는 앱에 하나만 두고 계속 쓴다 — 다른 사이드바 칸에 갔다 와도 보던 페이지가 그대로 남는다.
/// 쿠키·로그인 등은 이 브라우저만의 저장소에 따로 둔다 (사용자의 Safari·다른 앱과 섞이지 않는다).
/// 바뀜 (2026-11-08): 탭마다 하나 (WebTabs). 저장소는 모든 탭이 같이 쓰고, 보기 비율·패널 상태는 WebTabs 로 옮겼다
@MainActor
@Observable
final class WebBrowser: NSObject {
    /// 이 브라우저 전용 저장소의 이름표 (바꾸면 로그인·쿠키가 새로 시작된다)
    private static let storeID = UUID(uuidString: "6F1C2B7A-2D4E-4F0B-9C1A-21B0E5A7D301")!
    /// 모든 탭이 같이 쓰는 저장소 (한 탭에서 로그인하면 다른 탭도)
    static let dataStore = WKWebsiteDataStore(forIdentifier: storeID)

    @ObservationIgnored let webView: WKWebView

    /// 주소창에 보일 지금 주소 (아무것도 열지 않았으면 nil)
    private(set) var url: URL?
    private(set) var title: String?
    private(set) var canGoBack = false
    /// 바뀜 (2026-11-12): 폰이 원격으로 연 탭 — 이동 묻기를 하지 않는다 (맥 앞에 대답할 사람이 없을 수 있다)
    @ObservationIgnored var openedRemotely = false
    /// 앱이 직접 연 주소 (주소창·원격). 이 이동은 묻지 않는다
    @ObservationIgnored private var appLoad: (url: URL, at: Date)?
    /// 이동 묻기 창이 떠 있는 동안 (그동안 오는 다른 스크립트 이동은 묻지 않고 막는다)
    @ObservationIgnored private var asking = false
    private(set) var canGoForward = false
    private(set) var isLoading = false
    /// 불러오는 정도 0~1
    private(set) var progress = 0.0
    /// 이 페이지에서 감지한 영상 (먼저 찾은 것이 위). 다른 페이지로 가면 비운다
    private(set) var detected: [WebMedia] = []
    /// 요청 감지(비공개 API)를 쓸 수 있는지
    private(set) var watchesRequests = false
    /// 웹뷰 소리를 통째로 끌 수 있는지 (비공개 API) / 꺼져 있는지 (앱을 켤 때마다 꺼진 채로)
    private(set) var canMute = false
    private(set) var isMuted = false

    /// 웹 탐색의 오른쪽 패널(감지된 영상·설정)이 열려 있는지 — 열리면 웹뷰를 그만큼 좁혀 사이트 화면을 가리지 않는다 (사용자 2026-11-07)
    /// 바뀜 (2026-11-08): 열림 상태는 WebTabs.sidePanelOpen 으로
    static let sidePanelWidth: CGFloat = 320

    /// 페이지 보기 비율 (사파리 ⌘- 와 같음: 창이 1/비율만큼 넓은 것처럼 배치한 뒤 줄여 보인다. 이 맥에만, 기본 80%, 사용자 2026-11-07)
    /// 바뀜 (2026-11-08): 값은 WebTabs.zoom (모든 탭 같이), 여기는 저장 이름·범위만
    static let zoomKey = "webZoom"
    static var savedZoom: Double { UserDefaults.standard.object(forKey: zoomKey) as? Double ?? defaultZoom }
    /// 바뀜 (2026-11-07): 정해 둔 단계 대신 10% 씩 (30% ~ 200%)
    static let zoomRange: ClosedRange<Double> = 0.3...2.0
    static let defaultZoom = 0.8

    /// 감지 목록이 속한 페이지 (같은 페이지를 새로고침하면 목록을 그대로 둔다)
    @ObservationIgnored private var detectedPage: String?

    /// 요청을 보낼 때 본 헤더 (응답이 오면 영상인지 보고 버린다). 키: resourceLoadID
    @ObservationIgnored private var sentHeaders: [UInt64: [String: String]] = [:]

    @ObservationIgnored private var observations: [NSKeyValueObservation] = []

    override init() {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = Self.dataStore
        // 영상은 페이지가 시키는 대로 바로 재생 (소리 있는 자동 재생도 막지 않는다 — 영상을 찾으려고 여는 브라우저)
        config.mediaTypesRequiringUserActionForPlayback = []
        // 사이트가 Safari 로 알아보게 (WKWebView 기본 UA 에는 Version·Safari 가 없어 낮은 화질·옛 화면을 주는 곳이 있다)
        config.applicationNameForUserAgent = "Version/26.0 Safari/605.1.15"
        config.preferences.isElementFullscreenEnabled = true
        // 다른 사이드바 메뉴로 가서 웹뷰가 화면에서 빠져도 재생·받기가 이어지게: 숨은 페이지의 영상 멈춤·타이머 늦추기·프로세스 쉬게 하기를 끈다
        // (WebKit 비공개 설정. 없으면 건너뛴다)
        Self.setPrivate(config.preferences, "_setInvisibleAutoplayNotPermitted:", false)
        Self.setPrivate(config.preferences, "_setHiddenPageDOMTimerThrottlingEnabled:", false)
        Self.setPrivate(config.preferences, "_setPageVisibilityBasedProcessSuppressionEnabled:", false)
        // 바뀜 (2026-11-12, 사용자): 광고 차단 규칙 (막힌 요청은 감지 목록에도 안 나온다)
        AdBlock.shared.attach(config.userContentController)
        webView = WKWebView(frame: .zero, configuration: config)
        // 바뀜 (2026-11-09, 사용자): 모니터가 꺼지거나 다른 창이 덮어도 페이지를 숨김(document.hidden)으로 보지 않게 —
        //   창이 가려졌는지 살피는 것을 끈다 (WebKit 비공개, macOS 10.14.4~. 없으면 건너뛴다). 모니터는 그대로 꺼진다
        Self.setPrivate(webView, "_setWindowOcclusionDetectionEnabled:", false)
        webView.allowsBackForwardNavigationGestures = true
        webView.allowsMagnification = true
        super.init()
        canMute = webView.responds(to: NSSelectorFromString("_setPageMuted:"))
        webView.uiDelegate = self
        webView.navigationDelegate = self
        // 페이지가 받는 모든 요청·응답을 본다 (WebKit 비공개 API, 2019 년쯤부터 있음). 없으면 감지만 못 하고 탐색은 된다
        let setter = NSSelectorFromString("_setResourceLoadDelegate:")
        if webView.responds(to: setter) {
            webView.perform(setter, with: self)
            watchesRequests = true
        }
        observations = [
            // 닫은 뒤의 빈 페이지(about:blank)는 아무것도 열지 않은 것으로
            webView.observe(\.url) { [weak self] view, _ in MainActor.assumeIsolated { self?.url = view.url?.scheme == "about" ? nil : view.url } },
            webView.observe(\.title) { [weak self] view, _ in MainActor.assumeIsolated { self?.title = view.url?.scheme == "about" ? nil : view.title } },
            webView.observe(\.canGoBack) { [weak self] view, _ in MainActor.assumeIsolated { self?.canGoBack = view.canGoBack } },
            webView.observe(\.canGoForward) { [weak self] view, _ in MainActor.assumeIsolated { self?.canGoForward = view.canGoForward } },
            webView.observe(\.isLoading) { [weak self] view, _ in MainActor.assumeIsolated { self?.isLoading = view.isLoading } },
            webView.observe(\.estimatedProgress) { [weak self] view, _ in MainActor.assumeIsolated { self?.progress = view.estimatedProgress } },
        ]
        setMuted(true)
        webView.pageZoom = Self.savedZoom
    }

    /// 비공개 BOOL 설정 (선택자가 없으면 아무것도 하지 않는다)
    private static func setPrivate(_ object: NSObject, _ name: String, _ value: Bool) {
        let selector = NSSelectorFromString(name)
        guard object.responds(to: selector) else { return }
        typealias Setter = @convention(c) (AnyObject, Selector, Bool) -> Void
        unsafeBitCast(object.method(for: selector), to: Setter.self)(object, selector, value)
    }

    /// 주소창에 쓴 글: 주소면 그 주소로, 아니면 검색
    func open(_ text: String) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let url = Self.url(from: text) else { return }
        appLoad = (url, .now)
        webView.load(URLRequest(url: url))
    }

    /// 웹뷰에서 나오는 소리 전체를 끄고 켠다 (_WKMediaMutedState: 1 = 소리 끔). 페이지·플레이어 설정과 따로라 재생하며 받기에는 상관없다
    func setMuted(_ muted: Bool) {
        let selector = NSSelectorFromString("_setPageMuted:")
        guard webView.responds(to: selector) else { return }
        typealias Setter = @convention(c) (AnyObject, Selector, UInt) -> Void
        unsafeBitCast(webView.method(for: selector), to: Setter.self)(webView, selector, muted ? 1 : 0)
        isMuted = muted
    }

    /// 지금 사이트 닫기 (2026-11-07): 빈 페이지로 바꿔 재생·소리를 멈추고 감지 목록·뒤로 기록을 비운다.
    /// 웹뷰는 다른 메뉴에서도 뒤에 깔려 계속 돌기 때문. 받는 중인 파일·HLS 는 페이지와 따로라 계속 받는다.
    func close() {
        webView.stopLoading()
        webView.load(URLRequest(url: URL(string: "about:blank")!))
        // 뒤로 기록 비우기 (WebKit 비공개, 없으면 기록은 남는다)
        let clear = NSSelectorFromString("_clearBackForwardList")
        if webView.responds(to: clear) { webView.perform(clear) }
        detected = []
        sentHeaders = [:]
        detectedPage = nil
        url = nil
        title = nil
    }

    func goBack() { webView.goBack() }
    func goForward() { webView.goForward() }

    func reload() {
        if isLoading { webView.stopLoading() } else { webView.reload() }
    }

    /// "example.com" 처럼 점이 있고 띄어쓰기가 없으면 주소(https), "http://…" 등 스킴이 있으면 그대로, 그 밖에는 DuckDuckGo 검색
    static func url(from text: String) -> URL? {
        if let url = URL(string: text), let scheme = url.scheme?.lowercased(), ["http", "https", "file"].contains(scheme) {
            return url
        }
        if !text.contains(" "), text.contains("."), let url = URL(string: "https://" + text), url.host != nil {
            return url
        }
        var search = URLComponents(string: "https://duckduckgo.com/")!
        search.queryItems = [URLQueryItem(name: "q", value: text)]
        return search.url
    }
}

extension WebBrowser: WKUIDelegate {
    /// 새 창·새 탭으로 여는 링크는 같은 화면에서 연다. 사용자가 누르지 않은 스크립트 팝업은 막는다
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        // 바뀜 (2026-11-12): 예외 사이트(@@)는 스크립트 팝업도 같은 화면에서 연다 (로그인 창 등). 우리가 연 것이므로 이동 묻기도 하지 않는다
        if navigationAction.targetFrame == nil,
           navigationAction.navigationType == .linkActivated || AdBlock.shared.isException(webView.url) {
            if let url = navigationAction.request.url { appLoad = (url, .now) }
            webView.load(navigationAction.request)
        }
        return nil
    }

    /// 카메라·마이크는 쓰지 않는다
    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin, initiatedByFrame frame: WKFrameInfo,
                 type: WKMediaCaptureType, decisionHandler: @escaping @MainActor (WKPermissionDecision) -> Void) {
        decisionHandler(.deny)
    }
}

extension WebBrowser: WKNavigationDelegate {
    /// 페이지를 새로 열 때(링크·주소·새로고침·뒤로) 이 브라우저의 캐시를 먼저 비운다.
    /// 캐시에서 꺼낸 응답은 요청 감지(_resourceLoadDelegate)에 나타나지 않아, 한 번 본 페이지를 다시 열면 영상이 감지되지 않았다.
    /// 쿠키·로그인은 캐시와 따로라 남는다.
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        guard navigationAction.targetFrame?.isMainFrame == true else { return decisionHandler(.allow) }
        // 바뀜 (2026-11-12, 사용자): 누르지 않았는데 다른 곳으로 가려 하면 묻고, 거절하면 머문다. 팝업 가짜 창도 사이트에 맞게 다시 단다
        guard let target = navigationAction.request.url else { return decisionHandler(.allow) }
        // 바뀜 (2026-11-12, 사용자): 사이트별 UA — 바꿔야 하면 이 이동을 멈추고 새 UA 로 다시 연다 (우리가 연 것이므로 묻지 않는다)
        if let again = SiteAgent.prepare(webView, for: navigationAction) {
            decisionHandler(.cancel)
            appLoad = (target, .now)
            webView.load(again)
            return
        }
        if needsConfirmation(navigationAction, to: target) {
            guard !asking else {
                WebLog.write("이동 막음 (묻는 중): \(target.absoluteString)")
                return decisionHandler(.cancel)
            }
            asking = true
            confirmNavigation(to: target) { [weak self] go in
                self?.asking = false
                WebLog.write("스크립트 이동 \(go ? "허락" : "거절"): \(target.absoluteString)")
                guard go, let self else { return decisionHandler(.cancel) }
                self.allowNavigation(to: target, decisionHandler)
            }
            return
        }
        allowNavigation(to: target, decisionHandler)
    }

    private func allowNavigation(to target: URL, _ decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        PopupGuard.update(webView.configuration.userContentController, for: target)
        let caches: Set<String> = [WKWebsiteDataTypeDiskCache, WKWebsiteDataTypeMemoryCache, WKWebsiteDataTypeFetchCache]
        webView.configuration.websiteDataStore.removeData(ofTypes: caches, modifiedSince: .distantPast) {
            decisionHandler(.allow)
        }
    }

    /// 사용자가 누르지 않은(스크립트·자동 새로고침) 본 페이지 이동인지.
    /// 주소창·원격으로 연 것, 첫 페이지, 뒤로·앞으로·새로고침, 같은 페이지 안(#), 서버가 넘긴 것(리다이렉트), 예외 사이트는 묻지 않는다
    private func needsConfirmation(_ action: WKNavigationAction, to target: URL) -> Bool {
        guard AdBlock.shared.confirmNavigation, !openedRemotely, action.navigationType == .other,
              let current = webView.url, current.scheme?.hasPrefix("http") == true,
              target.scheme?.hasPrefix("http") == true,
              !AdBlock.shared.isException(current) else { return false }
        if let appLoad, appLoad.url == target || Date.now.timeIntervalSince(appLoad.at) < 3 {
            self.appLoad = nil
            return false
        }
        if Self.withoutFragment(current) == Self.withoutFragment(target) { return false }
        // 웹킷 비공개: 사용자가 누른 직후의 이동인지, 서버 리다이렉트인지. 알 수 없으면 묻지 않는다
        guard let userInitiated = Self.privateFlag(action, "_isUserInitiated") else { return false }
        if userInitiated || Self.privateFlag(action, "_isRedirect") == true { return false }
        return true
    }

    private static func privateFlag(_ object: NSObject, _ name: String) -> Bool? {
        let selector = NSSelectorFromString(name)
        guard object.responds(to: selector) else { return nil }
        typealias Getter = @convention(c) (AnyObject, Selector) -> Bool
        return unsafeBitCast(object.method(for: selector), to: Getter.self)(object, selector)
    }

    private static func withoutFragment(_ url: URL) -> String {
        url.absoluteString.split(separator: "#", maxSplits: 1).first.map(String.init) ?? url.absoluteString
    }

    /// "이 페이지가 다른 곳으로 이동하려 합니다" — 기본은 머무르기 (Return)
    private func confirmNavigation(to target: URL, _ completion: @escaping @MainActor (Bool) -> Void) {
        let alert = NSAlert()
        alert.messageText = "페이지가 다른 곳으로 이동하려 합니다"
        alert.informativeText = target.absoluteString
        alert.addButton(withTitle: "머무르기")
        alert.addButton(withTitle: "이동")
        if let window = webView.window {
            alert.beginSheetModal(for: window) { completion($0 == .alertSecondButtonReturn) }
        } else {
            completion(alert.runModal() == .alertSecondButtonReturn)
        }
    }

    /// 본문 프레임이 다른 페이지로 넘어가면 감지 목록을 비운다.
    /// 같은 페이지를 새로고침할 때는 그대로 둔다 — 새로고침한 페이지는 목록·영상을 캐시에서 꺼내 와 요청이 다시 안 보일 수 있다
    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        let page = webView.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }.map { parts -> String in
            var parts = parts
            parts.fragment = nil
            return parts.string ?? ""
        }
        if page != detectedPage {
            detected = []
            sentHeaders = [:]
        }
        detectedPage = page
    }
}

// MARK: - 요청 감지 (_WKResourceLoadDelegate, 비공개)

extension WebBrowser {
    private func loadID(_ load: AnyObject) -> UInt64? {
        ((load as? NSObject)?.value(forKey: "resourceLoadID") as? NSNumber)?.uint64Value
    }

    @objc(webView:resourceLoad:didSendRequest:)
    func resourceLoad(_ webView: WKWebView, _ load: AnyObject, didSendRequest request: URLRequest) {
        guard let id = loadID(load) else { return }
        sentHeaders[id] = request.allHTTPHeaderFields ?? [:]
    }

    @objc(webView:resourceLoad:didReceiveResponse:)
    func resourceLoad(_ webView: WKWebView, _ load: AnyObject, didReceiveResponse response: URLResponse) {
        guard let id = loadID(load) else { return }
        let headers = sentHeaders.removeValue(forKey: id) ?? [:]
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode), let url = http.url,
              url.scheme == "http" || url.scheme == "https" else { return }
        let type = ((load as? NSObject)?.value(forKey: "resourceType") as? NSNumber)?.intValue ?? -1
        guard let kind = WebMediaClassifier.kind(url: url, mimeType: http.mimeType ?? "", resourceType: type) else { return }
        let key = WebMediaClassifier.key(for: url)
        let size = kind == .file ? WebMediaClassifier.totalSize(http) : nil
        if let index = detected.firstIndex(where: { $0.id == key }) {
            // 같은 영상의 다른 구간: 크기만 채운다
            if detected[index].size == nil, let size { detected[index].size = size }
            return
        }
        // 이미 감지한 HLS·DASH 에 딸린 것(화질별·소리 목록, 조각이 든 트랙 파일, DASH 조각)이면 올리지 않는다
        if detected.contains(where: { $0.owns(key) }) { return }
        var media = WebMedia(id: key, url: URL(string: key) ?? url, kind: kind, mimeType: (http.mimeType ?? "").lowercased(),
                             size: size, pageURL: self.url, pageTitle: title,
                             headers: WebMediaClassifier.replayHeaders(headers), foundAt: Date())
        media.inspecting = kind == .hls || kind == .dash
        // 바뀜 (2026-11-09, 사용자): 새로고침하면 토큰·만료 쿼리만 바뀐 같은 영상이 또 쌓였다 — 일단 올리고, 내용으로 지문을 만들어
        //   앞서 찾은 것과 같으면 한 줄로 합친다 (settle). 주소 모양으로 짐작하지 않는다
        detected.append(media)
        WebLog.write("감지 \(kind) 페이지 \(self.url?.absoluteString ?? "-")\n원래 주소 \(url.absoluteString)\n받을 주소 \(media.url.absoluteString)\n페이지가 보낸 헤더\n\(WebLog.headers(headers))")
        // 바뀜 (2026-11-12): 받을 주소(HLS·DASH)를 찾았으면 재생 버퍼 줄은 뺀다
        if kind != .file { detected.removeAll { $0.kind == .mse } }
        if kind == .hls { Task { await inspectHLS(media) } }
        if kind == .dash { Task { await inspectDASH(media) } }
        if kind == .file { Task { await fingerprintFile(media) } }
    }

    /// 재생 버퍼(MSE)로 재생하는데 받을 주소(HLS·DASH)는 못 찾은 페이지 (2026-11-12, 사용자: 목록 주소가 보이지 않아 감지가 안 되던 사이트):
    /// 재생하며 받기 줄을 하나 올린다. 이미 HLS·DASH 를 찾았으면 그것으로 받으므로 올리지 않는다
    func noteMSEPlayer(mime: String) {
        guard let page = url, !detected.contains(where: { $0.kind != .file }) else { return }
        let key = "mse:" + WebMediaClassifier.key(for: page)
        detected.append(WebMedia(id: key, url: page, kind: .mse, mimeType: mime.lowercased(), size: nil, pageURL: page,
                                 pageTitle: title, headers: [:], foundAt: Date()))
        WebLog.write("감지 MSE 페이지 \(page.absoluteString) (\(mime))")
    }

    /// 살펴보기 끝 (실패해도)
    private func finishInspecting(_ id: String) {
        if let index = detected.firstIndex(where: { $0.id == id }) { detected[index].inspecting = false }
    }

    /// 파일: 앞 64KB 를 받아 지문
    private func fingerprintFile(_ media: WebMedia) async {
        let session = WebFetch.session(cookies: await cookies())
        defer { session.finishTasksAndInvalidate() }
        guard let print = await WebFingerprint.file(media, session: session) else { return }
        settle(media.id, fingerprint: print)
    }

    /// 지문을 적고, 앞서 찾은 같은 종류·같은 지문의 줄이 있으면 한 줄로 (2026-11-09, 사용자).
    /// 앞 줄 자리에 새 주소(새 토큰)를 넣는다 — 옛 토큰은 곧 만료된다. 앞 줄로 받는 중이거나 받은 것이 있으면 앞 줄을 두고 새 줄을 뺀다
    private func settle(_ id: String, fingerprint: String) {
        guard let index = detected.firstIndex(where: { $0.id == id }) else { return }
        detected[index].fingerprint = fingerprint
        let media = detected[index]
        guard let earlier = detected.firstIndex(where: { $0.id != id && $0.kind == media.kind && $0.fingerprint == fingerprint }) else { return }
        if WebDownloads.shared.item(for: detected[earlier]) != nil {
            detected.remove(at: index)
        } else {
            detected[earlier] = media
            detected.remove(at: index)
        }
        WebLog.write("감지 \(media.kind): 앞서 찾은 것과 내용이 같은 영상이라 한 줄로 합침 (\(fingerprint))")
    }

    @objc(webView:resourceLoad:didCompleteWithError:response:)
    func resourceLoad(_ webView: WKWebView, _ load: AnyObject, didCompleteWithError error: NSError?, response: URLResponse?) {
        if let id = loadID(load) { sentHeaders[id] = nil }
    }

    /// HLS 목록을 한 번 받아 해석: 마스터면 최고 화질을 적고 딸린 목록을 숨긴다, 라이브·DRM 이면 받기를 끈다
    private func inspectHLS(_ media: WebMedia) async {
        defer { finishInspecting(media.id) }
        let session = WebFetch.session(cookies: await cookies())
        defer { session.finishTasksAndInvalidate() }
        guard let data = try? await WebFetch.data(WebFetch.request(media.url, for: media), session: session),
              let text = String(data: data, encoding: .utf8), let playlist = HLSPlaylist.parse(text, base: media.url) else { return }
        guard let index = detected.firstIndex(where: { $0.id == media.id }) else { return }
        switch playlist {
        case .master(let variants, let audio):
            let lists = variants.map(\.url) + audio.compactMap(\.url)
            var children = Set(lists.map(WebMediaClassifier.key))
            detected[index].children = children
            detected[index].quality = variants.best?.label
            detected.removeAll { children.contains($0.id) }
            // 딸린 목록들을 열어: 조각이 든 파일(BYTERANGE 로 나눠 받는 CMAF_720.mp4 같은 것)도 숨기고, 최고 화질이 라이브·DRM 인지 본다
            let media = media
            let opened = await withTaskGroup(of: (URL, HLSPlaylist.Media?).self) { group in
                for url in lists {
                    group.addTask {
                        guard let data = try? await WebFetch.data(WebFetch.request(url, for: media), session: session),
                              let text = String(data: data, encoding: .utf8),
                              case .media(let list)? = HLSPlaylist.parse(text, base: url) else { return (url, nil) }
                        return (url, list)
                    }
                }
                var result: [URL: HLSPlaylist.Media] = [:]
                for await (url, list) in group { if let list { result[url] = list } }
                return result
            }
            for list in opened.values {
                for segment in list.segments {
                    children.insert(WebMediaClassifier.key(for: segment.url))
                    if let map = segment.map { children.insert(WebMediaClassifier.key(for: map.url)) }
                }
            }
            guard let index = detected.firstIndex(where: { $0.id == media.id }) else { return }
            detected[index].children = children
            detected.removeAll { $0.id != media.id && children.contains($0.id) }
            if let best = variants.best, let list = opened[best.url] {
                if let print = WebFingerprint.hls(list) { settle(media.id, fingerprint: print) }
                let standard = await HLSReceiver.looksStandard(list, media: media, session: session)
                if let index = detected.firstIndex(where: { $0.id == media.id }) {
                    detected[index].unsupported = list.hasDRM ? "DRM" : list.isLive ? "라이브" : nil
                    detected[index].needsCapture = !standard
                }
            }
        case .media(let list):
            var children: Set<String> = []
            for segment in list.segments {
                children.insert(WebMediaClassifier.key(for: segment.url))
                if let map = segment.map { children.insert(WebMediaClassifier.key(for: map.url)) }
            }
            detected[index].children = children
            detected.removeAll { $0.id != media.id && children.contains($0.id) }
            if let print = WebFingerprint.hls(list) { settle(media.id, fingerprint: print) }
            let standard = await HLSReceiver.looksStandard(list, media: media, session: session)
            if let index = detected.firstIndex(where: { $0.id == media.id }) {
                detected[index].unsupported = list.hasDRM ? "DRM" : list.isLive ? "라이브" : nil
                detected[index].needsCapture = !standard
            }
        }
    }

    /// DASH 목록을 한 번 받아 해석: 딸린 조각(먼저 올라온 것 포함)을 숨기고, DRM·라이브면 표시
    private func inspectDASH(_ media: WebMedia) async {
        defer { finishInspecting(media.id) }
        let session = WebFetch.session(cookies: await cookies())
        defer { session.finishTasksAndInvalidate() }
        guard let data = try? await WebFetch.data(WebFetch.request(media.url, for: media), session: session),
              let manifest = DASHManifest.parse(data, url: media.url),
              let index = detected.firstIndex(where: { $0.id == media.id }) else { return }
        detected[index].segmentPrefixes = manifest.segmentPrefixes
        detected[index].unsupported = manifest.hasDRM ? "DRM" : nil
        let owner = detected[index]
        detected.removeAll { $0.id != media.id && $0.kind == .file && owner.owns($0.id) }
        if let print = WebFingerprint.dash(data) { settle(media.id, fingerprint: print) }
    }

    /// 이 브라우저 저장소의 쿠키 (받을 때 같은 로그인으로)
    func cookies() async -> [HTTPCookie] {
        await Self.cookies()
    }

    /// 모든 탭이 같이 쓰는 저장소의 쿠키
    static func cookies() async -> [HTTPCookie] {
        await dataStore.httpCookieStore.allCookies()
    }
}
