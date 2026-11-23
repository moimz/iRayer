import Foundation
import Observation

/// 즐겨찾기 인물 (User.sqlite). 키는 정보출처:번호 (예: tmdb:21684) 라 에이전트가 달라도 같은 사람이다.
@Observable
final class FavoritePeople {
    static let shared = FavoritePeople()

    struct Person: Identifiable, Hashable {
        let key: String
        var name: String
        var photo: String?
        var id: String { key }
    }

    private(set) var people: [Person] = []

    private init() {
        reload()
    }

    func contains(_ key: String) -> Bool {
        people.contains { $0.key == key }
    }

    /// 보일 즐겨찾기: 성인 등급 숨기기 중에는 보이는 작품이 하나도 없는 사람을 뺀다 (즐겨찾기에서 지우지는 않는다)
    var visiblePeople: [Person] {
        guard AdultFilter.shared.isOn else { return people }
        return people.filter { !LibraryData.works(of: $0.key).isEmpty }
    }

    func toggle(key: String, name: String, photo: String?) {
        if contains(key) {
            try? AppDatabase.user.execute("DELETE FROM favorite_people WHERE key = ?", [.text(key)])
        } else {
            try? AppDatabase.user.execute(
                "INSERT OR REPLACE INTO favorite_people (key, name, photo, created_at) VALUES (?, ?, ?, ?)",
                [.text(key), .text(name), .of(photo), .of(Date.now)]
            )
        }
        reload()
        SyncEngine.shared.changed(Self.syncKind, key: key)
    }

    private func reload() {
        let rows = (try? AppDatabase.user.query("SELECT * FROM favorite_people ORDER BY name")) ?? []
        people = rows.compactMap { row in
            guard let key = row.string("key"), let name = row.string("name") else { return nil }
            return Person(key: key, name: name, photo: row.string("photo"))
        }
        .sorted { KoreanIndex.precedes($0.name, $1.name) }
    }
}

/// 재생목록 (User.sqlite). 항목은 영상 키 "#해시|크기" 라 파일을 옮겨도 그대로다.
@Observable
final class Playlists {
    static let shared = Playlists()

    struct Item: Hashable {
        let key: String
        let title: String
    }

    struct List: Identifiable, Hashable {
        let id: String
        var name: String
        var items: [Item]
    }

    private(set) var lists: [List] = []

    private init() {
        reload()
    }

    func list(_ id: String) -> List? {
        lists.first { $0.id == id }
    }

    @discardableResult
    func create(_ name: String) -> String {
        let id = UUID().uuidString
        try? AppDatabase.user.execute(
            "INSERT INTO playlists (id, name, sort, created_at, updated_at) VALUES (?, ?, (SELECT COUNT(*) FROM playlists), ?, ?)",
            [.text(id), .text(name), .of(Date.now), .of(Date.now)]
        )
        reload()
        SyncEngine.shared.changed(Self.syncKind, key: id)
        return id
    }

    func rename(_ id: String, to name: String) {
        try? AppDatabase.user.execute("UPDATE playlists SET name = ?, updated_at = ? WHERE id = ?", [.text(name), .of(Date.now), .text(id)])
        reload()
        SyncEngine.shared.changed(Self.syncKind, key: id)
    }

    func remove(_ id: String) {
        try? AppDatabase.user.execute("DELETE FROM playlists WHERE id = ?", [.text(id)])
        reload()
        SyncEngine.shared.changed(Self.syncKind, key: id)
    }

    func add(_ items: [Item], to id: String) {
        guard var list = list(id) else { return }
        list.items += items.filter { item in !list.items.contains { $0.key == item.key } }
        save(list)
    }

    func setItems(_ items: [Item], of id: String) {
        guard var list = list(id) else { return }
        list.items = items
        save(list)
    }

    fileprivate func save(_ list: List) {
        let database = AppDatabase.user
        try? database.transaction {
            try database.execute("DELETE FROM playlist_items WHERE playlist_id = ?", [.text(list.id)])
            for (index, item) in list.items.enumerated() {
                try database.execute("INSERT INTO playlist_items (playlist_id, sort, key, title) VALUES (?, ?, ?, ?)",
                                     [.text(list.id), .int(Int64(index)), .text(item.key), .text(item.title)])
            }
            try database.execute("UPDATE playlists SET updated_at = ? WHERE id = ?", [.of(Date.now), .text(list.id)])
        }
        reload()
        SyncEngine.shared.changed(Self.syncKind, key: list.id)
    }

    private func reload() {
        let database = AppDatabase.user
        let rows = (try? database.query("SELECT * FROM playlists ORDER BY sort, created_at")) ?? []
        let itemRows = (try? database.query("SELECT * FROM playlist_items ORDER BY playlist_id, sort")) ?? []
        lists = rows.compactMap { row in
            guard let id = row.string("id"), let name = row.string("name") else { return nil }
            let items = itemRows.filter { $0.string("playlist_id") == id }.compactMap { item -> Item? in
                guard let key = item.string("key") else { return nil }
                return Item(key: key, title: item.string("title") ?? "")
            }
            return List(id: id, name: name, items: items)
        }
    }
}

extension LibraryData {
    /// 영상 키("#해시|크기")의 라이브러리 파일 (재생목록을 재생할 때)
    static func file(forKey key: String) -> (library: LibraryRecord, file: FileEntry)? {
        guard key.hasPrefix("#"), let bar = key.firstIndex(of: "|"), let size = Int64(key[key.index(after: bar)...]) else { return nil }
        let hash = String(key[key.index(after: key.startIndex)..<bar])
        let entries = files(withHash: hash, size: size)
        for entry in entries {
            if let library = LibraryStore.shared.library(entry.libraryID) { return (library, entry) }
        }
        return nil
    }
}

extension LibraryData {
    /// 재생목록 카드의 칸 (앞에서부터 넷): 작품 포스터, 포스터가 없으면 그 영상의 썸네일.
    /// 같은 작품의 회차는 포스터가 같아 한 칸만. 숨긴 작품은 뺀다.
    static func playlistTiles(_ items: [Playlists.Item]) -> [MosaicCard.Tile] {
        var tiles: [MosaicCard.Tile] = []
        var seen: Set<String> = []
        // 한 작품의 회차가 길게 이어져도 너무 많이 읽지 않게
        for item in items.prefix(40) where !isHidden(fileKey: item.key) {
            guard let found = file(forKey: item.key) else { continue }
            if let key = found.file.itemKey, let poster = self.item(key)?.poster {
                if seen.insert(poster).inserted { tiles.append(.poster(poster)) }
            } else if seen.insert(item.key).inserted {
                tiles.append(.video(videoFile(found.file, in: found.library, title: item.title)))
            }
            if tiles.count == 4 { break }
        }
        return tiles
    }
}

// MARK: - 동기화

extension FavoritePeople {
    static let syncKind = "favoritePerson"

    private struct Payload: Codable { let key: String; let name: String; let photo: String? }

    var syncKinds: [SyncEngine.Kind] {
        [SyncEngine.Kind(name: Self.syncKind) { [unowned self] in
            people.map(\.key)
        } payload: { [unowned self] key in
            people.first { $0.key == key }.flatMap { try? syncEncoder.encode(Payload(key: $0.key, name: $0.name, photo: $0.photo)) }
        } apply: { [unowned self] _, data in
            guard let payload = try? JSONDecoder().decode(Payload.self, from: data) else { return false }
            if !contains(payload.key) { toggle(key: payload.key, name: payload.name, photo: payload.photo) }
            return true
        } delete: { [unowned self] key in
            if contains(key) { toggle(key: key, name: "", photo: nil) }
        }]
    }
}

extension Playlists {
    static let syncKind = "playlist"

    private struct Payload: Codable {
        struct Entry: Codable { let key: String; let title: String }
        let id: String
        let name: String
        let items: [Entry]
    }

    var syncKinds: [SyncEngine.Kind] {
        [SyncEngine.Kind(name: Self.syncKind) { [unowned self] in
            lists.map(\.id)
        } payload: { [unowned self] key in
            list(key).flatMap { list in
                try? syncEncoder.encode(Payload(id: list.id, name: list.name, items: list.items.map { Payload.Entry(key: $0.key, title: $0.title) }))
            }
        } apply: { [unowned self] _, data in
            guard let payload = try? JSONDecoder().decode(Payload.self, from: data) else { return false }
            try? AppDatabase.user.execute(
                """
                INSERT INTO playlists (id, name, sort, created_at, updated_at) VALUES (?, ?, (SELECT COUNT(*) FROM playlists), ?, ?)
                ON CONFLICT(id) DO UPDATE SET name = excluded.name, updated_at = excluded.updated_at
                """,
                [.text(payload.id), .text(payload.name), .of(Date.now), .of(Date.now)]
            )
            save(List(id: payload.id, name: payload.name, items: payload.items.map { Item(key: $0.key, title: $0.title) }))
            return true
        } delete: { [unowned self] key in
            remove(key)
        }]
    }
}
