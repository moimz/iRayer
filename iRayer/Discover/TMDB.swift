import Foundation
import Observation

/// TMDB 설정: 키(키체인)와 쓸 국가·언어.
/// 국가는 볼 수 있는 곳(구독·대여·구매, TMDB 의 시청처 = JustWatch 자료)을, 언어는 제목·줄거리를 정한다.
@Observable
final class TMDBSettings {
    static let shared = TMDBSettings()

    static let keyPageURL = URL(string: "https://www.themoviedb.org/settings/api")!

    /// API 읽기 액세스 토큰 (긴 것). 있으면 이것을 먼저 쓴다.
    var accessToken: String {
        didSet { save(accessToken, for: Self.tokenAccount) }
    }
    /// API 키 (짧은 것)
    var apiKey: String {
        didSet { save(apiKey, for: Self.apiKeyAccount) }
    }
    var region: String {
        didSet { UserDefaults.standard.set(region, forKey: "tmdbRegion") }
    }
    var language: String {
        didSet { UserDefaults.standard.set(language, forKey: "tmdbLanguage") }
    }

    /// TMDB 사용 (끄면 키가 있어도 검색에 "다른 곳에서 찾기"를 하지 않는다)
    var isEnabled: Bool {
        didSet { UserDefaults.standard.set(isEnabled, forKey: "tmdbEnabled") }
    }

    var isConfigured: Bool { !accessToken.isEmpty || !apiKey.isEmpty }
    /// 검색에서 쓸 수 있는지: 켜져 있고 키가 있다
    var isActive: Bool { isEnabled && isConfigured }

    /// 고를 수 있는 국가 (시청처가 있는 주요 국가)
    static let regions: [(code: String, name: String)] = [
        ("KR", "대한민국"), ("US", "미국"), ("JP", "일본"), ("GB", "영국"),
        ("CA", "캐나다"), ("AU", "호주"), ("DE", "독일"), ("FR", "프랑스"),
        ("TW", "대만"), ("HK", "홍콩"), ("SG", "싱가포르"), ("TH", "태국"),
    ]
    static let languages: [(code: String, name: String)] = [
        ("ko-KR", "한국어"), ("en-US", "영어"), ("ja-JP", "일본어"),
        ("zh-CN", "중국어(간체)"), ("zh-TW", "중국어(번체)"), ("fr-FR", "프랑스어"), ("de-DE", "독일어"),
    ]

    private static let tokenAccount = "tmdb.accessToken"
    private static let apiKeyAccount = "tmdb.apiKey"

    private init() {
        accessToken = Keychain.password(for: Self.tokenAccount) ?? ""
        apiKey = Keychain.password(for: Self.apiKeyAccount) ?? ""
        region = UserDefaults.standard.string(forKey: "tmdbRegion") ?? "KR"
        language = UserDefaults.standard.string(forKey: "tmdbLanguage") ?? "ko-KR"
        isEnabled = UserDefaults.standard.object(forKey: "tmdbEnabled") as? Bool ?? true
    }

    private func save(_ value: String, for account: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            Keychain.deletePassword(for: account)
        } else {
            Keychain.setPassword(trimmed, for: account)
        }
    }
}

/// TMDB 의 영화·시리즈 하나 (검색 결과)
struct TMDBTitle: Decodable, Identifiable, Hashable {
    let id: Int
    let mediaType: String
    let title: String?
    let name: String?
    let originalTitle: String?
    let originalName: String?
    let releaseDate: String?
    let firstAirDate: String?
    let overview: String?
    let posterPath: String?
    let backdropPath: String?
    let voteAverage: Double?

    var displayTitle: String { title ?? name ?? "" }
    var originalDisplayTitle: String? { originalTitle ?? originalName }
    var isMovie: Bool { mediaType == "movie" }
    var kindName: String { isMovie ? "영화" : "시리즈" }

    var year: Int? {
        guard let date = releaseDate ?? firstAirDate, date.count >= 4 else { return nil }
        return Int(date.prefix(4))
    }
}

/// 영화 상세 (출연진·감독 포함)
struct TMDBMovieDetail: Codable, Hashable {
    struct Genre: Codable, Hashable { let name: String }
    struct Person: Codable, Hashable, Identifiable {
        let id: Int
        let name: String
        let character: String?
        let job: String?
        let profilePath: String?
    }
    struct Credits: Codable, Hashable {
        let cast: [Person]
        let crew: [Person]
    }

    let id: Int
    let title: String?
    let overview: String?
    let posterPath: String?
    let backdropPath: String?
    let runtime: Int?
    let genres: [Genre]?
    let credits: Credits?

    var directors: [Person] { credits?.crew.filter { $0.job == "Director" } ?? [] }
}

/// 한 국가에서 볼 수 있는 곳
struct TMDBWatchOptions: Decodable {
    /// TMDB 의 시청처 페이지 (여기서 JustWatch 로 이어진다)
    let link: String?
    let flatrate: [TMDBProvider]?
    let free: [TMDBProvider]?
    let ads: [TMDBProvider]?
    let rent: [TMDBProvider]?
    let buy: [TMDBProvider]?

    var isEmpty: Bool {
        [flatrate, free, ads, rent, buy].allSatisfy { $0?.isEmpty ?? true }
    }
}

struct TMDBProvider: Decodable, Hashable, Identifiable {
    let providerId: Int
    let providerName: String
    let logoPath: String?

    var id: Int { providerId }
}

enum TMDBError: LocalizedError {
    case noKey
    case server(String)

    var errorDescription: String? {
        switch self {
        case .noKey: "설정 > TMDB 에서 키를 넣어 주세요."
        case .server(let message): message
        }
    }
}

/// 오류 응답의 내용
private struct TMDBFailure: Decodable {
    let statusMessage: String?
}

enum TMDBClient {
    private static let base = URL(string: "https://api.themoviedb.org/3/")!

    /// 포스터·로고 주소 (size: w92, w185, w342, w780 …)
    static func imageURL(_ path: String?, size: String) -> URL? {
        guard let path else { return nil }
        return URL(string: "https://image.tmdb.org/t/p/\(size)\(path)")
    }

    /// 에이전트가 준 TMDB 그림 주소를 다른 크기로 (주소에 크기가 들어 있다: /t/p/w300/…). TMDB 그림이 아니면 그대로.
    /// 화면을 꽉 채우는 맨 위 그림은 "original" 로 (장면 사진은 w92·w185·w300·original 뿐이다)
    static func resized(_ address: String?, to size: String) -> URL? {
        guard let address else { return nil }
        guard address.hasPrefix("https://image.tmdb.org/t/p/") else { return URL(string: address) }
        return URL(string: address.replacingOccurrences(of: #"/t/p/[^/]+/"#, with: "/t/p/\(size)/", options: .regularExpression))
    }

    /// 영화·시리즈 검색 (인물은 빼고)
    static func search(_ query: String) async throws -> [TMDBTitle] {
        struct Page: Decodable { let results: [Result] }
        // 인물이 섞여 오므로 종류만 먼저 보고 영화·시리즈만 푼다
        struct Result: Decodable {
            let mediaType: String
            let title: TMDBTitle?
            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                mediaType = try container.decode(String.self, forKey: .mediaType)
                title = mediaType == "movie" || mediaType == "tv" ? try TMDBTitle(from: decoder) : nil
            }
            enum CodingKeys: String, CodingKey { case mediaType }
        }
        let settings = TMDBSettings.shared
        let page: Page = try await get("search/multi", [
            URLQueryItem(name: "query", value: query),
            URLQueryItem(name: "language", value: settings.language),
            URLQueryItem(name: "region", value: settings.region),
            URLQueryItem(name: "include_adult", value: "true"),  // 성인물 표시가 붙은 작품도 (사용자 결정 2026-11-06)
        ])
        return page.results.compactMap(\.title)
    }

    /// 영화 찾기: 제목으로 찾아 연도가 가장 가까운 것 (±1년 안, 연도를 모르면 첫 번째)
    static func findMovie(_ title: String, year: Int?) async throws -> TMDBTitle? {
        struct Page: Decodable { let results: [TMDBTitle] }
        // 검색 결과에는 media_type 이 없어서 영화로 채운다
        struct Movie: Decodable {
            let id: Int
            let title: String?
            let originalTitle: String?
            let releaseDate: String?
            let overview: String?
            let posterPath: String?
            let backdropPath: String?
            let voteAverage: Double?
        }
        struct MoviePage: Decodable { let results: [Movie] }
        let page: MoviePage = try await get("search/movie", [
            URLQueryItem(name: "query", value: title),
            URLQueryItem(name: "language", value: TMDBSettings.shared.language),
            URLQueryItem(name: "include_adult", value: "true"),  // 성인물 표시가 붙은 작품도 (사용자 결정 2026-11-06)
        ])
        let titles = page.results.map {
            TMDBTitle(id: $0.id, mediaType: "movie", title: $0.title, name: nil, originalTitle: $0.originalTitle, originalName: nil,
                      releaseDate: $0.releaseDate, firstAirDate: nil, overview: $0.overview, posterPath: $0.posterPath,
                      backdropPath: $0.backdropPath, voteAverage: $0.voteAverage)
        }
        guard let year else { return titles.first }
        return titles.filter { $0.year.map { abs($0 - year) <= 1 } ?? false }
            .min { abs(($0.year ?? 0) - year) < abs(($1.year ?? 0) - year) }
    }

    /// 영화 상세 + 출연진·감독
    static func movieDetail(_ id: Int) async throws -> TMDBMovieDetail {
        try await get("movie/\(id)", [
            URLQueryItem(name: "language", value: TMDBSettings.shared.language),
            URLQueryItem(name: "append_to_response", value: "credits"),
        ])
    }

    /// 인물의 다른 이름들 (영어 이름 + 다른 표기)
    static func personNames(_ id: Int) async throws -> [String] {
        struct Person: Decodable {
            let name: String
            let alsoKnownAs: [String]?
        }
        let person: Person = try await get("person/\(id)", [URLQueryItem(name: "language", value: "en-US")])
        return [person.name] + (person.alsoKnownAs ?? [])
    }

    /// 인물이 나온 영화들 (출연·연출)
    static func personMovies(_ id: Int) async throws -> [TMDBTitle] {
        struct Credit: Decodable {
            let id: Int
            let title: String?
            let originalTitle: String?
            let releaseDate: String?
            let posterPath: String?
            let job: String?
        }
        struct Credits: Decodable {
            let cast: [Credit]
            let crew: [Credit]
        }
        let credits: Credits = try await get("person/\(id)/movie_credits", [
            URLQueryItem(name: "language", value: TMDBSettings.shared.language),
        ])
        return (credits.cast + credits.crew.filter { $0.job == "Director" }).map {
            TMDBTitle(id: $0.id, mediaType: "movie", title: $0.title, name: nil, originalTitle: $0.originalTitle, originalName: nil,
                      releaseDate: $0.releaseDate, firstAirDate: nil, overview: nil, posterPath: $0.posterPath,
                      backdropPath: nil, voteAverage: nil)
        }
    }

    /// 설정한 국가에서 볼 수 있는 곳 (없으면 nil)
    static func watchOptions(_ title: TMDBTitle) async throws -> TMDBWatchOptions? {
        struct Response: Decodable { let results: [String: TMDBWatchOptions] }
        let response: Response = try await get("\(title.isMovie ? "movie" : "tv")/\(title.id)/watch/providers", [])
        return response.results[TMDBSettings.shared.region]
    }

    /// 키가 맞는지 확인
    static func check() async throws {
        struct Response: Decodable {}
        let _: Response = try await get("configuration", [])
    }

    private static func get<T: Decodable>(_ path: String, _ query: [URLQueryItem]) async throws -> T {
        let settings = TMDBSettings.shared
        guard settings.isConfigured else { throw TMDBError.noKey }
        var components = URLComponents(url: base.appending(path: path), resolvingAgainstBaseURL: false)!
        var items = query
        if settings.accessToken.isEmpty {
            items.append(URLQueryItem(name: "api_key", value: settings.apiKey))
        }
        components.queryItems = items.isEmpty ? nil : items
        var request = URLRequest(url: components.url!)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if !settings.accessToken.isEmpty {
            request.setValue("Bearer \(settings.accessToken)", forHTTPHeaderField: "Authorization")
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            let message = (try? decoder.decode(TMDBFailure.self, from: data))?.statusMessage
            throw TMDBError.server(message ?? "TMDB 응답 오류 (\(http.statusCode))")
        }
        return try decoder.decode(T.self, from: data)
    }
}
