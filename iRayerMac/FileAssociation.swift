import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// 설정 › 파일 연결 (2026-11-27, 사용자): 영상 확장자마다 지금 기본 앱을 보이고, 토글로 iRayer 를 기본 앱으로 정한다.
/// - 기본 앱 바꾸기는 NSWorkspace.setDefaultApplication(at:toOpen:) (iSQL 의 SQLite 파일과 같은 방법). macOS 가 바꿀 때마다 한 번 확인을 묻는다.
/// - 기본 앱은 확장자가 아니라 형식(UTType)에 붙는다. mpg·mpeg, m2ts·mts 처럼 같은 형식인 확장자는 함께 바뀐다.
/// - 끄면 iRayer 로 바꾸기 전 앱으로 되돌린다 (기억해 둔 앱. 없거나 지워졌으면 그 형식을 여는 다른 앱 중 QuickTime Player → 처음 것).
///   macOS 에는 "기본 앱 없음" 이 없어 끄려면 다른 앱을 정해야 한다.
@MainActor
@Observable
final class FileAssociation {
    static let shared = FileAssociation()

    struct Row: Identifiable {
        let ext: String
        let type: UTType
        var id: String { ext }
        /// 지금 기본 앱 (없으면 nil)
        var app: URL?
        /// iRayer 로 열 수 있는 형식인지 (아니면 토글을 막는다)
        var openable: Bool
        var isOurs: Bool
    }

    private(set) var rows: [Row] = []
    var error: String?
    /// 바꾸는 중인 형식 (macOS 확인 창이 떠 있는 동안 토글을 막는다)
    private(set) var busy: Set<String> = []

    private static let previousKey = "fileAssociationPrevious"

    func refresh() {
        let workspace = NSWorkspace.shared
        rows = VideoFile.extensions.sorted().compactMap { ext in
            guard let type = UTType(filenameExtension: ext) else { return nil }
            let app = workspace.urlForApplication(toOpen: type)
            let openable = workspace.urlsForApplications(toOpen: type).contains(where: Self.isOurs)
            return Row(ext: ext, type: type, app: app, openable: openable, isOurs: app.map(Self.isOurs) ?? false)
        }
    }

    private static func isOurs(_ app: URL) -> Bool {
        Bundle(url: app)?.bundleIdentifier == Bundle.main.bundleIdentifier
    }

    static func appName(_ app: URL?) -> String {
        guard let app else { return "없음" }
        return FileManager.default.displayName(atPath: app.path(percentEncoded: false)).replacingOccurrences(of: ".app", with: "")
    }

    func set(_ row: Row, on: Bool) {
        let id = row.type.identifier
        guard !busy.contains(id) else { return }
        busy.insert(id)
        Task {
            defer { busy.remove(id); refresh() }
            do {
                if on {
                    // 되돌릴 앱을 기억해 둔다
                    if let app = row.app, !Self.isOurs(app) { remember(app, for: id) }
                    try await NSWorkspace.shared.setDefaultApplication(at: Bundle.main.bundleURL, toOpen: row.type)
                } else {
                    guard let app = previousApp(for: row.type) else {
                        error = "‘.\(row.ext)’ 을(를) 열 수 있는 다른 앱이 없어 되돌릴 수 없습니다."
                        return
                    }
                    try await NSWorkspace.shared.setDefaultApplication(at: app, toOpen: row.type)
                }
                error = nil
            } catch {
                // 사용자가 macOS 확인 창에서 취소한 경우도 여기로 온다
                self.error = "‘.\(row.ext)’ 의 기본 앱을 바꾸지 못했습니다: \(error.localizedDescription)"
            }
        }
    }

    private func remember(_ app: URL, for id: String) {
        var saved = UserDefaults.standard.dictionary(forKey: Self.previousKey) as? [String: String] ?? [:]
        saved[id] = app.path(percentEncoded: false)
        UserDefaults.standard.set(saved, forKey: Self.previousKey)
    }

    /// 끌 때 되돌릴 앱: 기억해 둔 앱 → QuickTime Player → 그 형식을 여는 다른 앱 중 처음 것
    private func previousApp(for type: UTType) -> URL? {
        let candidates = NSWorkspace.shared.urlsForApplications(toOpen: type).filter { !Self.isOurs($0) }
        let saved = UserDefaults.standard.dictionary(forKey: Self.previousKey) as? [String: String]
        if let path = saved?[type.identifier], FileManager.default.fileExists(atPath: path) {
            return URL(filePath: path)
        }
        return candidates.first { Bundle(url: $0)?.bundleIdentifier == "com.apple.QuickTimePlayerX" } ?? candidates.first
    }
}

/// 설정 › 파일 연결 탭
struct FileAssociationSettings: View {
    private var model = FileAssociation.shared

    var body: some View {
        Form {
            Section {
                ForEach(model.rows) { row in
                    LabeledContent {
                        HStack(spacing: 8) {
                            if let app = row.app {
                                Image(nsImage: NSWorkspace.shared.icon(forFile: app.path(percentEncoded: false)))
                                    .resizable().frame(width: 16, height: 16)
                            }
                            Text(FileAssociation.appName(row.app)).foregroundStyle(.secondary)
                            Toggle("", isOn: Binding(get: { row.isOurs }, set: { model.set(row, on: $0) }))
                                .labelsHidden()
                                .toggleStyle(.switch)
                                .disabled(!row.openable || model.busy.contains(row.type.identifier))
                        }
                    } label: {
                        Text(".\(row.ext)")
                        if let note = note(row) { Text(note) }
                    }
                }
            } header: {
                Text("영상 파일")
            } footer: {
                if let error = model.error {
                    Text(error).foregroundStyle(.red)
                } else {
                    Text("켜면 Finder 에서 두 번 눌러 iRayer 로 엽니다. 바꿀 때마다 macOS 가 한 번 확인을 묻습니다. 끄면 iRayer 로 바꾸기 전 앱으로 되돌립니다. 같은 형식인 확장자(mpg·mpeg, m2ts·mts)는 함께 바뀝니다. 다음으로 열기에는 켜지 않아도 늘 iRayer 가 있습니다.")
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { model.refresh() }
        // Finder 정보 창 등에서 바꾼 것도 보이게
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in model.refresh() }
    }

    /// 줄 아래 작은 설명
    private func note(_ row: FileAssociation.Row) -> String? {
        if !row.openable { return "이 맥이 영상 형식으로 알지 못해 정할 수 없습니다" }
        if row.ext == "ts" { return "TypeScript 코드 파일(.ts)도 같은 형식으로 보여 함께 바뀝니다" }
        return row.type.localizedDescription
    }
}
