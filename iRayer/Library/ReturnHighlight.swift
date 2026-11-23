import Observation
import SwiftUI

/// 상세 화면(영상 정보·이미지뷰어)에서 목록으로 돌아올 때, 보던 카드를 찾아 보여준다.
/// 화면 방향이 바뀌며 돌아오면 칸 수가 달라져 스크롤이 어긋나므로, 카드가 다 보이지 않으면 가운데로 스크롤한다.
/// 표시(그림 테두리)는 그 목록 화면이 떠 있는 동안 남고, 다른 것을 보고 돌아오면 그 카드로 옮겨 간다.
/// 목록을 나갔다 다시 들어오면 새 화면이라 표시가 없다.
@Observable
final class ReturnHighlight {
    static let shared = ReturnHighlight()

    /// 돌아온 일 (같은 카드로 또 돌아와도 바뀌도록 번호를 붙인다)
    struct Event: Equatable {
        /// 그 항목을 가리킬 수 있는 값들: 파일 주소, 재생 기록 키 (목록마다 쓰는 id 가 다르다)
        let ids: [AnyHashable]
        let serial: Int
    }

    private(set) var event: Event?

    /// 화면에 거의 다 보이는 카드 (스크롤할지 정하는 데만 쓰므로 화면을 다시 그리지 않는다)
    @ObservationIgnored private var visible: Set<AnyHashable> = []

    private init() {}

    func returned(from file: VideoFile) {
        let ids: [AnyHashable] = [file.url, file.stateKey]
        returned(ids)
    }

    func returned(_ ids: [AnyHashable]) {
        event = Event(ids: ids, serial: (event?.serial ?? 0) + 1)
    }

    func setVisible(_ id: AnyHashable, _ isVisible: Bool) {
        if isVisible { visible.insert(id) } else { visible.remove(id) }
    }

    func isVisible(_ id: AnyHashable) -> Bool {
        visible.contains(id)
    }
}

extension EnvironmentValues {
    /// 목록이 표시하고 있는 카드 id
    @Entry var returnHighlightedID: AnyHashable?
    /// 이 카드가 표시 중인지 (카드 안의 그림이 테두리를 두른다)
    @Entry var isReturnHighlighted = false
}

extension View {
    /// 돌아왔을 때 표시될 수 있는 카드 (`id` 는 목록에서 스크롤에 쓰는 id 와 같게)
    func returnHighlight(_ id: AnyHashable) -> some View {
        modifier(ReturnHighlightCard(id: id))
    }

    /// 카드의 그림(썸네일·포스터): 표시 중이면 파란 테두리
    func returnHighlightBorder(cornerRadius: CGFloat) -> some View {
        modifier(ReturnHighlightBorder(cornerRadius: cornerRadius))
    }

    /// 목록: 돌아온 카드가 이 목록에 있으면 (안 보이면 스크롤하고) 표시한다
    func showsReturnHighlight(ids: [AnyHashable], proxy: ScrollViewProxy?) -> some View {
        modifier(ReturnHighlightList(ids: ids, proxy: proxy))
    }
}

private struct ReturnHighlightCard: ViewModifier {
    let id: AnyHashable
    @Environment(\.returnHighlightedID) private var highlightedID

    func body(content: Content) -> some View {
        content
            .environment(\.isReturnHighlighted, highlightedID == id)
            .onScrollVisibilityChange(threshold: 0.9) { ReturnHighlight.shared.setVisible(id, $0) }
    }
}

private struct ReturnHighlightBorder: ViewModifier {
    let cornerRadius: CGFloat
    @Environment(\.isReturnHighlighted) private var isHighlighted

    func body(content: Content) -> some View {
        content
            .overlay {
                if isHighlighted {
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .strokeBorder(.tint, lineWidth: 3)
                        .allowsHitTesting(false)
                }
            }
    }
}

private struct ReturnHighlightList: ViewModifier {
    let ids: [AnyHashable]
    let proxy: ScrollViewProxy?
    @State private var highlight = ReturnHighlight.shared
    /// 이 목록 화면에서 표시 중인 카드 (화면이 있는 동안만)
    @State private var highlightedID: AnyHashable?

    func body(content: Content) -> some View {
        content
            .environment(\.returnHighlightedID, highlightedID)
            .onChange(of: highlight.event) { _, event in
                guard let event, let id = event.ids.first(where: { ids.contains($0) }) else { return }
                highlightedID = id
                guard let proxy else { return }
                // 돌아오는 화면 전환이 끝난 뒤에 스크롤 (보이는지 판단도 그때)
                Task {
                    try? await Task.sleep(for: .milliseconds(150))
                    if !highlight.isVisible(id) {
                        withAnimation(.easeInOut(duration: 0.35)) { proxy.scrollTo(id, anchor: .center) }
                    }
                }
            }
    }
}
