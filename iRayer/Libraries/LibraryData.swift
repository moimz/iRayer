import Foundation

/// Library.sqlite 읽기·쓰기: 라이브러리 파일과 에이전트가 준 메타정보
enum LibraryData {
    private static var database: SQLiteDatabase { AppDatabase.library }

    // MARK: - 화면에 쓰는 모양

    /// 라이브러리 격자의 작품 하나
    struct ItemSummary: Identifiable, Hashable {
        let key: String
        /// 작품 파일이 든 라이브러리 (둘러보기에서 작품 화면을 열 때)
        var libraryID: String = ""
        let type: String
        let title: String
        let titleOrigin: String?
        let year: Int?
        let poster: String?
        let collectionName: String?
        /// 이 작품의 파일 수
        let files: Int
        /// Apple TV 에서 산 작품
        var appleTV = false
        /// 라이브러리에 들어온 때 (라이브러리 화면의 최근 추가순)
        var added: Date?
        /// 가로로 긴 배경 그림 (홈의 최근 추가된 항목 카드)
        var backdrop: String?

        var id: String { key }
        var isSeries: Bool { type == "SERIES" }
    }

    /// 작품 상세
    struct ItemDetail {
        let key: String
        let agentID: String
        let id: String
        let type: String
        let title: String
        let titleOrigin: String?
        let year: Int?
        let date: String?
        let summary: String?
        let poster: String?
        let backdrop: String?
        let collectionName: String?
        var collectionID: String?
        /// 관람등급 "나라:등급"
        var rating: String?
        let genres: [String]
        let credits: [Credit]

        var isSeries: Bool { type == "SERIES" }
    }

    struct Credit: Identifiable, Hashable {
        let personKey: String
        /// 정보출처:번호 (즐겨찾기·인물 화면의 키)
        let globalKey: String
        let name: String
        /// 원어 이름 (예: 堺雅人). 이름과 같으면 nil
        var nameOrigin: String?
        let photo: String?
        let role: String
        let character: String?

        var id: String { personKey + role }
    }

    /// 라이브러리의 파일 하나
    struct FileEntry: Identifiable, Hashable {
        let libraryID: String
        /// 라이브러리 폴더 (path 는 이 폴더 기준, 2026-11-07)
        let folderID: String
        let path: String
        let rawPath: String
        let hash: String?
        let size: Int64
        let status: String
        let message: String?
        let itemKey: String?
        let season: Int?
        let episode: Int?
        let episodeEnd: Int?
        let targetFolder: String?
        let targetName: String?

        var id: String { libraryID + "|" + folderID + "|" + path }
        var name: String { (path as NSString).lastPathComponent }
    }

    struct EpisodeEntry: Hashable {
        let season: Int
        let episode: Int
        let title: String?
        let summary: String?
        let date: String?
        let still: String?
    }

    // MARK: - 읽기

    static func items(in libraryID: String) -> [ItemSummary] {
        let rows = (try? database.query(
            """
            SELECT i.key, i.type, i.title, i.title_origin, i.year, i.poster, i.collection_name,
                SUM(1 - f.purchase) AS files, MAX(f.purchase) AS purchased, MAX(f.added_at) AS added
            FROM \(visibleEntries) f JOIN items i ON i.key = f.item_key
            WHERE f.library_id = ?
            GROUP BY i.key
            """,
            [.text(libraryID)]
        )) ?? []
        return rows.compactMap { row in
            guard let key = row.string("key"), let title = row.string("title") else { return nil }
            return ItemSummary(key: key, libraryID: libraryID, type: row.string("type") ?? "MOVIE", title: title, titleOrigin: row.string("title_origin"),
                               year: row.int("year"), poster: row.string("poster"), collectionName: row.string("collection_name"),
                               files: row.int("files") ?? 0, appleTV: row.int("purchased") == 1, added: row.date("added"))
        }
        .sorted { KoreanIndex.precedes($0.title, $1.title) }
    }

    // MARK: - 둘러보기 (모든 라이브러리)

    struct GenreEntry: Identifiable, Hashable {
        let name: String
        let count: Int
        let posters: [String]
        /// 그 장르에 가장 최근 들어온 파일 (최근 추가순)
        var added: Date?
        var id: String { name }
    }

    struct CollectionEntry: Identifiable, Hashable {
        let id: String
        let name: String
        let count: Int
        let posters: [String]
        /// 그 컬렉션에 가장 최근 들어온 파일 (최근 추가순)
        var added: Date?
    }

    struct PersonSummary: Identifiable, Hashable {
        /// 정보출처:번호 (에이전트가 달라도 같은 사람)
        let key: String
        let name: String
        let photo: String?
        let works: Int
        /// 원어 이름 (예: 堺雅人). 이름과 같으면 nil
        var nameOrigin: String?
        var id: String { key }
    }

    // MARK: - 성인 등급 숨기기

    /// 성인 등급 ("나라:등급"): 한국 18·19·청소년관람불가·제한상영가, 미국 R·NC-17·TV-MA.
    /// TMDB 의 한국 등급은 사람이 넣어 "12세 이상 관람가", "청소년 관람불가" 처럼 글로 된 것도 있어 패턴으로 본다.
    /// (SQL 조건과 같은 규칙: adultCondition)
    /// 바뀜 (2026-11-06): "ADULT" (한국·미국 등급이 없고 성인물 표시이거나 다른 나라에서 18세 이상) 도 성인
    static func isAdult(_ rating: String?) -> Bool {
        guard let rating else { return false }
        if rating == "ADULT" { return true }
        if ["US:R", "US:NC-17", "US:TV-MA"].contains(rating) { return true }
        guard rating.hasPrefix("KR:") else { return false }
        let value = rating.dropFirst(3)
        return value.hasPrefix("18") || value.hasPrefix("19") || value.contains("청소년") || value.contains("제한") || value.hasPrefix("Restricted")
    }

    /// 나라 상관없이 18세 이상 등급인지 (18, R 18+, X18+, R18, NC-17, TV-MA …. 서버 isAdultCertification 과 같은 규칙)
    nonisolated static func isAdultCertification(_ value: String) -> Bool {
        let value = value.trimmingCharacters(in: .whitespaces).uppercased()
        if ["NC-17", "TV-MA", "X", "XXX"].contains(value) { return true }
        guard let match = value.wholeMatch(of: /(?:R|X)?\s*-?\s*(\d{2})\+?/) else { return false }
        return (Int(match.1) ?? 0) >= 18
    }

    /// isAdult 를 SQL 로 (column 은 등급 칸)
    private static func adultCondition(_ column: String) -> String {
        """
        (\(column) IN ('US:R', 'US:NC-17', 'US:TV-MA', 'ADULT') OR \(column) LIKE 'KR:18%' OR \(column) LIKE 'KR:19%'
            OR \(column) LIKE 'KR:%청소년%' OR \(column) LIKE 'KR:%제한%' OR \(column) LIKE 'KR:Restricted%')
        """
    }

    /// 화면에 보일 등급: 한국은 "전체·12세·15세·19세·제한상영", 미국은 그대로 (R, PG-13, TV-MA …)
    static func ratingLabel(_ rating: String?) -> String? {
        if rating == "ADULT" { return "성인" }
        guard let rating, let colon = rating.firstIndex(of: ":") else { return nil }
        let country = rating[..<colon], value = String(rating[rating.index(after: colon)...])
        guard country == "KR" else { return value }
        // "12", "12세 이상 관람가" → 12세, 18·청소년관람불가 → 19세 (우리나라 표기)
        let number = Int(value.prefix { $0.isNumber })
        if value.uppercased() == "ALL" || value.contains("전체") { return "전체" }
        if value.hasPrefix("Restricted") || value.contains("제한") { return "제한상영" }
        if value.contains("청소년") || number == 18 || number == 19 { return "19세" }
        return number.map { "\($0)세" } ?? value
    }

    /// 보이는 작품의 파일·구입작: 성인 등급 숨기기를 켰으면 성인 등급 작품의 것을 뺀 entries (모든 목록·선반·검색·인물이 이것을 읽는다)
    private static var visibleEntries: String {
        guard AdultFilter.shared.isOn else { return "entries" }
        return "(SELECT e.* FROM entries e JOIN items h ON h.key = e.item_key WHERE NOT \(adultCondition("COALESCE(h.rating, '')")))"
    }

    /// 영상 키("#해시|크기")의 파일이 숨긴 작품의 것인지 (이어보기·재생목록)
    static func isHidden(fileKey key: String) -> Bool {
        guard AdultFilter.shared.isOn, let found = file(forKey: key), let itemKey = found.file.itemKey,
              let row = try? database.first("SELECT rating FROM items WHERE key = ?", [.text(itemKey)]) else { return false }
        return isAdult(row.string("rating"))
    }

    /// 매칭된 파일(또는 구입작)이 있는 작품 (작품마다 라이브러리 하나)
    private static var matchedItems: String { """
        SELECT i.*, MIN(f.library_id) AS library_id, SUM(1 - f.purchase) AS files, MAX(f.purchase) AS purchased
        FROM items i JOIN \(visibleEntries) f ON f.item_key = i.key
        """ }

    private static func summaries(_ rows: [SQLiteRow]) -> [ItemSummary] {
        rows.compactMap { row in
            guard let key = row.string("key"), let title = row.string("title") else { return nil }
            return ItemSummary(key: key, libraryID: row.string("library_id") ?? "", type: row.string("type") ?? "MOVIE",
                               title: title, titleOrigin: row.string("title_origin"), year: row.int("year"),
                               poster: row.string("poster"), collectionName: row.string("collection_name"), files: row.int("files") ?? 0,
                               appleTV: row.int("purchased") == 1, added: row.date("added"), backdrop: row.string("backdrop"))
        }
    }

    /// 최근 라이브러리에 들어온 작품 (작품마다 가장 최근 파일 기준)
    static func recentItems(limit: Int = 20, libraries: [String]) -> [ItemSummary] {
        guard !libraries.isEmpty else { return [] }
        return summaries((try? database.query(
            """
            SELECT i.*, MIN(f.library_id) AS library_id, SUM(1 - f.purchase) AS files, MAX(f.purchase) AS purchased,
                MAX(f.added_at) AS added
            FROM items i JOIN \(visibleEntries) f ON f.item_key = i.key
            WHERE f.library_id IN (\(placeholders(libraries.count)))
            GROUP BY i.key HAVING added IS NOT NULL ORDER BY added DESC LIMIT ?
            """, libraries.map { .text($0) } + [.int(Int64(limit))])) ?? [])
    }

    /// 작품들이 속한 장르 (홈의 "최근 추가된 항목의 장르": 1.0 의 최근 영화가 든 컬렉션처럼).
    /// 많이 든 장르부터, 카드 그림은 그 작품들의 포스터, 편 수는 라이브러리 전체에서 그 장르의 작품 수.
    /// 순서는 최근순으로 바뀜: 그 장르 작품이 가장 늦게 들어온 장르부터 (방금 들어온 작품의 장르가 맨 앞. 적게 든 장르가 끝으로 밀리지 않게).
    static func genreCards(of items: [ItemSummary], limit: Int = 20) -> [GenreEntry] {
        guard !items.isEmpty else { return [] }
        let rows = (try? database.query("SELECT item_key, name FROM genres WHERE item_key IN (\(placeholders(items.count)))",
                                        items.map { .text($0.key) })) ?? []
        var names: [String: [String]] = [:]
        for row in rows {
            if let key = row.string("item_key"), let name = row.string("name") { names[key, default: []].append(name) }
        }
        var order: [String] = []
        var posters: [String: [String]] = [:]
        var hits: [String: Int] = [:]
        for item in items {
            for name in names[item.key] ?? [] {
                if hits[name] == nil { order.append(name) }
                hits[name, default: 0] += 1
                if let poster = item.poster { posters[name, default: []].append(poster) }
            }
        }
        let totals = Dictionary(genres().map { ($0.name, $0.count) }, uniquingKeysWith: { first, _ in first })
        // items 는 최근 추가순이라 order(처음 나온 차례)가 곧 최근순
        let shown = Array(order.prefix(limit))
        // 카드끼리 같은 포스터가 겹치지 않게. 최근 작품 포스터를 먼저 쓰고, 모자라면 그 장르의 다른 작품으로 채운다
        // (최근 작품 20편만으로는 장르 카드마다 같은 포스터가 돌아가며 나왔다)
        let picked = distinctPosters(shown.map { name in
            var seen = Set<String>()
            return ((posters[name] ?? []) + genrePosterCandidates(name)).filter { seen.insert($0).inserted }
        })
        return shown.indices.map { GenreEntry(name: shown[$0], count: totals[shown[$0]] ?? hits[shown[$0]]!, posters: picked[$0]) }
    }

    private static func placeholders(_ count: Int) -> String {
        Array(repeating: "?", count: count).joined(separator: ", ")
    }

    /// 끝까지 본 회차의 다음 회차 (같은 작품, 라이브러리 순서로. 시즌을 넘어간다)
    static func nextEpisode(afterKey key: String) -> (library: LibraryRecord, file: FileEntry, item: ItemDetail, episode: EpisodeEntry?)? {
        guard let found = file(forKey: key), let itemKey = found.file.itemKey, found.file.episode != nil,
              let item = item(itemKey), item.isSeries else { return nil }
        let ordered = files(ofItem: itemKey, in: found.library.id).filter { $0.episode != nil }.sorted(by: episodeOrder)
        guard let index = ordered.firstIndex(where: { $0.path == found.file.path }), index + 1 < ordered.count else { return nil }
        let next = ordered[index + 1]
        let episode = episodes(of: itemKey).first { $0.season == next.season && $0.episode == next.episode }
        return (found.library, next, item, episode)
    }

    /// 회차 순서: 시즌 (스페셜 0 은 맨 뒤) → 회차
    static func episodeOrder(_ a: FileEntry, _ b: FileEntry) -> Bool {
        let seasonA = a.season == 0 ? Int.max : (a.season ?? 1), seasonB = b.season == 0 ? Int.max : (b.season ?? 1)
        if seasonA != seasonB { return seasonA < seasonB }
        return (a.episode ?? 0) < (b.episode ?? 0)
    }

    /// 영상 키("#해시|크기")의 작품·회차 (이어보기 카드)
    static func itemInfo(forKey key: String) -> (item: ItemDetail, file: FileEntry, episode: EpisodeEntry?)? {
        guard let found = file(forKey: key), let itemKey = found.file.itemKey, let item = item(itemKey) else { return nil }
        let episode = episodes(of: itemKey).first { $0.season == found.file.season && $0.episode == found.file.episode }
        return (item, found.file, episode)
    }

    static func genres() -> [GenreEntry] {
        let rows = (try? database.query(
            """
            SELECT g.name, COUNT(DISTINCT g.item_key) AS n, MAX(f.added_at) AS added FROM genres g
            JOIN \(visibleEntries) f ON f.item_key = g.item_key
            GROUP BY g.name ORDER BY n DESC, g.name
            """
        )) ?? []
        // 카드 그림 후보: 그 장르를 잘 나타내는 작품 먼저 (장르가 적게 붙은 작품일수록 그 장르다운 작품),
        // 같으면 최근 작품. 카드끼리 같은 포스터가 겹치지 않게 distinctPosters 로 나눠 고른다.
        let candidates = rows.map { genrePosterCandidates($0.string("name") ?? "") }
        let posters = distinctPosters(candidates)
        return rows.indices.compactMap { index in
            guard let name = rows[index].string("name") else { return nil }
            return GenreEntry(name: name, count: rows[index].int("n") ?? 0, posters: posters[index], added: rows[index].date("added"))
        }
    }

    /// 장르 카드 그림 후보 (그 장르다운 작품 먼저). 같은 컬렉션(해리 포터 1~7 등)은 한 편만.
    static func genrePosterCandidates(_ name: String) -> [String] {
        let rows = (try? database.query(
            """
            SELECT i.poster, i.collection_id FROM genres g JOIN items i ON i.key = g.item_key
            WHERE g.name = ? AND i.poster IS NOT NULL AND g.item_key IN (SELECT item_key FROM \(visibleEntries))
            ORDER BY (SELECT COUNT(*) FROM genres g2 WHERE g2.item_key = g.item_key), i.year DESC LIMIT 80
            """, [.text(name)])) ?? []
        var collections = Set<String>()
        return rows.compactMap { row in
            if let collection = row.string("collection_id") {
                guard collections.insert(collection).inserted else { return nil }
            }
            return row.string("poster")
        }
        .prefix(40).map { $0 }
    }

    /// 묶음 카드마다 그림 넷을 고른다: 다른 카드에 이미 쓴 포스터는 되도록 피한다.
    /// 후보가 적은 묶음부터 고르고 (고를 게 적은 쪽이 먼저 가져가야 덜 겹친다), 모자라면 겹치더라도 채운다.
    static func distinctPosters(_ candidates: [[String]], count: Int = 4) -> [[String]] {
        var used = Set<String>()
        var result = Array(repeating: [String](), count: candidates.count)
        for index in candidates.indices.sorted(by: { candidates[$0].count < candidates[$1].count }) {
            var picked = candidates[index].filter { !used.contains($0) }.prefix(count).map { $0 }
            if picked.count < count {
                picked += candidates[index].filter { !picked.contains($0) }.prefix(count - picked.count)
            }
            used.formUnion(picked)
            result[index] = picked
        }
        return result
    }

    static func items(genre: String) -> [ItemSummary] {
        summaries((try? database.query(matchedItems + " JOIN genres g ON g.item_key = i.key WHERE g.name = ? GROUP BY i.key", [.text(genre)])) ?? [])
            .sorted { KoreanIndex.precedes($0.title, $1.title) }
    }

    static func collections() -> [CollectionEntry] {
        let rows = (try? database.query(
            """
            SELECT i.collection_id, i.collection_name, i.poster, MAX(f.added_at) AS added
            FROM items i JOIN \(visibleEntries) f ON f.item_key = i.key
            WHERE i.collection_id IS NOT NULL GROUP BY i.key ORDER BY i.year
            """
        )) ?? []
        var groups: [String: (name: String, posters: [String], count: Int, added: Date?)] = [:]
        var order: [String] = []
        for row in rows {
            guard let id = row.string("collection_id") else { continue }
            if groups[id] == nil { order.append(id); groups[id] = (row.string("collection_name") ?? "", [], 0, nil) }
            groups[id]!.count += 1
            if let poster = row.string("poster") { groups[id]!.posters.append(poster) }
            if let added = row.date("added"), added > groups[id]!.added ?? .distantPast { groups[id]!.added = added }
        }
        return order.compactMap { id in
            guard let group = groups[id] else { return nil }
            return CollectionEntry(id: id, name: group.name, count: group.count, posters: Array(group.posters.prefix(4)), added: group.added)
        }
        .sorted { KoreanIndex.precedes($0.name, $1.name) }
    }

    static func items(collection id: String) -> [ItemSummary] {
        summaries((try? database.query(matchedItems + " WHERE i.collection_id = ? GROUP BY i.key ORDER BY i.year", [.text(id)])) ?? [])
    }

    // MARK: - 검색

    /// 검색할 것: 라이브러리에 든 작품 모두와 그 작품의 인물 (검색 화면이 한 번 읽어 두고 글자마다 거른다)
    static func searchCatalog() -> (items: [ItemSummary], people: [PersonSummary]) {
        let items = summaries((try? database.query(matchedItems + " GROUP BY i.key")) ?? [])
            .sorted { KoreanIndex.precedes($0.title, $1.title) }
        return (items, allPeople())
    }

    /// 라이브러리 작품에 나온·만든 모든 인물 (작품이 많은 사람부터)
    static func allPeople() -> [PersonSummary] {
        ((try? database.query(
            """
            SELECT COALESCE(p.source || ':' || p.source_id, p.key) AS global_key, MIN(p.name) AS name, MAX(p.photo) AS photo,
                MAX(p.name_origin) AS name_origin, COUNT(DISTINCT c.item_key) AS works
            FROM people p JOIN credits c ON c.person_key = p.key
            WHERE c.item_key IN (SELECT item_key FROM \(visibleEntries))
            GROUP BY global_key ORDER BY works DESC
            """)) ?? []).compactMap { row -> PersonSummary? in
            guard let key = row.string("global_key"), let name = row.string("name") else { return nil }
            return PersonSummary(key: key, name: name, photo: row.string("photo"), works: row.int("works") ?? 0,
                                 nameOrigin: origin(row.string("name_origin"), name))
        }
    }

    /// 인물들의 원어 이름 (정보출처:번호 → 원어 이름, 이름과 같은 사람은 빠진다)
    static func originNames(_ keys: [String]) -> [String: String] {
        guard !keys.isEmpty else { return [:] }
        let rows = (try? database.query(
            """
            SELECT COALESCE(source || ':' || source_id, key) AS global_key, MIN(name) AS name, MAX(name_origin) AS name_origin
            FROM people WHERE COALESCE(source || ':' || source_id, key) IN (\(placeholders(keys.count))) GROUP BY global_key
            """, keys.map { .text($0) })) ?? []
        var result: [String: String] = [:]
        for row in rows {
            if let key = row.string("global_key"), let name = row.string("name"), let origin = origin(row.string("name_origin"), name) {
                result[key] = origin
            }
        }
        return result
    }

    /// 원어 이름: 비었거나 이름과 같으면 nil
    private static func origin(_ origin: String?, _ name: String) -> String? {
        guard let origin = origin?.trimmingCharacters(in: .whitespaces), !origin.isEmpty, origin != name else { return nil }
        return origin
    }

    /// TMDB 번호의 작품이 라이브러리에 있으면 그 작품 (검색의 "다른 곳에서 찾기" 결과에 "보관함에 있음")
    static func item(tmdbID: Int, isSeries: Bool) -> ItemSummary? {
        summaries((try? database.query(
            matchedItems + " WHERE i.source = 'tmdb' AND i.source_id = ? AND i.type = ? GROUP BY i.key",
            [.text(String(tmdbID)), .text(isSeries ? "SERIES" : "MOVIE")])) ?? []).first
    }

    /// 인물 (정보출처:번호, 없으면 에이전트 인물 키)
    static func person(_ key: String) -> PersonSummary? {
        let rows = (try? database.query(
            """
            SELECT name, photo, name_origin FROM people WHERE COALESCE(source || ':' || source_id, key) = ? LIMIT 1
            """, [.text(key)])) ?? []
        guard let row = rows.first, let name = row.string("name") else { return nil }
        return PersonSummary(key: key, name: name, photo: row.string("photo"), works: works(of: key).count,
                             nameOrigin: origin(row.string("name_origin"), name))
    }

    /// 인물이 나온·만든 작품 중 라이브러리에 있는 것
    /// 인물마다 그 사람 작품 중 가장 최근 라이브러리에 들어온 때 (둘러보기 인물의 최근 추가순)
    static func latestAdded(people keys: [String]) -> [String: Date] {
        guard !keys.isEmpty else { return [:] }
        let rows = (try? database.query(
            """
            SELECT COALESCE(p.source || ':' || p.source_id, p.key) AS global_key, MAX(f.added_at) AS added
            FROM people p JOIN credits c ON c.person_key = p.key JOIN \(visibleEntries) f ON f.item_key = c.item_key
            WHERE COALESCE(p.source || ':' || p.source_id, p.key) IN (\(placeholders(keys.count))) GROUP BY global_key
            """, keys.map { .text($0) })) ?? []
        var result: [String: Date] = [:]
        for row in rows {
            if let key = row.string("global_key"), let added = row.date("added") { result[key] = added }
        }
        return result
    }

    /// 영상 키("#해시|크기")들 중 가장 최근 라이브러리에 들어온 때 (둘러보기 재생목록의 최근 추가순). 라이브러리에 없는 영상은 셈하지 않는다
    static func latestAdded(fileKeys keys: [String]) -> Date? {
        keys.compactMap { key -> Date? in
            guard key.hasPrefix("#"), let bar = key.firstIndex(of: "|"), let size = Int64(key[key.index(after: bar)...]) else { return nil }
            let hash = String(key[key.index(after: key.startIndex)..<bar])
            return try? database.first("SELECT MAX(added_at) AS added FROM files WHERE hash = ? AND size = ?",
                                       [.text(hash), .int(size)])?.date("added")
        }
        .max()
    }

    static func works(of personKey: String) -> [ItemSummary] {
        summaries((try? database.query(
            matchedItems + """
             JOIN credits c ON c.item_key = i.key JOIN people p ON p.key = c.person_key
            WHERE COALESCE(p.source || ':' || p.source_id, p.key) = ? GROUP BY i.key ORDER BY i.year DESC
            """, [.text(personKey)])) ?? [])
    }

    static func item(_ key: String) -> ItemDetail? {
        guard let row = try? database.first("SELECT * FROM items WHERE key = ?", [.text(key)]),
              let agentID = row.string("agent_id"), let id = row.string("id"), let title = row.string("title") else { return nil }
        let genres = ((try? database.query("SELECT name FROM genres WHERE item_key = ?", [.text(key)])) ?? []).compactMap { $0.string("name") }
        let credits = ((try? database.query(
            """
            SELECT c.person_key, c.role, c.character, p.name, p.name_origin, p.photo, COALESCE(p.source || ':' || p.source_id, p.key) AS global_key
            FROM credits c JOIN people p ON p.key = c.person_key
            WHERE c.item_key = ? ORDER BY CASE c.role WHEN 'DIRECTOR' THEN 0 WHEN 'ACTOR' THEN 1 ELSE 2 END, c.sort
            """,
            [.text(key)]
        )) ?? []).compactMap { row -> Credit? in
            guard let person = row.string("person_key"), let name = row.string("name") else { return nil }
            return Credit(personKey: person, globalKey: row.string("global_key") ?? person, name: name,
                          nameOrigin: origin(row.string("name_origin"), name), photo: row.string("photo"),
                          role: row.string("role") ?? "ACTOR", character: row.string("character"))
        }
        return ItemDetail(key: key, agentID: agentID, id: id, type: row.string("type") ?? "MOVIE", title: title,
                          titleOrigin: row.string("title_origin"), year: row.int("year"), date: row.string("date"),
                          summary: row.string("summary"), poster: row.string("poster"), backdrop: row.string("backdrop"),
                          collectionName: row.string("collection_name"), collectionID: row.string("collection_id"),
                          rating: row.string("rating"), genres: genres, credits: credits)
    }

    static func files(in libraryID: String, status: String? = nil) -> [FileEntry] {
        var sql = "SELECT * FROM files WHERE library_id = ?"
        var values: [SQLiteValue] = [.text(libraryID)]
        if let status {
            sql += " AND status = ?"
            values.append(.text(status))
        }
        return ((try? database.query(sql + " ORDER BY path", values)) ?? []).compactMap(fileEntry)
    }

    static func files(ofItem key: String, in libraryID: String) -> [FileEntry] {
        ((try? database.query("SELECT * FROM files WHERE library_id = ? AND item_key = ? ORDER BY season, episode, path",
                              [.text(libraryID), .text(key)])) ?? []).compactMap(fileEntry)
    }

    static func files(withHash hash: String, size: Int64) -> [FileEntry] {
        ((try? database.query("SELECT * FROM files WHERE hash = ? AND size = ?", [.text(hash), .int(size)])) ?? []).compactMap(fileEntry)
    }

    /// 재생할 영상 (해시를 붙여 이어보기를 같이 쓴다)
    static func videoFile(_ file: FileEntry, in library: LibraryRecord, title: String?) -> VideoFile {
        var video = VideoFile(url: LibraryScanner.url(of: file, in: library), size: file.size, modifiedAt: .distantPast,
                              serverID: (LibraryStore.shared.library(library.id) ?? library).folder(file.folderID)?.serverID, displayTitle: title)
        video.hash = file.hash
        return video
    }

    /// 작품에 이은 Apple TV 구입작의 상점 번호
    static func purchases(ofItem key: String, in libraryID: String) -> [Int] {
        ((try? database.query("SELECT store_id FROM purchases WHERE library_id = ? AND item_key = ?",
                              [.text(libraryID), .text(key)])) ?? []).compactMap { $0.int("store_id") }
    }

    static func episodes(of key: String) -> [EpisodeEntry] {
        ((try? database.query("SELECT * FROM episodes WHERE item_key = ? ORDER BY season, episode", [.text(key)])) ?? []).compactMap { row in
            guard let season = row.int("season"), let episode = row.int("episode") else { return nil }
            return EpisodeEntry(season: season, episode: episode, title: row.string("title"), summary: row.string("summary"),
                                date: row.string("date"), still: row.string("still"))
        }
    }

    /// 저장소의 파일이 라이브러리에 들어 있으면 그 해시 (폴더 화면에서 봐도 라이브러리와 이어보기를 같이 쓰게)
    static func hashes(for files: [(url: URL, size: Int64)], serverID: UUID?) -> [URL: String] {
        guard let serverID else { return [:] }
        let folders = LibraryStore.shared.libraries.flatMap { library in library.folders.map { (library, $0) } }.filter { $0.1.serverID == serverID }
        var result: [URL: String] = [:]
        var unmatched: [(url: URL, size: Int64)] = []
        for file in files {
            let path = file.url.path(percentEncoded: false)
            if let (library, folder) = folders.first(where: { path.hasPrefix($0.1.rootURL.path(percentEncoded: false)) }) {
                let raw = LibraryScanner.relativePath(file.url, root: folder.rootURL)
                if let row = try? database.first("SELECT hash FROM files WHERE library_id = ? AND folder_id = ? AND path = ? AND size = ?",
                                                 [.text(library.id), .text(folder.id), .text(raw.precomposedStringWithCanonicalMapping), .int(file.size)]),
                   let hash = row.string("hash") {
                    result[file.url] = hash
                    continue
                }
            }
            unmatched.append(file)
        }
        // 라이브러리가 다른 접속(같은 NAS 를 WebDAV 로 등록한 라이브러리를 SMB 로 열 때 등)에 있으면 이름과 크기로 찾는다
        guard !unmatched.isEmpty else { return result }
        let rows = (try? database.query("SELECT raw_path, size, hash FROM files WHERE hash IS NOT NULL AND size IN (\(placeholders(unmatched.count)))",
                                        unmatched.map { .int($0.size) })) ?? []
        var byNameAndSize: [String: String] = [:]
        for row in rows {
            guard let raw = row.string("raw_path"), let size = row.int64("size"), let hash = row.string("hash") else { continue }
            byNameAndSize["\((raw as NSString).lastPathComponent.precomposedStringWithCanonicalMapping)|\(size)"] = hash
        }
        for file in unmatched {
            result[file.url] = byNameAndSize["\(file.url.lastPathComponent.precomposedStringWithCanonicalMapping)|\(file.size)"]
        }
        return result
    }

    /// 상태별 파일 수 (matched, unmatched, error, new …)
    static func counts(in libraryID: String) -> [String: Int] {
        let rows = (try? database.query("SELECT status, COUNT(*) AS n FROM files WHERE library_id = ? GROUP BY status",
                                        [.text(libraryID)])) ?? []
        return Dictionary(uniqueKeysWithValues: rows.compactMap { row in row.string("status").map { ($0, row.int("n") ?? 0) } })
    }

    private static func fileEntry(_ row: SQLiteRow) -> FileEntry? {
        guard let libraryID = row.string("library_id"), let path = row.string("path") else { return nil }
        return FileEntry(libraryID: libraryID, folderID: row.string("folder_id") ?? libraryID, path: path, rawPath: row.string("raw_path") ?? path, hash: row.string("hash"), size: row.int64("size") ?? 0,
                         status: row.string("status") ?? "new", message: row.string("message"), itemKey: row.string("item_key"),
                         season: row.int("season"), episode: row.int("episode"), episodeEnd: row.int("episode_end"),
                         targetFolder: row.string("target_folder"), targetName: row.string("target_name"))
    }

    // MARK: - 쓰기

    /// 에이전트가 찾은 결과를 저장한다
    static func saveMatch(_ match: AgentModels.Match, file: FileEntry, agentID: String) throws {
        try saveMatch(match, libraryID: file.libraryID, folderID: file.folderID, path: file.path, agentID: agentID)
    }

    /// 바뀜 (2026-11-07): 파일은 라이브러리 + 폴더 + 폴더 기준 경로로 찾는다
    static func saveMatch(_ match: AgentModels.Match, libraryID: String, folderID: String, path: String, agentID: String) throws {
        guard let item = match.item else { return }
        let key = agentID + ":" + item.id.value
        try database.transaction {
            try saveItem(item, key: key, agentID: agentID)
            if let episode = match.episode {
                try saveEpisode(episode, key: key)
            }
            try database.execute(
                """
                UPDATE files SET status = 'matched', message = NULL, agent_id = ?, item_key = ?, season = ?, episode = ?,
                    episode_end = ?, target_folder = ?, target_name = ?, checked_at = ?
                WHERE library_id = ? AND folder_id = ? AND path = ?
                """,
                [.text(agentID), .text(key), .of(match.episode?.season), .of(match.episode?.episode), .null,
                 .of(match.target?.folder), .of(match.target?.filename), .of(Date.now), .text(libraryID), .text(folderID), .text(path)]
            )
        }
    }

    /// 작품 (출연진·장르 포함)
    static func saveItem(_ item: AgentModels.Item, key: String, agentID: String) throws {
        try database.execute(
            """
            INSERT INTO items (key, agent_id, id, type, kind, source, source_id, title, title_origin, year, date, summary,
                poster, backdrop, collection_id, collection_name, rating, updated_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(key) DO UPDATE SET type = excluded.type, kind = excluded.kind, source = excluded.source,
                source_id = excluded.source_id, title = excluded.title, title_origin = excluded.title_origin,
                year = excluded.year, date = excluded.date, summary = excluded.summary, poster = excluded.poster,
                backdrop = excluded.backdrop, collection_id = excluded.collection_id,
                collection_name = excluded.collection_name, rating = COALESCE(excluded.rating, items.rating),
                updated_at = excluded.updated_at
            """,
            [.text(key), .text(agentID), .text(item.id.value), .text(item.type), .of(item.kind), .of(item.source),
             .of(item.sourceId?.value), .text(item.title), .of(item.titleOrigin), .of(item.year), .of(item.date),
             .of(item.summary), .of(item.poster), .of(item.backdrop), .of(item.collection?.id.value),
             .of(item.collection?.name), .of(item.rating), .of(Date.now)]
        )
        if let genres = item.genres {
            try database.execute("DELETE FROM genres WHERE item_key = ?", [.text(key)])
            for genre in Set(genres.flatMap { genreNames[$0] ?? [$0] }) {
                try database.execute("INSERT INTO genres (item_key, name) VALUES (?, ?)", [.text(key), .text(genre)])
            }
        }
        if let authors = item.authors {
            try database.execute("DELETE FROM credits WHERE item_key = ?", [.text(key)])
            for (index, author) in authors.enumerated() {
                let person = agentID + ":" + author.id.value
                try database.execute(
                    """
                    INSERT INTO people (key, agent_id, id, source, source_id, name, name_origin, photo) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(key) DO UPDATE SET name = excluded.name, name_origin = excluded.name_origin,
                        photo = COALESCE(excluded.photo, people.photo), source = excluded.source, source_id = excluded.source_id
                    """,
                    [.text(person), .text(agentID), .text(author.id.value), .of(author.source), .of(author.sourceId?.value),
                     .text(author.name), .of(author.nameOrigin), .of(author.photo)]
                )
                try database.execute(
                    "INSERT OR IGNORE INTO credits (item_key, person_key, role, character, sort) VALUES (?, ?, ?, ?, ?)",
                    [.text(key), .text(person), .text(author.role ?? "ACTOR"), .of(author.character), .int(Int64(index))]
                )
            }
        }
        for episode in item.episodes ?? [] {
            try saveEpisode(episode, key: key)
        }
    }

    /// TMDB 의 TV 전용 장르는 한국어 번역이 없어 영어로 온다: "&" 로 묶인 것은 나눠 영화 장르 이름으로
    /// (우리 서버 에이전트도 같은 표로 바꿔 주지만, 앱 안 TMDB 에이전트·예전 서버를 위해 여기서도)
    static let genreNames: [String: [String]] = [
        "Action & Adventure": ["액션", "모험"],
        "Sci-Fi & Fantasy": ["SF", "판타지"],
        "War & Politics": ["전쟁", "정치"],
        "Kids": ["키즈"],
        "News": ["뉴스"],
        "Reality": ["리얼리티"],
        "Soap": ["연속극"],
        "Talk": ["토크쇼"],
    ]

    static func saveEpisode(_ episode: AgentModels.Episode, key: String) throws {
        try database.execute(
            """
            INSERT INTO episodes (item_key, season, episode, title, summary, date, still) VALUES (?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(item_key, season, episode) DO UPDATE SET title = excluded.title, summary = excluded.summary,
                date = excluded.date, still = excluded.still
            """,
            [.text(key), .int(Int64(episode.season)), .int(Int64(episode.episode)), .of(episode.title), .of(episode.summary),
             .of(episode.date), .of(episode.still)]
        )
    }

    /// 에이전트가 찾은 Apple TV 구입작을 저장한다
    static func savePurchase(_ item: AgentModels.Item, libraryID: String, storeID: Int, agentID: String) throws {
        let key = agentID + ":" + item.id.value
        try database.transaction {
            try saveItem(item, key: key, agentID: agentID)
            try database.execute("UPDATE purchases SET status = 'matched', message = NULL, agent_id = ?, item_key = ? WHERE library_id = ? AND store_id = ?",
                                 [.text(agentID), .text(key), .text(libraryID), .int(Int64(storeID))])
        }
    }

    /// 에이전트가 찾지 못한 구입작: 상점 정보만으로 작품을 만들어 라이브러리에는 보이게 한다 (키 "appletv:상점번호")
    static func savePurchaseUnmatched(_ movie: AppleTVLibrary.Movie, poster: URL?, libraryID: String, status: String, message: String?) {
        let key = "appletv:\(movie.storeID)"
        try? database.transaction {
            try database.execute(
                """
                INSERT INTO items (key, agent_id, id, type, title, year, poster, updated_at) VALUES (?, 'appletv', ?, 'MOVIE', ?, ?, ?, ?)
                ON CONFLICT(key) DO UPDATE SET title = excluded.title, year = excluded.year, poster = COALESCE(excluded.poster, items.poster),
                    updated_at = excluded.updated_at
                """,
                [.text(key), .text(String(movie.storeID)), .text(movie.title), .of(movie.year), .of(poster?.absoluteString), .of(Date.now)]
            )
            try database.execute("UPDATE purchases SET status = ?, message = ?, agent_id = NULL, item_key = ? WHERE library_id = ? AND store_id = ?",
                                 [.text(status), .of(message), .text(key), .text(libraryID), .int(Int64(movie.storeID))])
        }
    }

    static func setStatus(_ status: String, message: String?, libraryID: String, folderID: String, path: String, agentID: String? = nil) {
        try? database.execute(
            "UPDATE files SET status = ?, message = ?, agent_id = COALESCE(?, agent_id), checked_at = ? WHERE library_id = ? AND folder_id = ? AND path = ?",
            [.text(status), .of(message), .of(agentID), .of(Date.now), .text(libraryID), .text(folderID), .text(path)]
        )
    }
}
