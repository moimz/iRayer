import SwiftUI

/// 설정 → 에이전트: 라이브러리의 파일이 무슨 작품인지 물어볼 곳 (docs/에이전트 규약.md)
struct AgentSettings: View {
    @State private var store = AgentStore.shared
    @State private var editing: AgentEdit?
    @State private var removing: AgentRecord?
    @State private var showsProtocol = false

    var body: some View {
        Form {
            Section {
                ForEach(store.agents) { agent in
                    SettingsRow(title: agent.name, icon: agent.type == .tmdb ? "film" : "server.rack")
                        .settingsRowActions(edit: { editing = AgentEdit(record: agent) }, remove: { removing = agent })
                        .settingsReorder(agent.id, in: store.agents.map(\.id)) { store.move(from: $0, to: $1) }
                }
                .onMove { store.move(from: $0, to: $1) }
                addMenu
            } header: {
                Text("에이전트")
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    Text("라이브러리의 영상이 무슨 작품인지 에이전트에게 물어봐서 포스터·줄거리·출연진을 받고 폴더를 정리합니다.")
                    Button("사용자 정의 에이전트 규약 보기") { showsProtocol = true }
                        #if os(macOS)
                        .buttonStyle(.link)
                        #else
                        .font(.footnote)
                        #endif
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("에이전트")
        .sheet(item: $editing) { edit in
            AgentEditView(record: edit.record, tmdb: edit.tmdb || edit.record?.type == .tmdb)
        }
        .sheet(isPresented: $showsProtocol) {
            AgentProtocolView()
        }
        .alert("‘\(removing?.name ?? "")’ 에이전트를 삭제할까요?", isPresented: Binding(
            get: { removing != nil },
            set: { if !$0 { removing = nil } }
        ), presenting: removing) { agent in
            Button("취소", role: .cancel) {}
            Button("삭제", role: .destructive) { store.remove(agent) }
        } message: { _ in
            Text("이 에이전트를 쓰는 라이브러리에서도 빠집니다.")
        }
    }

    private var addMenu: some View {
        SettingsAddMenu(title: "에이전트 추가") {
            Button("TMDB…") { editing = AgentEdit(record: nil, tmdb: true) }
            Button("사용자 정의 에이전트…") { editing = AgentEdit(record: nil) }
        }
    }

}

private struct AgentEdit: Identifiable {
    let id = UUID()
    let record: AgentRecord?
    var tmdb = false
}

/// 사용자 정의 에이전트 추가·편집: 주소와 API 키를 넣으면 에이전트에게 이름·종류를 물어본다
private struct AgentEditView: View {
    let record: AgentRecord?
    /// TMDB 에이전트면 API 키만 묻는다
    let tmdb: Bool
    @Environment(\.dismiss) private var dismiss
    @State private var url = ""
    @State private var key = ""
    @State private var working = false
    @State private var errorMessage: String?

    private var title: String {
        record == nil ? (tmdb ? "TMDB 에이전트 추가" : "사용자 정의 에이전트 추가") : "\(record?.name ?? "") 편집"
    }

    var body: some View {
        FormSheet(title: title, confirmTitle: record == nil ? "추가" : "저장",
                  confirmDisabled: tmdb ? (record == nil && key.isEmpty) : url.trimmingCharacters(in: .whitespaces).isEmpty,
                  working: working, onConfirm: save) {
            Section {
                if !tmdb {
                    TextField("주소", text: $url, prompt: Text("https://example.com/irayer"))
                        .textContentType(.URL)
                        #if os(iOS)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        #endif
                }
                SecureField("API 키", text: $key, prompt: Text(record == nil ? (tmdb ? "TMDB API 키 또는 읽기 토큰" : "에이전트에서 정한 키") : "바꾸지 않으려면 비워 두세요"))
            } header: {
                #if os(macOS)
                Text(title)
                #endif
            } footer: {
                if let errorMessage {
                    Text(errorMessage).foregroundStyle(.red)
                } else if tmdb {
                    Text("themoviedb.org 의 계정 설정 → API 에서 받은 키를 넣으세요. 영화·TV 시리즈를 TMDB 에서 직접 찾습니다.")
                } else {
                    Text("에이전트의 기본 주소입니다. 추가하면 에이전트에게 이름과 받는 종류를 물어봅니다. 집 안에서만 쓰는 에이전트는 키 없이도 될 수 있습니다.")
                }
            }
        }
        .onAppear { url = record?.url ?? "" }
    }

    private func save() {
        working = true
        errorMessage = nil
        Task {
            do {
                if let record {
                    try await AgentStore.shared.update(record, url: url, key: key.isEmpty ? nil : key)
                } else if tmdb {
                    _ = try await AgentStore.shared.addTMDB(key: key)
                } else {
                    _ = try await AgentStore.shared.addCustom(url: url, key: key)
                }
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
            }
            working = false
        }
    }
}

/// 앱에 들어 있는 에이전트 규약 문서
struct AgentProtocolView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        #if os(macOS)
        VStack(spacing: 0) {
            documentView
            Divider()
            HStack {
                Spacer()
                Button("닫기") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding()
        }
        .frame(width: 680, height: 620)
        #else
        NavigationStack {
            documentView
                .navigationTitle("에이전트 규약")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { CloseButton { dismiss() } }
                }
        }
        #endif
    }

    private var documentView: some View {
        ScrollView {
            Text(document)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(20)
        }
    }

    private var document: AttributedString {
        guard let url = Bundle.main.url(forResource: "AgentProtocol", withExtension: "md"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return AttributedString("규약 문서를 찾을 수 없습니다.") }
        return (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
    }
}
