import AppKit
import Security

/// inPlayer → iRayer 옮기기 (2026-11-23, 맥 첫 빌드에서만. 둘째 빌드에서 이 파일과 옛 키체인 그룹 권한을 뺀다).
/// 맥의 inPlayer 데이터를 **복사**만 한다 (옛 파일·설정·키체인은 그대로 둔다 — 문제가 생기면 inPlayer 를 그대로 다시 쓴다).
/// - Application Support 의 inPlayer2/ (SQLite) 와 목록 파일 → AppPaths.support. 동기화 상태(SyncState-*.json)는 빼서,
///   새 iCloud 저장소에 영역을 만들고 전부 올리게 한다 (SyncEngine.start 의 uploadAll)
/// - 설정(UserDefaults com.moimz.inPlayer) 전체 → 이 앱 설정. 동기화되는 목록(서버·폴더·즐겨찾기 등)도 여기 들어 있다
/// - 키체인(서비스 com.moimz.inPlayer.server): 옛 접근 그룹을 읽어 이 앱 서비스로 저장 (iCloud 키체인 항목은 폰으로도 간다)
/// 캐시·기록(Logs)·웹 탐색 데이터는 옮기지 않는다.
enum LegacyMigration {
    private static let doneKey = "migratedFromInPlayer"
    private static let oldBundleID = "com.moimz.inPlayer"
    private static let oldService = "com.moimz.inPlayer.server"
    private static let oldAccessGroup = "XSDBV8D2XL.com.moimz.inPlayer"

    /// 앱이 시작할 때 가장 먼저 (DB 를 열고 동기화를 시작하기 전)
    static func runIfNeeded() {
        guard !UserDefaults.standard.bool(forKey: doneKey) else { return }
        let oldSupport = URL.applicationSupportDirectory
        let oldDatabase = oldSupport.appending(path: "inPlayer2", directoryHint: .isDirectory)
        guard FileManager.default.fileExists(atPath: oldDatabase.path) else {
            // inPlayer 를 쓴 적이 없는 맥: 옮길 것이 없다
            UserDefaults.standard.set(true, forKey: doneKey)
            return
        }
        // 켜져 있는 inPlayer 가 DB 를 쓰는 중이면 반쯤 쓴 파일을 복사하게 된다
        if !NSRunningApplication.runningApplications(withBundleIdentifier: oldBundleID).isEmpty {
            let alert = NSAlert()
            alert.messageText = "inPlayer 를 끄고 다시 열어 주세요"
            alert.informativeText = "iRayer 가 처음 켜질 때 inPlayer 의 라이브러리·설정을 옮겨 옵니다. inPlayer 가 켜져 있으면 옮길 수 없습니다."
            alert.runModal()
            exit(0)
        }
        var log: [String] = []
        let fm = FileManager.default
        try? fm.createDirectory(at: AppPaths.support, withIntermediateDirectories: true)

        // 1. 파일
        let files = ((try? fm.contentsOfDirectory(atPath: oldDatabase.path)) ?? [])
            .filter { !$0.hasPrefix("SyncState") }
            .map { oldDatabase.appending(path: $0) }
            + ["MediaIndex.json", "AppleTVMovies.json", "TransferHistory.json"].map { oldSupport.appending(path: $0) }
        for source in files where fm.fileExists(atPath: source.path) {
            let target = AppPaths.support.appending(path: source.lastPathComponent)
            try? fm.removeItem(at: target)
            do { try fm.copyItem(at: source, to: target); log.append("파일 \(source.lastPathComponent)") }
            catch { log.append("파일 실패 \(source.lastPathComponent): \(error.localizedDescription)") }
        }

        // 2. 설정
        if let old = UserDefaults.standard.persistentDomain(forName: oldBundleID) {
            for (key, value) in old { UserDefaults.standard.set(value, forKey: key) }
            log.append("설정 \(old.count)개")
        }

        // 3. 키체인: iCloud 키체인(데이터 보호 키체인, 옛 접근 그룹)과 이 맥에만 둔 항목(로그인 키체인)
        var copied = 0
        for item in oldKeychainItems() {
            guard let account = item[kSecAttrAccount as String] as? String,
                  let data = item[kSecValueData as String] as? Data, let value = String(data: data, encoding: .utf8) else { continue }
            let synchronizable = (item[kSecAttrSynchronizable as String] as? Bool) ?? false
            Keychain.setPassword(value, for: account, synchronizable: synchronizable)
            copied += 1
        }
        log.append("키체인 \(copied)개")

        UserDefaults.standard.set(true, forKey: doneKey)
        SyncLog.write("inPlayer 에서 옮김: " + log.joined(separator: ", "))
    }

    private static func oldKeychainItems() -> [[String: Any]] {
        var found: [String: [String: Any]] = [:]
        let queries: [[String: Any]] = [
            [kSecUseDataProtectionKeychain as String: true, kSecAttrAccessGroup as String: oldAccessGroup,
             kSecAttrSynchronizable as String: kSecAttrSynchronizableAny],
            [kSecAttrSynchronizable as String: false],
        ]
        for extra in queries {
            var query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: oldService,
                kSecReturnAttributes as String: true,
                kSecReturnData as String: true,
                kSecMatchLimit as String: kSecMatchLimitAll,
            ]
            query.merge(extra) { $1 }
            var result: AnyObject?
            guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let items = result as? [[String: Any]] else { continue }
            for item in items {
                guard let account = item[kSecAttrAccount as String] as? String else { continue }
                // iCloud 키체인 쪽을 먼저 두고, 같은 이름이 이 맥에만 또 있으면 앞의 것을 쓴다
                if found[account] == nil { found[account] = item }
            }
        }
        return Array(found.values)
    }
}
