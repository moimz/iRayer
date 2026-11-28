import Foundation
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif
import Observation

/// 화면 모드: 시스템 설정을 따르거나 라이트·다크로 고정
enum AppAppearance: String, CaseIterable {
    case system, light, dark

    var title: String {
        switch self {
        case .system: "시스템 설정에 따름"
        case .light: "라이트 모드"
        case .dark: "다크 모드"
        }
    }

    #if os(iOS)
    var style: UIUserInterfaceStyle {
        switch self {
        case .system: .unspecified
        case .light: .light
        case .dark: .dark
        }
    }
    #else
    var nsAppearance: NSAppearance? {
        switch self {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }
    #endif
}

/// 앱 전체 설정 (기기별로 저장, 동기화하지 않음)
@Observable
final class AppSettings {
    static let shared = AppSettings()

    private let defaults = UserDefaults.standard

    /// 좌우 더블탭으로 건너뛸 초
    var skipSeconds: Int {
        didSet { defaults.set(skipSeconds, forKey: Keys.skipSeconds) }
    }

    /// 드래그 탐색 감도: 1pt 당 이동할 초 (테스트하며 조절)
    var seekSecondsPerPoint: Double {
        didSet { defaults.set(seekSecondsPerPoint, forKey: Keys.seekSecondsPerPoint) }
    }

    /// 화면을 끌 때 방향(가로 탐색 / 세로 밝기·볼륨)을 정하기까지 움직일 거리 (pt)
    var gestureDecisionDistance: Double {
        didSet { defaults.set(gestureDecisionDistance, forKey: Keys.gestureDecisionDistance) }
    }

    /// 핀치 확대 최대 배율 (contain 기준, 테스트하며 조절)
    var maxZoomScale: Double {
        didSet { defaults.set(maxZoomScale, forKey: Keys.maxZoomScale) }
    }

    /// 화면 모드 (영상 앱이라 시스템이 라이트여도 다크로 고정할 수 있게)
    var appearance: AppAppearance {
        didSet {
            defaults.set(appearance.rawValue, forKey: Keys.appearance)
            applyAppearance()
        }
    }

    /// 앱의 모든 창(앱 화면·플레이어 창)에 화면 모드를 적용한다. TV(외부 화면) 장면은 건드리지 않는다.
    func applyAppearance() {
        #if os(iOS)
        for scene in UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }) where scene.session.role == .windowApplication {
            for window in scene.windows { window.overrideUserInterfaceStyle = appearance.style }
        }
        #else
        NSApp.appearance = appearance.nsAppearance
        #endif
    }

    /// 하드웨어 디코딩 사용 여부
    var hardwareDecoding: Bool {
        didSet { defaults.set(hardwareDecoding, forKey: Keys.hardwareDecoding) }
    }

    /// 네트워크(NAS·WebDAV) 영상을 미리 받아 두는 시간(초). 길수록 대역이 잠깐 떨어져도 끊기지 않지만, 시작·탐색이 그만큼 늦어질 수 있다.
    var networkBufferSeconds: Int {
        didSet { defaults.set(networkBufferSeconds, forKey: Keys.networkBufferSeconds) }
    }

    /// 레터박스(영상이 없는 위아래·좌우)를 영상 색으로 은은하게 채우기 (Infuse 방식)
    var ambientLetterbox: Bool {
        didSet { defaults.set(ambientLetterbox, forKey: Keys.ambientLetterbox) }
    }

    /// 재생 화면에 디버그 정보(연결·받는 속도·버퍼·VLC 상태) 보이기 (2026-11-28, 사용자: 느리거나 NAS 가 시끄러울 때 보려고)
    var playerDebugInfo: Bool {
        didSet { defaults.set(playerDebugInfo, forKey: Keys.playerDebugInfo) }
    }

    /// 자막 글꼴 (앱이 그리는 자막 + VLC 가 그리는 자막)
    var subtitleFont: SubtitleFont {
        didSet { defaults.set(subtitleFont.rawValue, forKey: Keys.subtitleFont) }
    }

    /// 자막 크기 배율 (1 = 기본: 가로 화면에서 짧은 변의 5.5%)
    var subtitleScale: Double {
        didSet { defaults.set(subtitleScale, forKey: Keys.subtitleScale) }
    }

    /// 자막 가장자리 (외곽선 / 그림자)
    var subtitleEdge: SubtitleEdge {
        didSet { defaults.set(subtitleEdge.rawValue, forKey: Keys.subtitleEdge) }
    }

    /// 만화책 자동 넘김 간격(초). 켜고 끄기는 보기 화면의 ▶/■ (2026-11-08, 사용자: 읽는 속도는 책이 아니라 사람 것이라 앱 전체에)
    var comicAutoSeconds: Int {
        didSet { defaults.set(comicAutoSeconds, forKey: Keys.comicAutoSeconds) }
    }
    static let comicAutoChoices = [3, 5, 10, 15, 20, 30, 60]

    // 텍스트 뷰어 보기 설정 (2026-11-08, 사용자: 파일마다가 아니라 기기마다 — 화면 크기가 달라 맞는 값이 다르다)
    var textFont: SubtitleFont {
        didSet { defaults.set(textFont.rawValue, forKey: Keys.textFont) }
    }
    /// 글자 크기 (pt)
    var textSize: Double {
        didSet { defaults.set(textSize, forKey: Keys.textSize) }
    }
    static let textSizeRange: ClosedRange<Double> = 12...36
    /// 줄 간격 (글자 높이의 배수)
    var textLineSpacing: Double {
        didSet { defaults.set(textLineSpacing, forKey: Keys.textLineSpacing) }
    }
    static let textLineSpacingRange: ClosedRange<Double> = 1.0...2.4
    /// 좌우 여백 (pt)
    var textMargin: Double {
        didSet { defaults.set(textMargin, forKey: Keys.textMargin) }
    }
    static let textMarginRange: ClosedRange<Double> = 0...80
    var textTheme: ReadingTheme {
        didSet { defaults.set(textTheme.rawValue, forKey: Keys.textTheme) }
    }
    /// 텍스트 뷰어 밝기 (앱 따라감·밝게·어둡게)
    var textAppearance: TextAppearance {
        didSet { defaults.set(textAppearance.rawValue, forKey: Keys.textAppearance) }
    }

    /// 앱을 쓰는 동안(화면에 떠 있는 동안) 자동 잠금 끄기. 재생 중에는 이 설정과 상관없이 늘 끈다.
    var keepScreenOn: Bool {
        didSet {
            defaults.set(keepScreenOn, forKey: Keys.keepScreenOn)
            applyIdleTimer(playing: isPlaying)
        }
    }

    /// 파일 옮기기·압축 풀기 중 (앱이 잠기면 멈추므로 자동 잠금을 끈다)
    var isTransferring = false {
        didSet { applyIdleTimer(playing: isPlaying) }
    }
    @ObservationIgnored private var isPlaying = false

    /// 자동 잠금 적용. 앱이 백그라운드로 가면 iOS 가 원래대로 돌리므로 다른 앱에는 영향이 없다.
    func applyIdleTimer(playing: Bool) {
        isPlaying = playing
        #if os(iOS)
        UIApplication.shared.isIdleTimerDisabled = playing || keepScreenOn || isTransferring
        #else
        MacSleepGuard.shared.preventSleep(playing || keepScreenOn || isTransferring)
        #endif
    }

    private init() {
        defaults.register(defaults: [
            Keys.skipSeconds: 10,
            Keys.seekSecondsPerPoint: 0.15,
            Keys.maxZoomScale: 2.0,
            Keys.gestureDecisionDistance: 25.0,
            Keys.hardwareDecoding: true,
            Keys.networkBufferSeconds: 10,
            Keys.keepScreenOn: false,
            Keys.ambientLetterbox: true,
            Keys.subtitleScale: 1.0,
            Keys.comicAutoSeconds: 10,
            Keys.textSize: 18.0,
            Keys.textLineSpacing: 1.5,
            Keys.textMargin: 20.0,
        ])
        skipSeconds = defaults.integer(forKey: Keys.skipSeconds)
        seekSecondsPerPoint = defaults.double(forKey: Keys.seekSecondsPerPoint)
        maxZoomScale = defaults.double(forKey: Keys.maxZoomScale)
        gestureDecisionDistance = defaults.double(forKey: Keys.gestureDecisionDistance)
        hardwareDecoding = defaults.bool(forKey: Keys.hardwareDecoding)
        networkBufferSeconds = defaults.integer(forKey: Keys.networkBufferSeconds)
        keepScreenOn = defaults.bool(forKey: Keys.keepScreenOn)
        ambientLetterbox = defaults.bool(forKey: Keys.ambientLetterbox)
        playerDebugInfo = defaults.bool(forKey: Keys.playerDebugInfo)
        subtitleFont = defaults.string(forKey: Keys.subtitleFont).flatMap(SubtitleFont.init) ?? .system
        subtitleScale = defaults.double(forKey: Keys.subtitleScale)
        comicAutoSeconds = defaults.integer(forKey: Keys.comicAutoSeconds)
        textFont = defaults.string(forKey: Keys.textFont).flatMap(SubtitleFont.init) ?? .system
        textSize = defaults.double(forKey: Keys.textSize)
        textLineSpacing = defaults.double(forKey: Keys.textLineSpacing)
        textMargin = defaults.double(forKey: Keys.textMargin)
        textTheme = defaults.string(forKey: Keys.textTheme).flatMap(ReadingTheme.init) ?? .original
        textAppearance = defaults.string(forKey: Keys.textAppearance).flatMap(TextAppearance.init) ?? .system
        subtitleEdge = defaults.string(forKey: Keys.subtitleEdge).flatMap(SubtitleEdge.init) ?? .outlineShadow
        appearance = defaults.string(forKey: Keys.appearance).flatMap(AppAppearance.init) ?? .system
    }

    private enum Keys {
        static let skipSeconds = "skipSeconds"
        static let seekSecondsPerPoint = "seekSecondsPerPoint"
        static let maxZoomScale = "maxZoomScale"
        static let gestureDecisionDistance = "gestureDecisionDistance"
        static let hardwareDecoding = "hardwareDecoding"
        static let networkBufferSeconds = "networkBufferSeconds"
        static let keepScreenOn = "keepScreenOn"
        static let ambientLetterbox = "ambientLetterbox"
        static let playerDebugInfo = "playerDebugInfo"
        static let subtitleFont = "subtitleFont"
        static let subtitleScale = "subtitleScale"
        static let subtitleEdge = "subtitleEdge"
        static let appearance = "appearance"
        static let comicAutoSeconds = "comicAutoSeconds"
        static let textFont = "textFont"
        static let textSize = "textSize"
        static let textLineSpacing = "textLineSpacing"
        static let textMargin = "textMargin"
        static let textTheme = "textTheme"
        static let textAppearance = "textAppearance"
    }
}
