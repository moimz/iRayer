import CloudKit
import Foundation

/// 폰 ↔ 맥 명령·답을 CloudKit 레코드 이름으로 바로 읽고 쓴다 (2026-11-10, 사용자: A1).
/// 동기화 엔진(바뀐 것 목록으로 받기)으로는 폰 명령이 맥에 3~4분 뒤에야 왔다 — 레코드를 이름으로 콕 집어 읽으면 방금 쓴 것이 바로 보인다.
/// - 맥마다 받은편지함(inbox-맥id): 폰이 명령을 덧붙인다. 맥은 읽기만 하고 한 명령은 한 번만 한다 (10분 지난 명령은 폰이 덧붙일 때 뺀다)
/// - 맥마다 보낸편지함(outbox-맥id): 맥이 폰이 연 탭마다 찾은 영상을 통째로 쓴다. 폰은 기다리는 동안 읽는다
/// - 동기화 엔진 영역(iRayer)이 아니라 기본 영역에 둔다 (엔진이 받지 않게). 레코드 종류는 운영 스키마에 이미 있는 "Item" 의 payload 칸을 쓴다
///   (운영 환경에서는 앱이 새 종류를 만들 수 없다)
@MainActor
enum RemoteMailbox {
    struct Inbox: Codable {
        var commands: [MacCommand] = []
        /// 이때까지 폰이 웹 탐색을 보고 있다 — 맥이 그동안 자주 읽는다
        var phoneActiveUntil: Date?
    }

    struct Outbox: Codable, Equatable {
        var found: [MacFound] = []
        /// 맥에 열린 탭 (2026-11-10, 사용자: 폰 즐겨찾기 위에 보인다. 켜져 있음 기록은 동기화 엔진이라 늦어서 여기에도)
        var tabs: [MacPresence.Tab]?
    }

    private static let database = CKContainer(identifier: "iCloud.com.moimz.iRayer").privateCloudDatabase
    private static func inboxID(_ macID: String) -> CKRecord.ID { CKRecord.ID(recordName: "inbox-\(macID)") }
    private static func outboxID(_ macID: String) -> CKRecord.ID { CKRecord.ID(recordName: "outbox-\(macID)") }

    // MARK: 읽기·쓰기

    private static func read<T: Decodable>(_ id: CKRecord.ID, as type: T.Type) async -> (T?, CKRecord?) {
        do {
            let record = try await database.record(for: id)
            let value = (record["payload"] as? Data).flatMap { try? JSONDecoder().decode(T.self, from: $0) }
            return (value, record)
        } catch let error as CKError where error.code == .unknownItem {
            return (nil, nil)
        } catch {
            SyncLog.write("편지함 읽기 실패 \(id.recordName): \(error.localizedDescription)")
            return (nil, nil)
        }
    }

    /// 덮어쓰기 (같은 레코드를 둘이 쓰면 서버 것을 다시 읽어 고쳐 쓴다, 세 번까지)
    private static func update<T: Codable>(_ id: CKRecord.ID, as type: T.Type, empty: T, change: (inout T) -> Void) async -> Bool {
        for _ in 0 ..< 3 {
            let (value, existing) = await read(id, as: T.self)
            var next = value ?? empty
            change(&next)
            let record = existing ?? CKRecord(recordType: "Item", recordID: id)
            guard let data = try? JSONEncoder().encode(next) else { return false }
            record["payload"] = data
            record["updatedAt"] = Date.now
            do {
                _ = try await database.save(record)
                return true
            } catch let error as CKError where error.code == .serverRecordChanged {
                continue
            } catch {
                SyncLog.write("편지함 쓰기 실패 \(id.recordName): \(error.localizedDescription)")
                return false
            }
        }
        return false
    }

    // MARK: 폰

    /// 명령 보내기 (10분 지난 명령은 뺀다)
    static func send(_ command: MacCommand) async -> Bool {
        let start = Date.now
        let done = await update(inboxID(command.macID), as: Inbox.self, empty: Inbox()) { inbox in
            inbox.commands.removeAll { Date.now.timeIntervalSince($0.sentAt) > MacRemote.commandLifetime }
            inbox.commands.append(command)
            inbox.phoneActiveUntil = Date.now.addingTimeInterval(10 * 60)
        }
        SyncLog.write("편지함: 명령(\(command.action.rawValue)) 보냄 \(done ? "" : "실패 ")\(Int(Date.now.timeIntervalSince(start) * 1000))ms")
        return done
    }

    /// 폰이 웹 탐색을 보고 있다고 알린다 (맥이 10분 동안 2초마다 읽는다)
    static func markActive(_ macID: String) async {
        _ = await update(inboxID(macID), as: Inbox.self, empty: Inbox()) { inbox in
            inbox.commands.removeAll { Date.now.timeIntervalSince($0.sentAt) > MacRemote.commandLifetime }
            inbox.phoneActiveUntil = Date.now.addingTimeInterval(10 * 60)
        }
    }

    static func outbox(_ macID: String) async -> Outbox? {
        await read(outboxID(macID), as: Outbox.self).0
    }

    // MARK: 맥

    static func inbox(_ macID: String) async -> Inbox? {
        await read(inboxID(macID), as: Inbox.self).0
    }

    static func writeOutbox(_ macID: String, _ outbox: Outbox) async {
        _ = await update(outboxID(macID), as: Outbox.self, empty: Outbox()) { $0 = outbox }
    }
}
