import SwiftUI

// 아이폰·아이패드와 맥이 같이 쓰는 화면 코드에서, 한쪽에만 있는 표기를 감싼다.

extension View {
    /// 작은 제목 표시줄 (아이폰·아이패드). 맥은 창 제목을 쓰지 않으므로 그대로 둔다.
    func inlineNavigationTitle(_ inline: Bool = true) -> some View {
        #if os(iOS)
        navigationBarTitleDisplayMode(inline ? .inline : .automatic)
        #else
        self
        #endif
    }
}

extension View {
    /// 화면 안에서 찾기: 맥은 도구 막대 오른쪽 끝의 찾기 칸 (앞에 늘어나는 빈칸을 두어 칸이 빈 곳을 다 차지하지 않게),
    /// 아이폰·아이패드는 목록을 아래로 당기면 나오는 칸
    func pageSearchable(_ text: Binding<String>, prompt: String) -> some View {
        pageSearchable(text, prompt: prompt) { ToolbarItemGroup {} }
    }

    /// 찾기 칸 왼쪽에 놓을 단추들과 함께 ([‹ ›] … [단추] [찾기]). 빈칸과 단추를 한 도구 막대에 넣어야 차례가 맞는다.
    func pageSearchable(_ text: Binding<String>, prompt: String, @ToolbarContentBuilder actions: () -> some ToolbarContent) -> some View {
        #if os(macOS)
        searchable(text: text, placement: .toolbar, prompt: prompt)
            .toolbar {
                ToolbarSpacer(.flexible)
                actions()
            }
        #else
        searchable(text: text, placement: .navigationBarDrawer, prompt: prompt)
            .toolbar { actions() }
        #endif
    }
}

extension KoreanIndex {
    /// 찾기 글자가 비었거나 글 하나에라도 들어 있는지 (초성으로도)
    static func filter(_ query: String, _ texts: String?...) -> Bool {
        let query = query.trimmingCharacters(in: .whitespaces)
        return query.isEmpty || texts.contains { $0.map { matches(query, in: $0) } == true }
    }
}

extension View {
    /// 전체 화면으로 띄우기 (맥은 시트로)
    func fullScreenCoverOrSheet<Item: Identifiable, Content: View>(item: Binding<Item?>, @ViewBuilder content: @escaping (Item) -> Content) -> some View {
        #if os(iOS)
        fullScreenCover(item: item, content: content)
        #else
        sheet(item: item, content: content)
        #endif
    }
}

extension View {
    /// 설정 띄우기: 아이폰·아이패드는 시트, 맥은 오른쪽 옆 패널 (도구 막대의 설정 버튼으로 여닫는다).
    /// 맥 기본 인스펙터는 도구 막대를 패널 칸과 나눠 검색칸·버튼 자리를 바꿔 놓아서, 본문 옆에 직접 붙인다.
    /// 본문 위에 겹쳐 띄운다: 옆으로 붙이면 여닫을 때 본문 폭이 바뀌어 격자가 떨리며 다시 놓였다.
    func settingsPanel<Content: View>(isPresented: Binding<Bool>, width: CGFloat = 300, @ViewBuilder content: @escaping () -> Content) -> some View {
        #if os(macOS)
        overlay(alignment: .trailing) {
            if isPresented.wrappedValue {
                content()
                    .frame(width: width)
                    .frame(maxHeight: .infinity)
                    .background(.background)
                    // 왼쪽 가장자리 세로 구분선 (Divider 는 겹쳐 놓으면 가로줄이 되어 패널 가운데를 가로지른다)
                    .overlay(alignment: .leading) { Rectangle().fill(.separator).frame(width: 1) }
                    .shadow(color: .black.opacity(0.15), radius: 12, x: -2)
                    .transition(.move(edge: .trailing))
            }
        }
        .clipped()
        .animation(.easeInOut(duration: 0.2), value: isPresented.wrappedValue)
        #else
        sheet(isPresented: isPresented, content: content)
        #endif
    }
}

extension View {
    /// 탭 막대 숨기기 (맥은 탭 막대 대신 사이드바라 그대로)
    func hidesTabBar(_ hidden: Bool) -> some View {
        #if os(iOS)
        toolbar(hidden ? .hidden : .automatic, for: .tabBar)
        #else
        self
        #endif
    }

    /// 주소·아이디 입력: 자동 대문자·자동 고침 끄기
    func plainTextInput() -> some View {
        #if os(iOS)
        textInputAutocapitalization(.never).autocorrectionDisabled()
        #else
        autocorrectionDisabled()
        #endif
    }

    /// 주소 입력용 키보드 (맥은 키보드가 따로 없다)
    func urlKeyboard() -> some View {
        #if os(iOS)
        keyboardType(.URL)
        #else
        self
        #endif
    }

    /// 목록 편집 상태를 아래 목록에 넘긴다 (맥은 편집 상태를 목록이 따로 갖지 않는다)
    func editModeEnvironment(_ editMode: Binding<EditMode>) -> some View {
        #if os(iOS)
        environment(\.editMode, editMode)
        #else
        self
        #endif
    }
}

extension SearchFieldPlacement {
    /// 제목 아래 검색 막대 (맥은 도구 막대)
    static var drawer: SearchFieldPlacement {
        #if os(iOS)
        .navigationBarDrawer(displayMode: .automatic)
        #else
        // 맥은 도구 막대 오른쪽 (동작 아이콘은 왼쪽, 설정 버튼은 검색칸 오른쪽)
        .toolbar
        #endif
    }
}

extension ToolbarItemPlacement {
    /// 시트의 닫기 버튼 (맥은 시트 아래 취소 자리: 보이고 Esc 로도 닫힌다)
    static var closeBar: ToolbarItemPlacement {
        #if os(iOS)
        .topBarTrailing
        #else
        .cancellationAction
        #endif
    }

    /// 화면 아래 툴바 (맥은 도구 막대 가운데)
    static var bottomBarOrStatus: ToolbarItemPlacement {
        #if os(iOS)
        .bottomBar
        #else
        .status
        #endif
    }

    /// 툴바 오른쪽 위 (맥은 도구 막대 오른쪽 끝)
    static var trailingBar: ToolbarItemPlacement {
        #if os(iOS)
        .topBarTrailing
        #else
        .automatic
        #endif
    }

    /// 툴바 왼쪽 위 (맥은 도구 막대의 탐색 자리)
    static var leadingBar: ToolbarItemPlacement {
        #if os(iOS)
        .topBarLeading
        #else
        .navigation
        #endif
    }
}

extension Color {
    /// 묶음 목록 뒤 배경
    static var groupedBackground: Color {
        #if os(iOS)
        Color(.systemGroupedBackground)
        #else
        Color(nsColor: .windowBackgroundColor)
        #endif
    }

    /// 화면 기본 배경
    static var screenBackground: Color {
        #if os(iOS)
        Color(.systemBackground)
        #else
        Color(nsColor: .windowBackgroundColor)
        #endif
    }
}

/// 맥 화면 맨 위의 큰 제목 (음악 앱처럼 내용 안에). 아이폰·아이패드는 내비게이션 제목을 쓰므로 그리지 않는다.
struct MacPageTitle: View {
    let title: String
    /// 둘레에 여백이 없는 화면이면 제목에 여백을 준다
    var inset = true

    init(_ title: String, inset: Bool = true) {
        self.title = title
        self.inset = inset
    }

    var body: some View {
        #if os(macOS)
        Text(title)
            .font(.largeTitle.bold())
            .padding(.horizontal, inset ? nil : 0)
            .padding(.bottom, inset ? -12 : 0)
        #endif
    }
}

/// 시트를 닫는 버튼: 아이폰·아이패드는 ✕, 맥은 글자만 ("완료")
struct CloseButton: View {
    let action: () -> Void

    var body: some View {
        #if os(macOS)
        Button("완료", action: action).keyboardShortcut(.cancelAction)
        #else
        Button("닫기", systemImage: "xmark", action: action)
        #endif
    }
}

/// 묶음 폼의 묶음 제목 (2026-11-08, 사용자): 맥 팝오버(재생 설정·만화 보기 설정)에서 묶음 사이가 붙어 보이고 제목이 본문과 같아 보였다 →
/// 맥에서는 굵게 + 위에 여백 (첫 묶음은 팝오버 위 여백이 있으므로 빼고). 아이폰·아이패드 시트는 원래 모양 그대로
struct FormHeader: View {
    let title: String
    var isFirst = false

    init(_ title: String, isFirst: Bool = false) {
        self.title = title
        self.isFirst = isFirst
    }

    var body: some View {
        #if os(macOS)
        Text(title)
            .font(.headline)
            .padding(.top, isFirst ? 0 : 12)
        #else
        Text(title)
        #endif
    }
}

extension View {
    /// 찾기 칸을 눌렀을 때 (2026-11-08, 사용자): 아이폰은 라이브러리 화면처럼 제목 막대가 숨고 찾기 칸이 맨 위로 (가장 깔끔했다),
    /// 아이패드는 예전에 정한 대로 제목·찾기 칸이 제자리 (음악 앱처럼). 화면마다 다르게 보이던 것을 이것 하나로 맞춘다
    /// 바뀜 (2026-11-08): 아이패드도 아이폰과 같게 (사용자: 제자리 방식은 찾는 중 오른쪽 ✕ 단추가 안 나왔다) — 시스템 기본 그대로
    func searchBarBehavior() -> some View {
        self
    }
}
