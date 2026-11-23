import SwiftUI

/// 라이브러리 추가·편집: 저장소의 폴더 하나 + 종류 + 차례로 물어볼 에이전트.
/// 바뀜 (2026-11-07): 폴더 여러 개 (저장소가 달라도 된다). 다른 라이브러리에 든 폴더(겹치는 상위·하위 포함)는 넣을 수 없다.
/// 바뀜 (2026-11-07): 라이브러리 종류를 고르지 않는다 (에이전트에 보내지 않고 아이콘·이름·에이전트 종류의 기본값일 뿐이었다, 사용자).
///   이름·아이콘은 직접 정하고, 에이전트 종류는 에이전트 줄에서 고른다. Apple TV 구입작은 어느 라이브러리든 하나에만.
/// 추가는 [추가] 를 눌러야 만들고, 편집은 바꾸는 즉시 저장한다 (애플 설정·인스펙터처럼, [완료] 는 닫기만).
struct LibraryAddView: View {
    /// 편집을 띄우는 곳: 시트 (설정 창·아이폰·아이패드), 맥 라이브러리 화면의 옆 패널
    enum Presentation {
        case sheet, panel
    }

    let library: LibraryRecord?
    var presentation = Presentation.sheet
    @Environment(\.dismiss) private var dismiss
    @State private var locations = LocationStore.shared
    @State private var agentStore = AgentStore.shared

    @State private var folders: [LibraryRecord.Folder] = []
    /// 폴더를 고르는 저장소 (폴더 추가)
    @State private var pickingServer: NetworkServer?
    /// 넣을 수 없는 폴더 경고
    @State private var folderWarning: String?
    @State private var kind: LibraryKind = .movie
    @State private var name = ""
    @State private var agents: [LibraryRecord.Agent] = []
    @State private var appleTV = false
    @State private var showsOnHome = true
    @State private var homeShelf = true
    @State private var icon: String?
    @State private var scanner = LibraryScanner.shared
    @State private var organizing = false
    @State private var errorMessage: String?
    /// 편집: 마지막으로 저장한 것 (다시 훑을지 견줄 때) — 읽어 들이기 전에는 nil 이라 저장하지 않는다
    @State private var saved: LibraryRecord?

    var body: some View {
        if library == nil {
            withSheets(FormSheet(title: "라이브러리 추가", confirmTitle: "추가",
                                 confirmDisabled: folders.isEmpty || name.trimmingCharacters(in: .whitespaces).isEmpty || icon == nil,
                                 macSize: CGSize(width: 520, height: 720), onConfirm: add) {
                sections
            })
        } else {
            withSheets(editBody)
                // 바꾸면 잠깐 뒤에 저장 (이름을 칠 때마다 iCloud 로 보내지 않게, 계속 바꾸면 앞의 저장은 취소된다)
                .task(id: editState) {
                    guard saved != nil else { return }
                    try? await Task.sleep(for: .milliseconds(500))
                    guard !Task.isCancelled else { return }
                    saveEdit()
                }
                // 잠깐 뒤 저장을 기다리지 않고 닫아도 저장한다
                .onDisappear(perform: saveEdit)
        }
    }

    /// 편집: 맥 옆 패널은 내용만, 시트는 [완료] (닫기만, 이미 저장돼 있다)
    @ViewBuilder
    private var editBody: some View {
        #if os(macOS)
        if presentation == .panel {
            Form { sections }
                .formStyle(.grouped)
        } else {
            VStack(spacing: 0) {
                Form { sections }
                    .formStyle(.grouped)
                HStack {
                    Spacer()
                    Button("완료") { dismiss() }
                        .keyboardShortcut(.defaultAction)
                }
                .padding()
            }
            .frame(width: 520, height: 720)
        }
        #else
        NavigationStack {
            Form { sections }
                .navigationTitle("라이브러리 설정")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("완료", systemImage: "checkmark") { dismiss() }
                    }
                }
        }
        #endif
    }

    /// 시트들 (폴더 고르기, 폴더 정리)
    private func withSheets(_ content: some View) -> some View {
        content
            #if os(macOS)
            .sheet(isPresented: $organizing) {
                if let library { MacOrganizeView(library: library) {} }
            }
            #endif
            .sheet(item: $pickingServer) { server in
                RemoteFolderPicker(server: server, start: server.rootURL) { addFolder($0, server: server) }
            }
            .alert("폴더를 넣을 수 없습니다", isPresented: Binding(get: { folderWarning != nil }, set: { if !$0 { folderWarning = nil } })) {
                Button("확인", role: .cancel) {}
            } message: {
                Text(folderWarning ?? "")
            }
            .onAppear(perform: load)
    }

    /// 편집에서 저장할 값 (이 중 하나가 바뀌면 저장한다)
    private struct EditState: Equatable {
        let folders: [LibraryRecord.Folder]
        let kind: LibraryKind
        let name: String
        let agents: [LibraryRecord.Agent]
        let appleTV: Bool
        let showsOnHome: Bool
        let homeShelf: Bool
        let icon: String?
    }

    private var editState: EditState {
        EditState(folders: folders, kind: kind, name: name, agents: agents, appleTV: appleTV,
                  showsOnHome: showsOnHome, homeShelf: homeShelf, icon: icon)
    }

    @ViewBuilder
    private var sections: some View {
                Section {
                    ForEach(Array(folders.enumerated()), id: \.element.id) { index, folder in
                        folderRow(folder)
                            .contextMenu {
                                Button("빼기", systemImage: "minus.circle", role: .destructive) { folders.remove(at: index) }
                            }
                            #if os(iOS)
                            .swipeActions {
                                Button("빼기", role: .destructive) { folders.remove(at: index) }
                            }
                            #endif
                            .settingsReorder(folder.id, in: folders.map(\.id)) { folders.move(fromOffsets: $0, toOffset: $1) }
                    }
                    .onMove { folders.move(fromOffsets: $0, toOffset: $1) }
                    if folders.isEmpty {
                        Text("폴더를 추가하세요.").foregroundStyle(.secondary)
                    }
                    SettingsAddMenu(title: "폴더 추가") {
                        ForEach(locations.servers) { server in
                            Button(server.name) { pickingServer = server }
                        }
                    }
                    .disabled(locations.servers.isEmpty)
                } header: {
                    Text("폴더")
                } footer: {
                    if locations.servers.isEmpty {
                        Text("먼저 설정 → 저장소에서 저장소를 추가하세요.")
                    } else {
                        Text("여러 폴더의 영상을 한 라이브러리에 모읍니다. 폴더 하나는 한 라이브러리에만 넣을 수 있습니다. 빼려면 오른쪽 클릭(길게 누르기).")
                    }
                }

                Section {
                    TextField("이름", text: $name, prompt: Text("예: TV 시리즈"))
                    Toggle("홈에 표시", isOn: $showsOnHome)
                    Toggle("홈에 라이브러리 줄", isOn: $homeShelf)
                        .disabled(!showsOnHome)
                } footer: {
                    Text("홈에 표시를 끄면 홈의 이어보기·최근 추가·장르에서 빠집니다. 홈에 라이브러리 줄을 켜면 홈에 이 라이브러리의 최근 추가된 작품이 포스터로 한 줄 더 나옵니다.")
                }

                Section {
                    IconPicker(selection: $icon, defaultSymbol: icon ?? "questionmark.square.dashed")
                } header: {
                    Text("아이콘")
                } footer: {
                    if icon == nil { Text("아이콘을 고르세요.") }
                }

                Section {
                    Toggle("Apple TV 구입작 포함", isOn: $appleTV)
                } footer: {
                    Text("Apple TV 에서 산 영화도 이 라이브러리에 함께 보여줍니다. 아래 에이전트로 작품 정보를 찾고, 재생은 Apple TV 앱에서 합니다. 한 라이브러리에만 넣을 수 있어 켜면 다른 라이브러리에서는 꺼집니다.")
                }

                Section {
                    ForEach(Array(agents.enumerated()), id: \.element.agentID) { index, entry in
                        agentRow(index, entry)
                            .contextMenu {
                                Button("삭제", systemImage: "trash", role: .destructive) { agents.remove(at: index) }
                            }
                            #if os(iOS)
                            .swipeActions {
                                Button("삭제", role: .destructive) { agents.remove(at: index) }
                            }
                            #endif
                            .settingsReorder(entry.agentID, in: agents.map(\.agentID)) { agents.move(fromOffsets: $0, toOffset: $1) }
                    }
                    .onMove { agents.move(fromOffsets: $0, toOffset: $1) }
                    if agents.isEmpty {
                        Text("에이전트가 없으면 영상을 찾지 않고 파일만 보여줍니다.").foregroundStyle(.secondary)
                    }
                    addAgentMenu
                } header: {
                    Text("에이전트 (위에서부터 차례로)")
                } footer: {
                    if agentStore.agents.isEmpty {
                        Text("설정 → 에이전트에서 에이전트를 먼저 추가하세요.")
                    } else {
                        Text("앞 에이전트가 찾지 못하면 다음 에이전트에게 물어봅니다.")
                    }
                }

                if let library {
                    manageSection(library)
                }

                if let errorMessage {
                    Section { Text(errorMessage).foregroundStyle(.red) }
                }
    }

    /// 이미 있는 라이브러리의 관리: 다시 훑기, 못 찾은 파일 다시 매칭, 폴더 정리(맥)
    private func manageSection(_ library: LibraryRecord) -> some View {
        Section {
            if let progress = scanner.running[library.id] {
                HStack {
                    ProgressView().controlSize(.small)
                    Text(progress.total > 0 ? "\(progress.phase) \(progress.done)/\(progress.total)" : progress.phase)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("멈추기") { scanner.cancel(library.id) }
                }
            } else {
                SettingsActionButton(title: "다시 훑기", systemImage: "arrow.clockwise") { scanner.scan(library) }
                SettingsActionButton(title: "못 찾은 파일 다시 매칭", systemImage: "arrow.triangle.2.circlepath") {
                    scanner.scan(library, retryUnmatched: true)
                }
            }
            #if os(macOS)
            SettingsActionButton(title: "폴더 정리…", systemImage: "folder.badge.gearshape") { organizing = true }
                .disabled(scanner.isRunning(library.id))
            #endif
        } header: {
            Text("관리")
        } footer: {
            #if os(macOS)
            Text("다시 훑기는 새로 넣거나 바뀐 파일을 찾아 매칭합니다. 폴더 정리는 에이전트가 정한 위치(제목 (연도)/…, 시즌 폴더 …)와 다른 파일을 옮깁니다.")
            #else
            Text("다시 훑기는 새로 넣거나 바뀐 파일을 찾아 매칭합니다. 라이브러리 화면을 아래로 당겨도 됩니다.")
            #endif
        }
    }

    private var addAgentMenu: some View {
        SettingsAddMenu(title: "에이전트 추가") {
            ForEach(agentStore.agents) { agent in
                Button(agent.name) { add(agent) }
                    .disabled(agents.contains { $0.agentID == agent.id })
            }
        }
        .disabled(agentStore.agents.isEmpty)
    }

    /// 폴더 한 줄: 저장소/경로
    private func folderRow(_ folder: LibraryRecord.Folder) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "folder")
                .foregroundStyle(.tint)
                .frame(width: 22)
            Text(folderText(folder))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            Image(systemName: "line.3.horizontal")
                .foregroundStyle(.tertiary)
                .help("끌어서 순서 바꾸기")
        }
        .contentShape(.rect)
    }

    private func folderText(_ folder: LibraryRecord.Folder) -> String {
        guard let server = locations.servers.first(where: { $0.id == folder.serverID }) else { return folder.rootURL.path(percentEncoded: false) }
        let root = server.rootURL?.path(percentEncoded: false) ?? ""
        var path = folder.rootURL.path(percentEncoded: false)
        if path.hasPrefix(root) { path.removeFirst(root.count) }
        return "\(server.name)/\(path.trimmingCharacters(in: CharacterSet(charactersIn: "/")))"
    }

    /// 고른 폴더를 넣는다: 이 라이브러리나 다른 라이브러리의 폴더와 겹치면 넣지 않는다
    private func addFolder(_ url: URL, server: NetworkServer) {
        let path = url.standardizedFileURL.path(percentEncoded: false)
        let inThis = folders.contains { folder in
            guard folder.serverID == server.id else { return false }
            let other = folder.rootURL.standardizedFileURL.path(percentEncoded: false)
            return (path + "/").hasPrefix(other.hasSuffix("/") ? other : other + "/") || (other + "/").hasPrefix(path.hasSuffix("/") ? path : path + "/")
        }
        if inThis {
            folderWarning = "이미 넣은 폴더와 겹칩니다."
            return
        }
        if let other = LibraryStore.shared.overlapping(serverID: server.id, url: url, excluding: library?.id) {
            folderWarning = "이미 \(other.name) 라이브러리에 있는 폴더입니다. 폴더 하나는 한 라이브러리에만 넣을 수 있습니다."
            return
        }
        folders.append(LibraryRecord.Folder(id: UUID().uuidString, serverID: server.id, rootURL: url))
    }

    private func agentRow(_ index: Int, _ entry: LibraryRecord.Agent) -> some View {
        let agent = agentStore.agent(entry.agentID)
        return HStack(spacing: 10) {
            Image(systemName: agent?.type == .tmdb ? "film" : "server.rack")
                .foregroundStyle(.tint)
                .frame(width: 22)
            Text(agent?.name ?? "없는 에이전트")
            Spacer()
            Picker("종류", selection: Binding(
                get: { entry.kind },
                set: { agents[index].kind = $0 }
            )) {
                ForEach(agent?.kinds ?? []) { kind in Text(kind.name).tag(kind.id) }
            }
            .labelsHidden()
            .fixedSize()
            // 끌어서 순서 바꾸기 (설정 목록과 같게), 삭제는 오른쪽 클릭·길게 누르기·밀기
            Image(systemName: "line.3.horizontal")
                .foregroundStyle(.tertiary)
                .help("끌어서 순서 바꾸기")
        }
        .contentShape(.rect)
    }

    private func add(_ agent: AgentRecord) {
        // 같은 에이전트는 한 번만 (순서를 바꿀 때 줄을 에이전트로 구분한다)
        // 바뀜 (2026-11-07): 라이브러리 종류가 없어져 그 에이전트의 첫 종류로 (예전 라이브러리는 예전 종류에 맞는 것)
        guard !agents.contains(where: { $0.agentID == agent.id }),
              let kind = (library != nil ? kind.suggestedKind(in: agent) : nil) ?? agent.kinds.first?.id else { return }
        agents.append(LibraryRecord.Agent(agentID: agent.id, kind: kind))
    }

    private func load() {
        guard saved == nil else { return }
        if let library {
            folders = library.folders
            kind = library.kind
            name = library.name
            agents = library.agents
            appleTV = library.appleTV
            showsOnHome = library.showsOnHome
            homeShelf = library.homeShelf
            // 아이콘을 고른 적 없는 예전 라이브러리는 종류의 아이콘을 고른 것으로
            icon = library.icon ?? library.kind.symbol
            saved = library
        } else {
            // 새 라이브러리는 종류를 정하지 않는다 (기타로 저장, 쓰지 않는다). 사용자 정의 에이전트를 기본으로
            kind = .etc
            if let agent = agentStore.agents.first(where: { $0.type == .custom }) ?? agentStore.agents.first {
                add(agent)
            }
        }
    }

    private func record(id: String, scannedAt: Date?) -> LibraryRecord? {
        guard !folders.isEmpty else { return nil }
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        return LibraryRecord(id: id, name: trimmed.isEmpty ? (saved?.name ?? kind.title) : trimmed, kind: kind, folders: folders,
                             agents: agents, scannedAt: scannedAt, appleTV: appleTV, showsOnHome: showsOnHome,
                             homeShelf: homeShelf, icon: icon)
    }

    /// 추가: 만들고 훑기 시작
    private func add() {
        guard let record = record(id: UUID().uuidString, scannedAt: nil) else { return }
        do {
            try LibraryStore.shared.save(record)
            LibraryScanner.shared.scan(record)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// 편집: 바뀐 것을 바로 저장 (폴더를 아직 고르지 않았으면 기다린다). 폴더나 Apple TV 구입작 포함이 바뀌면 다시 훑는다.
    private func saveEdit() {
        guard let saved, let record = record(id: saved.id, scannedAt: saved.scannedAt), record != saved else { return }
        do {
            try LibraryStore.shared.save(record)
            errorMessage = nil
            if saved.folders != record.folders || saved.appleTV != record.appleTV {
                LibraryScanner.shared.scan(record)
            }
            self.saved = record
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

/// 저장소 안의 폴더 고르기
struct RemoteFolderPicker: View {
    let server: NetworkServer
    let start: URL?
    let onPick: (URL) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var current: URL?
    @State private var folders: [URL] = []
    @State private var loading = false
    @State private var errorMessage: String?

    var body: some View {
        #if os(macOS)
        // 맥: Finder·열기 창의 열 보기처럼 폴더를 고르면 오른쪽에 하위 폴더 열이 이어진다
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "externaldrive.connected.to.line.below").foregroundStyle(.secondary)
                Text(title).lineLimit(1).truncationMode(.head)
                Spacer()
            }
            .font(.callout)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            Divider()
            MacFolderColumns(server: server, start: start, selected: $current)
            Divider()
            HStack {
                Spacer()
                Button("취소", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("이 폴더 고르기") {
                    if let current { onPick(current) }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(current == nil)
            }
            .padding()
        }
        .frame(width: 720, height: 480)
        #else
        NavigationStack {
            folderList
                .navigationTitle(title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("취소", systemImage: "xmark", role: .cancel) { dismiss() }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("이 폴더 고르기", systemImage: "checkmark") {
                            if let current { onPick(current) }
                            dismiss()
                        }
                        .disabled(current == nil)
                    }
                    ToolbarItem(placement: .bottomBar) {
                        Button("상위 폴더", systemImage: "arrow.turn.left.up") { goUp() }
                            .disabled(isRoot)
                    }
                }
        }
        .task(id: current) { await load() }
        .onAppear { if current == nil { current = start ?? server.rootURL } }
        #endif
    }

    private var folderList: some View {
        List(folders, id: \.self) { folder in
            Button {
                current = folder
            } label: {
                Label(folder.lastPathComponent.precomposedStringWithCanonicalMapping, systemImage: "folder")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
        }
        .overlay {
            if let errorMessage {
                ContentUnavailableView("폴더를 읽지 못했습니다", systemImage: "exclamationmark.triangle", description: Text(errorMessage))
            } else if loading {
                #if os(iOS)
                ProgressView()
                #endif
            } else if folders.isEmpty {
                ContentUnavailableView("하위 폴더가 없습니다", systemImage: "folder")
            }
        }
    }

    private var isRoot: Bool {
        current?.standardizedFileURL == server.rootURL?.standardizedFileURL || current == server.rootURL
    }

    private var title: String {
        guard let current else { return server.name }
        let root = server.rootURL?.path(percentEncoded: false) ?? ""
        var path = current.path(percentEncoded: false)
        if path.hasPrefix(root) { path.removeFirst(root.count) }
        let trimmed = path.trimmingCharacters(in: CharacterSet(charactersIn: "/")).precomposedStringWithCanonicalMapping
        return trimmed.isEmpty ? server.name : "\(server.name)/\(trimmed)"
    }

    private func goUp() {
        guard let current, !isRoot else { return }
        self.current = current.deletingLastPathComponent()
    }

    private func load() async {
        guard let current else { return }
        loading = true
        errorMessage = nil
        do {
            folders = try await DirectoryLister.items(in: current, serverID: server.id)
                .filter { $0.isDirectory && !$0.url.lastPathComponent.hasPrefix(".") && !$0.url.lastPathComponent.hasPrefix("@") }
                .map(\.url)
                .sorted { KoreanIndex.precedes($0.lastPathComponent, $1.lastPathComponent) }
        } catch {
            folders = []
            errorMessage = error.localizedDescription
        }
        loading = false
    }
}

#if os(macOS)
/// 맥 폴더 고르기에서 읽은 폴더 목록 (앱이 켜져 있는 동안)
private enum MacFolderCache {
    static var children: [URL: [URL]] = [:]
}

/// 맥 폴더 고르기의 열 보기: 첫 열은 저장소 맨 위, 폴더를 고르면 오른쪽에 그 하위 폴더 열
private struct MacFolderColumns: View {
    let server: NetworkServer
    let start: URL?
    @Binding var selected: URL?
    /// 열마다 그 열이 보여주는 폴더 (맨 앞은 저장소 맨 위)
    @State private var columns: [URL] = []
    /// 폴더 → 하위 폴더 (읽은 것. 앱이 켜져 있는 동안 기억해 두어 다시 열 때 NAS 에 또 묻지 않는다)
    @State private var children: [URL: [URL]] = MacFolderCache.children
    @State private var failed: [URL: String] = [:]

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                HStack(spacing: 0) {
                    ForEach(Array(columns.enumerated()), id: \.element) { index, folder in
                        column(folder, index: index)
                            .frame(width: 220)
                            .id(folder)
                        Divider()
                    }
                }
            }
            // 처음 열 때는 애니메이션 없이 (창이 그려질 때 함께 움직여 단추가 미끄러져 보였다), 고를 때만 부드럽게
            .onChange(of: columns) { old, new in
                guard let last = new.last else { return }
                if old.isEmpty {
                    proxy.scrollTo(last, anchor: .trailing)
                } else {
                    withAnimation { proxy.scrollTo(last, anchor: .trailing) }
                }
            }
        }
        .task { setUp() }
    }

    private func column(_ folder: URL, index: Int) -> some View {
        // 고른 폴더는 경로로 맞춘다 (경로로 만든 주소와 NAS 가 준 주소는 끝의 / 등이 다를 수 있다)
        let next = columns.indices.contains(index + 1) ? Self.key(columns[index + 1]) : nil
        return List(selection: Binding(get: { next }, set: { picked in
            if let picked, let child = children[folder]?.first(where: { Self.key($0) == picked }) { pick(child, after: index) }
        })) {
            ForEach(children[folder] ?? [], id: \.self) { child in
                HStack(spacing: 6) {
                    Image(systemName: "folder.fill").foregroundStyle(.tint)
                    Text(child.lastPathComponent.precomposedStringWithCanonicalMapping).lineLimit(1)
                    Spacer()
                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                }
                .tag(Self.key(child))
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .overlay {
            if let message = failed[folder] {
                Text(message).font(.caption).foregroundStyle(.secondary).padding()
            } else if children[folder] == nil {
                ProgressView().controlSize(.small)
            } else if children[folder]?.isEmpty == true {
                Text("하위 폴더 없음").font(.caption).foregroundStyle(.tertiary)
            }
        }
        .task(id: folder) { await load(folder) }
    }

    private static func key(_ url: URL) -> String {
        url.path(percentEncoded: false).precomposedStringWithCanonicalMapping.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    /// index 열에서 폴더를 골랐다: 그 뒤 열은 버리고 고른 폴더의 열을 붙인다
    private func pick(_ picked: URL, after index: Int) {
        columns = Array(columns.prefix(index + 1)) + [picked]
        selected = picked
    }

    /// 처음: 저장소 맨 위부터 고른 폴더(start)까지 열을 연다
    private func setUp() {
        guard columns.isEmpty, let root = server.rootURL else { return }
        var chain = [root]
        if let start {
            let base = root.path(percentEncoded: false)
            let target = start.path(percentEncoded: false)
            if target.hasPrefix(base) {
                var url = root
                for part in target.dropFirst(base.count).split(separator: "/") {
                    url = url.appending(path: String(part), directoryHint: .isDirectory)
                    chain.append(url)
                }
            }
        }
        columns = chain
        selected = chain.count > 1 ? chain.last : root
    }

    private func load(_ folder: URL) async {
        guard children[folder] == nil else { return }
        do {
            let found = try await DirectoryLister.items(in: folder, serverID: server.id)
                .filter { $0.isDirectory && !$0.url.lastPathComponent.hasPrefix(".") && !$0.url.lastPathComponent.hasPrefix("@") }
                .map(\.url)
                .sorted { KoreanIndex.precedes($0.lastPathComponent, $1.lastPathComponent) }
            children[folder] = found
            MacFolderCache.children[folder] = found
        } catch {
            children[folder] = []
            failed[folder] = error.localizedDescription
        }
    }
}
#endif
