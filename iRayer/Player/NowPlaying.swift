import MediaPlayer
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

/// 잠금 화면·제어 센터·에어팟의 재생 조작과 "지금 재생 중" 정보 (제목, 길이, 위치, 그림).
/// 화면을 끄거나 다른 앱으로 가도 소리는 계속 나고(Info.plist 의 audio 백그라운드 모드), 여기서 멈추고 넘긴다.
final class NowPlaying {
    static let shared = NowPlaying()

    private weak var model: PlayerModel?
    #if os(iOS)
    /// AirPlay 로 TV 에서 재생하는 동안은 잠금 화면 정보와 버튼이 TV 재생을 따른다 (폰 플레이어는 멈춰 있다)
    weak var airPlay: AirPlaySession? {
        didSet { update(force: true) }
    }
    #endif
    private var commandsReady = false
    private var artwork: MPMediaItemArtwork?
    private var lastUpdate: (playing: Bool, at: Date) = (false, .distantPast)

    private init() {}

    func attach(_ model: PlayerModel) {
        self.model = model
        artwork = nil
        setUpCommands()
        setCommandsEnabled(true)
        update(force: true)
        // 그림은 목록 썸네일로 (없으면 만든 뒤에)
        let file = model.file
        Task { [weak self] in
            guard let image = await ThumbnailService.shared.thumbnail(for: file), let self, self.model === model else { return }
            self.artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
            self.update(force: true)
        }
    }

    func detach(_ model: PlayerModel) {
        guard self.model === model else { return }
        self.model = nil
        setCommandsEnabled(false)
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    /// 재생 중 주기적으로 부른다: 멈춤·재생이 바뀌었거나 조금 지났을 때만 새로 알린다 (잠금 화면은 위치를 스스로 늘려 간다)
    func update(force: Bool = false) {
        guard let state else { return }
        guard force || state.playing != lastUpdate.playing || Date().timeIntervalSince(lastUpdate.at) > 5 else { return }
        lastUpdate = (state.playing, Date())
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: state.title,
            MPMediaItemPropertyPlaybackDuration: state.duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: state.time,
            MPNowPlayingInfoPropertyPlaybackRate: state.playing ? state.rate : 0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: 1.0,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.video.rawValue,
        ]
        if let artwork { info[MPMediaItemPropertyArtwork] = artwork }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    /// 지금 보여줄 재생 (AirPlay 중이면 TV 재생)
    private var state: (title: String, duration: Double, time: Double, playing: Bool, rate: Double)? {
        #if os(iOS)
        if let airPlay {
            return (airPlay.title, airPlay.duration, airPlay.position, airPlay.isPlaying, 1)
        }
        #endif
        guard let model else { return nil }
        return (model.file.title, model.duration, model.currentTime, model.isPlaying, Double(model.rate))
    }

    /// 버튼 처리: AirPlay 중이면 TV 재생으로, 아니면 폰 플레이어로
    private func perform(play: Bool? = nil, skip: Double? = nil, seek: Double? = nil) -> MPRemoteCommandHandlerStatus {
        #if os(iOS)
        if let airPlay {
            if let play, play != airPlay.isPlaying { airPlay.togglePlay() }
            if let skip { Task { await airPlay.seek(to: airPlay.position + skip) } }
            if let seek { Task { await airPlay.seek(to: seek) } }
            update(force: true)
            return .success
        }
        #endif
        guard let model else { return .noActionableNowPlayingItem }
        if let play, play != model.isPlaying { model.togglePlay() }
        if let skip { model.skip(by: skip) }
        if let seek {
            model.seek(to: seek)
            model.currentTime = seek
        }
        update(force: true)
        return .success
    }

    private func setUpCommands() {
        guard !commandsReady else { return }
        commandsReady = true
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.addTarget { [weak self] _ in
            self?.perform(play: true) ?? .noActionableNowPlayingItem
        }
        center.pauseCommand.addTarget { [weak self] _ in
            self?.perform(play: false) ?? .noActionableNowPlayingItem
        }
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            guard let self, let state = self.state else { return .noActionableNowPlayingItem }
            return self.perform(play: !state.playing)
        }
        center.skipForwardCommand.addTarget { [weak self] _ in
            self?.perform(skip: Double(AppSettings.shared.skipSeconds)) ?? .noActionableNowPlayingItem
        }
        center.skipBackwardCommand.addTarget { [weak self] _ in
            self?.perform(skip: -Double(AppSettings.shared.skipSeconds)) ?? .noActionableNowPlayingItem
        }
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .noActionableNowPlayingItem }
            return self?.perform(seek: event.positionTime) ?? .noActionableNowPlayingItem
        }
    }

    private func setCommandsEnabled(_ enabled: Bool) {
        let center = MPRemoteCommandCenter.shared()
        let interval = NSNumber(value: AppSettings.shared.skipSeconds)
        center.skipForwardCommand.preferredIntervals = [interval]
        center.skipBackwardCommand.preferredIntervals = [interval]
        for command in [center.playCommand, center.pauseCommand, center.togglePlayPauseCommand,
                        center.skipForwardCommand, center.skipBackwardCommand, center.changePlaybackPositionCommand] {
            command.isEnabled = enabled
        }
        // 다음·이전 트랙은 쓰지 않는다 (다음 화 자동 재생을 하지 않으므로)
        center.nextTrackCommand.isEnabled = false
        center.previousTrackCommand.isEnabled = false
    }
}
