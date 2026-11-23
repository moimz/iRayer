#if os(iOS)
import SwiftUI
import WebKit

/// 아이폰·아이패드 [웹 탐색] (2026-11-09, 사용자): 폰에서는 받지 않고 둘러보기만 한다.
/// 받을 페이지를 찾으면 [맥에 보내기] → 맥·탭을 고르면 그 맥이 페이지를 열어 영상을 찾고, 폰에서 골라 맥이 받는다.
/// 즐겨찾기는 맥과 같은 것 (iCloud)
@MainActor
@Observable
final class PhoneBrowser: NSObject, WKNavigationDelegate, WKUIDelegate {
    let webView: WKWebView
    private(set) var url: URL?
    private(set) var title: String?
    private(set) var canGoBack = false
    private(set) var canGoForward = false
    private(set) var isLoading = false
    /// 불러온 정도 0~1
    private(set) var progress: Double = 0
    @ObservationIgnored private var observations: [NSKeyValueObservation] = []
    /// 앱이 꺼질 때까지 하나만 둔다 — 다른 메뉴에 갔다 와도 보던 페이지가 그대로 (2026-11-10, 사용자)
    static let shared = PhoneBrowser()

    override init() {
        let configuration = WKWebViewConfiguration()
        configuration.allowsInlineMediaPlayback = true
        // 바뀜 (2026-11-10, 사용자: 구글이 못생기게 나옴): 웹뷰 기본 User-Agent 에는 "Safari" 가 없어 옛 모양 페이지를 준다 — 사파리처럼 끝에 붙인다
        configuration.applicationNameForUserAgent = "Version/26.0 Mobile/15E148 Safari/604.1"
        // 바뀜 (2026-11-12, 사용자): 광고 차단 규칙
        AdBlock.shared.attach(configuration.userContentController)
        webView = WKWebView(frame: .zero, configuration: configuration)
        webView.allowsBackForwardNavigationGestures = true
        super.init()
        webView.navigationDelegate = self
        webView.uiDelegate = self
        observations = [
            webView.observe(\.url) { [weak self] view, _ in MainActor.assumeIsolated { self?.url = view.url } },
            webView.observe(\.title) { [weak self] view, _ in MainActor.assumeIsolated { self?.title = view.title } },
            webView.observe(\.canGoBack) { [weak self] view, _ in MainActor.assumeIsolated { self?.canGoBack = view.canGoBack } },
            webView.observe(\.canGoForward) { [weak self] view, _ in MainActor.assumeIsolated { self?.canGoForward = view.canGoForward } },
            webView.observe(\.isLoading) { [weak self] view, _ in MainActor.assumeIsolated { self?.isLoading = view.isLoading } },
            webView.observe(\.estimatedProgress) { [weak self] view, _ in MainActor.assumeIsolated { self?.progress = view.estimatedProgress } },
        ]
    }

    /// 주소창에 쓴 글: 주소면 그 주소로, 아니면 검색 (맥과 같은 규칙)
    func open(_ text: String) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let url = Self.url(from: text) else { return }
        webView.load(URLRequest(url: url))
    }

    static func url(from text: String) -> URL? {
        if let url = URL(string: text), let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme) { return url }
        if !text.contains(" "), text.contains("."), let url = URL(string: "https://" + text), url.host != nil { return url }
        var search = URLComponents(string: "https://duckduckgo.com/")!
        search.queryItems = [URLQueryItem(name: "q", value: text)]
        return search.url
    }

    /// 사이트별 UA (2026-11-12, 사용자): 바꿔야 하면 이 이동을 멈추고 새 UA 로 다시 연다
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        guard navigationAction.targetFrame?.isMainFrame == true, let again = SiteAgent.prepare(webView, for: navigationAction) else {
            return decisionHandler(.allow)
        }
        decisionHandler(.cancel)
        webView.load(again)
    }

    /// 새 창으로 여는 링크는 같은 화면에서 (누르지 않은 팝업은 막는다)
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if navigationAction.targetFrame == nil, navigationAction.navigationType == .linkActivated {
            webView.load(navigationAction.request)
        }
        return nil
    }
}

/// 바뀜 (2026-11-10): 웹뷰는 하나를 계속 쓰므로 감싸는 칸에 넣고, 화면에 붙을 때 그 칸으로 데려온다
/// (아이패드는 사이드바 [웹 탐색]과 [탐색] 안의 웹 탐색이 같은 웹뷰를 쓴다)
private final class WebViewHost: UIView {
    let webView: WKWebView
    init(_ webView: WKWebView) {
        self.webView = webView
        super.init(frame: .zero)
        adopt()
    }
    required init?(coder: NSCoder) { fatalError() }
    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil { adopt() }
    }
    private func adopt() {
        guard webView.superview !== self else { return }
        webView.removeFromSuperview()
        webView.frame = bounds
        webView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(webView)
    }
}

private struct WebViewContainer: UIViewRepresentable {
    let webView: WKWebView
    /// 아래에 떠 있는 막대만큼 페이지 끝에 여백 (막대 뒤로도 비쳐 보이되 끝까지 내리면 가리지 않게, 2026-11-09 사용자)
    var bottomInset: CGFloat = 0
    func makeUIView(context: Context) -> WebViewHost { WebViewHost(webView) }
    func updateUIView(_ host: WebViewHost, context: Context) {
        let view = host.webView
        guard view.scrollView.contentInset.bottom != bottomInset else { return }
        view.scrollView.contentInset.bottom = bottomInset
        view.scrollView.verticalScrollIndicatorInsets.bottom = bottomInset
    }
}

/// 바뀜 (2026-11-09, 사용자): 사파리처럼 둥근 주소 막대 — 평소엔 사이트 이름만 가운데, 누르면 주소 전체를 고쳐 쓰고 아래에 즐겨찾기.
/// 아이폰은 막대가 아래(엄지 닿는 곳), 아이패드는 위
struct PhoneWebView: View {
    // 바뀜 (2026-11-10, 사용자): 화면마다 새로 만들지 않고 앱 전체에 하나 — 나갔다 와도 초기화되지 않는다
    @State private var browser = PhoneBrowser.shared
    @State private var bookmarks = WebBookmarks.shared
    @State private var address = ""
    @State private var editing = false
    /// 키보드를 띄워 둘지 (끝낼 때는 키보드를 먼저 내리고 막대는 그다음에 바꾼다)
    @State private var keyboard = false
    @State private var sending = false
    @State private var downloads = MacDownloads.shared
    /// 받는 중 팝업 (2026-11-11, 사용자)
    @State private var showDownloads = false
    @Namespace private var glass
    /// 아이폰 아래 막대의 높이 (페이지 끝 여백)
    @State private var barHeight: CGFloat = 60
    /// 맥에 열린 탭 (맥 id → 탭들, 즐겨찾기 위에 보인다. 2026-11-10 사용자)
    @State private var macTabs: [String: [MacPresence.Tab]] = [:]
    /// 닫으라고 보낸 탭 (맥이 닫을 때까지 목록에서 뺀다)
    @State private var closedTabs: Set<String> = []
    private let isPad = UIDevice.current.userInterfaceIdiom == .pad

    var body: some View {
        // 바뀜 (2026-11-09, 사용자): 아이폰은 막대를 페이지 위에 띄워 사파리처럼 조금 더 아래에, 페이지 끝에는 막대만큼 여백
        ZStack(alignment: .bottom) {
            WebViewContainer(webView: browser.webView, bottomInset: isPad ? 0 : barHeight)
                .ignoresSafeArea(edges: isPad ? [] : .bottom)
            // 주소를 고치는 동안, 또는 아무 페이지도 안 열었을 때: 즐겨찾기
            if editing || browser.url == nil {
                favorites
                    .safeAreaPadding(.bottom, isPad ? 0 : barHeight)
                    // 보이는 동안 맥들의 보낸편지함에서 열린 탭을 읽는다 (켜져 있음 기록은 몇 분 늦다)
                    .task {
                        while !Task.isCancelled {
                            await loadMacTabs()
                            try? await Task.sleep(for: .seconds(3))
                        }
                    }
            }
            if !isPad {
                bar
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { barHeight = $0 }
                    // 사파리처럼 막대 아래 끝이 안전 영역 끝에 닿게 (키보드 위에서는 조금 띄운다)
                    .padding(.bottom, keyboard ? 8 : 0)
            }
        }
            .navigationTitle("웹 탐색")
            .navigationBarTitleDisplayMode(.inline)
            // 바뀜 (2026-11-10, 사용자): 아이패드는 따로 줄을 두지 않고 내비게이션 막대에 — [앱 ‹] [‹ ›] (빈칸) [주소] (빈칸) [맥에 보내기]
            .toolbar {
                // 바뀜 (2026-11-11, 사용자): 오른쪽 위에 [다운로드] — 맥에서 받는 중인 개수를 뱃지로, 누르면 받는 중인 것만 작은 팝업
                ToolbarItem(placement: .topBarTrailing) { downloadsButton }
                    .sharedBackgroundVisibility(.hidden)
                if isPad {
                    ToolbarItemGroup(placement: .topBarLeading) {
                        if !editing {
                            Button("뒤로", systemImage: "chevron.backward") { browser.webView.goBack() }
                                .disabled(!browser.canGoBack)
                            if browser.canGoForward {
                                Button("앞으로", systemImage: "chevron.forward") { browser.webView.goForward() }
                            }
                        }
                    }
                    // 바뀜 (2026-11-10, 사용자): 막대가 가운데 항목에는 유리를 깔지 않아 주소 막대에 바탕이 없었다 — 우리 유리를 쓴다
                    ToolbarItem(placement: .principal) {
                        capsule
                            .frame(minWidth: 320, idealWidth: 560, maxWidth: 560)
                    }
                    .sharedBackgroundVisibility(.hidden)
                    // 바뀜 (2026-11-10, 사용자): 막대 유리는 그림 폭(맥북+아이폰, 가로로 넓다)에 맞춰 옆으로 찌그러졌다 — 동그라미 유리를 직접
                    ToolbarItem(placement: .topBarTrailing) {
                        Button(editing ? "취소" : "맥에 보내기", systemImage: editing ? "xmark" : "macbook.and.iphone") {
                            if editing { stopEditing() } else { sending = true }
                        }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                        // 바뀜 (2026-11-10, 사용자): 맥북+아이폰 그림은 가로로 넓어 동그라미를 꽉 채웠다 — 작게
                        .font(.system(size: editing ? 17 : 15, weight: .medium))
                        .disabled(!editing && browser.url == nil)
                        .frame(width: 44, height: 44)
                        .contentShape(.circle)
                        .glassEffect(.regular.interactive(), in: .circle)
                    }
                    .sharedBackgroundVisibility(.hidden)
                }
            }
            .toolbar(.hidden, for: .tabBar)
            .sheet(isPresented: $sending) {
                if let url = browser.url {
                    SendToMacSheet(url: url, title: browser.title ?? url.host() ?? "")
                }
            }
            // 바뀜 (2026-11-11, 사용자): 키보드를 연 채 나가면 키보드를 내리고 주소 고치기를 끝낸다 (페이지 안 글칸도)
            .onDisappear {
                UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                keyboard = false
                editing = false
            }
            // 맥들에게 폰이 웹 탐색을 보고 있다고 알린다 (맥이 10분 동안 2초마다 받은편지함을 읽는다)
            .task {
                for mac in MacRemote.shared.aliveMacs { await RemoteMailbox.markActive(mac.macID) }
            }

    }

    private var activeDownloads: [MacDownloadEntry] {
        downloads.entries.values.filter(\.active).sorted { $0.since > $1.since }
    }

    /// 동그라미 유리 단추 + 오른쪽 위 빨간 숫자 (iPad 맥에 보내기 단추와 같은 크기)
    private var downloadsButton: some View {
        let count = activeDownloads.count
        return Button("다운로드", systemImage: "arrow.down.circle") { showDownloads = true }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .tint(.primary)
            .font(.system(size: 17, weight: .medium))
            .frame(width: 44, height: 44)
            .contentShape(.circle)
            .glassEffect(.regular.interactive(), in: .circle)
            .overlay(alignment: .topTrailing) {
                if count > 0 {
                    Text("\(count)")
                        .font(.caption2.weight(.bold))
                        .monospacedDigit()
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5)
                        .frame(minWidth: 18, minHeight: 18)
                        .background(.red, in: .capsule)
                        .offset(x: 4, y: -4)
                        .allowsHitTesting(false)
                }
            }
            .accessibilityValue(count > 0 ? "\(count)개 받는 중" : "")
            // 바뀜 (2026-11-11, 사용자: 팝업이 사라질 때 뱃지 움직임이 어색): 폴더 설정처럼 시트로
            .sheet(isPresented: $showDownloads) {
                ActiveDownloadsSheet()
            }
    }

    /// [‹] [›] [ 주소 막대 ] [맥에 보내기] — 고치는 중이면 [ 주소 입력 ] [취소]
    private var bar: some View {
        GlassEffectContainer { barContent }
    }

    /// 바뀜 (2026-11-09, 사용자): 주소를 고치다 ✕ 를 누르면 단추들이 이리저리 날아다녔다 — 오른쪽 단추는 하나를 두고 그림만 바꾸고(✕ ↔ 맥에 보내기),
    /// 유리마다 이름(glassEffectID)을 붙여 제자리에서 모양만 바뀌게, 뒤로·앞으로 덩어리는 제자리에서 흐려졌다 나타난다
    private var barContent: some View {
        // 바뀜 (2026-11-10, 사용자): 사파리와 같은 크기 — 단추·주소 막대 48pt, 사이 8pt, 양옆 여백 (아이폰 사파리를 재어 맞춤)
        HStack(spacing: 8) {
            if !editing {
                // 바뀜 (2026-11-09, 사용자): 뒤로·앞으로는 한 덩어리, 앞으로는 갈 곳이 있을 때만 (사파리처럼)
                HStack(spacing: 0) {
                    Button("뒤로", systemImage: "chevron.backward") { browser.webView.goBack() }
                        .disabled(!browser.canGoBack)
                        .frame(width: 48, height: 48)
                    if browser.canGoForward {
                        Button("앞으로", systemImage: "chevron.forward") { browser.webView.goForward() }
                            .frame(width: 44, height: 48)
                            .transition(.opacity.combined(with: .scale(scale: 0.6, anchor: .leading)))
                    }
                }
                .buttonStyle(.borderless)
                .glassEffect(.regular.interactive(), in: .capsule)
                .glassEffectID("nav", in: glass)
                .transition(.opacity)
                .animation(.smooth(duration: 0.25), value: browser.canGoForward)
            }
            // 바뀜 (2026-11-10, 사용자): 아이패드는 [단추] (빈칸) [주소] (빈칸) [단추]
            if isPad { Spacer(minLength: 12) }
            capsule
                .frame(maxWidth: isPad ? 560 : .infinity)
                .glassEffectID("address", in: glass)
            if isPad { Spacer(minLength: 12) }
            // "취소" 글 대신 ✕ (사용자)
            // 바뀜 (2026-11-10, 사용자 스크린샷): 유리 단추 모양은 그림 크기만큼만 커져 뒤로 단추보다 작았다 — 뒤로처럼 48pt 동그라미 유리
            Button(editing ? "취소" : "맥에 보내기", systemImage: editing ? "xmark" : "macbook.and.iphone") {
                if editing { stopEditing() } else { sending = true }
            }
            .disabled(!editing && browser.url == nil)
            .contentTransition(.symbolEffect(.replace))
            .buttonStyle(.borderless)
            // 맥북+아이폰 그림은 가로로 넓어 다른 단추보다 커 보인다 — 조금 작게 (2026-11-10, 사용자)
            .font(.system(size: editing ? 19 : 16, weight: .medium))
            .frame(width: 48, height: 48)
            .contentShape(.circle)
            .glassEffect(.regular.interactive(), in: .circle)
            .glassEffectID("action", in: glass)
        }
        .labelStyle(.iconOnly)
        // 웹 페이지 위에 떠 있어도 보이게 단추마다 유리 (사파리처럼)
        .tint(.primary)
        .font(.system(size: 19, weight: .medium))
        // 바뀜 (2026-11-10, 사용자): 여백이 바뀌니 더 어색했다 — 늘 같은 여백, 키보드 위 입력 도구 막대(시스템)와 같은 16pt
        .padding(.horizontal, isPad ? 20 : 16)
        .padding(.top, 8)
        .padding(.bottom, isPad ? 8 : 0)
    }

    private var capsule: some View {
        HStack(spacing: 8) {
            if editing {
                // 바뀜 (2026-11-10, 사용자): 돋보기 뺌 (사파리처럼). UIKit 글칸 — 누르면 전체 선택, 긴 주소도 끌어서 끝까지 고를 수 있게 (SwiftUI 글칸은 선택이 앞에 묶였다)
                AddressField(text: $address, focused: keyboard) {
                    browser.open(address)
                    stopEditing()
                } onBegin: {
                    keyboard = true
                } onEnd: {
                    // 바뀜 (2026-11-11, 사용자: 즐겨찾기를 스크롤하면 창이 닫혔다): 키보드만 내려가고 고치는 화면은 그대로 (사파리처럼). 닫기는 ✕
                    keyboard = false
                }
            } else {
                bookmarkButton
                Button { startEditing() } label: {
                    HStack(spacing: 4) {
                        if browser.url?.scheme == "https" {
                            Image(systemName: "lock.fill").font(.caption2)
                        }
                        Text(browser.url?.host() ?? "주소 또는 검색어")
                            .lineLimit(1)
                            .foregroundStyle(browser.url == nil ? .secondary : .primary)
                    }
                    .font(.body)
                    .frame(maxWidth: .infinity)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("주소: \(browser.url?.absoluteString ?? "없음")")
                Button(browser.isLoading ? "멈추기" : "새로고침", systemImage: browser.isLoading ? "xmark" : "arrow.clockwise") {
                    if browser.isLoading { browser.webView.stopLoading() } else { browser.webView.reload() }
                }
                .disabled(browser.url == nil)
            }
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 16)
        .frame(height: 48)
        .overlay(alignment: .bottom) {
            // 불러오는 정도
            if browser.isLoading {
                GeometryReader { proxy in
                    Capsule().fill(.tint).frame(width: proxy.size.width * browser.progress, height: 2)
                }
                .frame(height: 2)
                .padding(.horizontal, 18)
            }
        }
        .glassEffect(.regular.interactive(), in: .capsule)
    }

    /// 지금 페이지를 즐겨찾기에 넣기·빼기 (★ 면 들어 있음)
    private var bookmarkButton: some View {
        let saved = bookmarks.bookmark(for: browser.url)
        return Button(saved == nil ? "즐겨찾기에 넣기" : "즐겨찾기에서 빼기", systemImage: saved == nil ? "star" : "star.fill") {
            guard let url = browser.url else { return }
            if let saved { bookmarks.remove(saved.id) } else { bookmarks.add(title: browser.title ?? "", url: url) }
        }
        .disabled(browser.url == nil)
    }

    private func startEditing() {
        address = browser.url?.absoluteString ?? ""
        keyboard = true
        withAnimation(.smooth(duration: 0.25)) { editing = true }
    }

    /// 바뀜 (2026-11-10, 사용자): ✕ 를 누르면 키보드가 내려가는 것과 막대가 바뀌는 것이 겹쳐 어색했다 —
    ///   키보드를 먼저 내리고(막대가 키보드를 따라 내려간다), 다 내려간 뒤 막대 모양을 바꾼다
    private func stopEditing() {
        // 바뀜 (2026-11-11): 스크롤로 키보드가 이미 내려가 있으면 바로 막대를 바꾼다
        guard editing else { return }
        guard keyboard else {
            withAnimation(.smooth(duration: 0.25)) { editing = false }
            return
        }
        keyboard = false
        Task {
            try? await Task.sleep(for: .seconds(0.3))
            withAnimation(.smooth(duration: 0.25)) { editing = false }
        }
    }

    /// 고를 수 있는 맥과 그 맥에 열린 탭 (주소가 있는 것만 — 빈 새 탭은 볼 것도 닫을 것도 없다)
    private var openMacTabs: [(mac: MacPresence, tabs: [MacPresence.Tab])] {
        MacRemote.shared.aliveMacs.compactMap { mac in
            let tabs = (macTabs[mac.macID] ?? mac.tabs).filter { $0.url != nil && !closedTabs.contains($0.id) }
            return tabs.isEmpty ? nil : (mac, tabs)
        }
    }

    private func loadMacTabs() async {
        for mac in MacRemote.shared.aliveMacs {
            if let tabs = await RemoteMailbox.outbox(mac.macID)?.tabs { macTabs[mac.macID] = tabs }
        }
    }

    /// 맥의 탭 닫기 (재생하며 받는 탭은 맥도 닫지 않는다)
    private func closeMacTab(_ tab: MacPresence.Tab, on mac: MacPresence) {
        closedTabs.insert(tab.id)
        let command = MacCommand(id: UUID().uuidString, macID: mac.macID, action: .close, url: nil, tabID: tab.id,
                                 mediaID: nil, click: nil, sentAt: .now, from: UIDevice.current.name)
        Task { _ = await RemoteMailbox.send(command) }
    }

    /// 즐겨찾기 (맥과 같은 목록)
    /// 바뀜 (2026-11-10, 사용자): 위에 맥에 열린 탭 — 누르면 이 기기에서 그 페이지를 열고(맥과 상관없이), 왼쪽으로 밀면 맥에서 닫는다.
    ///   재생하며 받는 중인 탭은 닫을 수 없다
    private var favorites: some View {
        let macs = openMacTabs
        return Group {
            if bookmarks.items.isEmpty && macs.isEmpty {
                ContentUnavailableView("즐겨찾기 없음", systemImage: "star",
                                       description: Text("주소를 넣어 둘러보고, 받을 영상이 있는 페이지에서 [맥에 보내기] 를 누르세요."))
            } else {
                List {
                    ForEach(macs, id: \.mac.macID) { entry in
                        Section("\(entry.mac.name)에 열린 탭") {
                            ForEach(entry.tabs) { tab in
                                Button {
                                    if let url = tab.url { browser.open(url) }
                                    stopEditing()
                                } label: {
                                    HStack(spacing: 10) {
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(tab.title).lineLimit(1).foregroundStyle(.primary)
                                            Text(tab.busy ? "재생하며 받는 중" : (tab.url.flatMap { URL(string: $0)?.host() } ?? ""))
                                                .font(.caption)
                                                .foregroundStyle(tab.busy ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                                                .lineLimit(1)
                                        }
                                        Spacer(minLength: 0)
                                        if tab.busy {
                                            Image(systemName: "record.circle").foregroundStyle(.red)
                                        }
                                    }
                                }
                                .swipeActions(edge: .trailing) {
                                    if !tab.busy {
                                        Button("닫기", systemImage: "xmark", role: .destructive) { closeMacTab(tab, on: entry.mac) }
                                    }
                                }
                            }
                        }
                    }
                    if !bookmarks.items.isEmpty {
                    Section("즐겨찾기") {
                        ForEach(bookmarks.items) { item in
                            Button {
                                browser.open(item.url)
                                stopEditing()
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.title).lineLimit(1).foregroundStyle(.primary)
                                    Text(URL(string: item.url)?.host() ?? item.url)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                            }
                        }
                        .onDelete { offsets in
                            for index in offsets { bookmarks.remove(bookmarks.items[index].id) }
                        }
                    }
                    }
                }
                .scrollDismissesKeyboard(.immediately)
            }
        }
        .background(Color(.systemBackground))
    }
}

/// 웹 탐색 오른쪽 위 [다운로드]: 맥에서 받는 중인 것만 (끝난 것까지는 [다운로드] 화면, 2026-11-11 사용자)
private struct ActiveDownloadsSheet: View {
    @State private var downloads = MacDownloads.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let active = downloads.entries.filter(\.value.active).sorted { $0.value.since > $1.value.since }
        NavigationStack {
            Group {
                if active.isEmpty {
                    ContentUnavailableView("받는 중인 영상 없음", systemImage: "arrow.down.circle",
                                           description: Text("맥에서 받기 시작하면 여기에 나타납니다."))
                } else {
                    List(active, id: \.key) { row in
                        MacDownloadRow(entry: row.value)
                    }
                }
            }
            .navigationTitle("받는 중")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(role: .close) { dismiss() } }
            }
            // 당겨서·열 때 바로 받아 온다 (iCloud 알림이 늦을 때)
            .refreshable { await SyncEngine.shared.syncNow() }
            .task { await SyncEngine.shared.syncNow() }
        }
        .presentationDetents([.medium, .large])
    }
}

/// [맥에 보내기]: 맥 고르기 → 새 탭이나 열린 탭 고르기 → 보내면 맥이 찾은 영상
struct SendToMacSheet: View {
    let url: URL
    let title: String
    @Environment(\.dismiss) private var dismiss
    @State private var sent: MacCommand?

    var body: some View {
        NavigationStack {
            Group {
                if let sent {
                    MacFoundView(command: sent)
                } else {
                    picker
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    // 바뀜 (2026-11-10, 사용자): 글 대신 ✕
                    // 제목을 주면 글로 나온다 — 제목 없이 시스템 ✕ (2026-11-10, 사용자)
                    Button(role: .close) { dismiss() }
                }
            }
        }
    }

    private var picker: some View {
        let macs = MacRemote.shared.aliveMacs
        return Group {
            if macs.isEmpty {
                ContentUnavailableView("켜져 있는 맥 없음", systemImage: "desktopcomputer",
                                       description: Text("맥에서 iRayer 를 켜 두세요. 켜진 맥은 몇 분 안에 여기에 나타납니다."))
            } else {
                List {
                    Section {
                        Text(title.isEmpty ? url.absoluteString : title)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    ForEach(macs, id: \.macID) { mac in
                        Section(mac.name) {
                            Button { send(to: mac, tabID: nil) } label: {
                                Label("새 탭에서 열기", systemImage: "plus.square.on.square")
                            }
                            ForEach(mac.tabs) { tab in
                                Button { send(to: mac, tabID: tab.id) } label: {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(tab.title).lineLimit(1)
                                        Text(tab.busy ? "재생하며 받는 중 — 바꿀 수 없음" : (tab.url ?? "빈 탭"))
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }
                                }
                                .disabled(tab.busy)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("맥에 보내기")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await SyncEngine.shared.syncNow() }
        .task { await SyncEngine.shared.syncNow() }
    }

    private func send(to mac: MacPresence, tabID: String?) {
        let command = MacCommand(id: UUID().uuidString, macID: mac.macID, action: .open, url: url.absoluteString, tabID: tabID,
                                 mediaID: nil, click: nil, sentAt: .now, from: UIDevice.current.name)
        sent = command
        // 바뀜 (2026-11-10): 받은편지함 레코드에 바로 (동기화 엔진은 3~4분 걸렸다)
        Task { await RemoteMailbox.send(command) }
    }
}

/// 맥이 그 페이지에서 찾은 영상: 파일·표준 HLS 는 [받기] (맥이 받는다, 진행은 [다운로드]).
/// 재생하며 받기만 되는 영상은 아직 맥에서 (재생을 시켜야 해서 나중에, 사용자)
struct MacFoundView: View {
    let command: MacCommand
    /// 맥의 보낸편지함에서 이 명령으로 연 탭 (2026-11-10: 1.5초마다 읽는다)
    @State private var found: MacFound?
    /// 받기를 보낸 영상
    @State private var requested: Set<String> = []
    @State private var waitedLong = false
    /// 재생 단추 누르기 화면 (재생하며 받기, 2026-11-10)
    @State private var pressing = false
    /// 재생하며 받기를 보냈다 (맥이 재생해 보는 중)
    @State private var pendingCapture = false

    var body: some View {
        Group {
            if let found {
                List {
                    Section {
                        Text(found.title).lineLimit(2)
                        if found.loading {
                            Label("맥에서 페이지를 여는 중", systemImage: "hourglass")
                                .foregroundStyle(.secondary)
                        }
                        // 바뀜 (2026-11-10, 사용자): 맥의 재생하며 받기 상태
                        if let state = found.capture {
                            Label(Self.captureText(state, fraction: found.captureFraction),
                                  systemImage: state == "capturing" || state == "saved" ? "checkmark.circle.fill" : "record.circle")
                                .foregroundStyle(state == "waiting" ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tint))
                            if state == "waiting" {
                                Button("폰에서 재생 단추 누르기", systemImage: "hand.tap") { pressing = true }
                            }
                        }
                    }
                    Section("찾은 영상") {
                        if found.media.isEmpty {
                            Text(found.loading ? "찾는 중…" : "아직 찾은 영상이 없습니다. 맥에서 영상을 재생하면 나타날 수 있습니다.")
                                .foregroundStyle(.secondary)
                        }
                        ForEach(found.media) { media in
                            row(media, in: found)
                        }
                    }
                }
            } else {
                VStack(spacing: 12) {
                    ProgressView()
                    Text(waitedLong ? "맥이 답하지 않습니다. 맥에서 iRayer 가 켜져 있는지 확인하세요." : "맥에 보내는 중…")
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding()
            }
        }
        .sheet(isPresented: $pressing) {
            if let found { PressPlayView(found: found) }
        }
        .navigationTitle("맥에서 찾은 영상")
        .navigationBarTitleDisplayMode(.inline)
        // 보고 있는 동안 맥의 보낸편지함을 읽는다
        .task {
            let start = Date.now
            while !Task.isCancelled {
                if let outbox = await RemoteMailbox.outbox(command.macID),
                   let mine = outbox.found.first(where: { $0.commandID == command.id }) {
                    found = mine
                }
                if found == nil, Date.now.timeIntervalSince(start) > 60 { waitedLong = true }
                try? await Task.sleep(for: .seconds(1.5))
            }
        }
    }

    private func row(_ media: MacFound.Media, in found: MacFound) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(media.name).lineLimit(2)
                Text(detail(media))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            // 바뀜 (2026-11-10, 사용자): 누른 뒤 맥이 답할 때까지 돌아가는 표시 (아무 반응이 없어 보였다), 맥이 살펴보는 중이면 단추 대신 "확인 중"
            if media.started || (media.capturesOnly && found.capture != nil && found.capture != "waiting") {
                Label("받는 중", systemImage: "checkmark.circle.fill")
                    .labelStyle(.iconOnly)
                    .font(.title2)
                    .foregroundStyle(.tint)
                    .accessibilityLabel("맥에서 받는 중")
            } else if requested.contains(media.id) || (media.capturesOnly && pendingCapture) {
                ProgressView()
                    .accessibilityLabel("맥에 보내는 중")
            } else if media.checking == true {
                ProgressView()
                    .accessibilityLabel("맥에서 영상을 살펴보는 중")
            } else if media.downloadable {
                Button("받기", systemImage: "arrow.down.circle") { download(media, in: found) }
                    .labelStyle(.iconOnly)
                    .font(.title2)
                    .buttonStyle(.borderless)
            } else if media.capturesOnly, found.capture == nil {
                // 바뀜 (2026-11-10, 사용자): 맥에서 재생하며 받기를 켜고 소리 없이 재생해 본다 → 안 되면 폰에서 재생 단추를 누른다
                Button("재생하며 받기", systemImage: "record.circle") { startCapture(in: found) }
                    .labelStyle(.iconOnly)
                    .font(.title2)
                    .buttonStyle(.borderless)
            }
        }
    }

    private func detail(_ media: MacFound.Media) -> String {
        var parts = [media.kind]
        if let quality = media.quality { parts.append(quality) }
        if let size = media.size { parts.append(ByteCountFormatter.string(fromByteCount: size, countStyle: .file)) }
        if let reason = media.unsupported { parts.append("\(reason)라 받을 수 없음") }
        else if media.capturesOnly { parts.append("재생하며 받기만 됨") }
        if media.checking == true { parts = [media.kind, "맥에서 받는 방법을 확인하는 중…"] }
        else if media.started { parts.append("맥에서 받는 중 — [다운로드] 에서 보기") }
        else if requested.contains(media.id) { parts.append("맥에 받기를 보냈어요…") }
        else if media.capturesOnly, pendingCapture, found?.capture == nil || found?.capture == "waiting" { parts.append("맥에서 재생해 보는 중…") }
        return parts.joined(separator: " · ")
    }

    static func captureText(_ state: String, fraction: Double?) -> String {
        let percent = fraction.map { " · \(Int(($0 * 100).rounded()))%" } ?? ""
        switch state {
        case "waiting": return "맥에서 재생을 기다리는 중"
        case "capturing": return "맥에서 받기 시작됨\(percent)"
        case "saving": return "맥에서 영상 묶는 중"
        case "saved": return "맥에서 저장함"
        default: return "맥에서 받기 실패"
        }
    }

    private func startCapture(in found: MacFound) {
        pendingCapture = true
        let order = MacCommand(id: UUID().uuidString, macID: found.macID, action: .capture, url: nil, tabID: found.tabID,
                               mediaID: nil, click: nil, sentAt: .now, from: UIDevice.current.name)
        Task {
            await RemoteMailbox.send(order)
            // 맥이 소리 없이 재생해 보는 동안 기다렸다가, 그래도 재생을 기다리면 누르기 화면
            try? await Task.sleep(for: .seconds(6))
            if self.found?.capture != "capturing" { pressing = true }
        }
    }

    private func download(_ media: MacFound.Media, in found: MacFound) {
        let order = MacCommand(id: UUID().uuidString, macID: found.macID, action: .download, url: nil, tabID: found.tabID,
                               mediaID: media.id, click: nil, sentAt: .now, from: UIDevice.current.name)
        requested.insert(media.id)
        Task { await RemoteMailbox.send(order) }
    }
}

/// 재생 단추 누르기 (2026-11-10, 사용자): 맥에서 연 페이지를 폰에서도 데스크톱 모양으로 띄우고, 사용자가 누른 곳을
/// (프레임 주소 · CSS 선택자 · 화면 속 위치) 맥으로 보내 맥의 그 탭에서 똑같이 누른다. 폰에서는 누른 것이 실제로 눌리지 않는다 (재생·이동 안 함).
/// 맥에서 받기가 시작되면 "맥에서 받기 시작됨"
struct PressPlayView: View {
    let found: MacFound
    @Environment(\.dismiss) private var dismiss
    @State private var page = PressPage()
    @State private var state: String?
    @State private var fraction: Double?
    @State private var sentCount = 0

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                banner
                PressWebContainer(page: page)
            }
            .navigationTitle("재생 단추 누르기")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(role: .close) { dismiss() } }
            }
        }
        .task {
            if let url = found.url.flatMap(URL.init(string:)) { page.load(url) }
            page.onPress = { click in send(click) }
        }
        .task {
            // 맥의 보낸편지함에서 이 탭의 재생하며 받기 상태
            while !Task.isCancelled {
                if let outbox = await RemoteMailbox.outbox(found.macID), let mine = outbox.found.first(where: { $0.tabID == found.tabID }) {
                    state = mine.capture
                    fraction = mine.captureFraction
                }
                try? await Task.sleep(for: .seconds(1.5))
            }
        }
    }

    private var banner: some View {
        HStack(spacing: 10) {
            if state == "capturing" || state == "saved" {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text(MacFoundView.captureText(state ?? "", fraction: fraction))
            } else {
                Image(systemName: "hand.tap")
                Text(sentCount == 0 ? "영상의 재생 단추를 누르세요. 누른 곳을 맥에서 똑같이 누릅니다."
                                    : "맥에서 누름 (\(sentCount)번). 재생되지 않으면 다른 곳을 눌러 보세요.")
            }
            Spacer(minLength: 0)
        }
        .font(.footnote)
        .padding(.horizontal)
        .padding(.vertical, 10)
        .background(.bar)
    }

    private func send(_ click: MacCommand.Click) {
        sentCount += 1
        let order = MacCommand(id: UUID().uuidString, macID: found.macID, action: .click, url: nil, tabID: found.tabID,
                               mediaID: nil, click: click, sentAt: .now, from: UIDevice.current.name)
        Task { await RemoteMailbox.send(order) }
    }
}

/// 누르기 화면의 웹뷰: 데스크톱 모양(맥과 같은 페이지 구조), 미디어는 저절로 재생하지 않고, 누르면 그 자리 정보만 알려 준다
@MainActor
@Observable
final class PressPage: NSObject, WKScriptMessageHandler {
    let webView: WKWebView
    @ObservationIgnored var onPress: ((MacCommand.Click) -> Void)?

    override init() {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.preferredContentMode = .desktop
        configuration.mediaTypesRequiringUserActionForPlayback = .all
        configuration.allowsInlineMediaPlayback = true
        let controller = WKUserContentController()
        controller.addUserScript(WKUserScript(source: Self.pressScript, injectionTime: .atDocumentEnd, forMainFrameOnly: false))
        configuration.userContentController = controller
        AdBlock.shared.attach(controller)  // 바뀜 (2026-11-12): 광고 차단 규칙
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        controller.add(WeakPressHandler(self), name: "irayerPress")
    }

    func load(_ url: URL) { webView.load(URLRequest(url: url)) }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any] else { return }
        let click = MacCommand.Click(frameURL: body["frame"] as? String ?? message.frameInfo.request.url?.absoluteString,
                                     selector: body["selector"] as? String,
                                     x: body["x"] as? Double ?? 0.5, y: body["y"] as? Double ?? 0.5,
                                     label: body["label"] as? String)
        onPress?(click)
    }

    /// 누른 요소의 선택자(아이디가 있으면 거기까지, 아니면 같은 태그 중 몇 번째)·위치를 알리고, 실제로는 누르지 않는다
    private static let pressScript = """
    (() => {
      function selectorOf(el) {
        const parts = [];
        while (el && el.nodeType === 1 && parts.length < 14) {
          let part = el.tagName.toLowerCase();
          if (el.id) { parts.unshift(part + '#' + CSS.escape(el.id)); break; }
          const parent = el.parentElement;
          if (parent) {
            const same = [...parent.children].filter(c => c.tagName === el.tagName);
            if (same.length > 1) part += ':nth-of-type(' + (same.indexOf(el) + 1) + ')';
          }
          parts.unshift(part);
          el = parent;
        }
        return parts.join(' > ');
      }
      window.addEventListener('click', e => {
        e.preventDefault();
        e.stopImmediatePropagation();
        const el = e.target;
        const label = (el.getAttribute && (el.getAttribute('aria-label') || el.getAttribute('title'))) || (el.innerText || '').trim().slice(0, 40) || el.tagName;
        window.webkit.messageHandlers.irayerPress.postMessage({
          selector: selectorOf(el), x: e.clientX / innerWidth, y: e.clientY / innerHeight, frame: location.href, label: label
        });
      }, true);
    })();
    """
}

private final class WeakPressHandler: NSObject, WKScriptMessageHandler {
    weak var target: PressPage?
    init(_ target: PressPage) { self.target = target }
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        MainActor.assumeIsolated { target?.userContentController(controller, didReceive: message) }
    }
}

private struct PressWebContainer: UIViewRepresentable {
    let page: PressPage
    func makeUIView(context: Context) -> WKWebView { page.webView }
    func updateUIView(_ view: WKWebView, context: Context) {}
}

/// 주소 입력칸 (UITextField): 고치기 시작하면 주소 전체를 골라 둔다 (사파리처럼), 긴 주소도 끌어 고르면 글칸이 따라 넘어간다
private struct AddressField: UIViewRepresentable {
    @Binding var text: String
    var focused: Bool
    var onSubmit: () -> Void
    var onBegin: () -> Void = {}
    var onEnd: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> QuietTextField {
        let field = QuietTextField()
        field.placeholder = "주소 또는 검색어"
        field.keyboardType = .webSearch
        field.returnKeyType = .go
        field.autocapitalizationType = .none
        field.autocorrectionType = .no
        field.spellCheckingType = .no
        field.clearButtonMode = .whileEditing
        field.font = .preferredFont(forTextStyle: .body)
        field.adjustsFontForContentSizeCategory = true
        field.delegate = context.coordinator
        field.addTarget(context.coordinator, action: #selector(Coordinator.changed(_:)), for: .editingChanged)
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }

    func updateUIView(_ field: QuietTextField, context: Context) {
        context.coordinator.parent = self
        if field.text != text { field.text = text }
        // 바뀜 (2026-11-10, 사용자): 막대가 바뀌는 애니메이션 중에 글칸이 화면에 붙기 전 키보드를 부르면 곧 사라졌다 —
        //   화면에 붙은 다음(다음 차례)에 한 번만 부르고 전체 선택
        if focused, !field.isFirstResponder, !context.coordinator.focusing {
            context.coordinator.focusing = true
            // 바뀜 (2026-11-11, 사용자: 고르는 과정이 어색, 손잡이가 보임): selectAll 대신 사파리처럼 조용히 전체 선택 (textFieldDidBeginEditing)
            // 바뀜 (2026-11-11, 사용자: 처음 커서가 검게 보였다): 커서 색을 투명으로 하는 것으로는 안 숨겨졌다 —
            //   글칸이 커서·선택 모양을 아예 내주지 않게 하고(QuietTextField) 키보드를 부른다
            field.quiet = !(field.text ?? "").isEmpty
            DispatchQueue.main.async {
                field.becomeFirstResponder()
                context.coordinator.focusing = false
            }
        } else if !focused, field.isFirstResponder {
            field.resignFirstResponder()
        }
    }

    final class Coordinator: NSObject, UITextFieldDelegate {
        var parent: AddressField
        var focusing = false
        init(_ parent: AddressField) { self.parent = parent }

        @objc func changed(_ field: UITextField) {
            endQuiet(field)
            parent.text = field.text ?? ""
        }

        // MARK: 사파리처럼 조용한 전체 선택 (2026-11-11, 사용자)
        // 실제로는 글 전체를 골라 두되(쳐 넣으면 한글 조합까지 그대로 바뀐다) 시스템 선택 표시(회색 칠·손잡이·커서)는
        // 글칸이 내주지 않고(QuietTextField), 글 뒤에 파란 칠을 직접 그린다. 글을 쓰거나 다른 곳을 누르면 원래대로.
        private weak var highlight: UIView?

        private func fullRange(_ field: UITextField) -> UITextRange? {
            field.textRange(from: field.beginningOfDocument, to: field.endOfDocument)
        }

        private func isAllSelected(_ field: UITextField) -> Bool {
            guard let range = field.selectedTextRange, let all = fullRange(field) else { return false }
            return field.compare(range.start, to: all.start) == .orderedSame && field.compare(range.end, to: all.end) == .orderedSame
        }

        private func selectQuietly(_ field: QuietTextField) {
            guard !(field.text ?? "").isEmpty, let all = fullRange(field) else {
                endQuiet(field)
                return
            }
            field.quiet = true
            if !isAllSelected(field) { field.selectedTextRange = all }
        }

        private func drawHighlight(_ field: QuietTextField) {
            guard field.quiet, let all = fullRange(field) else { return }
            var rect = field.firstRect(for: all).insetBy(dx: -2, dy: -1)
            rect = rect.intersection(field.editingRect(forBounds: field.bounds).insetBy(dx: -2, dy: 0))
            guard !rect.isNull, rect.width > 0 else { return }
            highlight?.removeFromSuperview()
            let view = UIView(frame: rect)
            view.backgroundColor = UIColor.systemBlue.withAlphaComponent(0.3)
            view.layer.cornerRadius = 4
            view.isUserInteractionEnabled = false
            field.insertSubview(view, at: 0)
            highlight = view
        }

        private func endQuiet(_ field: UITextField) {
            highlight?.removeFromSuperview()
            guard let field = field as? QuietTextField, field.quiet else { return }
            field.quiet = false
            // 커서를 다시 그리게 한다
            field.selectedTextRange = field.selectedTextRange
        }

        func textFieldDidChangeSelection(_ field: UITextField) {
            guard let field = field as? QuietTextField, field.quiet, !isAllSelected(field) else { return }
            // 키보드를 부르며 커서를 끝에 놓는 것은 다시 전체로, 그 뒤 사용자가 누른 것은 원래대로
            if field.selecting { field.selectedTextRange = fullRange(field) } else { endQuiet(field) }
        }

        func textFieldShouldReturn(_ field: UITextField) -> Bool {
            parent.onSubmit()
            return false
        }

        /// 바뀜 (2026-11-11): 포커스 → 바로 전체 선택 → 키보드가 올라오는 동안 그대로 (사파리처럼)
        func textFieldDidBeginEditing(_ field: UITextField) {
            parent.onBegin()
            guard let field = field as? QuietTextField else { return }
            field.selecting = true
            selectQuietly(field)
            DispatchQueue.main.async { [weak self, weak field] in
                guard let self, let field, field.isFirstResponder else { return }
                if field.quiet { self.selectQuietly(field) }
                field.selecting = false
                self.drawHighlight(field)
            }
        }

        /// 화면에서 떨어져 나가며 끝난 것(애니메이션 중 다시 만들어짐)은 무시한다
        func textFieldDidEndEditing(_ field: UITextField) {
            endQuiet(field)
            guard field.window != nil else { return }
            parent.onEnd()
        }
    }
}

/// 조용한 전체 선택 동안 커서·선택 모양(회색 칠·손잡이)을 내주지 않는 글칸 (2026-11-11)
final class QuietTextField: UITextField {
    var quiet = false
    /// 포커스를 받는 첫 차례 (시스템이 커서를 끝에 놓는 것을 되돌린다)
    var selecting = false
    override func caretRect(for position: UITextPosition) -> CGRect {
        quiet ? .zero : super.caretRect(for: position)
    }
    override func selectionRects(for range: UITextRange) -> [UITextSelectionRect] {
        quiet ? [] : super.selectionRects(for: range)
    }
}
#endif
