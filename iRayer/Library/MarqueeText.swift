import SwiftUI

/// 한 줄 글자. 칸보다 길면 `…` 으로 자르지 않고 잠시 멈췄다가 왼쪽으로 흘러간 뒤 처음부터 다시 흐른다.
/// 화면에 보이는 동안만 움직인다 (사라지면 task 가 취소된다).
struct MarqueeText: View {
    let text: String
    /// 끝과 다시 시작하는 글자 사이 간격
    var gap: CGFloat = 40
    /// 초당 이동 거리 (pt)
    var speed: CGFloat = 30
    /// 흐르기 전에 멈춰 있는 시간
    var pause: Duration = .seconds(2)
    /// 칸에 다 들어가면 가운데 정렬 (제목 줄용)
    var centered = false

    @State private var textWidth: CGFloat = 0
    @State private var boxWidth: CGFloat = 0
    @State private var offset: CGFloat = 0

    private var overflows: Bool { boxWidth > 0 && textWidth > boxWidth + 0.5 }

    var body: some View {
        // 높이와 칸 너비는 한 줄짜리 글자로 정하고, 실제 글자는 그 위에 겹쳐 그린다
        Text(text)
            .lineLimit(1)
            .hidden()
            .frame(maxWidth: .infinity, alignment: .leading)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { boxWidth = $0 }
            .overlay(alignment: centered && !overflows ? .center : .leading) {
                HStack(spacing: gap) {
                    Text(text)
                    if overflows { Text(text) }
                }
                .fixedSize()
                .offset(x: offset)
                // 칸 밖으로 넘친 글자가 옆 칸의 터치를 가로채지 않게 한다
                .allowsHitTesting(false)
            }
            .background {
                Text(text)
                    .fixedSize()
                    .hidden()
                    .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { textWidth = $0 }
            }
            .clipped()
            // clipped 는 그리기만 자르고 터치 영역은 자르지 않는다 → 터치 영역을 이 칸으로 한정
            .contentShape(.rect)
            .task(id: overflows ? "\(text)|\(textWidth)" : nil) {
                offset = 0
                guard overflows else { return }
                let distance = textWidth + gap
                let duration = Double(distance / speed)
                while !Task.isCancelled {
                    try? await Task.sleep(for: pause)
                    guard !Task.isCancelled else { break }
                    withAnimation(.linear(duration: duration)) { offset = -distance }
                    try? await Task.sleep(for: .seconds(duration))
                    // 두 번째 글자가 첫 글자 자리에 와 있으므로 애니메이션 없이 되돌리면 이어져 보인다
                    var transaction = Transaction()
                    transaction.disablesAnimations = true
                    withTransaction(transaction) { offset = 0 }
                }
            }
    }
}
