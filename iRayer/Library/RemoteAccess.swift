import Foundation
#if os(macOS)
import VLCKit
#else
import MobileVLCKit
#endif

/// 위치(로컬 / WebDAV / SMB)에 상관없이 파일을 다루는 공통 기능
enum RemoteAccess {
    enum AccessError: LocalizedError {
        case unauthorized
        case forbidden
        case http(Int)
        case unsupported
        case unreachable

        var errorDescription: String? {
            switch self {
            case .unauthorized: "아이디 또는 비밀번호가 맞지 않습니다."
            case .forbidden: "접근 권한이 없습니다. 이 계정에 WebDAV 사용 권한과 폴더 접근 권한이 있는지 확인해 주세요."
            case .http(let status): "서버 응답 오류 (\(status))"
            case .unsupported: "아직 지원하지 않는 위치입니다."
            case .unreachable: "서버에 연결할 수 없습니다. 주소와 네트워크를 확인해 주세요."
            }
        }
    }

    /// 접속 정보를 붙인 VLC 미디어.
    /// VLC 3 은 :http-user 같은 미디어 옵션을 보안상 무시하므로, 접속 정보를 주소(http://아이디:비밀번호@주소)에 넣는다.
    static func media(for url: URL, serverID: UUID?) -> VLCMedia {
        guard url.scheme != "file",
              let credential = LocationStore.shared.credential(for: serverID),
              var components = URLComponents(url: url, resolvingAgainstBaseURL: true) else {
            return VLCMedia(url: url)
        }
        components.user = credential.username
        components.password = credential.password
        return VLCMedia(url: components.url ?? url)
    }

    /// 작은 파일(자막 등) 전체 읽기
    static func data(of url: URL, serverID: UUID?) async throws -> Data {
        switch url.scheme {
        case "file":
            return try Data(contentsOf: url)
        case "http", "https":
            let (data, response) = try await URLSession.shared.data(for: request(url, serverID: serverID))
            try check(response)
            return data
        case "smb":
            return try await SMBClient.shared.data(of: url, serverID: serverID)
        default:
            throw AccessError.unsupported
        }
    }

    /// 접속 정보(Basic 인증)를 붙인 요청
    static func request(_ url: URL, serverID: UUID?, method: String = "GET") -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        if let credential = LocationStore.shared.credential(for: serverID) {
            let token = Data("\(credential.username):\(credential.password)".utf8).base64EncodedString()
            request.setValue("Basic \(token)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    static func check(_ response: URLResponse) throws {
        guard let status = (response as? HTTPURLResponse)?.statusCode else { return }
        if status == 401 { throw AccessError.unauthorized }
        // 403: 로그인은 됐지만 그 계정에 권한이 없다 (NAS 의 WebDAV 사용 권한, 폴더 권한 등)
        if status == 403 { throw AccessError.forbidden }
        if !(200..<300).contains(status) { throw AccessError.http(status) }
    }
}
