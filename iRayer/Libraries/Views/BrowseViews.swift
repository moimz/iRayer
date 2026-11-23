import SwiftUI

// MARK: - 길 (라이브러리·둘러보기 화면이 같이 쓴다)

/// 작품 화면 (작품 파일이 든 라이브러리 + 작품 키)
struct BrowseItemRoute: Hashable {
    let libraryID: String
    let key: String
    /// 시리즈면 처음에 보여 줄 시즌 (홈 이어보기에서 그 회차의 시즌으로). 없으면 이어 볼 회차의 시즌
    var season: Int? = nil
}

/// 인물 화면 (정보출처:번호)
struct PersonRoute: Hashable {
    let key: String
    let name: String
    let photo: String?
    /// 원어 이름 (인물 화면에서 이름 아래)
    var nameOrigin: String? = nil
}

/// 작품 목록 화면 (장르·컬렉션)
struct ItemListRoute: Hashable {
    enum Source: Hashable {
        case genre(String)
        case collection(String)
    }
    let source: Source
    let title: String
}

/// 라이브러리 화면 (아이폰 탐색 탭에서 쌓을 때)
struct LibraryRoute: Hashable {
    let id: String
}

/// 재생목록 화면 (홈의 재생목록 줄에서)
struct PlaylistRoute: Hashable {
    let id: String
}

extension EnvironmentValues {
    /// 이미 라이브러리 길을 아는 스택 안 (아이폰 탐색·둘러보기 탭). 화면이 스택을 또 만들지 않는다.
    @Entry var inLibraryStack = false
}

extension View {
    /// 라이브러리·둘러보기 스택에서 쓰는 화면들
    func libraryDestinations(_ history: StackHistory?) -> some View {
        navigationDestination(for: BrowseItemRoute.self) { route in
            if let library = LibraryStore.shared.library(route.libraryID) {
                LibraryItemView(library: library, itemKey: route.key, initialSeason: route.season).stackChrome(history)
                    .environment(\.inLibraryStack, true)
            }
        }
        .navigationDestination(for: PersonRoute.self) { route in
            PersonView(route: route).stackChrome(history)
                .environment(\.inLibraryStack, true)
        }
        .navigationDestination(for: ItemListRoute.self) { route in
            ItemListView(route: route).stackChrome(history)
                .environment(\.inLibraryStack, true)
        }
        .navigationDestination(for: PlaylistRoute.self) { route in
            if let list = Playlists.shared.list(route.id) {
                PlaylistDetail(list: list).stackChrome(history)
                    .environment(\.inLibraryStack, true)
            }
        }
        .navigationDestination(for: LibraryRoute.self) { route in
            if let library = LibraryStore.shared.library(route.id) {
                LibraryItemsView(library: library).stackChrome(history)
                    .environment(\.inLibraryStack, true)
            }
        }
    }
}

/// 라이브러리·둘러보기 화면의 스택. 이미 그런 스택 안이면 (아이폰 탐색·둘러보기 탭) 새로 만들지 않는다.
struct LibraryStack<Content: View>: View {
    @ViewBuilder let content: () -> Content
    @Environment(\.inLibraryStack) private var embedded
    @State private var history = StackHistory()

    var body: some View {
        if embedded {
            content()
        } else {
            AppNavigationStack(history: history) {
                content()
                    .libraryDestinations(history)
                    .environment(\.inLibraryStack, true)
            }
        }
    }
}

// MARK: - 격자

/// 작품 포스터 격자 (누르면 작품 화면)
struct ItemGrid: View {
    let items: [LibraryData.ItemSummary]
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        LazyVGrid(columns: posterColumns(sizeClass), alignment: .leading, spacing: 22) {
            ForEach(items) { item in
                NavigationLink(value: BrowseItemRoute(libraryID: item.libraryID, key: item.key)) {
                    LibraryPosterCard(title: item.title, subtitle: item.year.map(String.init) ?? "", poster: item.poster,
                                      badges: item.appleTV ? ["appletv.fill"] : [])
                }
                .buttonStyle(.plain)
            }
        }
    }
}

/// 포스터 넷을 2×2 로 (장르·컬렉션·재생목록 묶음 카드)
struct MosaicCard: View {
    /// 한 칸: 포스터, 또는 포스터가 없는 영상의 썸네일 (칸 비율에 맞게 가운데를 잘라 채운다)
    enum Tile {
        case poster(String)
        case video(VideoFile)
    }

    let title: String
    let subtitle: String
    let tiles: [Tile]
    /// 칸이 하나도 없을 때 가운데 보일 아이콘 (빈 재생목록)
    var symbol: String?
    @Environment(\.horizontalSizeClass) private var sizeClass

    init(title: String, subtitle: String, posters: [String]) {
        self.init(title: title, subtitle: subtitle, tiles: posters.map(Tile.poster))
    }

    init(title: String, subtitle: String, tiles: [Tile], symbol: String? = nil) {
        self.title = title
        self.subtitle = subtitle
        self.tiles = tiles
        self.symbol = symbol
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // 칸 크기를 먼저 정하고 그림을 거기에 맞춘다 (그림 비율에 따라 카드 높이가 달라지지 않게)
            Color.clear
                .aspectRatio(2 / 3, contentMode: .fit)
                .overlay {
                    // 넷이 안 되면 첫 포스터 하나를 꽉 채운다 (빈 칸이 보이지 않게)
                    if tiles.isEmpty, let symbol {
                        Rectangle().fill(.quaternary)
                            .overlay { Image(systemName: symbol).font(.largeTitle).foregroundStyle(.secondary) }
                    } else if tiles.count < 4 {
                        GeometryReader { geometry in tile(0, geometry.size.width, geometry.size.height) }
                    } else {
                    GeometryReader { geometry in
                        let width = (geometry.size.width - 2) / 2
                        let height = (geometry.size.height - 2) / 2
                        VStack(spacing: 2) {
                            HStack(spacing: 2) { tile(0, width, height); tile(1, width, height) }
                            HStack(spacing: 2) { tile(2, width, height); tile(3, width, height) }
                        }
                    }
                    }
                }
                .clipShape(.rect(cornerRadius: 8))
            .shadow(color: .black.opacity(0.15), radius: 4, y: 2)
            MarqueeText(text: title).font(PosterCardFont.title(sizeClass))
            Text(subtitle).font(PosterCardFont.subtitle(sizeClass)).foregroundStyle(.secondary)
        }
        .contentShape(.rect)
    }

    @ViewBuilder
    private func tile(_ index: Int, _ width: CGFloat, _ height: CGFloat) -> some View {
        Group {
            switch tiles.indices.contains(index) ? tiles[index] : nil {
            case .video(let file): FileThumbnail(file: file)
            case .poster(let poster): CachedImage(url: URL(string: poster))
            case nil: CachedImage(url: nil)
            }
        }
        .frame(width: width, height: height)
        .clipped()
    }
}

/// 둘러보기 화면의 틀: 큰 제목 + 스크롤 + 스택
extension EnvironmentValues {
    /// 둘러보기 탭(아이폰)에 끼운 화면의 찾기 글자. 있으면 탭이 큰 제목·찾기 칸·스크롤을 맡고 화면은 내용만 그린다
    /// (영화 라이브러리처럼 스크롤 하나 안에서 내용만 좌우로 밀리게)
    @Entry var browseQuery: String?
    /// 미는 동안 옆에 미리 그린 화면 (도구 막대·이동 목적지를 달지 않는다)
    @Entry var browsePreview = false
}

/// 둘러보기 화면의 정렬 (화면마다 기억). 기본은 이름순
enum BrowseSort: String, CaseIterable {
    case name, added

    var title: String {
        switch self {
        case .name: "이름순"
        case .added: "최근 추가순"
        }
    }

    /// 기억하는 열쇠 (genres · collections · people · playlists)
    static func key(_ page: String) -> String { "browseSort." + page }

    /// 이름순은 가나다, 최근 추가순은 최근 것부터 (같으면 이름순)
    func sorted<T>(_ items: [T], name: (T) -> String, added: (T) -> Date?) -> [T] {
        switch self {
        case .name:
            return items.sorted { KoreanIndex.precedes(name($0), name($1)) }
        case .added:
            return items.sorted {
                let left = added($0) ?? .distantPast, right = added($1) ?? .distantPast
                return left != right ? left > right : KoreanIndex.precedes(name($0), name($1))
            }
        }
    }
}

/// 정렬 단추 (라이브러리 화면과 같은 모양·자리)
struct BrowseSortMenu: View {
    @AppStorage private var sort: BrowseSort

    init(page: String) {
        _sort = AppStorage(wrappedValue: .name, BrowseSort.key(page))
    }

    var body: some View {
        Menu("정렬", systemImage: "arrow.up.arrow.down") {
            Picker("정렬", selection: $sort) {
                ForEach(BrowseSort.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.inline)
        }
        .help("정렬")
    }
}

private struct BrowsePage<Content: View>: View {
    /// 비었을 때 화면 가운데에 보일 안내 (목록 안이 아니라 화면 전체의 가운데)
    struct Empty {
        let title: String
        let systemImage: String
        let description: String
    }

    let title: String
    /// 정렬을 기억하는 화면 이름 (BrowseSort.key)
    let sortPage: String
    /// 이 화면 안에서 찾기 (이름)
    @Binding var query: String
    /// 찾기 칸 안내 (없으면 "제목에서 찾기")
    var prompt: String?
    var empty: Empty?
    /// 찾은 것이 없다 (찾기 글자가 있을 때)
    var noResults = false
    @ViewBuilder let content: () -> Content
    @Environment(\.browseQuery) private var embeddedQuery

    var body: some View {
        if let embeddedQuery {
            embedded
                .onChange(of: embeddedQuery, initial: true) { _, new in query = new }
        } else {
            standalone
        }
    }

    /// 둘러보기 탭에 끼운 모양: 내용만 (비었을 때 안내는 내용 자리에)
    @ViewBuilder
    private var embedded: some View {
        if let empty {
            ContentUnavailableView(empty.title, systemImage: empty.systemImage, description: Text(empty.description))
                .frame(maxWidth: .infinity)
                .padding(.top, 80)
        } else if noResults {
            ContentUnavailableView.search(text: query)
                .frame(maxWidth: .infinity)
                .padding(.top, 80)
        } else {
            content()
        }
    }

    private var standalone: some View {
        LibraryStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    MacPageTitle(title, inset: false)
                    content()
                }
                .padding(pagePadding)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .overlay {
                if let empty {
                    ContentUnavailableView(empty.title, systemImage: empty.systemImage, description: Text(empty.description))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if noResults {
                    ContentUnavailableView.search(text: query)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .navigationTitle(title)
            // [정렬] [찾기] (둘러보기 탭에 끼우면 탭이 단다)
            .pageSearchable($query, prompt: prompt ?? "\(title)에서 찾기") {
                ToolbarItem(placement: .primaryAction) { BrowseSortMenu(page: sortPage) }
            }
        }
    }
}


// MARK: - 장르

struct GenresView: View {
    @State private var genres: [LibraryData.GenreEntry] = []
    @AppStorage(BrowseSort.key("genres")) private var sort = BrowseSort.name
    @State private var loaded = false
    @State private var query = ""
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        let shown = sort.sorted(genres.filter { KoreanIndex.filter(query, $0.name) }, name: \.name, added: \.added)
        BrowsePage(title: "장르", sortPage: "genres", query: $query, empty: loaded && genres.isEmpty ? .init(
            title: "장르가 없습니다", systemImage: "books.vertical",
            description: "라이브러리에서 작품을 찾으면 장르별로 모아 보여줍니다.") : nil, noResults: !genres.isEmpty && shown.isEmpty) {
            LazyVGrid(columns: posterColumns(sizeClass), alignment: .leading, spacing: 22) {
                ForEach(shown) { genre in
                    NavigationLink(value: ItemListRoute(source: .genre(genre.name), title: genre.name)) {
                        MosaicCard(title: genre.name, subtitle: "\(genre.count)편", posters: genre.posters)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .task(id: LibraryScanner.shared.revision) {
            genres = LibraryData.genres()
            loaded = true
        }
    }
}

// MARK: - 컬렉션

struct CollectionsBrowseView: View {
    @State private var collections: [LibraryData.CollectionEntry] = []
    @AppStorage(BrowseSort.key("collections")) private var sort = BrowseSort.name
    @State private var loaded = false
    @State private var query = ""
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        let shown = sort.sorted(collections.filter { KoreanIndex.filter(query, $0.name) }, name: \.name, added: \.added)
        BrowsePage(title: "컬렉션", sortPage: "collections", query: $query, empty: loaded && collections.isEmpty ? .init(
            title: "컬렉션이 없습니다", systemImage: "square.stack.3d.up",
            description: "라이브러리의 영화가 시리즈(컬렉션)에 들면 여기에 모아 보여줍니다.") : nil, noResults: !collections.isEmpty && shown.isEmpty) {
            LazyVGrid(columns: posterColumns(sizeClass), alignment: .leading, spacing: 22) {
                ForEach(shown) { collection in
                    NavigationLink(value: ItemListRoute(source: .collection(collection.id), title: collection.name)) {
                        MosaicCard(title: collection.name, subtitle: "\(collection.count)편", posters: collection.posters)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .task(id: LibraryScanner.shared.revision) {
            collections = LibraryData.collections()
            loaded = true
        }
    }
}

/// 장르·컬렉션 안의 작품
struct ItemListView: View {
    let route: ItemListRoute
    @State private var items: [LibraryData.ItemSummary] = []
    @State private var query = ""

    var body: some View {
        let shown = items.filter { KoreanIndex.filter(query, $0.title, $0.titleOrigin) }
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                MacPageTitle(route.title, inset: false)
                ItemGrid(items: shown)
            }
            .padding(pagePadding)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .overlay {
            if !items.isEmpty && shown.isEmpty { ContentUnavailableView.search(text: query) }
        }
        .navigationTitle(route.title)
        .pageSearchable($query, prompt: "\(route.title)에서 찾기")
        .task {
            switch route.source {
            case .genre(let name): items = LibraryData.items(genre: name)
            case .collection(let id): items = LibraryData.items(collection: id)
            }
        }
    }
}

// MARK: - 인물

struct PeopleView: View {
    @State private var favorites = FavoritePeople.shared
    @AppStorage(BrowseSort.key("people")) private var sort = BrowseSort.name
    @State private var query = ""
    /// 라이브러리의 모든 인물 (찾을 때만 쓴다)
    @State private var everyone: [LibraryData.PersonSummary] = []
    /// 즐겨찾기 인물의 원어 이름
    @State private var origins: [String: String] = [:]
    /// 즐겨찾기 인물마다 그 사람 작품이 가장 최근 들어온 때 (최근 추가순)
    @State private var added: [String: Date] = [:]
    @Environment(\.horizontalSizeClass) private var sizeClass

    private var personSize: CGFloat { sizeClass == .compact ? 84 : 100 }

    /// 보이는 인물: 찾기 글자가 없으면 즐겨찾기(정렬대로), 있으면 라이브러리의 모든 인물에서 (작품이 많은 사람부터)
    private var shown: [(key: String, name: String, photo: String?, detail: String?)] {
        if query.trimmingCharacters(in: .whitespaces).isEmpty {
            return sort.sorted(favorites.visiblePeople, name: \.name, added: { added[$0.key] }).map { ($0.key, $0.name, $0.photo, origins[$0.key]) }
        }
        // 원어 이름으로도 찾는다 (예: 堺雅人, Sakai). 카드 아래에는 원어 이름, 없으면 작품 수
        return everyone.filter { KoreanIndex.filter(query, $0.name, $0.nameOrigin) }.prefix(200)
            .map { ($0.key, $0.name, $0.photo, $0.nameOrigin ?? "\($0.works)편") }
    }

    var body: some View {
        let shown = shown
        BrowsePage(title: "인물", sortPage: "people", query: $query, prompt: "모든 인물에서 찾기", empty: favorites.visiblePeople.isEmpty && query.isEmpty ? .init(
            title: "즐겨찾기한 인물이 없습니다", systemImage: "star",
            description: "작품 화면의 출연·제작에서 인물을 누르고 ☆ 를 눌러 추가하세요. 찾기 칸에서는 라이브러리의 모든 인물을 찾습니다.") : nil,
            noResults: !query.isEmpty && shown.isEmpty) {
            // 원어 이름이 있는 사람과 없는 사람이 섞여도 사진 높이가 맞게 위로 붙인다
            LazyVGrid(columns: [GridItem(.adaptive(minimum: personSize + 10, maximum: 140), spacing: 18, alignment: .top)],
                      alignment: .leading, spacing: 22) {
                ForEach(shown, id: \.key) { person in
                    NavigationLink(value: PersonRoute(key: person.key, name: person.name, photo: person.photo)) {
                        PersonCard(name: person.name, photo: person.photo, detail: person.detail, size: personSize)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .task(id: favorites.people.map(\.key)) {
            origins = LibraryData.originNames(favorites.people.map(\.key))
            added = LibraryData.latestAdded(people: favorites.people.map(\.key))
        }
        // 찾기를 시작할 때 한 번 읽는다 (인물이 수천 명이라 화면을 열 때마다 읽지 않게)
        .onChange(of: query.isEmpty) {
            if everyone.isEmpty { everyone = LibraryData.allPeople() }
        }
    }
}

/// 둥근 사진 + 이름
struct PersonCard: View {
    let name: String
    let photo: String?
    let detail: String?
    var size: CGFloat = 100
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        VStack(spacing: 6) {
            CachedImage(url: photo.flatMap(URL.init(string:)))
                .frame(width: size, height: size)
                .clipShape(.circle)
                .overlay {
                    if photo == nil { Image(systemName: "person.fill").font(.title).foregroundStyle(.tertiary) }
                }
            // 글자는 포스터 카드와 같게 (아이폰은 한 단계 작게)
            MarqueeText(text: name, centered: true).font(PosterCardFont.title(sizeClass))
            if let detail, !detail.isEmpty {
                Text(detail).font(PosterCardFont.subtitle(sizeClass)).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .frame(width: size + 20)
        .contentShape(.rect)
    }
}

/// 인물 화면: 내 라이브러리에 있는 작품 + 즐겨찾기
struct PersonView: View {
    let route: PersonRoute
    @State private var favorites = FavoritePeople.shared
    @State private var works: [LibraryData.ItemSummary] = []
    @State private var query = ""
    /// 원어 이름 (들어온 길에 없으면 DB 에서)
    @State private var nameOrigin: String?

    var body: some View {
        let shown = works.filter { KoreanIndex.filter(query, $0.title, $0.titleOrigin) }
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                ItemGrid(items: shown)
                if !works.isEmpty && shown.isEmpty {
                    ContentUnavailableView.search(text: query).frame(maxWidth: .infinity)
                }
            }
            .padding(pagePadding)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        #if os(iOS)
        // 아이폰·아이패드: 라이브러리 화면처럼 시스템 큰 제목(이름), 찾기 칸은 그 아래. 스크롤하면 이름이 제목 줄로 올라간다.
        .navigationTitle(route.name)
        .navigationBarTitleDisplayMode(.large)
        #endif
        // [‹ ›] … [☆] [찾기]: 아이폰·아이패드는 당기면 나오는 찾기 칸
        .pageSearchable($query, prompt: "\(route.name)의 작품에서 찾기") {
            ToolbarItem(placement: .primaryAction) {
                let isFavorite = favorites.contains(route.key)
                Button(isFavorite ? "즐겨찾기에서 빼기" : "즐겨찾기", systemImage: isFavorite ? "star.fill" : "star") {
                    favorites.toggle(key: route.key, name: route.name, photo: route.photo)
                }
                .help(isFavorite ? "즐겨찾기에서 빼기" : "둘러보기 → 인물에 추가")
            }
        }
        .task {
            works = LibraryData.works(of: route.key)
            if route.nameOrigin == nil { nameOrigin = LibraryData.person(route.key)?.nameOrigin }
        }
    }

    /// 아이폰·아이패드: 이름은 큰 제목이 맡고 사진 옆에 원어 이름·작품 수. 맥: 사진 옆에 큰 이름
    @ViewBuilder
    private var header: some View {
        #if os(iOS)
        HStack(spacing: 16) {
            photo(size: 100)
            VStack(alignment: .leading, spacing: 4) {
                if let origin = nameOrigin ?? route.nameOrigin {
                    Text(origin).font(.title3).foregroundStyle(.secondary).textSelection(.enabled)
                }
                Text("내 라이브러리에 \(works.count)편").font(.subheadline).foregroundStyle(.secondary)
            }
        }
        #else
        HStack(spacing: 20) {
            photo(size: 120)
            VStack(alignment: .leading, spacing: 6) {
                Text(route.name).font(.largeTitle.bold())
                if let origin = nameOrigin ?? route.nameOrigin {
                    Text(origin).font(.title3).foregroundStyle(.secondary).textSelection(.enabled)
                }
                Text("내 라이브러리에 \(works.count)편").foregroundStyle(.secondary)
            }
        }
        #endif
    }

    private func photo(size: CGFloat) -> some View {
        CachedImage(url: route.photo.flatMap(URL.init(string:)))
            .frame(width: size, height: size)
            .clipShape(.circle)
            .overlay {
                if route.photo == nil { Image(systemName: "person.fill").font(size > 60 ? .largeTitle : .caption).foregroundStyle(.tertiary) }
            }
    }
}

// MARK: - 재생목록

struct PlaylistsView: View {
    @State private var playlists = Playlists.shared
    @AppStorage(BrowseSort.key("playlists")) private var sort = BrowseSort.name
    /// 재생목록마다 안의 영상이 가장 최근 라이브러리에 들어온 때 (최근 추가순)
    @State private var added: [String: Date] = [:]
    @State private var naming = false
    @State private var renaming: Playlists.List?
    @State private var query = ""
    @Environment(\.browseQuery) private var embeddedQuery
    @Environment(\.browsePreview) private var preview
    @Environment(\.horizontalSizeClass) private var sizeClass

    /// 찾기 글자에 맞는 재생목록 (정렬대로)
    private var shown: [Playlists.List] {
        sort.sorted(playlists.lists.filter { KoreanIndex.filter(query, $0.name) }, name: \.name, added: { added[$0.id] })
    }

    // 장르·컬렉션처럼 카드 격자 → 재생목록 화면 (맥·아이폰·아이패드 같게)
    var body: some View {
        if let embeddedQuery {
            // 둘러보기 탭에 끼운 모양 (탭이 큰 제목·찾기 칸·스크롤·정렬을 맡는다)
            Group {
                if preview { grid } else { actions(grid) }
            }
            .onChange(of: embeddedQuery, initial: true) { _, new in query = new }
        } else {
            LibraryStack {
                actions(
                    ScrollView {
                        VStack(alignment: .leading, spacing: 16) {
                            MacPageTitle("재생목록", inset: false)
                            grid
                        }
                        .padding(pagePadding)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .navigationTitle("재생목록")
                    // [정렬] [+] [찾기]
                    .pageSearchable($query, prompt: "재생목록에서 찾기") {
                        ToolbarItem(placement: .primaryAction) { BrowseSortMenu(page: "playlists") }
                    }
                )
            }
        }
    }

    /// 최근 추가순을 고를 때만 읽는다 (재생목록 항목마다 파일을 찾아서)
    private func loadAdded() {
        guard sort == .added else { return }
        added = Dictionary(uniqueKeysWithValues: playlists.lists.compactMap { list in
            LibraryData.latestAdded(fileKeys: list.items.map(\.key)).map { (list.id, $0) }
        })
    }

    private var grid: some View {
        cards
            .task(id: "\(sort.rawValue)|" + playlists.lists.map { "\($0.id):\($0.items.count)" }.joined(separator: ",")) { loadAdded() }
    }

    /// 재생목록 카드: 항목의 포스터 넷 (포스터가 없으면 영상 썸네일). 지우기는 길게 눌러서(맥은 오른쪽 클릭)
    @ViewBuilder
    private var cards: some View {
        if playlists.lists.isEmpty {
            ContentUnavailableView("재생목록이 없습니다", systemImage: "list.bullet.rectangle",
                                   description: Text("작품·회차의 ··· 메뉴에서 재생목록에 넣을 수 있습니다."))
                .frame(maxWidth: .infinity)
                .padding(.top, 80)
        } else if shown.isEmpty {
            ContentUnavailableView.search(text: query)
                .frame(maxWidth: .infinity)
                .padding(.top, 80)
        } else {
            LazyVGrid(columns: posterColumns(sizeClass), alignment: .leading, spacing: 22) {
                ForEach(shown) { list in
                    NavigationLink(value: PlaylistRoute(id: list.id)) {
                        PlaylistMosaicCard(list: list)
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button("이름 바꾸기…", systemImage: "pencil") { renaming = list }
                        Button("지우기", systemImage: "trash", role: .destructive) { playlists.remove(list.id) }
                    }
                }
            }
        }
    }

    /// [+] 새 재생목록, 재생목록 화면으로 가기
    private func actions(_ content: some View) -> some View {
        content
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("새 재생목록", systemImage: "plus") { naming = true }
                        .help("새 재생목록")
                }
            }
            .playlistNamePrompt(isPresented: $naming) { playlists.create($0) }
            .playlistRenamePrompt($renaming)
    }
}

/// 재생목록 카드: 항목의 포스터를 2×2 로 (포스터가 없는 영상은 썸네일)
struct PlaylistMosaicCard: View {
    let list: Playlists.List
    @State private var tiles: [MosaicCard.Tile] = []

    var body: some View {
        MosaicCard(title: list.name, subtitle: "\(list.items.count)개", tiles: tiles, symbol: "list.bullet.rectangle")
            .task(id: list.items) { tiles = LibraryData.playlistTiles(list.items) }
    }
}

/// 재생목록 안 항목 정렬: 직접 정한 순서(넣은 순서·편집에서 옮긴 순서) 또는 이름순
enum PlaylistItemSort: String, CaseIterable {
    case manual, name

    var title: String {
        switch self {
        case .manual: "직접 정한 순서"
        case .name: "이름순"
        }
    }
}

/// 재생목록 화면: 항목을 포스터 격자로 (누르면 재생). 도구 막대는 폴더 화면처럼 [정렬] [재생목록 편집] [찾기],
/// 이름·순서·빼기·지우기는 편집 창(아이폰·아이패드 시트, 맥 옆 패널)에서.
struct PlaylistDetail: View {
    /// 연 때의 재생목록 (이름을 바꾸거나 항목이 바뀌면 아래 list 가 새 값을 읽는다)
    private let opened: Playlists.List
    @State private var playlists = Playlists.shared
    @AppStorage("playlistItemSort") private var sort = PlaylistItemSort.manual
    @State private var query = ""
    @State private var editing = false
    /// 항목마다 카드 그림 (작품 포스터, 없으면 영상 썸네일)
    @State private var tiles: [String: MosaicCard.Tile] = [:]
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.stackHistory) private var history
    @Environment(\.dismiss) private var dismiss

    init(list: Playlists.List) {
        opened = list
    }

    private var list: Playlists.List { playlists.list(opened.id) ?? opened }

    /// 보이는 항목과 재생목록 안의 자리 (성인 등급 숨기기 중에는 숨긴 작품의 항목을 뺀다. 재생목록에서 지우지는 않는다)
    private var visible: [(index: Int, item: Playlists.Item)] {
        list.items.enumerated().filter { !LibraryData.isHidden(fileKey: $0.element.key) }.map { ($0.offset, $0.element) }
    }

    /// 찾기 글자에 맞는 항목 (정렬대로)
    private var shown: [(index: Int, item: Playlists.Item)] {
        let found = visible.filter { KoreanIndex.filter(query, $0.item.title) }
        return sort == .name ? found.sorted { KoreanIndex.precedes($0.item.title, $1.item.title) } : found
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                if shown.isEmpty {
                    emptyState
                        .frame(maxWidth: .infinity)
                        .padding(.top, 80)
                } else {
                    grid
                }
            }
            .padding(pagePadding)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle(list.name)
        #if os(macOS)
        .pageSearchable($query, prompt: "재생목록에서 찾기") {
            ToolbarItem(placement: .primaryAction) { sortMenu }
            ToolbarItem(placement: .primaryAction) { editButton }
        }
        #else
        // 폴더 화면처럼: 찾기 칸은 숨어 있다가 아래로 당기면 나온다
        .searchable(text: $query, placement: .drawer, prompt: "재생목록에서 찾기")
        // 바뀜 (2026-11-08): 아이폰은 라이브러리 화면처럼 (searchBarBehavior)
        .searchBarBehavior()
        .toolbar {
            ToolbarItem(placement: .primaryAction) { sortMenu }
            ToolbarItem(placement: .primaryAction) { editButton }
        }
        #endif
        .settingsPanel(isPresented: $editing) {
            PlaylistEditView(listID: list.id) {
                // 편집 창에서 재생목록을 지웠다: 창을 닫고 앞 화면으로
                editing = false
                if let history { history.goBack() } else { dismiss() }
            }
        }
        .task(id: list.items) {
            var found: [String: MosaicCard.Tile] = [:]
            for item in list.items where found[item.key] == nil {
                if let tile = LibraryData.playlistTiles([item]).first { found[item.key] = tile }
            }
            tiles = found
        }
    }

    /// 맥은 큰 제목 줄에, 아이폰·아이패드는 시스템 큰 제목 아래에 처음부터 재생
    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            #if os(macOS)
            Text(list.name).font(.largeTitle.bold()).lineLimit(2)
            Spacer()
            #endif
            Button { if let first = shown.first { play(from: first.index) } } label: {
                Label("처음부터 재생", systemImage: "play.fill")
                    .labelStyle(.titleAndIcon)
                    #if os(iOS)
                    .frame(maxWidth: .infinity)
                    #endif
            }
            .buttonStyle(.borderedProminent)
            #if os(iOS)
            .controlSize(.large)
            #endif
            .disabled(shown.isEmpty)
        }
    }

    private var grid: some View {
        LazyVGrid(columns: posterColumns(sizeClass), alignment: .leading, spacing: 22) {
            ForEach(shown, id: \.index) { entry in
                Button { play(from: entry.index) } label: {
                    MosaicCard(title: entry.item.title, subtitle: "", tiles: tiles[entry.item.key].map { [$0] } ?? [], symbol: "film")
                }
                .buttonStyle(.plain)
                .contextMenu {
                    Button("재생", systemImage: "play") { play(from: entry.index) }
                    Button("재생목록에서 빼기", systemImage: "minus.circle", role: .destructive) { remove(entry.index) }
                }
            }
        }
    }

    private var sortMenu: some View {
        Menu("정렬", systemImage: "arrow.up.arrow.down") {
            Picker("정렬", selection: $sort) {
                ForEach(PlaylistItemSort.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.inline)
        }
        .help("정렬")
    }

    /// 폴더 설정과 같은 자리·아이콘 (맥은 옆 패널을 열고 닫는다, 아이폰·아이패드는 시트)
    private var editButton: some View {
        Button("재생목록 편집", systemImage: "slider.horizontal.3") { editing.toggle() }
            .help("재생목록 편집")
    }

    /// 빈 재생목록·찾은 것 없음
    @ViewBuilder
    private var emptyState: some View {
        if visible.isEmpty {
            ContentUnavailableView("재생목록이 비어 있습니다", systemImage: "list.bullet.rectangle",
                                   description: Text("작품·회차의 ··· 메뉴에서 이 재생목록에 넣을 수 있습니다."))
        } else {
            ContentUnavailableView.search(text: query)
        }
    }

    private func remove(_ index: Int) {
        var items = list.items
        guard items.indices.contains(index) else { return }
        items.remove(at: index)
        Playlists.shared.setItems(items, of: list.id)
    }

    /// 그 항목부터 재생 (다음 항목은 플레이어의 재생목록에서 고른다)
    /// 다 보면 보이는 순서대로 다음 항목으로 이어진다 (찾지 못한 항목은 건너뛴다)
    private func play(from index: Int) {
        var files: [VideoFile] = []
        var start: Int?
        for entry in shown {
            guard let found = LibraryData.file(forKey: entry.item.key) else { continue }
            if entry.index == index { start = files.count }
            files.append(LibraryData.videoFile(found.file, in: found.library, title: entry.item.title))
        }
        guard let start else { return }
        PlayerHost.shared.play(files[start], resume: true, queue: PlayQueue.list(files, startingAt: start))
    }
}

/// 재생목록 편집 (폴더 설정 창처럼): 이름, 항목 순서 바꾸기·빼기, 재생목록 지우기. 바꾸는 대로 저장된다.
struct PlaylistEditView: View {
    let listID: String
    /// 재생목록을 지웠을 때 (부른 화면이 창을 닫고 앞 화면으로 간다)
    let onDeleted: () -> Void
    @State private var playlists = Playlists.shared
    @State private var name = ""
    @State private var confirmingDelete = false
    @Environment(\.dismiss) private var dismiss

    private var list: Playlists.List? { playlists.list(listID) }

    /// 숨긴 작품의 항목은 보이지 않게 (성인 등급 숨기기). 숨긴 항목이 있으면 순서 바꾸기는 막는다
    private var visible: [(index: Int, item: Playlists.Item)] {
        (list?.items ?? []).enumerated().filter { !LibraryData.isHidden(fileKey: $0.element.key) }.map { ($0.offset, $0.element) }
    }

    private var canMove: Bool { visible.count == list?.items.count }

    private var moveAction: ((IndexSet, Int) -> Void)? {
        guard canMove else { return nil }
        return { move($0, $1) }
    }

    var body: some View {
        #if os(macOS)
        shared(Form { sections }.formStyle(.grouped))
        #else
        shared(NavigationStack {
            Form { sections }
                .environment(\.editMode, .constant(.active))
                .navigationTitle("재생목록 편집")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("완료", systemImage: "checkmark") { dismiss() }
                    }
                }
        })
        #endif
    }

    /// 이름 저장·지우기 확인 (맥·아이폰·아이패드 같게)
    private func shared(_ content: some View) -> some View {
        content
            .onAppear { name = list?.name ?? "" }
            // 이름은 잠깐 뒤에 저장 (칠 때마다 iCloud 로 보내지 않게)
            .task(id: name) {
                try? await Task.sleep(for: .milliseconds(500))
                guard !Task.isCancelled else { return }
                saveName()
            }
            .onDisappear(perform: saveName)
            .confirmationDialog("‘\(list?.name ?? "")’ 재생목록을 지울까요?", isPresented: $confirmingDelete, titleVisibility: .visible) {
                Button("재생목록 지우기", role: .destructive) {
                    playlists.remove(listID)
                    onDeleted()
                }
            } message: {
                Text("영상 파일은 지워지지 않습니다.")
            }
    }

    @ViewBuilder
    private var sections: some View {
        Section("이름") {
            TextField("이름", text: $name, prompt: Text("재생목록 이름"))
        }
        Section {
            if visible.isEmpty {
                Text("항목이 없습니다").foregroundStyle(.secondary)
            }
            ForEach(visible, id: \.index) { entry in
                HStack {
                    Text(entry.item.title).lineLimit(2)
                    #if os(macOS)
                    Spacer()
                    // 맥은 목록 편집 상태가 없어 줄마다 빼기 단추
                    Button("빼기", systemImage: "minus.circle.fill") { remove([entry.index]) }
                        .labelStyle(.iconOnly)
                        .foregroundStyle(.red)
                        .buttonStyle(.borderless)
                        .help("재생목록에서 빼기")
                    #endif
                }
            }
            .onMove(perform: moveAction)
            .onDelete { offsets in remove(offsets.map { visible[$0].index }) }
        } header: {
            Text("항목")
        } footer: {
            #if os(macOS)
            Text(canMove ? "끌어서 순서를 바꿉니다." : "숨긴 작품이 들어 있어 순서를 바꿀 수 없습니다.")
            #else
            Text(canMove ? "오른쪽 손잡이를 끌어 순서를 바꿉니다." : "숨긴 작품이 들어 있어 순서를 바꿀 수 없습니다.")
            #endif
        }
        Section {
            Button("재생목록 지우기", role: .destructive) { confirmingDelete = true }
        }
    }

    private func saveName() {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard let list, !trimmed.isEmpty, trimmed != list.name else { return }
        playlists.rename(listID, to: trimmed)
    }

    private func move(_ source: IndexSet, _ destination: Int) {
        guard var items = list?.items else { return }
        items.move(fromOffsets: source, toOffset: destination)
        playlists.setItems(items, of: listID)
    }

    private func remove(_ indices: [Int]) {
        guard var items = list?.items else { return }
        for index in indices.sorted(by: >) where items.indices.contains(index) { items.remove(at: index) }
        playlists.setItems(items, of: listID)
    }
}

/// 재생목록에 넣기 메뉴 (작품·회차). "새 재생목록…" 은 메뉴가 닫히면 메뉴에 단 알림도 사라져서,
/// 이름 묻기는 화면 쪽(.newPlaylistPrompt)이 맡는다.
struct AddToPlaylistMenu: View {
    let items: [Playlists.Item]
    let onNew: ([Playlists.Item]) -> Void
    @State private var playlists = Playlists.shared

    var body: some View {
        Menu("재생목록에 추가", systemImage: "text.badge.plus") {
            ForEach(playlists.lists) { list in
                Button(list.name) { playlists.add(items, to: list.id) }
            }
            if !playlists.lists.isEmpty { Divider() }
            Button("새 재생목록…") { onNew(items) }
        }
        .disabled(items.isEmpty)
    }
}

extension View {
    /// 새 재생목록 이름을 묻고 만들어서 항목을 넣는다 (items 가 nil 이 아니면 묻는다)
    func newPlaylistPrompt(_ items: Binding<[Playlists.Item]?>) -> some View {
        modifier(NewPlaylistPrompt(items: items))
    }
}

private struct NewPlaylistPrompt: ViewModifier {
    @Binding var items: [Playlists.Item]?
    @State private var name = ""

    func body(content: Content) -> some View {
        content.playlistNamePrompt(isPresented: Binding(get: { items != nil }, set: { if !$0 { items = nil } })) { name in
            if let items { Playlists.shared.add(items, to: Playlists.shared.create(name)) }
        }
    }
}

extension View {
    /// 새 재생목록 이름 묻기. 아이폰·아이패드는 알림, 맥은 작은 시트 (맥 알림의 글자 칸은 여백·단추 모양이 어색하다)
    func playlistNamePrompt(isPresented: Binding<Bool>, onCreate: @escaping (String) -> Void) -> some View {
        modifier(PlaylistNamePrompt(isPresented: isPresented, title: "새 재생목록", confirm: "만들기", initial: "", onCreate: onCreate))
    }

    /// 재생목록 이름 바꾸기 (list 가 nil 이 아니면 묻는다)
    func playlistRenamePrompt(_ list: Binding<Playlists.List?>) -> some View {
        modifier(PlaylistNamePrompt(isPresented: Binding(get: { list.wrappedValue != nil }, set: { if !$0 { list.wrappedValue = nil } }),
                                    title: "재생목록 이름 바꾸기", confirm: "바꾸기", initial: list.wrappedValue?.name ?? "") { name in
            if let id = list.wrappedValue?.id { Playlists.shared.rename(id, to: name) }
        })
    }
}

private struct PlaylistNamePrompt: ViewModifier {
    @Binding var isPresented: Bool
    let title: String
    let confirm: String
    let initial: String
    let onCreate: (String) -> Void
    @State private var name = ""

    private var trimmed: String { name.trimmingCharacters(in: .whitespaces) }

    private func create() {
        if !trimmed.isEmpty { onCreate(trimmed) }
        name = ""
        isPresented = false
    }

    func body(content: Content) -> some View {
        #if os(macOS)
        content.sheet(isPresented: $isPresented, onDismiss: { name = "" }) {
            VStack(alignment: .leading, spacing: 16) {
                Text(title).font(.headline)
                TextField("이름", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(create)
                HStack {
                    Spacer()
                    Button("취소", role: .cancel) { name = ""; isPresented = false }
                        .keyboardShortcut(.cancelAction)
                    Button(confirm, action: create)
                        .keyboardShortcut(.defaultAction)
                        .disabled(trimmed.isEmpty)
                }
            }
            .padding(20)
            .frame(width: 320)
            .onAppear { name = initial }
        }
        #else
        content.alert(title, isPresented: $isPresented) {
            TextField("이름", text: $name)
            Button("취소", role: .cancel) { name = "" }
            Button(confirm, action: create)
        }
        .onChange(of: isPresented) { _, shown in if shown { name = initial } }
        #endif
    }
}
