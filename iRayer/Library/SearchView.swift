import SwiftUI

/// [검색] 탭: 라이브러리의 작품(제목·원제)과 인물, 모든 위치의 파일명(MediaIndex)으로 검색. 초성으로도 찾는다.
struct SearchView: View {
    @State private var query = ""
    @State private var files: [VideoFile] = []
    /// 라이브러리 작품·인물 중 찾은 것
    @State private var items: [LibraryData.ItemSummary] = []
    @State private var people: [LibraryData.PersonSummary] = []
    /// 라이브러리 작품·인물 전체 (화면을 열 때와 훑기가 끝날 때 다시 읽는다)
    @State private var catalog: (items: [LibraryData.ItemSummary], people: [LibraryData.PersonSummary]) = ([], [])
    @State private var searching = false
    @State private var index = MediaIndex.shared
    @State private var tmdb = TMDBSettings.shared
    /// "다른 곳에서 찾기"를 누른 검색어 (nil 이면 보관함 검색 화면). 검색어를 바꾸면 보관함 검색으로 돌아간다.
    @State private var tmdbQuery: String?
    /// TMDB 검색 결과
    @State private var tmdbTitles: [TMDBTitle] = []
    @State private var tmdbLoading = false
    @State private var tmdbError: String?
    @State private var tmdbSelection: TMDBTitle?
    @State private var history = StackHistory()
    @Environment(\.horizontalSizeClass) private var sizeClass

    /// 아이패드는 음악 앱처럼 화면 위쪽에 넓은 검색칸 (기본은 오른쪽 위 작은 칸)
    private var searchPlacement: SearchFieldPlacement {
        #if os(iOS)
        // 바뀜 (2026-11-08): 아이폰도 늘 제목 막대 아래 칸으로 — .automatic 은 검색한 뒤 스크롤하면 제목이 사라지고
        //   찾기 칸만 투명한 막대 아래 덩그러니 남았다 (사용자: 홈처럼 반투명 제목 막대 + 그 아래 찾기 칸)
        .navigationBarDrawer(displayMode: .always)
        #else
        // 바뀜 (2026-11-07): 맥은 라이브러리 화면처럼 도구 막대 오른쪽 (사용자)
        .toolbar
        #endif
    }

    /// 넓은 화면(아이패드·맥)은 보관함 결과를 포스터 격자로 (목록을 화면 폭으로 늘리면 휑하다)
    private var wide: Bool {
        #if os(macOS)
        true
        #else
        sizeClass == .regular
        #endif
    }

    /// 읽을거리 열기: 텍스트는 텍스트 뷰어, 압축 파일은 만화 (2026-11-08)
    static func openReading(_ file: VideoFile) async {
        if file.isText {
            await TextLauncher.shared.open(file)
        } else {
            await ComicLauncher.shared.open(file)
        }
    }

    var body: some View {
        AppNavigationStack(history: history) {
            Group {
                if wide && tmdbQuery == nil {
                    ScrollView {
                        wideLibraryResults
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                } else {
                    List {
                        if tmdbQuery != nil {
                            tmdbSections
                        } else {
                            librarySections
                        }
                    }
                }
            }
            .showsReturnHighlight(ids: files.map { AnyHashable($0.url) }, proxy: nil)
            .sheet(item: $tmdbSelection) { title in
                let found = libraryItem(title)
                TMDBDetailSheet(title: title, openInLibrary: found.map { item in
                    { history.path.append(BrowseItemRoute(libraryID: item.libraryID, key: item.key)) }
                })
            }
            .navigationTitle("검색")
            .searchable(text: $query, placement: searchPlacement, prompt: "제목, 인물, 파일명, 초성")
            #if os(macOS)
            // 찾기 칸이 빈 곳을 다 차지하지 않게 앞에 늘어나는 빈칸 (라이브러리 화면처럼 오른쪽, 2026-11-07)
            .toolbar { ToolbarSpacer(.flexible) }
            #endif
            #if os(iOS)
            // 아이패드: 검색칸을 눌러도 제목·검색칸이 위로 올라갔다 내려오지 않게 (음악 앱처럼 제자리)
            // 바뀜 (2026-11-08): 아이폰은 라이브러리 화면처럼 (searchBarBehavior)
            .searchBarBehavior()
            .navigationBarTitleDisplayMode(sizeClass == .regular ? .inline : .automatic)
            #endif
            .overlay {
                Group {
                if query.trimmingCharacters(in: .whitespaces).isEmpty {
                    ContentUnavailableView("검색", systemImage: "magnifyingglass",
                                           description: Text("작품 제목·인물·파일명으로 찾습니다. 초성(ㅂㅈ)으로도 찾을 수 있습니다."))
                } else if tmdbQuery != nil {
                    EmptyView()
                } else if searching && noResults {
                    ProgressView()
                } else if !searching && noResults {
                    ContentUnavailableView {
                        Label("‘\(trimmedQuery)’에 대한 결과 없음", systemImage: "magnifyingglass")
                    } description: {
                        Text("보관함에서 찾지 못했습니다.")
                    } actions: {
                        if canSearchTMDB {
                            Button("다른 곳에서 찾기", systemImage: "globe") {
                                Task { await searchTMDB() }
                            }
                            .buttonStyle(.glassProminent)
                        }
                    }
                }
                }
                // 결과 영역 크기와 상관없이 화면 가운데에 가로로 넉넉하게 (좁게 잡히면 글자가 한 줄에 한두 자씩 깨진다)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            // 입력이 멈추면 검색한다
            .task(id: query) {
                // 검색어가 바뀌면 보관함 검색으로 돌아간다
                if let tmdbQuery, tmdbQuery != trimmedQuery { closeTMDB() }
                // 기다리는 동안 "결과 없음"이 잠깐 보이지 않게
                searching = !query.trimmingCharacters(in: .whitespaces).isEmpty
                try? await Task.sleep(for: .milliseconds(350))
                guard !Task.isCancelled else { return }
                await search(query)
            }
            .task(id: LibraryScanner.shared.revision) {
                catalog = LibraryData.searchCatalog()
                await search(query)
            }
            .task {
                #if DEBUG
                // 테스트용 실행 인자 `-searchQuery <검색어>` (시뮬레이터 테스트 도구로는 검색창에 한글을 넣을 수 없어서)
                if query.isEmpty, let preset = UserDefaults.standard.string(forKey: "searchQuery") { query = preset }
                #endif
                // 파일명 검색용 목록이 비어 있으면 한 번 훑는다
                if index.files.isEmpty { await index.refresh() }
            }
            .locationDestinations()
            .libraryDestinations(history)
            .environment(\.inLibraryStack, true)
        }
    }

    private var noResults: Bool {
        files.isEmpty && items.isEmpty && people.isEmpty
    }

    /// TMDB 결과가 라이브러리에 있으면 그 작품
    private func libraryItem(_ title: TMDBTitle) -> LibraryData.ItemSummary? {
        LibraryData.item(tmdbID: title.id, isSeries: title.mediaType == "tv")
    }

    /// 보관함 검색 결과 (작품·인물·파일) + 맨 아래 "다른 곳에서 찾기"
    @ViewBuilder
    private var librarySections: some View {
        if !items.isEmpty {
            Section("작품") {
                ForEach(items) { item in
                    NavigationLink(value: BrowseItemRoute(libraryID: item.libraryID, key: item.key)) {
                        ItemRow(item: item)
                    }
                }
            }
        }
        if !people.isEmpty {
            Section("인물") {
                ForEach(people) { person in
                    NavigationLink(value: PersonRoute(key: person.key, name: person.name, photo: person.photo, nameOrigin: person.nameOrigin)) {
                        PersonRow(person: person)
                    }
                }
            }
        }
        if !files.isEmpty {
            Section("파일") {
                ForEach(files) { file in
                    if file.isArchive || file.isText {
                        Button {
                            Task { await Self.openReading(file) }
                        } label: {
                            BookRow(file: file)
                                .returnHighlight(file.url)
                        }
                        .buttonStyle(.plain)
                        .contextMenu { ReadingRecordMenu(file: file) }
                    } else {
                        NavigationLink(value: file) {
                            VideoRow(file: file)
                                .returnHighlight(file.url)
                        }
                    }
                }
            }
        }
        // 보관함 결과가 없으면 가운데 안내에 같은 버튼이 있다
        if canSearchTMDB && !searching && !noResults {
            Section {
                Button {
                    Task { await searchTMDB() }
                } label: {
                    Label("‘\(trimmedQuery)’ 다른 곳에서 찾기", systemImage: "globe")
                }
            } footer: {
                Text("TMDB 에서 찾아 볼 수 있는 곳(JustWatch 제공)을 보여줍니다.")
            }
        }
    }

    /// 넓은 화면의 보관함 결과: 작품은 포스터 격자, 인물은 동그라미 줄, 파일은 두세 칸 격자
    @ViewBuilder
    private var wideLibraryResults: some View {
        VStack(alignment: .leading, spacing: 28) {
            MacPageTitle("검색")
            if !items.isEmpty {
                resultSection("작품") {
                    LazyVGrid(columns: posterColumns(sizeClass), alignment: .leading, spacing: 22) {
                        ForEach(items) { item in
                            NavigationLink(value: BrowseItemRoute(libraryID: item.libraryID, key: item.key)) {
                                LibraryPosterCard(title: item.title, subtitle: item.year.map(String.init) ?? "", poster: item.poster,
                                                  badges: item.appleTV ? ["appletv.fill"] : [])
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal)
                }
            }
            if !people.isEmpty {
                resultSection("인물") {
                    PagingScrollView(margins: EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16)) {
                        ForEach(people) { person in
                            NavigationLink(value: PersonRoute(key: person.key, name: person.name, photo: person.photo, nameOrigin: person.nameOrigin)) {
                                PersonCard(name: person.name, photo: person.photo, detail: person.nameOrigin ?? "\(person.works)편", size: ShelfSize.person(sizeClass))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            if !files.isEmpty {
                resultSection("파일") {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 320), spacing: 16)], alignment: .leading, spacing: 4) {
                        ForEach(files) { file in
                            Group {
                                if file.isArchive || file.isText {
                                    Button {
                                        Task { await Self.openReading(file) }
                                    } label: {
                                        BookRow(file: file).returnHighlight(file.url)
                                    }
                                    .contextMenu { ReadingRecordMenu(file: file) }
                                } else {
                                    NavigationLink(value: file) {
                                        VideoRow(file: file).returnHighlight(file.url)
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                            .padding(.vertical, 6)
                            .contentShape(.rect)
                        }
                    }
                    .padding(.horizontal)
                }
            }
            if canSearchTMDB && !searching && !noResults {
                Button {
                    Task { await searchTMDB() }
                } label: {
                    Label("‘\(trimmedQuery)’ 다른 곳에서 찾기", systemImage: "globe")
                }
                .buttonStyle(.bordered)
                .padding(.horizontal)
            }
        }
        .padding(.vertical)
    }

    private func resultSection(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.title3.bold()).padding(.horizontal)
            content()
        }
    }

    /// "다른 곳에서 찾기" 결과 (TMDB)
    @ViewBuilder
    private var tmdbSections: some View {
        Section {
            Button {
                closeTMDB()
            } label: {
                Label("보관함 검색 결과로", systemImage: "chevron.backward")
            }
        }
        Section {
            if tmdbLoading {
                ProgressView().frame(maxWidth: .infinity)
            } else if let tmdbError {
                Text(tmdbError).foregroundStyle(.secondary)
            } else if tmdbTitles.isEmpty {
                Text("TMDB 에서 찾지 못했습니다.").foregroundStyle(.secondary)
            } else {
                ForEach(tmdbTitles) { title in
                    Button {
                        tmdbSelection = title
                    } label: {
                        TMDBRow(title: title, inLibrary: libraryItem(title) != nil)
                    }
                    .buttonStyle(.plain)
                }
            }
        } header: {
            Text("‘\(tmdbQuery ?? "")’ 다른 곳에서 찾기")
        } footer: {
            Text("TMDB 검색 결과입니다. 누르면 볼 수 있는 곳(JustWatch 제공)을 보여줍니다.")
        }
    }

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespaces)
    }

    /// TMDB 로 찾을 수 있는 검색어인지 (초성만 친 것은 TMDB 가 알아듣지 못한다)
    private var canSearchTMDB: Bool {
        tmdb.isActive && !trimmedQuery.isEmpty
            && !trimmedQuery.unicodeScalars.allSatisfy { (0x3131...0x314E).contains($0.value) || $0.properties.isWhitespace }
    }

    /// 완성된 검색어 하나로만 TMDB 를 부른다 (글자를 칠 때마다 부르지 않게)
    private func searchTMDB() async {
        let term = trimmedQuery
        guard !term.isEmpty else { return }
        tmdbQuery = term
        tmdbTitles = []
        tmdbError = nil
        tmdbLoading = true
        defer { tmdbLoading = false }
        do {
            let titles = try await TMDBClient.search(term)
            guard tmdbQuery == term else { return }
            tmdbTitles = titles
        } catch {
            guard tmdbQuery == term else { return }
            tmdbError = error.localizedDescription
        }
    }

    private func closeTMDB() {
        tmdbQuery = nil
        tmdbTitles = []
        tmdbError = nil
    }

    private func search(_ text: String) async {
        let term = text.trimmingCharacters(in: .whitespaces)
        guard !term.isEmpty else {
            files = []
            items = []
            people = []
            return
        }
        searching = true
        defer { searching = false }
        items = catalog.items.filter { item in
            KoreanIndex.matches(term, in: item.title) || item.titleOrigin.map { KoreanIndex.matches(term, in: $0) } == true
        }
        people = Array(catalog.people.filter { KoreanIndex.filter(term, $0.name, $0.nameOrigin) }.prefix(30))
        files = index.search(term)
    }
}

/// 검색 결과의 작품 한 줄: 포스터 + 제목 + 연도
private struct ItemRow: View {
    let item: LibraryData.ItemSummary

    var body: some View {
        HStack(spacing: 12) {
            CachedImage(url: item.poster.flatMap(URL.init(string:)))
                .frame(width: 44, height: 66)
                .background(.quaternary)
                .clipShape(.rect(cornerRadius: 4))
            VStack(alignment: .leading, spacing: 3) {
                Text(item.title).lineLimit(2)
                Text([item.year.map(String.init), item.isSeries ? "시리즈" : "영화"].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if item.appleTV { Image(systemName: "appletv.fill").font(.caption).foregroundStyle(.secondary) }
        }
        .contentShape(.rect)
    }
}

/// 검색 결과의 인물 한 줄: 동그란 사진 + 이름 + 작품 수
private struct PersonRow: View {
    let person: LibraryData.PersonSummary

    var body: some View {
        HStack(spacing: 12) {
            CachedImage(url: person.photo.flatMap(URL.init(string:)))
                .frame(width: 44, height: 44)
                .background(.quaternary)
                .clipShape(.circle)
            VStack(alignment: .leading, spacing: 3) {
                Text(person.name)
                Text([person.nameOrigin, "\(person.works)편"].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .contentShape(.rect)
    }
}

/// 검색 결과의 만화책 한 줄: 세로 표지 + 제목 + 읽은 정도
private struct BookRow: View {
    let file: VideoFile

    var body: some View {
        HStack(spacing: 12) {
            Group {
                if file.isText { TextCover() } else { ArchiveCover(file: file) }
            }
                .frame(width: 46, height: 68)
                .clipShape(.rect(cornerRadius: 6))
                .returnHighlightBorder(cornerRadius: 6)
                .frame(width: 120)
            VStack(alignment: .leading, spacing: 4) {
                Text(file.title)
                    .font(.body)
                    .lineLimit(2)
                Text(file.isText ? file.textSubtitle : file.readingSubtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .contentShape(.rect)
    }
}
