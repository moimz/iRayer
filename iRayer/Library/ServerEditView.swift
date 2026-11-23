import SwiftUI

/// 네트워크 서버 추가·편집
struct ServerEditView: View {
    @State private var server: NetworkServer
    @State private var password = ""
    @State private var checking = false
    @State private var errorMessage: String?
    @FocusState private var focus: Field?
    @Environment(\.dismiss) private var dismiss

    private enum Field: Hashable {
        case name, address, username, password
    }

    private let isNew: Bool

    init(server: NetworkServer) {
        _server = State(initialValue: server)
        isNew = !LocationStore.shared.servers.contains { $0.id == server.id }
    }

    var body: some View {
        // 설정의 다른 시트와 같은 틀: 맥은 제목 없이 아래 [취소] [저장], 아이폰·아이패드는 ✕ / ✓
        FormSheet(title: isNew ? "저장소 추가" : "저장소 편집", confirmTitle: isNew ? "추가" : "저장",
                  confirmDisabled: server.address.trimmingCharacters(in: .whitespaces).isEmpty, working: checking,
                  macSize: CGSize(width: 480, height: 0)) {
            Task { await save() }
        } content: {
                Section {
                    Picker("종류", selection: $server.kind) {
                        ForEach(NetworkServer.Kind.allCases, id: \.self) { kind in
                            Text(kind.title).tag(kind)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                Section {
                    // 입력란마다 키보드 설정이 다르면 옮겨 갈 때 키보드가 다시 만들어지며 깜박이므로
                    // 자동 대문자·자동 수정은 모든 입력란에서 똑같이 끈다 (주소의 URL 키보드만 다르다)
                    TextField("이름", text: $server.name, prompt: Text("예: 거실 NAS"))
                        .focused($focus, equals: .name)
                        .submitLabel(.next)
                        .onSubmit { focus = .address }
                    TextField("주소", text: $server.address, prompt: Text(addressPrompt))
                        .urlKeyboard()
                        .focused($focus, equals: .address)
                        .submitLabel(.next)
                        .onSubmit { focus = .username }
                } footer: {
                    Text(addressFooter)
                }

                // iOS 가 로그인 화면으로 보고 암호 앱에 "암호를 저장할까요?" 를 띄우지 않게 한다.
                // 서버 암호는 앱 전용 키체인에 두고, 나중에 iCloud 키체인 동기화로 다른 기기에 옮긴다.
                Section("로그인") {
                    TextField("아이디", text: $server.username)
                        .textContentType(.oneTimeCode)
                        .focused($focus, equals: .username)
                        .submitLabel(.next)
                        .onSubmit { focus = .password }
                    SecureField(isNew ? "비밀번호" : "비밀번호 (바꿀 때만 입력)", text: $password)
                        .textContentType(.oneTimeCode)
                        .focused($focus, equals: .password)
                        .submitLabel(.done)
                        .onSubmit { Task { await save() } }
                }
        }
            .plainTextInput()
            // 실패 이유는 키보드에 가려지지 않게 알림으로 보여준다
            .alert("저장하지 못했습니다", isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button("확인", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "")
            }
    }

    private var addressPrompt: String {
        server.kind == .webdav ? "http://192.168.0.10:5005/video" : "192.168.0.10/video"
    }

    private var addressFooter: String {
        server.kind == .webdav
            ? "http:// 또는 https:// 로 시작하는 WebDAV 주소입니다. 포트와 시작 폴더 경로를 포함할 수 있습니다."
            : "NAS 주소와 공유 폴더 이름입니다. 공유 폴더를 빼면 공유 폴더 목록부터 보여줍니다."
    }

    /// 저장 전에 실제로 접속해 본다 (WebDAV). 실패하면 이유를 보여주고 저장하지 않는다.
    private func save() async {
        if server.name.trimmingCharacters(in: .whitespaces).isEmpty {
            server.name = server.rootURL?.host() ?? server.address
        }
        guard let rootURL = server.rootURL else {
            errorMessage = "주소 형식이 올바르지 않습니다."
            return
        }

        let store = LocationStore.shared
        let previous = store.servers.first { $0.id == server.id }
        store.saveServer(server, password: isNew || !password.isEmpty ? password : nil)

        do {
            checking = true
            defer { checking = false }
            do {
                // 접속 정보가 바뀌었을 수 있으니 저장된 SMB 연결을 버리고 새로 접속한다
                if server.kind == .smb { await SMBClient.shared.reset() }
                switch server.kind {
                case .webdav: _ = try await WebDAVClient.list(rootURL, serverID: server.id)
                case .smb: _ = try await SMBClient.shared.list(rootURL, serverID: server.id)
                }
            } catch {
                // 접속에 실패하면 저장 전 상태로 되돌린다
                if let previous {
                    store.saveServer(previous, password: nil)
                } else {
                    store.remove(server)
                }
                errorMessage = error.localizedDescription
                return
            }
        }
        dismiss()
    }
}
