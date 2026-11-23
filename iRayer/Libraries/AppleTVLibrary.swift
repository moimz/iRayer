import SwiftUI
import Observation
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

/// Apple TV 에서 구입한 영화 목록. 맥이 미디어 보관함에서 읽어 iCloud 로 올리고, 아이폰·아이패드는 받는다.
/// "Apple TV 구입작 포함" 을 켠 영화 라이브러리가 이 목록을 훑어 작품에 잇는다. 재생은 Apple TV 앱에서만 된다.
@MainActor
@Observable
final class AppleTVLibrary {
    static let shared = AppleTVLibrary()

    struct Movie: Identifiable, Hashable, Codable, Sendable {
        /// Apple 상점 번호 (기기마다 같아서 동기화 열쇠로 쓴다. Apple TV 앱의 영화 화면을 찾는 데도 쓴다)
        let storeID: Int
        let title: String
        let year: Int?
        let genre: String

        var id: Int { storeID }
    }

    private(set) var movies: [Movie] = []
    private(set) var loaded = false
    private(set) var errorMessage: String?
    /// 보관함이 주는 그림 (맥에서 읽을 때만. 상점 포스터가 깨진 영화에 쓴다)
    @ObservationIgnored private(set) var artwork: [Int: Data] = [:]
    /// 상점 번호 → 세로 포스터 주소 (보관함의 그림은 가로로 긴 그림이라 상점의 포스터를 쓴다)
    private(set) var posters: [Int: URL] = (UserDefaults.standard.dictionary(forKey: "appleTVPosters") as? [String: String] ?? [:])
        .reduce(into: [:]) { result, entry in
            if let id = Int(entry.key), let url = URL(string: entry.value) { result[id] = url }
        }
    /// 상점 번호 → 미국 상점의 영어 제목 (에이전트에서 작품을 찾을 때 한국어 제목과 함께. 미국 상점에 없는 영화는 빈 글자)
    @ObservationIgnored private(set) var englishTitles: [Int: String] = UserDefaults.standard.dictionary(forKey: "appleTVEnglishTitles")
        .map { $0.reduce(into: [:]) { result, entry in if let id = Int(entry.key), let title = entry.value as? String { result[id] = title } } } ?? [:]
    /// 상점 번호 → Apple TV 영화 화면 주소 (한 번 찾으면 기억)
    @ObservationIgnored private var links: [String: String] = UserDefaults.standard.dictionary(forKey: "appleTVLinks") as? [String: String] ?? [:]
    private let fileURL = AppPaths.support.appending(path: "AppleTVMovies.json")

    private init() {
        if let data = try? Data(contentsOf: fileURL), let decoded = try? JSONDecoder().decode([Movie].self, from: data) {
            movies = decoded
        }
    }

    /// 상점 번호의 구입작
    func movie(_ storeID: Int) -> Movie? {
        movies.first { $0.storeID == storeID }
    }

    /// 맥: 미디어 보관함을 읽는다 (처음에는 맥이 접근 권한을 묻는다). 아이폰·아이패드: iCloud 로 받은 목록 그대로.
    func load() async {
        #if os(macOS)
        do {
            let read = try await AppleTVReader.read()
            let changed = read.map(\.movie) != movies
            movies = read.map(\.movie)
            artwork = read.reduce(into: [:]) { result, entry in result[entry.movie.storeID] = entry.artwork }
            errorMessage = nil
            if changed {
                save()
                SyncEngine.shared.publish(Self.syncKind)
                LibraryScanner.shared.appleTVChanged()
            }
        } catch {
            errorMessage = error.localizedDescription
        }
        #endif
        loaded = true
        await fetchPosters()
        await fetchEnglishTitles()
    }

    /// 아직 모르는 영어 제목을 미국 상점 조회로 받는다. 새로 알게 된 것이 있으면 못 찾은 구입작을 다시 찾게 한다.
    private func fetchEnglishTitles() async {
        let missing = movies.map(\.storeID).filter { englishTitles[$0] == nil }
        guard !missing.isEmpty else { return }
        for start in stride(from: 0, to: missing.count, by: 50) {
            let ids = missing[start..<min(start + 50, missing.count)]
            guard let url = URL(string: "https://itunes.apple.com/lookup?id=\(ids.map(String.init).joined(separator: ","))&country=us"),
                  let (data, _) = try? await URLSession.shared.data(from: url),
                  let lookup = try? JSONDecoder().decode(Lookup.self, from: data) else { continue }
            for id in ids { englishTitles[id] = "" }
            for result in lookup.results {
                if let id = result.trackId, let name = result.trackName { englishTitles[id] = name }
            }
        }
        UserDefaults.standard.set(Dictionary(uniqueKeysWithValues: englishTitles.map { (String($0.key), $0.value) }), forKey: "appleTVEnglishTitles")
        LibraryScanner.shared.appleTVChanged()
    }

    private func save() {
        try? FileManager.default.createDirectory(at: AppPaths.support, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(movies) { try? data.write(to: fileURL, options: .atomic) }
    }

    private static var country: String {
        (Locale.current.region?.identifier ?? "KR").lowercased()
    }

    /// 아직 모르는 포스터를 상점 조회로 한꺼번에 받는다 (한 번에 50편씩)
    private func fetchPosters() async {
        let missing = movies.map(\.storeID).filter { posters[$0] == nil }
        for start in stride(from: 0, to: missing.count, by: 50) {
            let ids = missing[start..<min(start + 50, missing.count)].map(String.init).joined(separator: ",")
            guard let url = URL(string: "https://itunes.apple.com/lookup?id=\(ids)&country=\(Self.country)"),
                  let (data, _) = try? await URLSession.shared.data(from: url),
                  let lookup = try? JSONDecoder().decode(Lookup.self, from: data) else { continue }
            // 100x100 대신 세로 포스터 크기로. 상점에 그림이 깨진 영화도 있어 실제로 받아지는 것만 쓴다 (나머지는 TMDB 포스터)
            let candidates: [(Int, URL)] = lookup.results.compactMap { result in
                guard let id = result.trackId, let small = result.artworkUrl100,
                      let poster = URL(string: small.replacingOccurrences(of: "100x100bb", with: "400x600bb")) else { return nil }
                return (id, poster)
            }
            let found = await withTaskGroup(of: (Int, URL)?.self) { group in
                for (id, poster) in candidates {
                    group.addTask {
                        var request = URLRequest(url: poster)
                        request.httpMethod = "HEAD"
                        let status = (try? await URLSession.shared.data(for: request))?.1 as? HTTPURLResponse
                        return status?.statusCode == 200 ? (id, poster) : nil
                    }
                }
                return await group.reduce(into: [(Int, URL)]()) { if let entry = $1 { $0.append(entry) } }
            }
            for (id, poster) in found { posters[id] = poster }
        }
        UserDefaults.standard.set(Dictionary(uniqueKeysWithValues: posters.map { (String($0.key), $0.value.absoluteString) }), forKey: "appleTVPosters")
    }

    private struct Lookup: Decodable {
        struct Result: Decodable {
            let trackId: Int?
            let trackName: String?
            let artworkUrl100: String?
        }
        let results: [Result]
    }

    /// Apple TV 앱에서 그 영화 화면을 연다. 상점 번호로 영화 화면 주소를 찾고, 못 찾으면 제목으로 검색한 화면.
    func open(_ movie: Movie) async {
        var url = links[String(movie.storeID)].flatMap(URL.init(string:))
        if url == nil {
            // 상점 주소는 tv.apple.com 의 영화 화면 주소로 넘겨준다 (상점 주소를 바로 열면 Apple TV 앱이 보관함만 연다)
            var request = URLRequest(url: URL(string: "https://itunes.apple.com/\(Self.country)/movie/id\(movie.storeID)")!)
            request.httpMethod = "HEAD"
            if let (_, response) = try? await URLSession.shared.data(for: request), let final = response.url, final.host() == "tv.apple.com" {
                url = final
                links[String(movie.storeID)] = final.absoluteString
                UserDefaults.standard.set(links, forKey: "appleTVLinks")
            }
        }
        var search = URLComponents(string: "https://tv.apple.com/\(Self.country)/search")!
        search.queryItems = [URLQueryItem(name: "term", value: movie.title)]
        let target = url ?? search.url!
        #if os(macOS)
        if let tv = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.TV") {
            _ = try? await NSWorkspace.shared.open([target], withApplicationAt: tv, configuration: NSWorkspace.OpenConfiguration())
        } else {
            NSWorkspace.shared.open(target)
        }
        #else
        // tv.apple.com 주소는 Apple TV 앱이 받는다
        await UIApplication.shared.open(target)
        #endif
    }
}

// MARK: - 동기화

extension AppleTVLibrary {
    static let syncKind = "appleTVMovie"

    /// 구입 목록 (맥이 올리고 모든 기기가 받는다)
    var syncKinds: [SyncEngine.Kind] {
        [
            SyncEngine.Kind(name: Self.syncKind) { [unowned self] in
                movies.map { String($0.storeID) }
            } payload: { [unowned self] key in
                movies.first { String($0.storeID) == key }.flatMap { try? syncEncoder.encode($0) }
            } apply: { [unowned self] key, data in
                guard let movie = try? JSONDecoder().decode(Movie.self, from: data) else { return false }
                if let index = movies.firstIndex(where: { String($0.storeID) == key }) {
                    movies[index] = movie
                } else {
                    movies.append(movie)
                }
                save()
                LibraryScanner.shared.appleTVChanged()
                return true
            } delete: { [unowned self] key in
                movies.removeAll { String($0.storeID) == key }
                save()
                LibraryScanner.shared.appleTVChanged()
            },
        ]
    }
}
