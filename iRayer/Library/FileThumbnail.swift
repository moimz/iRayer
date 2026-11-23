import SwiftUI

/// 영상의 썸네일 (영상에서 한 장면을 뽑는다)
struct FileThumbnail: View {
    let file: VideoFile
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            Rectangle().fill(.quaternary)
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Image(systemName: "film").foregroundStyle(.secondary)
            }
        }
        .task(id: file.url) { image = await ThumbnailService.shared.thumbnail(for: file) }
    }
}
