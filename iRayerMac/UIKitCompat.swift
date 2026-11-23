import AppKit
import SwiftUI

/// 아이폰 코드가 쓰는 UIImage 를 맥에서는 NSImage 로 (그림을 읽고 쓰는 정도만 쓴다)
typealias UIImage = NSImage

extension NSImage {
    convenience init(cgImage: CGImage) {
        self.init(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }

    var cgImage: CGImage? {
        cgImage(forProposedRect: nil, context: nil, hints: nil)
    }

    func jpegData(compressionQuality: CGFloat) -> Data? {
        guard let cgImage else { return nil }
        return NSBitmapImageRep(cgImage: cgImage).representation(using: .jpeg, properties: [.compressionFactor: compressionQuality])
    }

    func pngData() -> Data? {
        guard let cgImage else { return nil }
        return NSBitmapImageRep(cgImage: cgImage).representation(using: .png, properties: [:])
    }
}

/// VLC 가 영상을 그릴 뷰 (맥은 NSView)
typealias UIView = NSView

extension Image {
    init(uiImage: NSImage) {
        self.init(nsImage: uiImage)
    }
}

/// 목록 편집 상태 (맥 SwiftUI 에는 없어서 같은 모양으로 둔다)
enum EditMode {
    case inactive, transient, active

    var isEditing: Bool { self != .inactive }
}

extension NSImage {
    /// 맥은 그릴 때 알아서 풀어 쓰므로 그대로 돌려준다
    func byPreparingForDisplay() async -> NSImage? { self }

    /// 맥 NSImage 크기는 이미 포인트 단위라 배율 1
    var scale: CGFloat { 1 }
}
