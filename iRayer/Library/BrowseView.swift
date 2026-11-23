import SwiftUI

/// 폴더 화면으로 이동할 때 쓰는 경로
struct FolderRoute: Hashable {
    let url: URL
    let title: String
    /// 네트워크 서버 안이면 그 서버 (접속 정보를 찾는 데 쓴다)
    var serverID: UUID?
    /// 탐색 목록에 등록된 위치의 최상위면 그 위치 (··· 메뉴로 수정·삭제)
    var location: LocationID?
}

extension View {
    /// 폴더·영상 정보 화면으로 이동할 수 있게 한다 (탐색·홈·검색 탭에서 같이 쓴다)
    func locationDestinations() -> some View {
        modifier(LocationDestinations())
    }
}

private struct LocationDestinations: ViewModifier {
    /// 쌓인 화면은 스택 둘레의 환경값을 못 받으므로 (맥) 여기서 읽어 넘겨준다
    @Environment(\.openAncestor) private var openAncestor
    @Environment(\.stackHistory) private var history

    func body(content: Content) -> some View {
        content
            .navigationDestination(for: FolderRoute.self) { route in
                FolderView(route: route)
                    .environment(\.openAncestor, openAncestor)
                    .stackChrome(history)
            }
            .navigationDestination(for: VideoFile.self) { file in
                VideoInfoView(file: file)
                    .stackChrome(history)
            }
    }
}

/// [탐색] 탭 (아이폰·좁은 아이패드): 라이브러리 · 폴더. 추가·빼기는 설정 → 라이브러리에서 한다.
/// 키보드가 떠 있는지 알려 준다 (아이폰·아이패드)
private struct KeyboardShown: ViewModifier {
    @Binding var shown: Bool
    func body(content: Content) -> some View {
        #if os(iOS)
        content
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in shown = true }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in shown = false }
        #else
        content
        #endif
    }
}

struct BrowseView: View {
    @State private var libraries = LibraryStore.shared
    @State private var locations = LocationStore.shared
    @State private var history = StackHistory()
    /// 탭 막대가 있을 때 본 가장 큰 아래 안전 여백 (2026-11-10)
    @State private var tabBarInset: CGFloat = 0
    /// 키보드가 떠 있는지 (그동안의 안전 여백은 키보드 높이라 재지 않는다, 2026-11-11)
    @State private var keyboardShown = false

    var body: some View {
        AppNavigationStack(history: history) {
            List {
                if !libraries.libraries.isEmpty {
                    Section("라이브러리") {
                        ForEach(libraries.libraries) { library in
                            NavigationLink(value: LibraryRoute(id: library.id)) {
                                Label {
                                    Text(library.name)
                                } icon: {
                                    Image(systemName: library.symbol)
                                }
                            }
                        }
                    }
                }
                Section {
                    if locations.showsThisDevice {
                        NavigationLink(value: FolderRoute(url: locations.documentsURL, title: LocationStore.thisDeviceName)) {
                            Label(LocationStore.thisDeviceName, systemImage: LocationStore.thisDeviceIcon)
                        }
                    }
                    ForEach(locations.shownFolders) { folder in
                        if let url = locations.resolve(folder) {
                            NavigationLink(value: FolderRoute(url: url, title: folder.name, location: .folder(folder.id))) {
                                Label(folder.name, systemImage: folder.symbol)
                            }
                        } else {
                            Label("\(folder.name) (접근할 수 없음)", systemImage: "folder.badge.questionmark")
                                .foregroundStyle(.secondary)
                        }
                    }
                    ForEach(locations.servers) { server in
                        ForEach(locations.shownFavorites(of: server.id)) { favorite in
                            NavigationLink(value: FolderRoute(url: favorite.url, title: favorite.name, serverID: server.id, location: .favorite(favorite.id))) {
                                Label(favorite.name, systemImage: favorite.symbol)
                            }
                        }
                    }
                } header: {
                    Text("폴더")
                } footer: {
                    if libraries.libraries.isEmpty {
                        Text("설정 → 라이브러리에서 라이브러리와 폴더를 추가하세요.")
                    }
                }
                #if os(iOS)
                // 맥에서 받는 현황 (2026-11-09, 사용자: 폰에서는 받지 않고 맥이 받는 것을 본다. 아이폰 탭 막대는 5칸이라 여기에)
                Section("웹") {
                    NavigationLink {
                        PhoneWebView()
                    } label: {
                        Label("웹 탐색", systemImage: "globe")
                    }
                    NavigationLink {
                        MacDownloadsView()
                    } label: {
                        Label("다운로드", systemImage: "arrow.down.circle")
                    }
                }
                #endif
            }
            // 당겨서 새로고침: 검색용 목록을 모두 다시 만든다 (홈·검색에 켠 폴더)
            .refreshable {
                // 폴더는 NAS 를 훑느라 오래 걸릴 수 있어 기다리지 않는다
                Task { await MediaIndex.shared.refresh() }
            }
            // 웹 탐색처럼 탭 막대를 숨기는 화면에 들어가면 이 목록의 아래 여백이 줄어 목록이 내려앉았다가, 돌아올 때 탭 막대가
            // 다시 나오며 아래 메뉴를 가렸다 (2026-11-10, 사용자). 목록이 아래 안전 여백을 따르지 않게 하고, 탭 막대가 있을 때 본
            // 가장 큰 여백을 고정 여백으로 둔다 (줄어든 만큼 채우는 방식은 한 박자 늦어 그 사이 목록이 내려앉았다)
            // 바뀜 (2026-11-10, 사용자): 여백을 바꾸면 목록 기본 아래 여백·탭 막대 사이 틈이 없어지고 스크롤 끝이 어색했다 —
            //   목록은 그대로 안전 여백을 따르게 두고, 안전 여백 값만 탭 막대가 있을 때의 값으로 고정한다
            .safeAreaPadding(.bottom, tabBarInset)
            .ignoresSafeArea(.container, edges: .bottom)
            .onGeometryChange(for: CGFloat.self) { $0.safeAreaInsets.bottom } action: { bottom in
                // 바뀜 (2026-11-11, 사용자: 웹 탐색에서 키보드를 연 채 돌아오면 키보드만큼 목록이 올라가 있었다): 키보드가 떠 있을 때 여백은 재지 않는다
                guard !keyboardShown else { return }
                tabBarInset = max(tabBarInset, bottom)
            }
            .modifier(KeyboardShown(shown: $keyboardShown))
            .navigationTitle("탐색")
            .locationDestinations()
            .libraryDestinations(history)
            .environment(\.inLibraryStack, true)
        }
    }
}

/// [둘러보기] 탭 (아이폰·좁은 아이패드): 장르 · 컬렉션 · 인물 · 재생목록을 위쪽 분할 단추로 고른다.
/// 영화 라이브러리처럼 큰 제목·찾기 칸·분할 단추·스크롤은 이 탭 하나가 맡고, 화면들은 그 안에 내용만 그린다.
/// 좌우로 밀면 내용만 손가락을 따라 밀리고 옆 화면의 내용이 같은 깊이에서 들어온다 (캘린더 일 보기처럼, 넘어가면 톡 햅틱).
struct BrowseTabView: View {
    enum Page: String, CaseIterable {
        case genres = "장르", collections = "컬렉션", people = "인물", playlists = "재생목록"

        var prompt: String {
            self == .people ? "모든 인물에서 찾기" : "\(rawValue)에서 찾기"
        }

        /// 정렬을 기억하는 이름 (BrowseSort.key)
        var sortPage: String {
            switch self {
            case .genres: "genres"
            case .collections: "collections"
            case .people: "people"
            case .playlists: "playlists"
            }
        }
    }

    @State private var page = Page.genres
    @State private var history = StackHistory()
    /// 화면마다 따로 기억하는 찾기 글자
    @State private var queries: [Page: String] = [:]
    /// 좌우로 미는 중인 거리, 옆에 그릴 화면 쪽, 한 화면 폭
    @State private var pageOffset: CGFloat = 0
    @State private var pageTurning = 0
    @State private var pageWidth: CGFloat = 0

    var body: some View {
        AppNavigationStack(history: history) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Picker("둘러보기", selection: $page) {
                        ForEach(Page.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    pageView(page)
                        .pageSlide($pageOffset)
                        .overlay(alignment: .topLeading) {
                            // 미는 쪽 옆 화면 (한 화면 폭 옆에 붙어 따라온다)
                            if let next = neighbor(pageTurning) {
                                pageView(next)
                                    .environment(\.browsePreview, true)
                                    .pageSlide($pageOffset, shift: CGFloat(pageTurning) * pageWidth)
                                    .allowsHitTesting(false)
                            }
                        }
                }
                .padding(pagePadding)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { pageWidth = $0 }
            .swipeToPage($page, among: Page.allCases, offset: $pageOffset, turning: $pageTurning, distance: pageWidth)
            .navigationTitle(page.rawValue)
            // [정렬] [찾기]: 정렬은 지금 화면 것 (화면마다 기억)
            .pageSearchable(Binding { queries[page] ?? "" } set: { queries[page] = $0 }, prompt: page.prompt) {
                ToolbarItem(placement: .primaryAction) { BrowseSortMenu(page: page.sortPage).id(page) }
            }
            .libraryDestinations(history)
            .environment(\.inLibraryStack, true)
        }
    }

    private func pageView(_ page: Page) -> some View {
        Group {
            switch page {
            case .genres: GenresView()
            case .collections: CollectionsBrowseView()
            case .people: PeopleView()
            case .playlists: PlaylistsView()
            }
        }
        .environment(\.browseQuery, queries[page] ?? "")
    }

    /// 지금 화면의 앞(-1)·뒤(1) 화면 (0 이면 없음)
    private func neighbor(_ step: Int) -> Page? {
        guard step != 0, let index = Page.allCases.firstIndex(of: page), Page.allCases.indices.contains(index + step) else { return nil }
        return Page.allCases[index + step]
    }
}

/// 탐색 위치 화면의 ··· 메뉴에서 고른 동작.
/// 시트·알림은 툴바의 메뉴가 아니라 화면 본문(`LocationMenuPresentations`)에 붙인다.
/// 툴바 안에 붙여 두면 그 화면 위로 연 플레이어에서 시트(재생 설정)가 뜨지 않는다.
@Observable
final class LocationMenuModel {
    var editingServer: NetworkServer?
    var renaming = false
    var newName = ""
    var confirmDelete = false
}

/// ··· 메뉴가 여는 시트·알림
struct LocationMenuPresentations: ViewModifier {
    let location: LocationID?
    @Bindable var model: LocationMenuModel

    func body(content: Content) -> some View {
        let locations = LocationStore.shared
        content
            .sheet(item: $model.editingServer) { server in
                ServerEditView(server: server)
            }
            .alert("이름 변경", isPresented: $model.renaming) {
                TextField("이름", text: $model.newName)
                Button("취소", role: .cancel) {}
                Button("저장") {
                    let name = model.newName.trimmingCharacters(in: .whitespaces)
                    if case .folder(let id) = location, !name.isEmpty, let folder = locations.folders.first(where: { $0.id == id }) {
                        locations.update(folder, name: name, icon: folder.icon)
                    }
                }
            }
            .alert("탐색에서 삭제할까요?", isPresented: $model.confirmDelete) {
                Button("취소", role: .cancel) {}
                Button("삭제", role: .destructive) { if let location { locations.remove([location]) } }
            } message: {
                Text("서버와 폴더 안의 영상은 지워지지 않습니다.")
            }
    }
}

#if os(macOS)
/// 맥 폴더 화면 제목: "위치 › 상위 폴더 › 지금 폴더" (컬렉션처럼 큰 제목). 상위 폴더를 누르면 그리로 간다.
private struct FolderPathTitle: View {
    /// 가까운 것부터
    let ancestors: [FolderRoute]
    let title: String
    @Environment(\.openAncestor) private var openAncestor

    var body: some View {
        path
    }

    private var path: some View {
        HStack(spacing: 8) {
            ForEach(Array(ancestors.enumerated()).reversed(), id: \.element.url) { index, folder in
                part(folder, depth: index + 1)
                Image(systemName: "chevron.right")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            Text(title)
                .layoutPriority(1)
        }
        .font(.largeTitle.bold())
        .lineLimit(1)
    }

    @ViewBuilder
    private func part(_ folder: FolderRoute, depth: Int) -> some View {
        if let openAncestor {
            Button(folder.title) { openAncestor(depth, folder) }
                .buttonStyle(PathPartStyle())
        } else {
            NavigationLink(folder.title, value: folder)
                .buttonStyle(PathPartStyle())
        }
    }
}

/// 제목 속 상위 폴더: 흐린 글자, 마우스를 올리면 진하게
private struct PathPartStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        PathPartLabel(label: configuration.label, pressed: configuration.isPressed)
    }
}

private struct PathPartLabel<Label: View>: View {
    let label: Label
    let pressed: Bool
    @State private var hovering = false

    var body: some View {
        label
            .foregroundStyle(hovering && !pressed ? .primary : .secondary)
            .contentShape(.rect)
            .onHover { hovering = $0 }
    }
}
#endif

/// 위치 안의 하위 폴더와 영상 목록 (nPlayer 처럼 목록형)
struct FolderView: View {
    let route: FolderRoute

    @Environment(\.dismiss) private var dismiss
    @State private var locations = LocationStore.shared
    @State private var listing = DirectoryListing()
    @State private var menu = LocationMenuModel()
    @State private var loaded = false
    @State private var errorMessage: String?
    @State private var actions = FileActionsModel()
    @State private var transfers = TransferCenter.shared
    @State private var folderOptions = FolderOptionsStore.shared
    @State private var showSettings = false
    /// 하위 폴더를 폴더 구역에 추가 (폴더 추가 화면)
    @State private var addingFolder: FolderSettingsView.Target?
    /// 늘어나면 하위 폴더 표지를 다시 찾는다
    @State private var coverRevision = 0
    /// 이 폴더 안에서만 찾기 (위로 당기면 나오는 검색창)
    @State private var filter = ""
    @Environment(\.horizontalSizeClass) private var sizeClass
    /// 목록에 실제로 적용한 찾기 글자. 검색창을 닫을 때 검색창이 내려오는 동안 목록을 바꾸면
    /// 둘이 따로 움직여 어긋나므로, 검색창이 자리를 잡은 뒤에 목록을 바꾼다.
    @State private var appliedFilter = ""
    #if os(macOS)
    @Environment(\.stackHistory) private var history
    /// ⇧클릭으로 범위를 고를 때 기준이 되는 항목 (마지막으로 그냥 누르거나 ⌘클릭한 것)
    @State private var selectionAnchor: URL?
    #endif

    var body: some View {
        ScrollViewReader { proxy in
            // 카드 격자. 폴더 영상은 세로 포스터가 없으니 가로로 긴 썸네일을 쓰고,
            // 칸 최소 폭을 정해 두어 아이폰 세로는 2열, 넓은 화면(아이패드·가로)은 더 많이 놓인다.
            ScrollView {
              // 제목·격자 여백은 라이브러리·둘러보기 화면과 같게 (pagePadding, 제목과 격자 사이 16)
              VStack(alignment: .leading, spacing: 16) {
                #if os(macOS)
                FolderPathTitle(ancestors: ancestors, title: current?.title ?? route.title)
                    .frame(maxWidth: .infinity, alignment: .leading)
                #endif
                // 포스터형은 세로 표지(아이폰 세로 3열), 썸네일형은 가로 썸네일(2열). 넓은 화면은 더 많이.
                LazyVGrid(columns: [GridItem(.adaptive(minimum: gridMinimum), spacing: 12)], spacing: 16) {
                    ForEach(shown.folders, id: \.self) { folder in
                        selectable(folder.fileItem) {
                            NavigationLink(value: folder) { folderCard(folder).returnHighlight(folder.url) }
                        } card: {
                            folderCard(folder)
                        }
                        .id(folder.url)
                    }
                    ForEach(shown.videos) { file in
                        selectable(file.fileItem) {
                            NavigationLink(value: file) { videoCard(file).returnHighlight(file.url) }
                        } card: {
                            videoCard(file)
                        }
                        .id(file.url)
                    }
                    ForEach(shown.archives) { file in
                        selectable(file.fileItem) {
                            Button {
                                openArchive(file)
                            } label: {
                                archiveCard(file).returnHighlight(file.url)
                            }
                            .overlay {
                                if actions.openingArchive == file.url { ProgressView().controlSize(.large) }
                            }
                        } card: {
                            archiveCard(file)
                        }
                        .id(file.url)
                    }
                    // 바뀜 (2026-11-08): 텍스트 파일 (텍스트 뷰어)
                    ForEach(shown.texts) { file in
                        selectable(file.fileItem) {
                            Button {
                                openText(file)
                            } label: {
                                textCard(file).returnHighlight(file.url)
                            }
                        } card: {
                            textCard(file)
                        }
                        .id(file.url)
                    }
                }
                #if os(macOS)
                // 카드 사이 빈 곳을 누르면 선택 해제 (카드 뒤에 깔아서 카드를 누를 때는 함께 불리지 않게)
                .background { Color.clear.contentShape(.rect).onTapGesture(perform: clearSelection) }
                #endif
              }
              .padding(pagePadding)
            }
            #if os(macOS)
            .background { Color.clear.contentShape(.rect).onTapGesture(perform: clearSelection) }
            .modifier(MacSelectionKeys(model: self))
            #endif
            .showsReturnHighlight(ids: allItems.map { AnyHashable($0.url) }, proxy: proxy)
        }
        .navigationTitle(actions.isSelecting ? selectionTitle : current?.title ?? route.title)
        // 이 폴더 안에서만 찾기: 처음에는 숨어 있다가 목록을 아래로 당기면 나온다
        .searchable(text: $filter, placement: .drawer, prompt: "이 폴더에서 찾기")
        // 검색창을 열어도 제목 줄을 숨기지 않는다 (닫을 때 목록이 제목 줄을 늦게 따라 내려오며 튀지 않게)
        // 바뀜 (2026-11-08): 아이폰은 라이브러리 화면처럼 제목 막대가 숨는다 (searchBarBehavior, 아이패드는 그대로)
        .searchBarBehavior()
        .task(id: filter) {
            // 지울 때(검색창 닫기)는 검색창이 내려온 뒤에, 칠 때는 잠깐 멈추면 거른다
            try? await Task.sleep(for: .milliseconds(filter.isEmpty ? 450 : 150))
            guard !Task.isCancelled else { return }
            appliedFilter = filter
        }
        #if os(iOS)
        // 아이폰·아이패드: 시스템 큰 제목 (찾기 칸이 제목 아래에 붙게). 큰 제목은 누르는 동작을 정할 수 없어서
        // 상위 폴더로 가는 메뉴는 ‹ 옆에 둔다 (맥은 내용 맨 위 경로 제목)
        .toolbar {
            if !actions.isSelecting && !ancestors.isEmpty {
                ToolbarItem(placement: .topBarLeading) {
                    Menu {
                        ForEach(ancestors, id: \.url) { folder in
                            NavigationLink(value: folder) {
                                Label(folder.title, systemImage: folder.location == nil ? "folder" : "externaldrive.connected.to.line.below")
                            }
                        }
                    } label: {
                        Label("상위 폴더", systemImage: "arrow.turn.left.up")
                    }
                }
            }
        }
        #endif
        .toolbar { toolbar }
        .hidesTabBar(actions.isSelecting)
        // 선택 모드: 탭 막대 자리에 사진 앱 탭 막대처럼 생긴 막대 (복사·이동·이름 바꾸기 묶음 + 삭제)
        .overlay(alignment: .bottom) {
            if actions.isSelecting {
                SelectionBar(items: selectedItems, actions: actions)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .modifier(LocationMenuPresentations(location: route.location, model: menu))
        .modifier(FileActionsPresentations(model: actions, folder: current?.fileItem) { await load() })
        .onChange(of: transfers.revision) { Task { await load(refreshingCovers: true) } }
        .settingsPanel(isPresented: $showSettings) {
            if let addedRoot { FolderSettingsView(target: .edit(addedRoot), presentation: .panel) }
        }
        .sheet(item: $addingFolder) { FolderSettingsView(target: $0) }
        .onChange(of: current == nil) { wasRemoved, removed in
            // ··· 메뉴에서 삭제했으면 탐색 목록으로 돌아간다
            if removed && !wasRemoved { dismiss() }
        }
        .overlay {
            if let errorMessage {
                ContentUnavailableView {
                    Label("열 수 없습니다", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(errorMessage)
                } actions: {
                    Button("다시 시도") { Task { await load() } }
                }
            } else if !loaded {
                ProgressView()
            } else if !appliedFilter.isEmpty && shown.folders.isEmpty && shown.videos.isEmpty && shown.archives.isEmpty && shown.texts.isEmpty {
                ContentUnavailableView.search(text: filter)
            } else if listing.folders.isEmpty && listing.videos.isEmpty && listing.archives.isEmpty && listing.texts.isEmpty {
                ContentUnavailableView("볼 수 있는 파일이 없습니다", systemImage: "folder",
                                       description: Text("영상과 압축 파일(zip·rar)만 보여줍니다."))
            }
        }
        .task(id: current) { await load() }
        // 하위 폴더에서 돌아오면 위 폴더 목록이 그 폴더 카드를 보여준다
        .onDisappear { ReturnHighlight.shared.returned([route.url]) }
        .onChange(of: sortOrder) { listing.sort(by: sortOrder) }
        .appRefreshable { await load(refreshingCovers: true) }
    }

    /// 보이는 목록: 찾기 글자가 있으면 이름이 맞는 것만 (한 글자·단어 중간·초성)
    private var shown: DirectoryListing {
        // 성인 등급 숨기기 중에는 "숨김"을 켠 하위 폴더를 뺀다
        var listing = listing
        if AdultFilter.shared.isOn {
            listing.folders = listing.folders.filter { !FolderOptionsStore.shared.isHiddenForAdult($0.url, serverID: route.serverID) }
        }
        guard !appliedFilter.trimmingCharacters(in: .whitespaces).isEmpty else { return listing }
        var result = listing
        result.folders = listing.folders.filter { KoreanIndex.matches(appliedFilter, in: $0.title) }
        result.videos = listing.videos.filter { KoreanIndex.matches(appliedFilter, in: $0.name) }
        result.archives = listing.archives.filter { KoreanIndex.matches(appliedFilter, in: $0.name) }
        result.texts = listing.texts.filter { KoreanIndex.matches(appliedFilter, in: $0.name) }
        return result
    }

    /// 등록된 위치의 최상위면 지금 저장된 정보로 다시 만든다 (··· 메뉴에서 이름·주소를 바꾼 뒤에도 맞게).
    /// 위치가 삭제됐으면 nil.
    private var current: FolderRoute? {
        switch route.location {
        case .server(let id):
            guard let server = locations.servers.first(where: { $0.id == id }), let url = server.rootURL else { return nil }
            return FolderRoute(url: url, title: server.name, serverID: id, location: route.location)
        case .folder(let id):
            guard let folder = locations.folders.first(where: { $0.id == id }) else { return nil }
            return FolderRoute(url: route.url, title: folder.name, location: route.location)
        case .favorite(let id):
            guard let favorite = locations.favorites.first(where: { $0.id == id }) else { return nil }
            return FolderRoute(url: route.url, title: favorite.name, serverID: route.serverID, location: route.location)
        case nil:
            return route
        }
    }

    /// 이 폴더가 들어 있는 추가한 폴더 (폴더 설정은 거기에 둔다, 경로의 맨 위)
    private var addedRoot: AddedFolder? {
        locations.addedFolder(containing: route.url, serverID: route.serverID)?.folder
    }

    /// 상위 폴더들 (가까운 것부터 추가한 폴더까지). 제목을 누르면 고를 수 있다.
    private var ancestors: [FolderRoute] {
        guard let current, let added = addedRoot, let root = locations.route(of: added) else { return [] }
        let rootKey = FolderOptionsStore.key(root.url, serverID: route.serverID)
        var result: [FolderRoute] = []
        var url = current.url
        for _ in 0..<64 {
            if FolderOptionsStore.key(url, serverID: route.serverID) == rootKey { break }
            url = url.deletingLastPathComponent()
            if FolderOptionsStore.key(url, serverID: route.serverID) == rootKey {
                result.append(root)
                break
            }
            result.append(FolderRoute(url: url, title: url.lastPathComponent, serverID: route.serverID))
        }
        return result
    }

    // MARK: - 보기 방식

    /// 칸 최소 폭: 포스터형은 세로 표지(아이폰 세로 3열), 썸네일형은 가로 썸네일(2열). 넓은 화면(아이패드)은 칸을 키운다.
    private var gridMinimum: CGFloat {
        let wide = sizeClass == .regular
        return viewMode == .poster ? (wide ? 150 : 105) : (wide ? 220 : 160)
    }

    private var sortOrder: FolderSortOrder {
        folderOptions.sortOrder(route.url, serverID: route.serverID)
    }

    /// 정한 보기 방식 (위 폴더에서 물려받은 것 포함). 정하지 않았으면 압축 파일이 영상보다 많을 때 포스터형.
    private var viewMode: FolderViewMode {
        folderOptions.viewMode(route.url, serverID: route.serverID)
            ?? (listing.archives.count + listing.texts.count > listing.videos.count ? .poster : .thumbnail)
    }

    @ViewBuilder
    private func folderCard(_ folder: FolderRoute) -> some View {
        if viewMode == .poster {
            PosterCard(title: folder.title, subtitle: "폴더") { FolderCover(folder: folder, revision: coverRevision) }
        } else {
            FolderCard(title: folder.title, folder: folder, revision: coverRevision)
        }
    }

    @ViewBuilder
    private func videoCard(_ file: VideoFile) -> some View {
        if viewMode == .poster {
            PosterCard(title: file.title, subtitle: file.size.fileSizeText,
                       progress: { let state = PlaybackStateStore.shared.state(for: file.stateKey); return state.duration > 0 ? state.position / state.duration : nil }()) {
                FileThumbnail(file: file)
            }
        } else {
            VideoCard(file: file)
        }
    }

    @ViewBuilder
    private func archiveCard(_ file: VideoFile) -> some View {
        if viewMode == .poster {
            PosterCard(title: file.title, subtitle: file.readingSubtitle, progress: file.readingProgress) { ArchiveCover(file: file) }
        } else {
            ArchiveCard(file: file)
        }
    }

    @ViewBuilder
    private func textCard(_ file: VideoFile) -> some View {
        if viewMode == .poster {
            PosterCard(title: file.title, subtitle: file.textSubtitle, progress: file.readingProgress) { TextCover() }
        } else {
            TextCard(file: file)
        }
    }

    private func openText(_ file: VideoFile) {
        Task { await TextLauncher.shared.open(file) }
    }

    // MARK: - 파일 관리

    /// 보이는 순서대로 모든 항목
    /// 바뀜 (2026-11-08): 텍스트 파일도
    private var allItems: [FileItem] {
        shown.folders.map(\.fileItem) + shown.videos.map(\.fileItem) + shown.archives.map(\.fileItem) + shown.texts.map(\.fileItem)
    }

    private var selectedItems: [FileItem] {
        allItems.filter { actions.selection.contains($0.url) }
    }

    private var selectionTitle: String {
        actions.selection.isEmpty ? "항목 선택" : "\(actions.selection.count)개 선택됨"
    }

    /// 평소엔 누르면 열리고, 선택 모드에서는 누르면 고른다. 꾹 누르면 파일 메뉴.
    @ViewBuilder
    private func selectable(_ item: FileItem, @ViewBuilder link: () -> some View, @ViewBuilder card: () -> some View) -> some View {
        Group {
            #if os(macOS)
            // 맥은 선택 모드 없이 Finder 처럼: 누르면 고르고 (⌘·⇧ 로 늘리기), 두 번 누르면 열고, 오른쪽 클릭은 고른 것들의 메뉴
            let selected = actions.selection.contains(item.url)
            card()
                .returnHighlight(item.url)
                .overlay {
                    if actions.openingArchive == item.url { ProgressView().controlSize(.large) }
                }
                .background {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(selected ? Color.accentColor.opacity(0.25) : .clear)
                        .strokeBorder(selected ? Color.accentColor : .clear, lineWidth: 2)
                        .padding(-5)
                }
                .contentShape(.rect)
                .onTapGesture { click(item) }
                .contextMenu {
                    let items = selected ? selectedItems : [item]
                    if items.count == 1 {
                        Button("열기") { open(item) }
                        Divider()
                    }
                    itemMenu(items)
                }
            #else
            if actions.isSelecting {
                Button {
                    actions.toggle(item.url)
                } label: {
                    card()
                        .overlay(alignment: .topTrailing) { SelectionMark(isSelected: actions.selection.contains(item.url)) }
                        .opacity(actions.selection.contains(item.url) ? 0.75 : 1)
                }
            } else {
                link()
                    .contextMenu {
                        // 여러 개 고르기는 길게 눌러서 (파일 앱처럼)
                        Button("선택", systemImage: "checkmark.circle") {
                            actions.select(true)
                            actions.toggle(item.url)
                        }
                        Divider()
                        itemMenu([item])
                    }
            }
            #endif
        }
        .buttonStyle(.plain)
    }

    #if os(macOS)
    /// Finder 처럼 고르기: 그냥 누르면 그것만, ⌘ 는 넣고 빼기, ⇧ 는 기준 항목부터 여기까지 더하기. 두 번 누르면 연다.
    private func click(_ item: FileItem) {
        let event = NSApp.currentEvent
        let flags = event?.modifierFlags.intersection(.deviceIndependentFlagsMask) ?? []
        if flags.contains(.command) {
            actions.toggle(item.url)
            selectionAnchor = item.url
        } else if flags.contains(.shift), let anchor = selectionAnchor ?? actions.selection.first,
                  let from = allItems.firstIndex(where: { $0.url == anchor }),
                  let to = allItems.firstIndex(where: { $0.url == item.url }) {
            actions.selection.formUnion(allItems[min(from, to)...max(from, to)].map(\.url))
        } else if (event?.clickCount ?? 1) >= 2 {
            open(item)
        } else {
            actions.selection = [item.url]
            selectionAnchor = item.url
        }
    }

    /// 두 번 누르기·Return·메뉴의 "열기": 폴더는 들어가고, 영상은 정보 화면, 압축 파일은 만화로
    private func open(_ item: FileItem) {
        if let folder = shown.folders.first(where: { $0.url == item.url }) {
            history?.path.append(folder)
        } else if let file = shown.archives.first(where: { $0.url == item.url }) {
            openArchive(file)
        } else if let file = shown.texts.first(where: { $0.url == item.url }) {
            openText(file)
        } else if let file = shown.videos.first(where: { $0.url == item.url }) {
            history?.path.append(file)
        }
    }

    private func selectAll() {
        actions.selection = Set(allItems.map(\.url))
    }

    private func clearSelection() {
        actions.selection = []
    }

    /// 격자의 키보드: ⌘A 모두 선택, Return 열기, ⌫·⌘⌫ 삭제, Esc 선택 해제.
    /// SwiftUI 포커스는 카드를 누르면 바로 풀려 (카드가 포커스 대상이 아니라) 편집 메뉴·키가 격자로 오지 않으므로,
    /// 이 화면이 보이는 동안 이 창의 키를 직접 받는다. 키 코드로 보므로 한글 입력 중에도 ⌘A 가 맞는다.
    private struct MacSelectionKeys: ViewModifier {
        let model: FolderView
        @State private var window: NSWindow?
        @State private var monitor: Any?

        func body(content: Content) -> some View {
            content
                .background(WindowReader { window = $0 })
                .onAppear {
                    guard monitor == nil else { return }
                    monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                        handle(event) ? nil : event
                    }
                }
                .onDisappear {
                    if let monitor { NSEvent.removeMonitor(monitor) }
                    monitor = nil
                }
        }

        private func handle(_ event: NSEvent) -> Bool {
            // 이 창에서, 글자를 치는 중(검색칸)이 아닐 때만. 알림·시트는 다른 창이라 건드리지 않는다.
            guard let window, event.window === window, !(window.firstResponder is NSText) else { return false }
            let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
            let selected = model.selectedItems
            switch (event.keyCode, flags) {
            case (0, .command):  // A
                guard !model.allItems.isEmpty else { return false }
                model.selectAll()
            case (36, []), (76, []):  // Return, 숫자 패드 Enter
                guard selected.count == 1, let item = selected.first else { return false }
                model.open(item)
            case (51, []), (51, .command), (117, []):  // ⌫, ⌘⌫, ⌦
                guard !selected.isEmpty else { return false }
                model.actions.deleting = selected
            case (53, []):  // Esc
                guard !model.actions.selection.isEmpty else { return false }
                model.clearSelection()
            default:
                return false
            }
            return true
        }
    }

    /// 화면이 든 창을 알려 준다
    private struct WindowReader: NSViewRepresentable {
        let onChange: (NSWindow?) -> Void

        func makeNSView(context: Context) -> NSView { Reader(onChange: onChange) }
        func updateNSView(_ nsView: NSView, context: Context) {}

        final class Reader: NSView {
            let onChange: (NSWindow?) -> Void
            init(onChange: @escaping (NSWindow?) -> Void) {
                self.onChange = onChange
                super.init(frame: .zero)
            }
            required init?(coder: NSCoder) { fatalError() }
            override func viewDidMoveToWindow() {
                super.viewDidMoveToWindow()
                let window = window
                DispatchQueue.main.async { self.onChange(window) }
            }
        }
    }
    #endif

    /// 항목(들)에 할 수 있는 일
    @ViewBuilder
    private func itemMenu(_ items: [FileItem]) -> some View {
        Button("복사", systemImage: "doc.on.doc") { actions.pending = .init(items: items, move: false) }
        Button("이동", systemImage: "folder") { actions.pending = .init(items: items, move: true) }
        if items.count == 1, let item = items.first, !item.isDirectory, VideoFile.isArchive(item.url),
           let file = listing.archives.first(where: { $0.url == item.url }) {
            Button("압축 풀기", systemImage: "archivebox") { Task { await actions.askExtract(file) } }
            ReadingRecordMenu(file: file)
        }
        if items.count == 1, let item = items.first, item.isDirectory, let target = addTarget(item) {
            Button("폴더로 추가…", systemImage: "folder.badge.plus") { addingFolder = target }
        }
        if items.count == 1, let item = items.first {
            Button("이름 바꾸기", systemImage: "pencil") {
                actions.newName = item.name
                actions.renaming = item
            }
        }
        Button("삭제", systemImage: "trash", role: .destructive) { actions.deleting = items }
    }

    /// 하위 폴더를 폴더 구역에 추가할 때 (이미 추가한 폴더면 nil)
    private func addTarget(_ item: FileItem) -> FolderSettingsView.Target? {
        if let serverID = item.serverID {
            guard locations.favorite(item.url, serverID: serverID) == nil,
                  let server = locations.servers.first(where: { $0.id == serverID }) else { return nil }
            return .newStorage(server, item.url)
        }
        let key = FolderOptionsStore.key(item.url, serverID: nil)
        let added = locations.addedFolders.contains { added in
            locations.url(of: added).map { FolderOptionsStore.key($0, serverID: nil) == key } ?? false
        }
        return added ? nil : .newLocal(item.url)
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        if actions.isSelecting {
            ToolbarItem(placement: .leadingBar) {
                Button(actions.selection.count == allItems.count ? "선택 해제" : "모두 선택") {
                    actions.selection = actions.selection.count == allItems.count ? [] : Set(allItems.map(\.url))
                }
            }
            ToolbarItem(placement: .trailingBar) {
                Button("완료") { actions.select(false) }
                    .buttonStyle(.glassProminent)
            }
        } else if current != nil {
            // [‹ ›] … [새 폴더] [정렬 | 폴더 설정] [찾기] (라이브러리 화면처럼). 하위 폴더 추가는 그 폴더의 메뉴에서.
            // 아이폰·아이패드: 제목이 폴더 이름이고, 하위 폴더는 제목을 누르면 상위 폴더로. 찾기는 당기면 나온다.
            #if os(macOS)
            ToolbarSpacer(.flexible)
            #endif
            ToolbarItem(placement: .primaryAction) {
                Button("새 폴더", systemImage: "folder.badge.plus") {
                    actions.newName = ""
                    actions.creatingFolder = true
                }
                .help("새 폴더")
            }
            ToolbarSpacer(.fixed, placement: .primaryAction)
            ToolbarItemGroup(placement: .primaryAction) {
                Menu("정렬", systemImage: "arrow.up.arrow.down") {
                    Picker("정렬", selection: Binding(
                        get: { sortOrder },
                        set: { order in folderOptions.update(route.url, serverID: route.serverID) { $0.sortOrder = order } }
                    )) {
                        ForEach(FolderSortOrder.allCases, id: \.self) { Label($0.title, systemImage: $0.systemImage).tag($0) }
                    }
                    .pickerStyle(.inline)
                }
                .help("정렬")
                #if os(macOS)
                // 맥은 클릭으로 바로 고르므로 선택이 따로 없다 → 폴더 설정만 단추로 (옆 패널을 열고 닫는다)
                Button("폴더 설정", systemImage: "slider.horizontal.3") { showSettings.toggle() }
                    .help("폴더 설정")
                    .disabled(addedRoot == nil)
                #else
                // ⋯: 선택(꾹 누르기와 같음) · 폴더 설정 (재생목록 화면과 같은 자리)
                Menu("더 보기", systemImage: "ellipsis") {
                    Button("선택", systemImage: "checkmark.circle") { actions.select(true) }
                        .disabled(allItems.isEmpty)
                    Divider()
                    Button("폴더 설정", systemImage: "slider.horizontal.3") { showSettings.toggle() }
                        .disabled(addedRoot == nil)
                }
                #endif
            }
            #if os(macOS)
            DefaultToolbarItem(kind: .search, placement: .automatic)
            #endif
        }
    }

    private func openArchive(_ file: VideoFile) {
        Task { await actions.open(file, siblings: listing.archives) }
    }

    /// refreshingCovers: 새로고침·파일 작업 뒤 — 하위 폴더 표지도 다시 찾는다
    private func load(refreshingCovers: Bool = false) async {
        guard let current else { return }
        do {
            var result = try await DirectoryLister.list(current)
            // 받은 김에 홈·검색용 목록도 바꾼다 (이 폴더 바로 안의 파일만)
            MediaIndex.shared.update(current, listing: result)
            result.sort(by: sortOrder)
            listing = result
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
        loaded = true
        if refreshingCovers {
            await CoverService.shared.forgetFolders(listing.folders + [current])
            coverRevision += 1
        }
    }
}

/// 선택 모드의 아래 막대: 왼쪽 캡슐에 복사·이동·이름 바꾸기(아이콘 + 작은 글자), 오른쪽 동그라미에 삭제
private struct SelectionBar: View {
    let items: [FileItem]
    let actions: FileActionsModel

    var body: some View {
        GlassEffectContainer {
            HStack(alignment: .center) {
                HStack(spacing: 0) {
                    action("복사", systemImage: "doc.on.doc", enabled: !items.isEmpty) {
                        actions.pending = .init(items: items, move: false)
                    }
                    action("이동", systemImage: "folder", enabled: !items.isEmpty) {
                        actions.pending = .init(items: items, move: true)
                    }
                    action("이름 바꾸기", systemImage: "pencil", enabled: items.count == 1) {
                        actions.newName = items.first?.name ?? ""
                        actions.renaming = items.first
                    }
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 6)
                .glassEffect(.regular.interactive(), in: .capsule)
                Spacer()
                Button {
                    actions.deleting = items
                } label: {
                    Image(systemName: "trash")
                        .font(.title2)
                        .foregroundStyle(items.isEmpty ? AnyShapeStyle(.secondary) : AnyShapeStyle(.red))
                        .frame(width: 62, height: 62)
                        .contentShape(.circle)
                }
                .buttonStyle(.plain)
                .disabled(items.isEmpty)
                .glassEffect(.regular.interactive(), in: .circle)
                .accessibilityLabel("삭제")
            }
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 4)
    }

    private func action(_ title: String, systemImage: String, enabled: Bool, perform: @escaping () -> Void) -> some View {
        Button(action: perform) {
            VStack(spacing: 3) {
                Image(systemName: systemImage)
                    .font(.title3)
                    .frame(height: 24)
                Text(title)
                    .font(.caption2)
            }
            .frame(width: 76, height: 50)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .foregroundStyle(enabled ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
        .disabled(!enabled)
    }
}

/// 폴더 목록의 영상 카드: 가로 썸네일(이어보기 진행률·길이) + 흘러가는 제목 + 크기
/// 재생목록에서도 쓴다 (재생 중이면 테두리와 "재생 중" 표시).
struct VideoCard: View {
    let file: VideoFile
    var isCurrent = false

    @State private var thumbnail: UIImage?
    @State private var duration: Double?

    var body: some View {
        let state = PlaybackStateStore.shared.state(for: file.stateKey)
        VStack(alignment: .leading, spacing: 4) {
            Color.clear
                .aspectRatio(16 / 9, contentMode: .fit)
                .background(.quaternary)
                .overlay {
                    if let thumbnail {
                        Image(uiImage: thumbnail).resizable().scaledToFill()
                    } else {
                        Image(systemName: "film").foregroundStyle(.secondary)
                    }
                }
                .overlay(alignment: .topLeading) {
                    if isCurrent {
                        Label("재생 중", systemImage: "speaker.wave.2.fill")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(.tint, in: .capsule)
                            .padding(6)
                    }
                }
                .overlay(alignment: .bottomTrailing) {
                    if let duration {
                        Text(duration.durationText)
                            .font(.caption2.monospacedDigit().weight(.semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(.black.opacity(0.6), in: .rect(cornerRadius: 4))
                            .padding(6)
                    }
                }
                .overlay(alignment: .bottom) {
                    if state.position > 0, state.duration > 0 {
                        ProgressBar(fraction: state.position / state.duration)
                    }
                }
                .clipShape(.rect(cornerRadius: 8))
                .returnHighlightBorder(cornerRadius: 8)
                .overlay {
                    if isCurrent { RoundedRectangle(cornerRadius: 8).strokeBorder(.tint, lineWidth: 3) }
                }
            MarqueeText(text: file.title)
                .cardTitleFont()
                .foregroundStyle(isCurrent ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
            Text(file.size.fileSizeText)
                .cardSubtitleFont()
                .foregroundStyle(.secondary)
        }
        // 썸네일·제목 칸 전체를 누를 수 있게
        .contentShape(.rect)
        .task(id: file) {
            duration = ThumbnailService.shared.duration(for: file)
            thumbnail = await ThumbnailService.shared.thumbnail(for: file)
            duration = ThumbnailService.shared.duration(for: file)
        }
    }
}

/// 폴더 목록의 폴더 카드 (영상 카드와 같은 크기)
struct FolderCard: View {
    let title: String
    /// 있으면 폴더 안의 cover.jpg 같은 그림이나 첫 영상의 썸네일을 보인다 (없으면 폴더 아이콘)
    var folder: FolderRoute?
    /// 바뀌면 그림을 다시 찾는다 (폴더 화면 새로고침)
    var revision = 0
    @State private var image: UIImage?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Color.clear
                .aspectRatio(16 / 9, contentMode: .fit)
                .background(.quaternary)
                .overlay {
                    if let image {
                        Image(uiImage: image).resizable().scaledToFill()
                    } else {
                        Image(systemName: "folder.fill")
                            .font(.system(size: 36))
                            .foregroundStyle(.tint)
                    }
                }
                // 영상 카드와 헷갈리지 않게 모서리에 폴더 표시 (포스터형 폴더 표지와 같게).
                // 그림이 아니라 카드 칸에 붙인다: 꽉 채운 그림은 칸보다 커서 그 모서리는 잘려 나간 곳이다
                .overlay(alignment: .bottomTrailing) {
                    if image != nil { FolderBadge() }
                }
                .clipShape(.rect(cornerRadius: 8))
                .returnHighlightBorder(cornerRadius: 8)
            MarqueeText(text: title)
                .cardTitleFont()
            // 영상 카드의 크기 줄과 높이를 맞춘다
            Text("폴더")
                .cardSubtitleFont()
                .foregroundStyle(.secondary)
        }
        .contentShape(.rect)
        .task(id: folder.map { "\($0.url.absoluteString)#\(revision)" }) {
            guard let folder else { return }
            switch await CoverService.shared.preview(forFolder: folder) {
            case .image(let cover): image = cover
            case .video(let file): image = await ThumbnailService.shared.thumbnail(for: file)
            case nil: image = nil
            }
        }
    }
}

/// 폴더 목록의 압축 파일(만화책) 카드 (썸네일형: 표지를 가운데, 양옆은 흐린 표지)
struct ArchiveCard: View {
    let file: VideoFile

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Color.clear
                .aspectRatio(16 / 9, contentMode: .fit)
                .overlay { ArchiveCover(file: file, fillsWideArea: true) }
                .overlay(alignment: .bottom) {
                    if let progress = file.readingProgress { ProgressBar(fraction: progress) }
                }
                .clipShape(.rect(cornerRadius: 8))
                .returnHighlightBorder(cornerRadius: 8)
            MarqueeText(text: file.title)
                .cardTitleFont()
            Text(file.readingSubtitle)
                .cardSubtitleFont()
                .foregroundStyle(.secondary)
        }
        .contentShape(.rect)
    }
}

/// 영상 목록의 한 줄: 썸네일 + 제목 + 길이·크기 + 이어보기 진행률
struct VideoRow: View {
    let file: VideoFile

    @State private var thumbnail: UIImage?
    @State private var duration: Double?

    var body: some View {
        let state = PlaybackStateStore.shared.state(for: file.stateKey)
        HStack(spacing: 12) {
            ZStack(alignment: .bottom) {
                Rectangle().fill(.quaternary)
                if let thumbnail {
                    Image(uiImage: thumbnail).resizable().scaledToFill()
                }
                if state.position > 0, state.duration > 0 {
                    ProgressBar(fraction: state.position / state.duration)
                }
            }
            .frame(width: 120, height: 68)
            .clipShape(.rect(cornerRadius: 6))
            .returnHighlightBorder(cornerRadius: 6)

            VStack(alignment: .leading, spacing: 4) {
                Text(file.title)
                    .font(.body)
                    .lineLimit(2)
                Text([duration.map(\.durationText), file.size.fileSizeText].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .task(id: file) {
            duration = ThumbnailService.shared.duration(for: file)
            thumbnail = await ThumbnailService.shared.thumbnail(for: file)
            duration = ThumbnailService.shared.duration(for: file)
        }
    }
}

/// 썸네일 아래쪽의 이어보기 진행률 막대
struct ProgressBar: View {
    let fraction: Double

    var body: some View {
        GeometryReader { geometry in
            Rectangle()
                .fill(.tint)
                .frame(width: geometry.size.width * min(max(fraction, 0), 1))
        }
        .frame(height: 3)
        .background(.black.opacity(0.4))
    }
}
