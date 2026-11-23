import Foundation
import Observation

/// 폰 ↔ 맥 원격 웹 탐색 (2026-11-09, 사용자): 폰에서 둘러보다 [맥에 보내기] → 맥이 그 페이지를 열어 영상을 찾고 → 폰에서 골라 맥이 받는다.
/// iCloud 로 세 가지를 주고받는다. 주소·제목은 내 iCloud 안에만 오간다.
/// - 맥 목록 (macPresence): 맥이 5분마다(탭이 바뀌면 바로) "켜져 있음"과 열린 탭 목록을 올린다
/// - 명령·찾은 영상: 바뀜 (2026-11-10) — 동기화 엔진으로는 3~4분 걸려 RemoteMailbox(레코드를 이름으로 바로 읽고 쓰기)로 옮김.
///   명령은 10분 넘으면 하지 않는다
@MainActor
final class MacRemote {
    static let shared = MacRemote()

    let presence = SyncedRecords<MacPresence>(kind: "macPresence")

    /// 이 시간 안에 "켜져 있음" 을 올린 맥만 고를 수 있다
    static let aliveWithin: TimeInterval = 12 * 60
    /// 이보다 오래된 명령은 맥이 하지 않는다 (꺼져 있다 켜진 맥이 한참 전 명령을 하지 않게)
    static let commandLifetime: TimeInterval = 10 * 60

    var syncKinds: [SyncEngine.Kind] { [presence.syncKind] }

    /// 고를 수 있는 맥 (이름 순)
    var aliveMacs: [MacPresence] {
        presence.values.values.filter { Date.now.timeIntervalSince($0.seenAt) < Self.aliveWithin }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private init() {}
}

struct MacPresence: Codable, Equatable {
    struct Tab: Codable, Equatable, Identifiable {
        var id: String
        var title: String
        var url: String?
        /// 재생하며 받기 중 (페이지를 바꾸면 깨지므로 고를 수 없다)
        var busy: Bool
    }

    var macID: String
    var name: String
    var seenAt: Date
    var tabs: [Tab]
}

struct MacCommand: Codable, Equatable {
    enum Action: String, Codable {
        /// 주소 열기 (tabID 가 없으면 새 탭)
        case open
        /// 그 탭에서 찾은 영상 받기
        case download
        /// 그 탭에서 재생하며 받기를 켜고 소리 없이 재생해 본다 (2026-11-10)
        case capture
        /// 폰에서 누른 곳을 맥의 그 탭에서 똑같이 누른다 (재생 단추 등, 2026-11-10)
        case click
        /// 그 탭 닫기 (재생하며 받는 중이면 하지 않는다, 2026-11-10 사용자)
        case close
    }

    /// 폰에서 누른 곳: 그 프레임 주소, 요소를 찾는 CSS 선택자, 못 찾으면 쓸 화면 속 위치(0~1)
    struct Click: Codable, Equatable {
        var frameURL: String?
        var selector: String?
        var x: Double
        var y: Double
        /// 누른 것의 글 (기록용)
        var label: String?
    }

    var id: String
    var macID: String
    var action: Action
    var url: String?
    var tabID: String?
    var mediaID: String?
    var click: Click?
    var sentAt: Date
    /// 보낸 기기 이름 (맥의 기록용)
    var from: String
}

struct MacFound: Codable, Equatable {
    struct Media: Codable, Equatable, Identifiable {
        var id: String
        /// "FILE" · "HLS" · "DASH"
        var kind: String
        var name: String
        var quality: String?
        var size: Int64?
        /// 받기 단추로 받을 수 있다 (파일·표준 HLS)
        var downloadable: Bool
        /// 재생하며 받기로만 받을 수 있다 (비표준 HLS·DASH)
        var capturesOnly: Bool
        /// 받을 수 없는 이유 ("DRM", "라이브")
        var unsupported: String?
        /// 이 맥에서 이미 받는 중이거나 받은 것
        var started: Bool
        /// 맥이 아직 표준인지 살펴보는 중 (2026-11-10)
        var checking: Bool?
    }

    var macID: String
    var tabID: String
    var commandID: String
    var url: String?
    var title: String
    /// 페이지를 여는 중
    var loading: Bool
    var media: [Media]
    /// 이 탭의 재생하며 받기: "waiting"(재생 기다림)·"capturing"(받는 중)·"saving"·"saved"·"failed", 꺼져 있으면 nil (2026-11-10)
    var capture: String?
    /// 재생하며 받기: 받은 곳 / 전체 (0~1)
    var captureFraction: Double?
}
