import Foundation
import Observation

/// 영상별로 기억하는 재생 상태 (나중에 앱끼리 동기화할 데이터셋)
struct VideoPlaybackState: Codable, Equatable {
    /// 이어보기 위치 (초)
    var position: Double = 0
    /// 영상 길이 (초)
    var duration: Double = 0
    /// 자막 싱크 (밀리초, 양수면 자막이 늦게 표시)
    var subtitleDelay: Int = 0
    /// 오디오 싱크 (밀리초, 양수면 소리가 늦게 재생)
    var audioDelay: Int = 0
    /// 직접 불러온 외부 자막 파일 (보안 범위 북마크)
    var subtitleBookmark: Data?
    /// 직접 고른 내장 자막 트랙 ID
    var subtitleTrackID: Int32?
    /// 직접 고른 오디오 트랙 ID (없으면 VLC 기본)
    var audioTrackID: Int32?
    /// 처음 재생할 때 알아낸 해상도·코덱 (작품 화면 파일 줄에 보인다)
    var media: MediaInfo?
    /// 다 본 것으로 표시한 때 (2026-11-11, 사용자: 다 본 표시는 영구히). 전에는 최근 본 목록(50개)에만 있어 오래되면 빠졌다
    var watchedAt: Date?
    var updatedAt: Date = .now
}

/// 영상의 해상도·코덱 (1.0 에서는 Plex 가 알려 주던 것. 이제는 처음 재생할 때 VLC 가 알아낸 것을 저장한다)
struct MediaInfo: Codable, Equatable {
    var width: Int
    var height: Int
    /// FourCC 소문자 (h264, hevc …)
    var videoCodec: String?
    /// 재생한 오디오 트랙 (mp4a, a52 …)과 채널 수
    var audioCodec: String?
    var audioChannels: Int?
    /// MP4 목차로 잰 소리·영상의 최대 어긋남 (초, 2026-11-10). 크면 Non-Interleaved — 오디오 코덱 뒤에 * (사용자)
    var interleaveSkew: Double?

    var isNonInterleaved: Bool { (interleaveSkew ?? 0) > MP4Interleave.threshold }

    /// 코덱: "HEVC · AAC 5.1"
    var codecs: [String] {
        var parts: [String] = []
        if let videoCodec { parts.append(Self.name(videoCodec)) }
        if let audioCodec {
            let channels: String? = switch audioChannels {
            case 6: "5.1"
            case 8: "7.1"
            case 1: "모노"
            default: nil
            }
            // 바뀜 (2026-11-10, 사용자): Non-Interleaved 면 오디오 뒤에 * ("AC3 5.1*")
            parts.append([Self.name(audioCodec), channels].compactMap { $0 }.joined(separator: " ") + (isNonInterleaved ? "*" : ""))
        }
        return parts
    }

    /// 해상도: 4K · 1080p · 720p · 480p …
    var resolution: String? {
        guard width > 0, height > 0 else { return nil }
        if width >= 3800 || height >= 2100 { return "4K" }
        if width >= 1900 || height >= 1060 { return "1080p" }
        if width >= 1260 || height >= 700 { return "720p" }
        return "\(height)p"
    }

    /// FourCC → 알아보기 쉬운 이름
    private static func name(_ codec: String) -> String {
        [
            "h264": "H.264", "avc1": "H.264", "hevc": "HEVC", "hvc1": "HEVC", "hev1": "HEVC", "h265": "HEVC", "av01": "AV1",
            "vp90": "VP9", "vp80": "VP8", "mp4v": "MPEG-4", "xvid": "Xvid", "divx": "DivX", "dx50": "DivX", "mpgv": "MPEG-2",
            "wmv1": "WMV", "wmv2": "WMV", "wmv3": "WMV", "vc-1": "VC-1", "wvc1": "VC-1",
            "mp4a": "AAC", "a52": "AC3", "eac3": "E-AC3", "dts": "DTS", "mpga": "MP3", "mp3": "MP3", "opus": "Opus", "vorb": "Vorbis",
            "flac": "FLAC", "alac": "ALAC", "wma1": "WMA", "wma2": "WMA", "truehd": "TrueHD", "mlp": "TrueHD", "araw": "PCM", "s16l": "PCM",
        ][codec] ?? codec.uppercased()
    }
}

/// 영상별 재생 상태 저장소
/// 화면은 읽은 파일의 상태만 지켜본다: 한 파일의 위치가 바뀌면 그 파일을 보여주는 카드·화면만 다시 그린다.
final class PlaybackStateStore {
    static let shared = PlaybackStateStore()

    /// 한 파일의 상태 (화면이 지켜보는 단위)
    @Observable
    fileprivate final class Entry {
        var value: VideoPlaybackState
        init(_ value: VideoPlaybackState) { self.value = value }
    }

    fileprivate var states: [String: VideoPlaybackState] = [:]
    private var entries: [String: Entry] = [:]

    /// 2.0: User.sqlite 의 playback (영상 하나가 줄 하나). 1.0 의 PlaybackStates.json 은 읽지 않는다.
    private init() {
        let rows = (try? AppDatabase.user.query("SELECT key, data FROM playback")) ?? []
        for row in rows {
            guard let key = row.string("key"), let data = row.string("data"),
                  let state = try? JSONDecoder().decode(VideoPlaybackState.self, from: Data(data.utf8)) else { continue }
            states[key] = state
        }
    }

    func state(for key: String) -> VideoPlaybackState {
        entry(key).value
    }

    /// 다 본 것으로 표시된 영상인지 (다시 봐도 재생 기록을 남기지 않는다)
    func isWatched(_ key: String) -> Bool {
        entry(key).value.watchedAt != nil
    }

    func update(_ key: String, _ change: (inout VideoPlaybackState) -> Void) {
        var state = states[key] ?? VideoPlaybackState()
        change(&state)
        state.updatedAt = .now
        states[key] = state
        entry(key).value = state
        save(key)
        SyncEngine.shared.changed(Self.syncKind, key: key)
    }

    fileprivate func entry(_ key: String) -> Entry {
        if let entry = entries[key] { return entry }
        let entry = Entry(states[key] ?? VideoPlaybackState())
        entries[key] = entry
        return entry
    }

    /// 한 영상의 상태만 저장 (없으면 지운다)
    fileprivate func save(_ key: String) {
        if let state = states[key], let data = try? JSONEncoder().encode(state) {
            try? AppDatabase.user.execute(
                "INSERT INTO playback (key, data, updated_at) VALUES (?, ?, ?) ON CONFLICT(key) DO UPDATE SET data = excluded.data, updated_at = excluded.updated_at",
                [.text(key), .text(String(decoding: data, as: UTF8.self)), .of(state.updatedAt)]
            )
        } else {
            try? AppDatabase.user.execute("DELETE FROM playback WHERE key = ?", [.text(key)])
        }
    }
}

// MARK: - 동기화

extension PlaybackStateStore {
    static let syncKind = "playback"

    /// 외부 자막 북마크는 이 기기에서만 쓸 수 있어서 빼고 보낸다
    var syncKinds: [SyncEngine.Kind] {
        [
        SyncEngine.Kind(name: Self.syncKind) { [unowned self] in
            Array(states.keys)
        } payload: { [unowned self] key in
            guard var state = states[key] else { return nil }
            state.subtitleBookmark = nil
            return try? syncEncoder.encode(state)
        } date: { [unowned self] key in
            states[key]?.updatedAt
        } apply: { [unowned self] key, data in
            guard var state = try? JSONDecoder().decode(VideoPlaybackState.self, from: data) else { return false }
            state.subtitleBookmark = states[key]?.subtitleBookmark
            states[key] = state
            entry(key).value = state
            save(key)
            return true
        } delete: { [unowned self] key in
            states[key] = nil
            entry(key).value = VideoPlaybackState()
            save(key)
        }]
    }
}
