import AppKit
import Observation

/// 웹에서 받은 영상의 저장 위치 (이 맥에만, 동기화하지 않는다).
/// 받기는 언제나 가장 좋은 화질로 전체를 받는다 (화질 고르기·구간 받기 없음).
@MainActor
@Observable
final class WebDownloadSettings {
    static let shared = WebDownloadSettings()

    private static let folderKey = "webDownloadFolder"

    /// 저장 폴더 (기본: 다운로드 폴더)
    var folder: URL {
        didSet { UserDefaults.standard.set(folder.path, forKey: Self.folderKey) }
    }

    private init() {
        if let path = UserDefaults.standard.string(forKey: Self.folderKey) {
            folder = URL(fileURLWithPath: path, isDirectory: true)
        } else {
            folder = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        }
    }

    /// 폴더 고르기 창
    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = folder
        panel.prompt = "선택"
        panel.message = "웹에서 받은 영상을 저장할 폴더를 고르세요."
        if panel.runModal() == .OK, let url = panel.url { folder = url }
    }

    /// 화면에 보일 경로 (홈 폴더는 ~)
    var displayPath: String {
        (folder.path as NSString).abbreviatingWithTildeInPath
    }
}
