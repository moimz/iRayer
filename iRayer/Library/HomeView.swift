import SwiftUI

/// 홈: 이어보기, 라이브러리·폴더 바로가기, 최근 추가된 항목(라이브러리 작품 + 폴더 영상), 그 장르(1.0 의 최근 영화가 든 컬렉션처럼),
/// 라이브러리마다 최근 추가된 작품 포스터 줄("홈에 라이브러리 줄"을 켠 것), 즐겨찾기 인물, 재생목록
/// (라이브러리는 설정의 "홈에 표시"를 켠 것만, 라이브러리 밖 영상은 폴더 설정의 "홈에 표시"를 켠 폴더만)
struct HomeView: View {
    @State private var watch = WatchHistory.shared
    @State private var favorites = FavoritePeople.shared
    @State private var playlists = Playlists.shared
    @State private var libraries = LibraryStore.shared
    @State private var locations = LocationStore.shared
    @State private var index = MediaIndex.shared
    @State private var recent: [LibraryData.ItemSummary] = []
    /// 최근 추가된 항목이 속한 장르
    @State private var recentGenres: [LibraryData.GenreEntry] = []
    /// 라이브러리마다 최근 추가된 작품 (포스터 줄)
    @State private var libraryShelves: [(library: LibraryRecord, items: [LibraryData.ItemSummary])] = []
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        LibraryStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    MacPageTitle("홈", inset: false).padding(.horizontal, 20)
                    continueShelf
                    // 맥은 사이드바에 라이브러리·폴더가 다 있어서 홈에 다시 두지 않는다
                    #if !os(macOS)
                    locationShelf
                    #endif
                    recentShelf
                    if !recentGenres.isEmpty {
                        shelf("최근 추가된 항목의 장르") {
                            ForEach(recentGenres) { genre in
                                NavigationLink(value: ItemListRoute(source: .genre(genre.name), title: genre.name)) {
                                    MosaicCard(title: genre.name, subtitle: "\(genre.count)편", posters: genre.posters)
                                        .frame(width: posterWidth)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    ForEach(libraryShelves, id: \.library.id) { shelf in
                        self.shelf("최근 추가된 \(shelf.library.name)") {
                            ForEach(shelf.items) { item in
                                NavigationLink(value: BrowseItemRoute(libraryID: item.libraryID, key: item.key)) {
                                    LibraryPosterCard(title: item.title, subtitle: [item.year.map(String.init), item.isSeries ? "\(item.files)편" : nil]
                                                        .compactMap { $0 }.joined(separator: " · "), poster: item.poster,
                                                      badges: item.appleTV ? ["appletv.fill"] : [])
                                        .frame(width: posterWidth)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    if !favorites.visiblePeople.isEmpty {
                        shelf("즐겨찾기 인물") {
                            ForEach(favorites.visiblePeople) { person in
                                NavigationLink(value: PersonRoute(key: person.key, name: person.name, photo: person.photo)) {
                                    PersonCard(name: person.name, photo: person.photo, detail: nil, size: personSize)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    if !playlists.lists.isEmpty {
                        shelf("재생목록") {
                            ForEach(playlists.lists) { list in
                                NavigationLink(value: PlaylistRoute(id: list.id)) {
                                    PlaylistCard(list: list)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
                .padding(.vertical, 20)
                // 선반이 하나도 없을 때도 화면 폭을 다 쓴다 (맥에서 내용 폭만큼 좁아져 안내가 세로로 길게 갇히던 것)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .navigationTitle("홈")
            .overlay {
                if recent.isEmpty && continueItems.isEmpty && libraries.libraries.isEmpty {
                    ContentUnavailableView("홈에 보일 것이 없습니다", systemImage: "house",
                                           description: Text("설정 → 라이브러리에서 라이브러리를 추가하세요."))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            // 맥은 보기 메뉴의 "새로 고침"(⌘R)과 앱으로 돌아올 때
            .appRefreshable { await reload() }
            .locationDestinations()
        }
        .task(id: [String(LibraryScanner.shared.revision)] + libraries.libraries.map { "\($0.id)\($0.showsOnHome)\($0.homeShelf)\($0.name)" }) { reload() }
    }

    private func reload() {
        let ids = libraries.homeLibraryIDs
        recent = LibraryData.recentItems(libraries: ids)
        recentGenres = LibraryData.genreCards(of: recent)
        libraryShelves = libraries.libraries.filter { $0.showsOnHome && $0.homeShelf }.compactMap { library in
            let items = LibraryData.recentItems(libraries: [library.id])
            return items.isEmpty ? nil : (library, items)
        }
        // 폴더 영상 목록이 아직 없으면 한 번 훑는다 ("홈에 표시"를 켠 폴더만)
        if index.files.isEmpty { Task { await index.refresh() } }
    }

    // MARK: - 최근 추가된 항목

    /// 최근 추가된 항목 하나: 라이브러리 작품 또는 폴더 영상 (1.0 처럼 섞어서 들어온 순서로)
    private enum RecentEntry: Identifiable {
        case item(LibraryData.ItemSummary)
        case file(VideoFile)

        var id: String {
            switch self {
            case .item(let item): item.key
            case .file(let file): file.url.absoluteString
            }
        }

        var date: Date {
            switch self {
            case .item(let item): item.added ?? .distantPast
            case .file(let file): file.modifiedAt
            }
        }
    }

    /// 라이브러리 작품 + "홈에 표시"를 켠 폴더의 최근 영상 (라이브러리에 든 파일은 작품으로 이미 나오니 뺀다)
    private var recentEntries: [RecentEntry] {
        let files = index.recent(limit: 20).filter { LibraryData.file(forKey: $0.stateKey) == nil }
        return Array((recent.map(RecentEntry.item) + files.map(RecentEntry.file)).sorted { $0.date > $1.date }.prefix(20))
    }

    /// 1.0 처럼 가로형(16:9) 카드: 작품은 배경 그림, 폴더 영상은 영상에서 뜬 썸네일
    @ViewBuilder
    private var recentShelf: some View {
        let entries = recentEntries
        if !entries.isEmpty {
            shelf("최근 추가된 항목") {
                ForEach(entries) { entry in
                    switch entry {
                    case .item(let item):
                        NavigationLink(value: BrowseItemRoute(libraryID: item.libraryID, key: item.key)) {
                            WideCard(title: item.title, subtitle: [item.year.map(String.init), item.appleTV ? "Apple TV" : nil]
                                        .compactMap { $0 }.joined(separator: " · "), progress: nil) {
                                CachedImage(url: TMDBClient.resized(item.backdrop ?? item.poster, to: "w780"))
                            }
                        }
                        .buttonStyle(.plain)
                    case .file(let file):
                        NavigationLink(value: file) {
                            WideCard(title: file.title, subtitle: file.size.fileSizeText, progress: nil) {
                                FileThumbnail(file: file)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    // MARK: - 이어보기

    private enum ContinueItem: Identifiable {
        /// 보다 만 영상 (라이브러리 파일이면 작품·회차 정보)
        case watching(WatchEntry, LibraryInfo?)
        /// 보다 만 만화책
        case reading(WatchEntry)
        /// 끝까지 본 회차의 다음 회차
        case next(WatchEntry, library: LibraryRecord, file: LibraryData.FileEntry, item: LibraryData.ItemDetail, episode: LibraryData.EpisodeEntry?)

        typealias LibraryInfo = (item: LibraryData.ItemDetail, file: LibraryData.FileEntry, episode: LibraryData.EpisodeEntry?)

        var id: String {
            switch self {
            case .watching(let entry, _), .reading(let entry): entry.id
            case .next(let entry, _, let file, _, _): "\(entry.id)>\(file.id)"
            }
        }

        var entry: WatchEntry {
            switch self {
            case .watching(let entry, _), .reading(let entry), .next(let entry, _, _, _, _): entry
            }
        }
    }

    private var continueItems: [ContinueItem] {
        let homeLibraries = Set(libraries.homeLibraryIDs)
        let options = FolderOptionsStore.shared
        let started = Set(watch.entries.map(\.id))
        var items: [ContinueItem] = []
        for entry in watch.entries {
            // 라이브러리 파일은 그 라이브러리의 "홈에 표시", 아니면 폴더의 "홈에 표시"
            let found = LibraryData.file(forKey: entry.id)
            if let found {
                guard homeLibraries.contains(found.library.id), !LibraryData.isHidden(fileKey: entry.id) else { continue }
            } else if !options.showsOnHome(entry.file) || options.isHiddenForAdult(entry.file) {
                continue
            }
            if !entry.finished {
                guard PlaybackStateStore.shared.state(for: entry.id).position > 0 else { continue }
                // 바뀜 (2026-11-08): 텍스트도 읽을거리 (이어 보기에만)
                items.append(entry.file.isArchive || entry.file.isText ? .reading(entry) : .watching(entry, LibraryData.itemInfo(forKey: entry.id)))
            } else if let next = LibraryData.nextEpisode(afterKey: entry.id), let hash = next.file.hash,
                      !started.contains("#\(hash)|\(next.file.size)") {
                items.append(.next(entry, library: next.library, file: next.file, item: next.item, episode: next.episode))
            }
            if items.count >= 20 { break }
        }
        return items
    }

    @ViewBuilder
    private var continueShelf: some View {
        let items = continueItems
        if !items.isEmpty {
            shelf("이어보기") {
                ForEach(items) { item in
                    Button { Task { await play(item) } } label: { continueCard(item) }
                        .buttonStyle(.plain)
                        .contextMenu {
                            ContinueGoMenu(item: item)
                            // 바뀜 (2026-11-11, 사용자): 다 본 것으로 표시 (시리즈면 이 자리에 다음 화가 나온다)
                            if case .watching(let entry, _) = item {
                                Button("다 본 것으로 표시", systemImage: "checkmark") { LibraryData.markWatched(entry.file) }
                            }
                            Button("이어보기에서 빼기", systemImage: "minus.circle") { watch.remove(item.entry.id) }
                            if case .reading(let entry) = item { ReadingRecordMenu(file: entry.file) }
                        }
                }
            }
        }
    }

    @ViewBuilder
    private func continueCard(_ item: ContinueItem) -> some View {
        switch item {
        case .reading(let entry):
            BookCard(file: entry.file)
        case .watching(let entry, let info):
            let state = PlaybackStateStore.shared.state(for: entry.id)
            WideCard(title: info?.item.title ?? entry.file.title,
                     subtitle: [episodeLabel(info?.file), state.duration > 0 ? "\((state.duration - state.position).durationText) 남음" : nil]
                        .compactMap { $0 }.joined(separator: " · "),
                     progress: state.duration > 0 ? min(state.position / state.duration, 1) : nil) {
                if let artwork = info.flatMap({ $0.episode?.still ?? $0.item.backdrop ?? $0.item.poster }) {
                    CachedImage(url: TMDBClient.resized(artwork, to: "w780"))
                } else {
                    FileThumbnail(file: entry.file)
                }
            }
        case .next(_, _, let file, let item, let episode):
            WideCard(title: item.title, subtitle: ["다음 화", episodeLabel(file)].compactMap { $0 }.joined(separator: " · "), progress: nil) {
                CachedImage(url: TMDBClient.resized(episode?.still ?? item.backdrop ?? item.poster, to: "w780"))
            }
        }
    }

    private func episodeLabel(_ file: LibraryData.FileEntry?) -> String? {
        guard let file, let episode = file.episode else { return nil }
        return file.season == 0 ? "스페셜 \(episode)화" : "시즌 \(file.season ?? 1) · \(episode)화"
    }

    private func play(_ item: ContinueItem) async {
        switch item {
        case .reading(let entry):
            if entry.file.isText {
                await TextLauncher.shared.open(entry.file)
            } else {
                await ComicLauncher.shared.open(entry.file)
            }
        case .watching(let entry, _):
            // 라이브러리 파일은 지금 위치로 다시 찾는다 (옮겼어도 해시로 찾는다)
            if let found = LibraryData.file(forKey: entry.id) {
                PlayerHost.shared.play(LibraryData.videoFile(found.file, in: found.library, title: entry.file.displayTitle), resume: true)
            } else {
                PlayerHost.shared.play(entry.file, resume: true)
            }
        case .next(_, let library, let file, let item, _):
            PlayerHost.shared.play(LibraryData.videoFile(file, in: library, title: LibraryData.playTitle(item, file)), resume: false)
        }
    }

    // MARK: - 바로가기

    /// 라이브러리와 폴더 바로가기 (아이폰·아이패드)
    private var locationShelf: some View {
        shelf("바로가기") {
            ForEach(libraries.libraries) { library in
                NavigationLink(value: LibraryRoute(id: library.id)) {
                    LocationCard(title: library.name, systemImage: library.symbol)
                }
                .buttonStyle(.plain)
            }
            if locations.showsThisDevice {
                NavigationLink(value: FolderRoute(url: locations.documentsURL, title: LocationStore.thisDeviceName)) {
                    LocationCard(title: LocationStore.thisDeviceName, systemImage: LocationStore.thisDeviceIcon)
                }
                .buttonStyle(.plain)
            }
            ForEach(locations.shownFolders) { folder in
                if let url = locations.resolve(folder) {
                    NavigationLink(value: FolderRoute(url: url, title: folder.name, location: .folder(folder.id))) {
                        LocationCard(title: folder.name, systemImage: folder.symbol)
                    }
                    .buttonStyle(.plain)
                }
            }
            ForEach(locations.servers) { server in
                ForEach(locations.shownFavorites(of: server.id)) { favorite in
                    NavigationLink(value: FolderRoute(url: favorite.url, title: favorite.name, serverID: server.id, location: .favorite(favorite.id))) {
                        LocationCard(title: favorite.name, systemImage: favorite.symbol)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: - 선반

    private func shelf(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.title2.bold())
                .padding(.horizontal, shelfInset)
            // 맥은 마우스를 올리면 좌우 화살표
            PagingScrollView(margins: EdgeInsets(top: 0, leading: shelfInset, bottom: 0, trailing: shelfInset)) { content() }
        }
    }

    private var posterWidth: CGFloat { ShelfSize.poster(sizeClass) }
    private var personSize: CGFloat { ShelfSize.person(sizeClass) }

    private var shelfInset: CGFloat {
        #if os(macOS)
        20
        #else
        16
        #endif
    }
}

/// 가로형(16:9) 카드: 그림 + 진행률 + 제목 + 보조 줄
private struct WideCard<Artwork: View>: View {
    let title: String
    let subtitle: String
    let progress: Double?
    @ViewBuilder let artwork: Artwork

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Color.clear
                .frame(width: 240, height: 135)
                .background(.quaternary)
                .overlay { artwork }
                .overlay(alignment: .bottom) {
                    if let progress { ProgressBar(fraction: progress) }
                }
                .clipShape(.rect(cornerRadius: 8))
            Text(title).cardTitleFont().lineLimit(1)
            Text(subtitle).cardSubtitleFont().foregroundStyle(.secondary).lineLimit(1)
        }
        .frame(width: 240)
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
    }
}

/// 만화책 카드 (이어보기): 세로 표지. 그림 높이는 가로형 카드와 같다.
private struct BookCard: View {
    let file: VideoFile

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Group {
                if file.isText { TextCover() } else { ArchiveCover(file: file) }
            }
                .frame(width: 90, height: 135)
                .overlay(alignment: .bottom) {
                    if let progress = file.readingProgress { ProgressBar(fraction: progress) }
                }
                .clipShape(.rect(cornerRadius: 8))
            MarqueeText(text: file.title)
                .cardTitleFont()
            Text(file.isText ? file.textSubtitle : file.readingSubtitle)
                .cardSubtitleFont()
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(width: 90)
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
    }
}

/// 바로가기 카드
private struct LocationCard: View {
    let title: String
    let systemImage: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: systemImage)
                .font(.title2)
                .foregroundStyle(.tint)
            Text(title)
                .font(.subheadline)
                .lineLimit(1)
        }
        .frame(width: 130, height: 76, alignment: .leading)
        .padding(.horizontal, 12)
        .background(.quaternary.opacity(0.6), in: .rect(cornerRadius: 12))
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
    }
}

/// 재생목록 카드: 이름 + 항목 수
private struct PlaylistCard: View {
    let list: Playlists.List

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: "list.bullet.rectangle")
                .font(.title2)
                .foregroundStyle(.tint)
            Text(list.name)
                .font(.subheadline)
                .lineLimit(1)
            Text("\(list.items.count)개")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(width: 150, height: 90, alignment: .leading)
        .padding(.horizontal, 12)
        .background(.quaternary.opacity(0.6), in: .rect(cornerRadius: 12))
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
    }
}

extension HomeView {
    /// 이어보기 카드를 꾹 눌렀을 때: 라이브러리 작품이면 작품 화면(시리즈는 그 회차의 시즌), 아니면 그 영상이 든 폴더
    private struct ContinueGoMenu: View {
        let item: ContinueItem
        @Environment(\.stackHistory) private var history

        var body: some View {
            if let route {
                Button("작품 화면으로", systemImage: "info.circle") {
                    history?.path.append(route)
                }
            } else {
                let file = item.entry.file
                let folder = file.url.deletingLastPathComponent()
                Button("폴더로 가기", systemImage: "folder") {
                    history?.path.append(FolderRoute(url: folder, title: folder.lastPathComponent.removingPercentEncoding ?? folder.lastPathComponent,
                                                     serverID: file.serverID))
                }
            }
        }

        /// 라이브러리 작품 화면 (시리즈 회차면 그 시즌)
        private var route: BrowseItemRoute? {
            switch item {
            case .watching(_, let info):
                guard let info, let key = info.file.itemKey else { return nil }
                return BrowseItemRoute(libraryID: info.file.libraryID, key: key, season: info.item.isSeries ? info.file.season : nil)
            case .next(_, let library, let file, let detail, _):
                return BrowseItemRoute(libraryID: library.id, key: detail.key, season: detail.isSeries ? file.season : nil)
            case .reading:
                return nil
            }
        }
    }
}
