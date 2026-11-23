#if os(iOS)
import CryptoKit
import LocalAuthentication
import SwiftUI
import UIKit

/// 앱 잠금 (2026-11-12, 사용자: iOS 의 앱 잠금은 알림 내용까지 가려서 앱 자체 잠금으로).
/// 바뀜 (2026-11-12, 사용자: 기기 암호면 iOS 기본 기능과 같다): 앱 암호를 따로 정한다. Face ID 는 함께 쓸 수 있고, 안 되면 앱 암호.
/// - 앱 암호는 이 기기 키체인에만 (iCloud 키체인으로 옮기지 않는다), 소금을 친 SHA-256 으로.
/// - 앱 전환 화면(멀티태스킹)에는 흐리게: 앱이 비활성으로 바뀌는 순간 덮개를 씌운다 (그때 찍힌 화면이 전환 화면에 쓰인다).
/// - 덮개는 맨 위의 따로 된 창이라 재생 화면처럼 전체 화면으로 띄운 것도 가린다. TV 화면(외부 화면)은 가리지 않는다.
///   암호 정하기·확인도 이 창에서 한다 (설정 Form 안의 창은 Form 이 다시 그려지면 닫히는 일이 있어서 — AdultFilter 참고).
/// - 기기마다 따로 (iCloud 로 넘기지 않는다).
@MainActor
@Observable
final class AppLock {
    static let shared = AppLock()
    static let passcodeAccount = "appLockPasscode"

    /// 백그라운드로 간 뒤 이만큼 지나 돌아오면 잠근다 (0 = 바로)
    static let delays: [(seconds: Int, title: String)] = [(0, "바로"), (60, "1분 뒤"), (300, "5분 뒤"), (900, "15분 뒤")]

    enum Mode: Equatable {
        /// 흐리게만 (앱 전환 화면)
        case privacy
        /// 잠김: 풀어야 쓴다
        case locked
        /// 지금 암호 확인 (끄기·바꾸기 전에)
        case verify(Purpose)
        /// 새 암호 정하기 (켜기·바꾸기)
        case create
        /// 다른 기능의 PIN (성인 등급 숨기기) — 내용은 prompt
        case prompt
    }
    enum Purpose: Equatable { case disable, change }

    private(set) var enabled: Bool { didSet { UserDefaults.standard.set(enabled, forKey: "appLock.enabled") } }
    var delay: Int { didSet { UserDefaults.standard.set(delay, forKey: "appLock.delay") } }
    var useBiometrics: Bool { didSet { UserDefaults.standard.set(useBiometrics, forKey: "appLock.biometrics") } }
    /// 바뀜 (2026-11-12, 사용자: 숫자 4자리·6자리로, 전화 자판 같은 화면): 암호 자릿수 (nil = 410 에서 정해 모름 — 다 넣고 [확인])
    private(set) var length: Int? { didSet { UserDefaults.standard.set(length, forKey: "appLock.length") } }
    /// 덮개 뒤에 깔 흐린 앱 화면 (바뀜 2026-11-12, 사용자: 앱 전환 화면이 완전 회색 → 흐린 화면으로)
    private(set) var backdrop: UIImage?
    /// 덮개가 떠 있으면 그 모양 (nil = 덮개 없음)
    private(set) var mode: Mode?
    private(set) var authenticating = false
    /// 틀린 횟수, 5번 넘게 틀리면 잠시 기다리게
    private(set) var failures = 0
    private(set) var waitUntil: Date?
    @ObservationIgnored private var backgroundAt: Date?
    /// 바뀜 (2026-11-13, 사용자: 암호를 치기 시작해도 Face ID 를 계속 시도한다): Face ID 창이 닫히면 앱이 다시 활성이 되어 또 시도했다 — 저절로는 백그라운드에서 돌아올 때 한 번만
    @ObservationIgnored private var autoBiometricsTried = false
    @ObservationIgnored private var window: UIWindow?
    /// 지금 Face ID 를 보고 있는 것 — 화면을 누르면 그만두고 암호 자판을 보인다
    @ObservationIgnored private var biometricsContext: LAContext?

    var locked: Bool { mode == .locked }

    /// 바뀜 (2026-11-12, 사용자: 앱 잠금 자판을 성인 등급 숨기기 PIN 에도): 같은 덮개·자판으로 PIN 을 정하거나 확인한다 (iOS, 맥은 글 칸 그대로)
    struct PINPrompt {
        let title: String
        /// 정하기면 두 번 받아 맞춘다
        let creating: Bool
        /// 자릿수 (정할 때는 6)
        let length: Int
        /// 받은 PIN 으로 할 일. false 면 틀렸다고 알린다
        let done: (String) -> Bool
    }
    private(set) var prompt: PINPrompt?

    func askPIN(title: String, creating: Bool, length: Int, done: @escaping (String) -> Bool) {
        prompt = PINPrompt(title: title, creating: creating, length: length, done: done)
        present(.prompt)
    }

    /// PIN 을 받았을 때 (덮개에서)
    func finishPrompt(_ pin: String) -> Bool {
        guard let prompt, prompt.done(pin) else { return false }
        self.prompt = nil
        dismiss()
        return true
    }

    private init() {
        let defaults = UserDefaults.standard
        let on = defaults.bool(forKey: "appLock.enabled") && Keychain.password(for: Self.passcodeAccount) != nil
        enabled = on
        delay = defaults.integer(forKey: "appLock.delay")
        useBiometrics = defaults.object(forKey: "appLock.biometrics") as? Bool ?? true
        length = defaults.object(forKey: "appLock.length") as? Int
        mode = on ? .locked : nil
    }

    /// Face ID · Touch ID · Optic ID (없으면 nil)
    var biometryName: String? {
        let context = LAContext()
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil) else { return nil }
        switch context.biometryType {
        case .faceID: return "Face ID"
        case .touchID: return "Touch ID"
        case .opticID: return "Optic ID"
        default: return nil
        }
    }

    // MARK: - 앱 상태

    /// 앱 장면 상태가 바뀔 때마다 (IRayerApp)
    func scenePhaseChanged(_ phase: ScenePhase) {
        switch phase {
        case .inactive:
            // 전환 화면에 찍히기 전에 덮는다 (Face ID 화면이 떠 있는 동안도 비활성 — 그때는 그대로)
            if enabled, mode == nil { present(.privacy) }
        case .background:
            // 암호를 정하거나 확인하던 중이면 그만둔다
            if case .create = mode { mode = nil }
            if case .verify = mode { mode = nil }
            if mode == .prompt { mode = nil; prompt = nil }
            guard enabled else { dismiss(); return }
            if mode == nil { present(.privacy) }
            if !locked { backgroundAt = .now }
            autoBiometricsTried = false
        case .active:
            guard enabled || mode == .create || mode == .prompt else { dismiss(); return }
            if mode == .privacy || mode == nil, let backgroundAt, Date.now.timeIntervalSince(backgroundAt) >= Double(delay) {
                present(.locked)
            }
            backgroundAt = nil
            if locked {
                present(.locked)   // 앱을 처음 켤 때는 아직 창이 없다
                if !autoBiometricsTried {
                    autoBiometricsTried = true
                    tryBiometrics()
                }
            } else if mode == .privacy, !authenticating {
                dismiss()
            }
        @unknown default:
            break
        }
    }

    // MARK: - 풀기

    /// Face ID 로 풀기 (켜 두었고 이 기기에 있으면)
    func tryBiometrics() {
        guard useBiometrics, biometryName != nil, !authenticating, waitUntil == nil || waitUntil! < .now else { return }
        guard let mode, mode == .locked || { if case .verify = mode { return true } else { return false } }() else { return }
        authenticating = true
        let context = LAContext()
        context.localizedFallbackTitle = "앱 암호 입력"
        context.localizedCancelTitle = "취소"
        biometricsContext = context
        Task {
            let ok = (try? await context.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: "iRayer 잠금을 풉니다")) ?? false
            if biometricsContext === context { biometricsContext = nil }
            authenticating = false
            if ok { passed() }
        }
    }

    /// 바뀜 (2026-11-13, 사용자: 기본 앱처럼 Face ID 중에 누르면 취소되고 암호 자판이 떠야): Face ID 를 그만두고 자판으로
    func cancelBiometrics() {
        biometricsContext?.invalidate()
        biometricsContext = nil
        authenticating = false
    }

    /// 앱 암호로 풀기. 틀리면 false
    func submit(_ passcode: String) -> Bool {
        if let waitUntil, waitUntil > .now { return false }
        guard Self.matches(passcode) else {
            failures += 1
            if failures >= 5 { waitUntil = .now.addingTimeInterval(30 * Double(failures - 4)) }
            return false
        }
        passed()
        return true
    }

    private func passed() {
        failures = 0
        waitUntil = nil
        switch mode {
        case .verify(.disable):
            enabled = false
            Keychain.deletePassword(for: Self.passcodeAccount)
            dismiss()
        case .verify(.change):
            present(.create)
        default:
            dismiss()
        }
    }

    // MARK: - 설정에서

    /// 켜기: 새 암호부터 / 끄기·바꾸기: 지금 암호(또는 Face ID) 확인부터
    func requestEnable() { present(.create) }
    func requestDisable() { present(.verify(.disable)); tryBiometrics() }
    func requestChange() { present(.verify(.change)); tryBiometrics() }

    func savePasscode(_ passcode: String) {
        let salt = (0..<16).map { _ in UInt8.random(in: 0...255) }
        let saltText = Data(salt).base64EncodedString()
        Keychain.setPassword(saltText + ":" + Self.hash(passcode, salt: saltText), for: Self.passcodeAccount, synchronizable: false)
        length = passcode.count
        enabled = true
        dismiss()
    }

    /// 정하기·확인을 그만둔다 (잠김은 그만둘 수 없다)
    func cancel() {
        guard !locked else { return }
        prompt = nil
        dismiss()
    }

    private static func hash(_ passcode: String, salt: String) -> String {
        Data(SHA256.hash(data: Data((salt + passcode).utf8))).base64EncodedString()
    }

    private static func matches(_ passcode: String) -> Bool {
        guard let stored = Keychain.password(for: passcodeAccount), let colon = stored.firstIndex(of: ":") else { return false }
        let salt = String(stored[..<colon])
        return hash(passcode, salt: salt) == String(stored[stored.index(after: colon)...])
    }

    // MARK: - 덮개 창

    private func present(_ mode: Mode) {
        self.mode = mode
        if window == nil {
            guard let scene = UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene })
                .first(where: { $0.session.role == .windowApplication }) else { return }
            let window = UIWindow(windowScene: scene)
            window.windowLevel = .alert + 1
            let host = UIHostingController(rootView: AppLockCover())
            host.view.backgroundColor = .clear
            window.rootViewController = host
            self.window = window
        }
        if window?.isHidden != false { backdrop = Self.blurredSnapshot(of: window?.windowScene, except: window) }
        window?.isHidden = false
        if mode != .privacy { window?.makeKey() }
    }

    private func dismiss() {
        mode = nil
        backdrop = nil
        guard let window, !window.isHidden else { return }
        window.isHidden = true
        // 자판 입력을 앱 본 창으로 돌려준다
        window.windowScene?.windows.first { $0 !== window && !$0.isHidden }?.makeKey()
    }
}

extension AppLock {
    /// 앱 본 창을 찍어 흐리게 (작게 줄여 흐리면 빠르다). 영상 층(Metal)은 찍히지 않아 검게 나올 수 있다
    fileprivate static func blurredSnapshot(of scene: UIWindowScene?, except cover: UIWindow?) -> UIImage? {
        guard let main = scene?.windows.first(where: { $0 !== cover && !$0.isHidden && $0.windowLevel == .normal }) else { return nil }
        let scale: CGFloat = 0.25
        let size = CGSize(width: main.bounds.width * scale, height: main.bounds.height * scale)
        guard size.width > 0, size.height > 0 else { return nil }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let small = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            main.drawHierarchy(in: CGRect(origin: .zero, size: size), afterScreenUpdates: false)
        }
        guard let input = CIImage(image: small) else { return small }
        let blurred = input.clampedToExtent().applyingGaussianBlur(sigma: 6).cropped(to: input.extent)
        guard let cg = CIContext().createCGImage(blurred, from: input.extent) else { return small }
        return UIImage(cgImage: cg)
    }
}

/// 덮개: 흐린 앱 화면 + 모드에 따라 숫자 자판
/// 바뀜 (2026-11-12, 사용자): 글 칸·자판 대신 아이폰 잠금 화면 같은 숫자 자판, 암호는 숫자 4자리·6자리
private struct AppLockCover: View {
    @State private var lock = AppLock.shared
    @State private var digits = ""
    /// 정하기: 처음 넣은 암호 (한 번 더 넣어 맞추기)
    @State private var first: String?
    private let newLength = 6
    @State private var message: String?
    @State private var shakes = 0

    var body: some View {
        ZStack {
            backdrop
            switch lock.mode {
            // 바뀜 (2026-11-13, 사용자: Face ID 중 화면이 애플 기본과 다르다): Face ID 를 보는 동안은 자판 없이 자물쇠만 — 아무 데나 누르면 그만두고 자판
            // 바뀜 (2026-11-13, 사용자: 아이폰은 Face ID 중에도 암호 자판이 보이는 게 애플 기본 같아 괜찮았다 — 아이패드만): 자물쇠 화면은 아이패드만
            case .locked where lock.authenticating && Self.isPad, .verify where lock.authenticating && Self.isPad: scanning
            case .locked: pad(title: "암호 입력", length: lock.length, cancellable: false, creating: false)
            case .verify(.disable): pad(title: "앱 잠금을 끄려면 암호 입력", length: lock.length, cancellable: true, creating: false)
            case .verify(.change): pad(title: "지금 암호 입력", length: lock.length, cancellable: true, creating: false)
            case .create: pad(title: first == nil ? "새 암호 입력" : "새 암호 다시 입력", length: newLength, cancellable: true, creating: true)
            case .prompt:
                if let prompt = lock.prompt {
                    pad(title: prompt.creating && first != nil ? "한 번 더 입력" : prompt.title, length: prompt.length, cancellable: true, creating: prompt.creating)
                }
            default: EmptyView()
            }
        }
        .environment(\.colorScheme, .dark)
        .onChange(of: lock.mode) { digits = ""; first = nil; message = nil }
    }

    private var scanning: some View {
        VStack(spacing: 14) {
            Image(systemName: "lock.fill").font(.system(size: 28)).foregroundStyle(.white)
            Text("눌러서 암호 입력").font(.footnote).foregroundStyle(.white.opacity(0.7))
        }
        .padding(.top, 60)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .contentShape(Rectangle())
        .onTapGesture { lock.cancelBiometrics() }
    }

    /// 바뀜 (2026-11-12, 사용자: 화면 아래가 흐려지지 않았다): 찍힌 화면에 빈 곳(투명)이 있어 뒤의 앱이 그대로 비쳤다 — 흐린 재료를 먼저 깐다
    private var backdrop: some View {
        Rectangle().fill(.thinMaterial)
            .overlay {
                if let image = lock.backdrop {
                    Image(uiImage: image).resizable().scaledToFill()
                }
            }
            .overlay(Color.black.opacity(lock.mode == .privacy ? 0.05 : 0.3))
            .clipped()
            .ignoresSafeArea()
    }

    /// 바뀜 (2026-11-12, 사용자): 아이폰 암호 화면처럼 — 위에 제목·점, 아래에 자판
    /// 바뀜 (2026-11-12, 사용자: 자판이 너무 아래로 처졌다): 맨 아래 글 줄을 없애고 0 줄 양옆에 Face ID·삭제, 위아래 여백을 같게
    private func pad(title: String, length: Int?, cancellable: Bool, creating: Bool) -> some View {
        // 바뀜 (2026-11-12, 사용자: 아직 아래다): 아이폰 잠금 화면 비율에 맞춰 위 여백을 줄이고(최대 120) 남는 자리는 아래로
        // 바뀜 (2026-11-13, 사용자: 아이패드에서 정렬이 안 맞다): 아이패드는 화면이 커서 위에 붙어 보였다 — 제목·점·자판 묶음을 화면 가운데에
        // 바뀜 (2026-11-13, 사용자: 가운데가 전혀 안 맞다 — 아래로 내려갔다): 아이패드는 여백 Spacer 대신 묶음 전체를 화면 가운데에 둔다 (가로·세로 모두, 아이패드 잠금 화면처럼)
        VStack(spacing: 0) {
            if !Self.isPad { Spacer(minLength: 24).frame(maxHeight: 100) }
            Text(title).font(.title3).foregroundStyle(.white)
            dots(length)
                .modifier(Shake(amount: CGFloat(shakes)))
                .padding(.top, 22)
            Text(message ?? " ")
                .font(.footnote).foregroundStyle(.white.opacity(0.85))
                .multilineTextAlignment(.center)
                .frame(minHeight: 40)
                .padding(.horizontal, 24)
            if Self.isPad { Color.clear.frame(height: 36) } else { Spacer(minLength: 12).frame(maxHeight: 36) }
            keypad(length: length, cancellable: cancellable, creating: creating)
            if !Self.isPad {
                Spacer(minLength: 24)
                Spacer(minLength: 0)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .disabled(lock.authenticating)
    }

    /// 넣은 자리 표시 (자릿수를 모르면 넣은 만큼만)
    private func dots(_ length: Int?) -> some View {
        HStack(spacing: 22) {
            ForEach(0..<(length ?? max(digits.count, 1)), id: \.self) { index in
                Circle()
                    .strokeBorder(.white, lineWidth: 1.2)
                    .background(Circle().fill(index < digits.count ? Color.white : .clear))
                    .frame(width: 13, height: 13)
            }
        }
        .frame(height: 16)
    }

    private static let isPad = UIDevice.current.userInterfaceIdiom == .pad
    private static let letters = ["", "ABC", "DEF", "GHI", "JKL", "MNO", "PQRS", "TUV", "WXYZ"]
    private static let keySize: CGFloat = 78
    private static let keyGap: CGFloat = 26

    private func keypad(length: Int?, cancellable: Bool, creating: Bool) -> some View {
        // 바뀜 (2026-11-13): 아이패드는 아이패드 암호 화면처럼 줄 사이를 조금 더
        VStack(spacing: Self.isPad ? 22 : 16) {
            ForEach(0..<3) { row in
                HStack(spacing: Self.keyGap) {
                    ForEach(1...3, id: \.self) { column in
                        let number = row * 3 + column
                        key(String(number), letters: Self.letters[number - 1], length: length, creating: creating)
                    }
                }
            }
            HStack(spacing: Self.keyGap) {
                leftKey(length: length, creating: creating).frame(width: Self.keySize, height: Self.keySize)
                key("0", letters: "", length: length, creating: creating)
                rightKey(cancellable: cancellable).frame(width: Self.keySize, height: Self.keySize)
            }
            .font(.body)
            .foregroundStyle(.white)
        }
    }

    /// 0 왼쪽: Face ID · [확인](자릿수를 모르는 옛 암호)
    /// 바뀜 (2026-11-12, 사용자): 새로 정하는 암호는 6자리만 (4자리로 바꾸기 단추를 뺀다). 빈칸이어도 자리를 지켜 0 이 가운데에 있게
    @ViewBuilder private func leftKey(length: Int?, creating: Bool) -> some View {
        if length == nil, !creating, !digits.isEmpty {
            Button("확인") { submit(length: nil, creating: false) }
        } else if !creating, lock.mode != .prompt, lock.useBiometrics, let name = lock.biometryName {
            Button { lock.tryBiometrics() } label: {
                Image(systemName: name == "Touch ID" ? "touchid" : "faceid")
                    .font(.system(size: 30))
                    .frame(width: Self.keySize, height: Self.keySize)
                    .contentShape(Circle())
            }
        } else {
            Color.clear
        }
    }

    /// 0 오른쪽: 넣은 게 있으면 삭제(전화 자판의 지우기 모양), 없으면 취소
    @ViewBuilder private func rightKey(cancellable: Bool) -> some View {
        if !digits.isEmpty {
            Button { digits.removeLast() } label: {
                Image(systemName: "delete.backward.fill")
                    .font(.system(size: 30))
                    .frame(width: Self.keySize, height: Self.keySize)
                    .contentShape(Circle())
            }
            .buttonStyle(HapticKeyStyle(delete: true))
        } else if cancellable {
            // 바뀜 (2026-11-12, 사용자): 취소도 아이콘으로
            Button { lock.cancel() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 26, weight: .medium))
                    .frame(width: Self.keySize, height: Self.keySize)
                    .contentShape(Circle())
            }
            .accessibilityLabel("취소")
        } else {
            Color.clear
        }
    }

    /// 바뀜 (2026-11-12, 사용자): 아이폰 암호 자판처럼 유리 단추 (누르면 빛나는 interactive glass) + 누를 때 햅틱
    private func key(_ digit: String, letters: String, length: Int?, creating: Bool) -> some View {
        Button {
            guard digits.count < (length ?? 12) else { return }
            digits.append(digit)
            if let length, digits.count == length {
                // 마지막 점이 채워진 것을 보인 뒤에
                Task {
                    try? await Task.sleep(for: .milliseconds(120))
                    submit(length: length, creating: creating)
                }
            }
        } label: {
            VStack(spacing: -2) {
                Text(digit).font(.system(size: 36, weight: .regular))
                if !letters.isEmpty { Text(letters).font(.system(size: 10, weight: .semibold)).tracking(2) }
            }
            .foregroundStyle(.white)
            .frame(width: Self.keySize, height: Self.keySize)
            .contentShape(Circle())
        }
        .buttonStyle(HapticKeyStyle())
        .glassEffect(.regular.interactive(), in: Circle())
    }

    private func submit(length: Int?, creating: Bool) {
        if creating {
            if let first {
                if digits == first {
                    if lock.mode == .prompt { _ = lock.finishPrompt(digits) } else { lock.savePasscode(digits) }
                } else {
                    fail("암호가 일치하지 않습니다. 다시 해 보세요.")
                    self.first = nil
                }
            } else {
                first = digits
                digits = ""
                message = nil
            }
            return
        }
        if lock.mode == .prompt {
            if !lock.finishPrompt(digits) { fail("PIN 이 맞지 않습니다.") }
            return
        }
        if lock.submit(digits) { return }
        if let wait = lock.waitUntil, wait > .now {
            fail("여러 번 틀렸습니다. \(Int(wait.timeIntervalSinceNow.rounded(.up)))초 뒤에 다시 해 보세요.")
        } else {
            fail("암호가 틀렸습니다.")
        }
    }

    private func fail(_ text: String) {
        message = text
        digits = ""
        UINotificationFeedbackGenerator().notificationOccurred(.error)
        withAnimation(.linear(duration: 0.4)) { shakes += 1 }
    }
}

/// 바뀜 (2026-11-12, 사용자: 손을 뗄 때 진동해서 어색하다): 자판 단추는 누르는 순간(터치다운) 가볍게 톡
/// 바뀜 (2026-11-13, 사용자: 아이패드는 햅틱이 없으니 키보드 소리라도, 지울 때도): 아이패드는 키보드 누름 소리 (지우기는 지우기 소리). 무음 모드면 나지 않는다
private struct HapticKeyStyle: ButtonStyle {
    var delete = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .onChange(of: configuration.isPressed) { _, pressed in
                guard pressed else { return }
                // 바뀜 (2026-11-13, 사용자: 키보드 소리를 못 내면 냅두자): 아이패드 소리는 뺀다 (시스템 소리·키보드 클릭 모두 나지 않았고 앱 소리는 너무 컸다). 햅틱은 없는 기기에서는 그냥 안 난다
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
            }
    }
}

/// 틀렸을 때 점을 좌우로 흔든다
private struct Shake: GeometryEffect {
    var amount: CGFloat
    var animatableData: CGFloat {
        get { amount }
        set { amount = newValue }
    }
    func effectValue(size: CGSize) -> ProjectionTransform {
        ProjectionTransform(CGAffineTransform(translationX: 10 * sin(amount * .pi * 4), y: 0))
    }
}

/// 설정 › 앱 잠금
struct AppLockSection: View {
    @State private var lock = AppLock.shared

    var body: some View {
        Section {
            Toggle("앱 잠금", isOn: Binding(get: { lock.enabled }, set: { $0 ? lock.requestEnable() : lock.requestDisable() }))
            if lock.enabled {
                if let name = lock.biometryName {
                    Toggle("\(name) 함께 쓰기", isOn: $lock.useBiometrics)
                }
                Picker("잠그는 때", selection: $lock.delay) {
                    ForEach(AppLock.delays, id: \.seconds) { Text($0.title).tag($0.seconds) }
                }
                Button("암호 바꾸기") { lock.requestChange() }
            }
        } header: {
            Text("앱 잠금")
        } footer: {
            Text("앱 암호(숫자 4자리·6자리)를 따로 정합니다 (기기 암호와 별개, 이 기기에만). 앱을 떠났다 돌아오면 잠그고, 앱 전환 화면에서는 흐리게 보입니다. iOS 의 앱 잠금과 달리 알림 내용은 가리지 않습니다.")
        }
    }
}
#endif
