import AppKit
import Observation
import SwiftUI

/// 앱 전체의 재생 창들 (맥). 어디서 재생하든 여기로 요청하고, 영상은 따로 뜬 재생 창에서 나온다.
/// 영상마다 새 창을 열어 여러 개를 함께 볼 수 있다 (같은 영상은 열려 있는 창을 앞으로).
@MainActor
@Observable
final class PlayerHost {
    static let shared = PlayerHost()

    struct Request: Identifiable {
        let id = UUID()
        /// 지금 재생 중인 영상 (대기열에서 다음으로 넘어가면 바뀐다)
        var file: VideoFile
        let resume: Bool
        /// 다 보면 이어서 재생할 영상들 (시리즈 회차·재생목록). 없으면 끝나면 멈춘다
        var queue: PlayQueue?
    }

    /// 지금 열려 있는 재생들 (연 순서)
    private(set) var requests: [Request] = []
    /// 마지막에 연 재생 (없으면 nil)
    var request: Request? { requests.last }

    @ObservationIgnored private var windows: [UUID: PlayerWindowController] = [:]

    private init() {}

    /// 이 영상이 재생 창에 열려 있는지
    func isOpen(_ file: VideoFile) -> Bool {
        requests.contains { $0.file.stateKey == file.stateKey }
    }

    /// 영상을 새 재생 창에서 연다. 같은 영상이 이미 열려 있으면 그 창을 앞으로 가져온다.
    /// queue 를 주지 않아도 라이브러리의 시리즈 회차면 다음 회차로 이어진다.
    func play(_ file: VideoFile, resume: Bool, queue: PlayQueue? = nil) {
        if let open = requests.first(where: { $0.file.stateKey == file.stateKey }), let window = windows[open.id] {
            window.bringToFront()
            return
        }
        let request = Request(file: file, resume: resume, queue: queue ?? PlayQueue.series(for: file))
        // 새 창은 앞에 있던 재생 창에서 조금 비켜 연다
        let previous = requests.last.flatMap { windows[$0.id] }
        let window = PlayerWindowController(id: request.id, cascadeFrom: previous)
        requests.append(request)
        windows[request.id] = window
        window.show(request)
    }

    /// 이 창의 대기열
    func queue(of id: UUID) -> PlayQueue? {
        requests.first { $0.id == id }?.queue
    }

    /// 재생 창 안에서 다른 영상으로 넘어갔을 때 (다음·이전). 창은 그대로 두고 지금 영상·대기열만 바꾼다
    func moved(_ id: UUID, to file: VideoFile) {
        guard let index = requests.firstIndex(where: { $0.id == id }) else { return }
        let old = requests[index].file
        ResumeFrames.shared.begin(old.stateKey)
        requests[index].queue = requests[index].queue?.moved(to: file) ?? PlayQueue.series(for: file)
        requests[index].file = file
    }

    /// 재생 창이 닫혔을 때 (창이 부른다)
    func didClose(_ id: UUID) {
        guard let index = requests.firstIndex(where: { $0.id == id }) else { return }
        let file = requests[index].file
        ResumeFrames.shared.begin(file.stateKey)
        ReturnHighlight.shared.returned(from: file)
        requests.remove(at: index)
        windows[id] = nil
        // 닫힌 창이 잠자기 방지·제어 센터를 내려놓으므로 남은 창이 있으면 다시 잡는다
        if !requests.isEmpty {
            AppSettings.shared.applyIdleTimer(playing: true)
            MacPlayback.current?.becameFront()
        }
    }
}
