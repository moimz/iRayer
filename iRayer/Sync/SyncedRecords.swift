import Foundation
import Observation

/// iCloud 로 주고받는 작은 기록 묶음 하나 (2026-11-09: 폰 ↔ 맥 원격 웹 탐색).
/// 키 → 값. 이 기기에서 넣거나 빼면 올라가고, 다른 기기에서 넣거나 뺀 것은 받는다. 받은 것도 이 기기에 적어 둔다
/// (앱을 다시 켜면 iCloud 가 이미 받은 것을 다시 보내지 않으므로)
@MainActor
@Observable
final class SyncedRecords<Value: Codable & Equatable> {
    let kind: String
    private(set) var values: [String: Value] = [:]
    @ObservationIgnored private var stored: [String: Data] = [:]
    @ObservationIgnored private let storeKey: String
    /// 다른 기기에서 받았을 때 (키, 값)
    @ObservationIgnored var onReceive: ((String, Value) -> Void)?
    @ObservationIgnored private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return encoder
    }()

    init(kind: String) {
        self.kind = kind
        storeKey = "synced.\(kind)"
        if let data = UserDefaults.standard.data(forKey: storeKey),
           let saved = try? JSONDecoder().decode([String: Data].self, from: data) {
            stored = saved
            values = saved.compactMapValues { try? JSONDecoder().decode(Value.self, from: $0) }
        }
    }

    /// 넣거나 바꾼다 (내용이 같으면 올리지 않는다). 바뀌었으면 true
    @discardableResult
    func put(_ key: String, _ value: Value) -> Bool {
        guard let data = try? encoder.encode(value), stored[key] != data else { return false }
        stored[key] = data
        values[key] = value
        save()
        SyncEngine.shared.changed(kind, key: key)
        return true
    }

    func remove(_ key: String) {
        guard stored[key] != nil else { return }
        stored[key] = nil
        values[key] = nil
        save()
        SyncEngine.shared.changed(kind, key: key)
    }

    private func save() {
        if let data = try? JSONEncoder().encode(stored) { UserDefaults.standard.set(data, forKey: storeKey) }
    }

    var syncKind: SyncEngine.Kind {
        SyncEngine.Kind(name: kind) { [unowned self] in
            Array(stored.keys)
        } payload: { [unowned self] key in
            stored[key]
        } apply: { [unowned self] key, data in
            guard let value = try? JSONDecoder().decode(Value.self, from: data) else { return false }
            stored[key] = data
            values[key] = value
            save()
            onReceive?(key, value)
            return true
        } delete: { [unowned self] key in
            stored[key] = nil
            values[key] = nil
            save()
        }
    }
}
