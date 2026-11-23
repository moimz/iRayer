import Foundation
import Observation
import SwiftUI

/// 라이브러리 종류 (서버의 종류 id 와 같은 값)
enum LibraryKind: String, CaseIterable, Identifiable {
    case movie, drama, anime, docu, variety, etc

    var id: String { rawValue }

    var title: String {
        switch self {
        case .movie: "영화"
        case .drama: "드라마"
        case .anime: "애니메이션"
        case .docu: "다큐멘터리"
        case .variety: "예능"
        case .etc: "기타"
        }
    }

    var symbol: String {
        switch self {
        case .movie: "film"
        case .drama: "tv"
        case .anime: "photo.tv"
        case .docu: "graduationcap"
        case .variety: "popcorn"
        case .etc: "square.stack"
        }
    }

    /// 에이전트에서 이 라이브러리에 맞는 종류 (같은 id, 없으면 이름, TMDB 는 영화·TV 시리즈)
    func suggestedKind(in agent: AgentRecord) -> String? {
        if let same = agent.kinds.first(where: { $0.id == rawValue }) { return same.id }
        if let named = agent.kinds.first(where: { $0.name == title }) { return named.id }
        // 바뀜 (2026-11-07): 에이전트 종류가 영화·TV 시리즈·자동·기타 넷이 됨 (드라마·애니메이션·예능 = TV 시리즈, 다큐 = 자동)
        let mapped = switch self {
        case .movie: "movie"
        case .drama, .anime, .variety: "tv"
        case .docu: "auto"
        case .etc: "etc"
        }
        if agent.kinds.contains(where: { $0.id == mapped }) { return mapped }
        if agent.type == .tmdb { return self == .movie ? "movie" : "tv" }
        return agent.kinds.first?.id
    }
}

/// 라이브러리 하나: 저장소의 폴더 하나 + 종류 + 차례로 물어볼 에이전트
/// 바뀜 (2026-11-07): 폴더 여러 개 (folders). 에이전트는 라이브러리에 하나 (모든 폴더에 같이). 폴더 하나는 한 라이브러리에만.
struct LibraryRecord: Identifiable, Hashable {
    struct Agent: Hashable {
        var agentID: String
        /// 그 에이전트의 종류 id
        var kind: String
    }

    /// 라이브러리 폴더 (저장소마다 다를 수 있다). 파일 경로는 이 폴더 기준.
    struct Folder: Identifiable, Hashable {
        let id: String
        var serverID: UUID
        var rootURL: URL
    }

    let id: String
    var name: String
    var kind: LibraryKind
    /// 순서대로 (맨 위가 첫 폴더)
    var folders: [Folder]
    var agents: [Agent]
    var scannedAt: Date?
    /// Apple TV 구입작도 이 라이브러리에 넣는다 (영화 라이브러리만)
    var appleTV = false
    /// 홈의 이어보기·최근 추가·장르에 보여준다
    var showsOnHome = true
    /// 홈에 이 라이브러리의 "최근 추가된 …" 포스터 줄을 둔다 (홈에 표시를 켰을 때만)
    var homeShelf = true
    /// 사용자가 고른 아이콘 (SF Symbol 이름, 없으면 종류의 아이콘)
    var icon: String?

    var symbol: String { icon ?? kind.symbol }

    func folder(_ id: String) -> Folder? {
        folders.first { $0.id == id }
    }
}

/// 라이브러리 관리 (User.sqlite)
@Observable
final class LibraryStore {
    static let shared = LibraryStore()

    private(set) var libraries: [LibraryRecord] = []

    private init() {
        reload()
    }

    func library(_ id: String) -> LibraryRecord? {
        libraries.first { $0.id == id }
    }

    /// 홈에 보여줄 라이브러리
    var homeLibraryIDs: [String] {
        libraries.filter(\.showsOnHome).map(\.id)
    }

    func reload() {
        let database = AppDatabase.user
        let rows = (try? database.query("SELECT * FROM libraries ORDER BY sort, created_at")) ?? []
        let agentRows = (try? database.query("SELECT * FROM library_agents ORDER BY library_id, sort")) ?? []
        let folderRows = (try? database.query("SELECT * FROM library_folders ORDER BY library_id, sort")) ?? []
        libraries = rows.compactMap { row in
            guard let id = row.string("id"), let kind = row.string("kind").flatMap(LibraryKind.init) else { return nil }
            let folders = folderRows.filter { $0.string("library_id") == id }.compactMap { folder -> LibraryRecord.Folder? in
                guard let folderID = folder.string("id"), let serverID = folder.string("server_id").flatMap(UUID.init(uuidString:)),
                      let rootURL = folder.string("root_url").flatMap(URL.init(string:)) else { return nil }
                return LibraryRecord.Folder(id: folderID, serverID: serverID, rootURL: rootURL)
            }
            let agents = agentRows.filter { $0.string("library_id") == id }.compactMap { agent -> LibraryRecord.Agent? in
                guard let agentID = agent.string("agent_id"), let kind = agent.string("agent_kind") else { return nil }
                return LibraryRecord.Agent(agentID: agentID, kind: kind)
            }
            return LibraryRecord(id: id, name: row.string("name") ?? kind.title, kind: kind,
                                 folders: folders, agents: agents, scannedAt: row.date("scanned_at"), appleTV: row.int("apple_tv") == 1,
                                 showsOnHome: row.int("home") != 0, homeShelf: row.int("home_shelf") != 0, icon: row.string("icon"))
        }
    }

    func save(_ library: LibraryRecord) throws {
        let database = AppDatabase.user
        try database.transaction {
            try database.execute(
                """
                INSERT INTO libraries (id, name, kind, sort, scanned_at, created_at, apple_tv, home, home_shelf, icon)
                VALUES (?, ?, ?, (SELECT COUNT(*) FROM libraries), ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET name = excluded.name, kind = excluded.kind,
                    apple_tv = excluded.apple_tv, home = excluded.home, home_shelf = excluded.home_shelf, icon = excluded.icon
                """,
                [.text(library.id), .text(library.name), .text(library.kind.rawValue), .of(library.scannedAt), .of(Date.now), .int(library.appleTV ? 1 : 0), .int(library.showsOnHome ? 1 : 0), .int(library.homeShelf ? 1 : 0), .of(library.icon)]
            )
            try database.execute("DELETE FROM library_folders WHERE library_id = ?", [.text(library.id)])
            for (index, folder) in library.folders.enumerated() {
                try database.execute(
                    "INSERT INTO library_folders (id, library_id, server_id, root_url, sort) VALUES (?, ?, ?, ?, ?)",
                    [.text(folder.id), .text(library.id), .text(folder.serverID.uuidString), .text(folder.rootURL.absoluteString), .int(Int64(index))]
                )
            }
            try database.execute("DELETE FROM library_agents WHERE library_id = ?", [.text(library.id)])
            for (index, agent) in library.agents.enumerated() {
                try database.execute(
                    "INSERT INTO library_agents (library_id, sort, agent_id, agent_kind) VALUES (?, ?, ?, ?)",
                    [.text(library.id), .int(Int64(index)), .text(agent.agentID), .text(agent.kind)]
                )
            }
        }
        reload()
        SyncEngine.shared.changed(Self.syncKind, key: library.id)
        // Apple TV 구입작은 한 라이브러리에만 (사용자 2026-11-07): 켰으면 다른 라이브러리에서 끄고 넣어 둔 구입작을 지운다
        if library.appleTV {
            for other in libraries where other.id != library.id && other.appleTV {
                try? database.execute("UPDATE libraries SET apple_tv = 0 WHERE id = ?", [.text(other.id)])
                try? AppDatabase.library.execute("DELETE FROM purchases WHERE library_id = ?", [.text(other.id)])
                SyncEngine.shared.changed(Self.syncKind, key: other.id)
            }
            reload()
            LibraryScanner.shared.refreshViews()
        }
    }

    func setScanned(_ id: String) {
        try? AppDatabase.user.execute("UPDATE libraries SET scanned_at = ? WHERE id = ?", [.of(Date.now), .text(id)])
        reload()
    }

    /// 라이브러리를 뺀다 (저장소 안의 파일은 그대로, 받아 둔 메타정보만 지운다)
    func remove(_ library: LibraryRecord) {
        try? AppDatabase.user.execute("DELETE FROM libraries WHERE id = ?", [.text(library.id)])
        try? AppDatabase.library.execute("DELETE FROM files WHERE library_id = ?", [.text(library.id)])
        try? AppDatabase.library.execute("DELETE FROM purchases WHERE library_id = ?", [.text(library.id)])
        reload()
        SyncEngine.shared.changed(Self.syncKind, key: library.id)
    }

    /// 이 폴더와 겹치는(같거나 한쪽이 다른 쪽 안에 든) 다른 라이브러리 폴더 — 폴더 하나는 한 라이브러리에만 (사용자 2026-11-07)
    func overlapping(serverID: UUID, url: URL, excluding libraryID: String?) -> LibraryRecord? {
        let path = Self.folderPath(url)
        return libraries.first { library in
            library.id != libraryID && library.folders.contains { folder in
                guard folder.serverID == serverID else { return false }
                let other = Self.folderPath(folder.rootURL)
                return path.hasPrefix(other) || other.hasPrefix(path)
            }
        }
    }

    /// 비교용 폴더 경로 (끝에 / 하나, NFC)
    private static func folderPath(_ url: URL) -> String {
        var path = url.standardizedFileURL.path(percentEncoded: false).precomposedStringWithCanonicalMapping
        if !path.hasSuffix("/") { path += "/" }
        return path
    }

    func move(from source: IndexSet, to destination: Int) {
        var ordered = libraries
        ordered.move(fromOffsets: source, toOffset: destination)
        try? AppDatabase.user.transaction {
            for (index, library) in ordered.enumerated() {
                try AppDatabase.user.execute("UPDATE libraries SET sort = ? WHERE id = ?", [.int(Int64(index)), .text(library.id)])
            }
        }
        reload()
        ordered.forEach { SyncEngine.shared.changed(Self.syncKind, key: $0.id) }
    }
}

// MARK: - 동기화 (라이브러리 설정만. 파일 목록과 메타정보는 기기마다 훑어서 받는다)

extension LibraryStore {
    static let syncKind = "library"

    /// 바뀜 (2026-11-07): serverID·rootURL 하나 대신 folders (예전 형식은 읽지 않는다 — 모든 기기를 같이 올린다, 사용자)
    private struct Payload: Codable {
        struct Agent: Codable { let agentID: String; let kind: String }
        struct Folder: Codable { let id: String; let serverID: UUID; let rootURL: URL }
        let id: String
        let name: String
        let kind: String
        let folders: [Folder]
        let agents: [Agent]
        let sort: Int
        /// 없으면 끔 (이 설정이 생기기 전 기기가 올린 것)
        var appleTV: Bool?
        var showsOnHome: Bool?
        var homeShelf: Bool?
        var icon: String?
    }

    var syncKinds: [SyncEngine.Kind] {
        [SyncEngine.Kind(name: Self.syncKind) { [unowned self] in
            libraries.map(\.id)
        } payload: { [unowned self] key in
            guard let index = libraries.firstIndex(where: { $0.id == key }) else { return nil }
            let library = libraries[index]
            return try? syncEncoder.encode(Payload(id: library.id, name: library.name, kind: library.kind.rawValue,
                                                   folders: library.folders.map { Payload.Folder(id: $0.id, serverID: $0.serverID, rootURL: $0.rootURL) },
                                                   agents: library.agents.map { Payload.Agent(agentID: $0.agentID, kind: $0.kind) },
                                                   sort: index, appleTV: library.appleTV, showsOnHome: library.showsOnHome, homeShelf: library.homeShelf, icon: library.icon))
        } apply: { [unowned self] _, data in
            guard let payload = try? JSONDecoder().decode(Payload.self, from: data), let kind = LibraryKind(rawValue: payload.kind) else { return false }
            let old = library(payload.id)
            let record = LibraryRecord(id: payload.id, name: payload.name, kind: kind,
                                       folders: payload.folders.map { LibraryRecord.Folder(id: $0.id, serverID: $0.serverID, rootURL: $0.rootURL) },
                                       agents: payload.agents.map { LibraryRecord.Agent(agentID: $0.agentID, kind: $0.kind) },
                                       scannedAt: old?.scannedAt, appleTV: payload.appleTV ?? false,
                                       showsOnHome: payload.showsOnHome ?? true, homeShelf: payload.homeShelf ?? true, icon: payload.icon)
            try? save(record)
            // 다른 기기에서 Apple TV 구입작을 켜거나 껐으면 이 기기에서도 다시 넣는다 (이미 훑은 라이브러리만: 처음이면 어차피 훑는다)
            if let old, old.scannedAt != nil, old.appleTV != record.appleTV || old.folders != record.folders { LibraryScanner.shared.scan(record) }
            try? AppDatabase.user.execute("UPDATE libraries SET sort = ? WHERE id = ?", [.int(Int64(payload.sort)), .text(payload.id)])
            reload()
            return true
        } delete: { [unowned self] key in
            try? AppDatabase.user.execute("DELETE FROM libraries WHERE id = ?", [.text(key)])
            try? AppDatabase.library.execute("DELETE FROM files WHERE library_id = ?", [.text(key)])
            try? AppDatabase.library.execute("DELETE FROM purchases WHERE library_id = ?", [.text(key)])
            reload()
        }]
    }
}
