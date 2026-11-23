import SwiftUI

/// 라이브러리·폴더 아이콘 고르기: 후보 격자 + "모든 아이콘 보기". nil 이면 기본 아이콘(종류·폴더).
struct IconPicker: View {
    @Binding var selection: String?
    /// 고르지 않았을 때 쓰는 아이콘
    let defaultSymbol: String
    @State private var browsing = false

    /// 후보 (이 기기의 SF Symbols 에 있는 것만 보인다)
    static let candidates = [
        // 영상
        "film", "film.stack", "movieclapper", "popcorn", "ticket", "theatermasks", "video", "play.rectangle",
        "play.tv", "tv", "sparkles.tv", "appletv", "display", "photo.tv",
        // 다큐멘터리·자연·배움
        "globe", "globe.asia.australia", "globe.americas", "map", "mountain.2", "leaf", "tree", "pawprint",
        "bird", "fish", "tortoise", "ant", "binoculars", "camera.macro", "microbe", "atom", "graduationcap",
        "books.vertical", "book", "newspaper", "building.columns",
        // 예능·음악
        "face.smiling", "theatermask.and.paintbrush", "music.mic", "mic", "music.note", "music.note.tv",
        "party.popper", "balloon.2", "gamecontroller", "figure.dance", "figure.run", "fork.knife", "airplane",
        // 그 밖
        "folder", "folder.fill", "square.stack", "rectangle.stack", "heart", "star", "sparkles", "house",
        "person.2", "figure.2.and.child.holdinghands", "photo", "camera", "archivebox", "tray.full",
    ].filter(Self.exists)

    var body: some View {
        let current = selection ?? defaultSymbol
        // 모든 아이콘에서 고른 것이 후보에 없으면 맨 앞에 보인다
        let shown = Self.candidates.contains(current) ? Self.candidates : [current] + Self.candidates
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 40), spacing: 8)], spacing: 8) {
            ForEach(shown, id: \.self) { symbol in
                SymbolCell(symbol: symbol, selected: symbol == current) {
                    selection = symbol == defaultSymbol ? nil : symbol
                }
            }
        }
        .padding(.vertical, 4)
        SettingsActionButton(title: "모든 아이콘 보기…", systemImage: "square.grid.3x3") { browsing = true }
            .sheet(isPresented: $browsing) {
                SymbolBrowser(initial: current) { symbol in selection = symbol == defaultSymbol ? nil : symbol }
            }
        if selection != nil {
            SettingsActionButton(title: "기본 아이콘으로", systemImage: "arrow.uturn.backward") { selection = nil }
        }
    }

    /// 이 기기의 SF Symbols 에 그 이름이 있는지
    static func exists(_ name: String) -> Bool {
        guard !name.isEmpty else { return false }
        #if os(macOS)
        return NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil
        #else
        return UIImage(systemName: name) != nil
        #endif
    }
}

/// 아이콘 한 칸: 고른 것은 강조색 바탕
private struct SymbolCell: View {
    let symbol: String
    let selected: Bool
    var size: CGFloat = 40
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(size > 40 ? .title2 : .title3)
                .frame(width: size, height: size * 0.9)
                .foregroundStyle(selected ? Color.white : Color.accentColor)
                .background(selected ? Color.accentColor : Color.clear, in: .rect(cornerRadius: 8))
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help(symbol)
    }
}

/// SF Symbols 전체 보기 (SF Symbols 앱 없이): 아이콘을 눌러 고르고 [적용] 으로 정한다 (넘기다 잘못 눌러도 바로 바뀌지 않게).
/// 찾기 칸 옆 거르기 단추로 분류를 고른다. 목록(SFSymbols.json)은 맥의 CoreGlyphs 에서 뽑은 이름·분류·검색어
/// (개발 맥에서 한 번 뽑아 넣음). 이 기기에 없는 것은 뺀다.
struct SymbolBrowser: View {
    let initial: String
    let onPick: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var catalog: SymbolCatalog?
    @State private var category: Int?
    @State private var query = ""
    @State private var picked: String?

    private var shown: [SymbolCatalog.Symbol] {
        guard let catalog else { return [] }
        let words = query.lowercased().split(separator: " ").map(String.init)
        return catalog.symbols.filter { symbol in
            (category == nil || symbol.categories.contains(category!))
                && words.allSatisfy { symbol.name.contains($0) || symbol.keywords.contains($0) }
        }
    }

    private var title: String {
        guard let catalog, let category, catalog.categories.indices.contains(category) else { return "모든 아이콘" }
        return SymbolCatalog.title(catalog.categories[category].key)
    }

    private var grid: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 52), spacing: 6)], spacing: 6) {
                ForEach(shown) { symbol in
                    SymbolCell(symbol: symbol.name, selected: symbol.name == (picked ?? initial), size: 52) {
                        picked = symbol.name
                    }
                }
            }
            .padding()
        }
        .overlay {
            if catalog == nil { ProgressView() }
            else if shown.isEmpty { ContentUnavailableView.search(text: query) }
        }
    }

    var body: some View {
        #if os(macOS)
        // 맥: 설정의 다른 시트처럼 제목 없이 위 찾기 칸, 아래 [닫기] [적용]
        VStack(spacing: 0) {
            searchBar
            Divider()
            grid
            Divider()
            HStack {
                Text(title).foregroundStyle(.secondary)
                Spacer()
                Button("닫기") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("적용", action: apply)
                    .keyboardShortcut(.defaultAction)
                    .disabled(picked == nil)
            }
            .padding()
        }
        .frame(minWidth: 620, minHeight: 600)
        .task { catalog = await SymbolCatalog.load() }
        #else
        NavigationStack {
            grid
            .safeAreaInset(edge: .top, spacing: 0) { searchBar }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("닫기", systemImage: "xmark") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("적용", systemImage: "checkmark", action: apply).disabled(picked == nil)
                }
            }
        }
        .task { catalog = await SymbolCatalog.load() }
        #endif
    }

    /// 찾기 칸 + 분류 거르기 (설정의 다른 찾기 칸처럼 둥근 칸)
    private var searchBar: some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("영어로 찾기 (예: music, nature)", text: $query)
                    .textFieldStyle(.plain)
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    #endif
                if !query.isEmpty {
                    Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                        .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(.quaternary.opacity(0.7), in: .capsule)
            Menu {
                Picker("분류", selection: $category) {
                    Label("모두", systemImage: "square.grid.2x2").tag(Int?.none)
                    ForEach(Array((catalog?.categories ?? []).enumerated()), id: \.offset) { index, item in
                        Label(SymbolCatalog.title(item.key), systemImage: item.icon).tag(Optional(index))
                    }
                }
                .pickerStyle(.inline)
            } label: {
                Image(systemName: category == nil ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
                    .font(.title2)
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .foregroundStyle(.tint)
            .help("분류")
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
        .background(.bar)
    }

    private func apply() {
        if let picked { onPick(picked) }
        dismiss()
    }
}

/// 앱에 넣어 둔 SF Symbols 목록
struct SymbolCatalog: Sendable {
    struct Category: Decodable, Sendable {
        let key: String
        let icon: String
    }

    struct Symbol: Identifiable, Sendable {
        let name: String
        let categories: [Int]
        /// 영어 검색어 (공백으로 이음)
        let keywords: String
        var id: String { name }
    }

    let categories: [Category]
    let symbols: [Symbol]

    private struct File: Decodable {
        let categories: [Category]
        let symbols: [[Entry]]

        enum Entry: Decodable {
            case text(String), numbers([Int])
            init(from decoder: Decoder) throws {
                let container = try decoder.singleValueContainer()
                if let text = try? container.decode(String.self) { self = .text(text) } else { self = .numbers(try container.decode([Int].self)) }
            }
        }
    }

    /// 읽고 이 기기에 있는 것만 남긴다 (7천여 개라 한 번만, 화면을 막지 않게)
    static func load() async -> SymbolCatalog? {
        await Task.detached {
            guard let url = Bundle.main.url(forResource: "SFSymbols", withExtension: "json"),
                  let data = try? Data(contentsOf: url), let file = try? JSONDecoder().decode(File.self, from: data) else { return nil }
            let symbols = file.symbols.compactMap { entry -> Symbol? in
                guard entry.count == 3, case .text(let name) = entry[0], case .numbers(let categories) = entry[1],
                      case .text(let keywords) = entry[2], IconPicker.exists(name) else { return nil }
                return Symbol(name: name, categories: categories, keywords: keywords)
            }
            return SymbolCatalog(categories: file.categories, symbols: symbols)
        }.value
    }

    /// 분류 이름 (SF Symbols 앱의 분류)
    static func title(_ key: String) -> String {
        [
            "draw": "그리기", "variable": "변하는 값", "multicolor": "여러 색", "communication": "소통", "weather": "날씨",
            "maps": "지도", "objectsandtools": "물건·도구", "devices": "기기", "cameraandphotos": "카메라·사진", "gaming": "게임",
            "connectivity": "연결", "transportation": "교통", "automotive": "자동차", "accessibility": "손쉬운 사용",
            "privacyandsecurity": "개인정보·보안", "human": "사람", "home": "집", "fitness": "운동", "nature": "자연",
            "editing": "편집", "textformatting": "글자 서식", "media": "미디어", "keyboard": "키보드", "commerce": "쇼핑",
            "time": "시간", "health": "건강", "shapes": "모양", "arrows": "화살표", "indices": "번호", "math": "수학",
        ][key] ?? key
    }
}
