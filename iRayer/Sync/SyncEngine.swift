import CloudKit
import CryptoKit
import Foundation
import Observation
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

/// 앱끼리(아이폰·아이패드…) iCloud 동기화. CloudKit 개인 데이터베이스의 전용 영역(zone)에 항목 하나를 레코드 하나로 둔다.
///
/// - 저장소마다 "종류(kind)" 를 등록한다: 항목 키 목록, 항목 내용(JSON), 받은 항목 적용·삭제.
/// - 바뀐 항목만 올린다. 저장소가 `changed` 로 알리거나, 목록형 저장소는 `publish` 로 지금 목록을 넘기면 달라진 것만 골라 올린다.
/// - 충돌은 항목마다 마지막으로 바꾼 시각(updatedAt)이 더 늦은 쪽을 쓴다 (서버 도착 순서가 아니라).
/// - 지운 항목은 레코드를 지워서 다른 기기에서도 지워진다.
/// - 기기마다 다른 것(이 기기 폴더, 외부 자막 북마크, 화면·자막 설정, 캐시)은 올리지 않는다.
@MainActor
@Observable
final class SyncEngine {
    static let shared = SyncEngine()

    /// 동기화할 종류 하나
    struct Kind {
        let name: String
        /// 지금 가진 항목 키 (처음 켤 때 모두 올린다)
        let keys: () -> [String]
        /// 항목 내용. nil 이면 없음(지워짐) 또는 동기화하지 않는 항목.
        let payload: (String) -> Data?
        /// 처음 올릴 때 쓸 바꾼 시각 (저장소가 시각을 가지고 있으면)
        var date: (String) -> Date? = { _ in nil }
        /// 받은 내용 적용. 내용을 못 읽으면 false (예: 새 판 앱이 올린 새 형식) — 받았다고 적지 않고 앱이 켜질 때마다 다시 받아 본다
        /// 바뀜 (2026-11-09): Void → Bool (못 읽은 레코드를 받은 것으로 적어 앱을 올린 뒤에도 다시 받지 않던 것)
        let apply: (String, Data) -> Bool
        let delete: (String) -> Void
    }

    /// 마지막 동기화 시각, 진행 중, 오류 (설정 화면에 보여준다)
    private(set) var lastSyncedAt: Date?
    private(set) var isSyncing = false
    private(set) var lastError: String?
    private(set) var accountAvailable = true

    @ObservationIgnored private var kinds: [String: Kind] = [:]
    @ObservationIgnored private var engine: CKSyncEngine?
    @ObservationIgnored private var state = SyncState()
    @ObservationIgnored private let database = CKContainer(identifier: "iCloud.com.moimz.iRayer").privateCloudDatabase
    /// 동기화 영역 (영상 키는 "#해시|크기")
    @ObservationIgnored private let zoneID = CKRecordZone.ID(zoneName: "iRayer", ownerName: CKCurrentUserDefaultName)
    /// 받은 것을 적용하는 동안에는 저장소의 변경 알림을 다시 올리지 않는다
    @ObservationIgnored private var applyingRemote = false
    /// 목록형 저장소가 마지막으로 넘긴 내용 (달라진 것만 고르려고)
    @ObservationIgnored private var published: [String: [String: Data]] = [:]
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    /// 받았지만 저장하지 못한 레코드 (예: 라이브러리가 그 에이전트보다 먼저 왔다). 받기가 끝나면 다시 적용한다.
    @ObservationIgnored private var unapplied: [CKRecord.ID: CKRecord] = [:]

    private static let recordType = "Item"
    private static var stateURL: URL {
        // iCloud 환경(개발·운영)마다 따로 둔다: 운영으로 바꾸면 빈 상태에서 시작해 영역을 만들고 전부 다시 올린다
        AppDatabase.directory.appending(path: "SyncState-Production.json")
    }

    private init() {}

    // MARK: - 시작

    func register(_ kind: Kind) {
        kinds[kind.name] = kind
    }

    /// 앱이 시작할 때 (저장소를 모두 등록한 뒤) 한 번
    func start() {
        guard engine == nil else { return }
        #if NOTICE_SETUP
        // 바뀜 (2026-11-12): 알림 구독을 개발 iCloud 에 한 번 만드는 임시 빌드 — 동기화는 하지 않는다 (운영 동기화 상태를 개발 환경에 쓰지 않게)
        return
        #endif
        if let data = try? Data(contentsOf: Self.stateURL), let decoded = try? JSONDecoder().decode(SyncState.self, from: data) {
            state = decoded
        }
        // 목록형 저장소의 지금 내용을 기준으로 둔다 (다음 publish 부터 달라진 것만)
        for (name, kind) in kinds {
            published[name] = Dictionary(uniqueKeysWithValues: kind.keys().compactMap { key in kind.payload(key).map { (key, $0) } })
        }
        var configuration = CKSyncEngine.Configuration(database: database, stateSerialization: state.engine, delegate: self)
        configuration.automaticallySync = true
        let engine = CKSyncEngine(configuration)
        self.engine = engine
        if state.engine == nil {
            engine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: zoneID))])
        }
        // 처음 켤 때, 그리고 새로 생긴 종류가 있으면 그 종류의 항목을 모두 올린다
        uploadAll(only: state.uploadedAll ? Set(kinds.keys).subtracting(state.uploadedKinds ?? []) : nil)
        Task { await refetchMissing() }
        #if os(iOS)
        UIApplication.shared.registerForRemoteNotifications()
        #else
        NSApplication.shared.registerForRemoteNotifications()
        #endif
    }

    /// 지금 바로 주고받기 (설정 화면, 앱으로 돌아올 때)
    func syncNow() async {
        guard let engine else { return }
        isSyncing = true
        defer { isSyncing = false }
        do {
            try await engine.fetchChanges()
            try await engine.sendChanges()
            lastSyncedAt = .now
            lastError = nil
        } catch {
            // iCloud 에 로그인하지 않은 기기(시뮬레이터 등)는 알기 쉽게
            let status = try? await CKContainer(identifier: "iCloud.com.moimz.iRayer").accountStatus()
            let notSignedIn = (error as? CKError).map { [.notAuthenticated, .accountTemporarilyUnavailable].contains($0.code) } ?? false
            if notSignedIn || status != .available {
                lastError = "iCloud 에 로그인되어 있지 않습니다"
            } else {
                lastError = error.localizedDescription
            }
        }
    }

    /// 바로 올리기 (2026-11-09: 폰 → 맥 명령). syncNow 는 받아 오기가 실패하면 올리지 않아, 명령이 엔진이 알아서 보낼 때(몇 분 뒤)까지 묵었다
    func sendNow(_ reason: String) async {
        guard let engine else { return }
        let start = Date.now
        do {
            try await engine.sendChanges()
            SyncLog.write("올림 (\(reason)) \(Int(Date.now.timeIntervalSince(start) * 1000))ms")
        } catch {
            SyncLog.write("올리기 실패 (\(reason)): \(error.localizedDescription)")
        }
    }

    /// 바로 받아 오기 (2026-11-09: 맥이 폰 명령을, 폰이 맥의 답을 기다릴 때). 이미 받는 중이면 건너뛴다
    func fetchNow() async {
        guard let engine, !fetching else { return }
        fetching = true
        defer { fetching = false }
        let start = Date.now
        do {
            // 바뀜 (2026-11-09): 이 앱 영역만 콕 집어 받는다 — 그냥 받으면 데이터베이스의 "바뀐 영역" 목록부터 보는데,
            //   그 목록이 몇 분씩 늦게 갱신되어 폰 명령이 3~4분 뒤에야 맥에 왔다
            try await engine.fetchChanges(.init(scope: .zoneIDs([zoneID])))
        } catch {
            SyncLog.write("받아 오기 실패: \(error.localizedDescription)")
        }
        let took = Date.now.timeIntervalSince(start)
        if took > 5 { SyncLog.write("받아 오기가 \(Int(took))초 걸림") }
    }
    @ObservationIgnored private var fetching = false

    // MARK: - 저장소가 부르는 것

    /// 항목 하나가 바뀌었거나 지워졌다 (자주 바뀌는 저장소: 재생 위치 등)
    func changed(_ kindName: String, key: String) {
        guard !applyingRemote, let kind = kinds[kindName] else { return }
        let name = Self.recordName(kindName, key)
        state.refs[name] = SyncState.Ref(kind: kindName, key: key)
        state.stamps[name] = .now
        if kind.payload(key) != nil {
            engine?.state.add(pendingRecordZoneChanges: [.saveRecord(CKRecord.ID(recordName: name, zoneID: zoneID))])
        } else {
            engine?.state.add(pendingRecordZoneChanges: [.deleteRecord(CKRecord.ID(recordName: name, zoneID: zoneID))])
        }
        scheduleSave()
    }

    /// 목록형 저장소: 지금 목록 전체를 넘기면 달라진 항목·지운 항목만 골라 올린다
    func publish(_ kindName: String) {
        guard !applyingRemote, let kind = kinds[kindName] else { return }
        let current = Dictionary(uniqueKeysWithValues: kind.keys().compactMap { key in kind.payload(key).map { (key, $0) } })
        let previous = published[kindName] ?? [:]
        published[kindName] = current
        for (key, data) in current where previous[key] != data {
            changed(kindName, key: key)
        }
        for key in previous.keys where current[key] == nil {
            changed(kindName, key: key)
        }
    }

    // MARK: - 내부

    private func uploadAll(only names: Set<String>? = nil) {
        var changes: [CKSyncEngine.PendingRecordZoneChange] = []
        for (name, kind) in kinds where names?.contains(name) ?? true {
            for key in kind.keys() where kind.payload(key) != nil {
                let recordName = Self.recordName(name, key)
                state.refs[recordName] = SyncState.Ref(kind: name, key: key)
                // 시각을 모르는 항목은 아주 옛날로: 다른 기기에서 실제로 바꾼 것이 이긴다
                if state.stamps[recordName] == nil {
                    state.stamps[recordName] = kind.date(key) ?? Date(timeIntervalSince1970: 0)
                }
                changes.append(.saveRecord(CKRecord.ID(recordName: recordName, zoneID: zoneID)))
            }
        }
        engine?.state.add(pendingRecordZoneChanges: changes)
        state.uploadedAll = true
        state.uploadedKinds = (state.uploadedKinds ?? []).union(names ?? Set(kinds.keys))
        scheduleSave()
    }

    private static func recordName(_ kind: String, _ key: String) -> String {
        let hash = SHA256.hash(data: Data(key.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
        return kind + "." + hash
    }

    /// 올릴 레코드 만들기 (예전에 받은 서버 정보가 있으면 그 위에: 그래야 서버가 같은 레코드로 알아본다)
    private func record(for id: CKRecord.ID) -> CKRecord? {
        guard let ref = state.refs[id.recordName], let kind = kinds[ref.kind], let payload = kind.payload(ref.key) else { return nil }
        let record: CKRecord
        if let fields = state.systemFields[id.recordName],
           let coder = try? NSKeyedUnarchiver(forReadingFrom: fields) {
            coder.requiresSecureCoding = true
            record = CKRecord(coder: coder) ?? CKRecord(recordType: Self.recordType, recordID: id)
            coder.finishDecoding()
        } else {
            record = CKRecord(recordType: Self.recordType, recordID: id)
        }
        record["kind"] = ref.kind
        record["key"] = ref.key
        record["payload"] = payload
        record["updatedAt"] = state.stamps[id.recordName] ?? .now
        return record
    }

    private func remember(_ record: CKRecord) {
        let coder = NSKeyedArchiver(requiringSecureCoding: true)
        record.encodeSystemFields(with: coder)
        state.systemFields[record.recordID.recordName] = coder.encodedData
    }

    private static let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "-"

    /// 못 읽은 레코드로 적는다 (이 앱 판에서는 다시 받지 않는다)
    private func markUnreadable(_ name: String, reason: String) {
        if state.unreadable?[name] != Self.build { SyncLog.write("못 읽음으로 적음: \(name) — \(reason) (빌드 \(Self.build))") }
        var unreadable = state.unreadable ?? [:]
        unreadable[name] = Self.build
        state.unreadable = unreadable
    }

    /// 받은 레코드 적용: 이 기기에서 더 나중에 바꾼 것이면 무시한다 (곧 이쪽 것이 올라간다)
    private func apply(_ record: CKRecord) {
        remember(record)
        guard let kindName = record["kind"] as? String, let key = record["key"] as? String,
              let payload = record["payload"] as? Data else { return }
        // 바뀜 (2026-11-09): 이 판이 모르는 종류(새 판 앱이 더한 것)도 못 읽은 것으로 적어 두고 앱을 올린 뒤 다시 받는다
        guard let kind = kinds[kindName] else {
            markUnreadable(record.recordID.recordName, reason: "모르는 종류 \(kindName)")
            return
        }
        let remoteDate = record["updatedAt"] as? Date ?? .distantPast
        let name = record.recordID.recordName
        // 시각이 같으면(둘 다 처음 올린 1970) 이 기기 것을 둔다
        if let local = state.stamps[name], local >= remoteDate, kind.payload(key) != nil {
            unapplied[record.recordID] = nil
            return
        }
        // 바뀜 (2026-11-09): 먼저 적용해 보고, 읽었을 때만 받은 시각을 적는다 (못 읽었는데 시각부터 적어 다시 받지 않던 것 — 287 TV시리즈)
        applyingRemote = true
        let applied = kind.apply(key, payload)
        applyingRemote = false
        guard applied else {
            unapplied[record.recordID] = nil
            markUnreadable(name, reason: "내용을 못 읽음 (\(kindName))")
            return
        }
        if state.unreadable?[name] != nil {
            state.unreadable?[name] = nil
            SyncLog.write("다시 받아 적용함: \(name) (빌드 \(Self.build))")
        }
        state.refs[name] = SyncState.Ref(kind: kindName, key: key)
        state.stamps[name] = remoteDate
        published[kindName]?[key] = payload
        unapplied[record.recordID] = kind.payload(key) == nil ? record : nil
    }

    /// 저장하지 못한 레코드를 다시 적용한다 (다른 레코드가 와서 풀릴 수 있으니 더 풀리지 않을 때까지)
    private func retryUnapplied() {
        var remaining = unapplied.count
        while remaining > 0 {
            for record in unapplied.values { apply(record) }
            guard unapplied.count < remaining else { break }
            remaining = unapplied.count
        }
    }

    /// 받았다고 기록했지만 이 기기에 없는 항목을 서버에서 다시 받아 적용한다
    /// (예전 판에서 저장하지 못한 채 넘어간 것. 이 기기에서 지우는 중인 것은 빼고)
    private func refetchMissing() async {
        guard let engine else { return }
        let deleting = Set(engine.state.pendingRecordZoneChanges.compactMap { change -> String? in
            if case .deleteRecord(let id) = change { return id.recordName } else { return nil }
        })
        let missing = state.refs.filter { name, ref in
            !deleting.contains(name) && kinds[ref.kind].map { $0.payload(ref.key) == nil } == true
        }
        // 바뀜 (2026-11-09): 내용을 못 읽었던 레코드도 — 그때와 앱 판이 달라졌을 때만 (같은 판이면 또 못 읽는다)
        let retry = (state.unreadable ?? [:]).filter { $0.value != Self.build && !deleting.contains($0.key) }.keys
        let names = Set(missing.keys).union(retry)
        guard !names.isEmpty else { return }
        if !retry.isEmpty { SyncLog.write("앱 판이 바뀌어 못 읽었던 \(retry.count)개를 다시 받음 (빌드 \(Self.build)): \(retry.sorted().prefix(10).joined(separator: ", "))") }
        let ids = names.map { CKRecord.ID(recordName: $0, zoneID: zoneID) }
        guard let results = try? await database.records(for: ids) else { return }
        for (id, result) in results {
            switch result {
            case .success(let record): unapplied[record.recordID] = record
            // 서버에서 지워졌으면 더 볼 것 없다
            case .failure(let error as CKError) where error.code == .unknownItem: state.unreadable?[id.recordName] = nil
            case .failure: break
            }
        }
        // 못 읽었던 것은 다시 적용해 본다 (또 못 읽으면 unreadable 에 남는다)
        for name in retry {
            if let record = unapplied[CKRecord.ID(recordName: name, zoneID: zoneID)] { apply(record) }
        }
        retryUnapplied()
        scheduleSave()
    }

    private func applyDeletion(_ id: CKRecord.ID) {
        let name = id.recordName
        state.systemFields[name] = nil
        state.unreadable?[name] = nil
        guard let ref = state.refs[name], let kind = kinds[ref.kind] else { return }
        state.refs[name] = nil
        state.stamps[name] = nil
        applyingRemote = true
        kind.delete(ref.key)
        published[ref.kind]?[ref.key] = nil
        applyingRemote = false
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            saveState()
        }
    }

    private func saveState() {
        try? FileManager.default.createDirectory(at: AppPaths.support, withIntermediateDirectories: true)
        try? JSONEncoder().encode(state).write(to: Self.stateURL, options: .atomic)
    }

    /// 다른 Apple ID 로 바뀌었거나 로그아웃: 동기화 기록만 지우고(이 기기 데이터는 그대로) 처음부터 다시
    private func resetForAccountChange() {
        state = SyncState()
        saveState()
        engine = nil
        start()
    }
}

// MARK: - CKSyncEngine

extension SyncEngine: CKSyncEngineDelegate {
    nonisolated func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
        await MainActor.run { self.handle(event) }
    }

    nonisolated func nextRecordZoneChangeBatch(_ context: CKSyncEngine.SendChangesContext, syncEngine: CKSyncEngine) async -> CKSyncEngine.RecordZoneChangeBatch? {
        let pending = syncEngine.state.pendingRecordZoneChanges.filter { context.options.scope.contains($0) }
        return await CKSyncEngine.RecordZoneChangeBatch(pendingChanges: pending) { id in
            await MainActor.run { self.record(for: id) }
        }
    }

    private func handle(_ event: CKSyncEngine.Event) {
        switch event {
        case .stateUpdate(let update):
            state.engine = update.stateSerialization
            scheduleSave()

        case .accountChange(let change):
            switch change.changeType {
            case .signIn:
                accountAvailable = true
                uploadAll()
            case .signOut, .switchAccounts:
                accountAvailable = false
                resetForAccountChange()
            @unknown default:
                break
            }

        case .fetchedRecordZoneChanges(let changes):
            // 이 앱의 영역 것만 (같은 데이터베이스의 1.0 영역 "iRayer" 레코드도 함께 내려온다)
            for modification in changes.modifications where modification.record.recordID.zoneID == zoneID { apply(modification.record) }
            for deletion in changes.deletions where deletion.recordID.zoneID == zoneID { applyDeletion(deletion.recordID) }
            lastSyncedAt = .now
            scheduleSave()

        case .sentRecordZoneChanges(let sent):
            for record in sent.savedRecords { remember(record) }
            for id in sent.deletedRecordIDs { state.systemFields[id.recordName] = nil }
            for failure in sent.failedRecordSaves {
                let id = failure.record.recordID
                switch failure.error.code {
                case .serverRecordChanged:
                    // 다른 기기가 먼저 바꿨다: 더 나중에 바꾼 쪽을 쓴다
                    guard let server = failure.error.serverRecord else { break }
                    let serverDate = server["updatedAt"] as? Date ?? .distantPast
                    if let local = state.stamps[id.recordName], local > serverDate {
                        remember(server)
                        engine?.state.add(pendingRecordZoneChanges: [.saveRecord(id)])
                    } else {
                        apply(server)
                    }
                case .zoneNotFound:
                    engine?.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: zoneID))])
                    engine?.state.add(pendingRecordZoneChanges: [.saveRecord(id)])
                case .unknownItem:
                    state.systemFields[id.recordName] = nil
                    engine?.state.add(pendingRecordZoneChanges: [.saveRecord(id)])
                case .networkFailure, .networkUnavailable, .zoneBusy, .serviceUnavailable, .notAuthenticated, .operationCancelled, .requestRateLimited:
                    // 엔진이 다시 시도한다
                    break
                default:
                    lastError = failure.error.localizedDescription
                }
            }
            lastSyncedAt = .now
            scheduleSave()

        case .fetchedDatabaseChanges(let changes):
            // 다른 기기에서 동기화 영역을 지웠으면 (데이터 초기화) 처음부터 다시 올린다
            if changes.deletions.contains(where: { $0.zoneID == zoneID }) {
                state.systemFields = [:]
                engine?.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: zoneID))])
                state.uploadedAll = false
                uploadAll()
            }

        case .willFetchChanges, .willSendChanges:
            isSyncing = true
        case .didFetchChanges:
            retryUnapplied()
            isSyncing = false
        case .didSendChanges:
            isSyncing = false
        default:
            break
        }
    }
}

/// 동기화로 주고받는 JSON (키 순서를 고정해 같은 내용은 같은 바이트가 되게)
let syncEncoder: JSONEncoder = {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return encoder
}()

/// 동기화 기록 (Application Support/SyncState-Production.json)
private struct SyncState: Codable {
    struct Ref: Codable {
        let kind: String
        let key: String
    }

    var engine: CKSyncEngine.State.Serialization?
    var uploadedAll = false
    /// 이미 모두 올린 종류 (나중에 추가된 종류는 따로 처음 올린다)
    var uploadedKinds: Set<String>? = []
    /// 레코드 이름 → 항목
    var refs: [String: Ref] = [:]
    /// 레코드 이름 → 마지막으로 바꾼 시각 (충돌 때 비교)
    var stamps: [String: Date] = [:]
    /// 레코드 이름 → 서버가 준 레코드 정보 (변경 태그 등)
    var systemFields: [String: Data] = [:]
    /// 받았지만 내용을 못 읽은 레코드 이름 → 그때의 앱 판(빌드 번호) (2026-11-09).
    /// 앱 판이 바뀐 뒤 켜질 때 다시 받아 본다. 예전 상태 파일에는 없어 옵셔널
    var unreadable: [String: String]?
}
