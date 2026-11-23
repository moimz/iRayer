import SwiftUI
import Observation

/// 파일 복사·이동·삭제·압축 풀기 작업 하나 (작업 목록의 한 줄)
@Observable
final class TransferTask: Identifiable {
    enum State: Equatable {
        case running
        case finished
        case failed(String)
        case cancelled
    }

    let id = UUID()
    let title: String
    let systemImage: String
    /// 지금 다루는 파일 이름
    var current = ""
    /// 전체·끝난 바이트 (전체를 모르면 0)
    var total: Int64 = 0
    var done: Int64 = 0
    var state = State.running
    /// 끝난 뒤 보여줄 한 줄 (건너뛴 항목 수 등)
    var summary: String?
    var finishedAt: Date?

    @ObservationIgnored fileprivate var work: Task<Void, Never>?

    init(title: String, systemImage: String) {
        self.title = title
        self.systemImage = systemImage
    }

    /// 작업 내역으로 저장하는 끝난 작업
    struct Record: Codable {
        var title: String
        var systemImage: String
        /// finished · failed · cancelled
        var result: String
        var message: String?
        var summary: String?
        var finishedAt: Date?
    }

    var record: Record {
        let (result, message): (String, String?) = switch state {
        case .running, .finished: ("finished", nil)
        case .failed(let message): ("failed", message)
        case .cancelled: ("cancelled", nil)
        }
        return Record(title: title, systemImage: systemImage, result: result, message: message, summary: summary, finishedAt: finishedAt)
    }

    convenience init(record: Record) {
        self.init(title: record.title, systemImage: record.systemImage)
        state = switch record.result {
        case "failed": .failed(record.message ?? "")
        case "cancelled": .cancelled
        default: .finished
        }
        summary = record.summary
        finishedAt = record.finishedAt
    }

    var fraction: Double? {
        total > 0 ? min(Double(done) / Double(total), 1) : nil
    }

    var isRunning: Bool { state == .running }

    func cancel() {
        work?.cancel()
    }

    /// 진행률을 더한다. 취소됐으면 false.
    func add(_ bytes: Int64) -> Bool {
        done += bytes
        return !Task.isCancelled
    }
}

/// 같은 이름이 이미 있을 때
enum ConflictPolicy {
    case skip
    case replace
    case keepBoth
}

/// 앱 전체의 파일 작업 목록. 작업은 하나씩 차례로 돈다 (NAS 에 한꺼번에 몰리지 않게).
@Observable
final class TransferCenter {
    static let shared = TransferCenter()

    private(set) var tasks: [TransferTask] = []
    /// 작업이 끝날 때마다 늘어난다 (열려 있는 폴더 화면이 목록을 다시 읽는다)
    private(set) var revision = 0
    /// 화면 아래 진행 표시를 보일지. 다 끝나면 3초 뒤 사라지고, 실패가 있으면 작업 목록을 열어 볼 때까지 남는다.
    private(set) var showsBanner = false
    /// 진행 표시가 뜬 뒤 실패한 작업이 있었는지
    private(set) var bannerHasFailure = false
    /// 진행 표시를 눌러 작업 목록을 연 상태 (열려 있는 동안은 진행 표시를 내리지 않는다)
    var showsList = false

    @ObservationIgnored private var queue: Task<Void, Never>?
    #if os(iOS)
    @ObservationIgnored private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    #endif
    @ObservationIgnored private var hideBanner: Task<Void, Never>?
    @ObservationIgnored private let historyURL = AppPaths.support.appending(path: "TransferHistory.json")

    private init() {
        // 지난 작업 내역 (최근 50개)
        if let data = try? Data(contentsOf: historyURL),
           let records = try? JSONDecoder().decode([TransferTask.Record].self, from: data) {
            tasks = records.map(TransferTask.init(record:))
        }
    }

    var isBusy: Bool { tasks.contains(where: \.isRunning) }

    // MARK: - 작업 만들기

    /// 여러 항목을 폴더로 복사 또는 이동
    func transfer(_ items: [FileItem], to folder: FileItem, move: Bool, conflict: ConflictPolicy) {
        let verb = move ? "이동" : "복사"
        let task = TransferTask(title: "\(Self.describe(items))을(를) '\(folder.name.isEmpty ? LocationStore.thisDeviceName : folder.name)'(으)로 \(verb)",
                                systemImage: move ? "folder" : "doc.on.doc")
        task.total = items.reduce(0) { $0 + $1.size }
        enqueue(task) {
            var skipped = 0
            for item in items {
                try Task.checkCancellation()
                task.current = item.name
                let moved = move ? try await Self.moveOnServerFirst(item, into: folder, conflict: conflict, task: task, skipped: &skipped) : false
                if !moved {
                    try await Self.copy(item, into: folder, move: move, conflict: conflict, task: task, skipped: &skipped)
                }
            }
            if skipped > 0 { task.summary = "같은 이름이 있어 \(skipped)개는 건너뛰었습니다." }
        }
    }

    /// 여러 항목 삭제
    func delete(_ items: [FileItem]) {
        let task = TransferTask(title: "\(Self.describe(items)) 삭제", systemImage: "trash")
        task.total = Int64(items.count)
        enqueue(task) {
            for item in items {
                try Task.checkCancellation()
                task.current = item.name
                try await FileOperations.remove(item)
                Self.forgetDeleted(item)
                _ = task.add(1)
            }
        }
    }

    /// 지운 파일(폴더면 그 안의 파일 모두)을 홈의 이어보기·최근 추가에서 뺀다.
    /// 라이브러리 작품은 그대로 둔다 (라이브러리를 다시 훑을 때 빠진다)
    private static func forgetDeleted(_ item: FileItem) {
        let isGone = { (file: VideoFile) in file.serverID == item.serverID && FolderOptionsStore.isInside(file.url, item.url) }
        WatchHistory.shared.forget(where: isGone)
        MediaIndex.shared.forget(where: isGone)
    }

    /// 압축 풀기: 압축 파일 이름으로 폴더를 만들어 그 안에 푼다 (같은 이름이 있으면 "이름 (2)")
    func extract(_ file: FileItem, archive: any ComicArchive, password: String?, deleteOriginal: Bool) {
        let task = TransferTask(title: "'\(file.name)' 압축 풀기", systemImage: "archivebox")
        let entries = archive.entries.filter { !$0.isJunk }
        task.total = entries.reduce(0) { $0 + $1.size }
        let rar = archive as? RarArchive
        // RAR 은 먼저 한 번에 모두 풀어 두고(진행률 앞 절반) 그것을 옮긴다(뒤 절반). 하나씩 꺼내면 솔리드 RAR 은 매번 처음부터 풀어야 한다.
        if rar != nil { task.total *= 2 }
        enqueue(task) {
            defer { rar?.removeUnpacked() }
            if let rar {
                task.current = "압축 푸는 중"
                try await rar.unpackAll(password: password) { bytes in
                    Task { @MainActor in
                        if task.current == "압축 푸는 중", bytes > task.done { task.done = bytes }
                    }
                }
                task.done = task.total / 2
            }
            let parent = FileItem(url: file.url.deletingLastPathComponent(), serverID: file.serverID, isDirectory: true)
            let baseName = (file.name as NSString).deletingPathExtension
            let folder = parent.child(try await FileOperations.availableName(baseName, in: parent, isDirectory: true), isDirectory: true)
            try await FileOperations.createDirectory(folder.url, serverID: folder.serverID)
            var created: Set<String> = [""]

            /// zip 안 경로의 폴더들을 차례로 만든다
            func makeFolders(_ components: [String]) async throws {
                var path = ""
                for component in components {
                    path += path.isEmpty ? component : "/" + component
                    guard created.insert(path).inserted else { continue }
                    let url = path.split(separator: "/").reduce(folder.url) { $0.appending(path: String($1), directoryHint: .isDirectory) }
                    if try await FileOperations.item(at: url, serverID: folder.serverID) == nil {
                        try await FileOperations.createDirectory(url, serverID: folder.serverID)
                    }
                }
            }

            for entry in entries {
                try Task.checkCancellation()
                // "..", 빈 이름처럼 폴더 밖을 가리키는 경로는 버린다
                let components = entry.path.split(separator: "/").map(String.init).filter { !$0.isEmpty && $0 != "." && $0 != ".." }
                guard let name = components.last else { continue }
                if entry.isDirectory {
                    try await makeFolders(components)
                    continue
                }
                try await makeFolders(Array(components.dropLast()))
                task.current = name
                let url = components.reduce(folder.url) { $0.appending(path: $1, directoryHint: .notDirectory) }
                let writer = try FileOperations.writer(for: url, serverID: folder.serverID, length: entry.size)
                do {
                    try await archive.extract(entry, password: password) { data in
                        try await writer.write(data)
                        guard task.add(Int64(data.count)) else { throw CancellationError() }
                    }
                    try await writer.finish()
                } catch {
                    await writer.abort()
                    throw error
                }
            }
            if deleteOriginal { try await FileOperations.remove(file) }
            task.summary = "'\(folder.name)' 폴더에 풀었습니다." + (deleteOriginal ? " 원본은 지웠습니다." : "")
        }
    }

    /// 작업 하나를 목록에 넣고 차례가 되면 돈다
    func enqueue(_ task: TransferTask, _ operation: @escaping () async throws -> Void) {
        tasks.insert(task, at: 0)
        hideBanner?.cancel()
        if !showsBanner { bannerHasFailure = false }
        showsBanner = true
        let previous = queue
        let work = Task { @MainActor in
            await previous?.value
            guard !Task.isCancelled else {
                task.state = .cancelled
                return
            }
            self.begin()
            do {
                try await operation()
                task.state = .finished
            } catch is CancellationError {
                task.state = .cancelled
            } catch FileOperations.OperationError.cancelled {
                task.state = .cancelled
            } catch {
                task.state = .failed(error.localizedDescription)
                self.bannerHasFailure = true
            }
            task.current = ""
            task.finishedAt = .now
            self.revision += 1
            self.saveHistory()
            self.end()
        }
        task.work = work
        queue = work
    }

    func clearFinished() {
        tasks.removeAll { !$0.isRunning }
        saveHistory()
    }

    /// 작업 목록을 열어 보고 닫았다: 진행 표시도 같이 내린다 (아직 도는 작업이 있으면 남긴다)
    func acknowledge() {
        guard !isBusy else { return }
        hideBanner?.cancel()
        withAnimation { showsBanner = false }
    }

    private func saveHistory() {
        let records = tasks.filter { !$0.isRunning }.prefix(50).map(\.record)
        try? FileManager.default.createDirectory(at: AppPaths.support, withIntermediateDirectories: true)
        try? JSONEncoder().encode(Array(records)).write(to: historyURL, options: .atomic)
    }

    /// 작업 중에는 자동 잠금을 끄고, 앱이 백그라운드로 가도 조금 더 돌 수 있게 한다
    private func begin() {
        AppSettings.shared.isTransferring = true
        #if os(iOS)
        if backgroundTask == .invalid {
            backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "파일 작업") { [weak self] in
                self?.endBackgroundTask()
            }
        }
        #endif
    }

    private func end() {
        guard !isBusy else { return }
        AppSettings.shared.isTransferring = false
        endBackgroundTask()
        // 모두 잘 끝났으면 "작업 완료" 를 잠깐 보여주고 내린다
        guard !bannerHasFailure else { return }
        hideBanner = Task { @MainActor in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled, !self.isBusy, !self.showsList else { return }
            withAnimation { self.showsBanner = false }
        }
    }

    private func endBackgroundTask() {
        #if os(iOS)
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
        #endif
    }

    // MARK: - 복사·이동

    /// "파일이름" 또는 "파일이름 외 3개"
    static func describe(_ items: [FileItem]) -> String {
        guard let first = items.first else { return "" }
        return items.count == 1 ? "'\(first.name)'" : "'\(first.name)' 외 \(items.count - 1)개"
    }

    /// 같은 이름이 있을 때 쓸 이름. nil 이면 건너뛴다.
    private static func targetName(for item: FileItem, in folder: FileItem, conflict: ConflictPolicy) async throws -> String? {
        let existing = try await FileOperations.item(at: folder.child(item.name, isDirectory: item.isDirectory).url, serverID: folder.serverID)
        guard let existing else { return item.name }
        // 자기 자신 위로는 덮어쓰지 않는다
        if existing.url.standardizedFileURL == item.url.standardizedFileURL, existing.serverID == item.serverID { return nil }
        switch conflict {
        case .skip:
            return nil
        case .replace:
            try await FileOperations.remove(existing)
            return item.name
        case .keepBoth:
            return try await FileOperations.availableName(item.name, in: folder, isDirectory: item.isDirectory)
        }
    }

    /// 서버가 직접 옮길 수 있으면 옮긴다 (같은 서버 안: 바로 끝난다)
    private static func moveOnServerFirst(_ item: FileItem, into folder: FileItem, conflict: ConflictPolicy,
                                          task: TransferTask, skipped: inout Int) async throws -> Bool {
        guard item.serverID == folder.serverID else { return false }
        try checkNotInside(item, folder)
        guard let name = try await targetName(for: item, in: folder, conflict: conflict) else {
            skipped += 1
            _ = task.add(item.size)
            return true
        }
        let moved = try await FileOperations.moveOnServer(item, to: folder.child(name, isDirectory: item.isDirectory).url)
        if moved { _ = task.add(item.size) }
        return moved
    }

    /// 복사 (이동이면 복사가 끝까지 된 뒤 원본을 지운다)
    private static func copy(_ item: FileItem, into folder: FileItem, move: Bool, conflict: ConflictPolicy,
                             task: TransferTask, skipped: inout Int) async throws {
        try checkNotInside(item, folder)
        guard let name = try await targetName(for: item, in: folder, conflict: conflict) else {
            skipped += 1
            _ = task.add(item.size)
            return
        }
        let target = folder.child(name, isDirectory: item.isDirectory)
        if item.serverID == folder.serverID {
            let before = task.done
            let copied = try await FileOperations.copyOnServer(item, to: target.url) { _ in !Task.isCancelled }
            if copied {
                // 서버 복사는 진행률을 끝에 한 번에 더한다
                task.done = before + item.size
                if move { try await FileOperations.remove(item) }
                return
            }
        }
        try await copyTree(item, to: target, task: task)
        if move { try await FileOperations.remove(item) }
    }

    /// 위치가 다를 때: 폴더면 안쪽까지 차례로, 파일이면 조금씩 읽어 쓴다
    private static func copyTree(_ item: FileItem, to target: FileItem, task: TransferTask) async throws {
        try Task.checkCancellation()
        if item.isDirectory {
            try await FileOperations.createDirectory(target.url, serverID: target.serverID)
            let children = try await FileOperations.children(of: item)
            task.total += children.reduce(0) { $0 + ($1.isDirectory ? 0 : $1.size) }
            for child in children {
                try await copyTree(child, to: target.child(child.name, isDirectory: child.isDirectory), task: task)
            }
        } else {
            task.current = item.name
            try await FileOperations.copyFile(item, to: target.url, destinationServerID: target.serverID) { task.add($0) }
        }
    }

    /// 폴더를 자기 안으로 옮기거나 복사하지 않게
    private static func checkNotInside(_ item: FileItem, _ folder: FileItem) throws {
        guard item.isDirectory, item.serverID == folder.serverID else { return }
        let source = item.url.standardizedFileURL.absoluteString.trimmingCharacters(in: ["/"])
        let destination = folder.url.standardizedFileURL.absoluteString.trimmingCharacters(in: ["/"])
        if destination == source || destination.hasPrefix(source + "/") {
            throw TransferError.intoItself(item.name)
        }
    }

    enum TransferError: LocalizedError {
        case intoItself(String)

        var errorDescription: String? {
            switch self {
            case .intoItself(let name): "'\(name)' 폴더를 자기 안으로 옮길 수 없습니다."
            }
        }
    }
}

/// 작업 목록 (진행 중인 작업과 지난 작업 내역). 시트로도, 설정 화면에서 밀어 넣어도 쓴다.
struct TransferListView: View {
    /// 시트로 띄웠으면 닫기 버튼을 둔다
    var showsCloseButton = true

    @State private var center = TransferCenter.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List(center.tasks) { task in
            TransferRow(task: task)
        }
        .overlay {
            if center.tasks.isEmpty {
                ContentUnavailableView("작업 내역이 없습니다", systemImage: "arrow.up.arrow.down")
            }
        }
        .navigationTitle("파일 작업")
        .inlineNavigationTitle()
        .toolbar {
            ToolbarItem(placement: .trailingBar) {
                Button("끝난 작업 지우기", systemImage: "eraser") { center.clearFinished() }
                    .disabled(!center.tasks.contains { !$0.isRunning })
            }
            if showsCloseButton {
                ToolbarItem(placement: .closeBar) {
                    CloseButton { dismiss() }
                }
            }
        }
        .onAppear {
            // 설정 화면에서 열었을 때 (시트로 연 것은 닫을 때 내린다)
            if !showsCloseButton { center.acknowledge() }
        }
    }
}

private struct TransferRow: View {
    let task: TransferTask

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: task.systemImage)
                .font(.title3)
                .foregroundStyle(.tint)
                .frame(width: 30)
            VStack(alignment: .leading, spacing: 4) {
                Text(task.title)
                    .font(.subheadline)
                    .lineLimit(2)
                switch task.state {
                case .running:
                    if let fraction = task.fraction {
                        ProgressView(value: fraction)
                    } else {
                        ProgressView().progressViewStyle(.linear)
                    }
                    Text(task.current.isEmpty ? "기다리는 중" : "\(task.fraction.map { "\(Int($0 * 100))% · " } ?? "")\(task.current)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                case .finished:
                    Text(task.summary ?? "완료").font(.caption).foregroundStyle(.secondary)
                case .failed(let message):
                    Text(message).font(.caption).foregroundStyle(.red)
                case .cancelled:
                    Text("취소됨").font(.caption).foregroundStyle(.secondary)
                }
                if let finishedAt = task.finishedAt {
                    Text(finishedAt, format: .dateTime.month().day().hour().minute())
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            if task.isRunning {
                Button("취소", systemImage: "xmark.circle.fill") { task.cancel() }
                    .labelStyle(.iconOnly)
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .buttonStyle(.plain)
            }
        }
    }
}

/// 화면 아래(탭 막대 위)에 떠 있는 진행 표시. 누르면 작업 목록. 스크롤 영역은 줄이지 않고 목록 위에 겹친다.
struct TransferBanner: View {
    @State private var center = TransferCenter.shared

    var body: some View {
        Button {
            center.showsList = true
        } label: {
            HStack(spacing: 10) {
                if let task = center.tasks.first(where: \.isRunning) {
                    ProgressView(value: task.fraction ?? 0)
                        .progressViewStyle(.circular)
                        .controlSize(.small)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(task.title).font(.footnote.weight(.semibold)).lineLimit(1)
                        Text("\(task.fraction.map { "\(Int($0 * 100))% · " } ?? "")\(task.current)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                } else {
                    Image(systemName: center.bannerHasFailure ? "exclamationmark.circle.fill" : "checkmark.circle.fill")
                        .foregroundStyle(center.bannerHasFailure ? Color.orange : Color.green)
                    Text(center.bannerHasFailure ? "작업을 끝내지 못했습니다" : "작업 완료")
                        .font(.footnote.weight(.semibold))
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            // 캡슐 폭은 화면에 맞추되 안의 내용은 왼쪽부터
            .frame(maxWidth: 360, alignment: .leading)
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .capsule)
        .padding(.horizontal)
    }
}
