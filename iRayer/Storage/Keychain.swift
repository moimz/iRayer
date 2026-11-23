import Foundation
import Security

/// 서버 비밀번호 저장소 (키체인). 기본은 iCloud 키체인으로 같은 Apple ID 의 기기끼리 동기화된다 (끝단 암호화).
/// 기기마다 다른 값은 synchronizable: false 로 이 기기에만 둔다.
enum Keychain {
    private static let service = "com.moimz.iRayer.server"

    static func password(for account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func setPassword(_ password: String, for account: String, synchronizable: Bool = true) {
        deletePassword(for: account)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: Data(password.utf8),
            kSecAttrSynchronizable as String: synchronizable,
            // iCloud 키체인으로 동기화되는 항목은 ThisDeviceOnly 를 쓸 수 없다
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        SecItemAdd(query as CFDictionary, nil)
    }

    static func deletePassword(for account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny,
        ]
        SecItemDelete(query as CFDictionary)
    }

    /// 동기화를 켜기 전에 이 기기에만 저장한 항목을 iCloud 키체인으로 옮긴다 (한 번만, 앱 시작 때)
    static func migrateToSynchronizable(except deviceOnly: Set<String>) {
        guard !UserDefaults.standard.bool(forKey: "keychainSynchronized") else { return }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrSynchronizable as String: false,
            kSecReturnAttributes as String: true,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]
        var result: AnyObject?
        if SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let items = result as? [[String: Any]] {
            for item in items {
                guard let account = item[kSecAttrAccount as String] as? String, !deviceOnly.contains(account),
                      let data = item[kSecValueData as String] as? Data, let value = String(data: data, encoding: .utf8) else { continue }
                setPassword(value, for: account, synchronizable: true)
            }
        }
        UserDefaults.standard.set(true, forKey: "keychainSynchronized")
    }
}
