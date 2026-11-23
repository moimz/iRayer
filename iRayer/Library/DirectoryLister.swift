import Foundation

/// 위치(로컬 / WebDAV) 안의 하위 폴더와 영상 목록
struct DirectoryListing {
    var folders: [FolderRoute] = []
    var videos: [VideoFile] = []
    /// 압축 파일 (만화책으로 보거나 풀 수 있는 것)
    var archives: [VideoFile] = []
    /// 텍스트 파일 (텍스트 뷰어로 본다, 2026-11-08)
    var texts: [VideoFile] = []
    /// 폴더가 바뀐 날짜 (날짜순 정렬)
    var folderDates: [URL: Date] = [:]

    /// 폴더를 먼저, 그다음 영상, 압축 파일. 이름순은 초성 색인 순서(ㄱ~ㅎ → A~Z → #), 날짜순은 같은 날짜면 이름순.
    mutating func sort(by order: FolderSortOrder) {
        let dates = folderDates
        switch order {
        case .name:
            folders.sort { KoreanIndex.precedes($0.title, $1.title) }
            videos.sort { KoreanIndex.precedes($0.name, $1.name) }
            archives.sort { KoreanIndex.precedes($0.name, $1.name) }
            texts.sort { KoreanIndex.precedes($0.name, $1.name) }
        case .newest, .oldest:
            let newest = order == .newest
            func precedes(_ lhs: Date, _ rhs: Date, _ lhsName: String, _ rhsName: String) -> Bool {
                if lhs != rhs { return newest ? lhs > rhs : lhs < rhs }
                return KoreanIndex.precedes(lhsName, rhsName)
            }
            folders.sort { precedes(dates[$0.url] ?? .distantPast, dates[$1.url] ?? .distantPast, $0.title, $1.title) }
            videos.sort { precedes($0.modifiedAt, $1.modifiedAt, $0.name, $1.name) }
            archives.sort { precedes($0.modifiedAt, $1.modifiedAt, $0.name, $1.name) }
            texts.sort { precedes($0.modifiedAt, $1.modifiedAt, $0.name, $1.name) }
        }
    }
}

enum DirectoryLister {
    /// 파일 하나의 정보 (위치 종류와 상관없이 같은 형태로 모은다)
    struct Item {
        let url: URL
        let isDirectory: Bool
        let size: Int64
        let modifiedAt: Date
    }

    static func list(_ route: FolderRoute) async throws -> DirectoryListing {
        let items = try await items(in: route.url, serverID: route.serverID)

        let siblings = items.filter { !$0.isDirectory }.map(\.url)
        var listing = DirectoryListing()
        for item in items where !item.url.lastPathComponent.hasPrefix(".") {
            if item.isDirectory {
                listing.folders.append(FolderRoute(url: item.url, title: item.url.lastPathComponent, serverID: route.serverID))
                listing.folderDates[item.url] = item.modifiedAt
            } else if VideoFile.isVideo(item.url) {
                listing.videos.append(VideoFile(
                    url: item.url,
                    size: item.size,
                    modifiedAt: item.modifiedAt,
                    subtitles: SubtitleLoader.sidecars(for: item.url, in: siblings),
                    serverID: route.serverID
                ))
            } else if VideoFile.isArchive(item.url) {
                listing.archives.append(VideoFile(url: item.url, size: item.size, modifiedAt: item.modifiedAt, serverID: route.serverID))
            } else if TextBook.isText(item.url) {
                listing.texts.append(VideoFile(url: item.url, size: item.size, modifiedAt: item.modifiedAt, serverID: route.serverID))
            }
        }
        // 라이브러리에 든 파일은 해시를 붙인다 (이어보기를 라이브러리와 같이 쓴다)
        let hashes = LibraryData.hashes(for: listing.videos.map { ($0.url, $0.size) }, serverID: route.serverID)
        for index in listing.videos.indices {
            listing.videos[index].hash = hashes[listing.videos[index].url]
        }
        listing.sort(by: .name)
        return listing
    }

    /// 폴더 안의 모든 파일·폴더 (정렬 안 함). 파일 관리·압축 풀기에서도 쓴다.
    static func items(in url: URL, serverID: UUID?) async throws -> [Item] {
        let items: [Item]
        switch url.scheme {
        case "file":
            items = try listLocal(url)
        case "http", "https":
            items = try await WebDAVClient.list(url, serverID: serverID).map {
                Item(url: $0.url, isDirectory: $0.isDirectory, size: $0.size, modifiedAt: $0.modifiedAt)
            }
        case "smb":
            items = try await SMBClient.shared.list(url, serverID: serverID).map {
                Item(url: $0.url, isDirectory: $0.isDirectory, size: $0.size, modifiedAt: $0.modifiedAt)
            }
        default:
            throw RemoteAccess.AccessError.unsupported
        }
        return items
    }

    private static func listLocal(_ directory: URL) throws -> [Item] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey]
        return try FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]
        ).map { url in
            let values = try? url.resourceValues(forKeys: Set(keys))
            return Item(
                url: url,
                isDirectory: values?.isDirectory == true,
                size: Int64(values?.fileSize ?? 0),
                modifiedAt: values?.contentModificationDate ?? .distantPast
            )
        }
    }
}
