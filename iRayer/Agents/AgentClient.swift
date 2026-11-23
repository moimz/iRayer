import CryptoKit
import Foundation

/// 사용자 정의 에이전트에 규약대로 요청을 보낸다 (docs/에이전트 규약.md)
/// 모든 요청은 GET 이고, API 키가 있으면 시각 + 경로와 쿼리를 HMAC-SHA256 으로 서명해 헤더에 넣는다.
struct AgentClient {
    enum AgentError: LocalizedError {
        case address
        case failed(String)
        case response(Int)

        var errorDescription: String? {
            switch self {
            case .address: "에이전트 주소가 올바르지 않습니다."
            case .failed(let message): message
            case .response(let status): "에이전트가 응답하지 않습니다. (HTTP \(status))"
            }
        }
    }

    let baseURL: String
    let key: String?

    // MARK: - 규약의 요청

    func info() async throws -> AgentModels.Info {
        try await get("agent", [])
    }

    func match(kind: String, hash: String, size: Int64, path: String, duration: Double?,
               choice: String? = nil, season: Int? = nil, episode: Int? = nil, episodeEnd: Int? = nil) async throws -> AgentModels.Match {
        var query: [(String, String)] = [("kind", kind), ("hash", hash), ("size", String(size)), ("path", path)]
        if let duration { query.append(("duration", String(Int(duration.rounded())))) }
        if let choice { query.append(("choice", choice)) }
        if let season { query.append(("season", String(season))) }
        if let episode { query.append(("episode", String(episode))) }
        if let episodeEnd { query.append(("episode_end", String(episodeEnd))) }
        return try await get("match", query)
    }

    func search(kind: String, query text: String, year: Int? = nil) async throws -> [AgentModels.Candidate] {
        var query: [(String, String)] = [("kind", kind), ("query", text)]
        if let year { query.append(("year", String(year))) }
        let result: AgentModels.Search = try await get("search", query)
        return result.candidates
    }

    func item(_ id: String, kind: String? = nil) async throws -> AgentModels.Item {
        let result: AgentModels.ItemDetail = try await get("item", [("id", id)] + (kind.map { [("kind", $0)] } ?? []))
        return result.item
    }

    /// 작품 정보를 에이전트가 정보 출처(TMDB 등)에서 다시 받게 하고 돌려받는다 (작품 화면의 메타데이터 새로 고침, 2026-11-07)
    func refreshedItem(_ id: String, kind: String?) async throws -> AgentModels.Item {
        let result: AgentModels.ItemDetail = try await get("item", [("id", id), ("refresh", "1")] + (kind.map { [("kind", $0)] } ?? []))
        return result.item
    }

    func author(_ id: String) async throws -> AgentModels.AuthorDetail {
        try await get("author", [("id", id)])
    }

    func relocations(kind: String) async throws -> [AgentModels.Relocation] {
        let result: AgentModels.Relocations = try await get("relocations", [("kind", kind)])
        return result.relocations
    }

    // MARK: - 보내기

    private func get<T: Decodable>(_ endpoint: String, _ query: [(String, String)]) async throws -> T {
        let base = baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        // 쿼리는 직접 만든다: 서명한 문자열과 실제로 보내는 주소가 글자 하나까지 같아야 한다
        let queryString = query.map { "\(Self.encode($0.0))=\(Self.encode($0.1.precomposedStringWithCanonicalMapping))" }
            .joined(separator: "&")
        guard let url = URL(string: base + "/" + endpoint + (queryString.isEmpty ? "" : "?" + queryString)) else {
            throw AgentError.address
        }

        var request = URLRequest(url: url, timeoutInterval: 120)
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        if let key, !key.isEmpty {
            let time = String(Int(Date.now.timeIntervalSince1970))
            let pathAndQuery = url.path(percentEncoded: true) + (queryString.isEmpty ? "" : "?" + queryString)
            let mac = HMAC<SHA256>.authenticationCode(for: Data((time + "\n" + pathAndQuery).utf8),
                                                      using: SymmetricKey(data: Data(key.utf8)))
            // 바뀜 (2026-11-23, 사용자): 앱 이름을 따라 X-InPlayer-* → X-iRayer-* (서버 MoimzTools Meta 는 둘 다 받는다)
            request.setValue(time, forHTTPHeaderField: "X-iRayer-Time")
            request.setValue(mac.map { String(format: "%02x", $0) }.joined(), forHTTPHeaderField: "X-iRayer-Signature")
        }

        let (data, response) = try await URLSession.shared.data(for: request)
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        if let failure = try? decoder.decode(AgentModels.Failure.self, from: data), failure.success == false {
            throw AgentError.failed(failure.message ?? "에이전트가 요청을 처리하지 못했습니다.")
        }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw AgentError.response(http.statusCode)
        }
        return try decoder.decode(T.self, from: data)
    }

    private static func encode(_ text: String) -> String {
        // RFC 3986 의 예약되지 않은 문자만 그대로 (영문·숫자·-._~)
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        return text.addingPercentEncoding(withAllowedCharacters: allowed) ?? text
    }

    private static var userAgent: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "2.0"
        #if os(macOS)
        return "iRayer/\(version) (macOS)"
        #else
        return "iRayer/\(version) (iOS)"
        #endif
    }
}
