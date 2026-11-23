import Foundation

/// 라이브러리가 작품을 물어보는 곳 (에이전트 규약의 요청들). 사용자 정의 에이전트(웹 서버)와 앱 안의 TMDB 에이전트가 같은 모양으로 답한다.
protocol MetadataAgent {
    func match(kind: String, hash: String, size: Int64, path: String, duration: Double?,
               choice: String?, season: Int?, episode: Int?, episodeEnd: Int?) async throws -> AgentModels.Match
    func search(kind: String, query: String, year: Int?) async throws -> [AgentModels.Candidate]
    /// 작품 상세. id 는 작품 id 또는 /search 후보 id (파일 없이 작품만 찾을 때. kind 는 그때의 종류)
    func item(_ id: String, kind: String?) async throws -> AgentModels.Item
}

extension MetadataAgent {
    func item(_ id: String) async throws -> AgentModels.Item {
        try await item(id, kind: nil)
    }

    func match(kind: String, hash: String, size: Int64, path: String, duration: Double?) async throws -> AgentModels.Match {
        try await match(kind: kind, hash: hash, size: size, path: path, duration: duration,
                        choice: nil, season: nil, episode: nil, episodeEnd: nil)
    }

    func match(kind: String, hash: String, size: Int64, path: String, duration: Double?,
               choice: String?, season: Int?, episode: Int?) async throws -> AgentModels.Match {
        try await match(kind: kind, hash: hash, size: size, path: path, duration: duration,
                        choice: choice, season: season, episode: episode, episodeEnd: nil)
    }
}

extension AgentClient: MetadataAgent {}

/// 앱 안의 TMDB 에이전트 (서버 없이 TMDB 를 직접 부른다). 종류는 movie(영화)·tv(TV 시리즈).
/// reader 서버의 메타정보 핸들러와 같은 규칙: 파일명 해석, 제목·연도가 확실할 때만 자동 매칭, 한국어 제목(없으면 영어),
/// 컬렉션 묶음, 옮길 위치(제목 (연도)/…, 시리즈명 (연도)/시즌 1/시리즈명 - S01E01 (회차제목)).
/// 서버처럼 해시를 기억하지 않으므로, 앱은 Library.sqlite 에 받은 결과를 둔다.
struct TMDBAgent: MetadataAgent {
    let baseURL: String
    let key: String

    enum TMDBError: LocalizedError {
        case noKey
        case response(Int)

        var errorDescription: String? {
            switch self {
            case .noKey: "TMDB API 키가 없습니다."
            case .response(let status): "TMDB 가 응답하지 않습니다. (HTTP \(status))"
            }
        }
    }

    private static let image = "https://image.tmdb.org/t/p/"

    // MARK: - 규약

    func match(kind: String, hash: String, size: Int64, path: String, duration: Double?,
               choice: String?, season: Int?, episode: Int?, episodeEnd: Int?) async throws -> AgentModels.Match {
        // 바뀜 (2026-11-07): 종류 auto (서버와 같게) — 파일 이름에 회차가 있으면 TV 시리즈, 없으면 영화
        var parsed = FileNameParser.parse(path, series: kind == "tv")
        if kind == "auto", parsed.episode != nil || episode != nil { parsed = FileNameParser.parse(path, series: true) }
        let autoSeries = kind == "auto" && (parsed.episode != nil || episode != nil)
        if let season { parsed.season = season }
        if let episode { parsed.episode = episode; parsed.episodeEnd = episodeEnd }

        let isSeries: Bool
        let tmdbID: Int
        if let choice, let picked = Self.parseChoice(choice) {
            (isSeries, tmdbID) = picked
        } else {
            isSeries = kind == "tv" || autoSeries
            let candidates = try await searchRaw(isSeries: isSeries, query: parsed.title, year: parsed.year)
            guard let picked = Self.pick(candidates, title: parsed.title, year: parsed.year) else {
                return AgentModels.Match(matched: false, item: nil, episode: nil, target: nil, relocations: [],
                                         reason: "NOT_FOUND", candidates: Array(candidates.prefix(10)))
            }
            tmdbID = Int(picked.id.value.split(separator: ":").last ?? "") ?? 0
        }

        // 바뀜 (2026-11-07): 시리즈인데 시즌·회차를 모르면 매칭하지 않는다 (서버와 같게. 매칭 안 됨 목록에서 회차를 넣어 다시)
        if isSeries, parsed.season == nil || parsed.episode == nil {
            return AgentModels.Match(matched: false, item: nil, episode: nil, target: nil, relocations: [],
                                     reason: "NO_EPISODE", candidates: [])
        }
        let item = try await detail(isSeries: isSeries, id: tmdbID, withEpisodes: false)
        var episodeInfo: AgentModels.Episode?
        var maxEpisode = 0
        if isSeries, let season = parsed.season, let number = parsed.episode {
            let list = (try? await seasonEpisodes(id: tmdbID, season: season)) ?? []
            episodeInfo = list.first { $0.episode == number }
            maxEpisode = list.map(\.episode).max() ?? 0
        }
        let target = isSeries
            ? parsed.season.flatMap { season in parsed.episode.map { Self.seriesTarget(item, season: season, episode: $0, end: parsed.episodeEnd, title: episodeInfo?.title, maxEpisode: maxEpisode) } }
            : Self.movieTarget(item)
        return AgentModels.Match(matched: true, item: item, episode: episodeInfo ?? parsed.season.flatMap { season in
            parsed.episode.map { AgentModels.Episode(season: season, episode: $0, title: nil, summary: nil, date: nil, still: nil) }
        }, target: target, relocations: [], reason: nil, candidates: nil)
    }

    func search(kind: String, query: String, year: Int?) async throws -> [AgentModels.Candidate] {
        // auto 는 TV 시리즈와 영화를 모두 찾는다
        var results: [AgentModels.Candidate] = []
        for isSeries in kind == "auto" ? [true, false] : [kind == "tv"] {
            var found = try await searchRaw(isSeries: isSeries, query: query, year: year)
            if found.isEmpty, year != nil { found = try await searchRaw(isSeries: isSeries, query: query, year: nil) }
            results += found
        }
        return results
    }

    func item(_ id: String, kind: String?) async throws -> AgentModels.Item {
        guard let (isSeries, tmdbID) = Self.parseChoice(id) else { throw TMDBError.response(404) }
        return try await detail(isSeries: isSeries, id: tmdbID, withEpisodes: true)
    }

    /// 키가 맞는지 확인 (에이전트를 추가할 때)
    func check() async throws {
        let _: Configuration = try await get("/configuration", [:])
    }

    // MARK: - TMDB

    private struct Configuration: Decodable {}

    private struct SearchResult: Decodable {
        struct Result: Decodable {
            let id: Int
            let title: String?
            let name: String?
            let originalTitle: String?
            let originalName: String?
            let releaseDate: String?
            let firstAirDate: String?
            let overview: String?
            let posterPath: String?
        }
        let results: [Result]
    }

    private struct Detail: Decodable {
        struct Genre: Decodable { let name: String }
        struct Collection: Decodable { let id: Int; let name: String }
        struct Person: Decodable {
            let id: Int
            let name: String
            let originalName: String?
            let profilePath: String?
            let character: String?
            let job: String?
        }
        struct Credits: Decodable {
            let cast: [Person]?
            let crew: [Person]?
        }
        struct Season: Decodable { let seasonNumber: Int }
        /// 나라별 관람등급 (영화 release_dates, 시리즈 content_ratings)
        struct Ratings: Decodable {
            struct Country: Decodable {
                struct Release: Decodable { let certification: String? }
                /// iso_3166_1 (디코더가 iso31661 로 바꾼다)
                let iso31661: String
                let rating: String?
                let releaseDates: [Release]?
            }
            let results: [Country]?
        }

        let id: Int
        let title: String?
        let name: String?
        let originalTitle: String?
        let originalName: String?
        let originalLanguage: String?
        let releaseDate: String?
        let firstAirDate: String?
        let overview: String?
        let posterPath: String?
        let backdropPath: String?
        let genres: [Genre]?
        let belongsToCollection: Collection?
        let createdBy: [Person]?
        let credits: Credits?
        let seasons: [Season]?
        let releaseDates: Ratings?
        let contentRatings: Ratings?
        /// TMDB 성인물 표시
        let adult: Bool?

        /// 한국 등급을 먼저, 없으면 미국 등급 ("KR:15"). 둘 다 없으면 "" (우리 서버 에이전트와 같은 규칙)
        /// 바뀜 (2026-11-06): 둘 다 없으면 성인물 표시·다른 나라 18세 이상이면 "ADULT", 아니면 "NR"
        var rating: String {
            let results = (releaseDates ?? contentRatings)?.results ?? []
            func certifications(_ country: Ratings.Country) -> [String] {
                ([country.rating] + (country.releaseDates ?? []).map(\.certification))
                    .compactMap { $0?.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            }
            for code in ["KR", "US"] {
                if let country = results.first(where: { $0.iso31661 == code }), let first = certifications(country).first {
                    return code + ":" + first
                }
            }
            if adult == true || results.contains(where: { certifications($0).contains(where: LibraryData.isAdultCertification) }) {
                return "ADULT"
            }
            return "NR"
        }
    }

    private struct SeasonDetail: Decodable {
        struct Episode: Decodable {
            let episodeNumber: Int
            let name: String?
            let overview: String?
            let airDate: String?
            let stillPath: String?
        }
        let episodes: [Episode]?
    }

    private func searchRaw(isSeries: Bool, query: String, year: Int?) async throws -> [AgentModels.Candidate] {
        guard !query.isEmpty else { return [] }
        // 성인물 표시(adult)가 붙은 작품도 찾는다 (사용자 결정 2026-11-06)
        var params = ["query": query, "include_adult": "true"]
        if let year { params[isSeries ? "first_air_date_year" : "year"] = String(year) }
        let result: SearchResult = try await get(isSeries ? "/search/tv" : "/search/movie", params)
        return result.results.map { found in
            let date = (isSeries ? found.firstAirDate : found.releaseDate) ?? ""
            return AgentModels.Candidate(id: FlexibleID((isSeries ? "tv:" : "movie:") + String(found.id)),
                                         type: isSeries ? "SERIES" : "MOVIE",
                                         title: (isSeries ? found.name : found.title) ?? "",
                                         titleOrigin: isSeries ? found.originalName : found.originalTitle,
                                         year: Int(date.prefix(4)), summary: found.overview,
                                         poster: found.posterPath.map { Self.image + "w342" + $0 })
        }
    }

    private func detail(isSeries: Bool, id: Int, withEpisodes: Bool) async throws -> AgentModels.Item {
        let path = (isSeries ? "/tv/" : "/movie/") + String(id)
        let data: Detail = try await get(path, ["append_to_response": "credits," + (isSeries ? "content_ratings" : "release_dates")])
        var title = (isSeries ? data.name : data.title) ?? ""
        let origin = isSeries ? data.originalName : data.originalTitle
        // 한국어 제목이 없으면 TMDB 가 원제를 주므로, 한국어·영어 작품이 아니면 영어 제목을 쓴다
        if title == origin, !["ko", "en"].contains(data.originalLanguage ?? "") {
            let english: Detail? = try? await get(path, ["language": "en-US"])
            title = (isSeries ? english?.name : english?.title) ?? title
        }
        let date = (isSeries ? data.firstAirDate : data.releaseDate).flatMap { $0.isEmpty ? nil : $0 }

        var authors: [AgentModels.Author] = []
        func author(_ person: Detail.Person, role: String, character: String?) -> AgentModels.Author {
            AgentModels.Author(id: FlexibleID(String(person.id)), source: "tmdb", sourceId: FlexibleID(String(person.id)), name: person.name,
                               nameOrigin: person.originalName, photo: person.profilePath.map { Self.image + "w185" + $0 },
                               items: nil, role: role, character: character)
        }
        for person in (data.credits?.cast ?? []).prefix(20) { authors.append(author(person, role: "ACTOR", character: person.character)) }
        if isSeries {
            for person in data.createdBy ?? [] { authors.append(author(person, role: "WRITER", character: nil)) }
        } else {
            for person in data.credits?.crew ?? [] {
                if person.job == "Director" { authors.append(author(person, role: "DIRECTOR", character: nil)) }
                if ["Screenplay", "Writer"].contains(person.job ?? "") { authors.append(author(person, role: "WRITER", character: nil)) }
            }
        }

        var episodes: [AgentModels.Episode]?
        if isSeries, withEpisodes {
            episodes = []
            for season in data.seasons ?? [] {
                episodes! += (try? await seasonEpisodes(id: id, season: season.seasonNumber)) ?? []
            }
        }

        return AgentModels.Item(id: FlexibleID((isSeries ? "tv:" : "movie:") + String(id)), type: isSeries ? "SERIES" : "MOVIE",
                                kind: isSeries ? "tv" : "movie", source: "tmdb", sourceId: FlexibleID(String(id)), title: title,
                                titleOrigin: origin, collection: Self.collection(data.belongsToCollection, title: title),
                                year: date.flatMap { Int($0.prefix(4)) }, date: date, genres: data.genres?.map(\.name),
                                summary: data.overview.flatMap { $0.isEmpty ? nil : $0 },
                                poster: data.posterPath.map { Self.image + "w500" + $0 },
                                backdrop: data.backdropPath.map { Self.image + "w1280" + $0 }, rating: data.rating,
                                authors: authors, episodes: episodes)
    }

    // 바뀜 (2026-11-06): 한국어 회차제목이 "에피소드 1" 처럼 번호뿐이면 영어(en-US) 제목을 쓰고, 영어도 번호뿐이면 비운다
    private func seasonEpisodes(id: Int, season: Int) async throws -> [AgentModels.Episode] {
        let data: SeasonDetail = try await get("/tv/\(id)/season/\(season)", [:])
        var english: [Int: String] = [:]
        if (data.episodes ?? []).contains(where: { Self.isNumberOnlyTitle($0.name) }),
           let en: SeasonDetail = try? await get("/tv/\(id)/season/\(season)", ["language": "en-US"]) {
            for episode in en.episodes ?? [] {
                if let name = episode.name, !Self.isNumberOnlyTitle(name) { english[episode.episodeNumber] = name }
            }
        }
        return (data.episodes ?? []).map { episode in
            let title = Self.isNumberOnlyTitle(episode.name) ? english[episode.episodeNumber] : episode.name
            return AgentModels.Episode(season: season, episode: episode.episodeNumber, title: title,
                                summary: episode.overview.flatMap { $0.isEmpty ? nil : $0 },
                                date: episode.airDate.flatMap { $0.isEmpty ? nil : $0 },
                                still: episode.stillPath.map { Self.image + "w300" + $0 })
        }
    }

    private func get<T: Decodable>(_ path: String, _ params: [String: String]) async throws -> T {
        guard !key.isEmpty else { throw TMDBError.noKey }
        var components = URLComponents(string: baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/ ")) + path)!
        var items = params.map { URLQueryItem(name: $0.key, value: $0.value) }
        if !params.keys.contains("language") { items.append(URLQueryItem(name: "language", value: "ko-KR")) }
        // v4 읽기 토큰(eyJ…)은 헤더로, v3 키는 주소로
        let bearer = key.hasPrefix("eyJ")
        if !bearer { items.append(URLQueryItem(name: "api_key", value: key)) }
        components.queryItems = items
        var request = URLRequest(url: components.url!, timeoutInterval: 30)
        if bearer { request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) { throw TMDBError.response(http.statusCode) }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(T.self, from: data)
    }

    // MARK: - 규칙 (reader 메타정보 핸들러와 같게)

    /// "movie:123" · "tv:456" → (시리즈인지, 번호)
    private static func parseChoice(_ choice: String) -> (Bool, Int)? {
        let parts = choice.split(separator: ":")
        guard parts.count == 2, let id = Int(parts[1]), parts[0] == "movie" || parts[0] == "tv" else { return nil }
        return (parts[0] == "tv", id)
    }

    /// 제목 열쇠가 같고 연도가 ±1 일 때만 고른다 (연도를 모르는데 같은 이름이 여럿이면 고르지 않는다)
    private static func pick(_ candidates: [AgentModels.Candidate], title: String, year: Int?) -> AgentModels.Candidate? {
        let key = FileNameParser.key(title)
        let matches = candidates.filter { candidate in
            guard key == FileNameParser.key(candidate.title) || key == FileNameParser.key(candidate.titleOrigin ?? "") else { return false }
            guard let year, let found = candidate.year else { return true }
            return abs(found - year) <= 1
        }
        return matches.count == 1 || (matches.count > 1 && year != nil) ? matches.first : nil
    }

    private static func collection(_ collection: Detail.Collection?, title: String) -> AgentModels.Collection? {
        guard let collection else { return nil }
        var name = collection.name.replacingOccurrences(of: #"\s*\([^)]*\)$"#, with: "", options: .regularExpression)
        name = name.replacingOccurrences(of: #"\s*(시리즈|컬렉션|콜렉션|모음|Collection)$"#, with: "", options: [.regularExpression, .caseInsensitive])
        let hangul = #"\p{Script=Hangul}"#
        if title.range(of: hangul, options: .regularExpression) != nil, name.range(of: hangul, options: .regularExpression) == nil { return nil }
        return AgentModels.Collection(id: FlexibleID(String(collection.id)), name: name)
    }

    private static func movieTarget(_ item: AgentModels.Item) -> AgentModels.Target {
        let name = safeName(item.title) + (item.year.map { " (\($0))" } ?? "")
        let folder = ([item.collection.map { safeName($0.name) }, name] as [String?]).compactMap { $0 }.joined(separator: "/")
        return AgentModels.Target(folder: folder, filename: name)
    }

    /// 바뀜 (2026-11-11, 사용자): 회차 자릿수는 그 시즌의 가장 큰 회차에 맞춤 (100화 넘으면 S01E001, EpisodeCode)
    private static func seriesTarget(_ item: AgentModels.Item, season: Int, episode: Int, end: Int?, title: String?, maxEpisode: Int = 0) -> AgentModels.Target {
        let name = safeName(item.title)
        let code = EpisodeCode.make(season: season, episode: episode, end: end, maxEpisode: maxEpisode)
        var filename = "\(name) - \(code)"
        if let title = episodeTitle(title) { filename += " (\(title))" }
        let folder = "\(name)\(item.year.map { " (\($0))" } ?? "")/\(season == 0 ? "스페셜" : "시즌 \(season)")"
        return AgentModels.Target(folder: folder, filename: filename)
    }

    /// 회차제목이 비었거나 "1화", "에피소드 1", "Episode 1", "第1話" 처럼 번호뿐인지
    nonisolated static func isNumberOnlyTitle(_ title: String?) -> Bool {
        guard let title = title?.trimmingCharacters(in: .whitespaces), !title.isEmpty else { return true }
        return title.range(of: #"^(제?\s*\d+\s*(화|회|부)|(에피소드|episode|ep\.?)\s*\d+|第\s*\d+\s*(話|回|夜)|\d+)$"#,
                           options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// 번호뿐인 회차제목("1화", "에피소드 1", "第1話")은 쓰지 않고, 괄호는 푼다
    private static func episodeTitle(_ title: String?) -> String? {
        guard let title = title?.trimmingCharacters(in: .whitespaces), !title.isEmpty,
              title.range(of: #"^(제?\s*\d+\s*(화|회|부)|(에피소드|episode|ep\.?)\s*\d+|第\s*\d+\s*(話|回|夜)|\d+)$"#,
                          options: [.regularExpression, .caseInsensitive]) == nil else { return nil }
        var text = safeName(title.replacingOccurrences(of: #"[()\[\]]"#, with: " ", options: .regularExpression))
        if text.count > 80 { text = String(text.prefix(80)).trimmingCharacters(in: .whitespaces) + "…" }
        return text.isEmpty ? nil : text
    }

    /// 파일·폴더 이름에 쓸 수 없는 문자 (SMB·윈도우)
    static func safeName(_ name: String) -> String {
        var text = name.precomposedStringWithCanonicalMapping
        text = text.replacingOccurrences(of: #"\s*:\s*"#, with: " - ", options: .regularExpression)
        text = text.replacingOccurrences(of: #"[\\/?*"<>|]"#, with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        return text.trimmingCharacters(in: CharacterSet(charactersIn: " ."))
    }
}

/// 파일 경로에서 작품명·연도·시즌·회차를 알아낸다 (reader 메타정보 핸들러의 parsePath 와 같은 규칙)
enum FileNameParser {
    struct Parsed {
        var title: String
        var year: Int?
        var season: Int?
        var episode: Int?
        var episodeEnd: Int?
    }

    /// path 는 라이브러리 폴더 기준 경로. series 면 첫 폴더가 시리즈명이다.
    static func parse(_ path: String, series: Bool) -> Parsed {
        let parts = path.precomposedStringWithCanonicalMapping.split(separator: "/").map(String.init)
        let filename = (parts.last.map { ($0 as NSString).deletingPathExtension }) ?? path
        var parsed = Parsed(title: "")

        if let match = firstMatch(#"(?<![a-z])S(\d{1,2})\s*-?\s*E(\d{1,4})(?:\s*-?\s*E(\d{1,4}))?"#, filename)
            ?? firstMatch(#"(?<!\d)(\d{1,2})x(\d{2,3})(?:-(\d{2,3}))?(?!\d)"#, filename) {
            parsed.season = Int(match[1])
            parsed.episode = Int(match[2])
            parsed.episodeEnd = match.count > 3 ? Int(match[3]) : nil
        } else if let match = firstMatch(#"(?:^|[\s._\-\[])(?:E|EP)\.?\s*(\d{1,4})(?:$|[\s._\-\]：:])"#, filename)
                    ?? firstMatch(#"第\s*(\d{1,3})\s*[話话回夜]"#, filename)
                    ?? firstMatch(#"(\d{1,4})\s*(?:화|회|강)(?:$|[^가-힣])"#, filename)
                    ?? (series ? firstMatch(#"(?:^|\s-\s|\s)(\d{2,3})(?:\s|\.|$)"#, filename) : nil) {
            parsed.episode = Int(match[1])
        }
        if parsed.episode != nil, parsed.season == nil {
            parsed.season = 1
            for folder in parts.dropLast().dropFirst() {
                if let match = firstMatch(#"(?:시즌|Season|(?<![a-z])S)\s*(\d{1,2})(?!\d)"#, folder) ?? firstMatch(#"(?<!\d)(\d{1,2})\s*기(?:$|[^가-힣])"#, folder) {
                    parsed.season = Int(match[1])
                }
            }
        }

        // 시리즈는 첫 폴더가 시리즈명, 영화는 파일이 든 폴더명(없으면 파일명)
        let name: String
        if series {
            name = parts.count > 1 ? parts[0] : seriesName(filename)
        } else {
            name = parts.count > 1 ? parts[parts.count - 2] : filename
        }
        if let match = firstMatch(#"[\(\[\s._\-](19\d{2}|20\d{2})(?:[\)\]\s._\-]|$)"#, " " + name) { parsed.year = Int(match[1]) }
        parsed.title = clean(name)
        return parsed
    }

    /// 시리즈 폴더 없이 놓인 파일: 회차 표시(S01E01·E13·EP13·第13話·13화)부터 뒤(방송일·화질)를 뗀다.
    /// "미스터 션샤인.E13.180818.720p-NEXT" 가 "미스터 션샤인 E13 180818" 로 검색되어 찾지 못했다
    static func seriesName(_ filename: String) -> String {
        let cut = filename.replacingOccurrences(
            of: #"(?i)(?:(?<![a-z])S\d{1,2}\s*-?\s*E\d{1,4}|(?:^|(?<=[\s._\-\[]))EP?\.?\s*\d{1,4}(?=$|[\s._\-\]：:])|第\s*\d{1,3}\s*[話话回夜]|\d{1,4}\s*(?:화|회|강)(?=$|[^가-힣])).*$"#,
            with: "", options: .regularExpression)
        return cut.trimmingCharacters(in: CharacterSet(charactersIn: " ._-")).isEmpty ? filename : cut
    }

    /// 화질·코덱·연도 등을 지워 작품명만 남긴다
    static func clean(_ name: String) -> String {
        var text = name
        for (pattern, replacement) in [
            (#"\((19\d{2}|20\d{2})\)"#, " "), (#"\[[^\]]*\]"#, " "), (#"\{[^\}]*\}"#, " "), (#"[._]"#, " "),
            (#"(?i)\b(19\d{2}|20\d{2}|\d{3,4}p|4k|uhd|hdr\d*|dv|bluray|blu-ray|bdrip|brrip|web-?dl|webrip|hdtv|dvdrip|x26[45]|h ?26[45]|hevc|avc|aac\d?|ac3|dts|remux|proper|repack|extended|unrated|director'?s cut|감독판|확장판)\b.*$"#, ""),
            (#"\(\s*\)"#, " "), (#"(?i)S\d{1,2}\s*E\d{1,4}.*$"#, ""), (#"\s+"#, " "),
        ] {
            text = text.replacingOccurrences(of: pattern, with: replacement, options: .regularExpression)
        }
        return text.trimmingCharacters(in: CharacterSet(charactersIn: " \t-"))
    }

    /// 제목 비교 열쇠 (괄호·띄어쓰기·문장부호 빼고 소문자)
    static func key(_ title: String) -> String {
        title.precomposedStringWithCanonicalMapping
            .replacingOccurrences(of: #"\([^)]*\)"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"[^\p{L}\p{N}]+"#, with: "", options: .regularExpression)
            .lowercased()
    }

    private static func firstMatch(_ pattern: String, _ text: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        return (0..<match.numberOfRanges).map { index in
            Range(match.range(at: index), in: text).map { String(text[$0]) } ?? ""
        }
    }
}
