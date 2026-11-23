import Foundation
import Observation

/// 라이브러리 훑기: 저장소 폴더의 영상을 모두 찾아 해시를 만들고, 에이전트에게 차례로 물어본다.
/// 바뀌지 않은 파일(크기·수정 시각이 같은 것)은 다시 묻지 않는다. 못 찾은 파일은 다시 훑어도 묻지 않고, "다시 매칭" 으로만.
@Observable
final class LibraryScanner {
    static let shared = LibraryScanner()

    struct Progress {
        var phase: String
        var done = 0
        var total = 0
    }

    /// 훑는 중인 라이브러리와 진행 상황
    private(set) var running: [String: Progress] = [:]
    /// 라이브러리마다 마지막 오류
    private(set) var errors: [String: String] = [:]
    /// 화면을 다시 읽게 하는 신호 (훑기가 끝날 때·파일 하나가 매칭될 때 바뀐다)
    private(set) var revision = 0

    @ObservationIgnored private var tasks: [String: Task<Void, Never>] = [:]

    private init() {}

    func isRunning(_ libraryID: String) -> Bool { running[libraryID] != nil }

    /// 목록·선반을 다시 읽게 한다 (성인 등급 숨기기를 켜고 끌 때)
    func refreshViews() {
        revision += 1
    }

    // MARK: - 관람등급 채우기

    @ObservationIgnored private var ratingTask: Task<Void, Never>?

    /// 관람등급을 받기 전에 저장한 작품의 등급을 에이전트에게 다시 받아 채운다 (앱을 켤 때, 이 기기에 없는 것만 한 번).
    /// 에이전트가 등급을 다루지 않으면(예전 서버) 앞의 몇 편만 묻고 그만둔다 — 다음에 켤 때 다시.
    /// 바뀜 (2026-11-06): 등급이 "" 인 작품(예전 규칙: 한국·미국 등급만)도 새 규칙("ADULT"/"NR")으로 다시 받는다. 예전 서버는 또 "" 를 주므로 다루지 않는 것으로 센다
    func fillRatings() {
        guard ratingTask == nil else { return }
        let rows = (try? AppDatabase.library.query(
            "SELECT key, agent_id, id FROM items WHERE (rating IS NULL OR rating = '') AND agent_id != 'appletv' AND key IN (SELECT item_key FROM entries)")) ?? []
        let pending = rows.compactMap { row -> (key: String, agent: AgentRecord, id: String)? in
            guard let key = row.string("key"), let id = row.string("id"),
                  let agent = row.string("agent_id").flatMap(AgentStore.shared.agent) else { return nil }
            return (key, agent, id)
        }
        guard !pending.isEmpty else { return }
        ratingTask = Task {
            var filled = 0, unsupported = 0
            for chunk in stride(from: 0, to: pending.count, by: 4).map({ Array(pending[$0..<min($0 + 4, pending.count)]) }) {
                if Task.isCancelled || (filled == 0 && unsupported >= 8) { break }
                let results = await withTaskGroup(of: (String, String, AgentModels.Item?).self) { group in
                    for entry in chunk {
                        group.addTask { (entry.key, entry.agent.id, try? await entry.agent.client.item(entry.id)) }
                    }
                    return await group.reduce(into: []) { $0.append($1) }
                }
                for (key, agentID, item) in results {
                    guard let item else { continue }
                    if item.rating == nil || item.rating == "" { unsupported += 1; continue }
                    try? LibraryData.saveItem(item, key: key, agentID: agentID)
                    filled += 1
                }
                if filled > 0, filled % 40 < 4 { revision += 1 }
            }
            if filled > 0 { revision += 1 }
            ratingTask = nil
        }
    }

    /// 훑기 시작 (이미 하는 중이면 그대로). retryUnmatched 면 못 찾은 파일도 다시 묻는다.
    func scan(_ library: LibraryRecord, retryUnmatched: Bool = false) {
        guard tasks[library.id] == nil else { return }
        errors[library.id] = nil
        running[library.id] = Progress(phase: "폴더를 읽는 중")
        tasks[library.id] = Task {
            do {
                try await run(library, retryUnmatched: retryUnmatched)
                LibraryStore.shared.setScanned(library.id)
            } catch is CancellationError {
            } catch {
                errors[library.id] = error.localizedDescription
            }
            running[library.id] = nil
            tasks[library.id] = nil
            revision += 1
        }
    }

    func cancel(_ libraryID: String) {
        tasks[libraryID]?.cancel()
    }

    // MARK: - 훑기

    private struct Found {
        let url: URL
        /// 라이브러리 폴더 (path 는 이 폴더 기준)
        let folderID: String
        let serverID: UUID
        let path: String
        let rawPath: String
        let size: Int64
        let modifiedAt: Date
    }

    /// 바뀜 (2026-11-07): 라이브러리의 폴더마다 훑는다. 파일은 폴더 id + 폴더 기준 경로로 저장 (같은 경로가 두 폴더에 있어도 따로).
    ///   목록에서 빠진 폴더의 파일은 지운다.
    private func run(_ library: LibraryRecord, retryUnmatched: Bool) async throws {
        // 1. 폴더 전체의 영상 파일
        var found: [Found] = []
        for folder in library.folders {
            try await walk(folder.rootURL, root: folder.rootURL, folder: folder, into: &found) { count in
                self.running[library.id]?.phase = "폴더를 읽는 중 (\(count)개)"
            }
        }

        // 2. 저장해 둔 목록과 비교: 없어진 것은 지우고, 새것·바뀐 것은 다시
        let database = AppDatabase.library
        let rows = try database.query("SELECT folder_id, path, size, modified_at, status FROM files WHERE library_id = ?", [.text(library.id)])
        /// 키: 폴더 id + "\n" + 경로
        func key(_ folderID: String, _ path: String) -> String { folderID + "\n" + path }
        var known: [String: (folderID: String, path: String, size: Int64, modifiedAt: Double, status: String)] = [:]
        for row in rows {
            if let folderID = row.string("folder_id"), let path = row.string("path") {
                known[key(folderID, path)] = (folderID, path, row.int64("size") ?? 0, row.double("modified_at") ?? 0, row.string("status") ?? "new")
            }
        }
        let keys = Set(found.map { key($0.folderID, $0.path) })
        try database.transaction {
            for (fileKey, old) in known where !keys.contains(fileKey) {
                try database.execute("DELETE FROM files WHERE library_id = ? AND folder_id = ? AND path = ?",
                                     [.text(library.id), .text(old.folderID), .text(old.path)])
            }
            for file in found {
                let old = known[key(file.folderID, file.path)]
                let changed = old == nil || old?.size != file.size || abs((old?.modifiedAt ?? 0) - file.modifiedAt.timeIntervalSince1970) > 1
                if changed {
                    try database.execute(
                        """
                        INSERT INTO files (library_id, folder_id, path, raw_path, size, modified_at, status, added_at) VALUES (?, ?, ?, ?, ?, ?, 'new', ?)
                        ON CONFLICT(library_id, folder_id, path) DO UPDATE SET raw_path = excluded.raw_path, size = excluded.size,
                            modified_at = excluded.modified_at, hash = NULL, status = 'new', item_key = NULL, message = NULL
                        """,
                        [.text(library.id), .text(file.folderID), .text(file.path), .text(file.rawPath), .int(file.size), .of(file.modifiedAt), .of(Date.now)]
                    )
                } else {
                    try database.execute("UPDATE files SET raw_path = ? WHERE library_id = ? AND folder_id = ? AND path = ?",
                                         [.text(file.rawPath), .text(library.id), .text(file.folderID), .text(file.path)])
                }
            }
        }

        // 시리즈에 매칭됐는데 시즌·회차가 비어 있는 파일은 다시 묻는다 (TMDB 에 회차 정보가 없으면 예전 서버가 번호를 안 줘 비었다, 2026-11-07)
        let missing = (try? database.query(
            """
            SELECT f.folder_id, f.path FROM files f JOIN items i ON i.key = f.item_key
            WHERE f.library_id = ? AND f.status = 'matched' AND i.type = 'SERIES' AND (f.season IS NULL OR f.episode IS NULL)
            """, [.text(library.id)])) ?? []
        for row in missing {
            guard let folderID = row.string("folder_id"), let path = row.string("path") else { continue }
            LibraryData.setStatus("error", message: "시즌·회차가 비어 다시 매칭합니다.", libraryID: library.id, folderID: folderID, path: path)
            known[key(folderID, path)]?.status = "error"
        }

        // 3. 물어볼 파일: 새것, 오류난 것 (+ 원하면 못 찾은 것)
        let statuses = retryUnmatched ? ["new", "error", "unmatched"] : ["new", "error"]
        let pending = found.filter { file in
            guard let old = known[key(file.folderID, file.path)] else { return true }
            let changed = old.size != file.size || abs(old.modifiedAt - file.modifiedAt.timeIntervalSince1970) > 1
            return changed || statuses.contains(old.status)
        }
        running[library.id] = Progress(phase: "매칭하는 중", done: 0, total: pending.count)

        // 4. 해시 → 에이전트 (동시에 몇 개씩)
        let agents = library.agents.compactMap { entry in AgentStore.shared.agent(entry.agentID).map { ($0, entry.kind) } }
        try await withThrowingTaskGroup(of: Void.self) { group in
            var iterator = pending.makeIterator()
            func next() -> Bool {
                guard let file = iterator.next() else { return false }
                group.addTask { await self.match(file, library: library, agents: agents) }
                return true
            }
            for _ in 0..<4 { if !next() { break } }
            while try await group.next() != nil {
                try Task.checkCancellation()
                running[library.id]?.done += 1
                if running[library.id]!.done % 10 == 0 { revision += 1 }
                _ = next()
            }
        }

        // 5. Apple TV 구입작
        try await matchPurchases(library, agents: agents)
    }

    // MARK: - Apple TV 구입작

    /// Apple TV 구입 목록이 바뀌었다: 구입작을 넣는 라이브러리를 다시 훑는다 (iCloud 로 한 편씩 들어오니 잠깐 모았다가)
    func appleTVChanged() {
        appleTVTask?.cancel()
        appleTVTask = Task {
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            for library in LibraryStore.shared.libraries where library.appleTV && library.scannedAt != nil {
                scan(library)
            }
        }
    }

    @ObservationIgnored private var appleTVTask: Task<Void, Never>?

    /// 구입 목록을 라이브러리에 맞춘다: 새 구입작은 에이전트에서 찾아 작품에 잇는다 (못 찾으면 상점 정보만으로)
    private func matchPurchases(_ library: LibraryRecord, agents: [(AgentRecord, String)]) async throws {
        let database = AppDatabase.library
        // 바뀜 (2026-11-07): 영화 라이브러리가 아니어도 (라이브러리 종류를 고르지 않게 됨, 켤 수 있는 라이브러리는 하나)
        guard library.appleTV else {
            try database.execute("DELETE FROM purchases WHERE library_id = ?", [.text(library.id)])
            return
        }
        let movies = AppleTVLibrary.shared.movies
        let rows = try database.query("SELECT store_id, status FROM purchases WHERE library_id = ?", [.text(library.id)])
        var known: [Int: String] = [:]
        for row in rows {
            if let id = row.int("store_id") { known[id] = row.string("status") ?? "new" }
        }
        // 처음 켤 때 한꺼번에 들어오는 구입작은 들어온 때를 비워 둔다 (홈의 최근 추가에 몰리지 않게)
        let addedAt: Date? = known.isEmpty ? nil : .now
        let ids = Set(movies.map(\.storeID))
        try database.transaction {
            for id in known.keys where !ids.contains(id) {
                try database.execute("DELETE FROM purchases WHERE library_id = ? AND store_id = ?", [.text(library.id), .int(Int64(id))])
            }
            for movie in movies where known[movie.storeID] == nil {
                try database.execute("INSERT INTO purchases (library_id, store_id, title, year, added_at) VALUES (?, ?, ?, ?, ?)",
                                     [.text(library.id), .int(Int64(movie.storeID)), .text(movie.title), .of(movie.year), .of(addedAt)])
            }
        }

        // 못 찾은 구입작은 훑을 때마다 다시 찾는다 (몇 편 안 되고 검색만 하면 된다)
        let pending = movies.filter { known[$0.storeID] != "matched" }
        guard !pending.isEmpty else { return }
        running[library.id] = Progress(phase: "Apple TV 구입작 매칭하는 중", done: 0, total: pending.count)
        try await withThrowingTaskGroup(of: Void.self) { group in
            var iterator = pending.makeIterator()
            func next() -> Bool {
                guard let movie = iterator.next() else { return false }
                group.addTask { await self.matchPurchase(movie, library: library, agents: agents) }
                return true
            }
            for _ in 0..<4 { if !next() { break } }
            while try await group.next() != nil {
                try Task.checkCancellation()
                running[library.id]?.done += 1
                if running[library.id]!.done % 10 == 0 { revision += 1 }
                _ = next()
            }
        }
    }

    /// 구입작 하나: 에이전트마다 제목으로 검색해 확실한 후보가 있으면 그 작품으로
    private func matchPurchase(_ movie: AppleTVLibrary.Movie, library: LibraryRecord, agents: [(AgentRecord, String)]) async {
        var lastMessage = agents.isEmpty ? "에이전트가 없습니다." : nil
        var failed = false
        var titles = Self.searchTitles(movie.title)
        if let english = AppleTVLibrary.shared.englishTitles[movie.storeID], !english.isEmpty {
            titles += Self.searchTitles(english).filter { !titles.contains($0) }
        }
        for (agent, kind) in agents {
            do {
                var choice: AgentModels.Candidate?
                // 연도는 넣지 않는다: 확장판·리마스터는 상점의 연도가 그 판이 나온 해다
                // 제목으로 못 찾으면 짧은 검색어로 넓게 찾고 고르는 것은 온 제목으로 (TMDB 검색은 낱말 단위라
                // "드래곤길들이기2"·"인디아나 존스와 최후의 성전" 처럼 띄어쓰기·토씨가 다르면 아무것도 안 나온다)
                for query in titles + Self.shortQueries(titles) where choice == nil {
                    choice = Self.pick(try await agent.client.search(kind: kind, query: query, year: nil), titles: titles, year: movie.year,
                                       yearOnly: titles.contains(query))
                }
                guard let choice else {
                    lastMessage = "\(agent.name): 찾지 못했습니다."
                    continue
                }
                let item = try await agent.client.item(choice.id.value, kind: kind)
                try LibraryData.savePurchase(item, libraryID: library.id, storeID: movie.storeID, agentID: agent.id)
                return
            } catch {
                failed = true
                lastMessage = "\(agent.name): \(error.localizedDescription)"
            }
        }
        LibraryData.savePurchaseUnmatched(movie, poster: AppleTVLibrary.shared.posters[movie.storeID], libraryID: library.id,
                                          status: failed ? "error" : "unmatched", message: lastMessage)
    }

    /// 상점 제목으로 검색할 제목들: 괄호(확장판·Extended Version·연도)를 뗀 제목, 괄호 속이 다른 제목이면 그것도
    /// 예: "대부 (The Godfather)" → ["대부", "The Godfather"], "반지의 제왕: 왕의 귀환(확장판)" → ["반지의 제왕: 왕의 귀환"]
    static func searchTitles(_ title: String) -> [String] {
        let pattern = #"\s*[\(\[]([^\)\]]*)[\)\]]"#
        let base = title.replacingOccurrences(of: pattern, with: "", options: .regularExpression).trimmingCharacters(in: .whitespaces)
        var titles = base.isEmpty ? [title] : [base]
        let edition = #"(?i)확장판|감독판|극장판|리마스터|extended|director|edition|version|remaster|^\d{4}$"#
        if let regex = try? NSRegularExpression(pattern: pattern) {
            for match in regex.matches(in: title, range: NSRange(title.startIndex..., in: title)) {
                guard let range = Range(match.range(at: 1), in: title) else { continue }
                let inner = title[range].trimmingCharacters(in: .whitespaces)
                if !inner.isEmpty, inner.range(of: edition, options: .regularExpression) == nil { titles.append(inner) }
            }
        }
        // "쉰들러 리스트 Schindler's List" 처럼 한글 제목 뒤에 영어 제목이 붙은 것은 나눠서
        for title in titles {
            if let split = title.wholeMatch(of: #/(.*\p{Script=Hangul}.*?)\s+([A-Za-z][^\p{Script=Hangul}]*)/#) {
                titles += [String(split.1), String(split.2)]
            }
        }
        // "드래곤길들이기2" 처럼 붙여 쓴 번호는 띄어서도
        for title in titles where title.contains(#/\p{Script=Hangul}\d/#) {
            titles.append(title.replacing(#/(\p{Script=Hangul})(\d)/#) { "\($0.1) \($0.2)" })
        }
        return titles
    }

    /// 넓게 찾을 짧은 검색어: 첫 낱말 (띄어 쓰지 않은 한글 제목은 앞 세 글자)
    static func shortQueries(_ titles: [String]) -> [String] {
        var queries: [String] = []
        for title in titles {
            let words = title.split(whereSeparator: { $0 == " " || $0 == ":" }).map(String.init)
            let query = words.count > 1 ? words[0] : String(title.prefix(3))
            if query.count >= 2, !titles.contains(query), !queries.contains(query) { queries.append(query) }
        }
        return queries
    }

    /// 검색 결과에서 그 구입작이 확실한 후보: 영화이고 제목이 같은 것 (여럿이면 연도가 가까운 것).
    /// 제목이 같은 것이 없으면 표기만 조금 다른 것, 그것도 없으면 연도까지 같은 후보가 하나뿐일 때만 (yearOnly: 짧은 검색어로 넓게 찾았으면 하지 않는다).
    static func pick(_ candidates: [AgentModels.Candidate], titles: [String], year: Int?, yearOnly: Bool = true) -> AgentModels.Candidate? {
        let movies = candidates.filter { $0.type == "MOVIE" }
        let keys = Set(titles.map(normalized))
        let sameTitle = movies.filter { keys.contains(normalized($0.title)) || $0.titleOrigin.map { keys.contains(normalized($0)) } == true }
        if let year {
            if let closest = sameTitle.min(by: { abs(($0.year ?? 0) - year) < abs(($1.year ?? 0) - year) }) { return closest }
            // 표기만 조금 다른 제목 (캐리비언·캐리비안, 리로리드·리로디드): 거의 같고 연도도 맞으면
            let near = movies.filter { candidate in
                guard let candidateYear = candidate.year, abs(candidateYear - year) <= 1 else { return false }
                return keys.contains { key in similarity(key, normalized(candidate.title)) >= 0.8 }
            }
            if near.count == 1 { return near.first }
            guard yearOnly else { return nil }
            let sameYear = movies.filter { $0.year == year }
            return sameYear.count == 1 ? sameYear.first : nil
        }
        return sameTitle.first
    }

    /// 두 글자열이 얼마나 같은지 (0~1, 편집 거리 기준)
    private static func similarity(_ a: String, _ b: String) -> Double {
        let a = Array(a), b = Array(b)
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        var row = Array(0...b.count)
        for i in 1...a.count {
            var previous = row[0]
            row[0] = i
            for j in 1...b.count {
                let current = row[j]
                row[j] = min(row[j] + 1, row[j - 1] + 1, previous + (a[i - 1] == b[j - 1] ? 0 : 1))
                previous = current
            }
        }
        return 1 - Double(row[b.count]) / Double(max(a.count, b.count))
    }

    /// 제목 비교용: 소문자, 글자·숫자만
    private static func normalized(_ title: String) -> String {
        String(title.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(Character.init))
            .precomposedStringWithCanonicalMapping
    }

    /// 파일 하나: 해시를 만들고 에이전트에게 차례로 묻는다
    private func match(_ file: Found, library: LibraryRecord, agents: [(AgentRecord, String)]) async {
        let hash: String
        do {
            hash = try await FileHasher.hash(file.url, size: file.size, serverID: file.serverID)
            try? AppDatabase.library.execute("UPDATE files SET hash = ? WHERE library_id = ? AND folder_id = ? AND path = ?",
                                             [.text(hash), .text(library.id), .text(file.folderID), .text(file.path)])
        } catch {
            LibraryData.setStatus("error", message: "파일을 읽지 못했습니다: \(error.localizedDescription)", libraryID: library.id, folderID: file.folderID, path: file.path)
            return
        }
        guard !agents.isEmpty else {
            LibraryData.setStatus("unmatched", message: "에이전트가 없습니다.", libraryID: library.id, folderID: file.folderID, path: file.path)
            return
        }

        var lastMessage: String?
        var failed = false
        for (agent, kind) in agents {
            do {
                let result = try await agent.client.match(kind: kind, hash: hash, size: file.size, path: file.path, duration: nil)
                if result.matched == true, result.item != nil {
                    try LibraryData.saveMatch(result, libraryID: library.id, folderID: file.folderID, path: file.path, agentID: agent.id)
                    return
                }
                lastMessage = switch result.reason {
                case "EXCLUDED": "\(agent.name): 이 종류는 다루지 않습니다."
                case "NO_EPISODE": "\(agent.name): 시리즈인데 시즌·회차를 알아내지 못했습니다."
                default: "\(agent.name): 찾지 못했습니다."
                }
            } catch {
                failed = true
                lastMessage = "\(agent.name): \(error.localizedDescription)"
            }
        }
        LibraryData.setStatus(failed ? "error" : "unmatched", message: lastMessage, libraryID: library.id, folderID: file.folderID, path: file.path,
                              agentID: agents.first?.0.id)
    }

    /// 폴더 아래 모든 영상 (이름이 . 이나 _ 로 시작하는 폴더는 건너뛴다: 숨김·_정리됨)
    private func walk(_ url: URL, root: URL, folder: LibraryRecord.Folder, into found: inout [Found], report: (Int) -> Void) async throws {
        try Task.checkCancellation()
        let items = try await DirectoryLister.items(in: url, serverID: folder.serverID)
        for item in items {
            let name = item.url.lastPathComponent
            if name.hasPrefix(".") { continue }
            if item.isDirectory {
                if name.hasPrefix("_") || name.hasPrefix("@") || name.hasPrefix("#") { continue }
                try await walk(item.url, root: root, folder: folder, into: &found, report: report)
            } else if VideoFile.isVideo(item.url) {
                let raw = Self.relativePath(item.url, root: root)
                found.append(Found(url: item.url, folderID: folder.id, serverID: folder.serverID, path: raw.precomposedStringWithCanonicalMapping, rawPath: raw,
                                   size: item.size, modifiedAt: item.modifiedAt))
                if found.count % 50 == 0 { report(found.count) }
            }
        }
    }

    /// 라이브러리 폴더 기준 경로 (저장소에 있는 그대로)
    static func relativePath(_ url: URL, root: URL) -> String {
        let base = root.path(percentEncoded: false)
        var path = url.path(percentEncoded: false)
        if path.hasPrefix(base) { path.removeFirst(base.count) }
        return path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    /// 파일 주소 (저장소에 있는 그대로의 경로로)
    /// 바뀜 (2026-11-07): 파일이 든 라이브러리 폴더 기준 (폴더가 목록에서 빠졌으면 첫 폴더 — 다음 훑기 때 지워진다)
    static func url(of file: LibraryData.FileEntry, in library: LibraryRecord) -> URL {
        // 화면이 들고 있던 라이브러리가 폴더를 넣기 전 것일 수 있어 지금 저장된 것을 쓴다
        let library = LibraryStore.shared.library(library.id) ?? library
        let root = (library.folder(file.folderID) ?? library.folders.first)?.rootURL ?? URL(filePath: "/")
        return root.appending(path: file.rawPath, directoryHint: .notDirectory)
    }
}
