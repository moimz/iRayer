import SwiftUI

/// 찾지 못한 파일 목록과 수동 매칭: 파일을 골라 에이전트에서 검색하고, 고른 작품으로 다시 매칭한다
/// 바뀜 (2026-11-07): 매칭 고치기 — 작품 화면에서 그 작품의 파일(시리즈는 모든 회차, 영화는 그 파일)로 연다 (rematch). 한 번 매칭하면 닫는다.
struct UnmatchedView: View {
    /// 이미 매칭된 작품을 다른 작품으로 다시 매칭할 때: 그 작품의 파일과 처음 검색어
    struct Rematch {
        let files: [LibraryData.FileEntry]
        let query: String
        let year: Int?
    }

    let library: LibraryRecord
    var rematch: Rematch? = nil
    let onChange: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var files: [LibraryData.FileEntry] = []
    @State private var selected: LibraryData.FileEntry?

    var body: some View {
        NavigationSplitView {
            List(files, selection: $selected) { file in
                VStack(alignment: .leading, spacing: 2) {
                    Text(file.name).lineLimit(1).truncationMode(.middle)
                    Text(file.message ?? (file.status == "error" ? "오류" : "찾지 못함"))
                        .font(.caption)
                        .foregroundStyle(file.status == "error" ? .red : .secondary)
                        .lineLimit(1)
                }
                .tag(file)
            }
            .navigationSplitViewColumnWidth(min: 260, ideal: 300)
        } detail: {
            if let selected {
                ManualMatchPanel(library: library, file: selected, others: files,
                                 initialQuery: rematch?.query, initialYear: rematch?.year, includesAll: rematch != nil) {
                    reload()
                    onChange()
                    if rematch != nil { dismiss() }
                }
                .id(selected.id)
            } else {
                ContentUnavailableView("파일을 고르세요", systemImage: "questionmark.folder",
                                       description: Text("왼쪽에서 파일을 고르면 작품을 검색해 직접 정할 수 있습니다."))
            }
        }
        .toolbar {
            if rematch == nil {
                ToolbarItem {
                    Button("모두 다시 매칭") {
                        LibraryScanner.shared.scan(library, retryUnmatched: true)
                        dismiss()
                    }
                }
            }
            ToolbarItem(placement: .cancellationAction) {
                Button("닫기") { dismiss() }
            }
        }
        #if os(macOS)
        .frame(minWidth: 820, minHeight: 520)
        #endif
        .onAppear(perform: reload)
    }

    private func reload() {
        if let rematch {
            files = rematch.files
            if selected == nil { selected = files.first }
            return
        }
        files = LibraryData.files(in: library.id).filter { $0.status == "unmatched" || $0.status == "error" }
        if let selected, !files.contains(selected) { self.selected = files.first }
        if selected == nil { selected = files.first }
    }
}

/// 파일 하나의 수동 매칭: 에이전트·검색어로 찾아 후보를 고른다
private struct ManualMatchPanel: View {
    let library: LibraryRecord
    let file: LibraryData.FileEntry
    /// 찾지 못한 파일 모두 (시리즈를 고르면 같이 매칭할 파일을 고르게 한다)
    var others: [LibraryData.FileEntry] = []
    /// 처음 검색어·연도 (매칭 고치기는 지금 작품 제목, 없으면 경로에서 짐작)
    var initialQuery: String? = nil
    var initialYear: Int? = nil
    /// 같이 매칭할 파일을 모두 체크해 둔다 (매칭 고치기: 그 작품의 파일 모두)
    var includesAll = false
    let onMatched: () -> Void
    @State private var reviewing: AgentModels.Candidate?
    @State private var agentIndex = 0
    @State private var query = ""
    @State private var year = ""
    @State private var candidates: [AgentModels.Candidate] = []
    @State private var searching = false
    @State private var matching: String?
    @State private var errorMessage: String?

    private var agents: [(AgentRecord, String)] {
        library.agents.compactMap { entry in AgentStore.shared.agent(entry.agentID).map { ($0, entry.kind) } }
    }

    private var agentPicker: some View {
        Picker("에이전트", selection: $agentIndex) {
            ForEach(Array(agents.enumerated()), id: \.offset) { index, entry in
                Text("\(entry.0.name) · \(entry.0.kindName(entry.1))").tag(index)
            }
        }
        .labelsHidden()
        .fixedSize()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(file.path).font(.callout).foregroundStyle(.secondary).textSelection(.enabled).lineLimit(2)
            if agents.count > 1 {
                // 아이폰은 좁아서 검색 칸 위 줄에 따로
                #if os(iOS)
                agentPicker
                #endif
            }
            HStack {
                #if os(macOS)
                if agents.count > 1 { agentPicker }
                #endif
                TextField("검색어", text: $query).onSubmit { Task { await search() } }
                    #if os(iOS)
                    .textFieldStyle(.roundedBorder)
                    #endif
                TextField("연도", text: $year).frame(width: 64).onSubmit { Task { await search() } }
                    #if os(iOS)
                    .textFieldStyle(.roundedBorder)
                    .keyboardType(.numberPad)
                    #endif
                Button("검색") { Task { await search() } }
                    .disabled(query.isEmpty || agents.isEmpty)
            }
            if let errorMessage {
                Text(errorMessage).foregroundStyle(.red).font(.callout)
            }
            List(candidates) { candidate in
                HStack(spacing: 12) {
                    CachedImage(url: candidate.poster.flatMap(URL.init(string:)))
                        .frame(width: 46, height: 69)
                        .clipShape(.rect(cornerRadius: 4))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(candidate.title).font(.headline)
                        Text([candidate.year.map(String.init), candidate.titleOrigin, candidate.type == "SERIES" ? "시리즈" : "영화"]
                            .compactMap { $0 }.joined(separator: " · "))
                            .font(.caption).foregroundStyle(.secondary)
                        if let summary = candidate.summary {
                            Text(summary).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        }
                    }
                    Spacer()
                    if matching == candidate.id.value {
                        ProgressView().controlSize(.small)
                    } else {
                        Button("이 작품") { Task { await choose(candidate) } }
                            .disabled(matching != nil)
                    }
                }
            }
            .overlay {
                if searching { ProgressView() }
            }
        }
        .padding()
        .onAppear {
            query = initialQuery ?? Self.guess(file.path)
            if let initialYear { year = String(initialYear) }
        }
        .sheet(item: $reviewing) { candidate in
            let (agent, kind) = agents[agentIndex]
            BatchMatchSheet(library: library, agent: agent, kind: kind, candidate: candidate,
                            files: others.contains(file) ? others : [file] + others, chosen: file, includesAll: includesAll, onMatched: onMatched)
        }
    }

    /// 같이 매칭할 만한 파일 (같은 시리즈 폴더 또는 작품명이 같은 파일)
    private var siblings: [LibraryData.FileEntry] {
        BatchMatchSheet.siblings(of: file, in: others)
    }

    private func search() async {
        guard agents.indices.contains(agentIndex) else { return }
        let (agent, kind) = agents[agentIndex]
        searching = true
        errorMessage = nil
        do {
            candidates = try await agent.client.search(kind: kind, query: query, year: Int(year))
            if candidates.isEmpty { errorMessage = "결과가 없습니다." }
        } catch {
            errorMessage = error.localizedDescription
        }
        searching = false
    }

    private func choose(_ candidate: AgentModels.Candidate) async {
        // 시리즈이거나 같이 매칭할 파일이 있으면 회차를 확인하고 한꺼번에 (사용자 요청 2026-11-06)
        if candidate.type == "SERIES" || !siblings.isEmpty || (includesAll && others.count > 1) {
            reviewing = candidate
            return
        }
        guard agents.indices.contains(agentIndex), let hash = file.hash else { return }
        let (agent, kind) = agents[agentIndex]
        matching = candidate.id.value
        errorMessage = nil
        do {
            let result = try await agent.client.match(kind: kind, hash: hash, size: file.size, path: file.path, duration: nil,
                                                      choice: candidate.id.value, season: file.season, episode: file.episode)
            if result.matched == true {
                try LibraryData.saveMatch(result, file: file, agentID: agent.id)
                onMatched()
            } else {
                errorMessage = "매칭하지 못했습니다."
            }
        } catch {
            errorMessage = error.localizedDescription
        }
        matching = nil
    }

    /// 경로에서 검색어를 짐작한다: 파일이 든 폴더 이름 (없으면 파일 이름), 화질·연도 꼬리는 뗀다
    static func guess(_ path: String) -> String {
        let parts = path.split(separator: "/").map(String.init)
        var name = parts.count > 1 ? parts[0] : (parts.last.map { ($0 as NSString).deletingPathExtension } ?? path)
        name = name.replacingOccurrences(of: ".", with: " ").replacingOccurrences(of: "_", with: " ")
        if let range = name.range(of: #"\s*[\(\[]?(19|20)\d{2}.*$"#, options: .regularExpression) { name.removeSubrange(range) }
        if let range = name.range(of: #"\s*(1080p|720p|2160p|4k|bluray|web-?dl).*$"#, options: [.regularExpression, .caseInsensitive]) {
            name.removeSubrange(range)
        }
        return name.trimmingCharacters(in: .whitespaces)
    }
}

/// 여러 파일을 한 작품으로 한꺼번에 매칭: 파일마다 회차를 짐작해 보여주고(고칠 수 있다), 확인하면 차례로 매칭한다
private struct BatchMatchSheet: View {
    let library: LibraryRecord
    let agent: AgentRecord
    let kind: String
    let candidate: AgentModels.Candidate
    let files: [LibraryData.FileEntry]
    /// 처음 고른 파일 (맨 위, 처음부터 체크)
    let chosen: LibraryData.FileEntry
    /// 모든 파일을 처음부터 체크 (매칭 고치기)
    var includesAll = false
    let onMatched: () -> Void
    @Environment(\.dismiss) private var dismiss

    struct Row: Identifiable {
        let file: LibraryData.FileEntry
        var included: Bool
        var season: Int?
        var episode: Int?
        var id: String { file.id }
    }

    @State private var rows: [Row] = []
    @State private var episodes: [AgentModels.Episode] = []
    @State private var loadingEpisodes = true
    @State private var progress: (done: Int, total: Int)?
    @State private var failures: [String] = []

    private var isSeries: Bool { candidate.type == "SERIES" }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach($rows) { $row in
                        rowView($row)
                    }
                } header: {
                    Text(isSeries ? "체크한 파일을 이 작품의 회차로 매칭합니다. 회차가 틀리면 고치세요." : "체크한 파일을 이 작품으로 매칭합니다.")
                        .textCase(nil)
                } footer: {
                    if !failures.isEmpty {
                        Text(failures.joined(separator: "\n")).foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle(candidate.title + (candidate.year.map { " (\($0))" } ?? ""))
            .inlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("취소") { dismiss() }.disabled(progress != nil)
                }
                ToolbarItem(placement: .confirmationAction) {
                    if let progress {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("\(progress.done)/\(progress.total)").monospacedDigit()
                        }
                    } else {
                        Button("\(includedCount)개 매칭") { Task { await matchAll() } }
                            .disabled(includedCount == 0)
                    }
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 640, minHeight: 520)
        #endif
        .task { await load() }
        .interactiveDismissDisabled(progress != nil)
    }

    private var includedCount: Int { rows.filter(\.included).count }

    /// 회차만 넣고 시즌을 비웠을 때 쓸 시즌: 정규 시즌이 하나뿐인 작품은 그 시즌 (사용자 2026-11-07)
    private var onlySeason: Int? {
        let seasons = Set(episodes.map(\.season).filter { $0 > 0 })
        return seasons.count == 1 ? seasons.first : nil
    }

    @ViewBuilder
    private func rowView(_ row: Binding<Row>) -> some View {
        let value = row.wrappedValue
        HStack(spacing: 10) {
            Toggle("", isOn: row.included)
                .labelsHidden()
                #if os(macOS)
                .toggleStyle(.checkbox)
                #endif
                .disabled(value.file.hash == nil || progress != nil)
            VStack(alignment: .leading, spacing: 2) {
                Text(value.file.name).lineLimit(1).truncationMode(.middle)
                if let note = note(for: value) {
                    Text(note.text).font(.caption).foregroundStyle(note.warning ? .orange : .secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            if isSeries {
                HStack(spacing: 2) {
                    Text("S").foregroundStyle(.secondary)
                    TextField("", value: row.season, format: .number).frame(width: 40)
                    Text("E").foregroundStyle(.secondary).padding(.leading, 4)
                    TextField("", value: row.episode, format: .number).frame(width: 52)
                }
                .font(.callout.monospacedDigit())
                .multilineTextAlignment(.trailing)
                // 맥에서도 테두리를 그린다 (목록 안 기본 모양은 테두리가 없어 누를 자리가 안 보였다, 사용자 2026-11-07)
                .textFieldStyle(.roundedBorder)
                #if os(iOS)
                .keyboardType(.numberPad)
                #endif
                .disabled(!value.included || progress != nil)
            }
        }
    }

    /// 파일 아래 줄: 회차 제목, 또는 확인할 점
    private func note(for row: Row) -> (text: String, warning: Bool)? {
        if row.file.hash == nil { return ("파일 해시가 없어 매칭할 수 없습니다 (다시 훑기 필요)", true) }
        guard isSeries, row.included else { return nil }
        guard let season = row.season ?? onlySeason, let episode = row.episode else { return ("회차를 알아내지 못했습니다", true) }
        if rows.contains(where: { $0.id != row.id && $0.included && ($0.season ?? onlySeason) == season && $0.episode == episode }) {
            return ("회차가 다른 파일과 겹칩니다", true)
        }
        if let found = episodes.first(where: { $0.season == season && $0.episode == episode }) {
            return (found.title ?? "\(season)시즌 \(episode)화", false)
        }
        if loadingEpisodes { return nil }
        return (episodes.isEmpty ? "회차 목록을 받지 못했습니다" : "이 작품에 없는 회차입니다", !episodes.isEmpty)
    }

    private func load() async {
        let siblings = Set(Self.siblings(of: chosen, in: files).map(\.id))
        let ordered = [chosen] + files.filter { $0 != chosen && siblings.contains($0.id) } + files.filter { $0 != chosen && !siblings.contains($0.id) }
        rows = ordered.map { file in
            let parsed = FileNameParser.parse(file.path, series: true)
            return Row(file: file, included: file.hash != nil && (includesAll || file == chosen || siblings.contains(file.id)),
                       season: isSeries ? (file.season ?? parsed.season) : nil, episode: isSeries ? (file.episode ?? parsed.episode) : nil)
        }
        if isSeries {
            episodes = (try? await agent.client.item(candidate.id.value, kind: kind).episodes) ?? []
        }
        loadingEpisodes = false
    }

    private func matchAll() async {
        let targets = rows.filter { $0.included && $0.file.hash != nil }
        progress = (0, targets.count)
        failures = []
        for row in targets {
            do {
                let season = isSeries && row.episode != nil ? (row.season ?? onlySeason) : row.season
                let result = try await agent.client.match(kind: kind, hash: row.file.hash!, size: row.file.size, path: row.file.path, duration: nil,
                                                          choice: candidate.id.value, season: season, episode: row.episode)
                if result.matched == true {
                    try LibraryData.saveMatch(result, file: row.file, agentID: agent.id)
                } else {
                    failures.append("\(row.file.name): " + (result.reason == "NO_EPISODE" ? "시즌·회차를 넣으세요." : "매칭하지 못했습니다."))
                }
            } catch {
                failures.append("\(row.file.name): \(error.localizedDescription)")
            }
            progress?.done += 1
        }
        progress = nil
        onMatched()
        if failures.isEmpty { dismiss() }
        // 실패한 것은 남겨 다시 볼 수 있게: 매칭된 줄은 뺀다
        else { rows.removeAll { row in targets.contains { $0.id == row.id } && !failures.contains { $0.hasPrefix(row.file.name + ":") } } }
    }

    /// 같은 첫 폴더(시리즈 폴더)에 든 파일, 폴더 없이 놓였으면 작품명이 같은 파일
    static func siblings(of file: LibraryData.FileEntry, in files: [LibraryData.FileEntry]) -> [LibraryData.FileEntry] {
        let parts = file.path.split(separator: "/")
        let folder = parts.count > 1 ? String(parts[0]) : nil
        let title = FileNameParser.key(FileNameParser.parse(file.path, series: true).title)
        return files.filter { other in
            guard other != file else { return false }
            if let folder { return other.path.hasPrefix(folder + "/") }
            return other.path.split(separator: "/").count == 1 && FileNameParser.key(FileNameParser.parse(other.path, series: true).title) == title
        }
    }
}
