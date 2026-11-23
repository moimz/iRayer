import SwiftUI
import Observation

/// 성인 등급 숨기기 (기기마다, iCloud 로 넘기지 않는다): 켜면 성인 등급 작품(LibraryData.isAdult)이
/// 홈·라이브러리·둘러보기·검색·인물·이어보기·재생목록에서 빠지고, "숨김"을 켠 폴더도 빠진다.
/// 끌 때는 켤 때 정한 4자리 PIN 을 묻는다 (이 기기 키체인에만 둔다).
@Observable
final class AdultFilter {
    static let shared = AdultFilter()
    /// 키체인 계정 이름 (iCloud 키체인으로 옮기지 않는다)
    static let pinAccount = "adultFilterPIN"

    private(set) var isOn = UserDefaults.standard.bool(forKey: "hidesAdult")

    private init() {}

    func turnOn(pin: String) {
        Keychain.setPassword(pin, for: Self.pinAccount, synchronizable: false)
        set(true)
    }

    /// PIN 이 맞으면 끈다
    @discardableResult
    func turnOff(pin: String) -> Bool {
        guard check(pin) else { return false }
        Keychain.deletePassword(for: Self.pinAccount)
        set(false)
        return true
    }

    /// 정해 둔 PIN 자릿수 (예전 것은 4, 아이폰·아이패드에서 새로 정하면 6 — 2026-11-12)
    var pinLength: Int { Keychain.password(for: Self.pinAccount)?.count ?? 6 }

    func check(_ pin: String) -> Bool {
        Keychain.password(for: Self.pinAccount) == pin
    }

    private func set(_ on: Bool) {
        isOn = on
        UserDefaults.standard.set(on, forKey: "hidesAdult")
        // 열려 있는 목록·선반을 다시 읽게
        LibraryScanner.shared.refreshViews()
    }
}

/// 설정의 "성인 등급 숨기기" 칸: 켤 때 PIN 을 정하고, 끌 때 PIN 을 묻는다.
/// PIN 창은 이 칸이 아니라 Form 밖에 붙인다 (adultFilterPINSheet): Form 안의 칸에 붙이면 Form 이 다시 그려질 때
/// (앱을 켠 직후 iCloud 동기화 상태가 바뀔 때 등) 창이 뜨자마자 닫힌다.
struct AdultFilterSection: View {
    @State private var filter = AdultFilter.shared
    @Binding var asking: PINSheet.Purpose?

    var body: some View {
        Section {
            Toggle("성인 등급 숨기기", isOn: Binding(
                get: { filter.isOn },
                set: { asking = $0 ? .create : .unlock }
            ))
        } header: {
            Text("보호")
        } footer: {
            Text("청소년관람불가·제한상영가(미국 R·NC-17·TV-MA) 작품을 이 기기에서 숨깁니다. 폴더 설정에서 \"성인 등급 숨기기 중에는 숨김\"을 켠 폴더도 숨깁니다. 끌 때는 켤 때 정한 PIN 을 묻습니다.")
        }
    }
}

extension View {
    /// 성인 등급 숨기기 칸(AdultFilterSection)의 PIN 창. 그 칸이 든 Form 바깥에 붙인다.
    /// 바뀜 (2026-11-12, 사용자): 아이폰·아이패드는 앱 잠금과 같은 숫자 자판(6자리), 맥은 글 칸 그대로
    @ViewBuilder
    func adultFilterPINSheet(_ asking: Binding<PINSheet.Purpose?>) -> some View {
        #if os(iOS)
        onChange(of: asking.wrappedValue) { _, purpose in
            guard let purpose else { return }
            asking.wrappedValue = nil
            let filter = AdultFilter.shared
            AppLock.shared.askPIN(title: purpose == .create ? "성인 등급 숨기기 PIN 정하기" : "PIN 입력",
                                  creating: purpose == .create, length: purpose == .create ? 6 : filter.pinLength) { pin in
                switch purpose {
                case .create: filter.turnOn(pin: pin); return true
                case .unlock: return filter.turnOff(pin: pin)
                case .verify: return filter.check(pin)
                }
            }
        }
        #else
        sheet(item: asking) { purpose in
            PINSheet(purpose: purpose) { pin in
                let filter = AdultFilter.shared
                switch purpose {
                case .create: filter.turnOn(pin: pin); return true
                case .unlock: return filter.turnOff(pin: pin)
                case .verify: return filter.check(pin)
                }
            }
        }
        #endif
    }
}

/// 4자리 PIN 받기: 정할 때는 두 번, 풀 때는 한 번
/// 바뀜 (2026-11-12, 사용자: 맥은 키보드니 아무 글이나): 이제 맥만 쓴다 (아이폰·아이패드는 AppLock 숫자 자판). 숫자 4자리 대신 아무 글이나 (빈칸만 아니면)
struct PINSheet: View {
    enum Purpose: String, Identifiable {
        /// 켤 때 PIN 정하기, 끌 때 PIN 확인, 다른 설정을 바꿀 때 PIN 확인
        case create, unlock, verify
        var id: String { rawValue }
    }

    let purpose: Purpose
    /// 받은 PIN 으로 할 일. false 면 틀렸다고 알린다.
    let onDone: (String) -> Bool
    @Environment(\.dismiss) private var dismiss
    @State private var pin = ""
    @State private var again = ""
    @State private var message: String?

    private var valid: Bool {
        !pin.isEmpty && (purpose == .unlock || again == pin)
    }

    var body: some View {
        FormSheet(title: purpose == .create ? "PIN 정하기" : "PIN 입력",
                  confirmTitle: purpose == .create ? "켜기" : purpose == .unlock ? "끄기" : "확인",
                  confirmDisabled: !valid, macSize: CGSize(width: 360, height: 0)) {
            if onDone(pin) {
                dismiss()
            } else {
                message = "PIN 이 맞지 않습니다."
                pin = ""
            }
        } content: {
            Section {
                SecureField("PIN (아무 글이나)", text: $pin)
                    #if os(iOS)
                    .keyboardType(.numberPad)
                    #endif
                if purpose == .create {
                    SecureField("한 번 더", text: $again)
                        #if os(iOS)
                        .keyboardType(.numberPad)
                        #endif
                }
            } footer: {
                if let message {
                    Text(message).foregroundStyle(.red)
                } else {
                    Text(purpose == .create ? "끌 때와 숨긴 폴더 설정을 바꿀 때 이 PIN 을 묻습니다. 이 기기에만 저장됩니다." : "성인 등급 숨기기를 켤 때 정한 PIN 을 넣으세요.")
                }
            }
        }
    }
}
