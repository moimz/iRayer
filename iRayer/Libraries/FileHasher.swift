import Foundation

/// OpenSubtitles 방식 파일 해시: 파일 크기 + 앞 64KB + 뒤 64KB 를 8바이트(리틀 엔디언)씩 더한 값의 하위 64비트.
/// 파일 이름을 바꾸거나 옮겨도 같은 값이라 에이전트와 이어보기가 파일을 알아보는 열쇠로 쓴다. (크기와 함께)
enum FileHasher {
    static let chunk: Int64 = 65_536

    static func hash(_ url: URL, size: Int64, serverID: UUID?) async throws -> String {
        var sum = UInt64(bitPattern: size)
        for offset in [0, max(0, size - chunk)] {
            let range = offset..<min(size, offset + chunk)
            let data = try await read(url, range: range, serverID: serverID)
            sum = add(data, to: sum)
        }
        return String(format: "%016llx", sum)
    }

    private static func add(_ data: Data, to sum: UInt64) -> UInt64 {
        var sum = sum
        var bytes = [UInt8](data)
        if bytes.count % 8 != 0 { bytes += [UInt8](repeating: 0, count: 8 - bytes.count % 8) }
        bytes.withUnsafeBytes { buffer in
            for index in stride(from: 0, to: buffer.count, by: 8) {
                sum &+= UInt64(littleEndian: buffer.loadUnaligned(fromByteOffset: index, as: UInt64.self))
            }
        }
        return sum
    }

    private static func read(_ url: URL, range: Range<Int64>, serverID: UUID?) async throws -> Data {
        switch url.scheme {
        case "smb":
            return try await SMBClient.shared.read(url, range: range, serverID: serverID)
        case "http", "https":
            return try await WebDAVClient.read(url, range: range, serverID: serverID)
        case "file":
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            try handle.seek(toOffset: UInt64(range.lowerBound))
            return try handle.read(upToCount: range.count) ?? Data()
        default:
            throw RemoteAccess.AccessError.unsupported
        }
    }
}
