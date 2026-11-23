import Foundation

/// 에이전트 규약(docs/에이전트 규약.md)의 응답 모양
enum AgentModels {
    /// 받는 종류 하나
    struct Kind: Codable, Hashable, Identifiable {
        let id: String
        let name: String
        /// MOVIE, SERIES, AUTO
        let type: String
    }

    struct Info: Decodable {
        let name: String
        let version: String?
        let `protocol`: Int?
        let kinds: [Kind]
        let relocations: Bool?
    }

    struct Collection: Decodable, Hashable {
        let id: FlexibleID
        let name: String
    }

    struct Author: Decodable, Hashable {
        let id: FlexibleID
        let source: String?
        let sourceId: FlexibleID?
        let name: String
        let nameOrigin: String?
        let photo: String?
        let items: Int?
        let role: String?
        let character: String?
    }

    struct Episode: Decodable, Hashable {
        let season: Int
        let episode: Int
        let title: String?
        let summary: String?
        let date: String?
        let still: String?
    }

    struct Item: Decodable {
        let id: FlexibleID
        /// MOVIE, SERIES
        let type: String
        let kind: String?
        let source: String?
        let sourceId: FlexibleID?
        let title: String
        let titleOrigin: String?
        let collection: Collection?
        let year: Int?
        let date: String?
        let genres: [String]?
        let summary: String?
        let poster: String?
        let backdrop: String?
        /// 관람등급 "나라:등급" (KR:15, US:R …). 등급이 없으면 "", 에이전트가 다루지 않으면 nil
        var rating: String? = nil
        let authors: [Author]?
        let episodes: [Episode]?
    }

    struct Target: Decodable, Hashable {
        /// 라이브러리 폴더 기준 폴더
        let folder: String
        /// 확장자를 뺀 파일 이름
        let filename: String
    }

    struct Relocation: Decodable, Hashable {
        let hash: String
        let size: Int64
        let path: String
        let target: Target
        let to: String
    }

    struct Candidate: Decodable, Hashable, Identifiable {
        let id: FlexibleID
        let type: String
        let title: String
        let titleOrigin: String?
        let year: Int?
        let summary: String?
        let poster: String?
    }

    struct Match: Decodable {
        let matched: Bool?
        let item: Item?
        let episode: Episode?
        let target: Target?
        let relocations: [Relocation]?
        let reason: String?
        let candidates: [Candidate]?
    }

    struct Search: Decodable {
        let candidates: [Candidate]
    }

    struct ItemDetail: Decodable {
        let item: Item
    }

    struct AuthorWork: Decodable, Hashable {
        let id: FlexibleID
        let type: String
        let title: String
        let titleOrigin: String?
        let year: Int?
        let poster: String?
        let role: String?
        let character: String?
    }

    struct AuthorDetail: Decodable {
        let author: Author
        let items: [AuthorWork]
    }

    struct Relocations: Decodable {
        let relocations: [Relocation]
    }

    /// 실패 응답
    struct Failure: Decodable {
        let success: Bool?
        let message: String?
    }
}

/// 숫자로도 글자로도 오는 고유값 (TMDB 번호, UUID …)
struct FlexibleID: Decodable, Hashable, CustomStringConvertible {
    let value: String
    var description: String { value }

    init(_ value: String) { self.value = value }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let text = try? container.decode(String.self) {
            value = text
        } else if let number = try? container.decode(Int64.self) {
            value = String(number)
        } else {
            value = String(try container.decode(Double.self))
        }
    }
}
