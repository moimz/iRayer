import Foundation
import Observation

/// 맥에서 받는 것 한 줄 (맥이 iCloud 로 올리고, 아이폰·아이패드가 받아 본다. 2026-11-09)
/// 주소·쿠키는 넣지 않는다
struct MacDownloadEntry: Codable, Equatable {
    var macID: String
    var macName: String
    var title: String
    /// "download" · "capture"
    var type: String
    /// 받는 중·멈춤·완료·실패 등 화면에 그대로 보일 글
    var status: String
    var fraction: Double?
    var active: Bool
    /// 이 항목을 처음 올린 때 (목록 순서)
    var since: Date
    /// 재생하며 받기: 영상 길이와 아직 못 받은 구간 [[시작, 끝], …] (초 단위로 반올림) — 막대에 빈 곳을 뚫어 그린다 (2026-11-09, 사용자).
    /// 예전 판이 올린 것에는 없다
    var duration: Double?
    var gaps: [[Double]]?

    /// 0 ~ 길이에서 빈 구간을 뺀 곳 = 받은 구간
    var received: [ClosedRange<Double>]? {
        guard let duration, duration > 0, let gaps else { return nil }
        var result: [ClosedRange<Double>] = []
        var cursor = 0.0
        for gap in gaps.compactMap({ $0.count == 2 ? $0[0] ... max($0[0], $0[1]) : nil }).sorted(by: { $0.lowerBound < $1.lowerBound }) {
            if gap.lowerBound > cursor { result.append(cursor ... min(gap.lowerBound, duration)) }
            cursor = max(cursor, gap.upperBound)
        }
        if cursor < duration { result.append(cursor ... duration) }
        return result
    }
}

#if os(iOS)
/// 아이폰·아이패드: 맥들이 올린 받는 현황 (2026-11-09, 사용자: 폰에서는 받지 않고 맥에서 받는 것을 본다).
/// - 받은 내용을 이 기기에도 적어 둔다 (앱을 다시 켜면 iCloud 가 이미 받은 것을 다시 보내지 않는다)
/// - [끝난 항목 지우기]: 모든 맥의 끝난 항목(받는 중 빼고)을 지운다 → 서버에서 지워져 맥과 다른 기기로 간다
@MainActor
@Observable
final class MacDownloads {
    static let shared = MacDownloads()
    static let syncKind = "macDownloads"
    private static let storeKey = "macDownloads.received"

    /// 키("맥 id/항목 id") → 받은 그대로
    private var stored: [String: Data] = [:]
    private(set) var entries: [String: MacDownloadEntry] = [:]

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.storeKey),
           let saved = try? JSONDecoder().decode([String: Data].self, from: data) {
            stored = saved
            entries = saved.compactMapValues { try? JSONDecoder().decode(MacDownloadEntry.self, from: $0) }
        }
    }

    /// 맥마다 묶어 (맥 이름 순), 묶음 안은 최근에 시작한 것 먼저
    var groups: [(mac: String, entries: [(key: String, entry: MacDownloadEntry)])] {
        Dictionary(grouping: entries.map { (key: $0.key, entry: $0.value) }, by: \.entry.macID)
            .map { (mac: $0.value.first?.entry.macName ?? "Mac", entries: $0.value.sorted { $0.entry.since > $1.entry.since }) }
            .sorted { $0.mac.localizedStandardCompare($1.mac) == .orderedAscending }
    }

    var hasFinished: Bool { entries.values.contains { !$0.active } }

    func clearFinished() {
        for (key, entry) in entries where !entry.active {
            entries[key] = nil
            stored[key] = nil
        }
        save()
        SyncEngine.shared.publish(Self.syncKind)
    }

    private func save() {
        if let data = try? JSONEncoder().encode(stored) { UserDefaults.standard.set(data, forKey: Self.storeKey) }
    }

    var syncKinds: [SyncEngine.Kind] {
        [SyncEngine.Kind(name: Self.syncKind) { [unowned self] in
            Array(stored.keys)
        } payload: { [unowned self] key in
            stored[key]
        } apply: { [unowned self] key, data in
            guard let entry = try? JSONDecoder().decode(MacDownloadEntry.self, from: data) else { return false }
            stored[key] = data
            entries[key] = entry
            save()
            return true
        } delete: { [unowned self] key in
            stored[key] = nil
            entries[key] = nil
            save()
        }]
    }
}
#endif
