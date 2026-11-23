import Foundation
import Observation

/// 등록한 에이전트 하나
struct AgentRecord: Identifiable, Hashable {
    enum AgentType: String {
        /// 앱 안의 TMDB 에이전트 (API 키만)
        case tmdb
        /// 규약을 따르는 웹 서버 (주소 + API 키)
        case custom
    }

    let id: String
    var type: AgentType
    var name: String
    var url: String
    var version: String?
    var kinds: [AgentModels.Kind]
    var relocations: Bool

    /// 종류 id 의 이름 (없으면 id)
    func kindName(_ id: String) -> String {
        kinds.first { $0.id == id }?.name ?? id
    }

    /// 에이전트에 요청을 보낼 곳 (TMDB 는 앱 안에서, 사용자 정의는 웹 서버로)
    var client: any MetadataAgent {
        switch type {
        case .tmdb: TMDBAgent(baseURL: url, key: Keychain.password(for: AgentStore.keyAccount(id)) ?? "")
        case .custom: customClient
        }
    }

    /// 사용자 정의 에이전트 웹 서버
    var customClient: AgentClient {
        AgentClient(baseURL: url, key: Keychain.password(for: AgentStore.keyAccount(id)))
    }
}

/// 에이전트 관리 (User.sqlite, API 키는 키체인)
@Observable
final class AgentStore {
    static let shared = AgentStore()

    private(set) var agents: [AgentRecord] = []

    /// TMDB 에이전트의 종류 (앱에 고정)
    static let tmdbKinds = [
        AgentModels.Kind(id: "movie", name: "영화", type: "MOVIE"),
        AgentModels.Kind(id: "tv", name: "TV 시리즈", type: "SERIES"),
        // 바뀜 (2026-11-07): reader 와 같은 네 가지 중 TMDB 로 하는 셋 (자동 = 회차가 있으면 TV 시리즈, 없으면 영화)
        AgentModels.Kind(id: "auto", name: "자동 (영화·TV 시리즈)", type: "AUTO"),
    ]

    private init() {
        reload()
    }

    static func keyAccount(_ id: String) -> String { "agent.\(id)" }

    func agent(_ id: String) -> AgentRecord? {
        agents.first { $0.id == id }
    }

    func reload() {
        let rows = (try? AppDatabase.user.query("SELECT * FROM agents ORDER BY sort, created_at")) ?? []
        agents = rows.compactMap { row in
            guard let id = row.string("id"), let type = row.string("type").flatMap(AgentRecord.AgentType.init) else { return nil }
            let kinds = row.string("kinds").flatMap { try? JSONDecoder().decode([AgentModels.Kind].self, from: Data($0.utf8)) } ?? []
            return AgentRecord(id: id, type: type, name: row.string("name") ?? "", url: row.string("url") ?? "",
                               version: row.string("version"), kinds: kinds, relocations: row.int("relocations") == 1)
        }
    }

    /// 사용자 정의 에이전트를 추가한다. 에이전트에게 정보(이름·종류)를 물어보고, 대답하면 저장한다.
    func addCustom(url: String, key: String) async throws -> AgentRecord {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        let info = try await AgentClient(baseURL: trimmed, key: key).info()
        let record = AgentRecord(id: UUID().uuidString, type: .custom, name: info.name, url: trimmed, version: info.version,
                                 kinds: info.kinds, relocations: info.relocations ?? false)
        try save(record, key: key)
        return record
    }

    /// TMDB 에이전트를 추가한다 (키가 맞는지 TMDB 에 물어보고 저장)
    func addTMDB(key: String) async throws -> AgentRecord {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        let url = "https://api.themoviedb.org/3"
        try await TMDBAgent(baseURL: url, key: trimmed).check()
        let record = AgentRecord(id: UUID().uuidString, type: .tmdb, name: "TMDB", url: url, version: nil,
                                 kinds: Self.tmdbKinds, relocations: false)
        try save(record, key: trimmed)
        return record
    }

    /// 에이전트 정보를 다시 받는다 (종류가 바뀌었을 수 있다)
    func refresh(_ record: AgentRecord) async throws {
        guard record.type == .custom else { return }
        let info = try await record.customClient.info()
        var updated = record
        updated.name = info.name
        updated.version = info.version
        updated.kinds = info.kinds
        updated.relocations = info.relocations ?? false
        try save(updated, key: nil)
    }

    /// 주소·키를 바꾼다 (키가 nil 이면 그대로)
    func update(_ record: AgentRecord, url: String, key: String?) async throws {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        if record.type == .tmdb {
            if let key, !key.isEmpty { try await TMDBAgent(baseURL: record.url, key: key).check() }
            try save(record, key: key)
            return
        }
        let info = try await AgentClient(baseURL: trimmed, key: key ?? Keychain.password(for: Self.keyAccount(record.id))).info()
        var updated = record
        updated.url = trimmed
        updated.name = info.name
        updated.version = info.version
        updated.kinds = info.kinds
        updated.relocations = info.relocations ?? false
        try save(updated, key: key)
    }

    /// 순서 바꾸기 (설정 → 에이전트에서 끌어서)
    func move(from source: IndexSet, to destination: Int) {
        var ordered = agents
        ordered.move(fromOffsets: source, toOffset: destination)
        try? AppDatabase.user.transaction {
            for (index, agent) in ordered.enumerated() {
                try AppDatabase.user.execute("UPDATE agents SET sort = ? WHERE id = ?", [.int(Int64(index)), .text(agent.id)])
            }
        }
        reload()
        ordered.forEach { SyncEngine.shared.changed(Self.syncKind, key: $0.id) }
    }

    func remove(_ record: AgentRecord) {
        try? AppDatabase.user.execute("DELETE FROM agents WHERE id = ?", [.text(record.id)])
        Keychain.deletePassword(for: Self.keyAccount(record.id))
        reload()
        SyncEngine.shared.changed(Self.syncKind, key: record.id)
    }

    fileprivate func save(_ record: AgentRecord, key: String?) throws {
        let kinds = String(decoding: try JSONEncoder().encode(record.kinds), as: UTF8.self)
        try AppDatabase.user.execute(
            """
            INSERT INTO agents (id, type, name, url, version, kinds, relocations, sort, created_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, (SELECT COUNT(*) FROM agents), ?)
            ON CONFLICT(id) DO UPDATE SET name = excluded.name, url = excluded.url, version = excluded.version,
                kinds = excluded.kinds, relocations = excluded.relocations
            """,
            [.text(record.id), .text(record.type.rawValue), .text(record.name), .text(record.url), .of(record.version),
             .text(kinds), .int(record.relocations ? 1 : 0), .of(Date.now)]
        )
        SyncEngine.shared.changed(Self.syncKind, key: record.id)
        if let key {
            if key.isEmpty {
                Keychain.deletePassword(for: Self.keyAccount(record.id))
            } else {
                Keychain.setPassword(key, for: Self.keyAccount(record.id))
            }
        }
        reload()
    }
}

// MARK: - 동기화 (API 키는 iCloud 키체인으로 따로 넘어간다)

extension AgentStore {
    static let syncKind = "agent"

    private struct Payload: Codable {
        let id: String
        let type: String
        let name: String
        let url: String
        let version: String?
        let kinds: [AgentModels.Kind]
        let relocations: Bool
        /// 순서 (없으면 그대로)
        var sort: Int?
    }

    var syncKinds: [SyncEngine.Kind] {
        [SyncEngine.Kind(name: Self.syncKind) { [unowned self] in
            agents.map(\.id)
        } payload: { [unowned self] key in
            guard let agent = agent(key) else { return nil }
            return try? syncEncoder.encode(Payload(id: agent.id, type: agent.type.rawValue, name: agent.name, url: agent.url,
                                                   version: agent.version, kinds: agent.kinds, relocations: agent.relocations,
                                                   sort: agents.firstIndex { $0.id == key }))
        } apply: { [unowned self] _, data in
            guard let payload = try? JSONDecoder().decode(Payload.self, from: data),
                  let type = AgentRecord.AgentType(rawValue: payload.type) else { return false }
            try? save(AgentRecord(id: payload.id, type: type, name: payload.name, url: payload.url, version: payload.version,
                                  kinds: payload.kinds, relocations: payload.relocations), key: nil)
            if let sort = payload.sort {
                try? AppDatabase.user.execute("UPDATE agents SET sort = ? WHERE id = ?", [.int(Int64(sort)), .text(payload.id)])
                reload()
            }
            return true
        } delete: { [unowned self] key in
            try? AppDatabase.user.execute("DELETE FROM agents WHERE id = ?", [.text(key)])
            reload()
        }]
    }
}
