import Foundation
import AMSMB2

/// SMB 폴더 목록 조회와 작은 파일 읽기 (AMSMB2)
/// 주소 형식: smb://주소/공유폴더/경로/. 공유 폴더 없이 smb://주소/ 만 주면 공유 폴더 목록을 폴더처럼 보여준다.
actor SMBClient {
    static let shared = SMBClient()

    struct Entry {
        let url: URL
        let isDirectory: Bool
        let size: Int64
        let modifiedAt: Date
    }

    /// 서버·공유 폴더별로 연결을 재사용한다 (폴더를 옮길 때마다 로그인하지 않도록)
    private var connections: [String: SMB2Manager] = [:]
    /// 열어 둔 연결 수 (재생 화면 디버그 정보, 2026-11-28)
    var connectionCount: Int { connections.count }

    func list(_ directory: URL, serverID: UUID?) async throws -> [Entry] {
        let (share, path) = Self.split(directory)
        guard let share else {
            let manager = try manager(for: directory, serverID: serverID)
            let shares = try await Self.mapped(connecting: true) { try await manager.listShares() }
            return shares.map { share in
                Entry(url: directory.appending(path: share.name, directoryHint: .isDirectory),
                      isDirectory: true, size: 0, modifiedAt: .distantPast)
            }
        }

        let manager = try await connected(directory, share: share, serverID: serverID)
        let items = try await Self.mapped { try await manager.contentsOfDirectory(atPath: path) }
        return items.compactMap { item in
            guard let name = item[.nameKey] as? String, name != ".", name != ".." else { return nil }
            let isDirectory = item[.isDirectoryKey] as? Bool ?? false
            return Entry(
                url: directory.appending(path: name, directoryHint: isDirectory ? .isDirectory : .notDirectory),
                isDirectory: isDirectory,
                size: (item[.fileSizeKey] as? NSNumber)?.int64Value ?? 0,
                modifiedAt: item[.contentModificationDateKey] as? Date ?? .distantPast
            )
        }
    }

    /// 파일의 일부 읽기 (AirPlay 중계 서버가 TV 에 조금씩 보낼 때)
    func read(_ url: URL, range: Range<Int64>, serverID: UUID?) async throws -> Data {
        let (share, path) = Self.split(url)
        guard let share else { throw RemoteAccess.AccessError.unsupported }
        let manager = try await connected(url, share: share, serverID: serverID)
        return try await Self.mapped { try await manager.contents(atPath: path, range: range) }
    }

    /// 작은 파일(자막 등) 전체 읽기
    func data(of url: URL, serverID: UUID?) async throws -> Data {
        let (share, path) = Self.split(url)
        guard let share else { throw RemoteAccess.AccessError.unsupported }
        let manager = try await connected(url, share: share, serverID: serverID)
        return try await Self.mapped { try await manager.contents(atPath: path) }
    }

    // MARK: - 쓰기 (파일 관리·압축 풀기)

    /// 파일의 offset 위치에 이어 쓴다 (offset 0 이면 새로 만든다). 뒤에 있던 내용은 잘린다.
    func write(_ data: Data, to url: URL, offset: Int64, serverID: UUID?) async throws {
        let (share, path) = Self.split(url)
        guard let share else { throw RemoteAccess.AccessError.unsupported }
        let manager = try await connected(url, share: share, serverID: serverID)
        try await Self.mapped { try await manager.append(data: data, toPath: path, offset: offset, progress: nil) }
    }

    func createDirectory(_ url: URL, serverID: UUID?) async throws {
        let (share, path) = Self.split(url)
        guard let share else { throw RemoteAccess.AccessError.unsupported }
        let manager = try await connected(url, share: share, serverID: serverID)
        try await Self.mapped { try await manager.createDirectory(atPath: path) }
    }

    /// 파일 또는 폴더(안의 내용까지) 삭제
    func remove(_ url: URL, serverID: UUID?) async throws {
        let (share, path) = Self.split(url)
        guard let share else { throw RemoteAccess.AccessError.unsupported }
        let manager = try await connected(url, share: share, serverID: serverID)
        try await Self.mapped { try await manager.removeItem(atPath: path) }
    }

    /// 같은 공유 폴더 안에서 옮기기·이름 바꾸기
    func move(_ url: URL, to destination: URL, serverID: UUID?) async throws {
        let (share, path) = Self.split(url)
        let (destinationShare, destinationPath) = Self.split(destination)
        guard let share, share == destinationShare else { throw RemoteAccess.AccessError.unsupported }
        let manager = try await connected(url, share: share, serverID: serverID)
        try await Self.mapped { try await manager.moveItem(atPath: path, toPath: destinationPath) }
    }

    /// 같은 공유 폴더 안에서 복사 (서버가 직접 복사한다). progress: 지금까지 복사한 바이트
    func copy(_ url: URL, to destination: URL, serverID: UUID?, progress: @escaping @Sendable (Int64) -> Bool) async throws {
        let (share, path) = Self.split(url)
        let (destinationShare, destinationPath) = Self.split(destination)
        guard let share, share == destinationShare else { throw RemoteAccess.AccessError.unsupported }
        let manager = try await connected(url, share: share, serverID: serverID)
        try await Self.mapped {
            try await manager.copyItem(atPath: path, toPath: destinationPath, recursive: true) { bytes, _ in progress(bytes) }
        }
    }

    /// 있으면 그 정보 (폴더인지, 크기), 없으면 nil
    func item(at url: URL, serverID: UUID?) async throws -> (isDirectory: Bool, size: Int64)? {
        let (share, path) = Self.split(url)
        guard let share else { return (true, 0) }
        let manager = try await connected(url, share: share, serverID: serverID)
        do {
            let attributes = try await manager.attributesOfItem(atPath: path)
            let isDirectory = (attributes[.isDirectoryKey] as? NSNumber)?.boolValue ?? false
            return (isDirectory, (attributes[.fileSizeKey] as? NSNumber)?.int64Value ?? 0)
        } catch let error as POSIXError where error.code == .ENOENT {
            return nil
        }
    }

    /// 같은 공유 폴더인지 (서버가 직접 옮기거나 복사할 수 있는지)
    nonisolated static func sameShare(_ lhs: URL, _ rhs: URL) -> Bool {
        lhs.host() == rhs.host() && lhs.port == rhs.port && split(lhs).share != nil && split(lhs).share == split(rhs).share
    }

    // MARK: - 연결

    private func manager(for url: URL, serverID: UUID?) throws -> SMB2Manager {
        let key = "\(serverID?.uuidString ?? "-")|\(url.host() ?? "")"
        if let manager = connections[key] { return manager }
        guard let manager = Self.makeManager(url, serverID: serverID) else {
            throw RemoteAccess.AccessError.unsupported
        }
        connections[key] = manager
        return manager
    }

    private func connected(_ url: URL, share: String, serverID: UUID?) async throws -> SMB2Manager {
        let key = "\(serverID?.uuidString ?? "-")|\(url.host() ?? "")|\(share)"
        if let manager = connections[key] { return manager }
        guard let manager = Self.makeManager(url, serverID: serverID) else {
            throw RemoteAccess.AccessError.unsupported
        }
        try await Self.mapped(connecting: true) { try await manager.connectShare(name: share) }
        connections[key] = manager
        return manager
    }

    /// 연결이 끊긴 뒤 다시 시도할 수 있도록 저장된 연결을 버린다
    func reset() {
        connections.removeAll()
    }

    private static func makeManager(_ url: URL, serverID: UUID?) -> SMB2Manager? {
        var components = URLComponents()
        components.scheme = "smb"
        components.host = url.host()
        components.port = url.port
        guard let serverURL = components.url else { return nil }
        let credential = LocationStore.shared.credential(for: serverID).map {
            URLCredential(user: $0.username, password: $0.password, persistence: .forSession)
        }
        let manager = SMB2Manager(url: serverURL, credential: credential)
        manager?.timeout = 15
        return manager
    }

    /// smb://주소/공유폴더/경로 → (공유폴더, 경로)
    nonisolated private static func split(_ url: URL) -> (share: String?, path: String) {
        let components = url.path(percentEncoded: false).split(separator: "/").map(String.init)
        guard let share = components.first else { return (nil, "/") }
        return (share, "/" + components.dropFirst().joined(separator: "/"))
    }

    /// libsmb2 오류를 앱 오류로 바꾼다. 연결·인증 오류가 나면 저장된 연결을 버린다.
    /// - 로그인 실패는 NT 상태 이름(LOGON_FAILURE 등)이 설명에 들어오고, errno 는 ECONNREFUSED 로 온다.
    /// - 접속 자체가 안 되면 설명 없이 EPERM(-1) 으로 온다.
    private static func mapped<T>(connecting: Bool = false, _ operation: () async throws -> T) async throws -> T {
        do {
            return try await operation()
        } catch let error as POSIXError {
            let description = error.localizedDescription.uppercased()
            let loginFailed = ["LOGON_FAILURE", "WRONG_PASSWORD", "ACCESS_DENIED", "ACCOUNT_"].contains { description.contains($0) }
            if loginFailed || [.EACCES, .EAUTH, .ENEEDAUTH].contains(error.code) {
                await shared.reset()
                throw RemoteAccess.AccessError.unauthorized
            }
            let network: [POSIXError.Code] = [.ENOTCONN, .ECONNRESET, .ECONNREFUSED, .ETIMEDOUT, .EPIPE, .EHOSTUNREACH, .ENETUNREACH, .EHOSTDOWN]
            if network.contains(error.code) || (connecting && error.code == .EPERM) {
                await shared.reset()
                throw RemoteAccess.AccessError.unreachable
            }
            throw error
        }
    }
}
