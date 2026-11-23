import SwiftUI

/// 텍스트 파일 표지: 읽기 테마 바탕에 문서 그림 (표지 그림이 없는 파일이라)
struct TextCover: View {
    var body: some View {
        Rectangle().fill(.quaternary)
            .overlay {
                Image(systemName: "doc.plaintext")
                    .font(.system(size: 30))
                    .foregroundStyle(.secondary)
            }
    }
}

/// 썸네일형 폴더의 텍스트 카드 (16:9) — 만화 ArchiveCard 와 같은 모양
struct TextCard: View {
    let file: VideoFile

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Color.clear
                .aspectRatio(16 / 9, contentMode: .fit)
                .overlay { TextCover() }
                .overlay(alignment: .bottom) {
                    if let progress = file.readingProgress { ProgressBar(fraction: progress) }
                }
                .clipShape(.rect(cornerRadius: 8))
                .returnHighlightBorder(cornerRadius: 8)
            MarqueeText(text: file.title)
                .cardTitleFont()
            Text(file.textSubtitle)
                .cardSubtitleFont()
                .foregroundStyle(.secondary)
        }
        .contentShape(.rect)
    }
}

extension VideoFile {
    var isText: Bool { TextBook.isText(url) }

    /// "37%" · "다 읽음" 또는 크기 (텍스트는 쪽 수 대신 글자 위치 %)
    var textSubtitle: String {
        let state = PlaybackStateStore.shared.state(for: stateKey)
        guard state.duration > 0, state.position > 0 else { return size.fileSizeText }
        let fraction = state.position / state.duration
        return fraction >= 0.995 ? "다 읽음" : "\(Int(fraction * 100))%"
    }
}
