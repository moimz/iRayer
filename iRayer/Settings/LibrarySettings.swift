import SwiftUI

/// 설정 → 라이브러리: 라이브러리(에이전트로 매칭하는 곳)와 폴더(그냥 보는 곳). 사이드바에는 여기서 정한 것이 보인다.
struct LibrarySettings: View {
    @State private var libraries = LibraryStore.shared
    @State private var locations = LocationStore.shared
    @State private var editingLibrary: LibraryEdit?
    @State private var removing: Removal?
    @State private var showFolderPicker = false
    @State private var pickingServer: NetworkServer?
    /// 추가하거나 편집할 폴더 (폴더 화면의 폴더 설정과 같은 화면)
    @State private var folderSettings: FolderSettingsView.Target?

    private struct LibraryEdit: Identifiable {
        let id = UUID()
        let library: LibraryRecord?
    }

    private enum Removal: Identifiable {
        case library(LibraryRecord), folder(FolderLocation), favorite(ServerFavorite)

        var id: String {
            switch self {
            case .library(let library): "l" + library.id
            case .folder(let folder): "f" + folder.id.uuidString
            case .favorite(let favorite): "v" + favorite.id.uuidString
            }
        }

        var name: String {
            switch self {
            case .library(let library): library.name
            case .folder(let folder): folder.name
            case .favorite(let favorite): favorite.name
            }
        }
    }

    var body: some View {
        Form {
            librarySection
            folderSection
        }
        .formStyle(.grouped)
        .navigationTitle("라이브러리·폴더")
        .sheet(item: $editingLibrary) { edit in
            LibraryAddView(library: edit.library)
        }
        .sheet(item: $pickingServer) { server in
            RemoteFolderPicker(server: server, start: server.rootURL) { url in
                // 폴더 고르기 창이 닫힌 다음 이름 창을 띄운다
                DispatchQueue.main.async { folderSettings = .newStorage(server, url) }
            }
        }
        .fileImporter(isPresented: $showFolderPicker, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result { folderSettings = .newLocal(url) }
        }
        .sheet(item: $folderSettings) { target in
            FolderSettingsView(target: target)
        }
        .alert("‘\(removing?.name ?? "")’을(를) 삭제할까요?", isPresented: Binding(
            get: { removing != nil },
            set: { if !$0 { removing = nil } }
        ), presenting: removing) { removal in
            Button("취소", role: .cancel) {}
            Button("삭제", role: .destructive) { remove(removal) }
        } message: { removal in
            switch removal {
            case .library: Text("받아 둔 작품 정보만 지웁니다. 저장소 안의 영상은 그대로입니다.")
            default: Text("폴더 안의 영상은 지워지지 않습니다.")
            }
        }
    }

    // MARK: - 라이브러리

    private var librarySection: some View {
        Section {
            ForEach(libraries.libraries) { library in
                SettingsRow(title: library.name, icon: library.symbol)
                    .settingsRowActions(edit: { editingLibrary = LibraryEdit(library: library) }, remove: { removing = .library(library) })
                    .settingsReorder(library.id, in: libraries.libraries.map(\.id)) { libraries.move(from: $0, to: $1) }
            }
            .onMove { libraries.move(from: $0, to: $1) }
            SettingsAddButton(title: "라이브러리 추가") { editingLibrary = LibraryEdit(library: nil) }
        } header: {
            Text("라이브러리")
        } footer: {
            Text("저장소의 폴더 하나를 영화·드라마 같은 종류로 정하면, 에이전트에게 작품을 물어보고 포스터로 보여줍니다. 다시 훑기는 라이브러리 설정에서 합니다.")
        }
    }

    // MARK: - 폴더

    private var folderSection: some View {
        Section {
            // 이 기기 폴더는 늘 맨 위 (이름·삭제·순서 없음, 보기·홈·검색만 정한다)
            SettingsRow(title: LocationStore.thisDeviceName, icon: LocationStore.thisDeviceIcon, movable: false)
                .settingsRowActions(edit: { folderSettings = .edit(.thisDevice) }, remove: nil)
            ForEach(locations.folders) { folder in
                SettingsRow(title: folder.name, icon: locations.resolve(folder) != nil ? folder.symbol : "folder.badge.questionmark")
                    .settingsRowActions(edit: { folderSettings = .edit(.folder(folder)) }, remove: { removing = .folder(folder) })
                    .settingsReorder(folder.id, in: locations.folders.map(\.id)) { locations.moveFolders(from: $0, to: $1) }
            }
            .onMove { locations.moveFolders(from: $0, to: $1) }
            ForEach(locations.servers) { server in
                ForEach(locations.favorites(of: server.id)) { favorite in
                    SettingsRow(title: favorite.name, icon: favorite.symbol)
                        .settingsRowActions(edit: { folderSettings = .edit(.favorite(favorite)) }, remove: { removing = .favorite(favorite) })
                        .settingsReorder(favorite.id, in: locations.favorites(of: server.id).map(\.id)) {
                            locations.moveFavorites(of: server.id, from: $0, to: $1)
                        }
                }
                .onMove { locations.moveFavorites(of: server.id, from: $0, to: $1) }
            }
            addFolderMenu
        } header: {
            Text("폴더")
        } footer: {
            Text("폴더는 매칭하지 않고 안의 파일을 그대로 보여줍니다. 폴더 설정은 그 하위 폴더에도 모두 적용됩니다. 삭제해도 폴더 안의 영상은 지워지지 않습니다.")
        }
    }

    private var addFolderMenu: some View {
        SettingsAddMenu(title: "폴더 추가") {
            Button("\(LocationStore.thisDeviceName) 의 폴더…") { showFolderPicker = true }
            if !locations.servers.isEmpty {
                Divider()
                ForEach(locations.servers) { server in
                    Button("\(server.name) 의 폴더…") { pickingServer = server }
                }
            }
        }
    }

    private func remove(_ removal: Removal) {
        switch removal {
        case .library(let library): libraries.remove(library)
        case .folder(let folder): locations.remove(folder)
        case .favorite(let favorite): locations.remove(favorite)
        }
    }
}
