import SwiftUI
import Observation

extension FolderRoute {
    var fileItem: FileItem { FileItem(url: url, serverID: serverID, isDirectory: true) }
}

extension VideoFile {
    var fileItem: FileItem { FileItem(url: url, serverID: serverID, isDirectory: false, size: size) }
}

/// 폴더 화면의 파일 관리 (선택·복사·이동·이름 바꾸기·삭제·새 폴더) 상태
@Observable
final class FileActionsModel {
    /// 고른 항목을 어디로 보낼지 고르는 중
    struct Pending: Identifiable {
        let id = UUID()
        let items: [FileItem]
        let move: Bool
    }

    var isSelecting = false
    var selection = Set<URL>()

    var pending: Pending?
    /// 목적지에 같은 이름이 있어 어떻게 할지 묻는 중
    var conflict: (pending: Pending, folder: FileItem, names: [String])?
    var renaming: FileItem?
    var newName = ""
    var creatingFolder = false
    var deleting: [FileItem] = []
    var errorMessage: String?

    // MARK: 압축 파일

    /// 압축 파일로 할 일
    enum ArchiveAction {
        case read
        case extract(deleteOriginal: Bool)
        /// 목록까지 감춘 RAR: 암호로 목록을 연 다음 무엇을 할지 정한다
        case unlock
    }

    struct ArchiveRequest: Identifiable {
        let id = UUID()
        let file: VideoFile
        let archive: any ComicArchive
        let action: ArchiveAction
        /// 만화로 볼 때 "다음 권" 을 찾을 같은 폴더의 압축 파일들
        var siblings: [VideoFile] = []
    }

    /// 그림 말고 다른 파일도 들어 있어 무엇을 할지 묻는 중
    var archiveChoice: ArchiveRequest?
    /// "압축 풀기" 를 골라 원본을 지울지 묻는 중
    var extractChoice: ArchiveRequest?
    /// 암호를 묻는 중
    var passwordRequest: ArchiveRequest?
    var password = ""
    /// 압축 파일을 여는 중 (목록을 읽는 동안)
    var openingArchive: URL?

    /// 압축 파일을 눌렀다: 그림만 있으면 만화로 열고, 다른 파일도 있으면 무엇을 할지 묻는다
    func open(_ file: VideoFile, siblings: [VideoFile]) async {
        guard let archive = await load(file) else { return }
        // 목록까지 감춘 RAR: 암호를 먼저 묻고 목록을 연 다음 아래처럼 나눈다
        if archive.kind == .locked {
            return await proceed(ArchiveRequest(file: file, archive: archive, action: .unlock, siblings: siblings))
        }
        await choose(ArchiveRequest(file: file, archive: archive, action: .read, siblings: siblings))
    }

    /// 만화책이면 보기 화면, 그림이 아닌 파일이 있으면 무엇을 할지 묻는다
    private func choose(_ request: ArchiveRequest) async {
        if [.comic, .lockedComic].contains(request.archive.kind) {
            await proceed(request)
        } else {
            archiveChoice = request
        }
    }

    /// 꾹 눌러 "압축 풀기": 원본을 지울지 묻는다
    func askExtract(_ file: VideoFile) async {
        guard let archive = await load(file) else { return }
        extractChoice = ArchiveRequest(file: file, archive: archive, action: .extract(deleteOriginal: false))
    }

    private func load(_ file: VideoFile) async -> (any ComicArchive)? {
        openingArchive = file.url
        defer { openingArchive = nil }
        do {
            return try await ComicLauncher.shared.load(file)
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    /// 암호가 걸려 있으면 (기억해 둔 암호가 안 맞으면) 묻고, 아니면 바로 한다. 만화 보기는 ComicLauncher 가 맡는다.
    func proceed(_ request: ArchiveRequest) async {
        if case .read = request.action {
            return await ComicLauncher.shared.open(request.file, archive: request.archive, siblings: request.siblings)
        }
        guard request.archive.isEncrypted else { return await run(request, password: nil) }
        openingArchive = request.file.url
        let saved = ComicLauncher.shared.savedPassword(for: request.file)
        let savedWorks = if let saved { await request.archive.check(password: saved) } else { false }
        openingArchive = nil
        if let saved, savedWorks {
            return await run(request, password: saved)
        }
        password = ""
        passwordRequest = request
    }

    /// 암호를 입력했다. request 는 버튼을 누른 순간에 받아 둔다
    /// (알림이 닫히며 passwordRequest 가 먼저 지워지므로, Task 안에서 읽으면 이미 nil 이다).
    func submitPassword(for request: ArchiveRequest?) async {
        guard let request else { return }
        passwordRequest = nil
        let password = self.password
        // 확인하는 동안 카드에 도는 표시
        openingArchive = request.file.url
        let correct = await request.archive.check(password: password)
        openingArchive = nil
        if correct {
            ComicLauncher.shared.remember(password, for: request.file)
            await run(request, password: password)
        } else {
            await showError(ZipError.wrongPassword.localizedDescription)
        }
    }

    /// 알림 바로 뒤에 다른 알림을 띄우면 iOS 가 무시하므로, 앞 알림이 닫힐 때까지 조금 기다린다
    private func showError(_ message: String) async {
        try? await Task.sleep(for: .milliseconds(500))
        errorMessage = message
    }

    private func run(_ request: ArchiveRequest, password: String?) async {
        switch request.action {
        case .read:
            break
        case .unlock:
            guard let password else { return }
            openingArchive = request.file.url
            let unlocked = try? await ComicLauncher.unlock(request.archive, password: password)
            openingArchive = nil
            guard let unlocked else { return await showError(ZipError.wrongPassword.localizedDescription) }
            try? await Task.sleep(for: .milliseconds(500))
            await choose(ArchiveRequest(file: request.file, archive: unlocked, action: .read, siblings: request.siblings))
        case .extract(let deleteOriginal):
            // 파일 목록까지 감춘 RAR 은 암호로 목록을 다시 읽는다
            var archive = request.archive
            if let password, let unlocked = try? await ComicLauncher.unlock(archive, password: password) { archive = unlocked }
            TransferCenter.shared.extract(request.file.fileItem, archive: archive, password: password, deleteOriginal: deleteOriginal)
        }
    }

    func with(_ request: ArchiveRequest, _ action: ArchiveAction) -> ArchiveRequest {
        ArchiveRequest(file: request.file, archive: request.archive, action: action, siblings: request.siblings)
    }

    func select(_ on: Bool) {
        selection = []
        withAnimation { isSelecting = on }
    }

    func toggle(_ url: URL) {
        if selection.contains(url) { selection.remove(url) } else { selection.insert(url) }
    }

    /// 목적지를 골랐다: 같은 이름이 있으면 먼저 묻는다
    func send(_ pending: Pending, to folder: FileItem) async {
        let existing = Set(((try? await FileOperations.children(of: folder)) ?? []).map { $0.name.precomposedStringWithCanonicalMapping })
        let names = pending.items.map(\.name).filter { existing.contains($0.precomposedStringWithCanonicalMapping) }
        // 같은 폴더로 이동은 할 일이 없다
        if pending.move, pending.items.allSatisfy({ $0.url.deletingLastPathComponent().standardizedFileURL == folder.url.standardizedFileURL && $0.serverID == folder.serverID }) {
            return
        }
        if names.isEmpty {
            TransferCenter.shared.transfer(pending.items, to: folder, move: pending.move, conflict: .skip)
        } else {
            conflict = (pending, folder, names)
        }
        select(false)
    }
}

/// 파일 관리 시트·알림을 폴더 화면에 붙인다
struct FileActionsPresentations: ViewModifier {
    @Bindable var model: FileActionsModel
    /// 지금 폴더 (새 폴더를 만들 곳)
    let folder: FileItem?
    /// 이름 바꾸기·새 폴더처럼 바로 끝나는 일 뒤에 목록을 다시 읽는다
    let reload: () async -> Void

    func body(content: Content) -> some View {
        content
            .sheet(item: $model.pending) { pending in
                DestinationPicker(title: pending.move ? "이동할 위치" : "복사할 위치",
                                  actionTitle: pending.move ? "여기로 이동" : "여기로 복사") { folder in
                    Task { await model.send(pending, to: folder) }
                }
            }
            // 확인 창은 모두 화면 가운데 알림으로 (iOS 26 의 확인 메뉴는 화면 아무 데나 말풍선으로 떠서 헷갈린다)
            .alert(conflictTitle, isPresented: Binding(
                get: { model.conflict != nil },
                set: { if !$0 { model.conflict = nil } }
            )) {
                if let conflict = model.conflict {
                    Button("둘 다 유지") { start(conflict, .keepBoth) }
                    Button("덮어쓰기", role: .destructive) { start(conflict, .replace) }
                    Button("건너뛰기") { start(conflict, .skip) }
                }
                Button("취소", role: .cancel) {}
            } message: {
                Text("둘 다 유지하면 새로 넣는 것의 이름 뒤에 (2) 처럼 번호를 붙입니다.")
            }
            .alert("이름 바꾸기", isPresented: Binding(
                get: { model.renaming != nil },
                set: { if !$0 { model.renaming = nil } }
            )) {
                TextField("이름", text: $model.newName)
                Button("취소", role: .cancel) {}
                Button("저장") {
                    guard let item = model.renaming else { return }
                    let name = model.newName.trimmingCharacters(in: .whitespaces)
                    guard !name.isEmpty, name != item.name, !name.contains("/") else { return }
                    Task {
                        do {
                            try await FileOperations.rename(item, to: name)
                            model.select(false)
                            await reload()
                        } catch {
                            model.errorMessage = error.localizedDescription
                        }
                    }
                }
            }
            .alert("새 폴더", isPresented: $model.creatingFolder) {
                TextField("이름", text: $model.newName)
                Button("취소", role: .cancel) {}
                Button("만들기") {
                    let name = model.newName.trimmingCharacters(in: .whitespaces)
                    guard let folder, !name.isEmpty, !name.contains("/") else { return }
                    Task {
                        do {
                            try await FileOperations.createDirectory(folder.child(name, isDirectory: true).url, serverID: folder.serverID)
                            await reload()
                        } catch {
                            model.errorMessage = error.localizedDescription
                        }
                    }
                }
            }
            .alert(deleteTitle, isPresented: Binding(
                get: { !model.deleting.isEmpty },
                set: { if !$0 { model.deleting = [] } }
            )) {
                Button("취소", role: .cancel) {}
                Button("삭제", role: .destructive) {
                    TransferCenter.shared.delete(model.deleting)
                    model.select(false)
                }
            } message: {
                Text("삭제하면 되돌릴 수 없습니다.")
            }
            .alert(archiveTitle, isPresented: Binding(
                get: { model.archiveChoice != nil },
                set: { if !$0 { model.archiveChoice = nil } }
            ), presenting: model.archiveChoice) { request in
                Button("취소", role: .cancel) {}
                Button("압축 풀기") { Task { await model.proceed(model.with(request, .extract(deleteOriginal: false))) } }
                Button("풀고 원본 삭제", role: .destructive) { Task { await model.proceed(model.with(request, .extract(deleteOriginal: true))) } }
                if request.archive.entries.contains(where: \.isImage) {
                    Button("이미지만 이미지뷰어로 보기") { Task { await model.proceed(request) } }
                }
            } message: { _ in
                Text("압축 파일 이름으로 폴더를 만들어 그 안에 풉니다.")
            }
            .alert("'\(model.extractChoice?.file.name ?? "")' 압축 풀기", isPresented: Binding(
                get: { model.extractChoice != nil },
                set: { if !$0 { model.extractChoice = nil } }
            ), presenting: model.extractChoice) { request in
                Button("취소", role: .cancel) {}
                Button("압축 풀기") { Task { await model.proceed(model.with(request, .extract(deleteOriginal: false))) } }
                Button("풀고 원본 삭제", role: .destructive) { Task { await model.proceed(model.with(request, .extract(deleteOriginal: true))) } }
            } message: { _ in
                Text("압축 파일 이름으로 폴더를 만들어 그 안에 풉니다.")
            }
            .alert("암호", isPresented: Binding(
                get: { model.passwordRequest != nil },
                set: { if !$0 { model.passwordRequest = nil } }
            )) {
                SecureField("암호", text: $model.password)
                Button("취소", role: .cancel) {}
                Button("확인") {
                    let request = model.passwordRequest
                    Task { await model.submitPassword(for: request) }
                }
            } message: {
                Text("'\(model.passwordRequest?.file.name ?? "")'에 암호가 걸려 있습니다.")
            }
            .alert("작업하지 못했습니다", isPresented: Binding(
                get: { model.errorMessage != nil },
                set: { if !$0 { model.errorMessage = nil } }
            )) {
                Button("확인", role: .cancel) {}
            } message: {
                Text(model.errorMessage ?? "")
            }
    }

    private var conflictTitle: String {
        guard let names = model.conflict?.names, let first = names.first else { return "" }
        return names.count == 1 ? "'\(first)'이(가) 이미 있습니다" : "'\(first)' 외 \(names.count - 1)개가 이미 있습니다"
    }

    private var archiveTitle: String {
        "'\(model.archiveChoice?.file.name ?? "")'에 이미지가 아닌 파일이 들어 있습니다"
    }

    private var deleteTitle: String {
        "\(TransferCenter.describe(model.deleting))을(를) 삭제할까요?"
    }

    private func start(_ conflict: (pending: FileActionsModel.Pending, folder: FileItem, names: [String]), _ policy: ConflictPolicy) {
        TransferCenter.shared.transfer(conflict.pending.items, to: conflict.folder, move: conflict.pending.move, conflict: policy)
        model.conflict = nil
    }
}

/// 선택 모드에서 카드 오른쪽 위의 동그라미
struct SelectionMark: View {
    let isSelected: Bool

    var body: some View {
        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
            .font(.title3)
            .symbolRenderingMode(.palette)
            .foregroundStyle(isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(.white.opacity(0.9)),
                             isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.black.opacity(0.25)))
            .shadow(radius: 2)
            .padding(6)
    }
}

// MARK: - 목적지 고르기

/// 복사·이동할 폴더를 고르는 시트. 탐색 탭과 같은 목록 (파일 앱처럼).
struct DestinationPicker: View {
    let title: String
    let actionTitle: String
    let onPick: (FileItem) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var locations = LocationStore.shared

    var body: some View {
        NavigationStack {
            List {
                Section(LocationStore.thisDeviceName) {
                    NavigationLink(value: FolderRoute(url: locations.documentsURL, title: LocationStore.thisDeviceName)) {
                        Label(LocationStore.thisDeviceName, systemImage: LocationStore.thisDeviceIcon)
                    }
                }
                if !locations.folders.isEmpty {
                    Section("폴더") {
                        ForEach(locations.folders) { folder in
                            if let url = locations.resolve(folder) {
                                NavigationLink(value: FolderRoute(url: url, title: folder.name)) {
                                    Label(folder.name, systemImage: "folder")
                                }
                            }
                        }
                    }
                }
                if !locations.servers.isEmpty {
                    Section("네트워크") {
                        ForEach(locations.servers) { server in
                            if let url = server.rootURL {
                                NavigationLink(value: FolderRoute(url: url, title: server.name, serverID: server.id)) {
                                    Label(server.name, systemImage: "network")
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle(title)
            .inlineNavigationTitle()
            .navigationDestination(for: FolderRoute.self) { route in
                DestinationFolderView(route: route, actionTitle: actionTitle) { folder in
                    dismiss()
                    onPick(folder)
                }
            }
            .toolbar {
                ToolbarItem(placement: .closeBar) {
                    CloseButton { dismiss() }
                }
            }
        }
    }
}

/// 목적지 고르기 안의 폴더: 하위 폴더만 보여주고, 아래 버튼으로 이 폴더를 고른다
private struct DestinationFolderView: View {
    let route: FolderRoute
    let actionTitle: String
    let onPick: (FileItem) -> Void

    @State private var folders: [FolderRoute] = []
    @State private var loaded = false
    @State private var errorMessage: String?
    @State private var creating = false
    @State private var newName = ""

    var body: some View {
        List(folders, id: \.self) { folder in
            NavigationLink(value: folder) {
                Label(folder.title, systemImage: "folder")
            }
        }
        .overlay {
            if let errorMessage {
                ContentUnavailableView("열 수 없습니다", systemImage: "exclamationmark.triangle", description: Text(errorMessage))
            } else if !loaded {
                ProgressView()
            } else if folders.isEmpty {
                ContentUnavailableView("하위 폴더가 없습니다", systemImage: "folder")
            }
        }
        .navigationTitle(route.title)
        .inlineNavigationTitle()
        .toolbar {
            ToolbarItem(placement: .trailingBar) {
                Button("새 폴더", systemImage: "folder.badge.plus") {
                    newName = ""
                    creating = true
                }
            }
            ToolbarItem(placement: .bottomBarOrStatus) {
                Button(actionTitle) { onPick(route.fileItem) }
                    .buttonStyle(.glassProminent)
                    .disabled(!canWrite)
            }
        }
        .alert("새 폴더", isPresented: $creating) {
            TextField("이름", text: $newName)
            Button("취소", role: .cancel) {}
            Button("만들기") {
                let name = newName.trimmingCharacters(in: .whitespaces)
                guard !name.isEmpty, !name.contains("/") else { return }
                Task {
                    do {
                        try await FileOperations.createDirectory(route.fileItem.child(name, isDirectory: true).url, serverID: route.serverID)
                        await load()
                    } catch {
                        errorMessage = error.localizedDescription
                    }
                }
            }
        }
        .task { await load() }
    }

    /// SMB 서버의 최상위(공유 폴더 목록)에는 파일을 둘 수 없다
    private var canWrite: Bool {
        !(route.url.scheme == "smb" && route.url.path(percentEncoded: false).split(separator: "/").isEmpty)
    }

    private func load() async {
        do {
            folders = try await DirectoryLister.list(route).folders
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
        loaded = true
    }
}
