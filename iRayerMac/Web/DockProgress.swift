import AppKit

/// 받는 중일 때 Dock 아이콘 오른쪽 아래에 크롬처럼 개수와 진행률 원을 그린다 (2026-11-15, 사용자).
/// - 개수: 받기 중(다시 시도 포함) + 재생하며 받기가 켜져 있거나 묶는 중인 탭 (앱을 끌 때 묻는 개수와 같다)
/// - 원: 진행률을 아는 것들의 평균. 아는 것이 없으면 빈 원만 그린다
/// - 0.5초마다 보되, 개수나 진행률(1% 단위)이 바뀔 때만 다시 그린다. 다 끝나면 원래 아이콘으로
@MainActor
final class DockProgress {
    static let shared = DockProgress()

    private var timer: Timer?
    private let view = DockProgressView()
    /// 마지막에 그린 것 (nil = 원래 아이콘)
    private var shown: DockProgressView.Value?

    func start() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
            MainActor.assumeIsolated { DockProgress.shared.tick() }
        }
    }

    private func tick() {
        let value = current()
        guard value != shown else { return }
        shown = value
        let tile = NSApp.dockTile
        if let value {
            view.value = value
            if tile.contentView !== view { tile.contentView = view }
        } else {
            tile.contentView = nil
        }
        tile.display()
    }

    private func current() -> DockProgressView.Value? {
        let downloads = WebDownloads.shared.items.filter(\.isActive)
        let captures = WebTabs.shared.busyCaptures
        let count = downloads.count + captures.count
        guard count > 0 else { return nil }
        let fractions = downloads.compactMap(\.progress) + captures.compactMap { WebDownloadStatus.fraction($0) }
        let fraction = fractions.isEmpty ? nil : fractions.reduce(0, +) / Double(fractions.count)
        return .init(count: count, percent: fraction.map { Int(($0 * 100).rounded()) })
    }
}

/// Dock 아이콘: 앱 아이콘 위 오른쪽 아래에 흰 원 + 진행률 호 + 개수
final class DockProgressView: NSView {
    struct Value: Equatable {
        var count: Int
        /// 0...100, 모르면 nil
        var percent: Int?
    }

    var value = Value(count: 0, percent: nil)

    override func draw(_ dirtyRect: NSRect) {
        NSApp.applicationIconImage?.draw(in: bounds)
        let side = bounds.width * 0.42
        let circle = NSRect(x: bounds.maxX - side - bounds.width * 0.02, y: bounds.minY + bounds.width * 0.04, width: side, height: side)

        NSColor.white.setFill()
        NSBezierPath(ovalIn: circle).fill()

        let line = side * 0.1
        let ring = circle.insetBy(dx: line * 0.9, dy: line * 0.9)
        let center = NSPoint(x: ring.midX, y: ring.midY)
        let radius = ring.width / 2

        let track = NSBezierPath()
        track.appendArc(withCenter: center, radius: radius, startAngle: 0, endAngle: 360)
        track.lineWidth = line
        NSColor(white: 0.85, alpha: 1).setStroke()
        track.stroke()

        if let percent = value.percent, percent > 0 {
            // 12시 방향에서 시계 방향으로
            let arc = NSBezierPath()
            arc.appendArc(withCenter: center, radius: radius, startAngle: 90, endAngle: 90 - 360 * CGFloat(min(percent, 100)) / 100, clockwise: true)
            arc.lineWidth = line
            arc.lineCapStyle = .round
            NSColor.systemBlue.setStroke()
            arc.stroke()
        }

        let text = value.count > 99 ? "99+" : "\(value.count)"
        let font = NSFont.systemFont(ofSize: side * (text.count > 1 ? 0.38 : 0.48), weight: .semibold)
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor(white: 0.25, alpha: 1)]
        let size = text.size(withAttributes: attributes)
        text.draw(at: NSPoint(x: circle.midX - size.width / 2, y: circle.midY - size.height / 2), withAttributes: attributes)
    }
}
