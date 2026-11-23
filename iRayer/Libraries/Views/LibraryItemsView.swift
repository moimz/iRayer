import SwiftUI

/// 라이브러리 화면: 에이전트가 찾은 작품의 포스터 격자. 못 찾은 파일은 위쪽 알림 줄에서 따로 본다.
struct LibraryItemsView: View {
    let library: LibraryRecord
    @State private var scanner = LibraryScanner.shared
    @State private var items: [LibraryData.ItemSummary] = []
    @State private var counts: [String: Int] = [:]
    @State private var showsUnmatched = false
    /// 폴더 정리 묻기 (맥): 옮길 파일, 이미 물어본 파일
    @State private var asksOrganize = false
    @State private var organizing = false
    @State private var pendingMoves: [LibraryOrganizer.Move] = []
    @State private var declinedMoves: Set<String> = []
    @State private var editing = false
    @State private var source = Source.all
    /// 이 라이브러리 안에서 찾기 (제목·원제, 초성)
    @State private var filter = ""
    @State private var sort = Sort.name
    /// 좌우로 미는 중인 거리와 한 화면 폭 (미는 동안 옆 보기의 격자가 따라 들어온다)
    @State private var pageOffset: CGFloat = 0
    @State private var pageWidth: CGFloat = 0
    @State private var pageTurning = 0
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        LibraryStack {
            // 라이브러리 설정: 맥은 폴더 설정처럼 오른쪽 옆 패널, 아이폰·아이패드는 시트 (둘 다 바꾸는 즉시 저장)
            content
                .settingsPanel(isPresented: $editing, width: 360) {
                    LibraryAddView(library: LibraryStore.shared.library(library.id) ?? library, presentation: .panel)
                        .id(library.id)
                }
        }
        .task(id: scanner.revision) { reload() }
        .task {
            // 한 번도 훑지 않은 라이브러리는 열자마자 훑는다
            if library.scannedAt == nil && !scanner.isRunning(library.id) { scanner.scan(library) }
        }
        .sheet(isPresented: $showsUnmatched, onDismiss: offerOrganize) {
            UnmatchedView(library: library) { reload() }
        }
        #if os(macOS)
        // 매칭이 끝나면 폴더 정리를 이어서 할지 묻는다 (자동으로 추가 대신, 사용자 2026-11-07)
        .onChange(of: scanner.isRunning(library.id)) { was, now in
            if was && !now { offerOrganize() }
        }
        .alert("폴더도 정리할까요?", isPresented: $asksOrganize) {
            Button("정리…") { organizing = true }
            Button("나중에", role: .cancel) {}
        } message: {
            Text("에이전트가 정한 위치와 다른 파일이 \(pendingMoves.count)개 있습니다.")
        }
        .sheet(isPresented: $organizing) {
            MacOrganizeView(library: LibraryStore.shared.library(library.id) ?? library) { reload() }
        }
        #endif
    }

    #if os(macOS)
    /// 옮길 파일이 새로 생겼으면 폴더 정리를 묻는다 (나중에로 넘긴 파일만 남았으면 묻지 않는다)
    private func offerOrganize() {
        Task {
            let moves = await LibraryOrganizer.collect(LibraryStore.shared.library(library.id) ?? library)
            let ids = Set(moves.map(\.id))
            guard !ids.isEmpty, !ids.isSubset(of: declinedMoves) else { return }
            pendingMoves = moves
            declinedMoves.formUnion(ids)
            asksOrganize = true
        }
    }
    #else
    private func offerOrganize() {}
    #endif

    /// 보이는 작품: 보기(전체/내 라이브러리/Apple TV) → 찾기 → 정렬
    private func shownItems(_ source: Source) -> [LibraryData.ItemSummary] {
        let query = filter.trimmingCharacters(in: .whitespaces)
        let found = items.filter(source.includes).filter { item in
            query.isEmpty || KoreanIndex.matches(query, in: item.title) || item.titleOrigin.map { KoreanIndex.matches(query, in: $0) } == true
        }
        switch sort {
        case .name: return found
        case .added: return found.sorted { ($0.added ?? .distantPast) > ($1.added ?? .distantPast) }
        case .year: return found.sorted { ($0.year ?? 0) > ($1.year ?? 0) }
        }
    }

    private var content: some View {
        let shown = shownItems(source)
        return ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                MacPageTitle(library.name, inset: false)
                statusBar
                if library.appleTV {
                    sourcePicker
                }
                grid(shown)
                    .pageSlide($pageOffset)
                    .overlay(alignment: .topLeading) {
                        // 미는 쪽 옆 보기 (한 화면 폭 옆에 붙어 따라온다)
                        if let next = neighbor(pageTurning) {
                            grid(shownItems(next))
                                .pageSlide($pageOffset, shift: CGFloat(pageTurning) * pageWidth)
                                .allowsHitTesting(false)
                        }
                    }
            }
            .padding(pagePadding)
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { pageWidth = $0 }
        // Apple TV 를 합친 라이브러리는 좌우로 밀어 전체 · 내 라이브러리 · Apple TV 를 바꾼다
        .swipeToPage($source, among: library.appleTV ? Source.allCases : [], offset: $pageOffset, turning: $pageTurning, distance: pageWidth)
        #if os(macOS)
        .searchable(text: $filter, placement: .toolbar, prompt: "이 라이브러리에서 찾기")
        #else
        // 처음에는 숨어 있다가 목록을 아래로 당기면 나온다 (폴더 화면과 같게)
        .searchable(text: $filter, placement: .navigationBarDrawer, prompt: "이 라이브러리에서 찾기")
        #endif
        .onChange(of: sort) { _, new in UserDefaults.standard.set(new.rawValue, forKey: "librarySort." + library.id) }
        .onAppear { sort = UserDefaults.standard.string(forKey: "librarySort." + library.id).flatMap(Sort.init) ?? .name }
        .overlay {
            if items.isEmpty && !scanner.isRunning(library.id) && (counts["unmatched"] ?? 0) + (counts["error"] ?? 0) == 0 {
                ContentUnavailableView {
                    Label("아직 작품이 없습니다", systemImage: library.symbol)
                } description: {
                    Text("라이브러리 폴더를 훑어 에이전트에게 작품을 물어봅니다.")
                } actions: {
                    Button("지금 훑기") { scanner.scan(library) }
                }
            }
        }
        .navigationTitle(library.name)
        // [정렬] [라이브러리 설정] (맥은 그 옆에 찾기). 다시 훑기는 아이폰·아이패드는 당겨서 새로 고침, 맥은 라이브러리 설정에.
        // 폴더 정리(파일 옮기기, 맥만)도 라이브러리 설정에.
        .toolbar {
            // 오른쪽에 (왼쪽 ‹ › 와 사이를 비운다. 맥은 찾기 칸이 빈 곳을 다 차지하지 않게 늘어나는 빈칸을 먼저)
            #if os(macOS)
            ToolbarSpacer(.flexible)
            #endif
            ToolbarItemGroup(placement: .primaryAction) {
                sortMenu
                Button("라이브러리 설정", systemImage: "slider.horizontal.3") { editing.toggle() }
                    .help("라이브러리 설정")
            }
        }
        #if os(iOS)
        // 훑기는 뒤에서 이어지고 진행은 위쪽 줄에 보인다 (당김 표시는 바로 닫는다)
        .refreshable { scanner.scan(library) }
        #endif
    }

    private func grid(_ shown: [LibraryData.ItemSummary]) -> some View {
        LazyVGrid(columns: posterColumns(sizeClass), alignment: .leading, spacing: 22) {
            ForEach(shown) { item in
                NavigationLink(value: BrowseItemRoute(libraryID: library.id, key: item.key)) {
                    LibraryPosterCard(title: item.title, subtitle: subtitle(item), poster: item.poster,
                                      badges: library.appleTV ? item.sourceBadges : [])
                }
                .buttonStyle(.plain)
            }
        }
    }

    /// 지금 보기의 앞(-1)·뒤(1) 보기 (0 이면 없음)
    private func neighbor(_ step: Int) -> Source? {
        guard step != 0, let index = Source.allCases.firstIndex(of: source), Source.allCases.indices.contains(index + step) else { return nil }
        return Source.allCases[index + step]
    }

    @ViewBuilder
    private var statusBar: some View {
        let problems = (counts["unmatched"] ?? 0) + (counts["error"] ?? 0)
        if let progress = scanner.running[library.id] {
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text(progress.total > 0 ? "\(progress.phase) \(progress.done)/\(progress.total)" : progress.phase)
                    .foregroundStyle(.secondary)
                if progress.total > 0 {
                    ProgressView(value: Double(progress.done), total: Double(progress.total))
                        .frame(maxWidth: 220)
                }
                Button("멈추기") { scanner.cancel(library.id) }
                    .buttonStyle(.borderless)
            }
        } else if let error = scanner.errors[library.id] {
            Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
        }
        if problems > 0 {
            Button {
                showsUnmatched = true
            } label: {
                Label("찾지 못한 파일 \(problems)개", systemImage: "questionmark.folder")
            }
            .buttonStyle(.bordered)
        }
    }

    private var sortMenu: some View {
        Menu("정렬", systemImage: "arrow.up.arrow.down") {
            Picker("정렬", selection: $sort) {
                ForEach(Sort.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.inline)
        }
        .help("정렬")
    }

    /// 작품 정렬 (라이브러리마다 기억)
    enum Sort: String, CaseIterable {
        case name, added, year

        var title: String {
            switch self {
            case .name: "이름순"
            case .added: "최근 추가순"
            case .year: "연도순"
            }
        }
    }

    /// 보기 고르기. 넓으면 420, 좁으면 줄인다 (폭을 고정하면 옆 패널을 창 밖으로 밀어낸다).
    /// 맥은 칸을 고르게 채우는 AppKit 분할 단추: SwiftUI 분할 Picker 는 맥에서 다시 그릴 때마다 폭이 달라졌다.
    @ViewBuilder
    private var sourcePicker: some View {
        #if os(macOS)
        FillSegmentedPicker(options: Source.allCases.map { ("\($0.title) \(items.filter($0.includes).count)", $0) },
                            selection: $source, controlSize: .regular)
            .frame(maxWidth: 420)
        #else
        Picker("보기", selection: $source) {
            ForEach(Source.allCases, id: \.self) { source in
                Text("\(source.title) \(items.filter(source.includes).count)").tag(source)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(maxWidth: 420)
        #endif
    }

    /// Apple TV 구입작을 넣는 라이브러리의 보기: 어디에 있는 작품인지
    enum Source: CaseIterable {
        case all, files, appleTV

        var title: String {
            switch self {
            case .all: "전체"
            case .files: "내 라이브러리"
            case .appleTV: "Apple TV"
            }
        }

        func includes(_ item: LibraryData.ItemSummary) -> Bool {
            switch self {
            case .all: true
            case .files: item.files > 0
            case .appleTV: item.appleTV
            }
        }
    }

    private func subtitle(_ item: LibraryData.ItemSummary) -> String {
        var parts: [String] = []
        if let year = item.year { parts.append(String(year)) }
        if item.isSeries { parts.append("\(item.files)편") }
        return parts.joined(separator: " · ")
    }

    private func reload() {
        items = LibraryData.items(in: library.id)
        counts = LibraryData.counts(in: library.id)
    }
}

/// 포스터 카드 (2:3)
struct LibraryPosterCard: View {
    let title: String
    let subtitle: String
    let poster: String?
    /// 연도 줄 끝에 붙는 작은 아이콘 (어디에 있는 작품인지)
    var badges: [String] = []
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // 칸(2:3)을 먼저 정하고 그림을 거기에 채운다: 비율이 다른 포스터도 크기·모서리가 같게
            Color.clear
                .aspectRatio(2 / 3, contentMode: .fit)
                .frame(maxWidth: .infinity)
                .background(.quaternary)
                .overlay {
                    if let url = poster.flatMap(URL.init(string:)) {
                        CachedImage(url: url)
                    } else {
                        Image(systemName: "film").font(.largeTitle).foregroundStyle(.tertiary)
                    }
                }
                .clipShape(.rect(cornerRadius: 8))
                .shadow(color: .black.opacity(0.15), radius: 4, y: 2)
            // 제목은 한 줄 (길면 1.0 처럼 흐른다): 두 줄이면 연도 줄과 떨어져 보인다
            MarqueeText(text: title).font(PosterCardFont.title(sizeClass))
            if !subtitle.isEmpty || !badges.isEmpty {
                HStack(spacing: 6) {
                    Text(subtitle)
                    Spacer(minLength: 0)
                    ForEach(badges, id: \.self) { Image(systemName: $0) }
                }
                .font(PosterCardFont.subtitle(sizeClass))
                .foregroundStyle(.secondary)
            }
        }
        .contentShape(.rect)
    }
}

/// 포스터 카드 글자 (제목·보조 줄): 맥은 한 단계 크게(본문 13pt), 아이폰은 카드가 좁아 한 단계 작게, 아이패드는 그대로
enum PosterCardFont {
    static func title(_ sizeClass: UserInterfaceSizeClass?) -> Font {
        #if os(macOS)
        .body
        #else
        sizeClass == .compact ? .footnote : .callout
        #endif
    }

    static func subtitle(_ sizeClass: UserInterfaceSizeClass?) -> Font {
        #if os(macOS)
        .subheadline
        #else
        sizeClass == .compact ? .caption2 : .caption
        #endif
    }
}

extension View {
    /// 카드 아래 제목 글자 (포스터·썸네일·폴더 카드 모두 같게)
    func cardTitleFont() -> some View { modifier(CardFont(isSubtitle: false)) }
    /// 카드 아래 보조 줄 글자 (연도·크기·편수)
    func cardSubtitleFont() -> some View { modifier(CardFont(isSubtitle: true)) }
}

private struct CardFont: ViewModifier {
    let isSubtitle: Bool
    @Environment(\.horizontalSizeClass) private var sizeClass

    func body(content: Content) -> some View {
        content.font(isSubtitle ? PosterCardFont.subtitle(sizeClass) : PosterCardFont.title(sizeClass))
    }
}

/// 포스터 격자 칸: 맥은 넉넉하게, 아이폰은 한 줄에 셋
func posterColumns(_ sizeClass: UserInterfaceSizeClass?) -> [GridItem] {
    #if os(macOS)
    [GridItem(.adaptive(minimum: 140, maximum: 190), spacing: 18)]
    #else
    [GridItem(.adaptive(minimum: PosterGrid.minimum(sizeClass), maximum: 190), spacing: 12)]
    #endif
}

/// 포스터 격자 칸 최소 폭: 아이폰 세로 3열, 넓은 화면(아이패드)은 칸을 키운다
enum PosterGrid {
    static func minimum(_ sizeClass: UserInterfaceSizeClass?) -> CGFloat {
        sizeClass == .regular ? 150 : 105
    }
}

/// 라이브러리·둘러보기 화면 둘레 여백
var pagePadding: EdgeInsets {
    #if os(macOS)
    EdgeInsets(top: 20, leading: 20, bottom: 20, trailing: 20)
    #else
    EdgeInsets(top: 8, leading: 16, bottom: 20, trailing: 16)
    #endif
}

extension LibraryData.ItemSummary {
    /// 어디에 있는 작품인지: Apple TV 구입작, NAS 파일
    var sourceBadges: [String] {
        (appleTV ? ["appletv.fill"] : []) + (files > 0 ? ["externaldrive.fill"] : [])
    }
}
