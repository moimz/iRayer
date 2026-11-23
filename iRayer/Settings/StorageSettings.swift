import SwiftUI

/// 설정 → 저장소: 영상을 가져오는 곳 (SMB, WebDAV). 라이브러리와 폴더는 여기 등록한 저장소에서 고른다.
struct StorageSettings: View {
    @State private var locations = LocationStore.shared
    @State private var editing: NetworkServer?
    @State private var removing: NetworkServer?

    var body: some View {
        Form {
            Section {
                ForEach(locations.servers) { server in
                    SettingsRow(title: server.name, icon: "externaldrive.connected.to.line.below")
                        .settingsRowActions(edit: { editing = server }, remove: { removing = server })
                        .settingsReorder(server.id, in: locations.servers.map(\.id)) { locations.moveServers(from: $0, to: $1) }
                }
                .onMove { locations.moveServers(from: $0, to: $1) }
                SettingsAddButton(title: "저장소 추가", action: add)
            } header: {
                Text("저장소")
            } footer: {
                Text("라이브러리와 폴더는 여기 등록한 저장소에서 고릅니다. 저장소를 삭제해도 안의 영상은 지워지지 않습니다.")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("저장소")
        .sheet(item: $editing) { server in
            ServerEditView(server: server)
        }
        .alert("‘\(removing?.name ?? "")’ 저장소를 삭제할까요?", isPresented: Binding(
            get: { removing != nil },
            set: { if !$0 { removing = nil } }
        ), presenting: removing) { server in
            Button("취소", role: .cancel) {}
            Button("삭제", role: .destructive) { locations.remove(server) }
        } message: { _ in
            Text("이 저장소의 라이브러리와 폴더도 함께 빠집니다. 저장소 안의 영상은 지워지지 않습니다.")
        }
    }

    private func add() {
        editing = NetworkServer(kind: .smb, name: "", address: "", username: "")
    }
}
