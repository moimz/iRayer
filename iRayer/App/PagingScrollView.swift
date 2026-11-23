import SwiftUI

/// 가로로 넘기는 줄(홈·작품 화면·검색)의 카드 크기: 어디서나 같게
enum ShelfSize {
    /// 포스터·장르 모음 카드 폭: 아이폰은 라이브러리 격자(한 줄에 셋)처럼 세 장 남짓이 보이게, 넓은 화면은 넉넉하게
    static func poster(_ sizeClass: UserInterfaceSizeClass?) -> CGFloat {
        #if os(macOS)
        150
        #else
        sizeClass == .compact ? 108 : 150
        #endif
    }

    /// 인물 사진 지름: 아이폰은 포스터 줄처럼 줄여서 네 명 남짓
    static func person(_ sizeClass: UserInterfaceSizeClass?) -> CGFloat {
        #if os(macOS)
        100
        #else
        sizeClass == .compact ? 76 : 100
        #endif
    }
}

extension EnvironmentValues {
    /// 화면 둘레 여백 (DetailPage 가 내용에 준 것). 가로로 넘기는 줄은 이만큼 밖으로 나가 화면 끝까지 그린다.
    @Entry var pageMargins = EdgeInsets()
    /// 화면(DetailPage)의 세로 스크롤을 그 안의 뷰(.id)로 넘긴다 (2026-11-07: 회차 찾기 칸에 포커스가 가면 회차 줄까지 보이게)
    @Entry var pageScroll: PageScroll? = nil
}

/// DetailPage 의 세로 스크롤을 안쪽 뷰가 옮기게 넘기는 것
/// 바뀜 (2026-11-07): ScrollViewReader·표식(anchor) 대신 내용 안 위치(pt)로 바로 옮긴다 — 표식 방식은 기기·방향마다 어긋나
///   세로에서는 다이내믹 아일랜드까지, 가로에서는 제목 막대까지 올라갔다 (사용자)
struct PageScroll {
    /// 위치를 재는 좌표 공간 (DetailPage 스크롤 내용의 맨 위가 0)
    static let space = "detailPageContent"
    /// 화면 위쪽 막대(상태 표시줄·도구 막대) 높이 — 내용이 이 밑으로 깔린다 (DetailPage 는 위쪽 안전 영역을 무시한다)
    var topInset: CGFloat = 0
    let scrollToOffset: (CGFloat) -> Void

    /// 내용 안 위치(space 기준) y 가 위쪽 막대 바로 아래(여유 8)에 오게
    func reveal(top y: CGFloat) {
        scrollToOffset(max(0, y - topInset - 8))
    }
}

/// 여백 안에 놓여도 화면 끝까지 넘겨 보는 가로 줄 (홈 선반처럼): 넘기는 동안은 카드가 여백 밖까지 보이고, 끝까지 넘기면 여백이 보인다.
/// 맥은 마우스를 올리면 좌우 화살표 (PagingScrollView).
struct BleedingRow<Content: View>: View {
    var spacing: CGFloat = 16
    /// 넘겨 보일 카드 순번 (넣으면 그 카드로 넘기고 nil 로 되돌린다)
    var scrollTarget: Binding<Int?>? = nil
    @ViewBuilder let content: Content
    @Environment(\.pageMargins) private var margins

    var body: some View {
        PagingScrollView(spacing: spacing, margins: EdgeInsets(top: 0, leading: margins.leading, bottom: 0, trailing: margins.trailing),
                         scrollTarget: scrollTarget) {
            content
        }
        .padding(.leading, -margins.leading)
        .padding(.trailing, -margins.trailing)
    }
}

/// 가로로 넘기는 줄 (홈 선반·출연진 등). 카드(content 의 뷰 하나하나)를 이 줄이 늘어놓는다.
/// 맥은 손가락으로 밀 수 없으니, 마우스를 올리면 양쪽에 < > 버튼이 나와 넘긴다 (음악 앱처럼):
/// > 는 오른쪽 끝에 걸려 잘린 카드를 맨 앞(앞 여백 뒤)으로, < 는 왼쪽 끝에 걸린 카드를 맨 뒤로 당긴다.
struct PagingScrollView<Content: View>: View {
    var spacing: CGFloat = 16
    /// 줄 앞뒤 여백 (넘기는 동안은 카드가 이 여백 위로 지나간다)
    var margins = EdgeInsets()
    /// 바뀜 (2026-11-07): 넘겨 보일 카드 순번. 카드는 이 줄이 다시 늘어놓아 카드에 붙인 .id 로는 넘길 수 없었다
    ///   (작품 화면의 회차 찾기·이어 볼 회차로 넘기기). 애니메이션 없이 넘기고 nil 로 되돌린다.
    var scrollTarget: Binding<Int?>? = nil
    @ViewBuilder let content: Content

    #if os(macOS)
    @State private var position = ScrollPosition(edge: .leading)
    @State private var offset: CGFloat = 0
    @State private var contentWidth: CGFloat = 0
    @State private var containerWidth: CGFloat = 0
    /// 카드마다 줄 안에서의 가로 범위 (화면에 그려진 것만)
    @State private var frames: [Int: ClosedRange<CGFloat>] = [:]
    @State private var hovering = false
    /// 마우스가 줄 또는 화살표 위에 있는지 (줄에서 화살표로 옮겨 가는 사이 잠깐 비는 것은 기다린다)
    @State private var overRow = false
    @State private var overArrow = false
    @State private var hideTask: Task<Void, Never>?
    #endif

    var body: some View {
        ScrollViewReader { proxy in
            scroller
                .onChange(of: scrollTarget?.wrappedValue) { scroll(proxy) }
                .onAppear { scroll(proxy) }
        }
    }

    private func scroll(_ proxy: ScrollViewProxy) {
        guard let target = scrollTarget?.wrappedValue else { return }
        // 줄이 자리를 잡은 뒤에
        DispatchQueue.main.async {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) { proxy.scrollTo(target, anchor: .center) }
            scrollTarget?.wrappedValue = nil
        }
    }

    @ViewBuilder
    private var scroller: some View {
        #if os(macOS)
        ScrollView(.horizontal, showsIndicators: false) {
            // 마우스 올림은 스크롤 뷰가 아니라 안의 내용에서 받는다 (맥 스크롤 뷰는 올림을 넘겨 주지 않는다)
            row
                .contentShape(.rect)
                .onContinuousHover { phase in
                    if case .active = phase { overRow = true } else { overRow = false }
                    updateHover()
                }
        }
            .scrollPosition($position)
            .onScrollGeometryChange(for: [CGFloat].self) { geometry in
                [geometry.contentOffset.x, geometry.contentSize.width, geometry.containerSize.width]
            } action: { _, values in
                offset = values[0]
                contentWidth = values[1]
                containerWidth = values[2]
            }
            .overlay(alignment: .leading) {
                if hovering, offset > 1 { arrow("chevron.left") { page(-1) } }
            }
            .overlay(alignment: .trailing) {
                if hovering, contentWidth == 0 || offset + containerWidth < contentWidth - 1 { arrow("chevron.right") { page(1) } }
            }
            .animation(.easeInOut(duration: 0.15), value: hovering)
        #else
        ScrollView(.horizontal, showsIndicators: false) { row }
        #endif
    }

    private var row: some View {
        Group(subviews: content) { cards in
            LazyHStack(alignment: .top, spacing: spacing) {
                ForEach(cards.indices, id: \.self) { index in
                    cards[index]
                        #if os(macOS)
                        .onGeometryChange(for: ClosedRange<CGFloat>.self) { geometry in
                            let frame = geometry.frame(in: .named(Self.space))
                            return frame.minX...frame.maxX
                        } action: { frames[index] = $0 }
                        #endif
                }
            }
            .padding(.leading, margins.leading)
            .padding(.trailing, margins.trailing)
            .coordinateSpace(.named(Self.space))
        }
    }

    private static var space: String { "pagingRow" }

    #if os(macOS)
    private func arrow(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .semibold))
                .frame(width: 34, height: 44)
                // 글자만이 아니라 유리 단추 전체를 누를 수 있게
                .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .glassEffect(in: .capsule)
        .onHover { inside in
            overArrow = inside
            updateHover()
        }
        .padding(.horizontal, 6)
        .transition(.opacity)
    }

    private func updateHover() {
        hideTask?.cancel()
        if overRow || overArrow {
            hovering = true
        } else {
            hideTask = Task {
                try? await Task.sleep(for: .milliseconds(250))
                if !Task.isCancelled { hovering = false }
            }
        }
    }

    /// 걸려 잘린 카드에 맞춰 넘긴다: > 는 오른쪽 끝에 걸린 카드가 맨 앞으로, < 는 왼쪽 끝에 걸린 카드가 맨 뒤로
    private func page(_ direction: CGFloat) {
        let cards = frames.values.sorted { $0.lowerBound < $1.lowerBound }
        var target: CGFloat
        if direction > 0 {
            let right = offset + containerWidth
            if let cut = cards.first(where: { $0.upperBound > right + 1 }) {
                target = cut.lowerBound - margins.leading
            } else {
                target = contentWidth - containerWidth
            }
        } else {
            if let cut = cards.last(where: { $0.lowerBound < offset - 1 }) {
                target = cut.upperBound + margins.trailing - containerWidth
            } else {
                target = 0
            }
        }
        // 카드가 보이는 폭보다 넓어 제자리면 한 화면만큼
        if direction > 0, target <= offset + 1 { target = offset + containerWidth }
        if direction < 0, target >= offset - 1 { target = offset - containerWidth }
        target = min(max(target, 0), max(contentWidth - containerWidth, 0))
        withAnimation(.easeInOut(duration: 0.35)) { position.scrollTo(x: target) }
    }
    #endif
}
