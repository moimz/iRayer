import CryptoKit
import Foundation

/// 영상 지문 (2026-11-09, 사용자): 주소는 새로고침마다 토큰이 바뀌어 같은 영상을 못 알아보므로 내용으로 가린다.
/// - HLS: 조각 수 + 조각마다의 길이(EXTINF)를 차례로 (목록은 원래 살피려고 받으니 요청이 더 들지 않는다)
/// - DASH: 목록(MPD)에서 주소의 쿼리를 지운 글 전체
/// - 파일: 전체 크기 + 앞 64KB 의 해시 (앞부분만 따로 한 번 받는다)
/// 지문이 같으면 감지 목록에서 한 줄로 합친다. 지문을 못 만들면(거절 등) 합치지 않는다 — 잘못 합치는 것보다 따로 두는 게 낫다
enum WebFingerprint {
    static let fileHead = 64 * 1024

    static func hls(_ list: HLSPlaylist.Media) -> String? {
        guard !list.segments.isEmpty else { return nil }
        let durations = list.segments.map { String(format: "%.3f", $0.duration) }.joined(separator: ",")
        return "hls:\(list.segments.count):\(hash(Data(durations.utf8)))"
    }

    static func dash(_ data: Data) -> String? {
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        // 주소에 붙은 서명·만료 쿼리 (따옴표·태그·공백 전까지)
        let plain = text.replacingOccurrences(of: #"\?[^"'<>\s]*"#, with: "", options: .regularExpression)
        return "dash:\(hash(Data(plain.utf8)))"
    }

    /// 앞 64KB 만 받아 (서버가 Range 를 무시하고 통째로 주면 64KB 에서 끊는다)
    static func file(_ media: WebMedia, session: URLSession) async -> String? {
        let request = WebFetch.request(media.url, for: media, range: "bytes=0-\(fileHead - 1)")
        guard let (bytes, response) = try? await session.bytes(for: request),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return nil }
        var head = Data()
        head.reserveCapacity(fileHead)
        do {
            for try await byte in bytes {
                head.append(byte)
                if head.count >= fileHead { break }
            }
        } catch {
            return nil
        }
        bytes.task.cancel()
        guard !head.isEmpty else { return nil }
        let size = WebMediaClassifier.totalSize(http).map(String.init) ?? "-"
        return "file:\(size):\(hash(head))"
    }

    private static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).prefix(16).map { String(format: "%02x", $0) }.joined()
    }
}
