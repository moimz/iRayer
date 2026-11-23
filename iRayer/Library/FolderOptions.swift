import Foundation
import Observation

/// 폴더 목록 보기 방식
enum FolderViewMode: String, Codable, CaseIterable {
    /// 세로 포스터 (만화책 표지) — 아이폰 한 줄에 3개
    case poster
    /// 가로 썸네일 (영상) — 아이폰 한 줄에 2개
    case thumbnail

    var title: String {
        switch self {
        case .poster: "포스터"
        case .thumbnail: "썸네일"
        }
    }
}

/// 목록 정렬. 이름순일 때만 초성 색인을 보여준다.
enum FolderSortOrder: String, Codable, CaseIterable {
    case name
    /// 새로 바뀐(추가된) 것 먼저
    case newest
    case oldest

    var title: String {
        switch self {
        case .name: "이름순"
        case .newest: "최신순"
        case .oldest: "오래된순"
        }
    }

    var systemImage: String {
        switch self {
        case .name: "textformat"
        case .newest: "arrow.down"
        case .oldest: "arrow.up"
        }
    }
}

/// 폴더에 정한 것. 보기·홈·검색·숨김은 추가한 폴더(AddedFolder)에만 두고 그 하위 폴더는 모두 따른다.
/// 정렬은 폴더마다 따로 (도구 막대의 정렬 단추, 물려받지 않는다).
struct FolderOptions: Codable, Equatable {
    var viewMode: FolderViewMode?
    var showsOnHome: Bool?
    var showsInSearch: Bool?
    var sortOrder: FolderSortOrder?
    /// 성인 등급 숨기기를 켰을 때 이 폴더를 숨긴다
    var hidesForAdult: Bool?
    /// 이 설정을 둔 폴더
    var url: URL
    var serverID: UUID?
}

/// 폴더 옵션 저장소: 보기 방식, 홈에 표시, 검색에 표시, 숨김 (추가한 폴더 단위), 정렬 (폴더마다).
/// 홈·검색 표시는 정하지 않았으면 끔 (괜히 NAS 전체를 훑지 않게).
@Observable
final class FolderOptionsStore {
    static let shared = FolderOptionsStore()

    fileprivate(set) var options: [String: FolderOptions] = [:]

    fileprivate let defaults = UserDefaults.standard

    private init() {
        if let data = defaults.data(forKey: "folderOptions"), let decoded = try? JSONDecoder().decode([String: FolderOptions].self, from: data) {
            options = decoded
        }
    }

    // MARK: - 폴더

    /// 폴더를 가리키는 키. 이 기기 문서 폴더는 앱을 다시 설치하면 경로가 바뀌므로 그 안의 상대 경로로 적는다.
    nonisolated static func key(_ url: URL, serverID: UUID?) -> String {
        var path = url.standardizedFileURL.path(percentEncoded: false).precomposedStringWithCanonicalMapping
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        if url.isFileURL {
            var documents = URL.documentsDirectory.standardizedFileURL.path(percentEncoded: false).precomposedStringWithCanonicalMapping
            while documents.hasSuffix("/") { documents.removeLast() }
            // /private/var 와 /var 처럼 표기가 달라도 같은 폴더로 본다
            for prefix in [documents, "/private" + documents, documents.replacingOccurrences(of: "/private", with: "")] where path == prefix || path.hasPrefix(prefix + "/") {
                return "docs:" + path.dropFirst(prefix.count)
            }
            return "file:" + path
        }
        return "\(serverID?.uuidString ?? "-")|\(url.host() ?? ""):\(url.port ?? 0)\(path)"
    }

    /// url 이 folder 와 같거나 그 안에 있는지 (로컬 경로 표기 차이는 key 로 맞춘다)
    nonisolated static func isInside(_ url: URL, _ folder: URL) -> Bool {
        let path = key(url, serverID: nil), base = key(folder, serverID: nil)
        return path == base || path.hasPrefix(base.hasSuffix("/") || base.hasSuffix(":") ? base : base + "/")
    }

    /// 이 폴더가 들어 있는 추가한 폴더의 설정 (추가한 폴더 밖이면 nil)
    private func rootOptions(_ url: URL, serverID: UUID?) -> FolderOptions? {
        guard let root = LocationStore.shared.addedFolder(containing: url, serverID: serverID) else { return nil }
        return options[Self.key(root.url, serverID: serverID)]
    }

    func explicit(_ url: URL, serverID: UUID?) -> FolderOptions? {
        options[Self.key(url, serverID: serverID)]
    }

    /// 보기 방식 (정하지 않았으면 nil: 안의 파일로 정한다)
    func viewMode(_ url: URL, serverID: UUID?) -> FolderViewMode? {
        rootOptions(url, serverID: serverID)?.viewMode
    }

    /// 정렬 (이 폴더에 정하지 않았으면 이름순)
    func sortOrder(_ url: URL, serverID: UUID?) -> FolderSortOrder {
        explicit(url, serverID: serverID)?.sortOrder ?? .name
    }

    func showsOnHome(_ url: URL, serverID: UUID?) -> Bool {
        rootOptions(url, serverID: serverID)?.showsOnHome ?? false
    }

    func showsInSearch(_ url: URL, serverID: UUID?) -> Bool {
        rootOptions(url, serverID: serverID)?.showsInSearch ?? false
    }

    /// 성인 등급 숨기기를 켰고 이 폴더가 든 추가한 폴더에 "숨김"을 켰는지
    func isHiddenForAdult(_ url: URL, serverID: UUID?) -> Bool {
        AdultFilter.shared.isOn && hidesForAdult(url, serverID: serverID)
    }

    /// 파일이 들어 있는 폴더 기준
    func isHiddenForAdult(_ file: VideoFile) -> Bool {
        isHiddenForAdult(file.url.deletingLastPathComponent(), serverID: file.serverID)
    }

    func hidesForAdult(_ url: URL, serverID: UUID?) -> Bool {
        rootOptions(url, serverID: serverID)?.hidesForAdult ?? false
    }

    /// 파일이 들어 있는 폴더 기준
    func showsOnHome(_ file: VideoFile) -> Bool {
        return showsOnHome(file.url.deletingLastPathComponent(), serverID: file.serverID)
    }

    func showsInSearch(_ file: VideoFile) -> Bool {
        showsInSearch(file.url.deletingLastPathComponent(), serverID: file.serverID)
    }

    func update(_ url: URL, serverID: UUID?, _ change: (inout FolderOptions) -> Void) {
        let key = Self.key(url, serverID: serverID)
        var value = options[key] ?? FolderOptions(url: url, serverID: serverID)
        change(&value)
        options[key] = value
        defaults.set(try? JSONEncoder().encode(options), forKey: "folderOptions")
        SyncEngine.shared.changed(Self.optionKind, key: key)
    }

    /// 홈·검색에 켠 추가한 폴더들 (훑기 시작점)
    var indexedRoots: [FolderRoute] {
        let locations = LocationStore.shared
        return locations.addedFolders.compactMap { added in
            guard let route = locations.route(of: added),
                  showsOnHome(route.url, serverID: route.serverID) || showsInSearch(route.url, serverID: route.serverID) else { return nil }
            return route
        }
    }

    /// 2.0: 하위 폴더가 위 폴더 설정을 물려받던 것을 추가한 폴더 단위로 옮긴다 (한 번만).
    /// 추가한 폴더에는 예전에 물려받던 값을 적고, 그 안 하위 폴더에 따로 둔 값은 지운다 (정렬은 폴더마다 그대로).
    func migrateToAddedFolders() {
        guard !defaults.bool(forKey: "folderOptionsByAddedFolder") else { return }
        defaults.set(true, forKey: "folderOptionsByAddedFolder")
        let locations = LocationStore.shared
        let old = options
        func inherited<T>(_ url: URL, _ serverID: UUID?, _ value: (FolderOptions) -> T?) -> T? {
            var current = url
            for _ in 0..<64 {
                if let found = old[Self.key(current, serverID: serverID)].flatMap(value) { return found }
                let parent = current.deletingLastPathComponent()
                if parent.path(percentEncoded: false) == current.path(percentEncoded: false) || current.path(percentEncoded: false).isEmpty { break }
                current = parent
            }
            return nil
        }
        var changed: Set<String> = []
        var roots: Set<String> = []
        for added in locations.addedFolders {
            guard let url = locations.url(of: added) else { continue }
            let key = Self.key(url, serverID: added.serverID)
            roots.insert(key)
            var value = old[key] ?? FolderOptions(url: url, serverID: added.serverID)
            value.viewMode = inherited(url, added.serverID) { $0.viewMode }
            value.showsOnHome = inherited(url, added.serverID) { $0.showsOnHome }
            value.showsInSearch = inherited(url, added.serverID) { $0.showsInSearch }
            value.hidesForAdult = inherited(url, added.serverID) { $0.hidesForAdult }
            let empty = value.viewMode == nil && value.showsOnHome == nil && value.showsInSearch == nil && value.hidesForAdult == nil && value.sortOrder == nil
            if value != old[key], !(empty && old[key] == nil) { options[key] = value; changed.insert(key) }
        }
        for (key, value) in old where !roots.contains(key) && locations.addedFolder(containing: value.url, serverID: value.serverID) != nil {
            if let sort = value.sortOrder {
                options[key] = FolderOptions(sortOrder: sort, url: value.url, serverID: value.serverID)
            } else {
                options[key] = nil
            }
            if options[key] != value { changed.insert(key) }
        }
        guard !changed.isEmpty else { return }
        defaults.set(try? JSONEncoder().encode(options), forKey: "folderOptions")
        changed.forEach { SyncEngine.shared.changed(Self.optionKind, key: $0) }
    }
}

// MARK: - 동기화

extension FolderOptionsStore {
    static let optionKind = "folderOption"

    /// 폴더 옵션(사용자가 추가한 이 기기 폴더 "file:" 는 기기 전용이라 빼고)
    var syncKinds: [SyncEngine.Kind] {
        [
            SyncEngine.Kind(name: Self.optionKind) { [unowned self] in
                Array(options.keys)
            } payload: { [unowned self] key in
                guard !key.hasPrefix("file:"), let value = options[key] else { return nil }
                return try? syncEncoder.encode(value)
            } apply: { [unowned self] key, data in
                guard let value = try? JSONDecoder().decode(FolderOptions.self, from: data) else { return false }
                options[key] = value
                defaults.set(try? JSONEncoder().encode(options), forKey: "folderOptions")
                return true
            } delete: { [unowned self] key in
                options[key] = nil
                defaults.set(try? JSONEncoder().encode(options), forKey: "folderOptions")
            },
        ]
    }
}
