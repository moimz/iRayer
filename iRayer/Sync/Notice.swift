import CloudKit
import Foundation
import UserNotifications

/// 기기 사이 알림 (2026-11-12, 사용자: 맥이 다 받으면 아이폰에 푸시).
/// 보내는 쪽(맥)이 CloudKit 개인 데이터베이스의 기본 영역에 레코드 하나를 남기면, 구독해 둔 아이폰·아이패드에 애플이 알림을 띄운다.
/// 푸시 키(.p8)·서버 없이 iCloud 동기화가 이미 가진 푸시 권한(aps-environment)만 쓴다.
/// 운영 iCloud 스키마에는 앱이 새 레코드 종류를 만들 수 없어 동기화와 같은 "Item" 종류를 빌려 쓴다: kind = 제목, key = 본문.
/// 기본 영역에만 두므로 동기화 영역(iRayer)과 섞이지 않는다. 구독은 iCloud 계정 단위라 켜고 끄면 모든 기기에 함께 적용된다.
enum Notice {
    private static let container = CKContainer(identifier: "iCloud.com.moimz.iRayer")
    private static let subscriptionID = "iRayer.notice"
    private static let recordType = "Item"
    /// 보낸 알림 레코드 (이름 → 보낸 시각). 하루 지난 것은 다음에 보낼 때 지운다
    private static let sentKey = "notice.sent"
    static let enabledKey = "notice.enabled"

    // MARK: - 보내기 (맥)

    static func send(title: String, body: String) {
        let name = "notice-" + UUID().uuidString
        let record = CKRecord(recordType: recordType, recordID: CKRecord.ID(recordName: name, zoneID: CKRecordZone.default().zoneID))
        record["kind"] = title
        record["key"] = body
        record["updatedAt"] = Date.now
        Task {
            let database = container.privateCloudDatabase
            do {
                _ = try await database.save(record)
                SyncLog.write("알림 보냄: \(title) — \(body)")
            } catch {
                SyncLog.write("알림 못 보냄: \(title) — \(error.localizedDescription)")
                return
            }
            var sent = UserDefaults.standard.dictionary(forKey: sentKey) as? [String: Date] ?? [:]
            sent[name] = .now
            let old = sent.filter { $0.value < .now.addingTimeInterval(-86_400) }.map(\.key)
            if !old.isEmpty {
                let ids = old.map { CKRecord.ID(recordName: $0, zoneID: CKRecordZone.default().zoneID) }
                _ = try? await database.modifyRecords(saving: [], deleting: ids)
                old.forEach { sent[$0] = nil }
            }
            UserDefaults.standard.set(sent, forKey: sentKey)
        }
    }

    // MARK: - 받기 (아이폰·아이패드)

    #if os(iOS)
    /// 켜기: 이 기기의 알림 허락을 묻고 iCloud 에 구독을 단다. 끄기: 구독을 뗀다 (모든 기기)
    static func setEnabled(_ on: Bool) async -> String? {
        UserDefaults.standard.set(on, forKey: enabledKey)
        let database = container.privateCloudDatabase
        if !on {
            do { _ = try await database.deleteSubscription(withID: subscriptionID) } catch let error as CKError where error.code == .unknownItem {} catch {
                return error.localizedDescription
            }
            return nil
        }
        let granted = (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])) ?? false
        if let error = await subscribe() { return error }
        return granted ? nil : "이 기기는 알림이 꺼져 있습니다 (iOS 설정 › 알림 › iRayer)"
    }

    /// 앱이 켜질 때: 켜 둔 상태면 구독을 다시 단다 (같은 이름이라 덮어쓴다)
    static func refresh() {
        guard UserDefaults.standard.bool(forKey: enabledKey) else { return }
        Task { _ = await subscribe() }
    }

    private static func subscribe() async -> String? {
        let subscription = CKQuerySubscription(recordType: recordType, predicate: NSPredicate(value: true),
                                               subscriptionID: subscriptionID, options: [.firesOnRecordCreation])
        subscription.zoneID = CKRecordZone.default().zoneID
        let info = CKSubscription.NotificationInfo()
        // 글 그대로 보여 준다 (번역 표에 없는 키는 키 자체가 형식 글이 된다)
        // 바뀜 (2026-11-12, 사용자: 내용 없이 "알림" 만 왔다): 키를 번역 표(ko.lproj/Localizable.strings)에 둔다 — 표에 없는 "%1$@" 키는 글로 바뀌지 않았다
        info.titleLocalizationKey = "notice.title"
        info.titleLocalizationArgs = ["kind"]
        info.alertLocalizationKey = "notice.body"
        info.alertLocalizationArgs = ["key"]
        info.soundName = "default"
        subscription.notificationInfo = info
        do {
            _ = try await container.privateCloudDatabase.save(subscription)
            SyncLog.write("알림 구독함")
            return nil
        } catch {
            SyncLog.write("알림 구독 못 함: \(error.localizedDescription)")
            return error.localizedDescription
        }
    }

    /// 앱을 보고 있을 때도 배너로 보여 준다
    final class Presenter: NSObject, UNUserNotificationCenterDelegate {
        static let shared = Presenter()
        func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
            // 바뀜 (2026-11-12, 사용자: 내용 없이 "1 알림" 만 온다): 받은 알림의 글과 원래 내용(aps)을 기록에 남긴다
            let content = notification.request.content
            let aps = (content.userInfo["aps"] as? [String: Any]).map { "\($0)" } ?? "-"
            SyncLog.write("알림 받음: 제목 [\(content.title)] 본문 [\(content.body)] aps \(aps)")
            return [.banner, .list, .sound]
        }
    }
    #endif
}
