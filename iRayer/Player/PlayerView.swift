import AVFoundation
import SwiftUI

/// 플레이어 (전체 화면). PlayerHost 의 창에 뜬다. PiP 는 아이폰 기본 PiP (SystemPiP).
struct PlayerView: View {
    @State private var model: PlayerModel
    @State private var showMenu = false
    @State private var showPlaylist = false
    @State private var host = PlayerHost.shared
    @State private var external = ExternalDisplay.shared
    @State private var airPlayMessage: String?
    @State private var airPlay: AirPlaySession?
    /// 기기 선택 창을 띄워 둔 동안 미리 준비해 둔 AirPlay 재생 (기기가 연결되면 airPlay 로 넘어간다)
    @State private var airPlayPending: AirPlaySession?
    @State private var airPlayPicker = 0
    @State private var airPlayResumeAt: Double = 0
    /// 기기 선택 창을 열 때 재생 중이었다 (기기를 고르지 않고 닫으면 다시 재생한다)
    @State private var airPlayWasPlaying = false
    /// AirPlay 로 못 보냈는데 소리는 아직 AirPlay 기기로 나가고 있다 (알림에서 다시 시도할 수 있게)
    @State private var airPlayCanRetry = false
    /// 플레이어가 닫혔다 (닫힌 뒤 늦게 온 AirPlay 끝 알림으로 폰 재생을 다시 시작하지 않게)
    @State private var closed = false

    init(file: VideoFile, resume: Bool) {
        _model = State(initialValue: PlayerModel(file: file, resume: resume))
    }

    var body: some View {
        let framed = playerStack
            .statusBarHidden(!model.controlsVisible)
            .persistentSystemOverlays(model.controlsVisible ? .automatic : .hidden)
        return presentations(framed)
    }

    /// 영상·자막·컨트롤.
    /// Infuse 처럼 위쪽은 ✕ · AirPlay · PiP, 제목은 진행률 바 위. 위아래 컨트롤이 같은 안쪽 여백에 맞춰 놓인다.
    private var playerStack: some View {
        // 위쪽 버튼(✕ · AirPlay · PiP)은 시스템 제목 막대에 올려 다른 화면의 뒤로 버튼과 같은 자리에 둔다.
        NavigationStack {
            playerLayers
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("닫기", systemImage: "xmark") { host.close() }
                    }
                    ToolbarItemGroup(placement: .topBarTrailing) {
                        Button("AirPlay", systemImage: "airplayvideo") { Task { await startAirPlay() } }
                        if SystemPiP.isSupported {
                            Button("PiP", systemImage: "pip.enter") {
                                model.controlsVisible = false
                                _ = model.startSystemPiP()
                            }
                        }
                    }
                }
                .toolbarVisibility(model.controlsVisible ? .visible : .hidden, for: .navigationBar)
                .toolbarBackgroundVisibility(.hidden, for: .navigationBar)
                .toolbarColorScheme(.dark, for: .navigationBar)
                .navigationBarTitleDisplayMode(.inline)
        }
    }

    private var playerLayers: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            PlayerSurface(model: model)
                // 재생목록에서 영상을 바꾸면 새 플레이어에 붙도록 영상 뷰를 새로 만든다
                .id(ObjectIdentifier(model))
                .ignoresSafeArea()
            if !external.isConnected {
                AmbientLetterbox(image: model.ambientImage, videoFrame: model.videoFrame)
                    .ignoresSafeArea()
            }
            if external.isConnected {
                // 영상과 자막은 TV 에 나온다. 폰은 조작용.
                Label("TV에서 재생 중", systemImage: "tv")
                    .font(.headline)
                    .foregroundStyle(.white.opacity(0.6))
                    .allowsHitTesting(false)
            } else {
                SubtitleOverlay(text: model.subtitleText, videoBottomInset: model.videoBottomInset, raised: model.controlsVisible)
                    .ignoresSafeArea()
            }
            if model.isOpeningPiP {
                // PiP 단추를 누르면 바로 알린다 (영상 출력을 바꾸는 동안 화면이 까맣고, PiP 창은 조금 뒤에 뜬다).
                // 크게 보기로 돌아올 때 iOS 가 그리는 안내와 같은 모양·문구 (AVKit 의 PIP_COVER_CAPTION)
                ZStack {
                    Color.black
                    VStack(spacing: 14) {
                        Image(systemName: "pip")
                            .font(.system(size: 54, weight: .regular))
                        Text("이 비디오는 화면 속 화면에서 재생 중입니다.")
                            .font(.subheadline)
                            .multilineTextAlignment(.center)
                    }
                    .foregroundStyle(Color(white: 0.55))
                    .padding(.horizontal, 40)
                }
                .ignoresSafeArea()
                .allowsHitTesting(false)
                .transition(.opacity)
            }
            // 위쪽 제목 막대·안전 영역과 상관없이 화면 한가운데에
            PlayerStatusOverlay(model: model) { host.close() }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .ignoresSafeArea()
            if model.controlsVisible {
                PlayerControls(model: model, queue: airPlay == nil ? host.request?.queue.flatMap { $0.files.count > 1 ? $0 : nil } : nil) {
                    showMenu = true
                } onPlaylist: {
                    showPlaylist = true
                } onStep: { forward in
                    step(forward: forward)
                }
                .transition(.opacity)
            } else if let time = model.scrubTime {
                // UI 없이 화면을 끌어 탐색할 때: 오른쪽 위에 탐색 중인 시각만 작게
                Text(time.durationText)
                    .font(.subheadline.monospacedDigit().weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(.black.opacity(0.5), in: .capsule)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    .padding()
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            // 시리즈·재생목록이면 끝나기 조금 전부터 다음 화 버튼 (AirPlay 로 보내는 중에는 띄우지 않는다)
            // PiP 중에는 플레이어 창이 숨어 있어 다음 영상이 보이지 않은 채 소리만 나므로, 크게 보기로 돌아온 뒤에 띄운다
            if airPlay == nil, !host.inSystemPiP, let queue = host.request?.queue, let next = queue.next,
               model.reachedEnd || NextUpButton.shows(duration: model.duration, time: model.currentTime) {
                NextUpButton(kind: queue.kind, time: model.currentTime, duration: model.duration, ended: model.reachedEnd) {
                    play(next)
                }
                .id(ObjectIdentifier(model))
                // 조작이 보이면 아래 진행률 바 위로
                .padding(.bottom, model.controlsVisible ? 110 : 24)
                .padding()
                .transition(.opacity)
            }
        }
        .overlay(alignment: .topTrailing) {
            if let level = model.level {
                LevelIndicator(level: level)
                    // 조작이 보이면 위쪽 버튼 아래로
                    .padding(.top, model.controlsVisible ? 64 : 0)
                    .padding()
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.15), value: model.scrubTime == nil)
        .animation(.easeOut(duration: 0.15), value: model.level == nil)
        .animation(.easeOut(duration: 0.15), value: model.isOpeningPiP)
    }
}

/// 밝기·볼륨을 바꾸는 중: 아이콘 + 막대 + 퍼센트
private struct LevelIndicator: View {
    let level: PlayerModel.Level

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.subheadline.weight(.semibold))
                .frame(width: 20)
            ProgressView(value: Double(level.value))
                .tint(.white)
                .frame(width: 70)
            Text("\(Int((level.value * 100).rounded()))%")
                .font(.subheadline.monospacedDigit().weight(.semibold))
                .frame(width: 42, alignment: .trailing)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.black.opacity(0.5), in: .capsule)
    }

    private var symbol: String {
        switch level.kind {
        case .brightness: level.value < 0.5 ? "sun.min.fill" : "sun.max.fill"
        case .volume: level.value == 0 ? "speaker.slash.fill" : level.value < 0.5 ? "speaker.wave.1.fill" : "speaker.wave.3.fill"
        }
    }
}

extension PlayerView {
    /// 플레이어가 띄우는 시트·알림과 화면 수명 처리
    fileprivate func presentations(_ content: some View) -> some View {
        content
        // 화면 미러링 중이면 TV 에는 영상만 보여준다 (iOS 27 부터 필요한 등록)
        .background(ExternalDisplayRegistrar().allowsHitTesting(false))
        .background(RoutePickerPresenter(trigger: airPlayPicker) { airPlayPickerClosed() }.frame(width: 1, height: 1).opacity(0.02))
        .animation(.easeInOut(duration: 0.2), value: model.controlsVisible)
        .onAppear {
            model.start()
            ExternalDisplay.shared.player = model
            // AirPlay 를 접어 둔 채 다른 영상으로 바꿨으면 열자마자 TV 로 보낸다
            if host.takeSendToAirPlay() { Task { await startAirPlay() } }
        }
        .onDisappear {
            ExternalDisplay.shared.player = nil
            // TV 로 보내던 중에 플레이어가 닫히면(다른 영상으로 바꿈) TV 재생도 끝낸다
            closed = true
            airPlay?.finish()
            model.close()
        }
        // 앱 아래 작은 재생 막대·접기를 위해 AirPlay 시작·끝을 알린다
        .onChange(of: airPlay?.id) { host.setAirPlay(airPlay) }
        .sheet(isPresented: $showMenu) {
            PlayerMenuView(model: model)
                .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $showPlaylist) {
            PlaylistView(current: model.file) { file in play(file) }
                .presentationDetents([.medium, .large])
        }
        .fullScreenCover(item: $airPlay) { session in
            AirPlayScreen(session: session, title: model.file.title, onCollapse: { host.collapseAirPlay() }, onEnd: { position in
                guard !closed else { return }
                model.resume(at: position)
            }, onFailure: { position in
                guard !closed else { return }
                // TV 가 재생하다 실패했으면 그 자리부터 (처음부터 못 보냈으면 0 이 온다)
                if position > 0 { airPlayResumeAt = position }
                airPlayFailed(AirPlayHandoff.failedMessage)
            }, onProgress: { position in
                model.externalProgress(position)
            })
        }
        .onReceive(NotificationCenter.default.publisher(for: AVAudioSession.routeChangeNotification).receive(on: RunLoop.main)) { note in
            // 바뀜 (2026-11-09, 사용자): 쓰던 소리 기기(이어폰)가 사라지면 일시정지 (AirPlay 로 TV 에서 트는 중이면 그대로)
            if airPlay == nil,
               let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
               AVAudioSession.RouteChangeReason(rawValue: raw) == .oldDeviceUnavailable {
                model.pauseForLostRoute()
            }
            airPlayRouteChanged()
        }
        .alert("AirPlay", isPresented: Binding(
            get: { airPlayMessage != nil },
            set: { if !$0 { airPlayMessage = nil } }
        )) {
            if airPlayCanRetry {
                Button("다시 시도") { Task { await startAirPlay() } }
            }
            Button("확인", role: .cancel) {}
        } message: {
            Text(airPlayMessage ?? "")
        }
        .alert("재생 오류", isPresented: .constant(model.errorMessage != nil)) {
            Button("확인") { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
    }
}

extension PlayerView {
    /// 재생목록에서 고른 영상으로 바꿔 재생한다 (이어보기 위치가 있으면 거기부터)
    /// finishing: 보던 영상을 끝까지 안 봤어도 다 본 것으로 (다음 버튼으로 넘길 때)
    fileprivate func play(_ file: VideoFile, finishing: Bool = false) {
        let next = PlayerModel(file: file, resume: true)
        guard next.file.id != model.file.id else { return }
        let previous = model.file
        model.close()
        if finishing { LibraryData.markWatched(previous) }
        model = next
        // 영상 뷰가 새로 붙으면 그때 시작된다 (PlayerModel.start)
        next.start()
        ExternalDisplay.shared.player = next
        host.moved(to: file)
    }

    /// 대기열(시리즈 회차·재생목록)의 다음·이전 영상으로. 다음으로 넘기면 보던 영상은 다 본 것으로 한다
    fileprivate func step(forward: Bool) {
        guard let queue = host.request?.queue, let file = forward ? queue.next : queue.previous else { return }
        play(file, finishing: forward)
    }

    /// AirPlay 기기 선택 창을 연다. 창이 떠 있는 동안 폰 재생은 잠깐 멈춘다
    /// (기기를 고르는 순간 소리만 먼저 TV 로 넘어가 폰에는 멈춘 화면만 남지 않게). 기기가 연결되면 그때 TV 로 넘긴다.
    fileprivate func startAirPlay() async {
        airPlayCanRetry = false
        airPlayPending = AirPlaySession(model: model)
        airPlayWasPlaying = model.isPlaying
        airPlayResumeAt = model.currentTime
        model.pauseForHandoff()
        if AirPlayHandoff.isAirPlayRoute {
            // 이미 AirPlay 로 소리가 나가고 있으면 바로 넘긴다
            airPlayRouteChanged()
        } else {
            airPlayPicker += 1
        }
    }

    /// 소리 출력이 AirPlay 기기로 바뀌면(기기 선택 창에서 골랐으면) 폰 재생을 멈추고 TV 로 넘긴다
    fileprivate func airPlayRouteChanged() {
        guard airPlay == nil, let pending = airPlayPending, AirPlayHandoff.isAirPlayRoute else { return }
        airPlayPending = nil
        airPlay = pending
        Task {
            guard await pending.start(at: airPlayResumeAt) else {
                pending.finish()
                airPlay = nil
                airPlayFailed(AirPlayHandoff.noNetworkMessage)
                return
            }
        }
    }

    /// 기기 선택 창이 닫혔다. 기기를 골랐으면 곧 소리 출력이 바뀌어 넘어가고,
    /// 고르지 않았으면(그냥 닫았거나 iPhone 을 골랐으면) 멈췄던 재생을 다시 한다.
    fileprivate func airPlayPickerClosed() {
        Task {
            // 소리 출력 바뀜은 창이 닫힌 뒤 조금 늦게 오기도 한다 (2초까지 기다린다)
            for _ in 0..<10 {
                try? await Task.sleep(for: .milliseconds(200))
                guard airPlay == nil, airPlayPending != nil else { return }
                if AirPlayHandoff.isAirPlayRoute {
                    airPlayRouteChanged()
                    return
                }
            }
            airPlayPending = nil
            if airPlayWasPlaying { model.resume(at: airPlayResumeAt) }
        }
    }

    /// TV 로 보내지 못했다. 소리가 아직 AirPlay 기기로 나가면 폰에서 이어 재생하지 않는다 (소리만 TV 로 가므로):
    /// 멈춘 채로 두고 다시 시도할 수 있게 한다. AirPlay 가 끊겨 있으면 폰에서 이어 재생한다.
    fileprivate func airPlayFailed(_ message: String) {
        if AirPlayHandoff.isAirPlayRoute {
            model.seek(to: airPlayResumeAt)
            airPlayCanRetry = true
            airPlayMessage = message == AirPlayHandoff.failedMessage ? AirPlayHandoff.failedStillConnectedMessage : message
        } else {
            airPlayCanRetry = false
            if airPlayWasPlaying { model.resume(at: airPlayResumeAt) }
            airPlayMessage = message
        }
    }
}

/// UI 가 표시된 상태의 재생 컨트롤. 빈 영역은 터치가 아래 화면(제스처)으로 통과한다.
/// Infuse 처럼 위쪽은 ✕ · (오른쪽) AirPlay · PiP, 아래쪽은 진행률 바 위에 제목(왼쪽, 길면 흐름)과 설정·재생목록 버튼(오른쪽).
/// 위아래 모두 같은 안쪽 여백(안전 영역 + 여백)에 맞춘다.
private struct PlayerControls: View {
    let model: PlayerModel
    /// 시리즈·재생목록이면 가운데 재생 단추 양옆에 이전·다음
    let queue: PlayQueue?
    let onSettings: () -> Void
    let onPlaylist: () -> Void
    let onStep: (_ forward: Bool) -> Void
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                LinearGradient(colors: [.black.opacity(0.6), .clear], startPoint: .top, endPoint: .bottom)
                    .frame(height: 140)
                Spacer()
                LinearGradient(colors: [.clear, .black.opacity(0.7)], startPoint: .top, endPoint: .bottom)
                    .frame(height: 200)
            }
            .ignoresSafeArea()
            .allowsHitTesting(false)

            VStack {
                Spacer()

                HStack(spacing: sizeClass == .regular ? 40 : 28) {
                    if let queue {
                        stepButton("이전 영상", systemImage: "backward.end.fill", enabled: queue.previous != nil) { onStep(false) }
                    }
                    // 첫 장면이 나오기 전에는 가운데 "불러오는 중" 표시와 겹치지 않게 숨긴다
                    Button {
                        model.togglePlay()
                    } label: {
                        Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                            // 넓은 화면(아이패드)에서는 조금 크게
                            .font(.system(size: sizeClass == .regular ? 44 : 34))
                            .frame(width: sizeClass == .regular ? 72 : 56, height: sizeClass == .regular ? 72 : 56)
                    }
                    .buttonStyle(.glass)
                    .buttonBorderShape(.circle)
                    .opacity(model.hasFirstFrame && model.playbackError == nil ? 1 : 0)
                    .allowsHitTesting(model.hasFirstFrame && model.playbackError == nil)
                    if let queue {
                        stepButton("다음 영상", systemImage: "forward.end.fill", enabled: queue.next != nil) { onStep(true) }
                    }
                }

                Spacer()

                VStack(spacing: 10) {
                    HStack(spacing: 16) {
                        MarqueeText(text: model.file.title)
                            .font(.title3.bold())
                            .foregroundStyle(.white)
                        buttonGroup {
                            controlButton("재생 설정", systemImage: "gearshape.fill", action: onSettings)
                            controlButton("재생목록", systemImage: "list.bullet.rectangle.portrait", action: onPlaylist)
                        }
                    }
                    ScrubBar(model: model)
                }
                // 이 영역의 터치는 화면 제스처(드래그 탐색·탭)가 가져가지 않게 한다
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { model.bottomControlsFrame = $0 }
            }
            .padding()
        }
    }

    /// 재생 단추 옆의 이전·다음 (재생 단추보다 작게)
    private func stepButton(_ title: String, systemImage: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: sizeClass == .regular ? 24 : 20))
                .frame(width: sizeClass == .regular ? 52 : 44, height: sizeClass == .regular ? 52 : 44)
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.circle)
        .disabled(!enabled)
        .accessibilityLabel(title)
    }

    /// 아이콘 버튼 묶음 (유리 캡슐)
    private func buttonGroup<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 0, content: content)
            .padding(.horizontal, 4)
            .glassEffect(.regular.interactive(), in: .capsule)
    }

    private func controlButton(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.title3)
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }
}

/// 레터박스(영상이 없는 위아래·좌우)를 영상 색으로 은은하게 채운다 (Infuse 방식).
/// 영상의 작은 스냅숏을 화면 가득 늘려 흐리게 하고 어둡게 눌러서, 영상 자리만 비우고 덮는다 (VLC 가 그린 검은 띠 위).
/// 바뀜 (2026-11-07): 화면 가득 늘리면 빈 자리에 맞닿은 곳이 영상 가장자리 색이 아니라 경계에서 색이 끊겼다 (위 5% 가 검고 아래가 희면 검은 줄 위에 회색).
/// 이제 영상 가장자리 띠(약 1%, 맨 끝 인코딩 테두리는 건너뜀)를 테두리 방향으로 흐려 색 한 줄로 만들고, 빈 자리로 늘리며
/// 화면 끝으로 갈수록 투명하게(끝 0%) 검은 바탕에 녹인다. 검은 레터박스가 들어간 영상은 가장자리가 검어 저절로 검게 된다.
private struct AmbientLetterbox: View {
    let image: UIImage?
    let videoFrame: CGRect

    var body: some View {
        GeometryReader { geometry in
            let edges = image.flatMap { AmbientEdges.cached(for: $0) }
            ZStack {
                if let edges {
                    bars(edges, in: geometry.size)
                        // 스냅숏이 바뀔 때 천천히 섞이게
                        .id(ObjectIdentifier(edges))
                        .transition(.opacity)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .animation(.easeInOut(duration: 1.5), value: edges.map(ObjectIdentifier.init))
        }
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private func bars(_ edges: AmbientEdges, in size: CGSize) -> some View {
        let frame = videoFrame
        // VLC 가 그린 검은 띠가 가장자리에 1pt 남지 않도록 영상 쪽으로 살짝 겹친다
        let overlap: CGFloat = 1
        if frame.height < size.height - 4 {
            let top = frame.minY + overlap
            let bottom = size.height - frame.maxY + overlap
            if top > overlap {
                strip(edges.top, horizontal: true, fadeTo: .top)
                    .frame(width: frame.width, height: top)
                    .position(x: frame.midX, y: top / 2)
            }
            if bottom > overlap {
                strip(edges.bottom, horizontal: true, fadeTo: .bottom)
                    .frame(width: frame.width, height: bottom)
                    .position(x: frame.midX, y: size.height - bottom / 2)
            }
        }
        if frame.width < size.width - 4 {
            let left = frame.minX + overlap
            let right = size.width - frame.maxX + overlap
            if left > overlap {
                strip(edges.left, horizontal: false, fadeTo: .leading)
                    .frame(width: left, height: frame.height)
                    .position(x: left / 2, y: frame.midY)
            }
            if right > overlap {
                strip(edges.right, horizontal: false, fadeTo: .trailing)
                    .frame(width: right, height: frame.height)
                    .position(x: size.width - right / 2, y: frame.midY)
            }
        }
    }

    /// 색 한 줄을 빈 자리 크기로 늘리고, 영상 쪽은 진하게 바깥(화면 끝)은 투명하게
    private func strip(_ line: CGImage, horizontal: Bool, fadeTo outside: UnitPoint) -> some View {
        let inside = UnitPoint(x: 1 - outside.x, y: 1 - outside.y)
        return Image(decorative: line, scale: 1)
            .resizable()
            .interpolation(.high)
            // 바뀜 (2026-11-07): 너무 밝아 검은 덮개 0.3 → 0.55 (사용자)
            .overlay(Color.black.opacity(0.55))
            .mask {
                // 안쪽은 진하고 바깥에서 빨리 사라지는 곡선
                LinearGradient(stops: [
                    .init(color: .black, location: 0),
                    .init(color: .black.opacity(0.7), location: 0.25),
                    .init(color: .black.opacity(0.3), location: 0.55),
                    .init(color: .black.opacity(0.08), location: 0.8),
                    .init(color: .clear, location: 1),
                ], startPoint: inside, endPoint: outside)
            }
    }
}

/// 스냅숏의 네 가장자리 띠를 색 한 줄(가로 띠는 폭×1, 세로 띠는 1×높이)로 만든다
private final class AmbientEdges {
    let top: CGImage
    let bottom: CGImage
    let left: CGImage
    let right: CGImage

    nonisolated private init(top: CGImage, bottom: CGImage, left: CGImage, right: CGImage) {
        self.top = top
        self.bottom = bottom
        self.left = left
        self.right = right
    }

    private static var cache: (key: ObjectIdentifier, edges: AmbientEdges?)?

    static func cached(for image: UIImage) -> AmbientEdges? {
        let key = ObjectIdentifier(image)
        if let cache, cache.key == key { return cache.edges }
        let edges = image.cgImage.flatMap { make($0) }
        cache = (key, edges)
        return edges
    }

    nonisolated private static func make(_ image: CGImage) -> AmbientEdges? {
        let width = image.width, height = image.height
        guard width >= 8, height >= 8 else { return nil }
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }

        // 맨 끝 줄(인코딩 테두리·깨진 픽셀)은 건너뛰고, 그 안쪽 약 1~2% 를 평균
        func band(_ length: Int) -> (skip: Int, size: Int) {
            (max(1, Int((Double(length) * 0.01).rounded())), max(1, Int((Double(length) * 0.02).rounded())))
        }
        let rows = band(height), columns = band(width)

        // 그림 줄 순서는 위에서 아래 (CGContext 메모리 첫 줄이 그림 맨 위)
        func rowLine(_ range: Range<Int>) -> [SIMD3<Double>] {
            (0..<width).map { x in
                var sum = SIMD3<Double>(repeating: 0)
                for y in range {
                    let i = (y * width + x) * 4
                    sum += SIMD3(Double(pixels[i]), Double(pixels[i + 1]), Double(pixels[i + 2]))
                }
                return sum / Double(range.count)
            }
        }
        func columnLine(_ range: Range<Int>) -> [SIMD3<Double>] {
            (0..<height).map { y in
                var sum = SIMD3<Double>(repeating: 0)
                for x in range {
                    let i = (y * width + x) * 4
                    sum += SIMD3(Double(pixels[i]), Double(pixels[i + 1]), Double(pixels[i + 2]))
                }
                return sum / Double(range.count)
            }
        }

        let top = rowLine(rows.skip ..< rows.skip + rows.size)
        let bottom = rowLine(height - rows.skip - rows.size ..< height - rows.skip)
        let left = columnLine(columns.skip ..< columns.skip + columns.size)
        let right = columnLine(width - columns.skip - columns.size ..< width - columns.skip)

        guard let topImage = lineImage(blurred(top), horizontal: true),
              let bottomImage = lineImage(blurred(bottom), horizontal: true),
              let leftImage = lineImage(blurred(left), horizontal: false),
              let rightImage = lineImage(blurred(right), horizontal: false) else { return nil }
        return AmbientEdges(top: topImage, bottom: bottomImage, left: leftImage, right: rightImage)
    }

    /// 테두리 방향으로 흐리기 (줄 길이의 약 8% 반경 상자 흐림 두 번, 끝은 끝 색을 이어 씀)
    nonisolated private static func blurred(_ line: [SIMD3<Double>]) -> [SIMD3<Double>] {
        let radius = max(1, line.count * 8 / 100)
        var current = line
        for _ in 0..<2 {
            current = current.indices.map { index in
                var sum = SIMD3<Double>(repeating: 0)
                for offset in -radius...radius {
                    sum += current[min(max(index + offset, 0), current.count - 1)]
                }
                return sum / Double(radius * 2 + 1)
            }
        }
        return current
    }

    nonisolated private static func lineImage(_ line: [SIMD3<Double>], horizontal: Bool) -> CGImage? {
        var bytes = [UInt8]()
        bytes.reserveCapacity(line.count * 4)
        for color in line {
            bytes += [UInt8(min(max(color.x, 0), 255)), UInt8(min(max(color.y, 0), 255)), UInt8(min(max(color.z, 0), 255)), 255]
        }
        let width = horizontal ? line.count : 1, height = horizontal ? 1 : line.count
        guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}

/// 앱이 직접 그리는 자막 (SRT·SMI·VTT). 보이는 영상의 아래쪽에 붙이고, UI 가 보일 때는 진행률 바와 겹치지 않도록 위로 올린다.
struct SubtitleOverlay: View {
    let text: String?
    /// 화면 아래에서 보이는 영상 아래쪽 가장자리까지의 거리
    let videoBottomInset: CGFloat
    let raised: Bool

    var body: some View {
        GeometryReader { geometry in
            VStack {
                Spacer()
                if let text {
                    // 글꼴·크기는 설정 > 자막 (가로 화면 기준, 세로 화면은 70%)
                    SubtitleText(text: text, baseSize: SubtitleText.baseSize(for: geometry.size))
                        .padding(.horizontal, 24)
                }
            }
            .frame(maxWidth: .infinity)
            // 화면 아래 가장자리(홈 인디케이터) 또는 진행률 바보다는 위에 둔다
            .padding(.bottom, max(videoBottomInset + 12, raised ? 140 : 24))
        }
        .allowsHitTesting(false)
        .animation(.easeOut(duration: 0.2), value: raised)
    }
}

/// 진행률 바. 드래그로 탐색할 수 있고, 화면 제스처로 탐색할 때도 함께 움직인다.
private struct ScrubBar: View {
    let model: PlayerModel

    var body: some View {
        TimeBar(time: model.scrubTime ?? model.currentTime, duration: model.duration, isScrubbing: model.scrubTime != nil,
                buffered: model.bufferedFraction) { target in
            if model.scrubTime == nil { model.beginScrub() }
            model.updateScrub(to: target)
        } onEnded: {
            model.endScrub()
        }
    }
}

/// 진행률 바 모양과 드래그 (플레이어와 AirPlay 화면이 같이 쓴다)
/// iOS 기본 플레이어처럼 화면 폭을 다 쓰고, 시간은 바 아래에 (지난 시간 · 남은 시간).
/// 바를 누른 곳으로 뛰지 않고 끌어서 움직이며, 손가락을 바에서 위아래로 멀리 뗄수록 천천히(정밀하게) 움직인다.
struct TimeBar: View {
    let time: Double
    let duration: Double
    let isScrubbing: Bool
    /// 시간 표시에 더할 값 (AirPlay 주소가 이어 재생한 위치부터 시작할 때)
    var labelOffset: Double = 0
    /// 받아 둔 끝 위치 (0~1). 지난 곳과 이 사이를 옅게 칠한다.
    var buffered: Double?
    /// 드래그 중인 위치 (초)
    let onChanged: (Double) -> Void
    let onEnded: () -> Void

    /// 드래그 중: 마지막 손가락 x 와 그때까지 옮긴 위치
    @State private var drag: (x: CGFloat, time: Double, moved: Bool)?
    @State private var speed = ScrubSpeed.normal
    /// 손가락이 닿아 있는 동안 true. 제스처가 취소돼도(onEnded 가 불리지 않아도) false 로 돌아온다.
    @GestureState private var touching = false

    var body: some View {
        let active = drag != nil || isScrubbing
        VStack(spacing: 4) {
            GeometryReader { geometry in
                let fraction = duration > 0 ? min(max(time / duration, 0), 1) : 0
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.3))
                    if let buffered, buffered > fraction {
                        Capsule().fill(.white.opacity(0.35))
                            .frame(width: geometry.size.width * min(buffered, 1))
                    }
                    Capsule().fill(.white)
                        .frame(width: geometry.size.width * fraction)
                }
                .frame(height: active ? 12 : 7)
                .frame(maxHeight: .infinity)
                .contentShape(.rect)
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .updating($touching) { _, touching, _ in touching = true }
                        .onChanged { value in changed(value, width: geometry.size.width, barY: geometry.size.height / 2) }
                        .onEnded { _ in finish() }
                )
            }
            .frame(height: 24)
            // 탐색 속도 (손가락을 바에서 멀리 뗐을 때만)
            .overlay(alignment: .top) {
                if drag != nil, speed != .normal {
                    Text(speed.label)
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(.black.opacity(0.5), in: .capsule)
                        .offset(y: -30)
                        .transition(.opacity)
                }
            }

            HStack {
                Text((labelOffset + time).durationText)
                Spacer()
                Text("-" + max(duration - time, 0).durationText)
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.white.opacity(0.8))
        }
        .animation(.easeOut(duration: 0.15), value: active)
        .animation(.easeOut(duration: 0.15), value: speed)
        .onChange(of: touching) { _, touching in
            if !touching { finish() }
        }
        // 드래그 중에 컨트롤이 사라져도 탐색을 끝낸다
        .onDisappear { finish() }
    }

    private func finish() {
        guard let current = drag else { return }
        drag = nil
        speed = .normal
        if current.moved { onEnded() }
    }

    private func changed(_ value: DragGesture.Value, width: CGFloat, barY: CGFloat) {
        guard let current = drag else {
            // 처음 누른 곳은 기준점일 뿐, 그 자리로 뛰지 않는다
            drag = (value.location.x, time, false)
            return
        }
        speed = ScrubSpeed(distance: abs(value.location.y - barY))
        let dx = value.location.x - current.x
        let target = min(max(current.time + Double(dx / max(width, 1)) * duration * speed.factor, 0), duration)
        drag = (value.location.x, target, current.moved || dx != 0)
        if dx != 0 { onChanged(target) }
    }
}

/// 진행률 바를 끄는 속도. 손가락이 바에서 위아래로 멀어질수록 느려진다 (iOS 기본 플레이어와 같은 방식).
private enum ScrubSpeed: Equatable {
    case normal, half, quarter, fine

    init(distance: CGFloat) {
        switch distance {
        case ..<60: self = .normal
        case ..<120: self = .half
        case ..<180: self = .quarter
        default: self = .fine
        }
    }

    var factor: Double {
        switch self {
        case .normal: 1
        case .half: 0.5
        case .quarter: 0.25
        case .fine: 0.1
        }
    }

    var label: String {
        switch self {
        case .normal: "고속 탐색"
        case .half: "1/2 속도 탐색"
        case .quarter: "1/4 속도 탐색"
        case .fine: "미세 탐색"
        }
    }
}

/// 영상이 나오기 전 "불러오는 중", 보는 도중 멈추면 작은 도는 표시, 재생하지 못하면 안내와 다시 시도
private struct PlayerStatusOverlay: View {
    let model: PlayerModel
    let onClose: () -> Void

    var body: some View {
        Group {
            if let error = model.playbackError {
                VStack(spacing: 14) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 34))
                        .foregroundStyle(.yellow)
                    Text("재생할 수 없습니다")
                        .font(.headline)
                    Text(error)
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.75))
                        .multilineTextAlignment(.center)
                    HStack(spacing: 12) {
                        Button("닫기", action: onClose)
                            .buttonStyle(.glass)
                        Button("다시 시도") { model.retry() }
                            .buttonStyle(.glassProminent)
                    }
                    .padding(.top, 4)
                }
                .foregroundStyle(.white)
                .padding(24)
                .frame(maxWidth: 320)
            } else if !model.hasFirstFrame {
                // 도는 표시가 한가운데 (재생 중 버퍼링 표시와 같은 자리), 제목·안내는 그 아래
                ProgressView()
                    .controlSize(.large)
                    .tint(.white)
                    .overlay(alignment: .top) {
                        VStack(spacing: 6) {
                            Text(model.file.title)
                                .font(.subheadline.weight(.semibold))
                                .lineLimit(2)
                                .multilineTextAlignment(.center)
                            Text(model.isSlowToLoad ? "아직 불러오는 중입니다 (서버 응답이 느려요)" : "불러오는 중")
                                .font(.caption)
                                .foregroundStyle(.white.opacity(0.7))
                        }
                        .frame(width: 300)
                        .fixedSize(horizontal: false, vertical: true)
                        .offset(y: 52)
                    }
                    .foregroundStyle(.white)
                    .allowsHitTesting(false)
            } else if model.isBuffering {
                ProgressView()
                    .controlSize(.large)
                    .tint(.white)
                    .padding(14)
                    .background(.black.opacity(0.35), in: .circle)
                    .allowsHitTesting(false)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: model.hasFirstFrame)
    }
}
