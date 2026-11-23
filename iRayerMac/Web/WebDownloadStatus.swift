import AppKit
import Foundation
import Observation

/// 맥에서 받는 중인 것(받기·재생하며 받기)을 iCloud 로 올린다 (2026-11-09, 사용자) — 아이폰·아이패드가 현황을 보게 (보는 화면은 나중).
/// - 항목마다 레코드 하나 ("맥 id/항목 id"). 내용은 이름·상태 글·진행률 정도 (주소·쿠키는 넣지 않는다)
/// - 15초마다 지금 목록을 넘기고, 달라진 것만 올라간다 (진행률은 1% 단위라 매번 바뀌지 않는다). 목록에서 빠진 항목은 지운다
/// - 다른 맥의 항목도 받아 그대로 들고 있는다 (안 들고 있으면 다음 넘길 때 지운 것으로 보고 서버에서 지워 버린다)
/// - 끝난 항목은 지우지 않고 기록으로 둔다 — 폰에서 "아까 받던 거 어디 갔지?" 가 되지 않게 (사용자).
///   이 맥이 올린 것은 이 맥에도 적어 두었다가(UserDefaults) 앱을 다시 켜면 기록으로 들고, 받는 중이던 것은 "앱을 꺼서 멈춤" 으로 바꿔 올린다.
///   날짜로 저절로 지우지 않는다 — 어느 기기에서든 [끝난 항목 지우기] 를 누르면 모든 맥의 끝난 항목(받는 중 빼고)이 지워지고 그것이 동기화된다 (사용자)
/// 바뀜 (2026-11-10, 사용자): 맥 다운로드 화면도 폰처럼 iCloud 목록 전체를 보인다 — 지금 받는 것(live)은 그 화면이 직접 그리고,
///   나머지(앱을 다시 켜기 전 것·탭을 닫아 빠진 것·다른 맥의 것)는 extras. 이번에 켠 뒤 지금 목록에서 빠진 항목도 기록으로 남긴다
///   (전에는 탭을 닫으면 그 재생하며 받기가 서버에서도 지워졌다)
@MainActor
@Observable
final class WebDownloadStatus {
    static let shared = WebDownloadStatus()
    static let syncKind = "macDownloads"

    /// 한 줄 (아이폰·아이패드와 같이 쓴다)
    typealias Entry = MacDownloadEntry

    /// 이 맥을 가리키는 값 (처음 한 번 만들어 둔다)
    let macID: String = {
        if let id = UserDefaults.standard.string(forKey: "macDownloads.macID") { return id }
        let id = UUID().uuidString
        UserDefaults.standard.set(id, forKey: "macDownloads.macID")
        return id
    }()
    @ObservationIgnored private let macName = Host.current().localizedName ?? "Mac"
    /// 지금 받는 것 말고 화면에 더 보일 항목 (이 맥의 지난 것 + 다른 맥의 것)
    private(set) var extras: [String: Entry] = [:]
    /// 다른 맥이 올린 항목 (키 → 받은 내용)
    @ObservationIgnored private var others: [String: Data] = [:]
    /// 이 맥이 올린 항목 중 지금 목록에 없는 것 (지난번에 켰을 때 것, 이번에 끝나 빠진 것). 바뀜 (2026-11-10): 이번 것도 담는다
    @ObservationIgnored private var history: [String: Entry] = [:]
    /// 지금 목록 항목을 처음 본 때
    @ObservationIgnored private var firstSeen: [String: Date] = [:]
    /// 재생하며 받기의 영상 길이 (마지막에 본 것)
    @ObservationIgnored private var durations: [String: Double] = [:]
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return encoder
    }()

    private static let historyKey = "macDownloads.history"

    /// 지난번에 올린 이 맥의 항목을 기록으로 (받는 중이던 것은 멈춘 것으로)
    private init() {
        guard let data = UserDefaults.standard.data(forKey: Self.historyKey),
              let saved = try? JSONDecoder().decode([String: Entry].self, from: data) else { return }
        for (key, var entry) in saved {
            if entry.active {
                entry.active = false
                entry.status = "앱을 꺼서 멈춤"
                interrupted.insert(key)
            }
            history[key] = entry
        }
    }

    /// 앱을 다시 켜며 멈춘 것으로 바꾼 항목 (시작할 때 한 번 올린다)
    @ObservationIgnored private var interrupted: Set<String> = []

    /// 동기화를 시작한 뒤 한 번
    func start() {
        guard timer == nil else { return }
        for key in interrupted { SyncEngine.shared.changed(Self.syncKind, key: key) }
        interrupted = []
        timer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { _ in
            MainActor.assumeIsolated { WebDownloadStatus.shared.tick() }
        }
        refreshExtras()
    }

    /// 지금 목록을 넘기고(달라진 것만 올라간다) 이 맥에도 적어 둔다
    private func tick() {
        // 바뀜 (2026-11-10): 지금 목록에서 빠진 항목도 기록으로 (받는 중에 빠졌으면 멈춘 것으로)
        let live = live()
        for (key, var entry) in history where live[key] == nil && entry.active {
            entry.active = false
            entry.status = "멈춤"
            history[key] = entry
        }
        history.merge(live) { $1 }
        SyncEngine.shared.publish(Self.syncKind)
        let current = mine()
        if let data = try? JSONEncoder().encode(current) { UserDefaults.standard.set(data, forKey: Self.historyKey) }
        refreshExtras()
    }

    /// 지금 받는 것(화면이 직접 그린다)의 키
    func liveKeys() -> Set<String> { Set(live().keys) }

    private func refreshExtras() {
        let liveKeys = liveKeys()
        var result = mine().filter { !liveKeys.contains($0.key) }
        for (key, data) in others {
            if let entry = try? JSONDecoder().decode(Entry.self, from: data) { result[key] = entry }
        }
        if result != extras { extras = result }
    }

    /// [끝난 항목 지우기]: 모든 맥의 끝난 항목(받는 중 빼고)을 지운다 — 다음 넘길 때 서버에서도 지워져 다른 기기로 간다.
    /// 이 맥의 지금 목록(받기)은 WebDownloads 가 이미 뺐고, 저장을 마친 재생하며 받기는 패널에 남으니 여기서만 뺀다
    func clearHistory() {
        let finished = mine().filter { !$0.value.active }.keys
        dismissed.formUnion(finished)
        history = history.filter { $0.value.active }
        others = others.filter { (try? JSONDecoder().decode(Entry.self, from: $0.value))?.active ?? false }
        tick()
    }

    /// 지운 이 맥의 항목 (다음 넘길 때 다시 올리지 않게)
    @ObservationIgnored private var dismissed: Set<String> = []

    private func since(_ key: String) -> Date {
        if let date = firstSeen[key] { return date }
        firstSeen[key] = .now
        return .now
    }

    /// 이 맥의 항목: 지난 기록 + 지금 목록 (7일 지난 것은 뺀다)
    private func mine() -> [String: Entry] {
        let live = live()
        // 지운 뒤 다시 받기 시작했으면 다시 보인다
        for (key, entry) in live where entry.active { dismissed.remove(key) }
        return history.merging(live) { $1 }.filter { !dismissed.contains($0.key) }
    }

    /// 지금 목록: 받기 + 탭마다의 재생하며 받기
    private func live() -> [String: Entry] {
        var result: [String: Entry] = [:]
        for item in WebDownloads.shared.items {
            let fraction = item.state == .done ? 1 : item.progress.map { ($0 * 100).rounded() / 100 }
            result["\(macID)/\(item.id.uuidString)"] = Entry(macID: macID, macName: macName, title: item.file.lastPathComponent,
                                                            type: "download", status: Self.status(item), fraction: fraction,
                                                            active: item.isActive, since: since("\(macID)/\(item.id.uuidString)"))
        }
        for tab in WebTabs.shared.tabs where tab.capture.state != .off {
            let capture = tab.capture
            let key = "\(macID)/capture-\(ObjectIdentifier(capture).hashValue)"
            var entry = Entry(macID: macID, macName: macName, title: capture.title.isEmpty ? "재생하며 받기" : capture.title,
                              type: "capture", status: Self.status(capture), fraction: Self.fraction(capture), active: capture.isOn,
                              since: since(key))
            // 바뀜 (2026-11-09, 사용자): 폰 막대에 빈 곳이 보이게 길이·빈 구간도 (저장한 뒤에는 플레이어가 없어 마지막에 본 길이)
            if let duration = capture.playback?.duration { durations[key] = duration }
            // 받은 구간을 아직 셈하지 않았으면(받기 전) 빈 구간이 비어 있어 다 받은 것처럼 보이니 뺀다
            if let duration = durations[key], capture.frontier != nil || !capture.isOn {
                entry.duration = duration.rounded()
                entry.gaps = (capture.isOn ? capture.gaps : capture.savedHoles).map { [$0.lowerBound.rounded(), $0.upperBound.rounded()] }
            }
            result[key] = entry
        }
        return result
    }

    private static func status(_ item: WebDownloads.Item) -> String {
        switch item.state {
        case .running: item.note ?? "받는 중"
        case .retrying: "다시 시도하는 중"
        case .stopped: "멈춤"
        case .done: "완료"
        case .failed(let message): "실패: \(message)"
        }
    }

    private static func status(_ capture: WebCapture) -> String {
        let holes = capture.isOn ? capture.holes.count : capture.savedHoles.count
        let gaps = holes > 0 ? " (빈 구간 \(holes)개)" : ""
        switch capture.state {
        case .off: return ""
        case .waiting: return "재생을 기다리는 중"
        case .capturing: return (capture.fillingGaps ? "빈 구간 채우는 중" : "받는 중") + gaps
        case .saving: return "영상 묶는 중"
        case .saved: return "완료" + gaps
        case .failed(let message): return "실패: \(message)"
        }
    }

    /// 재생하며 받기: 받은 곳 / 전체 길이 (1% 단위)
    /// 바뀜 (2026-11-15, 사용자): Dock 진행률(DockProgress)도 같이 쓴다
    static func fraction(_ capture: WebCapture) -> Double? {
        if case .saved = capture.state { return 1 }
        guard let duration = capture.playback?.duration, duration > 0 else { return nil }
        let missing = capture.gaps.reduce(0) { $0 + ($1.upperBound - $1.lowerBound) }
        return (max(0, min(1, 1 - missing / duration)) * 100).rounded() / 100
    }

    var syncKinds: [SyncEngine.Kind] {
        [SyncEngine.Kind(name: Self.syncKind) { [unowned self] in
            Array(mine().keys) + Array(others.keys)
        } payload: { [unowned self] key in
            if let entry = mine()[key] { return try? encoder.encode(entry) }
            return others[key]
        } apply: { [unowned self] key, data in
            guard let entry = try? JSONDecoder().decode(Entry.self, from: data) else { return false }
            // 이 맥이 올린 것은 이 맥이 적어 둔 기록이 기준 (받아도 그대로)
            if entry.macID != macID { others[key] = data }
            refreshExtras()
            return true
        } delete: { [unowned self] key in
            // 다른 기기에서 [끝난 항목 지우기] 를 눌렀다: 이 맥의 것이면 다운로드 목록에서도 뺀다 (받는 중이면 둔다)
            others[key] = nil
            history[key] = nil
            dismissed.insert(key)
            let prefix = "\(macID)/"
            if key.hasPrefix(prefix), let id = UUID(uuidString: String(key.dropFirst(prefix.count))) {
                WebDownloads.shared.removeFinished(id: id)
            }
            refreshExtras()
        }]
    }
}
