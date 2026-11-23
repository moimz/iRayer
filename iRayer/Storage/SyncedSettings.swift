import Foundation
import Observation

/// 모든 기기가 같이 쓰는 설정 (iCloud 로 동기화). 기기마다 따로인 설정은 AppSettings.
@Observable
final class SyncedSettings {
    static let shared = SyncedSettings()
    static let syncKind = "setting"

    /// 다음 회차 버튼을 끝나기 몇 초 전부터 띄울지 (짧은 영상은 길이의 10% 까지만, 사용자 2026-11-07)
    var nextEpisodeLead: Int {
        didSet { save(Keys.nextEpisodeLead, nextEpisodeLead) }
    }

    static let nextEpisodeLeadChoices = [15, 30, 60, 90, 120]

    @ObservationIgnored private let defaults = UserDefaults.standard
    @ObservationIgnored private var applying = false

    private init() {
        defaults.register(defaults: [Keys.nextEpisodeLead: 60])
        nextEpisodeLead = defaults.integer(forKey: Keys.nextEpisodeLead)
    }

    private func save(_ key: String, _ value: Int) {
        defaults.set(value, forKey: key)
        if !applying { SyncEngine.shared.changed(Self.syncKind, key: key) }
    }

    private enum Keys {
        static let nextEpisodeLead = "nextEpisodeLead"
    }

    var syncKinds: [SyncEngine.Kind] {
        [
            SyncEngine.Kind(name: Self.syncKind) {
                [Keys.nextEpisodeLead]
            } payload: { [unowned self] key in
                guard key == Keys.nextEpisodeLead, defaults.object(forKey: key) != nil else { return nil }
                return try? JSONEncoder().encode(nextEpisodeLead)
            } apply: { [unowned self] key, data in
                // 모르는 설정(새 판 앱이 더한 것)도 false — 앱을 올린 뒤 다시 받는다
                guard key == Keys.nextEpisodeLead, let value = try? JSONDecoder().decode(Int.self, from: data) else { return false }
                applying = true
                nextEpisodeLead = value
                applying = false
                return true
            } delete: { _ in },
        ]
    }
}

/// 웹 탐색 즐겨찾기 (iCloud 로 동기화, 지금은 맥 웹 탐색만 쓴다)
@Observable
final class WebBookmarks {
    static let shared = WebBookmarks()
    static let syncKind = "webBookmark"

    struct Bookmark: Codable, Identifiable, Hashable {
        var id: String
        var title: String
        var url: String
        var sort: Double
        var updatedAt: Date
    }

    /// 순서대로
    private(set) var items: [Bookmark] = []

    @ObservationIgnored private let defaults = UserDefaults.standard
    @ObservationIgnored private static let storeKey = "webBookmarks"

    private init() {
        if let data = defaults.data(forKey: Self.storeKey), let decoded = try? JSONDecoder().decode([Bookmark].self, from: data) {
            items = decoded.sorted { $0.sort < $1.sort }
        }
    }

    func bookmark(for url: URL?) -> Bookmark? {
        guard let url else { return nil }
        let key = Self.normalized(url.absoluteString)
        return items.first { Self.normalized($0.url) == key }
    }

    func add(title: String, url: URL) {
        guard bookmark(for: url) == nil else { return }
        let item = Bookmark(id: UUID().uuidString, title: title.isEmpty ? (url.host() ?? url.absoluteString) : title,
                            url: url.absoluteString, sort: (items.last?.sort ?? 0) + 1, updatedAt: .now)
        items.append(item)
        save(changed: [item.id])
    }

    func remove(_ id: String) {
        items.removeAll { $0.id == id }
        save(changed: [id])
    }

    func rename(_ id: String, to title: String) {
        guard let index = items.firstIndex(where: { $0.id == id }), !title.isEmpty else { return }
        items[index].title = title
        items[index].updatedAt = .now
        save(changed: [id])
    }

    func move(from source: IndexSet, to destination: Int) {
        items.move(fromOffsets: source, toOffset: destination)
        for index in items.indices where items[index].sort != Double(index) {
            items[index].sort = Double(index)
            items[index].updatedAt = .now
        }
        save(changed: items.map(\.id))
    }

    private func save(changed ids: [String]) {
        defaults.set(try? JSONEncoder().encode(items), forKey: Self.storeKey)
        for id in ids { SyncEngine.shared.changed(Self.syncKind, key: id) }
    }

    /// 끝의 / 와 # 뒤는 같은 곳으로 본다
    private static func normalized(_ string: String) -> String {
        var value = string.split(separator: "#", maxSplits: 1).first.map(String.init) ?? string
        while value.hasSuffix("/") { value.removeLast() }
        return value
    }

    var syncKinds: [SyncEngine.Kind] {
        [
            SyncEngine.Kind(name: Self.syncKind) { [unowned self] in
                items.map(\.id)
            } payload: { [unowned self] key in
                items.first { $0.id == key }.flatMap { try? JSONEncoder().encode($0) }
            } date: { [unowned self] key in
                items.first { $0.id == key }?.updatedAt
            } apply: { [unowned self] key, data in
                guard let item = try? JSONDecoder().decode(Bookmark.self, from: data) else { return false }
                items.removeAll { $0.id == key }
                items.append(item)
                items.sort { $0.sort < $1.sort }
                defaults.set(try? JSONEncoder().encode(items), forKey: Self.storeKey)
                return true
            } delete: { [unowned self] key in
                items.removeAll { $0.id == key }
                defaults.set(try? JSONEncoder().encode(items), forKey: Self.storeKey)
            },
        ]
    }
}
