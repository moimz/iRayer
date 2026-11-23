import Foundation

/// 앱 파일 위치 (2026-11-23, iRayer 로 옮기며).
/// 맥 앱은 샌드박스가 없어 `URL.applicationSupportDirectory`·`URL.cachesDirectory` 가 ~/Library/Application Support·Caches 자체라
/// 다른 앱과 섞이지 않게 앱 이름 폴더 안에 둔다. 아이폰·아이패드는 앱 저장 공간 안이라 원래부터 섞이지 않지만 같은 모양으로 맞춘다.
enum AppPaths {
    /// DB·동기화 상태·목록 파일: Application Support/iRayer
    static let support = URL.applicationSupportDirectory.appending(path: "iRayer", directoryHint: .isDirectory)

    /// 다시 만들 수 있는 것 (그림·미리보기·자막 등)
    static let caches: URL = {
        #if os(macOS)
        URL.cachesDirectory.appending(path: Bundle.main.bundleIdentifier ?? "com.moimz.iRayer", directoryHint: .isDirectory)
        #else
        URL.cachesDirectory
        #endif
    }()
}
