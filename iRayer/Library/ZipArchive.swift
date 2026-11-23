import Foundation
import Compression
import CommonCrypto

/// 위치(이 기기 / WebDAV / SMB)에 상관없이 파일의 아무 곳이나 읽는다.
/// 원격은 범위 요청이라 작은 읽기(머리글 등)가 많으면 느리므로 블록 단위로 조금 기억해 둔다.
actor ArchiveSource {
    let url: URL
    let serverID: UUID?
    let size: Int64

    private let blockSize: Int64 = 256 << 10
    private var blocks: [Int64: Data] = [:]
    private var order: [Int64] = []

    init(url: URL, serverID: UUID?, size: Int64) {
        self.url = url
        self.serverID = serverID
        self.size = size
    }

    func read(_ range: Range<Int64>) async throws -> Data {
        let range = max(range.lowerBound, 0)..<min(range.upperBound, size)
        guard !range.isEmpty else { return Data() }
        // 큰 읽기(그림 한 장, 압축 풀기)는 바로 읽는다
        if range.count > blockSize { return try await FileOperations.read(url, range: range, serverID: serverID) }
        var result = Data()
        var offset = range.lowerBound
        while offset < range.upperBound {
            let index = offset / blockSize
            let block = try await block(index)
            let start = Int(offset - index * blockSize)
            let end = min(block.count, Int(range.upperBound - index * blockSize))
            guard start < end else { break }
            result.append(block[block.startIndex + start..<block.startIndex + end])
            offset = index * blockSize + Int64(end)
        }
        return result
    }

    private func block(_ index: Int64) async throws -> Data {
        if let block = blocks[index] { return block }
        let start = index * blockSize
        let block = try await FileOperations.read(url, range: start..<min(start + blockSize, size), serverID: serverID)
        blocks[index] = block
        order.append(index)
        if order.count > 24 { blocks[order.removeFirst()] = nil }
        return block
    }
}

/// zip 안의 파일 하나
nonisolated struct ZipEntry: Hashable, Sendable {
    /// zip 안의 경로 (폴더는 / 로 끝난다)
    let path: String
    let method: UInt16
    let flags: UInt16
    let crc32: UInt32
    let dosTime: UInt16
    let compressedSize: Int64
    let size: Int64
    let localHeaderOffset: Int64
    /// AES 암호 (WinZip 방식): 세기 1~3, 실제 압축 방법
    var aesStrength: UInt8?
    var aesMethod: UInt16?
    var aesVersion: UInt16?
    /// RAR: 목록에서의 순서 (꺼낼 때 쓴다)
    var index = 0

    var isDirectory: Bool { path.hasSuffix("/") }
    var isEncrypted: Bool { flags & 1 != 0 }
    var name: String { (path as NSString).lastPathComponent }

    /// 만화·압축 풀기에서 무시하는 군더더기 (맥의 리소스 포크, 윈도우 썸네일 등)
    var isJunk: Bool {
        let lower = path.lowercased()
        return lower.hasPrefix("__macosx/") || lower.contains("/__macosx/") || name.hasPrefix(".")
            || ["thumbs.db", "desktop.ini"].contains(name.lowercased())
    }

    static let imageExtensions: Set<String> = ["jpg", "jpeg", "png", "gif", "webp", "bmp", "heic", "heif", "avif", "tif", "tiff"]

    var isImage: Bool { Self.imageExtensions.contains((name as NSString).pathExtension.lowercased()) }

    /// 만화로 볼 때 그림이 아니어도 괜찮은 파일 (설명·정보 파일)
    var isNote: Bool { ["txt", "nfo", "xml", "url", "html", "htm", "md", "sfv", "db", "ini"].contains((name as NSString).pathExtension.lowercased()) }
}

nonisolated enum ZipError: LocalizedError {
    case notZip
    case unsupported(String)
    case wrongPassword
    case corrupted

    var errorDescription: String? {
        switch self {
        case .notZip: "zip 파일이 아니거나 손상되었습니다."
        case .unsupported(let what): "지원하지 않는 압축 방식입니다 (\(what))."
        case .wrongPassword: "암호가 맞지 않습니다."
        case .corrupted: "압축 파일이 손상되었습니다."
        }
    }
}

/// zip 파일 읽기. 끝부분의 목록(central directory)만 읽어 두고, 파일은 필요할 때 그 부분만 읽는다.
/// 지원: 무압축·deflate, zip64, 옛 암호(ZipCrypto)·AES 암호, UTF-8·CP949·Shift-JIS 파일명.
nonisolated final class ZipArchive: Sendable {
    let source: ArchiveSource
    let entries: [ZipEntry]

    private init(source: ArchiveSource, entries: [ZipEntry]) {
        self.source = source
        self.entries = entries
    }

    @concurrent
    static func open(_ source: ArchiveSource) async throws -> ZipArchive {
        let size = source.size
        guard size >= 22 else { throw ZipError.notZip }
        // 1. 끝에서 목록 끝 표시(EOCD)를 찾는다 (뒤에 주석이 최대 64KB 붙을 수 있다)
        let tailStart = max(0, size - 65_557)
        let tail = try await source.read(tailStart..<size)
        guard let eocd = tail.lastIndex(of: 0x06054b50, before: tail.count - 22) else { throw ZipError.notZip }
        var count = Int64(tail.uint16(at: eocd + 10))
        var directorySize = Int64(tail.uint32(at: eocd + 12))
        var directoryOffset = Int64(tail.uint32(at: eocd + 16))

        // 2. zip64: 바로 앞의 zip64 위치 표시 → zip64 목록 끝 표시
        if count == 0xFFFF || directorySize == 0xFFFF_FFFF || directoryOffset == 0xFFFF_FFFF, eocd >= 20,
           tail.uint32(at: eocd - 20) == 0x07064b50 {
            let recordOffset = Int64(tail.uint64(at: eocd - 20 + 8))
            let record = try await source.read(recordOffset..<recordOffset + 56)
            guard record.count >= 56, record.uint32(at: 0) == 0x06064b50 else { throw ZipError.corrupted }
            count = Int64(record.uint64(at: 32))
            directorySize = Int64(record.uint64(at: 40))
            directoryOffset = Int64(record.uint64(at: 48))
        }

        // 3. 목록 읽기
        let directory = try await source.read(directoryOffset..<directoryOffset + directorySize)
        var entries: [ZipEntry] = []
        var position = 0
        while entries.count < count, position + 46 <= directory.count, directory.uint32(at: position) == 0x02014b50 {
            let flags = directory.uint16(at: position + 8)
            let method = directory.uint16(at: position + 10)
            let time = directory.uint16(at: position + 12)
            let crc = directory.uint32(at: position + 16)
            var compressed = Int64(directory.uint32(at: position + 20))
            var uncompressed = Int64(directory.uint32(at: position + 24))
            let nameLength = Int(directory.uint16(at: position + 28))
            let extraLength = Int(directory.uint16(at: position + 30))
            let commentLength = Int(directory.uint16(at: position + 32))
            var offset = Int64(directory.uint32(at: position + 42))
            let nameStart = position + 46
            guard nameStart + nameLength + extraLength <= directory.count else { break }
            let nameBytes = directory.subdata(in: directory.startIndex + nameStart..<directory.startIndex + nameStart + nameLength)
            var name = decodeName(nameBytes, utf8: flags & 0x800 != 0)

            var aes: (strength: UInt8, method: UInt16, version: UInt16)?
            var extra = nameStart + nameLength
            let extraEnd = extra + extraLength
            while extra + 4 <= extraEnd {
                let id = directory.uint16(at: extra)
                let length = Int(directory.uint16(at: extra + 2))
                let body = extra + 4
                guard body + length <= extraEnd else { break }
                switch id {
                case 0x0001:
                    // zip64: 0xFFFFFFFF 인 값만 차례로 들어 있다
                    var field = body
                    if uncompressed == 0xFFFF_FFFF, field + 8 <= body + length { uncompressed = Int64(directory.uint64(at: field)); field += 8 }
                    if compressed == 0xFFFF_FFFF, field + 8 <= body + length { compressed = Int64(directory.uint64(at: field)); field += 8 }
                    if offset == 0xFFFF_FFFF, field + 8 <= body + length { offset = Int64(directory.uint64(at: field)) }
                case 0x7075:
                    // Info-ZIP 유니코드 경로 (버전 1바이트 + CRC 4바이트 + UTF-8 이름)
                    if length > 5, let unicode = String(data: directory.subdata(in: directory.startIndex + body + 5..<directory.startIndex + body + length), encoding: .utf8) {
                        name = unicode
                    }
                case 0x9901:
                    if length >= 7 {
                        aes = (directory[directory.startIndex + body + 4], directory.uint16(at: body + 5), directory.uint16(at: body))
                    }
                default:
                    break
                }
                extra = body + length
            }

            var entry = ZipEntry(path: name.replacingOccurrences(of: "\\", with: "/").precomposedStringWithCanonicalMapping,
                                 method: method, flags: flags, crc32: crc, dosTime: time,
                                 compressedSize: compressed, size: uncompressed, localHeaderOffset: offset)
            entry.aesStrength = aes?.strength
            entry.aesMethod = aes?.method
            entry.aesVersion = aes?.version
            entries.append(entry)
            position = extraEnd + commentLength
        }
        guard !entries.isEmpty || count == 0 else { throw ZipError.corrupted }
        return ZipArchive(source: source, entries: entries)
    }

    /// 파일명 바이트 → 문자열. UTF-8 표시가 없으면 UTF-8 → CP949(윈도우 한글) → Shift-JIS → Latin-1 순으로 시도한다.
    private static func decodeName(_ bytes: Data, utf8: Bool) -> String {
        if utf8 || bytes.allSatisfy({ $0 < 0x80 }), let name = String(data: bytes, encoding: .utf8) { return name }
        if let name = String(data: bytes, encoding: .utf8) { return name }
        for encoding in [CFStringEncodings.dosKorean, .shiftJIS] {
            let converted = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(encoding.rawValue)))
            if let name = String(data: bytes, encoding: converted) { return name }
        }
        return String(data: bytes, encoding: .isoLatin1) ?? ""
    }

    // MARK: - 파일 꺼내기

    /// 파일 하나를 통째로 (그림 등 작은 파일)
    @concurrent
    func data(of entry: ZipEntry, password: String? = nil) async throws -> Data {
        var result = Data()
        result.reserveCapacity(Int(entry.size))
        try await extract(entry, password: password) { result.append($0) }
        return result
    }

    /// 파일 하나를 조금씩 풀어 넘긴다 (큰 파일을 풀 때)
    func extract(_ entry: ZipEntry, password: String?, chunkSize: Int64 = 1 << 20, output: (Data) async throws -> Void) async throws {
        var start = try await dataStart(of: entry)
        var remaining = entry.compressedSize
        var decryptor: Decryptor?
        var checksCRC = false

        if entry.isEncrypted {
            guard let password, !password.isEmpty else { throw ZipError.wrongPassword }
            if entry.method == 99 {
                let (aes, headerLength) = try await AESDecryptor.make(entry, at: start, source: source, password: password)
                decryptor = aes
                start += headerLength
                remaining -= headerLength + 10 // 끝의 인증 코드 10바이트
            } else {
                let header = try await source.read(start..<start + 12)
                guard header.count == 12 else { throw ZipError.corrupted }
                var crypto = ZipCrypto(password: password)
                let decrypted = crypto.decrypt(header)
                let check = entry.flags & 0x8 != 0 ? UInt8(entry.dosTime >> 8) : UInt8(entry.crc32 >> 24)
                guard decrypted.last == check else { throw ZipError.wrongPassword }
                decryptor = crypto
                start += 12
                remaining -= 12
                // 확인 바이트는 256 번에 1 번 우연히 맞을 수 있어서 끝까지 CRC 로 확인한다
                checksCRC = true
            }
        }

        let method = entry.method == 99 ? (entry.aesMethod ?? 0) : entry.method
        guard method == 0 || method == 8 else { throw ZipError.unsupported("방식 \(method)") }

        var crc = CRC32()
        var produced: Int64 = 0
        func emit(_ data: Data) async throws {
            if checksCRC { crc.update(data) }
            produced += Int64(data.count)
            try await output(data)
        }

        var inflater: OutputFilter?
        // 풀린 조각은 바로 복사해 둔다 (OutputFilter 가 넘기는 Data 는 안쪽 버퍼를 다시 쓸 수 있다)
        var inflated = Data()
        if method == 8 {
            inflater = try OutputFilter(.decompress, using: .zlib) { data in
                if let data { data.withUnsafeBytes { inflated.append(contentsOf: $0) } }
            }
        }

        var offset = start
        while remaining > 0 {
            try Task.checkCancellation()
            let length = min(chunkSize, remaining)
            var chunk = try await source.read(offset..<offset + length)
            guard !chunk.isEmpty else { throw ZipError.corrupted }
            offset += Int64(chunk.count)
            remaining -= Int64(chunk.count)
            if decryptor != nil { chunk = decryptor!.decrypt(chunk) }
            if let inflater {
                do {
                    try inflater.write(chunk)
                } catch {
                    throw entry.isEncrypted ? ZipError.wrongPassword : ZipError.corrupted
                }
                if !inflated.isEmpty {
                    let piece = inflated
                    inflated = Data()
                    try await emit(piece)
                }
            } else {
                try await emit(chunk)
            }
        }
        if let inflater {
            try? inflater.finalize()
            if !inflated.isEmpty { try await emit(inflated) }
        }
        if checksCRC, crc.value != entry.crc32 { throw ZipError.wrongPassword }
        if produced != entry.size, entry.size > 0 { throw entry.isEncrypted ? ZipError.wrongPassword : ZipError.corrupted }
    }

    /// 암호가 맞는지 (파일을 다 풀지 않고 머리글만 본다)
    @concurrent
    func check(password: String) async -> Bool {
        guard let entry = entries.first(where: { $0.isEncrypted && !$0.isDirectory }) else { return true }
        do {
            let start = try await dataStart(of: entry)
            if entry.method == 99 {
                _ = try await AESDecryptor.make(entry, at: start, source: source, password: password)
                return true
            }
            let header = try await source.read(start..<start + 12)
            var crypto = ZipCrypto(password: password)
            let check = entry.flags & 0x8 != 0 ? UInt8(entry.dosTime >> 8) : UInt8(entry.crc32 >> 24)
            return crypto.decrypt(header).last == check
        } catch {
            return false
        }
    }

    var isEncrypted: Bool { entries.contains { $0.isEncrypted } }

    /// 로컬 머리글 다음, 실제 데이터가 시작하는 위치
    private func dataStart(of entry: ZipEntry) async throws -> Int64 {
        let header = try await source.read(entry.localHeaderOffset..<entry.localHeaderOffset + 30)
        guard header.count == 30, header.uint32(at: 0) == 0x04034b50 else { throw ZipError.corrupted }
        return entry.localHeaderOffset + 30 + Int64(header.uint16(at: 26)) + Int64(header.uint16(at: 28))
    }
}

// MARK: - 암호 풀기

nonisolated private protocol Decryptor {
    mutating func decrypt(_ data: Data) -> Data
}

/// 옛 zip 암호 (PKWARE 전통 방식)
nonisolated private struct ZipCrypto: Decryptor {
    private var keys: (UInt32, UInt32, UInt32) = (0x12345678, 0x23456789, 0x34567890)

    init(password: String) {
        for byte in password.utf8 { update(byte) }
    }

    private mutating func update(_ byte: UInt8) {
        keys.0 = CRC32.table[Int((keys.0 ^ UInt32(byte)) & 0xFF)] ^ (keys.0 >> 8)
        keys.1 = (keys.1 &+ (keys.0 & 0xFF)) &* 134_775_813 &+ 1
        keys.2 = CRC32.table[Int((keys.2 ^ (keys.1 >> 24)) & 0xFF)] ^ (keys.2 >> 8)
    }

    mutating func decrypt(_ data: Data) -> Data {
        var output = Data(count: data.count)
        output.withUnsafeMutableBytes { out in
            data.withUnsafeBytes { input in
                for index in 0..<input.count {
                    let temp = UInt16(truncatingIfNeeded: keys.2) | 2
                    let byte = input[index] ^ UInt8(truncatingIfNeeded: (UInt32(temp) &* UInt32(temp ^ 1)) >> 8)
                    update(byte)
                    out[index] = byte
                }
            }
        }
        return output
    }
}

/// WinZip AES 암호: PBKDF2-SHA1 로 키를 만들고, 작은 쪽부터 세는 카운터로 AES-CTR
nonisolated private final class AESDecryptor: Decryptor {
    private let cryptor: CCCryptorRef
    private var counter: UInt64 = 0
    private var keystream = Data()
    private var used = 0

    /// 머리글(소금 + 확인값)을 읽어 암호를 확인한다. 머리글 길이도 돌려준다.
    static func make(_ entry: ZipEntry, at start: Int64, source: ArchiveSource, password: String) async throws -> (AESDecryptor, Int64) {
        let keyLength: Int
        switch entry.aesStrength {
        case 1: keyLength = 16
        case 2: keyLength = 24
        case 3: keyLength = 32
        default: throw ZipError.unsupported("AES")
        }
        let saltLength = keyLength / 2
        let header = try await source.read(start..<start + Int64(saltLength + 2))
        guard header.count == saltLength + 2 else { throw ZipError.corrupted }
        let salt = header.prefix(saltLength)
        var derived = [UInt8](repeating: 0, count: keyLength * 2 + 2)
        let passwordBytes = Array(password.utf8)
        let status = salt.withUnsafeBytes { saltBuffer in
            passwordBytes.withUnsafeBufferPointer { passwordBuffer in
                passwordBuffer.withMemoryRebound(to: CChar.self) { passwordChars in
                    CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), passwordChars.baseAddress, passwordBytes.count,
                                         saltBuffer.bindMemory(to: UInt8.self).baseAddress, saltLength,
                                         CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1), 1000, &derived, derived.count)
                }
            }
        }
        guard status == kCCSuccess else { throw ZipError.corrupted }
        guard derived[keyLength * 2] == header[header.startIndex + saltLength],
              derived[keyLength * 2 + 1] == header[header.startIndex + saltLength + 1] else { throw ZipError.wrongPassword }

        var cryptor: CCCryptorRef?
        let created = CCCryptorCreate(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionECBMode),
                                      derived, keyLength, nil, &cryptor)
        guard created == kCCSuccess, let cryptor else { throw ZipError.corrupted }
        return (AESDecryptor(cryptor: cryptor), Int64(saltLength + 2))
    }

    private init(cryptor: CCCryptorRef) {
        self.cryptor = cryptor
    }

    deinit {
        CCCryptorRelease(cryptor)
    }

    func decrypt(_ data: Data) -> Data {
        // 필요한 만큼 카운터 블록을 AES 로 암호화해 키 스트림을 만든다
        let needed = data.count - (keystream.count - used)
        if needed > 0 {
            let blocks = (needed + 15) / 16
            var counters = Data(count: blocks * 16)
            counters.withUnsafeMutableBytes { buffer in
                for block in 0..<blocks {
                    counter += 1
                    var value = counter.littleEndian
                    withUnsafeBytes(of: &value) { buffer.baseAddress!.advanced(by: block * 16).copyMemory(from: $0.baseAddress!, byteCount: 8) }
                }
            }
            var stream = Data(count: counters.count)
            var moved = 0
            stream.withUnsafeMutableBytes { out in
                counters.withUnsafeBytes { input in
                    _ = CCCryptorUpdate(cryptor, input.baseAddress, input.count, out.baseAddress, out.count, &moved)
                }
            }
            keystream = keystream.suffix(from: keystream.startIndex + used) + stream
            used = 0
        }
        var output = Data(count: data.count)
        output.withUnsafeMutableBytes { out in
            data.withUnsafeBytes { input in
                keystream.withUnsafeBytes { key in
                    for index in 0..<input.count { out[index] = input[index] ^ key[used + index] }
                }
            }
        }
        used += data.count
        return output
    }
}

/// CRC-32 (zip 이 쓰는 것)
nonisolated struct CRC32 {
    static let table: [UInt32] = (0..<256).map { index in
        var value = UInt32(index)
        for _ in 0..<8 { value = value & 1 != 0 ? 0xEDB8_8320 ^ (value >> 1) : value >> 1 }
        return value
    }

    private var crc: UInt32 = 0xFFFF_FFFF

    var value: UInt32 { crc ^ 0xFFFF_FFFF }

    mutating func update(_ data: Data) {
        var crc = self.crc
        data.withUnsafeBytes { buffer in
            for byte in buffer { crc = Self.table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8) }
        }
        self.crc = crc
    }
}

// MARK: - 바이트 읽기

nonisolated private extension Data {
    func uint16(at offset: Int) -> UInt16 {
        UInt16(self[startIndex + offset]) | UInt16(self[startIndex + offset + 1]) << 8
    }

    func uint32(at offset: Int) -> UInt32 {
        UInt32(uint16(at: offset)) | UInt32(uint16(at: offset + 2)) << 16
    }

    func uint64(at offset: Int) -> UInt64 {
        UInt64(uint32(at: offset)) | UInt64(uint32(at: offset + 4)) << 32
    }

    /// 뒤에서부터 4바이트 표시를 찾는다
    func lastIndex(of signature: UInt32, before end: Int) -> Int? {
        var index = Swift.min(end, count - 4)
        while index >= 0 {
            if uint32(at: index) == signature { return index }
            index -= 1
        }
        return nil
    }
}
