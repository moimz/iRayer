import CoreGraphics
import QuickLookThumbnailing
import os

/// 장면을 못 뽑았을 때만 남긴다 (Console 에서 com.moimz.iRayer.thumbnail)
private let log = Logger(subsystem: "com.moimz.iRayer.thumbnail", category: "thumbnail")

/// 아이폰·아이패드 파일 앱 썸네일 (1.2~, 2026-11-25 사용자: "아이폰 안의 mkv 도 썸네일").
/// iOS 가 스스로 못 그리는 영상(MKV·AVI·WMV·FLV·WebM·RMVB 등, Support/Thumbnail-Info.plist 의 QLSupportedContentTypes)을
/// FFmpeg 로 한 장면 뽑아 그린다. 위치는 상관없다 (나의 iPhone·iCloud Drive·다른 앱 폴더).
/// NAS 파일은 iNAS 파일 제공 확장이 자기 썸네일을 따로 넘기므로 겹치지 않는다.
final class ThumbnailProvider: QLThumbnailProvider {
    /// 바뀜 (2026-11-25, 사용자: iNAS 썸네일 실패 정리 반영): 한 번에 하나씩.
    /// iNAS 에서 확장 메모리 한도가 약 20MB 라 FFmpeg 를 여럿 함께 돌리면 확장이 기록 없이 끝났다.
    /// 파일 앱은 폴더를 열면 썸네일을 한꺼번에 묻는다 → 차례로 줄 세운다 (모든 요청이 같은 확장 프로세스로 온다)
    private static let queue = DispatchQueue(label: "com.moimz.iRayer.thumbnail", qos: .userInitiated)

    override func provideThumbnail(for request: QLFileThumbnailRequest, _ handler: @escaping (QLThumbnailReply?, Error?) -> Void) {
        let maximum = request.maximumSize
        let pixels = max(64, Int(max(maximum.width, maximum.height) * request.scale))
        let url = request.fileURL
        // FFmpeg 는 읽는 동안 스레드를 붙잡으니 따로 큐에서
        Self.queue.async {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            guard let image = VideoFrame.image(path: url.path, maxPixels: pixels) else {
                log.error("장면 못 뽑음 \(url.lastPathComponent)")
                handler(nil, CocoaError(.fileReadCorruptFile))
                return
            }
            // 영상 비율을 지켜 maximumSize 안에 맞춘다 (포인트 단위, 그리기는 scale 배 픽셀로 된다)
            let ratio = CGFloat(image.width) / CGFloat(image.height)
            var size = maximum
            if ratio >= maximum.width / maximum.height {
                size.height = (maximum.width / ratio).rounded()
            } else {
                size.width = (maximum.height * ratio).rounded()
            }
            handler(QLThumbnailReply(contextSize: size, drawing: { context in
                context.interpolationQuality = .high
                // 그리기 판은 픽셀 단위(size × scale)로 온다 → 판 전체에 그린다
                context.draw(image, in: CGRect(x: 0, y: 0, width: context.width, height: context.height))
                return true
            }), nil)
        }
    }
}
