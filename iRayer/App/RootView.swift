import SwiftUI

/// 앱 최상위 탭 구조: [홈] [탐색] [둘러보기] [설정] [검색]
struct RootView: View {
    @State private var transfers = TransferCenter.shared
    @State private var locations = LocationStore.shared
    @State private var libraries = LibraryStore.shared
    @AppStorage("tabCustomization") private var tabCustomization = TabViewCustomization()
    private let isPad = UIDevice.current.userInterfaceIdiom == .pad
    /// 고른 탭 (사이드바의 위치도 탭 하나씩, 값은 사용자화 ID 와 같다)
    @State private var selectedTab = {
        #if DEBUG
        // 테스트용 실행 인자 `-startTab <home|browse|settings|search|…>` (시뮬레이터 탭이 가끔 안 먹어서)
        if let tab = UserDefaults.standard.string(forKey: "startTab") { return tab }
        #endif
        return "home"
    }()


    var body: some View {
        // 아이폰은 아래 탭 막대. 아이패드는 위쪽 탭 막대 ↔ 사이드바 (맥과 같은 사이드바: 라이브러리·둘러보기·폴더).
        // 사이드바 묶음은 아이폰 탭 막대에는 보이지 않는다 (아이폰은 [탐색]·[둘러보기] 탭에서 들어간다).
        // [탐색]·[둘러보기]는 사이드바에도 둔다: iPadOS 27 에서 사이드바에서 숨기면(.defaultVisibility(.hidden, for: .sidebar))
        // 위쪽 탭 막대에서도 사라져, 사이드바를 접으면 라이브러리·폴더로 갈 길이 없었다.
        TabView(selection: $selectedTab) {
            Tab("홈", systemImage: "house", value: "home") { HomeView() }
                .customizationID("home")
            Tab("탐색", systemImage: "books.vertical", value: "browse") { BrowseView() }
                .customizationID("browse")
            Tab("둘러보기", systemImage: "square.grid.2x2", value: "discover") { BrowseTabView() }
                .customizationID("discover")
            Tab("설정", systemImage: "gearshape", value: "settings") { SettingsView() }
                .customizationID("settings")
            Tab(value: "search", role: .search) { SearchView() }
                .customizationID("search")
            // 사이드바 묶음은 아이패드만 (아이폰은 탭이 5개를 넘으면 "더 보기" 로 밀린다)
            if isPad {
                if !libraries.libraries.isEmpty {
                    TabSection("라이브러리") {
                        ForEach(libraries.libraries) { library in
                            Tab(library.name, systemImage: library.symbol, value: "library.\(library.id)") {
                                LibraryItemsView(library: library).id(library.id)
                            }
                            .customizationID("library.\(library.id)")
                        }
                    }
                    .customizationID("libraries")
                    .defaultVisibility(.hidden, for: .tabBar)
                }
                TabSection("둘러보기") {
                    Tab("장르", systemImage: "books.vertical", value: "genres") { GenresView() }
                        .customizationID("genres")
                    Tab("컬렉션", systemImage: "square.stack.3d.up", value: "collections") { CollectionsBrowseView() }
                        .customizationID("collections")
                    Tab("인물", systemImage: "person.2", value: "people") { PeopleView() }
                        .customizationID("people")
                    Tab("재생목록", systemImage: "list.bullet.rectangle", value: "playlists") { PlaylistsView() }
                        .customizationID("playlists")
                }
                .customizationID("browseSection")
                .defaultVisibility(.hidden, for: .tabBar)
                // 폴더: 매칭하지 않고 그냥 보는 곳. 추가·빼기는 설정 → 라이브러리.
                TabSection("폴더") {
                    if locations.showsThisDevice {
                        Tab(LocationStore.thisDeviceName, systemImage: LocationStore.thisDeviceIcon, value: "device") {
                            SidebarLocationView(location: .thisDevice)
                        }
                        .customizationID("device")
                    }
                    ForEach(locations.shownFolders) { folder in
                        Tab(folder.name, systemImage: folder.symbol, value: "folder.\(folder.id)") {
                            SidebarLocationView(location: .folder(folder.id))
                        }
                        .customizationID("folder.\(folder.id)")
                    }
                    ForEach(locations.servers) { server in
                        ForEach(locations.shownFavorites(of: server.id)) { favorite in
                            Tab(favorite.name, systemImage: favorite.symbol, value: "favorite.\(favorite.id)") {
                                SidebarLocationView(location: .favorite(favorite.id))
                            }
                            .customizationID("favorite.\(favorite.id)")
                        }
                    }
                }
                .customizationID("devices")
                .defaultVisibility(.hidden, for: .tabBar)
                // 맥에서 받는 현황 (2026-11-09, 사용자)
                TabSection("웹") {
                    Tab("웹 탐색", systemImage: "globe", value: "web") {
                        NavigationStack { PhoneWebView() }
                    }
                    .customizationID("webBrowse")
                    Tab("다운로드", systemImage: "arrow.down.circle", value: "downloads") {
                        NavigationStack { MacDownloadsView() }
                    }
                    .customizationID("downloads")
                }
                .customizationID("web")
                .defaultVisibility(.hidden, for: .tabBar)
            }
        }
        .tabViewStyle(.sidebarAdaptable)
        // AirPlay 를 접어 두면 탭 막대 위에 작은 재생 막대 (2026-11-11, 사용자)
        .modifier(AirPlayAccessory())
        // 사이드바 묶음을 탭 막대에서 숨기려면 탭 사용자화가 켜져 있어야 한다
        .tabViewCustomization($tabCustomization)
        // 파일 복사·압축 풀기 진행 표시 (작업이 있을 때만)
        // 파일 작업 진행 표시: 탭 막대 위에 떠 있다
        .overlay(alignment: .bottom) {
            if transfers.showsBanner {
                TransferBanner()
                    .padding(.bottom, 64)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.25), value: transfers.showsBanner)
        // 작업 목록은 진행 표시가 사라져도 닫히지 않게 맨 위에서 띄운다
        .sheet(isPresented: Binding(get: { transfers.showsList }, set: { transfers.showsList = $0 }),
               onDismiss: { transfers.acknowledge() }) {
            NavigationStack { TransferListView() }
        }
        .modifier(ComicLauncherPresentations())
        .modifier(TextLauncherPresentations())
        .task {
            AppSettings.shared.applyAppearance()
        }
        // Apple TV 구입작을 넣는 라이브러리가 있으면 구입 목록의 포스터를 받아 둔다
        .task(id: libraries.libraries.contains(where: \.appleTV)) {
            if libraries.libraries.contains(where: \.appleTV) { await AppleTVLibrary.shared.load() }
        }
        // iCloud 로 받은 라이브러리는 이 기기에서 한 번도 훑지 않았으니 바로 훑는다 (작품 정보는 기기마다 받는다)
        .task(id: libraries.libraries.map(\.id)) {
            for library in libraries.libraries where library.scannedAt == nil {
                LibraryScanner.shared.scan(library)
            }
            // 관람등급을 받기 전에 저장한 작품의 등급을 채운다 (성인 등급 숨기기)
            LibraryScanner.shared.fillRatings()
        }
        #if DEBUG
        .sheet(item: $debugInfo) { file in
            NavigationStack { VideoInfoView(file: file) }
        }
        .fullScreenCover(item: $debugFolder) { route in
            NavigationStack { FolderView(route: route).locationDestinations() }
                .modifier(ComicLauncherPresentations())
        .modifier(TextLauncherPresentations())
        }
        .onAppear(perform: startDebugAutoplay)
        #endif
    }

    #if DEBUG
    @State private var debugInfo: VideoFile?
    @State private var debugFolder: FolderRoute?

    /// 테스트용 실행 인자
    /// - `-debugServers "이름|주소|아이디|비밀번호;…"`: 서버를 미리 등록 (주소가 smb:// 로 시작하면 SMB) (시뮬레이터에서 입력란에 글자를 넣을 수 없어서)
    /// - `-autoplay <문서 폴더 안 파일명>`: 바로 플레이어를 연다
    /// - `-infoFile <문서 폴더 안 파일명>`: 바로 영상 정보 화면을 연다
    /// - `-debugFolder "<서버 이름>/<경로>"`: 바로 그 폴더 화면을 연다 (서버 이름 대신 "이 기기")
    private func startDebugAutoplay() {
        if let servers = UserDefaults.standard.string(forKey: "debugServers") {
            let store = LocationStore.shared
            for entry in servers.split(separator: ";") {
                let fields = entry.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
                guard fields.count == 4, !store.servers.contains(where: { $0.name == fields[0] }) else { continue }
                store.saveServer(
                    NetworkServer(kind: fields[1].hasPrefix("smb://") ? .smb : .webdav, name: fields[0], address: fields[1], username: fields[2]),
                    password: fields[3]
                )
            }
        }

        let defaults = UserDefaults.standard
        if let path = defaults.string(forKey: "debugFolder") {
            let parts = path.split(separator: "/").map(String.init)
            let store = LocationStore.shared
            let server = store.servers.first { $0.name == parts.first }
            if let root = server?.rootURL ?? (parts.first == "이 기기" ? store.documentsURL : nil) {
                let url = parts.dropFirst().reduce(root) { $0.appending(path: $1, directoryHint: .isDirectory) }
                debugFolder = FolderRoute(url: url, title: parts.last ?? "", serverID: server?.id)
            }
        }
        guard let name = defaults.string(forKey: "autoplay") ?? defaults.string(forKey: "infoFile") else { return }
        let url = URL.documentsDirectory.appending(path: name)
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let siblings = (try? FileManager.default.contentsOfDirectory(at: URL.documentsDirectory, includingPropertiesForKeys: nil)) ?? []
        let file = VideoFile(
            url: url,
            size: Int64(values?.fileSize ?? 0),
            modifiedAt: values?.contentModificationDate ?? .distantPast,
            subtitles: SubtitleLoader.sidecars(for: url, in: siblings)
        )
        if defaults.string(forKey: "autoplay") != nil { PlayerHost.shared.play(file, resume: true) } else { debugInfo = file }
    }
    #endif
}

#if DEBUG
extension FolderRoute: Identifiable {
    var id: URL { url }
}
#endif

/// AirPlay 를 접어 두었을 때만 탭 막대 위 자리(iOS 26 tabViewBottomAccessory)에 작은 재생 막대를 띄우고,
/// 그동안 다른 영상을 누르면 TV 영상을 바꿀지 묻는다
private struct AirPlayAccessory: ViewModifier {
    @State private var host = PlayerHost.shared

    func body(content: Content) -> some View {
        accessory(content)
            .alert("TV 에서 이 영상으로 바꿀까요?", isPresented: Binding(
                get: { host.pendingPlay != nil },
                set: { if !$0 { host.pendingPlay = nil } }
            )) {
                Button("바꾸기") { host.confirmPendingPlay() }
                Button("취소", role: .cancel) { host.pendingPlay = nil }
            } message: {
                Text("‘\(host.airPlay?.title ?? "")’ 대신 ‘\(host.pendingPlay?.file.title ?? "")’을(를) TV 로 보냅니다.")
            }
    }

    @ViewBuilder
    private func accessory(_ content: Content) -> some View {
        let session = host.airPlayCollapsed ? host.airPlay : nil
        if #available(iOS 26.1, *) {
            content.tabViewBottomAccessory(isEnabled: session != nil) {
                if let session { AirPlayMiniBar(session: session) }
            }
        } else if let session {
            content.tabViewBottomAccessory { AirPlayMiniBar(session: session) }
        } else {
            content
        }
    }
}
