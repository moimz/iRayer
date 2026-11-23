import AVKit
import SwiftUI

/// 재생 화면의 AirPlay 버튼.
/// VLC 는 영상을 폰에서 직접 그리므로, AirPlay 로 보내려면 TV 가 받아 갈 주소를 iOS 기본 플레이어(AVPlayer)로 넘겨야 한다.
/// 모든 영상을 한 길로 보낸다: VLC 가 풀고 자막을 입힌 장면을 폰이 다시 압축해 HLS 로 내보낸다 (HLSStream).
/// (그릇·코덱을 보고 원본을 그대로 보내는 샛길은 이 길이 다 된 뒤에 필요하면 판다)
enum AirPlayHandoff {
    static let failedMessage = "AirPlay 로 재생하지 못했습니다. 제어 센터의 화면 미러링을 이용해 주세요."
    /// 실패했는데 소리는 아직 AirPlay 기기로 나간다 (앱이 연결을 끊을 수 없어, 폰에서 이어 재생하면 소리만 TV 로 간다)
    static let failedStillConnectedMessage = "AirPlay 로 재생하지 못했습니다. 다시 시도하거나, 폰에서 보려면 제어 센터에서 AirPlay 연결을 끊어 주세요."
    static let noNetworkMessage = "Wi-Fi 에 연결되어 있어야 AirPlay 로 보낼 수 있습니다."

    /// 지금 소리가 AirPlay 기기로 나가고 있다
    static var isAirPlayRoute: Bool {
        AVAudioSession.sharedInstance().currentRoute.outputs.contains { $0.portType == .airPlay }
    }
}

/// AirPlay 로 넘긴 재생 한 번. 재생목록이 영상 전체라 위치는 TV 재생 위치 그대로이고,
/// 탐색하면 TV 가 그 자리 조각을 달라고 해서 폰이 그 자리부터 만든다 (만든 곳 밖이면 TV 화면이 몇 초 멈춘다).
@MainActor
@Observable
final class AirPlaySession: Identifiable {
    let id = UUID()
    let player: AVPlayer
    /// 영상 전체 길이
    let duration: Double
    let title: String
    @ObservationIgnored private var stream: HLSStream?
    @ObservationIgnored private let file: VideoFile
    @ObservationIgnored private let audioTrack: Int32
    @ObservationIgnored private let subtitle: HLSStream.Subtitle

    /// 기기를 고르기 전에 미리 준비만 한다 (만들기는 연결된 뒤 start 에서)
    init(model: PlayerModel) {
        let player = AVPlayer()
        player.allowsExternalPlayback = true
        player.usesExternalPlaybackWhileExternalScreenIsActive = true
        self.player = player
        file = model.file
        title = model.file.title
        duration = model.duration
        audioTrack = model.selectedAudioID
        subtitle = switch model.selectedSubtitle {
        case .off: .off
        case .embedded(let id): .embedded(id)
        // 앱이 그리는 자막은 지금 설정(싱크 포함) 그대로. VLC 에 붙인 외부 자막(ASS 등)은 아직 못 보낸다.
        case .external: model.cues.isEmpty ? .off : .app(model.cues, delay: model.subtitleDelay)
        }
    }

    /// position 부터 만들어 TV 로 보낸다. Wi-Fi 주소를 모르면 false.
    @discardableResult
    func start(at position: Double) async -> Bool {
        let stream = HLSStream(file: file, duration: duration, audioTrack: audioTrack, subtitle: subtitle)
        guard let url = await LocalStreamServer.shared.url(for: stream) else { return false }
        self.stream = stream
        Task { await stream.start(at: position) }
        let item = AVPlayerItem(url: url)
        player.replaceCurrentItem(with: item)
        await player.seek(to: CMTime(seconds: position, preferredTimescale: 600))
        player.play()
        NowPlaying.shared.airPlay = self
        return true
    }

    var isPlaying: Bool { player.rate != 0 }

    func togglePlay() {
        if isPlaying { player.pause() } else { player.play() }
        NowPlaying.shared.update(force: true)
    }

    func seek(to target: Double) async {
        let target = min(max(target, 0), max(duration - 1, 0))
        await player.seek(to: CMTime(seconds: target, preferredTimescale: 600))
        NowPlaying.shared.update(force: true)
    }

    var position: Double {
        let seconds = player.currentTime().seconds
        return seconds.isFinite ? seconds : 0
    }

    func finish() {
        if NowPlaying.shared.airPlay === self { NowPlaying.shared.airPlay = nil }
        player.pause()
        player.replaceCurrentItem(with: nil)
        guard let stream else { return }
        stream.stop()
        LocalStreamServer.shared.remove(stream)
        self.stream = nil
    }
}

/// AirPlay 재생 화면: TV 로 연결된 뒤 폰에 보이는 조작 화면.
/// 닫기 버튼은 두지 않는다 — 앱이 AirPlay 연결을 직접 끊을 수 없으므로, 사용자가 AirPlay 를 끊으면(iPhone 을 고르거나 제어 센터에서)
/// 그걸 알아채고 닫은 뒤 폰에서 그 위치부터 이어 본다.
struct AirPlayScreen: View {
    let session: AirPlaySession
    let title: String
    /// 접기: 플레이어를 숨기고 앱을 쓴다 (TV 재생은 그대로, 2026-11-11 사용자)
    var onCollapse: () -> Void = {}
    /// 끝난 위치 (폰에서 이어 볼 위치)
    let onEnd: (Double) -> Void
    /// 실패한 위치 (TV 가 재생하던 곳)
    let onFailure: (Double) -> Void
    /// TV 재생 위치 (몇 초마다: 시청 기록·이어보기)
    var onProgress: (Double) -> Void = { _ in }

    @Environment(\.dismiss) private var dismiss
    @State private var finished = false
    @State private var isPlaying = true
    @State private var current: Double = 0
    @State private var scrubbing: Double?
    /// 탐색한 곳: TV 가 그 자리를 재생할 때까지 진행바를 거기 둔다 (멀리 가면 TV 는 몇 초 동안 예전 위치를 알려 준다)
    @State private var seekTarget: (time: Double, since: Date)?
    @State private var routeName: String?

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                VStack(spacing: 28) {
                    Spacer()
                    VStack(spacing: 10) {
                        Image(systemName: "tv")
                            .font(.system(size: 64, weight: .light))
                        if let routeName {
                            Text("‘\(routeName)’에서 재생 중")
                                .font(.headline)
                        } else {
                            ProgressView("연결하는 중…")
                                .tint(.white)
                        }
                    }
                    .foregroundStyle(.white.opacity(0.7))
                    HStack(spacing: 40) {
                        controlButton("gobackward.10") { jump(-10) }
                        controlButton(isPlaying ? "pause.fill" : "play.fill", size: 34) { togglePlay() }
                        controlButton("goforward.10") { jump(10) }
                    }
                    Spacer()
                    Text("AirPlay 연결을 끊으면 폰에서 이어서 재생합니다")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.5))
                    progress
                }
                .padding()
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                // 바뀜 (2026-11-11, 사용자): 오른쪽은 AirPlay 단추, 왼쪽(플레이어의 닫기 자리)에 접기
                ToolbarItem(placement: .topBarLeading) {
                    Button("접기", systemImage: "chevron.down") { onCollapse() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    RoutePickerButton()
                        .frame(width: 32, height: 32)
                }
            }
        }
        .interactiveDismissDisabled()
        .task {
            // 재생 위치·TV 이름을 갱신하고, AirPlay 가 끊기면 끝낸다
            let started = Date.now
            var wasExternal = false
            var savedAt = Date.distantPast
            while !Task.isCancelled, !finished {
                let player = session.player
                let position = session.position
                if let target = seekTarget, abs(position - target.time) > 3, Date.now.timeIntervalSince(target.since) < 20 {
                    // 탐색한 곳을 TV 가 아직 재생하지 않는다
                } else {
                    seekTarget = nil
                    if scrubbing == nil { current = position }
                    if player.isExternalPlaybackActive, Date.now.timeIntervalSince(savedAt) > 5 {
                        savedAt = .now
                        onProgress(position)
                    }
                }
                isPlaying = player.rate != 0
                // 잠금 화면의 지금 재생 중도 TV 재생을 따른다
                NowPlaying.shared.update()
                if player.currentItem?.status == .failed {
                    fail()
                    break
                }
                let external = player.isExternalPlaybackActive
                routeName = external ? AVAudioSession.sharedInstance().currentRoute.outputs.first?.portName ?? "TV" : nil
                if external {
                    wasExternal = true
                } else if wasExternal || !AirPlayHandoff.isAirPlayRoute || Date.now.timeIntervalSince(started) > 20 {
                    // (첫 조각을 만들고 TV 가 받아 가기까지 몇 초 걸린다)
                    // 연결이 끊겼거나, 영상을 받지 않는 기기(스피커)였다
                    end()
                    break
                }
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
    }

    /// 플레이어와 같은 모양의 진행률 바
    private var progress: some View {
        TimeBar(time: scrubbing ?? current, duration: session.duration, isScrubbing: scrubbing != nil) { target in
            scrubbing = target
        } onEnded: {
            guard let target = scrubbing else { return }
            current = target
            seekTarget = (target, .now)
            scrubbing = nil
            Task { await session.seek(to: target) }
        }
        .foregroundStyle(.white)
    }

    private func controlButton(_ symbol: String, size: CGFloat = 26, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size))
                .frame(width: 64, height: 64)
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.circle)
    }

    private func togglePlay() {
        session.togglePlay()
        isPlaying = session.isPlaying
    }

    private func jump(_ seconds: Double) {
        let target = max(0, current + seconds)
        current = target
        seekTarget = (target, .now)
        Task { await session.seek(to: target) }
    }

    private func end() {
        guard !finished else { return }
        finished = true
        // 탐색 중에 끊겼으면 탐색한 곳부터
        let position = seekTarget?.time ?? session.position
        session.finish()
        dismiss()
        onEnd(position)
    }

    private func fail() {
        guard !finished else { return }
        finished = true
        let position = session.position
        session.finish()
        dismiss()
        onFailure(position)
    }
}

/// AirPlay 기기 선택 버튼 (iOS 기본)
private struct RoutePickerButton: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.tintColor = .white
        view.prioritizesVideoDevices = true
        return view
    }

    func updateUIView(_ view: AVRoutePickerView, context: Context) {}
}

/// 숨겨 둔 AirPlay 기기 선택 창. trigger 가 바뀔 때마다 연다. 창이 닫히면 onClose (기기를 골랐든 안 골랐든).
/// AVRoutePickerView 에는 열기 API 가 없어 안의 버튼을 누른다.
struct RoutePickerPresenter: UIViewRepresentable {
    let trigger: Int
    var onClose: () -> Void = {}

    func makeUIView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.prioritizesVideoDevices = true
        view.delegate = context.coordinator
        return view
    }

    func updateUIView(_ view: AVRoutePickerView, context: Context) {
        context.coordinator.onClose = onClose
        guard trigger != context.coordinator.lastTrigger else { return }
        context.coordinator.lastTrigger = trigger
        guard trigger > 0 else { return }
        view.subviews.compactMap { $0 as? UIButton }.first?.sendActions(for: .touchUpInside)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, AVRoutePickerViewDelegate {
        var lastTrigger = 0
        var onClose: () -> Void = {}

        func routePickerViewDidEndPresentingRoutes(_ routePickerView: AVRoutePickerView) {
            onClose()
        }
    }
}

/// AirPlay 를 접어 두었을 때 앱 아래(탭 막대 위)에 뜨는 작은 재생 막대 (2026-11-11, 사용자).
/// 누르면 AirPlay 재생 화면을 다시 펼친다. TV 연결은 앱이 끊을 수 없으므로 끝내기 단추는 두지 않는다 (펼쳐서 AirPlay 단추로)
struct AirPlayMiniBar: View {
    let session: AirPlaySession
    @Environment(\.tabViewBottomAccessoryPlacement) private var placement

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            HStack(spacing: 12) {
                Image(systemName: "tv")
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(session.title).font(.subheadline.weight(.medium)).lineLimit(1)
                    if placement != .inline {
                        ProgressView(value: min(session.position, session.duration), total: max(session.duration, 1))
                            .progressViewStyle(.linear)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Button(session.isPlaying ? "일시정지" : "재생", systemImage: session.isPlaying ? "pause.fill" : "play.fill") {
                    session.togglePlay()
                }
                .labelStyle(.iconOnly)
                .font(.title3)
            }
            .padding(.horizontal, 16)
            .contentShape(.rect)
            .onTapGesture { PlayerHost.shared.expandAirPlay() }
        }
    }
}
