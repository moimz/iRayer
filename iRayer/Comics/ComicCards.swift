import SwiftUI

/// 압축 파일 카드의 그림. 만화책이면 표지, 표지를 못 읽으면 내용에 맞는 아이콘:
/// 암호 걸린 만화책은 책 + 자물쇠, 다른 파일도 든 압축 파일·읽을 수 없는 것은 압축 파일 아이콘. 읽는 중에는 빈 칸.
struct ArchiveCover: View {
    let file: VideoFile
    /// 썸네일형 카드처럼 가로로 넓은 칸이면 표지를 가운데 두고 양옆을 흐린 표지로 채운다
    var fillsWideArea = false

    @State private var info: CoverInfo?

    var body: some View {
        ZStack {
            Rectangle().fill(.quaternary)
            if let info {
                if let image = info.image {
                    if fillsWideArea {
                        Image(uiImage: image).resizable().scaledToFill()
                            .blur(radius: 18)
                            .overlay(.black.opacity(0.25))
                        Image(uiImage: image).resizable().scaledToFit()
                    } else {
                        Image(uiImage: image).resizable().scaledToFill()
                    }
                } else {
                    Image(systemName: info.kind == .lockedComic ? "book.closed.fill" : "doc.zipper")
                        .font(.system(size: 30))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .overlay(alignment: .topLeading) {
            if info?.kind == .lockedComic || info?.kind == .locked {
                Image(systemName: "lock.fill")
                    .font(.caption)
                    .foregroundStyle(.white)
                    .padding(5)
                    .background(.black.opacity(0.5), in: .rect(cornerRadius: 5))
                    .padding(5)
            }
        }
        .clipped()
        .task(id: file.url) {
            info = await CoverService.shared.cached(file)
            if info == nil { info = await CoverService.shared.cover(for: file) }
        }
    }
}

/// 포스터형 폴더의 폴더 표지 (안의 cover.jpg 또는 첫 번째 책 표지)
struct FolderCover: View {
    let folder: FolderRoute
    /// 바뀌면 표지를 다시 찾는다 (폴더 화면 새로고침)
    var revision = 0
    @State private var image: UIImage?

    var body: some View {
        // 폴더 표시는 그림이 아니라 카드 칸 모서리에 (꽉 채운 그림은 칸보다 커서 그 모서리는 잘려 나간 곳이다)
        Rectangle().fill(.quaternary)
            .overlay {
                if let image {
                    Image(uiImage: image).resizable().scaledToFill()
                } else {
                    Image(systemName: "folder.fill")
                        .font(.system(size: 30))
                        .foregroundStyle(.tint)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if image != nil { FolderBadge() }
            }
            .clipped()
        .task(id: "\(folder.url.absoluteString)#\(revision)") { image = await CoverService.shared.cover(forFolder: folder) }
    }
}

/// 그림이 든 폴더 카드 모서리의 작은 폴더 표시 (영상·책 카드와 구분)
struct FolderBadge: View {
    var body: some View {
        Image(systemName: "folder.fill")
            .font(.caption)
            .foregroundStyle(.white)
            .padding(5)
            .background(.black.opacity(0.45), in: .rect(cornerRadius: 5))
            .padding(5)
    }
}

/// 세로 포스터 카드 (2:3): 그림 + 진행률 + 흐르는 제목 + 보조 줄
struct PosterCard<Artwork: View>: View {
    let title: String
    let subtitle: String
    var progress: Double?
    @ViewBuilder let artwork: Artwork

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Color.clear
                .aspectRatio(2 / 3, contentMode: .fit)
                .overlay { artwork }
                .overlay(alignment: .bottom) {
                    if let progress, progress > 0 { ProgressBar(fraction: progress) }
                }
                .clipShape(.rect(cornerRadius: 8))
                .returnHighlightBorder(cornerRadius: 8)
            MarqueeText(text: title)
                .cardTitleFont()
            Text(subtitle)
                .cardSubtitleFont()
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .contentShape(.rect)
    }
}

extension VideoFile {
    /// 만화책 읽은 정도 (0~1, 읽지 않았으면 nil). 위치 = 본 쪽 수, 길이 = 전체 쪽 수로 저장한다.
    var readingProgress: Double? {
        let state = PlaybackStateStore.shared.state(for: stateKey)
        guard state.duration > 0, state.position > 0 else { return nil }
        return state.position / state.duration
    }

    /// "12 / 120쪽" 또는 크기
    var readingSubtitle: String {
        let state = PlaybackStateStore.shared.state(for: stateKey)
        guard state.duration > 0, state.position > 0 else { return size.fileSizeText }
        return state.position >= state.duration ? "다 읽음" : "\(Int(state.position)) / \(Int(state.duration))쪽"
    }
}

/// 만화책 길게 누르기 메뉴의 읽기 기록 항목 (읽은 기록이 있을 때만): 다 읽은 것으로 표시 / 읽기 기록 지우기
struct ReadingRecordMenu: View {
    let file: VideoFile

    var body: some View {
        let state = PlaybackStateStore.shared.state(for: file.stateKey)
        if state.position > 0, state.duration > 0 {
            if state.position < state.duration {
                Button("다 읽은 것으로 표시", systemImage: "checkmark") { file.markRead() }
            }
            Button("읽기 기록 지우기", systemImage: "arrow.counterclockwise") { file.clearPlaybackRecord() }
        }
    }
}

extension VideoFile {
    /// 만화책을 다 읽은 것으로 (목록에 "다 읽음", 홈 이어보기에서 빠진다)
    func markRead() {
        PlaybackStateStore.shared.update(stateKey) { $0.position = $0.duration }
        WatchHistory.shared.record(self, finished: true)
    }
}
