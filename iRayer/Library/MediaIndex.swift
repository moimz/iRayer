import Foundation
import Observation

/// 위치(이 기기·폴더·NAS)의 영상·만화책 목록.
/// 홈의 "최근 추가된 영상"과 검색(파일명)에 쓴다. 캐시해 두고 먼저 보여준 뒤 다시 훑어서 갱신한다 (stale-while-revalidate).
/// 폴더 설정에서 "홈에 표시" 나 "검색에 표시" 를 켠 추가한 폴더만 훑는다.
@Observable
final class MediaIndex {
    static let shared = MediaIndex()

    /// 찾은 영상 전체
    private(set) var files: [VideoFile] = []
    /// 다시 훑는 중
    private(set) var isScanning = false

    private let fileURL = AppPaths.support.appending(path: "MediaIndex.json")
    /// 위치 하나에서 너무 깊거나 많이 내려가지 않게
    private let maxDepth = 6
    private let maxFolders = 2000

    private init() {
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode([VideoFile].self, from: data) {
            files = decoded
        }
    }

    /// 최근 추가 순 (파일 수정 시각). 홈에 표시하는 폴더의 영상만.
    func recent(limit: Int) -> [VideoFile] {
        let options = FolderOptionsStore.shared
        return Array(files.filter { !$0.isArchive && !$0.isText && options.showsOnHome($0) && !options.isHiddenForAdult($0) }
            .sorted { $0.modifiedAt > $1.modifiedAt }.prefix(limit))
    }

    /// 파일명 검색 (대소문자·한글 자모 분리 무시)
    func search(_ term: String) -> [VideoFile] {
        let query = term.precomposedStringWithCanonicalMapping.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return [] }
        let options = FolderOptionsStore.shared
        return files.filter { KoreanIndex.matches(query, in: $0.name) && options.showsInSearch($0) && !options.isHiddenForAdult($0) }
    }

    /// 모든 위치를 다시 훑는다. 위치 하나가 실패하면(서버 꺼짐 등) 그 위치는 예전 결과를 그대로 둔다.
    func refresh() async {
        guard !isScanning else { return }
        isScanning = true
        defer { isScanning = false }

        var result: [VideoFile] = []
        for root in Self.roots() {
            if let found = await scan(root) {
                result += found
            } else {
                // 같은 주소를 계정만 달리해 여러 번 등록할 수 있으므로 서버 ID 까지 같은 것만 남긴다
                let prefix = root.url.absoluteString
                result += files.filter { $0.serverID == root.serverID && $0.url.absoluteString.hasPrefix(prefix) }
            }
        }
        // 홈·검색에 켠 폴더 밖의 예전 기록은 버린다
        let options = FolderOptionsStore.shared
        result = result.filter { options.showsOnHome($0) || options.showsInSearch($0) }
        // 같은 서버의 같은 파일은 한 번만 (폴더 위치가 겹칠 때)
        var seen = Set<String>()
        files = result.filter { seen.insert("\($0.serverID?.uuidString ?? "-")|\($0.url.absoluteString)").inserted }
        save()
    }

    /// 폴더 화면이 새로 받은 목록으로 그 폴더 바로 안의 파일만 바꾼다 (홈·검색에 켠 폴더일 때. 하위 폴더는 그대로)
    func update(_ folder: FolderRoute, listing: DirectoryListing) {
        let options = FolderOptionsStore.shared
        guard options.showsOnHome(folder.url, serverID: folder.serverID) || options.showsInSearch(folder.url, serverID: folder.serverID) else { return }
        let folderKey = FolderOptionsStore.key(folder.url, serverID: folder.serverID)
        let isInFolder = { (file: VideoFile) in
            file.serverID == folder.serverID && FolderOptionsStore.key(file.url.deletingLastPathComponent(), serverID: file.serverID) == folderKey
        }
        // 바뀜 (2026-11-08): 텍스트 파일도 (검색에 나오게, 최근 추가에서는 뺀다)
        let fresh = listing.videos + listing.archives + listing.texts
        let old = files.filter(isInFolder)
        guard Set(old.map(\.stateKey)) != Set(fresh.map(\.stateKey)) else { return }
        files = files.filter { !isInFolder($0) } + fresh
        save()
    }

    /// 지운 파일들을 뺀다 (파일 삭제 뒤: 다시 훑기 전에도 홈 최근 추가·검색에서 바로 빠지게)
    func forget(where isGone: (VideoFile) -> Bool) {
        guard files.contains(where: isGone) else { return }
        files.removeAll(where: isGone)
        save()
    }

    /// 훑을 위치: 홈 또는 검색에 켠 추가한 폴더 (다른 켠 폴더 안에 추가한 폴더는 위 폴더를 훑을 때 함께 훑는다)
    private static func roots() -> [FolderRoute] {
        let roots = FolderOptionsStore.shared.indexedRoots
        return roots.filter { root in
            !roots.contains { other in
                other.serverID == root.serverID && other.url != root.url && FolderOptionsStore.isInside(root.url, other.url)
            }
        }
    }

    /// 위치 하나를 넓이 우선으로 훑는다. 최상위부터 열 수 없으면 nil.
    /// 홈·검색 둘 다 끈 하위 폴더는 들어가지 않는다.
    private func scan(_ root: FolderRoute) async -> [VideoFile]? {
        guard let first = try? await DirectoryLister.list(root) else { return nil }
        let options = FolderOptionsStore.shared
        let included = { (folder: FolderRoute) in
            options.showsOnHome(folder.url, serverID: folder.serverID) || options.showsInSearch(folder.url, serverID: folder.serverID)
        }
        var videos = first.videos + first.archives + first.texts
        var queue = first.folders.filter(included).map { ($0, 1) }
        var visited = 1
        while !queue.isEmpty, visited < maxFolders {
            let (folder, depth) = queue.removeFirst()
            visited += 1
            guard let listing = try? await DirectoryLister.list(folder) else { continue }
            videos += listing.videos + listing.archives + listing.texts
            if depth < maxDepth {
                queue += listing.folders.filter(included).map { ($0, depth + 1) }
            }
        }
        return videos
    }

    private func save() {
        try? FileManager.default.createDirectory(at: AppPaths.support, withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(files) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
