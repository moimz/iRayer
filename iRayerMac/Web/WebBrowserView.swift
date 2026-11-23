import SwiftUI
import WebKit

/// 사이드바 [웹 탐색]: 웹 페이지를 보며 영상을 찾는 화면.
/// 도구 막대는 Safari 처럼 [‹ ›] · 가운데 주소칸 · [새로고침][감지 패널]. 감지 패널은 라이브러리 설정처럼 페이지 위 오른쪽에 겹쳐 뜬다 (settingsPanel).
/// 웹뷰 자체는 여기 없고 아래에 늘 깔려 있다 (WebPageLayer) — 이 화면은 그 위에 도구 막대·안내·패널만 얹는다.
/// 바뀜 (2026-11-07): 주소칸 오른쪽 이동(→), 즐겨찾기 추가(☆)·목록, 보기 비율, 사이트 닫기, 설정 패널(감지 패널과 같은 자리, 둘 중 하나만).
/// 바뀜 (2026-11-08): 오른쪽은 [감지된 영상(영상 그림)][설정], 새로고침 뺌. 감지 패널만 웹뷰를 좁히고 설정 패널은 위에 겹쳐 뜬다 (둘 다 열 수 있음).
/// 바뀜 (2026-11-08): 탭 (WebTabs) — 내비 옆 탭 단추로 새 탭·탭 오가기·닫기, 주소칸 오른쪽에 탭마다 소리 끄기.
struct WebBrowserView: View {
    @State private var tabs = WebTabs.shared
    @State private var bookmarks = WebBookmarks.shared
    /// 지금 탭의 브라우저·재생하며 받기
    private var browser: WebBrowser { tabs.current.browser }
    private var capture: WebCapture { tabs.current.capture }
    /// 받는 중이라 닫기 전에 물을 탭 (사이트 닫기·탭 닫기)
    @State private var closing: (tab: UUID, closesTab: Bool)?
    @State private var showsSettings = false
    @State private var showsBookmarks = false
    @State private var address = AddressController()

    var body: some View {
        // 빈 바탕은 눌러도 아래 웹뷰로 간다
        Color.clear
            .allowsHitTesting(false)
            .overlay {
                if browser.url == nil {
                    // 아직 아무 페이지도 열지 않았을 때
                    ContentUnavailableView("웹 탐색", systemImage: "globe",
                                           description: Text("위 주소칸에 주소나 검색어를 입력하세요."))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(.background)
                }
            }
            .overlay(alignment: .top) {
                if browser.isLoading {
                    ProgressView(value: browser.progress)
                        .progressViewStyle(.linear)
                        .tint(.accentColor)
                        .frame(height: 2)
                }
            }
            // 바뀜 (2026-11-08, 사용자): 감지된 영상 패널은 다른 메뉴(홈 등)에 갔다 와도 열린 채로 (열림 상태를 WebTabs 에 둔다).
            //   설정 패널은 지금처럼 이 화면의 상태라 다른 메뉴에 갔다 오면 닫힌다
            .settingsPanel(isPresented: $tabs.sidePanelOpen, width: WebBrowser.sidePanelWidth) { DetectedPanel() }
            .settingsPanel(isPresented: $showsSettings, width: WebBrowser.sidePanelWidth) { WebSettingsPanel() }
            // 바뀜 (2026-11-08, 사용자): 웹뷰를 좁히는 것은 감지된 영상 패널만. 설정은 라이브러리 설정처럼 위에 떠서 덮는다
            //   (감지된 영상 패널이 열려 있어도 그 위에 겹쳐 뜬다, 둘을 따로 열고 닫음)
            .background { zoomShortcuts }
            .toolbar {
                ToolbarItemGroup(placement: .navigation) {
                    Button("뒤로", systemImage: "chevron.left") { browser.goBack() }
                        .disabled(!browser.canGoBack)
                        .help("뒤로")
                    Button("앞으로", systemImage: "chevron.right") { browser.goForward() }
                        .disabled(!browser.canGoForward)
                        .help("앞으로")
                }
                // 바뀜 (2026-11-08, 사용자): 탭 단추는 ‹ › 묶음과 떨어진 따로 된 단추로
                // 바뀜 (2026-11-08): 맥에서는 ToolbarSpacer(.fixed) 만으로는 ‹ › 와 한 유리에 묶여 있었다 (사용자) →
                //   이 칸은 같이 쓰는 유리 배경을 끄고 단추가 제 유리를 갖게 한다
                // 바뀜 (2026-11-08): 유리를 직접 그리던 것을 되돌리고 재생목록의 [+] 처럼 — .navigation 이 아닌 동작 자리(.primaryAction)
                //   칸으로 두면 ‹ › 바로 뒤에 제 유리로 붙는다 (제목을 숨긴 창이라 동작 자리도 왼쪽부터 흐른다). 주소칸을 가운데(.principal)에
                //   두면 동작 자리가 오른쪽으로 밀리므로, 주소칸도 동작 자리에 두고 양옆 빈 칸(flexible)으로 가운데쯤에 둔다
                ToolbarItem(placement: .primaryAction) {
                    tabMenu
                }
                ToolbarSpacer(.flexible)
                // 바뀜 (2026-11-07): 즐겨찾기·주소칸·닫기·이동을 도구 막대 칸으로 나눔 (한 칸에 몰면 단추마다 도움말이 따로 뜨지 않고 누름이 주소칸에 먹혔다)
                ToolbarItemGroup(placement: .primaryAction) {
                    // 페이지가 없으면 즐겨찾기 목록, 열려 있으면 즐겨찾기 추가(☆)·빼기(★)
                    Button(leadingTitle, systemImage: leadingSymbol) { leadingAction() }
                        .help(leadingTitle)
                        .popover(isPresented: $showsBookmarks, arrowEdge: .bottom) {
                            BookmarkList { url in
                                showsBookmarks = false
                                browser.open(url)
                            }
                        }
                    // 라이브러리 화면의 찾기 칸과 비슷한 둥근 칸 (돋보기·✕ 없는 글 칸)
                    AddressField(url: browser.url, controller: address) { browser.open($0) }
                        // 바뀜 (2026-11-07): 100 좁게, 도구 막대 유리 위에 한 겹 더 그리던 음영은 뺌 (사용자)
                        .padding(.horizontal, 6)
                        // 바뀜 (2026-11-08): 창이 좁으면 칸이 최소 폭보다 먼저 줄지 못해 통째로 » 넘침 메뉴로 빠지고 즐겨찾기 단추만 남았다 (사용자) →
                        //   최소 폭 200 → 120 (넘치는 순서는 맥이 오른쪽 끝부터: [영상 목록][설정] → 이동·소리 → 주소칸)
                        // 바뀜 (2026-11-08): 도구 막대가 칸을 줄이지 않아 효과가 없었다 — 대신 라이브러리 창 최소 폭을 1000 으로 (사용자)
                        .frame(minWidth: 120, idealWidth: 420, maxWidth: 540, minHeight: 28, maxHeight: 28)
                    // 바뀜 (2026-11-08, 사용자): 사이트 닫기(✕)는 뺌 — 탭 메뉴의 [이 탭 닫기] (탭이 하나면 사이트만 닫는다)
                    // 바뀜 (2026-11-08, 사용자): 소리 끄기는 설정에서 주소칸 옆으로 (늘 보임, 이 탭에만)
                    if browser.canMute {
                        Button(browser.isMuted ? "소리 켜기" : "소리 끄기",
                               systemImage: browser.isMuted ? "speaker.slash" : "speaker.wave.2") { browser.setMuted(!browser.isMuted) }
                            .help(browser.isMuted ? "이 탭 소리 켜기" : "이 탭 소리 끄기")
                    }
                    Button("이동", systemImage: "arrow.right") { address.submit() }
                        .help("주소칸에 쓴 곳으로 이동")
                }
                ToolbarSpacer(.flexible)
                // 바뀜 (2026-11-08, 사용자): 새로고침은 뺌 (이동 단추를 다시 누르면 된다), 감지된 영상은 사이드바 그림 대신 영상 그림, 그 옆에 설정
                ToolbarItemGroup(placement: .primaryAction) {
                    Button("감지된 영상", systemImage: "film.stack") { tabs.sidePanelOpen.toggle() }
                        .badge(browser.detected.count)
                        .help(tabs.sidePanelOpen ? "감지된 영상 닫기" : "감지된 영상 보기")
                    Button("웹 탐색 설정", systemImage: "gearshape") { showsSettings.toggle() }
                        .help(showsSettings ? "설정 닫기" : "웹 탐색 설정")
                }
            }
            .confirmationDialog("재생하며 받는 중입니다", isPresented: Binding(get: { closing != nil }, set: { if !$0 { closing = nil } }),
                                titleVisibility: .visible, presenting: closing) { target in
                Button("받은 데까지 저장하고 닫기") {
                    tabs.tabs.first { $0.id == target.tab }?.capture.stop(save: true)
                    finishClose(target)
                }
                Button("버리고 닫기", role: .destructive) {
                    tabs.tabs.first { $0.id == target.tab }?.capture.stop(save: false)
                    finishClose(target)
                }
                Button("취소", role: .cancel) {}
            } message: { target in
                Text(target.closesTab ? "탭을 닫으면 재생하며 받기가 끝납니다. 받기 단추로 받는 파일은 계속 받습니다."
                     : "사이트를 닫으면 재생하며 받기가 끝납니다. 받기 단추로 받는 파일은 계속 받습니다.")
            }
            .navigationTitle(browser.title ?? "웹 탐색")
    }

    private func closeTab(_ id: UUID) {
        let target = (tab: id, closesTab: true)
        if tabs.tabs.first(where: { $0.id == id })?.capture.isOn == true { closing = target } else { finishClose(target) }
    }

    private func finishClose(_ target: (tab: UUID, closesTab: Bool)) {
        if target.closesTab {
            tabs.close(target.tab)
        } else {
            tabs.tabs.first { $0.id == target.tab }?.browser.close()
        }
    }

    /// 내비 옆 탭 단추 (2026-11-08, 사용자): [새 탭] · 열린 탭 목록(눌러 오가기, 받는 중이면 ● 표시) · [이 탭 닫기]
    private var tabMenu: some View {
        Menu {
            Button("새 탭", systemImage: "plus") { tabs.add() }
            Divider()
            Picker("탭", selection: $tabs.currentID) {
                ForEach(tabs.tabs) { tab in
                    // 바뀜 (2026-11-15, 사용자): 제목이 아주 긴 사이트가 있어 메뉴가 화면을 가로지른다 — 40자에서 자르고 … (메뉴 항목은 줄임 표시가 안 된다)
                    let title = tab.title.count > 40 ? tab.title.prefix(40).trimmingCharacters(in: .whitespaces) + "…" : tab.title
                    Text(tab.capture.isOn ? "● \(title)" : title).tag(tab.id)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
            Divider()
            // 바뀜 (2026-11-08): 탭이 하나여도 켜 둔다 — 그때는 사이트만 닫아 빈 탭이 된다 (주소칸의 ✕ 를 뺐으므로)
            Button("이 탭 닫기", systemImage: "xmark") { closeTab(tabs.currentID) }
                .disabled(tabs.tabs.count < 2 && browser.url == nil)
        } label: {
            Label("탭", systemImage: "square.on.square")
                .labelStyle(.iconOnly)
        }
        .help(tabs.tabs.count > 1 ? "탭 \(tabs.tabs.count)개 (새 탭·탭 오가기)" : "탭 (새 탭·탭 오가기)")
    }

    /// 주소칸 왼쪽 단추: 페이지가 없으면 즐겨찾기 목록, 있으면 추가(☆)·빼기(★)
    private var leadingSaved: Bool { bookmarks.bookmark(for: browser.url) != nil }
    private var leadingTitle: String {
        browser.url == nil ? "즐겨찾기 목록" : (leadingSaved ? "즐겨찾기에서 빼기" : "즐겨찾기에 추가")
    }
    private var leadingSymbol: String {
        browser.url == nil ? "book" : (leadingSaved ? "star.fill" : "star")
    }

    private func leadingAction() {
        guard let url = browser.url else {
            showsBookmarks.toggle()
            return
        }
        if let saved = bookmarks.bookmark(for: url) {
            bookmarks.remove(saved.id)
        } else {
            bookmarks.add(title: browser.title ?? "", url: url)
        }
    }

    /// 보이지 않는 단추로 단축키만 (웹 탐색 화면에 있을 때)
    private var zoomShortcuts: some View {
        Group {
            Button("크게") { tabs.stepZoom(1) }.keyboardShortcut("+", modifiers: .command)
            Button("크게") { tabs.stepZoom(1) }.keyboardShortcut("=", modifiers: .command)
            Button("작게") { tabs.stepZoom(-1) }.keyboardShortcut("-", modifiers: .command)
            Button("기본 크기") { tabs.zoom = WebBrowser.defaultZoom }.keyboardShortcut("0", modifiers: .command)
            Button("새 탭") { tabs.add() }.keyboardShortcut("t", modifiers: .command)
        }
        .opacity(0)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    static func percent(_ value: Double) -> String {
        "\(Int((value * 100).rounded()))%"
    }
}

/// 도구 막대 즐겨찾기 목록 (누르면 이동). 이름 바꾸기·지우기·순서는 설정 패널에서
private struct BookmarkList: View {
    @State private var bookmarks = WebBookmarks.shared
    let onOpen: (String) -> Void

    var body: some View {
        Group {
            if bookmarks.items.isEmpty {
                ContentUnavailableView("즐겨찾기 없음", systemImage: "star",
                                       description: Text("도구 막대의 ☆ 로 지금 사이트를 추가하세요."))
                    .frame(width: 280, height: 180)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(bookmarks.items) { item in
                            BookmarkListRow(item: item) { onOpen(item.url) }
                        }
                    }
                    .padding(.vertical, 6)
                }
                .frame(width: 300)
                .frame(maxHeight: 420)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// 즐겨찾기 목록 한 줄. 바뀜 (2026-11-10, 사용자): 마우스를 올리면 둥근 바탕이 깔린다 (어느 줄을 누를지 보이게)
private struct BookmarkListRow: View {
    let item: WebBookmarks.Bookmark
    let onOpen: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: onOpen) {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title).lineLimit(1)
                Text(URL(string: item.url)?.host() ?? item.url)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(.primary.opacity(hovering ? 0.08 : 0), in: .rect(cornerRadius: 6))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 6)
        .onHover { hovering = $0 }
        .help(item.url)
    }
}

/// 웹 탐색 설정 패널 (감지 패널과 같은 자리): 저장 위치, 보기 비율, 소리, 받기 속도, 즐겨찾기 관리
private struct WebSettingsPanel: View {
    @State private var settings = WebDownloadSettings.shared
    @State private var tabs = WebTabs.shared
    @State private var bookmarks = WebBookmarks.shared
    @State private var remoteEnabled = MacRemoteHost.isEnabled
    @State private var adBlock = AdBlock.shared
    @State private var editingAdBlock = false

    /// 아이콘 단추: − 처럼 얇은 그림도 단추 크기가 같게
    private func zoomButton(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .frame(width: 16, height: 16)
        }
        .accessibilityLabel(title)
        .help(title)
    }

    var body: some View {
        Form {
            Section("받기") {
                LabeledContent("저장 위치") {
                    HStack(spacing: 8) {
                        Text(settings.displayPath)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(settings.folder.path)
                        Button("변경…") { settings.chooseFolder() }
                    }
                }
                // 바뀜 (2026-11-07): 재생하며 받기 속도는 재생하며 받기 칸에서 바로 바꾼다 (사용자)
            }
            Section {
                // 자막 싱크처럼 − 값 + (10% 씩, 사용자 2026-11-07. 되돌리기 단추는 뺌 — ⌘0 은 남김)
                LabeledContent("보기 비율") {
                    HStack(spacing: 6) {
                        zoomButton("작게", systemImage: "minus") { tabs.stepZoom(-1) }
                            .disabled(tabs.zoom <= WebBrowser.zoomRange.lowerBound + 0.001)
                        Text(WebBrowserView.percent(tabs.zoom))
                            .monospacedDigit()
                            .frame(minWidth: 44)
                        zoomButton("크게", systemImage: "plus") { tabs.stepZoom(1) }
                            .disabled(tabs.zoom >= WebBrowser.zoomRange.upperBound - 0.001)
                    }
                    .buttonStyle(.bordered)
                }
                .help("⌘+ 크게, ⌘- 작게, ⌘0 80%")
                // 바뀜 (2026-11-08): 소리 끄기는 주소칸 옆 단추로 옮김 (탭마다)
            } header: {
                Text("보기")
            } footer: {
                Text("소리는 탭마다 꺼진 채로 시작합니다. 주소칸 옆 단추로 켭니다.")
                    .foregroundStyle(.secondary)
            }
            Section {
                if bookmarks.items.isEmpty {
                    Text("없음").foregroundStyle(.secondary)
                } else {
                    ForEach(bookmarks.items) { item in
                        BookmarkRow(item: item)
                    }
                    .onMove { bookmarks.move(from: $0, to: $1) }
                }
            } header: {
                Text("즐겨찾기")
            } footer: {
                Text("이름을 고치고 Return. 끌어서 순서를 바꿉니다. iCloud 로 다른 기기와 같이 씁니다.")
                    .foregroundStyle(.secondary)
            }
            // 광고 차단 (2026-11-12, 사용자): 규칙은 시트에서 고친다 (패널은 좁다). iCloud 로 아이폰·아이패드와 같이 쓴다
            Section {
                Toggle("광고 차단", isOn: Binding(get: { adBlock.enabled }, set: { adBlock.update(enabled: $0) }))
                // 바뀜 (2026-11-12, 사용자)
                Toggle("팝업 막기", isOn: Binding(get: { adBlock.fakePopups }, set: { adBlock.update(fakePopups: $0) }))
                    .help("스크립트가 연 팝업은 열지 않고, 페이지에는 열린 것처럼 가짜 창을 돌려줍니다")
                Toggle("누르지 않은 이동은 묻기", isOn: Binding(get: { adBlock.confirmNavigation }, set: { adBlock.update(confirmNavigation: $0) }))
                    .help("누르지 않았는데 페이지가 다른 곳으로 가려 하면 묻습니다. 폰에서 원격으로 연 탭은 묻지 않습니다")
                LabeledContent(adBlock.error != nil ? "규칙에 문제 있음" : "규칙 \(adBlock.compiledCount)개") {
                    Button("규칙 편집…") { editingAdBlock = true }
                }
            }
            .sheet(isPresented: $editingAdBlock) {
                NavigationStack {
                    AdBlockSettings()
                        .toolbar {
                            ToolbarItem(placement: .confirmationAction) { Button("완료") { editingAdBlock = false } }
                        }
                }
                .frame(minWidth: 560, idealWidth: 620, minHeight: 560, idealHeight: 680)
            }
            // 원격 제어 (2026-11-10, 사용자): 아이폰·아이패드 웹 탐색에서 이 맥에 페이지를 보내고 탭을 보고 닫을지
            Section {
                Toggle("원격 제어", isOn: $remoteEnabled)
                    .onChange(of: remoteEnabled) { MacRemoteHost.shared.setEnabled(remoteEnabled) }
            } footer: {
                Text("켜면 아이폰·아이패드 웹 탐색에서 이 맥으로 페이지를 보내 받고, 열린 탭을 보고 닫을 수 있습니다.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

private struct BookmarkRow: View {
    let item: WebBookmarks.Bookmark
    @State private var title = ""

    var body: some View {
        HStack(spacing: 6) {
            TextField("이름", text: $title)
                .labelsHidden()
                .onSubmit { WebBookmarks.shared.rename(item.id, to: title) }
                .help(item.url)
            Button("지우기", systemImage: "trash", role: .destructive) { WebBookmarks.shared.remove(item.id) }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .help("즐겨찾기에서 지우기")
        }
        .onAppear { title = item.title }
        .onChange(of: item.title) { title = item.title }
    }
}

/// 감지된 영상 패널 (라이브러리 설정 패널과 같은 자리·모양): 위에 재생하며 받기(고정), 아래에 감지된 영상(스크롤).
/// 바뀜 (2026-11-07): 저장 위치·받기 속도는 설정 패널로 옮겼다
private struct DetectedPanel: View {
    @State private var tabs = WebTabs.shared
    private var browser: WebBrowser { tabs.current.browser }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                // 바뀜 (2026-11-08): 지금 탭의 재생하며 받기 (탭을 바꾸면 새로 그린다)
                CaptureSection(capture: tabs.current.capture)
                    .id(tabs.currentID)
            }
            .formStyle(.grouped)
            .scrollDisabled(true)
            .fixedSize(horizontal: false, vertical: true)
            Divider()
            ScrollView {
                if browser.detected.isEmpty {
                    ContentUnavailableView("감지된 영상 없음", systemImage: "film.stack",
                                           description: Text(browser.watchesRequests ? "페이지에서 영상을 재생하면 여기에 나타납니다."
                                                             : "이 macOS 에서는 요청 감지를 쓸 수 없습니다."))
                        .padding(.top, 40)
                } else {
                    LazyVStack(spacing: 0) {
                        ForEach(browser.detected) { media in
                            DetectedRow(media: media)
                            Divider().padding(.leading, 14)
                        }
                    }
                }
            }
            .frame(maxHeight: .infinity)
        }
    }
}

/// 재생하며 받기 (받기 단추로 안 받아지는 비표준 플레이어용): 켜면 새로고침하고, 재생되는 그대로 모아 끝나면 저장
private struct CaptureSection: View {
    @Bindable var capture: WebCapture
    private var browser: WebBrowser { capture.browser }
    @State private var gapsOpen = false
    private static let gapRowHeight: CGFloat = 24

    /// 빈 구간 한 줄: [시작] ~ [끝]  [재시도]   [길이] — 칸마다 폭을 맞춰 열이 서게 (2026-11-09, 사용자: 한 글자로 이어 붙여 줄마다 어긋났다)
    /// 재시도는 채우러 가 본 구간만 "1/3" (다 가 보고 넘어간 구간에도 남긴다 — "3/3" 이면 거기는 안 되는 곳, 사용자)
    private func gapRow(_ gap: ClosedRange<Double>, widest: String) -> some View {
        let tries = capture.attempts(at: gap)
        let limit = capture.attemptLimit
        return HStack(spacing: 6) {
            Self.column(gap.lowerBound.durationText, like: widest)
            Text("~").foregroundStyle(.secondary)
            Self.column(gap.upperBound.durationText, like: widest)
            Self.column(tries > 0 ? "\(min(tries, limit))/\(limit)" : "", like: "\(limit)/\(limit)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .help(tries > 0 ? "채우러 가 본 횟수 \(min(tries, limit))번 (최대 \(limit)번)" : "")
            Spacer(minLength: 8)
            Text((gap.upperBound - gap.lowerBound).durationText)
                .foregroundStyle(.secondary)
        }
        .monospacedDigit()
    }

    /// 가장 긴 글자만큼 폭을 잡고 오른쪽 맞춤 (자릿수가 달라도 열이 선다)
    private static func column(_ text: String, like widest: String) -> some View {
        ZStack(alignment: .trailing) {
            Text(widest).hidden()
            Text(text)
        }
    }

    /// "12개", 채우는 중이면 "12개 · 14:23 채우는 중" (채우러 간 구간의 시작, 2026-11-09 사용자)
    private func gapsText(_ holes: [ClosedRange<Double>]) -> String {
        let count = "\(holes.count)개"
        // 바뀜 (2026-11-09, 사용자): 저장한 뒤에는 "채우는 중" 을 빼고 개수만
        guard capture.isOn, capture.fillingGaps else { return count }
        guard let target = capture.fillTarget else { return "\(count) · 채우는 중" }
        return "\(count) · \(target.lowerBound.durationText) 채우는 중"
    }
    /// 펼친 빈 구간 목록에 한 번에 보이는 줄 수 (넘으면 스크롤)
    private static let visibleGapRows: CGFloat = 8

    /// 빈 구간 줄 (눌러서 펼치면 구간 목록) — 받는 중과 저장한 뒤에 같이 쓴다
    /// 바뀜 (2026-11-09, 사용자): 빈 구간을 남기고 저장했으면 저장한 뒤에도 그대로 보인다
    @ViewBuilder
    private func gapsRows(_ holes: [ClosedRange<Double>]) -> some View {
        if !holes.isEmpty {
            // 바뀜 (2026-11-08): 화살표만이 아니라 "빈 구간" 줄 전체를 눌러 펼친다 (사용자)
            // 바뀜 (2026-11-09, 사용자): 왼쪽 › 대신 오른쪽 개수 옆 ⌄ (다른 줄의 값·화살표와 같은 자리), 펼친 목록은 높이를 정해 그 안에서 스크롤
            //   (빈 구간이 많으면 패널 전체를 차지했다)
            Button {
                withAnimation { gapsOpen.toggle() }
            } label: {
                LabeledContent("빈 구간") {
                    HStack(spacing: 3) {
                        Text(gapsText(holes))
                        Image(systemName: "chevron.down")
                            .font(.caption2.weight(.semibold))
                            .rotationEffect(.degrees(gapsOpen ? 180 : 0))
                    }
                    .foregroundStyle(.secondary)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            if gapsOpen {
                ScrollView {
                    VStack(spacing: 0) {
                        let widest = holes.map(\.upperBound).max()?.durationText ?? ""
                        ForEach(holes, id: \.lowerBound) { gap in
                            let row = gapRow(gap, widest: widest)
                                .frame(height: Self.gapRowHeight)
                                .contentShape(.rect)
                            // 저장한 뒤에는 옮길 플레이어가 없어 보기만
                            if capture.isOn {
                                Button { capture.show(gap) } label: { row }
                                    .buttonStyle(.plain)
                                    .help("이 구간 앞으로 이동합니다")
                            } else {
                                row
                            }
                        }
                    }
                }
                .frame(height: min(CGFloat(holes.count), Self.visibleGapRows) * Self.gapRowHeight)
            }
        }
    }

    var body: some View {
        Section {
            switch capture.state {
            case .off:
                Button("재생하며 받기 시작", systemImage: "record.circle") { capture.start() }
                    .disabled(browser.url == nil)
                    .help("받기 단추로 안 받아지는 영상용: 지금 자리부터 재생되는 그대로 모으고, 앞부분은 끝까지 받은 뒤 채워 저장합니다")
            case .waiting:
                Label("페이지에서 영상을 재생하세요", systemImage: "play.circle")
                    .foregroundStyle(.secondary)
                Button("취소", role: .cancel) { capture.stop(save: false) }
            case .capturing:
                // 바뀜 (2026-11-07, 사용자): 현재·전체를 한 줄로, "받아 둔 곳"(플레이어 버퍼의 끝)은 뺌,
                //   빈 구간은 펼쳐 보고 눌러서 그 자리로, 받기 속도는 여기서 바로 바꾼다(설정 패널에서 뺌), 같은 종류 트랙은 합쳐서
                if let playback = capture.playback {
                    LabeledContent("현재", value: "\(playback.time.durationText) / \(playback.duration?.durationText ?? "-")")
                        .monospacedDigit()
                }
                // 바뀜 (2026-11-07): "받은 곳"(끊김 없이 받은 데까지)도 뺌 — 빈 구간 목록으로 보고, 채우기는 앱이 하거나 목록을 눌러 옮긴다 (사용자)
                gapsRows(capture.holes)
                // 바뀜 (2026-11-07): 다른 값처럼 오른쪽 끝 글자 + 작은 화살표 (버튼 모양이라 줄이 안 맞아 보였다, 사용자)
                LabeledContent("받기 속도") {
                    Menu {
                        Picker("받기 속도", selection: $capture.speed) {
                            ForEach(WebCapture.speeds, id: \.self) { speed in
                                Text(speed == 1 ? "1배 (재생대로)" : "\(speed.formatted())배").tag(speed)
                            }
                        }
                        .pickerStyle(.inline)
                        .labelsHidden()
                    } label: {
                        HStack(spacing: 3) {
                            Text(capture.speed == 1 ? "1배 (재생대로)" : "\(capture.speed.formatted())배")
                            Image(systemName: "chevron.up.chevron.down").font(.caption2.weight(.semibold))
                        }
                        .foregroundStyle(.secondary)
                    }
                    .menuStyle(.button)
                    .buttonStyle(.plain)
                    .fixedSize()
                }
                .help("재생 시간보다 몇 배 빨리 미리 받을지 (화면 재생 속도는 그대로). 너무 높이면 사이트가 막거나 화질이 낮아질 수 있습니다.")
                // 바뀜 (2026-11-08): 로딩이 멈추면 몇 초 뒤 건너뛸지 (사용자)
                // 바뀜 (2026-11-09, 사용자): 이름 "로딩 멈춤 감지" → "재생 오류 대기", 아래에 자동 새로고침 켜고 끄기
                LabeledContent("재생 오류 대기") {
                    Menu {
                        Picker("재생 오류 대기", selection: $capture.stallLimit) {
                            ForEach(WebCapture.stallLimits, id: \.self) { limit in
                                Text(limit == 0 ? "사용 안 함" : "\(limit)초").tag(limit)
                            }
                        }
                        .pickerStyle(.inline)
                        .labelsHidden()
                    } label: {
                        HStack(spacing: 3) {
                            Text(capture.stallLimit == 0 ? "사용 안 함" : "\(capture.stallLimit)초")
                            Image(systemName: "chevron.up.chevron.down").font(.caption2.weight(.semibold))
                        }
                        .foregroundStyle(.secondary)
                    }
                    .menuStyle(.button)
                    .buttonStyle(.plain)
                    .fixedSize()
                }
                .help("재생 중인데 이 시간 넘게 화면이 멈춰 있으면(로딩이 안 끝남) 5초 건너뛰어 계속 받습니다. 건너뛴 곳은 끝까지 받은 뒤 다시 가 봅니다.")
                Toggle("재생 오류 시 자동 새로고침", isOn: $capture.autoReload)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .help("건너뛰어도 곧 또 멈추기를 3번 하면 페이지를 새로고침해 받은 끝부터 이어 받습니다 (3분에 한 번까지). 끝까지 받은 뒤 빈 구간이 안 채워지면 저장하기 전에 한 번 새로고침하고 다시 가 봅니다.")
                // 바뀜 (2026-11-08, 사용자): 영상·소리를 한 줄로 "영상/소리  1.0 GB / 100 MB" (소리가 따로 없으면 영상만)
                if !capture.tracks.isEmpty {
                    let sizes = [true, false].compactMap { video -> String? in
                        let same = capture.tracks.filter { $0.isVideo == video }
                        return same.isEmpty ? nil : ByteCountFormatter.string(fromByteCount: same.map(\.bytes).reduce(0, +), countStyle: .file)
                    }
                    let kinds = [true, false].filter { video in capture.tracks.contains { $0.isVideo == video } }
                    LabeledContent(kinds.map { $0 ? "영상" : "소리" }.joined(separator: "/")) {
                        Text(sizes.joined(separator: " / "))
                            .monospacedDigit()
                    }
                    .help("받은 양 (앞뒤로 오가 다시 받은 것도 포함, 저장할 때 겹친 것은 뺍니다)")
                }
                // 바뀜 (2026-11-08, 사용자): 맨 아래 경과 시간 — 실제로 받기 시작한(첫 조각이 들어온) 뒤 흐른 시간
                if let receivedSince = capture.receivedSince {
                    TimelineView(.periodic(from: receivedSince, by: 1)) { context in
                        LabeledContent("경과 시간", value: max(0, context.date.timeIntervalSince(receivedSince)).durationText)
                            .monospacedDigit()
                    }
                }
                HStack {
                    Button("여기까지 저장") { capture.stop(save: true) }
                        .help("재생한 데까지만 저장합니다 (끝까지 재생하면 저절로 저장됩니다)")
                        .buttonStyle(.borderedProminent)
                    Button("취소", role: .cancel) { capture.stop(save: false) }
                }
            case .saving:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("영상 묶는 중")
                }
            case .saved(let files):
                Label(files.count == 1 ? "저장했습니다" : "\(files.count)개 저장했습니다", systemImage: "checkmark.circle")
                gapsRows(capture.savedHoles)
                HStack {
                    Button("Finder 에서 보기") { NSWorkspace.shared.activateFileViewerSelecting(files) }
                    Button("닫기") { capture.reset() }
                }
            case .failed(let message):
                Label(message, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
                Button("닫기") { capture.reset() }
            }
        } header: {
            Text("재생하며 받기")
        }
        // 바뀜 (2026-11-08, 사용자): 시작 단추 아래 긴 설명(footer)은 뺌 — 단추 도움말로
    }
}

/// 감지된 영상 한 줄: [종류] 파일 이름 / 크기·사이트 · 오른쪽 단추.
/// 받기 시작하면 줄 아래에 진행 막대와 "받은 양 / 전체 · 속도" 가 붙는다.
private struct DetectedRow: View {
    let media: WebMedia
    @State private var downloads = WebDownloads.shared

    var body: some View {
        let item = downloads.item(for: media)
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 10) {
                Text(media.kind.rawValue)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(.secondary.opacity(0.5)))
                VStack(alignment: .leading, spacing: 2) {
                    Text(item?.file.lastPathComponent ?? media.fileName)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .help(media.url.absoluteString)
                Spacer(minLength: 4)
                WebDownloadButton(media: media, item: item)
            }
            if let item, item.state != .done {
                WebDownloadProgress(item: item)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private var detail: String {
        var parts: [String] = []
        if let quality = media.quality { parts.append(quality) }
        if let size = media.size { parts.append(ByteCountFormatter.string(fromByteCount: size, countStyle: .file)) }
        if let unsupported = media.unsupported { parts.append(unsupported) }
        if media.needsCapture { parts.append("비표준 · 재생하며 받기") }
        if media.kind == .dash || media.kind == .mse, media.unsupported == nil { parts.append("재생하며 받기") }
        if let host = media.url.host() { parts.append(host) }

        return parts.joined(separator: " · ")
    }
}

/// 주소칸: 도구 막대의 맥 기본 검색 칸(NSSearchField). Return 을 누르면 연다.
/// 페이지가 바뀌면 지금 주소를 보여 주되, 고쳐 쓰는 중에는 건드리지 않는다.
/// 바뀜 (2026-11-07): 누르거나 포커스가 가면 주소 전체를 고른다 (사파리처럼), 옆 이동(→) 단추는 controller 로 보낸다.
/// 바뀜 (2026-11-07): 왼쪽 돋보기 자리에 즐겨찾기(페이지 없을 때)·닫기(페이지 열렸을 때) 단추를 둔다.
/// 바뀜 (2026-11-07): 왼쪽은 즐겨찾기 목록(페이지 없을 때)·추가/빼기(열렸을 때), 오른쪽 ✕ 는 사이트 닫기 (고쳐 쓰는 중이면 글만 지움).
/// 바뀜 (2026-11-07): 검색 칸 대신 그냥 글 칸(NSTextField)으로. 검색 칸 안의 돋보기·✕ 단추는 칸이 스스로 되돌려
///   그림·동작을 바꿀 수 없고 누름도 칸이 먹어서, 즐겨찾기·닫기는 도구 막대의 따로 된 단추로 뺐다 (사용자).
///   "고쳐 쓰는 중" 은 포커스가 아니라 실제로 글을 고쳤는지로 본다 (포커스만 있으면 페이지 주소로 바꾼다). Esc 는 페이지 주소로 되돌린다.
struct AddressField: NSViewRepresentable {
    let url: URL?
    let controller: AddressController
    let onSubmit: (String) -> Void

    func makeNSView(context: Context) -> NSTextField {
        let field = SelectAllTextField()
        field.placeholderString = "주소 또는 검색어"
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.usesSingleLineMode = true
        field.lineBreakMode = .byTruncatingTail
        field.cell?.isScrollable = true
        field.target = context.coordinator
        field.action = #selector(Coordinator.submit(_:))
        field.delegate = context.coordinator
        field.stringValue = url?.absoluteString ?? ""
        controller.field = field
        controller.onSubmit = { [weak coordinator = context.coordinator] in coordinator?.submit(field) }
        context.coordinator.field = field
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        let coordinator = context.coordinator
        coordinator.onSubmit = onSubmit
        if coordinator.url != url {
            coordinator.url = url
            coordinator.edited = false
        }
        if !coordinator.edited { coordinator.show(url?.absoluteString ?? "") }
    }

    func makeCoordinator() -> Coordinator { Coordinator(onSubmit: onSubmit) }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var onSubmit: (String) -> Void
        var url: URL?
        weak var field: NSTextField?
        /// 사용자가 글을 고쳤는지 (페이지가 바뀌거나 보내면 풀린다)
        var edited = false
        init(onSubmit: @escaping (String) -> Void) { self.onSubmit = onSubmit }

        func controlTextDidChange(_ notification: Notification) { edited = true }

        /// Esc: 고친 글을 버리고 페이지 주소로
        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            guard selector == #selector(NSResponder.cancelOperation(_:)) else { return false }
            edited = false
            show(url?.absoluteString ?? "")
            control.window?.makeFirstResponder(nil)
            return true
        }

        /// 칸에 글을 보인다 (포커스가 있어도)
        func show(_ text: String) {
            guard let field, field.stringValue != text else { return }
            if let editor = field.currentEditor() as? NSTextView {
                editor.string = text
                editor.selectAll(nil)
            }
            field.stringValue = text
        }

        @objc func submit(_ field: NSTextField) {
            guard !field.stringValue.isEmpty else { return }
            edited = false
            onSubmit(field.stringValue)
            field.window?.makeFirstResponder(nil)
        }
    }
}

/// 이동(→) 단추가 주소칸의 글을 보내게 잇는다
@MainActor
final class AddressController {
    weak var field: NSTextField?
    var onSubmit: (() -> Void)?

    func submit() { onSubmit?() }
}

/// 누르거나 Tab 으로 들어오면 글 전체를 고르는 글 칸
/// 바뀜 (2026-11-07): 검색 칸 → 글 칸
private final class SelectAllTextField: NSTextField {
    private var selectsOnMouseUp = false

    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        if became {
            selectsOnMouseUp = NSApp.currentEvent?.type == .leftMouseDown
            // 키보드로 들어온 때는 바로 (누른 때는 누르는 동안 커서가 놓이므로 뗀 뒤에)
            DispatchQueue.main.async { [weak self] in self?.currentEditor()?.selectAll(nil) }
        }
        return became
    }

    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        // 처음 누른 때만 전체를 고른다 (이미 고치는 중에 누르면 커서 두기)
        if selectsOnMouseUp {
            selectsOnMouseUp = false
            currentEditor()?.selectAll(nil)
        }
    }
}

/// 웹뷰를 창에 늘 깔아 둔다 (라이브러리 창 내용 영역 맨 아래). 웹 탐색 칸이 아니면 투명하게, 누를 수도 없게.
/// 창에서 떼어 내면 WebKit 이 숨은 페이지로 보고 영상을 멈춰(document.hidden) 재생하며 받기가 끊긴다 —
/// 투명하게 덮어 두면 보이는 페이지로 남아 다른 메뉴를 보는 동안에도 재생·받기가 이어진다 (창을 내리거나 앱을 가리면 멈춘다).
/// 바뀜 (2026-11-07): 웹 탐색의 오른쪽 패널이 열리면 그 폭만큼 좁힌다 (다른 화면의 패널처럼 덮으면 사이트 화면이 가려 매번 접었다 폈다 했다, 사용자)
/// 바뀜 (2026-11-08): 탭마다 웹뷰를 겹쳐 깐다. 지금 탭만 보이고 눌리며, 뒤 탭도 창에 남아 재생·받기가 이어진다
struct WebPageLayer: View {
    let visible: Bool
    @State private var tabs = WebTabs.shared

    var body: some View {
        ZStack {
            ForEach(tabs.tabs) { tab in
                let front = visible && tab.id == tabs.currentID
                WebViewHost(webView: tab.browser.webView)
                    .padding(.trailing, front && tabs.sidePanelOpen ? WebBrowser.sidePanelWidth : 0)
                    .opacity(front ? 1 : 0)
                    .allowsHitTesting(front)
                    .zIndex(front ? 1 : 0)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: tabs.sidePanelOpen)
    }
}

/// 앱에 하나뿐인 웹뷰를 SwiftUI 에 붙인다 (화면을 다시 그려도 웹뷰는 새로 만들지 않는다)
private struct WebViewHost: NSViewRepresentable {
    let webView: WKWebView

    func makeNSView(context: Context) -> WKWebView { webView }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}
