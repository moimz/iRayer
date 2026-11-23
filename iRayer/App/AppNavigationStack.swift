import SwiftUI
import Observation

/// 쌓인 화면 길과 앞으로 가기 기억 (Finder 의 ‹ › 처럼)
@Observable
final class StackHistory {
    var path = NavigationPath() {
        didSet {
            // 새로 들어가면 앞으로 갈 길은 버린다 (뒤로·앞으로 가기로 바꾼 것과, 같은 길을 다시 써 넣는 것은 빼고)
            if !moving, path.count > oldValue.count { ahead.removeAll() }
        }
    }
    private var ahead: [NavigationPath] = []
    private var moving = false

    var canGoBack: Bool { !path.isEmpty }
    var canGoForward: Bool { !ahead.isEmpty }

    /// steps 만큼 뒤로 (경로 제목에서 상위 폴더를 누르면 여러 단계)
    func goBack(_ steps: Int = 1) {
        guard steps > 0, path.count >= steps else { return }
        ahead.append(path)
        move { path.removeLast(steps) }
    }

    func goForward() {
        guard let next = ahead.popLast() else { return }
        move { path = next }
    }

    private func move(_ change: () -> Void) {
        moving = true
        change()
        moving = false
    }
}

extension EnvironmentValues {
    /// 지금 화면이 든 스택 (맥 도구 막대의 ‹ › 가 쓴다)
    @Entry var stackHistory: StackHistory?
}

/// 화면을 쌓는 스택. 맥은 도구 막대 왼쪽에 ‹ › 를 늘 두고 (갈 곳이 없으면 흐리게) 시스템 뒤로 버튼은 숨긴다.
/// 시스템 뒤로 버튼은 쌓였을 때만 나타나 옆 버튼들을 밀어서 헷갈렸다.
struct AppNavigationStack<Root: View>: View {
    var history: StackHistory?
    @ViewBuilder var root: () -> Root
    @State private var own = StackHistory()

    init(history: StackHistory? = nil, @ViewBuilder root: @escaping () -> Root) {
        self.history = history
        self.root = root
    }

    var body: some View {
        let history = self.history ?? own
        NavigationStack(path: Bindable(history).path) {
            root()
                .stackChrome(history, isRoot: true)
        }
    }
}

extension View {
    /// 스택 안 화면마다: 스택을 알려 주고 (맥은 쌓인 화면이 스택 둘레의 환경값을 못 받는다) 맥은 ‹ › 를 단다
    /// isRoot: 스택 맨 아래 화면 (그 밖의 쌓인 화면은 언제나 뒤로 갈 수 있다)
    func stackChrome(_ history: StackHistory?, isRoot: Bool = false) -> some View {
        modifier(StackChrome(history: history, isRoot: isRoot))
    }
}

private struct StackChrome: ViewModifier {
    let history: StackHistory?
    var isRoot = false
    @Environment(\.dismiss) private var dismiss

    func body(content: Content) -> some View {
        #if os(macOS)
        content
            .environment(\.stackHistory, history)
            .navigationBarBackButtonHidden(true)
            .toolbar {
                if let history {
                    ToolbarItemGroup(placement: .navigation) {
                        // 쌓인 화면은 늘 켠다: 앱을 켜고 홈에서 처음 들어간 화면은 ‹ 가 흐린 채로 남았다 (도구 막대가 스택 상태를 늦게 받음).
                        // 스택 기록이 비어 있으면 시스템 뒤로(dismiss)로 나간다
                        Button("뒤로", systemImage: "chevron.left") {
                            if history.canGoBack { history.goBack() } else { dismiss() }
                        }
                            .disabled(isRoot && !history.canGoBack)
                            .keyboardShortcut("[")
                            .help("뒤로 (⌘[)")
                        Button("앞으로", systemImage: "chevron.right") { history.goForward() }
                            .disabled(!history.canGoForward)
                            .keyboardShortcut("]")
                            .help("앞으로 (⌘])")
                    }
                }
            }
        #else
        content
            .environment(\.stackHistory, history)
        #endif
    }
}

// MARK: - 새로 고침

/// 맥의 "새로 고침" (보기 메뉴 ⌘R, 앱으로 돌아올 때). 늘어나면 보이는 화면이 다시 읽는다.
@Observable
final class RefreshSignal {
    static let shared = RefreshSignal()
    private(set) var count = 0
    @ObservationIgnored private var last = Date.now

    private init() {}

    func send() {
        count += 1
        last = .now
    }

    /// 앱으로 돌아올 때: 너무 자주 다시 읽지 않게 5분에 한 번
    func sendIfStale() {
        if Date.now.timeIntervalSince(last) > 300 { send() }
    }
}

extension View {
    /// 새로 고침: 아이폰·아이패드는 당겨서, 맥은 보기 메뉴의 "새로 고침"(⌘R)과 앱으로 돌아올 때
    func appRefreshable(_ action: @escaping @Sendable () async -> Void) -> some View {
        modifier(AppRefreshable(action: action))
    }
}

private struct AppRefreshable: ViewModifier {
    let action: @Sendable () async -> Void
    @State private var signal = RefreshSignal.shared

    func body(content: Content) -> some View {
        #if os(macOS)
        content
            .onChange(of: signal.count) { Task { await action() } }
        #else
        content
            .refreshable { await action() }
        #endif
    }
}

