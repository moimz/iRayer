import SwiftUI
import Observation

/// 만화책 열기 (폴더·홈·검색 어디서든). 암호를 묻고, 같은 폴더의 다음 권을 찾아 보기 화면을 띄운다.
/// 보기 화면은 앱 맨 위(`RootView`)에서 띄운다.
@Observable
final class ComicLauncher {
    static let shared = ComicLauncher()

    /// 지금 보는 책
    var book: ComicBook?
    /// 암호를 묻는 중
    var pending: (file: VideoFile, archive: any ComicArchive, siblings: [VideoFile])?
    var password = ""
    var errorMessage: String?
    /// RAR 을 받는 중 (이름, 받은 비율)
    var downloading: (name: String, fraction: Double)?

    /// 폴더마다 마지막으로 맞은 암호 (앱이 켜져 있는 동안). 같은 폴더의 다음 권에 먼저 써 본다.
    @ObservationIgnored private var passwords: [String: String] = [:]

    private init() {}

    private static func passwordKey(_ file: VideoFile) -> String {
        "\(file.serverID?.uuidString ?? "-")|\(file.url.deletingLastPathComponent().absoluteString)"
    }

    func savedPassword(for file: VideoFile) -> String? {
        #if DEBUG
        // 테스트용 실행 인자 `-debugArchivePassword <암호>` (시뮬레이터에서는 암호 입력란에 글자를 넣을 수 없어서)
        if let password = UserDefaults.standard.string(forKey: "debugArchivePassword") { return passwords[Self.passwordKey(file)] ?? password }
        #endif
        return passwords[Self.passwordKey(file)]
    }

    func remember(_ password: String, for file: VideoFile) {
        passwords[Self.passwordKey(file)] = password
    }

    /// 홈·검색에서 열 때: 압축 파일을 읽고 같은 폴더의 책 목록(다음 권)을 찾는다
    func open(_ file: VideoFile) async {
        do {
            let archive = try await load(file)
            let folder = FolderRoute(url: file.url.deletingLastPathComponent(), title: "", serverID: file.serverID)
            let siblings = (try? await DirectoryLister.list(folder).archives) ?? [file]
            await open(file, archive: archive, siblings: siblings)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// 압축 파일 열기. NAS 의 RAR 은 받아 두는 동안 진행률을 보여준다.
    func load(_ file: VideoFile) async throws -> any ComicArchive {
        guard ComicArchives.isRar(file.url), !RarCache.isLocal(file) else { return try await ComicArchives.open(file) }
        downloading = (file.name, 0)
        defer { downloading = nil }
        return try await ComicArchives.open(file) { fraction in
            Task { @MainActor in
                if ComicLauncher.shared.downloading != nil { ComicLauncher.shared.downloading = (file.name, fraction) }
            }
        }
    }

    /// 암호가 걸려 있으면 (기억해 둔 암호가 안 맞으면) 묻고 연다
    func open(_ file: VideoFile, archive: any ComicArchive, siblings: [VideoFile]) async {
        if archive.isEncrypted {
            if let saved = savedPassword(for: file), await archive.check(password: saved),
               let unlocked = try? await Self.unlock(archive, password: saved) {
                present(file, archive: unlocked, password: saved, siblings: siblings)
            } else {
                password = ""
                pending = (file, archive, siblings)
            }
        } else {
            present(file, archive: archive, password: nil, siblings: siblings)
        }
    }

    func submitPassword(_ request: (file: VideoFile, archive: any ComicArchive, siblings: [VideoFile])? = nil) async {
        guard let pending = request ?? pending else { return }
        self.pending = nil
        if await pending.archive.check(password: password), let unlocked = try? await Self.unlock(pending.archive, password: password) {
            remember(password, for: pending.file)
            present(pending.file, archive: unlocked, password: password, siblings: pending.siblings)
        } else {
            // 암호 창이 닫힐 때까지 기다렸다 띄운다 (바로 띄우면 iOS 가 무시한다)
            try? await Task.sleep(for: .milliseconds(500))
            errorMessage = ZipError.wrongPassword.localizedDescription
        }
    }

    /// 파일 목록까지 감춘 RAR 은 암호로 목록을 다시 읽는다
    static func unlock(_ archive: any ComicArchive, password: String) async throws -> any ComicArchive {
        guard let rar = archive as? RarArchive else { return archive }
        return try await rar.unlocked(password: password)
    }

    private func present(_ file: VideoFile, archive: any ComicArchive, password: String?, siblings: [VideoFile]) {
        let book = ComicBook(file: file, archive: archive, password: password, siblings: siblings)
        guard !book.pages.isEmpty else {
            errorMessage = "이미지가 없는 압축 파일입니다."
            return
        }
        self.book = book
    }
}

/// 만화 보기 화면과 암호 창을 붙인다 (앱 맨 위에 한 번)
struct ComicLauncherPresentations: ViewModifier {
    @State private var launcher = ComicLauncher.shared

    func body(content: Content) -> some View {
        content
            #if os(macOS)
            // 맥은 따로 뜬 만화 창에서 본다
            .onChange(of: launcher.book?.id) {
                guard let book = launcher.book else { return }
                launcher.book = nil
                ComicWindowHost.shared.show(book)
            }
            #else
            .fullScreenCoverOrSheet(item: $launcher.book) { book in
                ComicReaderView(book: book)
                    .onDisappear { ReturnHighlight.shared.returned(from: book.file) }
            }
            #endif
            .alert("암호", isPresented: Binding(
                get: { launcher.pending != nil },
                set: { if !$0 { launcher.pending = nil } }
            )) {
                SecureField("암호", text: $launcher.password)
                Button("취소", role: .cancel) {}
                Button("확인") {
                    // 알림이 닫히며 pending 이 먼저 지워지므로 누른 순간에 받아 둔다
                    let request = launcher.pending
                    Task { await launcher.submitPassword(request) }
                }
            } message: {
                Text("'\(launcher.pending?.file.name ?? "")'에 암호가 걸려 있습니다.")
            }
            .overlay(alignment: .top) {
                if let downloading = launcher.downloading {
                    HStack(spacing: 10) {
                        ProgressView(value: downloading.fraction)
                            .progressViewStyle(.circular)
                        VStack(alignment: .leading, spacing: 0) {
                            Text("RAR 받는 중 \(Int(downloading.fraction * 100))%").font(.footnote.weight(.semibold))
                            Text(downloading.name).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .glassEffect(.regular, in: .capsule)
                    .padding(.top, 8)
                    .padding(.horizontal)
                }
            }
            .alert("열 수 없습니다", isPresented: Binding(
                get: { launcher.errorMessage != nil },
                set: { if !$0 { launcher.errorMessage = nil } }
            )) {
                Button("확인", role: .cancel) {}
            } message: {
                Text(launcher.errorMessage ?? "")
            }
    }
}
