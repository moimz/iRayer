import Foundation
import CryptoKit
import Cunrar

/// RAR 압축 파일 (UnRAR 라이브러리, 풀기만).
/// RAR 은 파일 전체가 이 기기에 있어야 하므로 NAS 의 파일은 Caches 에 받아 둔다.
/// "솔리드" RAR 은 앞의 파일을 다 풀어야 뒤의 파일을 꺼낼 수 있어서, 만화로 볼 때는 한 번에 모두 풀어 Caches 에 둔다.
nonisolated final class RarArchive: ComicArchive, @unchecked Sendable {
    let localURL: URL
    let entries: [ZipEntry]
    /// 파일 목록까지 암호로 감춘 RAR
    let isHeaderEncrypted: Bool
    var isEncrypted: Bool { isHeaderEncrypted || entries.contains { $0.isEncrypted } }

    /// 모두 풀어 둔 폴더 (파일 이름은 목록 순서 번호)
    private let unpackedDirectory: URL
    private let lock = NSLock()

    private init(localURL: URL, entries: [ZipEntry], isHeaderEncrypted: Bool) {
        self.localURL = localURL
        self.entries = entries
        self.isHeaderEncrypted = isHeaderEncrypted
        unpackedDirectory = RarCache.directory(for: localURL)
    }

    enum RarError: LocalizedError {
        case failed(Int32)

        var errorDescription: String? {
            switch self {
            case .failed(let code) where code == ERAR_MISSING_PASSWORD || code == ERAR_BAD_PASSWORD: ZipError.wrongPassword.localizedDescription
            case .failed(let code) where code == ERAR_BAD_DATA: "RAR 파일이 손상되었거나 암호가 맞지 않습니다."
            case .failed(let code) where code == ERAR_UNKNOWN_FORMAT || code == ERAR_BAD_ARCHIVE: "RAR 파일이 아니거나 손상되었습니다."
            case .failed(let code): "RAR 파일을 풀지 못했습니다 (\(code))."
            }
        }
    }

    // MARK: - 열기

    static func open(_ file: VideoFile, progress: (@Sendable (Double) -> Void)?) async throws -> RarArchive {
        let localURL = try await RarCache.localCopy(of: file, progress: progress)
        return try await list(localURL)
    }

    @concurrent
    private static func list(_ url: URL) async throws -> RarArchive {
        var headerEncrypted = false
        var entries: [ZipEntry] = []
        try withArchive(url, mode: RAR_OM_LIST, password: nil) { handle, flags in
            headerEncrypted = flags.Flags & UInt32(ROADF_ENCHEADERS) != 0
            if headerEncrypted { return }
            entries = try readEntries(handle)
        }
        return RarArchive(localURL: url, entries: entries, isHeaderEncrypted: headerEncrypted)
    }

    /// 목록을 감춘 RAR: 암호를 넣어야 목록을 볼 수 있다
    func unlocked(password: String) async throws -> RarArchive {
        guard isHeaderEncrypted else { return self }
        let url = localURL
        let entries = try await Self.listEntries(url, password: password)
        return RarArchive(localURL: url, entries: entries, isHeaderEncrypted: true)
    }

    @concurrent
    private static func listEntries(_ url: URL, password: String) async throws -> [ZipEntry] {
        var entries: [ZipEntry] = []
        try withArchive(url, mode: RAR_OM_LIST, password: password) { handle, _ in
            entries = try readEntries(handle)
        }
        return entries
    }

    private static func readEntries(_ handle: UnsafeMutableRawPointer) throws -> [ZipEntry] {
        var entries: [ZipEntry] = []
        var header = RARHeaderDataEx()
        while true {
            let result = RARReadHeaderEx(handle, &header)
            if result == ERAR_END_ARCHIVE { break }
            guard result == ERAR_SUCCESS else { throw RarError.failed(result) }
            let isDirectory = header.Flags & UInt32(RHDF_DIRECTORY) != 0
            let name = fileName(&header).replacingOccurrences(of: "\\", with: "/").precomposedStringWithCanonicalMapping
            var entry = ZipEntry(path: isDirectory ? name + "/" : name,
                                 method: 0, flags: header.Flags & UInt32(RHDF_ENCRYPTED) != 0 ? 1 : 0,
                                 crc32: header.FileCRC, dosTime: 0,
                                 compressedSize: Int64(header.PackSizeHigh) << 32 | Int64(header.PackSize),
                                 size: Int64(header.UnpSizeHigh) << 32 | Int64(header.UnpSize),
                                 localHeaderOffset: 0)
            entry.index = entries.count
            entries.append(entry)
            let skipped = RARProcessFile(handle, RAR_SKIP, nil, nil)
            guard skipped == ERAR_SUCCESS else { throw RarError.failed(skipped) }
        }
        return entries
    }

    /// 넓은 문자 파일명 (한글 등이 깨지지 않게)
    private static func fileName(_ header: inout RARHeaderDataEx) -> String {
        withUnsafeBytes(of: &header.FileNameW) { buffer in
            let characters = buffer.bindMemory(to: wchar_t.self)
            var scalars = String.UnicodeScalarView()
            for character in characters {
                guard character != 0, let scalar = Unicode.Scalar(UInt32(bitPattern: character)) else { break }
                scalars.append(scalar)
            }
            return String(scalars)
        }
    }

    // MARK: - 암호

    func check(password: String) async -> Bool {
        let url = localURL
        if isHeaderEncrypted {
            return (try? await Self.listEntries(url, password: password)) != nil
        }
        guard let entry = entries.first(where: { $0.isEncrypted && !$0.isDirectory && $0.size > 0 }) else { return true }
        // 끝까지 풀지 않고 첫 데이터가 나오면 맞은 것으로 본다 (800MB 영상을 다 풀어 보지 않게).
        // RAR5 는 틀린 암호를 처음에 알아채고, RAR4 는 끝의 CRC 에서야 알 수 있어 그때는 풀다가 실패한다.
        let received = ReceivedFlag()
        do {
            try await Self.process(url, password: password, only: entry.index) { _, _ in
                received.value = true
                return false
            }
            return true
        } catch {
            return received.value
        }
    }

    private final class ReceivedFlag: @unchecked Sendable {
        var value = false
    }

    // MARK: - 꺼내기

    func data(of entry: ZipEntry, password: String?) async throws -> Data {
        try await unpackAll(password: password)
        return try Data(contentsOf: unpackedDirectory.appending(path: String(entry.index)))
    }

    /// 압축 풀기: 파일 하나씩 (앞의 파일을 건너뛰며)
    func extract(_ entry: ZipEntry, password: String?, output: (Data) async throws -> Void) async throws {
        // 모두 풀어 두었으면 거기서 읽는다
        let unpacked = unpackedDirectory.appending(path: String(entry.index))
        if FileManager.default.fileExists(atPath: unpacked.path(percentEncoded: false)) {
            let handle = try FileHandle(forReadingFrom: unpacked)
            defer { try? handle.close() }
            while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty { try await output(chunk) }
            return
        }
        let temporary = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temporary) }
        FileManager.default.createFile(atPath: temporary.path(percentEncoded: false), contents: nil)
        let writer = try FileHandle(forWritingTo: temporary)
        try await Self.process(localURL, password: password, only: entry.index) { _, data in
            (try? writer.write(contentsOf: data)) != nil
        }
        try writer.close()
        let reader = try FileHandle(forReadingFrom: temporary)
        defer { try? reader.close() }
        while let chunk = try reader.read(upToCount: 1 << 20), !chunk.isEmpty { try await output(chunk) }
    }

    /// 한 번에 모두 풀어 Caches 에 둔다 (만화 보기, 압축 풀기). 이미 풀어 두었으면 바로 끝난다.
    /// progress: 지금까지 푼 바이트 (다른 스레드에서 불린다)
    func unpackAll(password: String?, progress: (@Sendable (Int64) -> Void)? = nil) async throws {
        let marker = unpackedDirectory.appending(path: "done")
        if FileManager.default.fileExists(atPath: marker.path(percentEncoded: false)) { return }
        let directory = unpackedDirectory
        let url = localURL
        try await Self.unpack(url, to: directory, password: password, lock: lock, progress: progress)
        FileManager.default.createFile(atPath: marker.path(percentEncoded: false), contents: nil)
    }

    /// 압축 풀기에 쓰려고 모두 풀어 둔 것을 지운다 (Caches 를 차지하지 않게)
    func removeUnpacked() {
        try? FileManager.default.removeItem(at: unpackedDirectory)
    }

    @concurrent
    private static func unpack(_ url: URL, to directory: URL, password: String?, lock: NSLock,
                               progress: (@Sendable (Int64) -> Void)?) async throws {
        // 여러 쪽이 한꺼번에 불러도 한 번만 푼다 (기다리는 동안 다른 쪽이 다 풀었으면 바로 끝)
        try lock.withLock {
            if FileManager.default.fileExists(atPath: directory.appending(path: "done").path(percentEncoded: false)) { return }
            try? FileManager.default.removeItem(at: directory)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            var current: (index: Int, handle: FileHandle)?
            var unpacked: Int64 = 0
            do {
                try processSync(url, password: password, only: nil) { index, data in
                    if current?.index != index {
                        try? current?.handle.close()
                        let file = directory.appending(path: String(index))
                        FileManager.default.createFile(atPath: file.path(percentEncoded: false), contents: nil)
                        current = (try? FileHandle(forWritingTo: file)).map { (index, $0) }
                    }
                    try? current?.handle.write(contentsOf: data)
                    unpacked += Int64(data.count)
                    progress?(unpacked)
                    return true
                }
            } catch {
                try? current?.handle.close()
                try? FileManager.default.removeItem(at: directory)
                throw error
            }
            try? current?.handle.close()
        }
    }

    @concurrent
    private static func process(_ url: URL, password: String?, only: Int?, output: @escaping (Int, Data) -> Bool) async throws {
        try processSync(url, password: password, only: only, output: output)
    }

    /// 처음부터 차례로 읽으며 파일 내용을 넘긴다. only 가 있으면 그 파일까지만 (앞의 것은 건너뛴다).
    /// output 이 false 를 돌려주면 멈춘다. 빈 파일은 output 이 불리지 않는다.
    private static func processSync(_ url: URL, password: String?, only: Int?, output: @escaping (Int, Data) -> Bool) throws {
        final class Context {
            var index = 0
            let output: (Int, Data) -> Bool
            var cancelled = false
            init(output: @escaping (Int, Data) -> Bool) { self.output = output }
        }
        let context = Context(output: output)
        let pointer = Unmanaged.passRetained(context)
        defer { pointer.release() }
        let callback: UNRARCALLBACK = { message, userData, p1, p2 in
            guard let raw = UnsafeRawPointer(bitPattern: userData) else { return -1 }
            let context = Unmanaged<Context>.fromOpaque(raw).takeUnretainedValue()
            switch message {
            case UCM_PROCESSDATA.rawValue:
                if let bytes = UnsafeRawPointer(bitPattern: p1), !context.output(context.index, Data(bytes: bytes, count: p2)) {
                    context.cancelled = true
                }
                // 작업을 취소했으면 큰 파일을 푸는 도중에도 멈춘다
                if Task.isCancelled { context.cancelled = true }
                return context.cancelled ? -1 : 0
            case UCM_NEEDPASSWORD.rawValue, UCM_NEEDPASSWORDW.rawValue:
                // 암호를 미리 넣었는데도 묻는다 = 암호가 없거나 틀림
                return -1
            default:
                return 0
            }
        }
        try withArchive(url, mode: RAR_OM_EXTRACT, password: password) { handle, _ in
            RARSetCallback(handle, callback, Int(bitPattern: pointer.toOpaque()))
            var header = RARHeaderDataEx()
            var index = 0
            while true {
                if Task.isCancelled { context.cancelled = true }
                let result = RARReadHeaderEx(handle, &header)
                if result == ERAR_END_ARCHIVE { break }
                guard result == ERAR_SUCCESS else { throw RarError.failed(result) }
                context.index = index
                let wanted = only == nil || only == index
                let isDirectory = header.Flags & UInt32(RHDF_DIRECTORY) != 0
                let processed = RARProcessFile(handle, wanted && !isDirectory ? RAR_TEST : RAR_SKIP, nil, nil)
                guard processed == ERAR_SUCCESS else {
                    if context.cancelled { throw CancellationError() }
                    throw RarError.failed(processed)
                }
                if only == index { break }
                index += 1
            }
        }
    }

    private static func withArchive(_ url: URL, mode: Int32, password: String?,
                                    _ body: (UnsafeMutableRawPointer, RAROpenArchiveDataEx) throws -> Void) throws {
        var flags = RAROpenArchiveDataEx()
        flags.OpenMode = UInt32(mode)
        let handle = url.path(percentEncoded: false).utf8CString.withUnsafeBufferPointer { path -> UnsafeMutableRawPointer? in
            flags.ArcName = UnsafeMutablePointer(mutating: path.baseAddress)
            return UnsafeMutableRawPointer(RAROpenArchiveEx(&flags))
        }
        guard let handle, flags.OpenResult == ERAR_SUCCESS else { throw RarError.failed(Int32(flags.OpenResult)) }
        defer { RARCloseArchive(handle) }
        if let password {
            password.utf8CString.withUnsafeBufferPointer { RARSetPassword(handle, UnsafeMutablePointer(mutating: $0.baseAddress)) }
        }
        try body(handle, flags)
    }
}

/// NAS 의 RAR 을 받아 두는 곳 (Caches/Rar). 전체가 3GB 를 넘으면 오래 안 쓴 것부터 지운다.
nonisolated enum RarCache {
    static let root = AppPaths.caches.appending(path: "Rar", directoryHint: .isDirectory)
    private static let limit: Int64 = 3 << 30

    /// 받아 둔 파일 이름: 서버·경로·크기로 정한다 (같은 파일이면 다시 받지 않는다)
    static func localURL(for file: VideoFile) -> URL {
        let key = "\(file.serverID?.uuidString ?? "-")|\(file.url.absoluteString)|\(file.size)"
        let hash = SHA256.hash(data: Data(key.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
        return root.appending(path: hash + ".rar")
    }

    /// 모두 풀어 둘 폴더 (받아 둔 파일 옆)
    static func directory(for localURL: URL) -> URL {
        if localURL.path(percentEncoded: false).hasPrefix(root.path(percentEncoded: false)) {
            return localURL.deletingPathExtension()
        }
        // 이 기기에 있는 RAR 은 경로로 이름을 정한다
        let hash = SHA256.hash(data: Data(localURL.path(percentEncoded: false).utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
        return root.appending(path: "local-" + hash, directoryHint: .isDirectory)
    }

    /// 받아 둔 RAR 을 모두 지운다 (설정 → 캐시)
    static func clear() {
        try? FileManager.default.removeItem(at: root)
    }

    /// 이미 이 기기에 있는지 (표지를 만들 때 큰 RAR 을 일부러 받지 않으려고)
    static func isLocal(_ file: VideoFile) -> Bool {
        file.url.isFileURL || FileManager.default.fileExists(atPath: localURL(for: file).path(percentEncoded: false))
    }

    static func localCopy(of file: VideoFile, progress: (@Sendable (Double) -> Void)?) async throws -> URL {
        if file.url.isFileURL { return file.url }
        let target = localURL(for: file)
        if FileManager.default.fileExists(atPath: target.path(percentEncoded: false)) {
            try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: target.path(percentEncoded: false))
            return target
        }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        trim(adding: file.size)
        let partial = target.appendingPathExtension("part")
        try? FileManager.default.removeItem(at: partial)
        FileManager.default.createFile(atPath: partial.path(percentEncoded: false), contents: nil)
        let handle = try FileHandle(forWritingTo: partial)
        do {
            var offset: Int64 = 0
            let chunk: Int64 = 4 << 20
            while offset < file.size {
                try Task.checkCancellation()
                let data = try await FileOperations.read(file.url, range: offset..<min(offset + chunk, file.size), serverID: file.serverID)
                guard !data.isEmpty else { break }
                try handle.write(contentsOf: data)
                offset += Int64(data.count)
                progress?(Double(offset) / Double(max(file.size, 1)))
            }
            try handle.close()
            try FileManager.default.moveItem(at: partial, to: target)
        } catch {
            try? handle.close()
            try? FileManager.default.removeItem(at: partial)
            throw error
        }
        return target
    }

    /// 새로 받을 만큼 자리를 비운다 (오래 안 쓴 것부터). 받아 둔 RAR 과 모두 풀어 둔 폴더를 함께 센다.
    private static func trim(adding size: Int64) {
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .contentModificationDateKey, .isDirectoryKey]
        guard let items = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: keys) else { return }
        var entries = items.map { url -> (URL, Int64, Date) in
            let values = try? url.resourceValues(forKeys: Set(keys))
            return (url, allocatedSize(url, isDirectory: values?.isDirectory == true), values?.contentModificationDate ?? .distantPast)
        }
        var total = entries.reduce(0) { $0 + $1.1 } + size
        entries.sort { $0.2 < $1.2 }
        while total > limit, let oldest = entries.first {
            try? FileManager.default.removeItem(at: oldest.0)
            total -= oldest.1
            entries.removeFirst()
        }
    }

    private static func allocatedSize(_ url: URL, isDirectory: Bool) -> Int64 {
        guard isDirectory else {
            return Int64((try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize) ?? 0)
        }
        let files = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.totalFileAllocatedSizeKey])
        var total: Int64 = 0
        while let file = files?.nextObject() as? URL {
            total += Int64((try? file.resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize) ?? 0)
        }
        return total
    }
}
