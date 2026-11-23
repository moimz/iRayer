import SwiftUI

/// 사이드바(맥·아이패드)에 바로 두는 위치: 이 기기, 폴더, 네트워크 서버와 그 즐겨찾기
enum SidebarLocation: Hashable {
    case thisDevice
    case folder(UUID)
    case server(UUID)
    case favorite(UUID)
}

/// 사이드바에서 고른 위치의 화면 (그 안에서 폴더·작품으로 들어간다)
struct SidebarLocationView: View {
    let location: SidebarLocation
    @State private var locations = LocationStore.shared

    var body: some View {
        switch location {
        case .thisDevice:
            folderStack(FolderRoute(url: locations.documentsURL, title: LocationStore.thisDeviceName))
        case .folder(let id):
            if let folder = locations.folders.first(where: { $0.id == id }), let url = locations.resolve(folder) {
                folderStack(FolderRoute(url: url, title: folder.name, location: .folder(folder.id)))
            } else {
                ContentUnavailableView("폴더에 접근할 수 없습니다", systemImage: "folder.badge.questionmark")
            }
        case .server(let id):
            if let server = locations.servers.first(where: { $0.id == id }), let url = server.rootURL {
                folderStack(FolderRoute(url: url, title: server.name, serverID: server.id, location: .server(server.id)))
            }
        case .favorite(let id):
            if let (favorite, server) = favorite(id) {
                folderStack(FolderRoute(url: favorite.url, title: favorite.name, serverID: server.id, location: .favorite(favorite.id)))
            }
        }
    }

    private func folderStack(_ route: FolderRoute) -> some View {
        FolderStack(route: route).id(route.url)
    }

    private func favorite(_ id: UUID) -> (ServerFavorite, NetworkServer)? {
        for server in locations.servers {
            if let favorite = locations.favorites(of: server.id).first(where: { $0.id == id }) { return (favorite, server) }
        }
        return nil
    }
}

/// 사이드바 위치의 폴더 화면. 제목의 상위 폴더를 누르면 쌓인 화면을 그만큼 되돌리고,
/// 즐겨찾기처럼 위치 중간에서 시작했으면 그 상위 폴더를 새 시작 화면으로 연다.
private struct FolderStack: View {
    let route: FolderRoute
    @State private var root: FolderRoute?
    @State private var history = StackHistory()

    var body: some View {
        AppNavigationStack(history: history) {
            FolderView(route: root ?? route)
                .id(root?.url)
                .locationDestinations()
                .environment(\.openAncestor, openAncestor)
        }
    }

    private func openAncestor(_ depth: Int, _ folder: FolderRoute) {
        if depth <= history.path.count {
            history.goBack(depth)
        } else {
            root = folder
            history = StackHistory()
        }
    }
}

extension EnvironmentValues {
    /// 폴더 제목에서 상위 폴더를 골랐을 때 (몇 단계 위인지, 그 폴더). 없으면 그 폴더를 새로 쌓아 연다.
    @Entry var openAncestor: ((Int, FolderRoute) -> Void)?
}
