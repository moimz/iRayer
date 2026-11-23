import SwiftUI

/// 라이브러리 작품 화면: 배경 그림·정보·출연진, 영화는 이어보기와 파일, 시리즈는 이어 볼 회차와 시즌별 회차 카드(가로로 넘김)
struct LibraryItemView: View {
    let library: LibraryRecord
    let itemKey: String
    /// 처음에 보여 줄 시즌 (없으면 이어 볼 회차의 시즌)
    var initialSeason: Int? = nil
    @State private var detail: LibraryData.ItemDetail?
    @State private var files: [LibraryData.FileEntry] = []
    @State private var episodes: [LibraryData.EpisodeEntry] = []
    @State private var season: Int?
    /// 이 작품의 Apple TV 구입작 (재생은 Apple TV 앱에서)
    @State private var purchases: [AppleTVLibrary.Movie] = []
    /// 이 작품이 든 컬렉션의 작품들 (1.0 처럼 작품 화면 아래에)
    @State private var collection: [LibraryData.ItemSummary] = []
    /// 이 작품의 장르 카드 (1.0 의 컬렉션처럼 포스터를 겹친 묶음)
    @State private var genres: [LibraryData.GenreEntry] = []
    /// 새 재생목록에 넣을 항목 (이름을 묻는 동안)
    @State private var newPlaylistItems: [Playlists.Item]?
    @State private var watch = WatchHistory.shared
    @State private var refreshing = false
    /// 매칭 고치기 (다른 작품으로 다시 매칭)
    @State private var rematching = false
    /// 회차 찾기 (시즌 줄 오른쪽): 찾은 회차로 넘기고 잠깐 강조한다. Return 은 다음으로 맞는 회차
    @State private var episodeQuery = ""
    @State private var episodeHit = 0
    @State private var highlightedEpisode: String?
    /// 회차 줄을 넘겨 보일 카드 순번 (회차 찾기·이어 볼 회차)
    @State private var episodeScroll: Int?
    /// 회차 칸 위쪽 끝의 화면 내용 안 위치 (찾기 칸 포커스 때 여기를 위로)
    @State private var episodesTop: CGFloat = 0
    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        Group {
            if let detail {
                DetailPage(playEnabled: upNext != nil || !purchases.isEmpty, onPlay: playFirst) {
                    CachedImage(url: TMDBClient.resized(detail.backdrop ?? detail.poster, to: "original"))
                } content: {
                    info(detail)
                    if detail.isSeries { seasonsSection } else if !files.isEmpty { filesSection }
                    if !detail.credits.isEmpty { creditsSection(detail) }
                    if collection.count > 1, let name = detail.collectionName, let id = detail.collectionID {
                        itemShelf(name, more: ItemListRoute(source: .collection(id), title: name), items: collection)
                    }
                    if !genres.isEmpty { genreSection }
                }
            } else {
                ProgressView()
            }
        }
        .navigationTitle(detail?.title ?? "")
        .toolbar {
            // 맥: ‹ › 다음은 비우고 단추는 오른쪽에 (2026-11-07, 사용자)
            #if os(macOS)
            ToolbarSpacer(.flexible)
            #endif
            ToolbarItemGroup {
                // 메타데이터 새로 고침 (나중에 매칭 고치기·직접 찾기가 생기면 그 메뉴가 된다)
                // 바뀜 (2026-11-08): 단추를 뱅글이로 바꿔 끼우면 도구 막대 묶음 크기가 바뀌어 뱅글이가 묶음 밖으로 삐져나왔다 (사용자) —
                //   단추는 그대로 두고 그림만 뱅글이로 바꾸고 누름을 끈다
                // 바뀜 (2026-11-08): 그림을 뱅글이로 바꾸거나 누름을 꺼도 단추가 묶음에서 떨어졌다 붙었다 (사용자) → 단추·그림은 그대로,
                //   새로 고침 화살표만 도는 효과로. 도는 동안 다시 눌러도 무시
                Button {
                    guard !refreshing else { return }
                    Task { await refreshMetadata() }
                } label: {
                    Label {
                        Text("메타데이터 새로 고침")
                    } icon: {
                        // 바뀜 (2026-11-08, 사용자): 도는 동안은 그림을 로딩 그림(progress.indicator)으로 바꿔 돌린다 (같은 그림 칸이라 묶음이 안 흔들림)
                        // 바뀜 (2026-11-08): 통째로 돌리면 크고 어색하고, 끝나면 화살표가 남은 회전을 마저 돌았다 (사용자) →
                        //   돌리지 않고 맥 뱅글이처럼 점이 차례로 밝아지게(variableColor), 그림은 조금 작게
                        Image(systemName: refreshing ? "progress.indicator" : "arrow.clockwise")
                            .symbolEffect(.variableColor.iterative.dimInactiveLayers.nonReversing,
                                          options: .repeat(.continuous), isActive: refreshing)
                            // 바뀜 (2026-11-08): imageScale(.medium) 이 도구 막대 기본보다 작아 평소 화살표도 작아졌다 (사용자) → 도는 동안만 조금 줄인다
                            .scaleEffect(refreshing ? 0.85 : 1)
                    }
                }
                .help(refreshing ? "새로 고치는 중" : "에이전트에게 이 작품의 정보를 다시 받습니다")
                .disabled(detail == nil)
                // 매칭 고치기: 찾지 못한 파일 직접 찾기와 같은 화면으로 이 작품의 파일을 (사용자 2026-11-07)
                Button("메타데이터 찾기", systemImage: "magnifyingglass") { rematching = true }
                    .help("다른 작품으로 다시 매칭합니다")
                    .disabled(detail == nil || files.isEmpty)
                AddToPlaylistMenu(items: playlistItems(files)) { newPlaylistItems = $0 }
            }
        }
        .newPlaylistPrompt($newPlaylistItems)
        .sheet(isPresented: $rematching) {
            UnmatchedView(library: library,
                          rematch: .init(files: files, query: detail?.title ?? "", year: detail?.year)) {
                LibraryScanner.shared.refreshViews()
                Task {
                    await load()
                    // 다른 작품으로 옮겨 이 작품에 파일이 없으면 화면을 닫는다
                    if files.isEmpty && purchases.isEmpty { dismiss() }
                }
            }
        }
        .task { await load() }
    }

    // MARK: - 정보

    private func info(_ detail: LibraryData.ItemDetail) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            // 아이폰은 화면이 좁아 한 단계 작게
            Text(detail.title).font(sizeClass == .compact ? .title.bold() : .largeTitle.bold())
            // 등급·연도·장르는 줄을 바꾸지 않고 한 줄 (넘치면 옆으로 밀어 본다)
            ScrollView(.horizontal) {
              HStack(spacing: 0) {
                // 관람등급 (테두리 작은 글자, Apple TV 앱처럼)
                if let rating = LibraryData.ratingLabel(detail.rating) {
                    Text(rating)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(.secondary, lineWidth: 1))
                        .padding(.trailing, 8)
                }
                let meta = [detail.year.map(String.init), detail.genres.isEmpty ? nil : detail.genres.joined(separator: " · ")].compactMap { $0 }
                Text(meta.joined(separator: "  ·  ")).foregroundStyle(.secondary)
                    .lineLimit(1)
              }
            }
            .scrollIndicators(.hidden)
            // 컬렉션은 따로 한 줄, 누르면 그 컬렉션의 작품 목록으로
            if let name = detail.collectionName, let id = detail.collectionID {
                NavigationLink(value: ItemListRoute(source: .collection(id), title: name)) {
                    Label(name, systemImage: "square.stack")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tint)
            }
            if let origin = detail.titleOrigin, origin != detail.title {
                Text(origin).font(.callout).foregroundStyle(.secondary)
            }
            if detail.isSeries {
                seriesResume
            } else if let file = files.first {
                ResumeControls(state: PlaybackStateStore.shared.state(for: key(file)), watched: watched(file)) {
                    play(file, resume: true)
                } restart: {
                    play(file, resume: false)
                } markWatched: {
                    markWatched(file)
                } unwatch: {
                    videoFile(file).clearPlaybackRecord()
                }
                .padding(.top, 4)
            }
            ForEach(purchases) { movie in
                Button {
                    Task { await AppleTVLibrary.shared.open(movie) }
                } label: {
                    Label("Apple TV 에서 보기", systemImage: "appletv.fill")
                        .padding(.horizontal, 6)
                }
                .buttonStyle(.glassProminent)
                .controlSize(.large)
                .padding(.top, 4)
            }
            if let summary = detail.summary, !summary.isEmpty {
                Text(summary).font(.body).textSelection(.enabled).padding(.top, 4)
            }
        }
    }

    /// 시리즈: 이어 볼 회차 단추 (보다 만 회차는 이어서, 끝까지 봤으면 다음 회차, 본 적 없으면 첫 회차)
    @ViewBuilder
    private var seriesResume: some View {
        if let next = upNext {
            Button { play(next.file, resume: next.resume) } label: {
                Label("\(next.resume ? "이어서 보기" : "재생") · \(episodeLabel(next.file))", systemImage: "play.fill")
                    .padding(.horizontal, 6)
            }
            .buttonStyle(.glassProminent)
            .controlSize(.large)
            .padding(.top, 4)
        }
    }

    // MARK: - 영화: 파일

    private var filesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("파일").font(.title3.bold())
            ForEach(files) { file in
                Button { play(file, resume: true) } label: {
                    HStack {
                        Image(systemName: "play.circle")
                        VStack(alignment: .leading, spacing: 2) {
                            Text(file.name).lineLimit(1).truncationMode(.middle)
                            Text(LibraryData.formatLine(file)).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .padding(.vertical, 4)
            }
        }
    }

    // MARK: - 시리즈: 시즌·회차

    private var seasons: [Int] {
        Array(Set(files.compactMap(\.season))).sorted { ($0 == 0 ? Int.max : $0) < ($1 == 0 ? Int.max : $1) }
    }

    // 바뀜 (2026-11-07): 시즌 줄 오른쪽에 회차 찾기 칸 (무한도전처럼 한 시즌에 수백 회, 사용자). 전체는 그대로 두고
    //   찾은 회차로 애니메이션 없이 바로 넘긴다 (지나가는 카드를 만들지 않게). 숫자는 회차 번호(없으면 가장 가까운 회차), 글자는 제목·파일 이름
    private var seasonsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            let current = season ?? seasons.first
            let title = current.map(seasonTitle) ?? "에피소드"
            let shown = files.filter { $0.season == current }
            HStack(spacing: 12) {
            // 1.0 처럼 제목 모양의 메뉴: "시즌 1 ⌄" 를 누르면 시즌을 고른다 (시즌이 하나면 제목만)
            if seasons.count > 1 {
                Menu {
                    Picker("시즌", selection: Binding(get: { current ?? 0 }, set: { season = $0 })) {
                        ForEach(seasons, id: \.self) { Text(seasonTitle($0)).tag($0) }
                    }
                    // 맥은 메뉴 속 Picker 를 하위 메뉴로 한 번 더 감싸므로 바로 펼친다
                    .pickerStyle(.inline)
                    .labelsHidden()
                } label: {
                    HStack(spacing: 4) {
                        Text(title).font(.title3.bold())
                        Image(systemName: "chevron.down").font(.caption.weight(.semibold))
                    }
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
            } else {
                Text(title).font(.title3.bold())
            }
                Spacer(minLength: 8)
                if shown.count > 1 {
                    episodeSearchField(shown)
                }
            }
            // 회차는 가로로 넘겨 본다. 이어 볼 회차 자리로 넘겨 둔다.
                BleedingRow(scrollTarget: $episodeScroll) {
                    ForEach(shown) { file in
                        episodeCard(file)
                    }
                }
                // 첫 회차면 그대로 둔다 (넘기면 앞 여백이 사라진다)
                .onAppear {
                    if let next = upNext?.file, next.path != shown.first?.path,
                       let index = shown.firstIndex(where: { $0.path == next.path }) { episodeScroll = index }
                }
                // 시즌을 바꾸면 줄을 새로 만들어 그 시즌 첫 회차부터
                .id(current)
        }
        // 찾기 칸에 포커스가 가면 이 칸 위쪽 끝을 화면 위쪽 막대 바로 아래로 (그 아래로 회차 줄을 보이는 만큼): 내용 안 위치를 재 둔다
        .onGeometryChange(for: CGFloat.self) { $0.frame(in: .named(PageScroll.space)).minY } action: { episodesTop = $0 }
    }

    /// 회차 찾기 칸: 치는 대로 첫 회차로, Return 은 다음 회차로
    private func episodeSearchField(_ shown: [LibraryData.FileEntry]) -> some View {
        HStack(spacing: 4) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary).font(.callout)
            TextField("회차 찾기", text: $episodeQuery)
                .textFieldStyle(.plain)
                #if os(iOS)
                .submitLabel(.search)
                // 키보드가 올라오면 iOS 는 찾기 칸까지만 올려 회차 줄이 키보드에 가렸다 → 회차 칸을 위쪽 막대 바로 아래로 (사용자 2026-11-07)
                // 바뀜 (2026-11-07): 아래 끝을 키보드 위에 맞추던 것은 가로 모드에서 찾기 칸이 위로 밀려 가렸다
                .modifier(RevealOnFocus(top: episodesTop))
                #endif
                .onSubmit {
                    episodeHit += 1
                    jumpToEpisode(shown)
                }
            if !episodeQuery.isEmpty {
                Button("지우기", systemImage: "xmark.circle.fill") { episodeQuery = "" }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        // 바뀜 (2026-11-07): 1.5 배 넓게 (사용자)
        .frame(width: sizeClass == .compact ? 210 : 300)
        .background(.fill.tertiary, in: .capsule)
        .onChange(of: episodeQuery) {
            episodeHit = 0
            jumpToEpisode(shown)
        }
    }

    /// 찾는 말에 맞는 회차로 넘긴다 (숫자: 그 번호, 없으면 가장 가까운 번호 / 글자: 제목·파일 이름에 든 것, 초성도)
    private func jumpToEpisode(_ shown: [LibraryData.FileEntry]) {
        let query = episodeQuery.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else {
            highlightedEpisode = nil
            return
        }
        var hits: [LibraryData.FileEntry]
        // 바뀜 (2026-11-07): "10."·"10화"·"E10"·"EP10"·"제10회" 처럼 번호 앞뒤의 장식은 떼고 번호로 ("10." 이 글자로 찾아져 안 됐다)
        if let match = query.wholeMatch(of: #/(?i)(?:제|e|ep\.?)?\s*(\d+)\s*(?:화|회|\.)?/#), let number = Int(match.1) {
            let exact = shown.filter { $0.episode == number }
            hits = exact.isEmpty
                ? Array(shown.filter { $0.episode != nil }.sorted { abs($0.episode! - number) < abs($1.episode! - number) }.prefix(1))
                : exact
        } else {
            hits = shown.filter { file in
                let info = episodes.first { $0.season == file.season && $0.episode == file.episode }
                return KoreanIndex.matches(query, in: info?.title ?? "") || KoreanIndex.matches(query, in: file.name)
            }
        }
        guard !hits.isEmpty else { return }
        let target = hits[episodeHit % hits.count]
        // 줄이 애니메이션 없이 넘긴다 (지나가는 카드를 만들지 않게)
        episodeScroll = shown.firstIndex { $0.path == target.path }
        highlightedEpisode = target.path
        Task {
            try? await Task.sleep(for: .seconds(2))
            if highlightedEpisode == target.path { highlightedEpisode = nil }
        }
    }

    /// 회차 카드: 장면·제목·방영일·줄거리·파일명. 누르면 바로 재생(이어서), 길게 누르면 처음부터·다 본 것으로·재생목록
    private func episodeCard(_ file: LibraryData.FileEntry) -> some View {
        let info = episodes.first { $0.season == file.season && $0.episode == file.episode }
        let width: CGFloat = sizeClass == .compact ? 260 : 300
        return Button { play(file, resume: true) } label: {
            VStack(alignment: .leading, spacing: 4) {
                EpisodeArtwork(still: info?.still, file: videoFile(file))
                    .frame(width: width, height: width * 9 / 16)
                    .overlay(alignment: .bottom) { WatchProgress(key: key(file)) }
                    .clipShape(.rect(cornerRadius: 8))
                    // 회차 찾기로 찾은 카드
                    .overlay {
                        if highlightedEpisode == file.path {
                            RoundedRectangle(cornerRadius: 8).strokeBorder(.tint, lineWidth: 3)
                        }
                    }
                    .animation(.easeOut(duration: 0.3), value: highlightedEpisode)
                    .padding(.bottom, 4)
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(episodeTitle(file, info)).font(.headline).lineLimit(1)
                    if watched(file) {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.secondary).font(.subheadline)
                    }
                }
                if let date = info?.date { Text(date).font(.caption).foregroundStyle(.secondary) }
                Text(info?.summary ?? "")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(3, reservesSpace: true)
                Text(file.name)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                // 바뀜 (2026-11-10, 사용자): 영화처럼 파일명 아래에 형식 줄 (한 번 재생해야 해상도·코덱·시간이 나온다)
                Text(LibraryData.formatLine(file))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            .frame(width: width, alignment: .leading)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("처음부터", systemImage: "arrow.counterclockwise") { play(file, resume: false) }
            if watched(file) {
                Button("다 본 표시 지우기", systemImage: "arrow.uturn.backward") { videoFile(file).clearPlaybackRecord() }
            } else {
                Button("다 본 것으로 표시", systemImage: "checkmark") { markWatched(file) }
            }
            AddToPlaylistMenu(items: playlistItems([file])) { newPlaylistItems = $0 }
        }
    }

    /// 재생목록에 넣을 항목 (해시가 있는 파일만)
    private func playlistItems(_ files: [LibraryData.FileEntry]) -> [Playlists.Item] {
        files.compactMap { file in
            guard file.hash != nil else { return nil }
            return Playlists.Item(key: key(file), title: videoFile(file).title)
        }
    }

    private func episodeTitle(_ file: LibraryData.FileEntry, _ info: LibraryData.EpisodeEntry?) -> String {
        let number = file.episode.map { "\($0)화" } ?? file.name
        // 바뀜 (2026-11-07): "1회"·"Episode 1" 처럼 번호뿐인 제목은 빼고 번호만 (서버 규칙 전에 받아 둔 회차, 사용자)
        guard let title = info?.title, !title.isEmpty, !title.hasPrefix("에피소드"), !TMDBAgent.isNumberOnlyTitle(title) else { return number }
        return "\(number). \(title)"
    }

    private func seasonTitle(_ number: Int) -> String {
        number == 0 ? "스페셜" : "시즌 \(number)"
    }

    private func episodeLabel(_ file: LibraryData.FileEntry) -> String {
        guard let episode = file.episode else { return file.name }
        return file.season == 0 ? "스페셜 \(episode)화" : "시즌 \(file.season ?? 1) \(episode)화"
    }

    // MARK: - 출연진

    private func creditsSection(_ detail: LibraryData.ItemDetail) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("출연·제작").font(.title3.bold())
            BleedingRow(spacing: 14) {
                ForEach(detail.credits) { credit in
                    NavigationLink(value: PersonRoute(key: credit.globalKey, name: credit.name, photo: credit.photo, nameOrigin: credit.nameOrigin)) {
                        PersonCard(name: credit.name, photo: credit.photo, detail: roleText(credit), size: ShelfSize.person(sizeClass))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func roleText(_ credit: LibraryData.Credit) -> String {
        switch credit.role {
        case "DIRECTOR": "감독"
        case "WRITER": "각본"
        // 배역이 없으면 원어 이름
        default: credit.character.flatMap { $0.isEmpty ? nil : $0 } ?? credit.nameOrigin ?? ""
        }
    }

    // MARK: - 컬렉션·장르

    /// 작품 포스터 가로 줄 (제목을 누르면 그 컬렉션·장르의 모든 작품). 지금 작품은 테두리로 표시한다.
    private func itemShelf(_ title: String, more: ItemListRoute, items: [LibraryData.ItemSummary]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            NavigationLink(value: more) {
                HStack(spacing: 4) {
                    Text(title).font(.title3.bold())
                    Image(systemName: "chevron.right").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            BleedingRow {
                ForEach(items) { item in
                    let current = item.key == itemKey
                    NavigationLink(value: BrowseItemRoute(libraryID: item.libraryID, key: item.key)) {
                        LibraryPosterCard(title: item.title, subtitle: item.year.map(String.init) ?? "", poster: item.poster,
                                          badges: item.appleTV ? ["appletv.fill"] : [])
                            .frame(width: ShelfSize.poster(sizeClass))
                            .overlay(alignment: .top) {
                                if current {
                                    RoundedRectangle(cornerRadius: 8).strokeBorder(.tint, lineWidth: 3)
                                        .aspectRatio(2 / 3, contentMode: .fit)
                                }
                            }
                    }
                    .buttonStyle(.plain)
                    // 지금 작품은 누를 수 없게 (흐리게 하지는 않는다)
                    .allowsHitTesting(!current)
                }
            }
        }
    }

    /// 장르: 장르마다 포스터를 겹친 카드 한 줄 (누르면 그 장르의 작품 목록)
    private var genreSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("장르").font(.title3.bold())
            BleedingRow {
                ForEach(genres) { genre in
                    NavigationLink(value: ItemListRoute(source: .genre(genre.name), title: genre.name)) {
                        MosaicCard(title: genre.name, subtitle: "\(genre.count)편", posters: genre.posters)
                            .frame(width: ShelfSize.poster(sizeClass))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: - 재생

    private func key(_ file: LibraryData.FileEntry) -> String {
        file.hash.map { "#\($0)|\(file.size)" } ?? "\(file.name)|\(file.size)"
    }

    private func watched(_ file: LibraryData.FileEntry) -> Bool {
        // 바뀜 (2026-11-11): 다 본 표시는 재생 상태(영구)에서
        PlaybackStateStore.shared.isWatched(key(file))
    }

    /// 지금 재생할 것: 시리즈는 이어 볼 회차, 영화는 첫 파일 (이어보기 위치가 있으면 이어서)
    private var upNext: (file: LibraryData.FileEntry, resume: Bool)? {
        let ordered = detail?.isSeries == true ? files.filter { $0.episode != nil }.sorted(by: LibraryData.episodeOrder) : files
        guard let first = ordered.first else { return nil }
        let keys = ordered.map(key)
        // 이 작품에서 가장 최근에 본 회차
        if let last = watch.entries.first(where: { keys.contains($0.id) }), let index = keys.firstIndex(of: last.id) {
            if !last.finished { return (ordered[index], true) }
            if index + 1 < ordered.count { return (ordered[index + 1], false) }
        }
        return (first, PlaybackStateStore.shared.state(for: key(first)).position > 0)
    }

    /// 그림의 재생 단추: 이어 볼 것이 있으면 그것, 파일이 없으면 Apple TV 앱에서
    private func playFirst() {
        if let next = upNext {
            play(next.file, resume: next.resume)
        } else if let movie = purchases.first {
            Task { await AppleTVLibrary.shared.open(movie) }
        }
    }

    private func play(_ file: LibraryData.FileEntry, resume: Bool) {
        PlayerHost.shared.play(videoFile(file), resume: resume)
    }

    private func markWatched(_ file: LibraryData.FileEntry) {
        LibraryData.markWatched(videoFile(file))
    }

    private func videoFile(_ file: LibraryData.FileEntry) -> VideoFile {
        LibraryData.videoFile(file, in: library, title: detail.map { LibraryData.playTitle($0, file) })
    }

    /// 메타데이터 새로 고침: 이 작품의 파일을 에이전트에게 다시 물어 작품 정보·옮길 위치를 새로 받는다.
    /// 파일 없이 Apple TV 구입작만 있으면 작품 정보만 다시 받는다.
    private func refreshMetadata() async {
        guard let detail, let entry = library.agents.first(where: { $0.agentID == detail.agentID }),
              let agent = AgentStore.shared.agent(entry.agentID) else { return }
        refreshing = true
        defer { refreshing = false }
        // 바뀜 (2026-11-07): 사용자 정의 에이전트(reader)는 정보 출처(TMDB)에서 다시 받게 한 뒤 (새 회차·바뀐 줄거리·포스터)
        //   파일을 다시 매칭한다. 서버는 평소엔 처음 받은 정보를 계속 쓰고, 이때만 다시 받는다 (직접 고친 작품은 그대로)
        if agent.type == .custom, let item = try? await agent.customClient.refreshedItem(detail.id, kind: entry.kind) {
            try? LibraryData.saveItem(item, key: itemKey, agentID: agent.id)
        }
        for file in files {
            guard let hash = file.hash,
                  let result = try? await agent.client.match(kind: entry.kind, hash: hash, size: file.size, path: file.path, duration: nil,
                                                             choice: nil, season: file.season, episode: file.episode, episodeEnd: nil),
                  result.matched == true else { continue }
            try? LibraryData.saveMatch(result, file: file, agentID: agent.id)
        }
        if files.isEmpty, let item = try? await agent.client.item(detail.id, kind: entry.kind) {
            try? LibraryData.saveItem(item, key: itemKey, agentID: agent.id)
        }
        LibraryScanner.shared.refreshViews()
        await load()
    }

    private func load() async {
        detail = LibraryData.item(itemKey)
        files = LibraryData.files(ofItem: itemKey, in: library.id)
        purchases = LibraryData.purchases(ofItem: itemKey, in: library.id).compactMap(AppleTVLibrary.shared.movie)
        if let detail {
            // 컬렉션이 길면 (기타 라이브러리의 시리즈 등) 지금 작품 앞뒤로 20편만. 전체는 줄 제목을 눌러서
            let members = detail.collectionID.map { LibraryData.items(collection: $0) } ?? []
            let limit = 20
            if members.count > limit {
                let index = members.firstIndex { $0.key == itemKey } ?? 0
                let start = min(max(index - limit / 2, 0), members.count - limit)
                collection = Array(members[start..<start + limit])
            } else {
                collection = members
            }
            // 이 작품의 장르 카드끼리도 포스터가 겹치지 않게 다시 고른다 (전체 장르 목록에서 고른 그림은 다른 장르와 나눠 가진 것이라)
            let all = LibraryData.genres()
            let mine = detail.genres.compactMap { name in all.first { $0.name == name } }
            let picked = LibraryData.distinctPosters(mine.map { LibraryData.genrePosterCandidates($0.name) })
            genres = mine.indices.map { LibraryData.GenreEntry(name: mine[$0].name, count: mine[$0].count, posters: picked[$0]) }
        }
        episodes = LibraryData.episodes(of: itemKey)
        // 이어 볼 회차의 시즌을 먼저 보여준다
        if detail?.isSeries == true, season == nil { season = initialSeason ?? upNext?.file.season }
        // 시리즈는 회차 정보(제목·장면)를 에이전트에게 한 번 더 받는다
        if let detail, detail.isSeries, let agent = AgentStore.shared.agent(detail.agentID),
           let item = try? await agent.client.item(detail.id) {
            try? LibraryData.saveItem(item, key: itemKey, agentID: agent.id)
            episodes = LibraryData.episodes(of: itemKey)
        }
    }
}

/// 회차·파일 그림 아래의 본 정도 막대 (이어보기 위치가 있을 때만)
private struct WatchProgress: View {
    let key: String

    var body: some View {
        let state = PlaybackStateStore.shared.state(for: key)
        if state.position > 0, state.duration > 0 {
            ProgressBar(fraction: min(state.position / state.duration, 1))
        }
    }
}

/// 회차 그림: 에이전트가 준 장면 사진, 없으면 영상에서 뜬 썸네일 (폴더 화면과 같은 썸네일)
private struct EpisodeArtwork: View {
    let still: String?
    let file: VideoFile
    @State private var thumbnail: UIImage?

    var body: some View {
        if let still {
            // 에이전트가 준 w300 은 레티나 화면의 카드(260~300pt = 520~600px)에 흐리다: TMDB 는 w780 도 준다
            CachedImage(url: TMDBClient.resized(still, to: "w780"))
        } else if let thumbnail {
            Image(uiImage: thumbnail).resizable().scaledToFill()
        } else {
            Rectangle().fill(.quaternary)
                .task(id: file.url) { thumbnail = await ThumbnailService.shared.thumbnail(for: file) }
        }
    }
}

extension LibraryData {
    /// 플레이어에 보일 제목: 시리즈 회차는 "작품 S1E3" (파일 이름의 S01E03 보다 읽기 편해서 그대로, 2026-11-11 사용자)
    static func playTitle(_ item: ItemDetail, _ file: FileEntry) -> String {
        guard item.isSeries, let number = file.episode else { return item.title }
        return "\(item.title) \(file.season.map { "S\($0)" } ?? "")E\(number)"
    }

    /// 파일 형식 줄: "4K · MKV · HEVC · AAC 5.1 · 4.2 GB · 2시간 1분" (해상도·코덱·재생 시간은 한 번 재생한 파일만)
    /// 바뀜 (2026-11-10, 사용자): 형식(MKV·MP4)은 파일명 확장자로 보이므로 뺀다 — "1080p · HEVC · AC3 5.1* · 5 GB · 1시간 4분"
    static func formatLine(_ file: FileEntry) -> String {
        let state = PlaybackStateStore.shared.state(for: file.hash.map { "#\($0)|\(file.size)" } ?? "")
        let parts = [state.media?.resolution].compactMap { $0 } + (state.media?.codecs ?? [])
            + [file.size.fileSizeText] + (state.duration > 0 ? [state.duration.durationText] : [])
        return parts.joined(separator: " · ")
    }

    /// 다 본 것으로: 이어보기 위치를 지우고 끝까지 본 기록을 남긴다 (홈 이어보기에 다음 회차가 나온다)
    static func markWatched(_ video: VideoFile) {
        PlaybackStateStore.shared.update(video.stateKey) {
            $0.position = 0
            $0.watchedAt = .now
        }
        WatchHistory.shared.record(video, finished: true)
    }
}

#if os(iOS)
/// 글 칸에 포커스가 가면 화면(DetailPage)을 그 위치(top)가 위쪽 막대 바로 아래에 오게 옮긴다 (키보드와 함께, 기다리지 않고)
private struct RevealOnFocus: ViewModifier {
    let top: CGFloat
    @Environment(\.pageScroll) private var pageScroll
    @FocusState private var focused: Bool

    func body(content: Content) -> some View {
        content
            .focused($focused)
            .onChange(of: focused) {
                guard focused else { return }
                pageScroll?.reveal(top: top)
            }
    }
}
#endif
