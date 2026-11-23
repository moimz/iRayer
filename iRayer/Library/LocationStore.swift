import Foundation
import Observation

/// 사용자가 추가한 내부 폴더 위치
struct FolderLocation: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String
    var bookmark: Data
    /// 사용자가 고른 아이콘 (SF Symbol 이름, 없으면 폴더)
    var icon: String?

    var symbol: String { icon ?? "folder" }
}

/// 사용자가 등록한 네트워크 서버 (비밀번호는 키체인에 따로 저장)
struct NetworkServer: Identifiable, Codable, Hashable {
    enum Kind: String, Codable, CaseIterable {
        case webdav, smb

        var title: String {
            switch self {
            case .webdav: "WebDAV"
            case .smb: "SMB"
            }
        }
    }

    var id = UUID()
    var kind: Kind
    var name: String
    /// WebDAV: http(s)://주소:포트/경로, SMB: 주소/공유폴더
    var address: String
    var username: String

    /// 서버의 최상위 위치
    var rootURL: URL? {
        let trimmed = address.trimmingCharacters(in: .whitespaces)
        switch kind {
        case .webdav:
            let withScheme = trimmed.contains("://") ? trimmed : "http://\(trimmed)"
            guard var components = URLComponents(string: withScheme) else { return nil }
            if !components.path.hasSuffix("/") { components.path += "/" }
            return components.url
        case .smb:
            let path = trimmed.replacingOccurrences(of: "smb://", with: "")
            return URL(string: "smb://\(path.hasSuffix("/") ? path : path + "/")")
        }
    }
}

/// 탐색 목록의 항목 (편집 모드에서 여러 개를 고를 때 쓴다)
enum LocationID: Hashable {
    case folder(UUID)
    case server(UUID)
    case favorite(UUID)
}

/// 서버 안의 즐겨찾기 폴더 (탐색에서 그 서버 아래에 바로 보인다)
struct ServerFavorite: Identifiable, Codable, Hashable {
    var id = UUID()
    let serverID: UUID
    let url: URL
    var name: String
    /// 사용자가 고른 아이콘 (SF Symbol 이름, 없으면 폴더)
    var icon: String?

    var symbol: String { icon ?? "folder" }

    /// 서버 맨 위에서 이 폴더까지의 경로 (이름 아래 작게)
    func path(in server: NetworkServer) -> String {
        let root = server.rootURL?.path(percentEncoded: false) ?? ""
        var path = url.path(percentEncoded: false)
        if path.hasPrefix(root) { path.removeFirst(root.count) }
        return path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }
}

/// 폴더 구역에 추가한 폴더 하나: 이 기기, 이 기기의 폴더, 저장소 안 폴더.
/// 폴더 설정(보기·홈·검색·숨김)은 여기에만 두고, 그 하위 폴더는 모두 이 설정을 따른다. 경로도 여기가 맨 위.
enum AddedFolder: Hashable, Identifiable {
    case thisDevice
    case folder(FolderLocation)
    case favorite(ServerFavorite)

    var id: String {
        switch self {
        case .thisDevice: "device"
        case .folder(let folder): "f" + folder.id.uuidString
        case .favorite(let favorite): "v" + favorite.id.uuidString
        }
    }

    var name: String {
        switch self {
        case .thisDevice: LocationStore.thisDeviceName
        case .folder(let folder): folder.name
        case .favorite(let favorite): favorite.name
        }
    }

    var icon: String? {
        switch self {
        case .thisDevice: nil
        case .folder(let folder): folder.icon
        case .favorite(let favorite): favorite.icon
        }
    }

    var symbol: String {
        if case .thisDevice = self { return LocationStore.thisDeviceIcon }
        return icon ?? "folder"
    }

    var serverID: UUID? {
        if case .favorite(let favorite) = self { return favorite.serverID }
        return nil
    }
}

/// 서버 접속 정보
struct ServerCredential {
    let username: String
    let password: String
}

/// 탐색 위치 목록: 이 기기 + 사용자가 추가한 폴더 + 네트워크 서버
@Observable
final class LocationStore {
    static let shared = LocationStore()

    private(set) var folders: [FolderLocation] = []
    fileprivate(set) var servers: [NetworkServer] = []
    fileprivate(set) var favorites: [ServerFavorite] = []

    /// 보안 범위 접근을 시작한 폴더 URL (앱이 실행되는 동안 유지)
    @ObservationIgnored private var accessed: [UUID: URL] = [:]

    private let foldersKey = "folderLocations"
    private let serversKey = "networkServers"
    private let favoritesKey = "serverFavorites"

    private init() {
        let defaults = UserDefaults.standard
        if let data = defaults.data(forKey: foldersKey),
           let decoded = try? JSONDecoder().decode([FolderLocation].self, from: data) {
            folders = decoded
        }
        if let data = defaults.data(forKey: serversKey),
           let decoded = try? JSONDecoder().decode([NetworkServer].self, from: data) {
            servers = decoded
        }
        if let data = defaults.data(forKey: favoritesKey),
           let decoded = try? JSONDecoder().decode([ServerFavorite].self, from: data) {
            favorites = decoded
        }
    }

    /// 파일 앱의 "나의 iPhone > iRayer" 에 보이는 앱 문서 폴더
    /// 이 기기 폴더의 이름과 아이콘 (맥은 사용자의 동영상 폴더)
    #if os(macOS)
    static let thisDeviceName = "동영상"
    static let thisDeviceIcon = "film"
    #else
    static let thisDeviceName = "이 기기"
    static let thisDeviceIcon = "iphone"
    #endif

    #if os(macOS)
    /// 맥은 사용자의 동영상 폴더 (영상을 두는 표준 위치, 접근 권한 창도 뜨지 않는다)
    var documentsURL: URL { URL.moviesDirectory }
    #else
    var documentsURL: URL { URL.documentsDirectory }
    #endif

    // MARK: - 폴더

    /// 폴더 선택기에서 고른 폴더를 위치로 추가 (이름이 없으면 폴더 이름)
    @discardableResult
    func addFolder(_ url: URL, name: String? = nil, icon: String? = nil) throws -> FolderLocation {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let bookmark = try url.bookmarkData()
        let folder = FolderLocation(name: name ?? url.lastPathComponent, bookmark: bookmark, icon: icon)
        folders.append(folder)
        save()
        return folder
    }

    func remove(_ location: FolderLocation) {
        if let url = accessed.removeValue(forKey: location.id) {
            url.stopAccessingSecurityScopedResource()
        }
        folders.removeAll { $0.id == location.id }
        save()
    }

    func update(_ location: FolderLocation, name: String, icon: String?) {
        guard let index = folders.firstIndex(where: { $0.id == location.id }) else { return }
        folders[index].name = name
        folders[index].icon = icon
        save()
    }

    /// 북마크를 실제 URL 로 풀고 접근 권한을 연다
    func resolve(_ location: FolderLocation) -> URL? {
        if let url = accessed[location.id] { return url }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: location.bookmark, bookmarkDataIsStale: &stale) else {
            return nil
        }
        _ = url.startAccessingSecurityScopedResource()
        accessed[location.id] = url
        if stale, let fresh = try? url.bookmarkData(),
           let index = folders.firstIndex(where: { $0.id == location.id }) {
            folders[index].bookmark = fresh
            save()
        }
        return url
    }

    // MARK: - 네트워크 서버

    /// 서버 추가 또는 수정. 비밀번호가 nil 이면 기존 비밀번호를 유지한다.
    func saveServer(_ server: NetworkServer, password: String?) {
        if let index = servers.firstIndex(where: { $0.id == server.id }) {
            servers[index] = server
        } else {
            servers.append(server)
        }
        if let password {
            Keychain.setPassword(password, for: server.id.uuidString)
        }
        save()
    }

    func remove(_ server: NetworkServer) {
        Keychain.deletePassword(for: server.id.uuidString)
        servers.removeAll { $0.id == server.id }
        favorites.removeAll { $0.serverID == server.id }
        save()
    }

    /// 서버의 접속 정보. 탐색을 시작한 서버를 폴더·영상 정보에 함께 들고 다니므로 서버 ID 로 찾는다.
    /// (주소만으로 고르면 같은 NAS 에 계정을 달리해 등록한 서버끼리 헷갈린다)
    func credential(for serverID: UUID?) -> ServerCredential? {
        guard let serverID, let server = servers.first(where: { $0.id == serverID }) else { return nil }
        return ServerCredential(username: server.username, password: Keychain.password(for: server.id.uuidString) ?? "")
    }

    // MARK: - 서버 안 즐겨찾기

    func favorites(of serverID: UUID) -> [ServerFavorite] {
        favorites.filter { $0.serverID == serverID }
    }

    func favorite(_ url: URL, serverID: UUID?) -> ServerFavorite? {
        guard let serverID else { return nil }
        let key = FolderOptionsStore.key(url, serverID: serverID)
        return favorites.first { $0.serverID == serverID && FolderOptionsStore.key($0.url, serverID: serverID) == key }
    }

    @discardableResult
    func addFavorite(_ url: URL, name: String, icon: String? = nil, serverID: UUID) -> ServerFavorite {
        if let existing = favorite(url, serverID: serverID) { return existing }
        let favorite = ServerFavorite(serverID: serverID, url: url, name: name, icon: icon)
        favorites.append(favorite)
        save()
        return favorite
    }

    func remove(_ favorite: ServerFavorite) {
        favorites.removeAll { $0.id == favorite.id }
        save()
    }

    func update(_ favorite: ServerFavorite, name: String, icon: String?) {
        guard let index = favorites.firstIndex(where: { $0.id == favorite.id }) else { return }
        favorites[index].name = name
        favorites[index].icon = icon
        save()
    }

    // MARK: - 추가한 폴더

    /// 추가한 폴더 모두 (이 기기 → 이 기기의 폴더 → 저장소 안 폴더, 설정 목록 순서)
    var addedFolders: [AddedFolder] {
        [.thisDevice] + folders.map(AddedFolder.folder) + servers.flatMap { favorites(of: $0.id).map(AddedFolder.favorite) }
    }

    /// 추가한 폴더의 주소 (이 기기 폴더는 북마크를 풀어서)
    func url(of added: AddedFolder) -> URL? {
        switch added {
        case .thisDevice: documentsURL
        case .folder(let folder): resolve(folder)
        case .favorite(let favorite): favorite.url
        }
    }

    /// 추가한 폴더를 여는 화면 주소
    func route(of added: AddedFolder) -> FolderRoute? {
        guard let url = url(of: added) else { return nil }
        switch added {
        case .thisDevice: return FolderRoute(url: url, title: added.name)
        case .folder(let folder): return FolderRoute(url: url, title: folder.name, location: .folder(folder.id))
        case .favorite(let favorite): return FolderRoute(url: url, title: favorite.name, serverID: favorite.serverID, location: .favorite(favorite.id))
        }
    }

    /// 이 폴더가 들어 있는 추가한 폴더와 그 주소 (겹치면 가장 안쪽 것)
    func addedFolder(containing url: URL, serverID: UUID?) -> (folder: AddedFolder, url: URL)? {
        var best: (folder: AddedFolder, url: URL, length: Int)?
        for added in addedFolders where added.serverID == serverID {
            guard let base = self.url(of: added), FolderOptionsStore.isInside(url, base) else { continue }
            let length = FolderOptionsStore.key(base, serverID: nil).count
            if length > best?.length ?? -1 { best = (added, base, length) }
        }
        return best.map { ($0.folder, $0.url) }
    }

    /// 지금 정보로 다시 찾는다 (이름·아이콘을 바꾼 뒤, 지웠으면 nil)
    func refreshed(_ added: AddedFolder) -> AddedFolder? {
        switch added {
        case .thisDevice: .thisDevice
        case .folder(let folder): folders.first { $0.id == folder.id }.map(AddedFolder.folder)
        case .favorite(let favorite): favorites.first { $0.id == favorite.id }.map(AddedFolder.favorite)
        }
    }

    func update(_ added: AddedFolder, name: String, icon: String?) {
        switch added {
        case .thisDevice: break
        case .folder(let folder): update(folder, name: name, icon: icon)
        case .favorite(let favorite): update(favorite, name: name, icon: icon)
        }
    }

    // MARK: - 편집

    func remove(_ ids: Set<LocationID>) {
        for id in ids {
            switch id {
            case .folder(let id): folders.first { $0.id == id }.map(remove)
            case .server(let id): servers.first { $0.id == id }.map(remove)
            case .favorite(let id): favorites.first { $0.id == id }.map(remove)
            }
        }
    }

    func moveFolders(from source: IndexSet, to destination: Int) {
        folders.move(fromOffsets: source, toOffset: destination)
        save()
    }

    /// 서버 순서를 id 순서대로 (즐겨찾기 줄이 섞인 목록에서 옮긴 결과)
    func setServerOrder(_ ids: [UUID]) {
        servers = ids.compactMap { id in servers.first { $0.id == id } }
        save()
    }

    /// 한 저장소 안 즐겨찾기 폴더의 순서 바꾸기
    func moveFavorites(of serverID: UUID, from source: IndexSet, to destination: Int) {
        var mine = favorites(of: serverID)
        mine.move(fromOffsets: source, toOffset: destination)
        favorites = favorites.filter { $0.serverID != serverID } + mine
        save()
    }

    func moveServers(from source: IndexSet, to destination: Int) {
        servers.move(fromOffsets: source, toOffset: destination)
        save()
    }

    fileprivate func save() {
        let defaults = UserDefaults.standard
        if let data = try? JSONEncoder().encode(folders) {
            defaults.set(data, forKey: foldersKey)
        }
        if let data = try? JSONEncoder().encode(servers) {
            defaults.set(data, forKey: serversKey)
        }
        if let data = try? JSONEncoder().encode(favorites) {
            defaults.set(data, forKey: favoritesKey)
        }
        // 지금 순서가 기준 (예전에 받은 다른 기기 순서로 다시 섞이지 않게)
        Self.receivedOrders = orders
        // 이 기기 폴더(북마크)는 기기 전용이라 동기화하지 않는다
        for kind in [Self.serverKind, Self.favoriteKind, Self.orderKind] { SyncEngine.shared.publish(kind) }
    }
}

// MARK: - 동기화

extension LocationStore {
    static let serverKind = "server"
    static let favoriteKind = "favorite"
    /// 목록 순서 (항목 하나: 목록 이름 → id 순서)
    static let orderKind = "locationOrder"

    /// 지금 목록들의 순서
    fileprivate var orders: [String: [String]] {
        [
            "servers": servers.map(\.id.uuidString),
            "favorites": favorites.map(\.id.uuidString),
        ]
    }

    /// 받은 순서대로 늘어놓는다 (순서에 없는 항목은 뒤에, 원래 순서대로)
    fileprivate static func ordered<Item>(_ items: [Item], by ids: [String]?, id: (Item) -> String) -> [Item] {
        guard let ids else { return items }
        let rank = Dictionary(ids.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        return items.enumerated().sorted { lhs, rhs in
            (rank[id(lhs.element)] ?? Int.max, lhs.offset) < (rank[id(rhs.element)] ?? Int.max, rhs.offset)
        }.map(\.element)
    }

    /// 마지막으로 받은 순서 (항목이 순서보다 늦게 도착해도 그 자리에 놓으려고)
    fileprivate static var receivedOrders: [String: [String]] {
        get { (UserDefaults.standard.dictionary(forKey: "locationOrders") as? [String: [String]]) ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: "locationOrders") }
    }

    /// 서버 목록·서버 즐겨찾기. 서버 비밀번호는 iCloud 키체인이 따로 동기화한다.
    /// 받은 새 항목은 목록 끝에 붙인다 (순서는 기기마다).
    var syncKinds: [SyncEngine.Kind] {
        [
            Self.listKind(Self.serverKind, items: { [unowned self] in servers }, id: { $0.id.uuidString }) { [unowned self] in
                servers = Self.ordered($0, by: Self.receivedOrders["servers"]) { $0.id.uuidString }
                save()
            },
            Self.listKind(Self.favoriteKind, items: { [unowned self] in favorites }, id: { $0.id.uuidString }) { [unowned self] in
                favorites = Self.ordered($0, by: Self.receivedOrders["favorites"]) { $0.id.uuidString }
                save()
            },
            SyncEngine.Kind(name: Self.orderKind) {
                ["servers", "favorites"]
            } payload: { [unowned self] key in
                orders[key].flatMap { try? syncEncoder.encode($0) }
            } apply: { [unowned self] key, data in
                guard let ids = try? JSONDecoder().decode([String].self, from: data) else { return false }
                Self.receivedOrders[key] = ids
                switch key {
                case "servers": servers = Self.ordered(servers, by: ids) { $0.id.uuidString }
                case "favorites": favorites = Self.ordered(favorites, by: ids) { $0.id.uuidString }
                default: return true
                }
                save()
                return true
            } delete: { _ in },
        ]
    }

    private static func listKind<Item: Codable>(_ name: String, items: @escaping () -> [Item], id: @escaping (Item) -> String,
                                                set: @escaping ([Item]) -> Void) -> SyncEngine.Kind {
        SyncEngine.Kind(name: name) {
            items().map(id)
        } payload: { key in
            items().first { id($0) == key }.flatMap { try? syncEncoder.encode($0) }
        } apply: { key, data in
            guard let item = try? JSONDecoder().decode(Item.self, from: data) else { return false }
            var list = items()
            if let index = list.firstIndex(where: { id($0) == key }) { list[index] = item } else { list.append(item) }
            set(list)
            return true
        } delete: { key in
            set(items().filter { id($0) != key })
        }
    }
}

// MARK: - 성인 등급 숨기기

extension LocationStore {
    /// 사이드바·바로가기에 보일 이 기기 폴더 (성인 등급 숨기기 중에 "숨김"을 켰으면 뺀다)
    var showsThisDevice: Bool {
        !FolderOptionsStore.shared.isHiddenForAdult(documentsURL, serverID: nil)
    }

    /// 사이드바·바로가기에 보일 폴더
    var shownFolders: [FolderLocation] {
        guard AdultFilter.shared.isOn else { return folders }
        return folders.filter { folder in resolve(folder).map { !FolderOptionsStore.shared.isHiddenForAdult($0, serverID: nil) } ?? true }
    }

    /// 사이드바·바로가기에 보일 저장소 안 즐겨찾기 폴더
    func shownFavorites(of serverID: UUID) -> [ServerFavorite] {
        favorites(of: serverID).filter { !FolderOptionsStore.shared.isHiddenForAdult($0.url, serverID: serverID) }
    }
}
