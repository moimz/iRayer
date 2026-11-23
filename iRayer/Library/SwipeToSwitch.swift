import SwiftUI

extension View {
    /// 분할 단추로 고르는 화면을 좌우로 밀어서도 바꾼다 (왼쪽으로 밀면 다음, 오른쪽으로 밀면 이전).
    /// 왼쪽 끝에서 시작한 밀기는 뒤로 가기 몫이라 쓰지 않고, 위아래로 더 움직인 것은 스크롤로 본다.
    /// 미는 동안 offset 이 손가락을 따라가고 (화면이 옆 화면을 그려 보여 준다),
    /// 놓으면 넘기거나 제자리로 돌아간다. 캘린더 일 보기처럼 넘어갈 때 톡 하고 햅틱.
    /// turning: 옆에 그릴 보기 쪽 (1 다음, -1 이전, 0 없음). 되돌아가는 애니메이션이 끝날 때까지 남아 있어야
    /// 옆 보기가 제자리에서 흐려지며 돌아오는 화면과 겹치지 않는다.
    /// distance: 한 화면을 넘기는 거리 (보통 화면 폭)
    func swipeToPage<Value: Hashable>(_ selection: Binding<Value>, among values: [Value],
                                      offset: Binding<CGFloat>, turning: Binding<Int>, distance: CGFloat) -> some View {
        #if os(iOS)
        gesture(HorizontalPan { translation in
            guard let index = values.firstIndex(of: selection.wrappedValue) else { return }
            let step = translation < 0 ? 1 : -1
            // 끝 화면 너머로는 조금만 끌려 온다
            let exists = values.indices.contains(index + step)
            turning.wrappedValue = exists && translation != 0 ? step : 0
            offset.wrappedValue = exists ? translation : translation / 4
        } onEnd: { translation, velocity in
            guard let index = values.firstIndex(of: selection.wrappedValue) else { return }
            let step = translation.width < 0 ? 1 : -1
            // 1/3 넘게 밀었거나 같은 쪽으로 빠르게 튕겼으면 넘긴다
            let flung = abs(velocity.width) > 500 && (velocity.width < 0) == (translation.width < 0)
            guard values.indices.contains(index + step), abs(translation.width) > distance / 3 || flung else {
                withAnimation(.snappy) {
                    offset.wrappedValue = 0
                } completion: {
                    // 그새 다시 밀기 시작했으면 그대로 둔다
                    if offset.wrappedValue == 0 { turning.wrappedValue = 0 }
                }
                return
            }
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            withAnimation(.snappy(duration: 0.25)) {
                offset.wrappedValue = -CGFloat(step) * distance
            } completion: {
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) {
                    selection.wrappedValue = values[index + step]
                    offset.wrappedValue = 0
                    turning.wrappedValue = 0
                }
            }
        })
        #else
        self
        #endif
    }

    /// swipeToPage 의 offset 만큼 옮긴다 (shift: 옆 보기는 한 화면 폭 옆에).
    /// 거리 값은 이 안에서만 읽어서, 미는 동안 매 장면 바뀌어도 화면 전체(목록 거르기·정렬)를 다시 계산하지 않는다.
    func pageSlide(_ offset: Binding<CGFloat>, shift: CGFloat = 0) -> some View {
        modifier(PageSlide(offset: offset, shift: shift))
    }
}

private struct PageSlide: ViewModifier {
    @Binding var offset: CGFloat
    let shift: CGFloat

    func body(content: Content) -> some View {
        content.offset(x: offset + shift)
    }
}

#if os(iOS)
/// 가로 밀기. SwiftUI DragGesture 는 같이 돌기만 해서 포스터 위에서 밀면 그 포스터도 눌린 것으로 열렸다.
/// UIKit 밀기 인식기는 밀기로 알아보는 순간 아래 단추의 터치를 취소한다.
private struct HorizontalPan: UIGestureRecognizerRepresentable {
    /// 미는 중: 가로로 움직인 거리
    let onChange: (CGFloat) -> Void
    /// 놓았을 때: 움직인 거리, 속도
    let onEnd: (CGSize, CGSize) -> Void

    func makeUIGestureRecognizer(context: Context) -> UIPanGestureRecognizer {
        let pan = UIPanGestureRecognizer()
        pan.delegate = context.coordinator
        return pan
    }

    func handleUIGestureRecognizerAction(_ recognizer: UIPanGestureRecognizer, context: Context) {
        let translation = recognizer.translation(in: recognizer.view)
        switch recognizer.state {
        case .changed:
            onChange(translation.x)
        case .cancelled, .failed:
            onEnd(.zero, .zero)
        case .ended:
            let velocity = recognizer.velocity(in: recognizer.view)
            onEnd(CGSize(width: translation.x, height: translation.y), CGSize(width: velocity.x, height: velocity.y))
        default:
            break
        }
    }

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        /// 가로로 움직이기 시작했고 화면 왼쪽 끝(뒤로 가기)에서 시작하지 않았을 때만
        func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
            guard let pan = recognizer as? UIPanGestureRecognizer, let view = pan.view else { return false }
            let velocity = pan.velocity(in: view)
            let start = pan.location(in: nil).x - pan.translation(in: nil).x
            return abs(velocity.x) > abs(velocity.y) * 2 && start > 30
        }
    }
}
#endif
