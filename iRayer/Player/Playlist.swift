import SwiftUI

/// 재생 중인 영상과 같은 묶음의 영상들 (플레이어의 재생목록 버튼)
/// - 이 기기·폴더·NAS: 같은 폴더의 영상
enum Playlist {
    struct Group: Identifiable {
        let title: String
        let files: [VideoFile]
        var id: String { title }
    }

    static func load(for file: VideoFile) async -> [Group] {
        let folder = file.url.deletingLastPathComponent()
        let isDocuments = folder.standardizedFileURL.path == LocationStore.shared.documentsURL.standardizedFileURL.path
        let route = FolderRoute(url: folder, title: isDocuments ? LocationStore.thisDeviceName : folder.lastPathComponent, serverID: file.serverID)
        guard let listing = try? await DirectoryLister.list(route), !listing.videos.isEmpty else { return [] }
        return [Group(title: route.title, files: listing.videos)]
    }
}

/// 재생목록 시트: 묶음별 영상 목록. 고르면 그 영상으로 바꿔 재생한다.
struct PlaylistView: View {
    @Environment(\.horizontalSizeClass) private var sizeClass
    let current: VideoFile
    let onSelect: (VideoFile) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var groups: [Playlist.Group]?

    var body: some View {
        NavigationStack {
            Group {
                if let groups, !groups.isEmpty {
                    // 폴더 목록과 같은 카드 격자 (아이폰 세로 2열, 넓은 화면은 더 많이)
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 20) {
                                ForEach(groups) { group in
                                    Text(group.title)
                                        .font(.headline)
                                    LazyVGrid(columns: [GridItem(.adaptive(minimum: sizeClass == .regular ? 220 : 160), spacing: 12)], spacing: 16) {
                                        ForEach(group.files) { file in
                                            Button {
                                                dismiss()
                                                onSelect(file)
                                            } label: {
                                                VideoCard(file: file, isCurrent: isCurrent(file))
                                            }
                                            .buttonStyle(.plain)
                                            .id("\(group.id)|\(file.id)")
                                        }
                                    }
                                }
                            }
                            .padding()
                        }
                        .onAppear {
                            // 재생 중인 영상이 보이게
                            if let group = groups.first(where: { $0.files.contains(where: isCurrent) }),
                               let file = group.files.first(where: isCurrent) {
                                proxy.scrollTo("\(group.id)|\(file.id)", anchor: .center)
                            }
                        }
                    }
                } else if groups != nil {
                    ContentUnavailableView("재생목록이 없습니다", systemImage: "list.bullet",
                                           description: Text("같은 폴더에 다른 영상이 없습니다."))
                } else {
                    ProgressView()
                }
            }
            .navigationTitle("재생목록")
            .inlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .closeBar) {
                    CloseButton { dismiss() }
                }
            }
        }
        .task { groups = await Playlist.load(for: current) }
    }

    /// 파일명+크기로 비교한다
    /// (같은 폴더 안이므로 겹치지 않는다. 주소는 /var 와 /private/var 처럼 표기가 달라질 수 있다)
    private func isCurrent(_ file: VideoFile) -> Bool {
        return file.stateKey == current.stateKey
    }
}
