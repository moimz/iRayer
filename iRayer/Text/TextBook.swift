import Foundation
import Observation
import SwiftUI

// 텍스트 뷰어 (2026-11-08, 사용자 설계).
// 읽은 위치는 스크롤이 아니라 글자 위치(본문 처음부터 몇 번째 글자, UTF-16)로 저장한다 — 글꼴·크기·기기가 달라도 같은 문장에서 이어 읽는다.
// PlaybackStateStore 의 position = 글자 위치, duration = 전체 글자 수 (폴더 카드 진행 막대·iCloud 그대로).

/// 텍스트 파일의 인코딩 (파일마다 고를 수 있다)
enum TextEncoding: String, Codable, CaseIterable, Identifiable {
    case auto
    case utf8
    case cp949
    case utf16
    case shiftJIS

    var id: String { rawValue }

    var title: String {
        switch self {
        case .auto: "자동"
        case .utf8: "UTF-8"
        case .cp949: "한국어 (CP949)"
        case .utf16: "UTF-16"
        case .shiftJIS: "일본어 (Shift-JIS)"
        }
    }

    var encoding: String.Encoding? {
        switch self {
        case .auto: nil
        case .utf8: .utf8
        case .cp949: String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.dosKorean.rawValue)))
        case .utf16: .utf16
        case .shiftJIS: .shiftJIS
        }
    }

    /// 풀기. 자동이면 BOM → 엄격 UTF-8 → CP949 순으로 해 보고, 쓴 인코딩을 함께 돌려준다
    static func decode(_ data: Data, as choice: TextEncoding) -> (text: String, used: TextEncoding)? {
        if choice != .auto {
            guard let encoding = choice.encoding, let text = String(data: data, encoding: encoding) else { return nil }
            return (text.trimmingBOM, choice)
        }
        if data.starts(with: [0xEF, 0xBB, 0xBF]), let text = String(data: data, encoding: .utf8) { return (text.trimmingBOM, .utf8) }
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]), let text = String(data: data, encoding: .utf16) {
            return (text.trimmingBOM, .utf16)
        }
        // String(data:encoding: .utf8) 는 잘못된 바이트가 있으면 nil (엄격)
        if let text = String(data: data, encoding: .utf8) { return (text, .utf8) }
        if let encoding = TextEncoding.cp949.encoding, let text = String(data: data, encoding: encoding) { return (text, .cp949) }
        return nil
    }
}

private extension String {
    var trimmingBOM: String { hasPrefix("\u{FEFF}") ? String(dropFirst()) : self }
}

/// 파일마다 기억하는 설정 (iCloud 로 다른 기기에도). 글꼴·크기 등 보기 설정은 기기마다라 AppSettings 에 있다
struct TextFileSettings: Codable, Equatable {
    var encoding: TextEncoding = .auto
}

final class TextSettingsStore {
    static let shared = TextSettingsStore()
    static let fileKind = "textFile"

    fileprivate var files: [String: TextFileSettings] = [:]
    fileprivate let defaults = UserDefaults.standard
    private static let key = "textSettings.files"

    private init() {
        if let data = defaults.data(forKey: Self.key), let decoded = try? JSONDecoder().decode([String: TextFileSettings].self, from: data) {
            files = decoded
        }
    }

    func settings(for file: VideoFile) -> TextFileSettings {
        files[file.stateKey] ?? TextFileSettings()
    }

    func save(_ settings: TextFileSettings, for file: VideoFile) {
        files[file.stateKey] = settings
        persist()
        SyncEngine.shared.changed(Self.fileKind, key: file.stateKey)
    }

    fileprivate func persist() {
        defaults.set(try? JSONEncoder().encode(files), forKey: Self.key)
    }

    var syncKinds: [SyncEngine.Kind] {
        [
            SyncEngine.Kind(name: Self.fileKind) { [unowned self] in
                Array(files.keys)
            } payload: { [unowned self] key in
                files[key].flatMap { try? syncEncoder.encode($0) }
            } apply: { [unowned self] key, data in
                // 바뀜 (2026-11-09): 못 읽으면 지우지 않고 false (SyncEngine 이 나중에 다시 받는다)
                guard let value = try? JSONDecoder().decode(TextFileSettings.self, from: data) else { return false }
                files[key] = value
                persist()
                return true
            } delete: { [unowned self] key in
                files[key] = nil
                persist()
            },
        ]
    }
}

/// 텍스트 뷰어 밝기 (2026-11-08, 사용자: 앱을 다크로 두면 테마가 전부 어두운 쪽으로만 나왔다 — 앱 화면 모드와 따로, 애플 도서 앱처럼)
enum TextAppearance: String, CaseIterable, Identifiable {
    case system, light, dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: "앱 따라감"
        case .light: "밝게"
        case .dark: "어둡게"
        }
    }

    /// 실제로 어둡게 그릴지 (앱 따라감이면 지금 화면 모드)
    func isDark(_ scheme: ColorScheme) -> Bool {
        switch self {
        case .system: scheme == .dark
        case .light: false
        case .dark: true
        }
    }
}

/// 읽기 배경 테마 (애플 도서 앱처럼). 밝게/어둡게는 앱 화면 모드를 따른다 — 어두울 때도 새하얀 글자 대신 눈이 덜 부신 색
enum ReadingTheme: String, CaseIterable, Identifiable {
    case original, quiet, paper, bold, calm, focus

    var id: String { rawValue }

    var title: String {
        switch self {
        case .original: "원본"
        case .quiet: "조용함"
        case .paper: "종이"
        case .bold: "굵게"
        case .calm: "차분함"
        case .focus: "초점"
        }
    }

    /// (배경, 글자) — 0xRRGGBB
    private func hex(dark: Bool) -> (background: UInt32, text: UInt32) {
        switch (self, dark) {
        case (.original, false), (.bold, false): (0xFFFFFF, 0x1C1C1E)
        case (.original, true), (.bold, true): (0x121212, 0xD6D6D6)
        case (.quiet, false): (0x4A4A4D, 0xD4D4D6)
        case (.quiet, true): (0x2A2A2C, 0xA9A9AC)
        case (.paper, false): (0xEEEDEA, 0x2E2E2E)
        case (.paper, true): (0x1E1E1E, 0xBDBDBA)
        case (.calm, false): (0xF4E8D4, 0x4B3B2A)
        case (.calm, true): (0x2E2820, 0xD9C8AE)
        case (.focus, false): (0xFFFAEC, 0x262421)
        case (.focus, true): (0x1F1D18, 0xE3DCC8)
        }
    }

    var isBold: Bool { self == .bold }

    func colors(dark: Bool) -> (background: Color, text: Color) {
        let value = hex(dark: dark)
        return (Self.color(value.background), Self.color(value.text))
    }

    func platformColors(dark: Bool) -> (background: PlatformColor, text: PlatformColor) {
        let value = hex(dark: dark)
        return (Self.platform(value.background), Self.platform(value.text))
    }

    private static func color(_ hex: UInt32) -> Color {
        Color(red: Double(hex >> 16 & 0xFF) / 255, green: Double(hex >> 8 & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }

    private static func platform(_ hex: UInt32) -> PlatformColor {
        PlatformColor(red: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}

#if os(macOS)
import AppKit
typealias PlatformColor = NSColor
typealias PlatformFont = NSFont
#else
import UIKit
typealias PlatformColor = UIColor
typealias PlatformFont = UIFont
#endif

/// 읽을 글자 모양 (AppSettings 의 기기별 보기 설정을 묶은 것)
struct TextStyle: Equatable {
    var font: SubtitleFont
    var size: Double
    var lineSpacing: Double
    var margin: Double
    var theme: ReadingTheme

    static var current: TextStyle {
        let settings = AppSettings.shared
        return TextStyle(font: settings.textFont, size: settings.textSize, lineSpacing: settings.textLineSpacing,
                         margin: settings.textMargin, theme: settings.textTheme)
    }

    func platformFont() -> PlatformFont {
        let size = CGFloat(self.size)
        // 마루부리는 굵은 것(SemiBold)도 넣었다
        if font == .maruBuri, theme.isBold, let bold = PlatformFont(name: "MaruBuriot-SemiBold", size: size) { return bold }
        if font != .system, let custom = PlatformFont(name: font.rawValue, size: size) { return custom }
        return .systemFont(ofSize: size, weight: theme.isBold ? .semibold : .regular)
    }

    /// 본문 글자 속성 (글꼴·줄 간격·색)
    func attributes(dark: Bool) -> [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineHeightMultiple = CGFloat(lineSpacing)
        paragraph.lineBreakStrategy = .hangulWordPriority
        var attributes: [NSAttributedString.Key: Any] = [
            .font: platformFont(),
            .paragraphStyle: paragraph,
            .foregroundColor: theme.platformColors(dark: dark).text,
        ]
        // 나눔 글꼴은 굵은 것을 넣지 않아 "굵게" 테마에서는 획을 조금 두껍게
        if theme.isBold, font != .system, font != .maruBuri { attributes[.strokeWidth] = -1.5 }
        return attributes
    }
}

/// 연 텍스트 파일 하나
struct TextBook: Identifiable {
    let file: VideoFile
    /// 원래 바이트 (인코딩을 바꾸면 다시 푼다)
    let data: Data
    var text: String
    /// 실제로 쓴 인코딩 (자동이면 알아낸 것)
    var encoding: TextEncoding
    var id: URL { file.url }

    /// 이 크기보다 크면 열지 않는다 (소설 한 권은 보통 수 MB)
    static let maxBytes: Int64 = 64 << 20

    static let extensions: Set<String> = ["txt"]

    static func isText(_ url: URL) -> Bool {
        extensions.contains(url.pathExtension.lowercased())
    }
}
