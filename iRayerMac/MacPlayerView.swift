import AppKit
import SwiftUI

/// 재생 창의 내용: 영상 + 자막 + 마우스를 올리면 보이는 조작
struct MacPlayerView: View {
    let playback: MacPlayback
    @State private var showMenu = false
    /// 간소한 조작 막대의 세로 볼륨 슬라이더
    @State private var showVolume = false
    @FocusState private var focused: Bool

    private var model: PlayerModel { playback.model }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color.black
                VideoSurface(model: model)
                // 영상 어디를 끌어도 창이 움직인다 (제목 띠만 잡을 수 있던 것). 조작은 이 위에 있어 그대로 눌린다
                Color.clear
                    .contentShape(.rect)
                    .gesture(WindowDragGesture())
                    .allowsWindowActivationEvents(true)
                SubtitleText(text: model.subtitleText ?? "", baseSize: SubtitleText.baseSize(for: geometry.size))
                    .padding(.horizontal, 32)
                    .padding(.bottom, model.controlsVisible ? 96 : 28)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                    .opacity(model.subtitleText == nil ? 0 : 1)
                    .allowsHitTesting(false)
                status
                if model.controlsVisible {
                    controls(width: geometry.size.width)
                        .transition(.opacity)
                }
                // 시리즈·재생목록이면 끝나기 조금 전부터 다음 화 버튼 (같은 창에서 넘어간다)
                if let queue = playback.queue, queue.next != nil,
                   model.reachedEnd || NextUpButton.shows(duration: model.duration, time: model.currentTime) {
                    NextUpButton(kind: queue.kind, time: model.currentTime, duration: model.duration, ended: model.reachedEnd) {
                        playback.playNext()
                    }
                    .id(ObjectIdentifier(model))
                    .padding(.bottom, model.controlsVisible ? 90 : 28)
                    .padding(.trailing, 28)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                    .transition(.opacity)
                }
            }
        }
        .ignoresSafeArea()
        .animation(.easeInOut(duration: 0.2), value: model.controlsVisible)
        .onContinuousHover { phase in
            if case .active = phase { reveal() }
        }
        .onTapGesture(count: 2) { playback.toggleFullScreen() }
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onAppear {
            focused = true
            // 창을 다시 쓰면 앞 영상에서 숨긴 신호등이 그대로 남아 있으므로 지금 상태로 맞춘다
            setWindowButtons(visible: model.controlsVisible)
        }
        .onKeyPress(.space) { model.togglePlay(); return .handled }
        // ← → 설정한 시간, ⌘← ⌘→ 그 5배 (메뉴 단축키로 두면 검색 칸의 ⌘← ⌘→ 를 가로챈다)
        .onKeyPress(keys: [.rightArrow, .leftArrow]) { press in
            playback.skip(forward: press.key == .rightArrow, far: press.modifiers.contains(.command))
            return .handled
        }
        .onKeyPress(.escape) {
            guard playback.isFullScreen else { return .ignored }
            playback.toggleFullScreen()
            return .handled
        }
        .onKeyPress("f") { playback.toggleFullScreen(); return .handled }
        // Return 은 전체 화면으로 (전체 화면에서 다시 누르면 그대로), Esc 는 원래 크기로
        .onKeyPress(.return) {
            if !playback.isFullScreen { playback.toggleFullScreen() }
            return .handled
        }
        // 슬라이더 한 칸(10%)씩
        .onKeyPress(.upArrow) { playback.volume += MacPlayback.maxVolume / 10; reveal(); return .handled }
        .onKeyPress(.downArrow) { playback.volume -= MacPlayback.maxVolume / 10; reveal(); return .handled }
        .onChange(of: model.videoSize) { _, size in playback.fitWindow(to: size) }
        // 재생 설정·볼륨 팝오버가 열린 동안은 조작을 숨기지 않고, 닫으면 4초를 다시 센다
        .onChange(of: showMenu || showVolume) { _, open in
            model.holdsControls = open
            if !open { model.touchControls() }
        }
        .onChange(of: model.controlsVisible) { _, visible in
            setWindowButtons(visible: visible)
            // 조작이 숨으면 마우스 포인터도 숨긴다 (움직이면 다시 보인다)
            if !visible { NSCursor.setHiddenUntilMouseMoves(true) }
        }
        .preferredColorScheme(.dark)
    }

    /// 신호등(닫기·최소화·전체 화면)은 조작과 함께 보였다 숨는다
    private func setWindowButtons(visible: Bool) {
        playback.window?.standardWindowButton(.closeButton)?.superview?.animator().alphaValue = visible ? 1 : 0
    }

    private func reveal() {
        if !model.controlsVisible { model.controlsVisible = true }
        model.touchControls()
    }

    /// 불러오는 중·버퍼링·오류
    @ViewBuilder
    private var status: some View {
        if let error = model.playbackError {
            VStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle.fill").font(.largeTitle).foregroundStyle(.yellow)
                Text("재생할 수 없습니다").font(.headline)
                Text(error).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                Button("다시 시도") { model.retry() }
            }
            .padding(32)
        } else if !model.hasFirstFrame || model.isBuffering {
            ProgressView().controlSize(.large)
        }
    }

    private func controls(width: CGFloat) -> some View {
        VStack(spacing: 0) {
            // 위: 제목 (신호등 오른쪽)
            Text(model.file.title)
                .font(.headline)
                .lineLimit(1)
                .padding(.leading, 84)
                .padding(.trailing, 16)
                .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
                .padding(.top, 6)
                .background(LinearGradient(colors: [.black.opacity(0.75), .black.opacity(0.35), .clear], startPoint: .top, endPoint: .bottom).frame(height: 90), alignment: .top)
            Spacer()
            // 좁은 창(SD 영상 원본 크기 등)은 간소한 모양
            ControlBar(playback: playback, compact: width < 560, showMenu: $showMenu, showVolume: $showVolume)
                .padding(width < 560 ? 10 : 16)
        }
        .foregroundStyle(.white)
    }
}

/// 아래 조작 막대: 재생 · 시간 · 진행률 · 남은 시간 · 볼륨 · 재생 설정 · 항상 위 · 전체 화면.
/// 창이 좁으면(SD 영상을 원본 크기로 연 창 등) 간소한 모양: 위에 진행률을 꽉 차게, 아래에 재생 … 볼륨 · 설정 · 항상 위 · 전체 화면.
private struct ControlBar: View {
    let playback: MacPlayback
    let compact: Bool
    @Binding var showMenu: Bool
    @Binding var showVolume: Bool

    private var model: PlayerModel { playback.model }

    var body: some View {
        Group {
            if compact {
                VStack(spacing: 8) {
                    // 진행률 위: 왼쪽 지금 시간, 오른쪽 전체 시간
                    HStack {
                        Text(format(model.scrubTime ?? model.currentTime))
                            .foregroundStyle(.white.opacity(0.9))
                        Spacer(minLength: 0)
                        Text(format(model.duration))
                            .foregroundStyle(.secondary)
                    }
                    .font(.system(size: 11, weight: .medium))
                    .monospacedDigit()
                    .padding(.bottom, -6)
                    timeBar
                    HStack(spacing: 14) {
                        leadingButtons
                        Spacer(minLength: 0)
                        // 슬라이더 놓을 자리가 없어 누르면 세로 슬라이더를 띄운다
                        Button { showVolume.toggle() } label: { volumeIcon }
                            .help("볼륨 (↑ ↓)")
                            .popover(isPresented: $showVolume, arrowEdge: .top) {
                                Slider(value: volumeBinding, in: 0...MacPlayback.maxVolume)
                                    .controlSize(.small)
                                    .frame(width: 120)
                                    .rotationEffect(.degrees(-90))
                                    .frame(width: 36, height: 136)
                            }
                        trailingButtons
                    }
                }
                .padding(12)
                .glassEffect(in: .rect(cornerRadius: 18))
            } else {
                HStack(spacing: 14) {
                    leadingButtons
                    Text(format(model.scrubTime ?? model.currentTime))
                        .monospacedDigit()
                    timeBar
                    Text("-" + format(max(model.duration - (model.scrubTime ?? model.currentTime), 0)))
                        .monospacedDigit()
                    volumeIcon
                        .help("볼륨 (↑ ↓)")
                    Slider(value: volumeBinding, in: 0...MacPlayback.maxVolume)
                        .controlSize(.mini)
                        .frame(width: 70)
                    trailingButtons
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .glassEffect(in: .capsule)
            }
        }
        .buttonStyle(.borderless)
        .font(.system(size: 15, weight: .medium))
        .onHover { _ in model.touchControls() }
    }

    /// 재생 단추, 시리즈 회차·재생목록이면 양옆에 이전·다음
    @ViewBuilder
    private var leadingButtons: some View {
        if let queue = playback.queue {
            Button { playback.step(forward: false) } label: { Image(systemName: "backward.end.fill") }
                .help("이전 영상")
                .disabled(queue.previous == nil)
            playButton
            Button { playback.step(forward: true) } label: { Image(systemName: "forward.end.fill") }
                .help("다음 영상 (지금 영상은 다 본 것으로)")
                .disabled(queue.next == nil)
        } else {
            playButton
        }
    }

    private var playButton: some View {
        Button { model.togglePlay() } label: {
            Image(systemName: model.isPlaying ? "pause.fill" : "play.fill").frame(width: 20)
        }
        .help(model.isPlaying ? "일시 정지 (스페이스)" : "재생 (스페이스)")
    }

    private var timeBar: some View {
        MacTimeBar(time: model.scrubTime ?? model.currentTime, duration: model.duration, buffered: model.bufferedFraction) { value in
            if model.scrubTime == nil { model.beginScrub() }
            model.updateScrub(to: value)
        } onEnded: {
            if model.scrubTime != nil { model.endScrub() }
        }
    }

    private var volumeIcon: some View {
        Image(systemName: playback.volume == 0 ? "speaker.slash.fill" : playback.volume < 0.5 ? "speaker.wave.1.fill"
              : playback.volume <= 1 ? "speaker.wave.2.fill" : "speaker.wave.3.fill")
            .frame(width: 22)
    }

    private var volumeBinding: Binding<Double> {
        Binding(get: { playback.volume }, set: { playback.volume = $0 })
    }

    /// 재생 설정 · 항상 위 · 전체 화면
    @ViewBuilder
    private var trailingButtons: some View {
        Button { showMenu.toggle() } label: { Image(systemName: "gearshape") }
            .help("자막·오디오·배속")
            .popover(isPresented: $showMenu, arrowEdge: .top) {
                PlayerMenuView(model: model)
                    // 바뀜 (2026-11-08): 묶음 사이 여백(FormHeader)만큼 높임
                    // 바뀜 (2026-11-08): 아래 막대 단추의 글자(15pt 굵게)를 물려받아 설정 글자가 컸다 (사용자) → 맥 기본 글자로
                    .font(.body)
                    .frame(width: 380, height: 480)
            }
        Button { playback.toggleAlwaysOnTop() } label: {
            Image(systemName: playback.alwaysOnTop ? "pin.fill" : "pin")
        }
        .help(playback.alwaysOnTop ? "항상 위에 두기 끄기 (⌥⌘T)" : "항상 위에 두기 (⌥⌘T)")
        Button { playback.toggleFullScreen() } label: {
            Image(systemName: playback.isFullScreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
        }
        .help("전체 화면 (F)")
    }

    private func format(_ seconds: Double) -> String {
        let total = Int(seconds.rounded(.down))
        let h = total / 3600, m = total / 60 % 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}

/// 진행률: 누른 곳으로 가고 끌어서 움직인다. 받아 둔 곳(직접 읽기)까지는 옅게 칠한다.
private struct MacTimeBar: View {
    let time: Double
    let duration: Double
    /// 받아 둔 끝 위치 (0~1)
    let buffered: Double?
    let onChanged: (Double) -> Void
    let onEnded: () -> Void
    @State private var hovering = false
    @State private var dragging = false

    var body: some View {
        GeometryReader { geometry in
            let fraction = duration > 0 ? min(max(time / duration, 0), 1) : 0
            let active = hovering || dragging
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.25))
                if let buffered, buffered > fraction {
                    Capsule().fill(.white.opacity(0.3))
                        .frame(width: geometry.size.width * min(buffered, 1))
                }
                Capsule().fill(.white)
                    .frame(width: geometry.size.width * fraction)
            }
            .frame(height: active ? 7 : 5)
            .frame(maxHeight: .infinity)
            .contentShape(.rect)
            .onHover { hovering = $0 }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        dragging = true
                        guard duration > 0, geometry.size.width > 0 else { return }
                        onChanged(min(max(value.location.x / geometry.size.width, 0), 1) * duration)
                    }
                    .onEnded { _ in
                        dragging = false
                        onEnded()
                    }
            )
            .animation(.easeOut(duration: 0.12), value: active)
        }
        .frame(height: 18)
        .frame(minWidth: 60)
    }
}

/// VLC 가 영상을 그리는 뷰
struct VideoSurface: NSViewRepresentable {
    let model: PlayerModel

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.black.cgColor
        model.attach(to: view)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}
