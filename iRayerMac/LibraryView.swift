import SwiftUI

/// 라이브러리 창: 왼쪽 사이드바 + 오른쪽 내용 (Finder·음악 앱처럼). 창 제목 글자는 쓰지 않는다.
/// 사이드바에 라이브러리·둘러보기·이 Mac·폴더를 바로 둔다.
struct LibraryView: View {
    enum Item: Hashable {
        case home, search
        case genres, browseCollections, people, playlists
        case library(String)
        case location(SidebarLocation)
        case web, downloads
    }

    @State private var selection: Item? = .home
    @State private var libraries = LibraryStore.shared
    @State private var editingLibrary: LibraryRecord?
    @State private var removingLibrary: LibraryRecord?
    @State private var locations = LocationStore.shared
    @State private var transfers = TransferCenter.shared
    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Label("검색", systemImage: "magnifyingglass").tag(Item.search)
                Label("홈", systemImage: "house").tag(Item.home)
                if !libraries.libraries.isEmpty {
                    Section("라이브러리") {
                        ForEach(libraries.libraries) { library in
                            Label(library.name, systemImage: library.symbol)
                                .tag(Item.library(library.id))
                                .contextMenu {
                                    Button("다시 훑기") { LibraryScanner.shared.scan(library) }
                                    Button("라이브러리 설정…") { editingLibrary = library }
                                    Divider()
                                    Button("라이브러리 빼기…", role: .destructive) { removingLibrary = library }
                                }
                        }
                        .onMove { libraries.move(from: $0, to: $1) }
                    }
                }
                Section("둘러보기") {
                    Label("장르", systemImage: "books.vertical").tag(Item.genres)
                    Label("컬렉션", systemImage: "square.stack.3d.up").tag(Item.browseCollections)
                    Label("인물", systemImage: "person.2").tag(Item.people)
                    Label("재생목록", systemImage: "list.bullet.rectangle").tag(Item.playlists)
                }
                // 폴더: 매칭하지 않고 그냥 보는 곳 (이 Mac 폴더, 저장소 안의 폴더). 추가·빼기는 설정 → 라이브러리.
                Section("폴더") {
                    if locations.showsThisDevice {
                        Label(LocationStore.thisDeviceName, systemImage: LocationStore.thisDeviceIcon).tag(Item.location(.thisDevice))
                    }
                    ForEach(locations.shownFolders) { folder in
                        Label(folder.name, systemImage: folder.symbol).tag(Item.location(.folder(folder.id)))
                    }
                    ForEach(locations.servers) { server in
                        ForEach(locations.shownFavorites(of: server.id)) { favorite in
                            Label(favorite.name, systemImage: favorite.symbol)
                                .tag(Item.location(.favorite(favorite.id)))
                                .help("\(server.name)/\(favorite.path(in: server))")
                        }
                    }
                }
                // 웹: 웹 페이지를 보며 영상을 찾아 받는 곳 (2.1)
                Section("웹") {
                    Label("웹 탐색", systemImage: "globe").tag(Item.web)
                    // 바뀜 (2026-11-08, 사용자): 받는 중인 개수 배지 (오른쪽). badge 를 tag 뒤에 붙이면 줄이 tag 를 잃어 눌러도 안 골라졌다 → badge 먼저
                    Label("다운로드", systemImage: "arrow.down.circle")
                        .badge(WebTabs.shared.activeDownloads)
                        .tag(Item.downloads)
                }
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 210, max: 300)
        } detail: {
            ZStack {
                // 웹 탐색의 웹뷰는 다른 칸을 보는 동안에도 창에 남겨 둔다 (재생하며 받기가 끊기지 않게)
                WebPageLayer(visible: selection == .web)
                detail
                    .id(selection)
            }
        }
        .toolbar(removing: .title)
        // 도구 막대의 ··· 메뉴에 아래 화살표를 붙이지 않는다 (다른 맥 앱처럼)
        .menuIndicator(.hidden)
        // 카드마다 파란 키보드 초점 테두리가 늘 떠 있지 않게 (마우스로 쓰는 화면)
        .focusEffectDisabled()
        .overlay(alignment: .bottom) {
            if transfers.showsBanner {
                TransferBanner()
                    .padding(.bottom, 16)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.25), value: transfers.showsBanner)
        // 관람등급을 받기 전에 저장한 작품의 등급을 채운다 (성인 등급 숨기기)
        .task { LibraryScanner.shared.fillRatings() }
        // Apple TV 구입작을 넣는 라이브러리가 있으면 미디어 보관함에서 구입 목록을 읽는다 (바뀌었으면 그 라이브러리를 다시 훑는다)
        .task(id: libraries.libraries.contains(where: \.appleTV)) {
            if libraries.libraries.contains(where: \.appleTV) { await AppleTVLibrary.shared.load() }
        }
        .sheet(isPresented: Binding(get: { transfers.showsList }, set: { transfers.showsList = $0 }),
               onDismiss: { transfers.acknowledge() }) {
            NavigationStack { TransferListView() }
                .frame(minWidth: 480, minHeight: 360)
        }
        .modifier(ComicLauncherPresentations())
        .modifier(TextLauncherPresentations())
        .sheet(item: $editingLibrary) { LibraryAddView(library: $0) }
        .alert("‘\(removingLibrary?.name ?? "")’ 라이브러리를 뺄까요?", isPresented: Binding(
            get: { removingLibrary != nil },
            set: { if !$0 { removingLibrary = nil } }
        ), presenting: removingLibrary) { library in
            Button("취소", role: .cancel) {}
            Button("빼기", role: .destructive) {
                if selection == .library(library.id) { selection = .location(.thisDevice) }
                libraries.remove(library)
            }
        } message: { _ in
            Text("받아 둔 작품 정보만 지웁니다. 저장소 안의 영상은 그대로입니다.")
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch selection ?? .search {
        case .home: HomeView()
        case .search: SearchView()
        case .genres: GenresView()
        case .browseCollections: CollectionsBrowseView()
        case .people: PeopleView()
        case .playlists: PlaylistsView()
        case .library(let id):
            if let library = libraries.library(id) {
                LibraryItemsView(library: library).id(library.id)
            }
        case .location(let location): SidebarLocationView(location: location)
        case .web: WebBrowserView()
        case .downloads: WebDownloadsView()
        }
    }
}
