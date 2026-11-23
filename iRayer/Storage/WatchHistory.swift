import Foundation
import Observation

/// 본 영상 기록 (홈의 이어보기). 재생 위치 자체는 PlaybackStateStore 에 있고, 여기는 다시 열 수 있도록 영상 정보를 기억한다.
struct WatchEntry: Codable, Identifiable, Hashable {
    let file: VideoFile
    var updatedAt: Date
    /// 끝까지 봤다 (에피소드면 이어보기 자리에 다음 에피소드를 보여준다)
    var finished: Bool

    var id: String { file.stateKey }
}

@Observable
final class WatchHistory {
    static let shared = WatchHistory()

    /// 최근에 본 순서
    fileprivate(set) var entries: [WatchEntry] = []

    fileprivate let limit = 50

    /// 2.0: User.sqlite 의 history (본 영상 하나가 줄 하나). 1.0 의 WatchHistory.json 은 읽지 않는다.
    private init() {
        let rows = (try? AppDatabase.user.query("SELECT data FROM history ORDER BY updated_at DESC LIMIT ?", [.int(Int64(limit))])) ?? []
        entries = rows.compactMap { row in
            row.string("data").flatMap { try? JSONDecoder().decode(WatchEntry.self, from: Data($0.utf8)) }
        }
        moveWatchedMarks()
    }

    /// 한 번만 (2026-11-11): 이 목록에만 있던 다 본 표시를 재생 상태(영구)로 옮긴다
    private func moveWatchedMarks() {
        let flag = "watchedMarksMoved"
        guard !UserDefaults.standard.bool(forKey: flag) else { return }
        UserDefaults.standard.set(true, forKey: flag)
        let store = PlaybackStateStore.shared
        for entry in entries where entry.finished && !store.isWatched(entry.id) {
            store.update(entry.id) { $0.watchedAt = entry.updatedAt }
        }
    }

    func record(_ file: VideoFile, finished: Bool) {
        entries.removeAll { $0.id == file.stateKey }
        entries.insert(WatchEntry(file: file, updatedAt: .now, finished: finished), at: 0)
        if entries.count > limit { entries.removeLast(entries.count - limit) }
        save()
        SyncEngine.shared.changed(Self.syncKind, key: file.stateKey)
    }

    /// 이어보기에서 빼기
    func remove(_ id: String) {
        entries.removeAll { $0.id == id }
        save()
        SyncEngine.shared.changed(Self.syncKind, key: id)
    }

    /// 지운 파일들을 뺀다 (파일 삭제 뒤. 다른 기기에도 빠진다)
    func forget(where isGone: (VideoFile) -> Bool) {
        let gone = entries.filter { isGone($0.file) }
        guard !gone.isEmpty else { return }
        entries.removeAll { isGone($0.file) }
        save()
        for entry in gone { SyncEngine.shared.changed(Self.syncKind, key: entry.id) }
    }

    /// 지금 목록을 저장한다 (목록에 없는 줄은 지운다)
    fileprivate func save() {
        let database = AppDatabase.user
        try? database.transaction {
            try database.execute("DELETE FROM history")
            for entry in entries {
                guard let data = try? JSONEncoder().encode(entry) else { continue }
                try database.execute("INSERT INTO history (key, data, updated_at) VALUES (?, ?, ?)",
                                     [.text(entry.id), .text(String(decoding: data, as: UTF8.self)), .of(entry.updatedAt)])
            }
        }
    }
}

// MARK: - 동기화

extension WatchHistory {
    static let syncKind = "watch"

    /// 이 기기 폴더의 파일은 다른 기기에서 열 수 없으니 보내지 않는다
    var syncKinds: [SyncEngine.Kind] {
        [SyncEngine.Kind(name: Self.syncKind) { [unowned self] in
            entries.map(\.id)
        } payload: { [unowned self] key in
            guard let entry = entries.first(where: { $0.id == key }), !entry.file.url.isFileURL else { return nil }
            return try? syncEncoder.encode(entry)
        } date: { [unowned self] key in
            entries.first { $0.id == key }?.updatedAt
        } apply: { [unowned self] key, data in
            guard let entry = try? JSONDecoder().decode(WatchEntry.self, from: data) else { return false }
            entries.removeAll { $0.id == key }
            entries.append(entry)
            entries.sort { $0.updatedAt > $1.updatedAt }
            if entries.count > limit { entries.removeLast(entries.count - limit) }
            save()
            return true
        } delete: { [unowned self] key in
            entries.removeAll { $0.id == key }
            save()
        }]
    }
}
