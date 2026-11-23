import Foundation

/// 파일 관리에서 다루는 파일·폴더 하나 (이 기기·연결한 폴더 / WebDAV / SMB)
struct FileItem: Hashable, Identifiable {
    let url: URL
    /// 네트워크 서버 안이면 그 서버
    let serverID: UUID?
    let isDirectory: Bool
    var size: Int64 = 0

    var id: URL { url }
    var name: String { url.lastPathComponent }

    /// 같은 폴더 안의 다른 이름
    func renamed(_ name: String) -> FileItem {
        FileItem(url: url.deletingLastPathComponent().appending(path: name, directoryHint: isDirectory ? .isDirectory : .notDirectory),
                 serverID: serverID, isDirectory: isDirectory, size: size)
    }

    /// 이 폴더 안의 항목
    func child(_ name: String, isDirectory: Bool, size: Int64 = 0) -> FileItem {
        FileItem(url: url.appending(path: name, directoryHint: isDirectory ? .isDirectory : .notDirectory),
                 serverID: serverID, isDirectory: isDirectory, size: size)
    }
}

/// 위치 종류와 상관없이 파일을 읽고 쓰고 옮기는 기능
enum FileOperations {
    enum OperationError: LocalizedError {
        case alreadyExists(String)
        case cancelled

        var errorDescription: String? {
            switch self {
            case .alreadyExists(let name): "같은 이름이 이미 있습니다: \(name)"
            case .cancelled: "취소했습니다."
            }
        }
    }

    // MARK: - 읽기

    /// 파일의 일부 읽기
    @concurrent
    static func read(_ url: URL, range: Range<Int64>, serverID: UUID?) async throws -> Data {
        switch url.scheme {
        case "file":
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            try handle.seek(toOffset: UInt64(range.lowerBound))
            return try handle.read(upToCount: range.count) ?? Data()
        case "http", "https":
            return try await WebDAVClient.read(url, range: range, serverID: serverID)
        case "smb":
            return try await SMBClient.shared.read(url, range: range, serverID: serverID)
        default:
            throw RemoteAccess.AccessError.unsupported
        }
    }

    /// 있으면 그 정보, 없으면 nil
    static func item(at url: URL, serverID: UUID?) async throws -> FileItem? {
        switch url.scheme {
        case "file":
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false), isDirectory: &isDirectory) else { return nil }
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap { $0 } ?? 0
            return FileItem(url: url, serverID: serverID, isDirectory: isDirectory.boolValue, size: Int64(size))
        case "http", "https":
            guard let found = try await WebDAVClient.item(at: url, serverID: serverID) else { return nil }
            return FileItem(url: url, serverID: serverID, isDirectory: found.isDirectory, size: found.size)
        case "smb":
            guard let found = try await SMBClient.shared.item(at: url, serverID: serverID) else { return nil }
            return FileItem(url: url, serverID: serverID, isDirectory: found.isDirectory, size: found.size)
        default:
            throw RemoteAccess.AccessError.unsupported
        }
    }

    /// 폴더 안의 항목 (숨김 파일 제외)
    static func children(of folder: FileItem) async throws -> [FileItem] {
        try await DirectoryLister.items(in: folder.url, serverID: folder.serverID)
            .filter { !$0.url.lastPathComponent.hasPrefix(".") }
            .map { FileItem(url: $0.url, serverID: folder.serverID, isDirectory: $0.isDirectory, size: $0.size) }
    }

    // MARK: - 쓰기

    static func createDirectory(_ url: URL, serverID: UUID?) async throws {
        switch url.scheme {
        case "file":
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        case "http", "https":
            try await WebDAVClient.createDirectory(url, serverID: serverID)
        case "smb":
            try await SMBClient.shared.createDirectory(url, serverID: serverID)
        default:
            throw RemoteAccess.AccessError.unsupported
        }
    }

    /// 파일 또는 폴더(안의 내용까지) 삭제
    static func remove(_ item: FileItem) async throws {
        switch item.url.scheme {
        case "file":
            try FileManager.default.removeItem(at: item.url)
        case "http", "https":
            try await WebDAVClient.remove(item.isDirectory ? WebDAVClient.directoryURL(item.url) : item.url, serverID: item.serverID)
        case "smb":
            try await SMBClient.shared.remove(item.url, serverID: item.serverID)
        default:
            throw RemoteAccess.AccessError.unsupported
        }
    }

    /// 같은 폴더 안에서 이름 바꾸기
    static func rename(_ item: FileItem, to name: String) async throws {
        let target = item.renamed(name)
        if try await self.item(at: target.url, serverID: item.serverID) != nil {
            throw OperationError.alreadyExists(name)
        }
        guard try await moveOnServer(item, to: target.url) else { throw RemoteAccess.AccessError.unsupported }
    }

    /// 서버가 직접 옮길 수 있으면 옮기고 true (같은 기기 안, 같은 WebDAV 서버, 같은 SMB 공유 폴더)
    static func moveOnServer(_ item: FileItem, to destination: URL) async throws -> Bool {
        switch (item.url.scheme, destination.scheme) {
        case ("file", "file"):
            try FileManager.default.moveItem(at: item.url, to: destination)
        case ("http", "http"), ("https", "https"):
            guard WebDAVClient.sameServer(item.url, destination) else { return false }
            try await WebDAVClient.transfer(item.url, to: destination, isDirectory: item.isDirectory, copy: false, overwrite: false, serverID: item.serverID)
        case ("smb", "smb"):
            guard SMBClient.sameShare(item.url, destination) else { return false }
            try await SMBClient.shared.move(item.url, to: destination, serverID: item.serverID)
        default:
            return false
        }
        return true
    }

    /// 서버가 직접 복사할 수 있으면 복사하고 true. progress: 지금까지 복사한 바이트 (서버가 알려 주지 않으면 끝날 때 한 번)
    static func copyOnServer(_ item: FileItem, to destination: URL, progress: @escaping @Sendable (Int64) -> Bool) async throws -> Bool {
        switch (item.url.scheme, destination.scheme) {
        case ("file", "file"):
            try await copyLocal(item.url, to: destination)
        case ("http", "http"), ("https", "https"):
            guard WebDAVClient.sameServer(item.url, destination) else { return false }
            try await WebDAVClient.transfer(item.url, to: destination, isDirectory: item.isDirectory, copy: true, overwrite: false, serverID: item.serverID)
        case ("smb", "smb"):
            guard SMBClient.sameShare(item.url, destination) else { return false }
            try await SMBClient.shared.copy(item.url, to: destination, serverID: item.serverID, progress: progress)
        default:
            return false
        }
        return true
    }

    @concurrent
    private static func copyLocal(_ url: URL, to destination: URL) async throws {
        try FileManager.default.copyItem(at: url, to: destination)
    }

    /// 새 파일에 차례로 써 넣는 쓰개. length 는 전체 크기 (WebDAV 는 미리 알려야 한다).
    static func writer(for url: URL, serverID: UUID?, length: Int64) throws -> FileWriter {
        switch url.scheme {
        case "file": try LocalFileWriter(url: url)
        case "http", "https": WebDAVFileWriter(url: url, serverID: serverID, length: length)
        case "smb": SMBFileWriter(url: url, serverID: serverID)
        default: throw RemoteAccess.AccessError.unsupported
        }
    }

    /// 파일 하나를 조금씩 읽어 다른 곳에 쓴다 (위치가 서로 다를 때). progress: 이번에 더 옮긴 바이트, false 면 멈춤.
    static func copyFile(_ item: FileItem, to destination: URL, destinationServerID: UUID?,
                         progress: (Int64) -> Bool) async throws {
        let chunk: Int64 = 4 << 20
        let writer = try writer(for: destination, serverID: destinationServerID, length: item.size)
        do {
            var offset: Int64 = 0
            while offset < item.size {
                let end = min(offset + chunk, item.size)
                let data = try await read(item.url, range: offset..<end, serverID: item.serverID)
                guard !data.isEmpty else { break }
                try await writer.write(data)
                offset += Int64(data.count)
                guard progress(Int64(data.count)), !Task.isCancelled else { throw OperationError.cancelled }
            }
            try await writer.finish()
        } catch {
            await writer.abort()
            throw error
        }
    }

    /// 같은 이름이 있으면 "이름 (2)", "이름 (3)" … 처럼 비어 있는 이름
    static func availableName(_ name: String, in folder: FileItem, isDirectory: Bool) async throws -> String {
        let base = isDirectory ? name : (name as NSString).deletingPathExtension
        let ext = isDirectory ? "" : (name as NSString).pathExtension
        var candidate = name
        var number = 2
        while try await item(at: folder.child(candidate, isDirectory: isDirectory).url, serverID: folder.serverID) != nil {
            candidate = ext.isEmpty ? "\(base) (\(number))" : "\(base) (\(number)).\(ext)"
            number += 1
        }
        return candidate
    }
}

/// 새 파일에 앞에서부터 차례로 써 넣는다
protocol FileWriter {
    func write(_ data: Data) async throws
    /// 다 썼다
    func finish() async throws
    /// 실패·취소: 쓰다 만 파일을 지운다
    func abort() async
}

private final class LocalFileWriter: FileWriter {
    let url: URL
    let handle: FileHandle

    init(url: URL) throws {
        guard FileManager.default.createFile(atPath: url.path(percentEncoded: false), contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        self.url = url
        handle = try FileHandle(forWritingTo: url)
    }

    @concurrent
    func write(_ data: Data) async throws {
        try handle.write(contentsOf: data)
    }

    func finish() async throws {
        try handle.close()
    }

    func abort() async {
        try? handle.close()
        try? FileManager.default.removeItem(at: url)
    }
}

private final class SMBFileWriter: FileWriter {
    let url: URL
    let serverID: UUID?
    private var offset: Int64 = 0

    init(url: URL, serverID: UUID?) {
        self.url = url
        self.serverID = serverID
    }

    func write(_ data: Data) async throws {
        try await SMBClient.shared.write(data, to: url, offset: offset, serverID: serverID)
        offset += Int64(data.count)
    }

    func finish() async throws {
        // 빈 파일도 만들어지게
        if offset == 0 { try await SMBClient.shared.write(Data(), to: url, offset: 0, serverID: serverID) }
    }

    func abort() async {
        try? await SMBClient.shared.remove(url, serverID: serverID)
    }
}

/// WebDAV 는 PUT 한 번으로 올려야 하므로, 이어진 스트림 한 쌍으로 쓰는 대로 흘려보낸다
private final class WebDAVFileWriter: FileWriter {
    let url: URL
    let serverID: UUID?
    private let pipe: UploadPipe
    private let upload: Task<URLResponse, Error>

    init(url: URL, serverID: UUID?, length: Int64) {
        self.url = url
        self.serverID = serverID
        var input: InputStream?
        var output: OutputStream?
        Stream.getBoundStreams(withBufferSize: 1 << 20, inputStream: &input, outputStream: &output)
        let pipe = UploadPipe(output: output!)
        self.pipe = pipe
        var request = RemoteAccess.request(url, serverID: serverID, method: "PUT")
        request.setValue(String(length), forHTTPHeaderField: "Content-Length")
        request.httpBodyStream = input
        upload = Task.detached {
            do {
                let (_, response) = try await URLSession.shared.data(for: request)
                pipe.end(nil)
                return response
            } catch {
                pipe.end(error)
                throw error
            }
        }
    }

    func write(_ data: Data) async throws {
        try await pipe.write(data)
    }

    func finish() async throws {
        pipe.close()
        try RemoteAccess.check(try await upload.value)
    }

    func abort() async {
        upload.cancel()
        pipe.close()
        _ = try? await upload.value
        try? await WebDAVClient.remove(url, serverID: serverID)
    }
}

/// 업로드 스트림에 쓰는 쪽 (메인 스레드 밖에서 기다리며 쓴다)
nonisolated private final class UploadPipe: @unchecked Sendable {
    private let output: OutputStream
    private let lock = NSLock()
    /// 업로드가 끝났으면 .some(실패 오류 또는 nil) — 쓰는 쪽이 끝없이 기다리지 않게
    private var ended: Error??

    init(output: OutputStream) {
        self.output = output
        output.open()
    }

    func end(_ error: Error?) {
        lock.withLock { ended = .some(error) }
    }

    func close() {
        output.close()
    }

    @concurrent
    func write(_ data: Data) async throws {
        var written = 0
        while written < data.count {
            if case .some(let error) = lock.withLock({ ended }) { throw error ?? URLError(.cannotWriteToFile) }
            if output.streamStatus == .error { throw output.streamError ?? URLError(.cannotWriteToFile) }
            if output.hasSpaceAvailable {
                let count = data.withUnsafeBytes { buffer in
                    output.write(buffer.baseAddress!.assumingMemoryBound(to: UInt8.self) + written, maxLength: data.count - written)
                }
                if count < 0 { throw output.streamError ?? URLError(.cannotWriteToFile) }
                written += count
            } else {
                try await Task.sleep(for: .milliseconds(2))
            }
        }
    }
}
