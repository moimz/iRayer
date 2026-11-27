import Foundation
import Observation
#if os(macOS)
import AppKit
#endif

/// 다른 앱(파일 앱 등)에서 "iRayer로 열기"로 넘어온 영상 (1.2~, 2026-11-25 사용자: 파일 앱의 mkv 를 iRayer 로).
/// - 원래 자리에서 연다 (Info.plist 의 LSSupportsOpeningDocumentsInPlace). 넘어온 주소는 그 파일 하나만 읽을 권한이 있다.
/// - 앱이 아는 위치(이 기기·추가한 폴더·라이브러리 폴더) 안의 파일이면 평소처럼 재생 기록을 남긴다.
///   밖의 파일은 재생만 한다: 재생 위치·이어보기·동기화·장면 캡처를 모두 남기지 않는다
///   (다음에 다시 열 권한이 없어 이어보기에 남겨도 열 수 없다. 2026-11-25 사용자 결정).
/// - 바뀜 (2026-11-25, 사용자와 iNAS 조사): 파일 앱은 다른 앱에 넘길 경로를 NFD(자모 분리)로 만든다. 디스크 이름이 NFC 인
///   한글 파일(파일 제공 앱이 NFC 이름을 준 경우)은 샌드박스 정규 경로 검사에서 막혀 iRayer 가 주소 없이 뜨거나 아예 안 불린다.
///   iRayer 쪽으로는 못 고침 — iNAS 는 파일 앱에 이름을 NFD 로 줘서 해결 (iNAS 9d1041a, 빌드 26). Ai/iRayer.md 참고.
/// - 공통 부분(위치 판단·기록 여부)은 맥도 쓴다. 맥은 Finder "다음으로 열기 › iRayer" 로 넘어온다 (2026-11-27, InfoMac.plist 의 CFBundleDocumentTypes,
///   AppDelegate.application(_:open:)). 맥은 샌드박스가 없어 권한 문제는 없고, 기록 규칙(아는 위치 밖이면 재생만)은 같다.
@MainActor
enum OpenedFile {
    /// 밖에서 열어 기록을 남기지 않는 영상 주소들 (PlayerModel 이 본다)
    private static var transient: Set<URL> = []
    /// 열어 둔 보안 범위 접근 (다음 파일을 열 때 닫는다)
    private static var accessed: URL?

    /// 이 영상의 재생 기록을 남기는지 (밖에서 연 파일이면 false)
    static func keepsRecords(_ url: URL) -> Bool {
        !transient.contains(url)
    }

    /// 앱이 아는 위치 안인지: 이 기기(앱의 문서 폴더)·추가한 폴더·라이브러리의 로컬 폴더
    static func isKnownLocation(_ url: URL) -> Bool {
        let path = canonicalPath(url)
        let store = LocationStore.shared
        // 다른 앱이 원래 자리 대신 복사본을 주면(메일 첨부 공유 등) 앱의 Documents/Inbox 에 온다 → 이 기기 안이지만 밖에서 온 것
        let inbox = canonicalPath(store.documentsURL.appending(path: "Inbox", directoryHint: .isDirectory))
        if path.hasPrefix(inbox + "/") { return false }
        var roots = [store.documentsURL]
        roots += store.folders.compactMap { store.resolve($0) }
        roots += LibraryStore.shared.libraries.flatMap(\.folders).map(\.rootURL).filter(\.isFileURL)
        return roots.contains { root in
            let rootPath = canonicalPath(root)
            return path == rootPath || path.hasPrefix(rootPath + "/")
        }
    }

    /// /var ↔ /private/var 같은 차이를 없앤 경로 (폴더 주소 끝의 / 는 뗀다)
    private static func canonicalPath(_ url: URL) -> String {
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path(percentEncoded: false)
        return path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
    }

    /// 넘어온 파일 주소 → 재생할 영상. 영상이 아니면 nil. 접근 권한은 다음 파일을 열 때까지 열어 둔다.
    static func videoFile(for url: URL) -> VideoFile? {
        guard url.isFileURL, VideoFile.isVideo(url) else { return nil }
        if let previous = accessed, previous != url { previous.stopAccessingSecurityScopedResource() }
        if url.startAccessingSecurityScopedResource() { accessed = url }
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        // 같은 폴더의 자막: 파일 하나만 허락받은 경우 목록을 못 읽어 비어 있다 (아는 위치 안이면 읽힌다)
        let directory = url.deletingLastPathComponent()
        let siblings = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        let file = VideoFile(
            url: url,
            size: Int64(values?.fileSize ?? 0),
            modifiedAt: values?.contentModificationDate ?? .distantPast,
            subtitles: SubtitleLoader.sidecars(for: url, in: siblings)
        )
        if isKnownLocation(url) { transient.remove(url) } else { transient.insert(url) }
        return file
    }

    #if os(iOS)
    /// onOpenURL 에서 부른다: 영상이면 바로 재생 (아는 위치면 이어서, 아니면 처음부터)
    /// 바뀜 (2026-11-25, 사용자: "못 열면 다른 앱처럼 못 열었다고 알림이라도"): 영상이 아니거나 읽을 수 없으면 알림
    static func open(_ url: URL) {
        guard url.isFileURL else { return }
        let name = url.lastPathComponent
        guard VideoFile.isVideo(url) else {
            OpenFailure.shared.message = "‘\(name)’ 은(는) iRayer 가 재생할 수 있는 영상 형식이 아닙니다."
            return
        }
        guard let file = videoFile(for: url) else { return }
        guard isReadable(url) else {
            // 파일 앱이 넘겨준 권한으로 읽히지 않음 (예: NFD 한글 이름 경로가 디스크 이름과 어긋난 경우)
            OpenFailure.shared.message = "‘\(name)’ 을(를) 열 수 없습니다. 파일 앱이 iRayer 에 이 파일을 읽을 권한을 주지 않았습니다.\n\n설정 › 폴더 추가로 이 파일이 있는 폴더를 iRayer 에 추가하면 그 안에서 열 수 있습니다."
            return
        }
        PlayerHost.shared.play(file, resume: keepsRecords(url))
    }

    /// 실제로 앞부분이 읽히는지 (권한만 있고 못 읽는 경우를 거른다)
    private static func isReadable(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        return (try? handle.read(upToCount: 1)) != nil
    }
    #endif

    #if os(macOS)
    /// Finder 에서 연 파일들 (AppDelegate.application(_:open:)): 영상마다 재생 창을 연다. 영상이 아니거나 못 읽으면 알린다
    static func open(_ urls: [URL]) {
        var failed: [String] = []
        for url in urls where url.isFileURL {
            guard VideoFile.isVideo(url), FileManager.default.isReadableFile(atPath: url.path(percentEncoded: false)),
                  let file = videoFile(for: url) else {
                failed.append(url.lastPathComponent)
                continue
            }
            PlayerHost.shared.play(file, resume: keepsRecords(url))
        }
        guard !failed.isEmpty else { return }
        let alert = NSAlert()
        alert.messageText = failed.count == 1 ? "‘\(failed[0])’ 을(를) 열 수 없습니다." : "\(failed.count)개 파일을 열 수 없습니다."
        alert.informativeText = "iRayer 가 재생할 수 있는 영상 형식이 아니거나 읽을 수 없는 파일입니다." + (failed.count > 1 ? "\n\n" + failed.joined(separator: "\n") : "")
        alert.runModal()
    }
    #endif
}

#if os(iOS)
/// 다른 앱에서 넘어온 파일을 못 열었을 때 보여 줄 알림 (RootView 위에 뜬다)
@MainActor @Observable
final class OpenFailure {
    static let shared = OpenFailure()
    var message: String?
}
#endif
