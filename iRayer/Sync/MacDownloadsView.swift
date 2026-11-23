import SwiftUI

#if os(iOS)
/// 아이폰·아이패드 [다운로드]: 맥에서 받는(받은) 것 (2026-11-09, 사용자). 받기는 맥이 하고 여기서는 본다.
/// 맥마다 묶고, 끝난 항목은 [끝난 항목 지우기] 를 누를 때까지 남는다 (어느 기기에서 지우든 모두 지워진다)
struct MacDownloadsView: View {
    @State private var downloads = MacDownloads.shared

    var body: some View {
        Group {
            if downloads.entries.isEmpty {
                ContentUnavailableView("받는 영상 없음", systemImage: "arrow.down.circle",
                                       description: Text("맥의 웹 탐색에서 받는 영상이 여기에 나타납니다."))
            } else {
                List {
                    ForEach(downloads.groups, id: \.mac) { group in
                        Section(group.mac) {
                            ForEach(group.entries, id: \.key) { row in
                                MacDownloadRow(entry: row.entry)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("다운로드")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("끝난 항목 지우기", systemImage: "trash") { downloads.clearFinished() }
                    .disabled(!downloads.hasFinished)
            }
        }
        // 당겨서 바로 받아 오기 (iCloud 알림이 늦을 때)
        .refreshable { await SyncEngine.shared.syncNow() }
        .task { await SyncEngine.shared.syncNow() }
    }
}

#endif

/// 한 줄 (바뀜 2026-11-10, 사용자: 맥 다운로드 화면도 iCloud 목록을 같이 보여 맥에서도 쓴다)
struct MacDownloadRow: View {
    let entry: MacDownloadEntry

    var body: some View {
        HStack(spacing: 12) {
            // 바뀜 (2026-11-10, 사용자): 그림 폭이 달라 줄마다 글 시작이 어긋났다 — 그림 자리 폭을 고정
            Image(systemName: entry.type == "capture" ? "record.circle" : "film")
                .font(.title2)
                .foregroundStyle(.secondary)
                .frame(width: 32)
            VStack(alignment: .leading, spacing: 4) {
                // 바뀜 (2026-11-10, 사용자): 이름은 한 줄, 길면 옆으로 흘러가며 다 보인다
                MarqueeText(text: entry.title)
                // 바뀜 (2026-11-09, 사용자): 재생하며 받기는 0초~끝 막대에 받은 곳만 칠해 빈 구간이 뚫려 보이게 (끝난 뒤에도 남은 빈 구간이 보인다)
                if let received = entry.received, let duration = entry.duration {
                    CoverageBar(received: received, duration: duration)
                        .frame(height: 6)
                } else if entry.active, let fraction = entry.fraction {
                    ProgressView(value: fraction)
                }
                Text(statusText)
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(entry.status.hasPrefix("실패") ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }

    /// "받는 중 (빈 구간 1개) · 42%"
    private var statusText: String {
        guard entry.active, let fraction = entry.fraction else { return entry.status }
        return "\(entry.status) · \(Int((fraction * 100).rounded()))%"
    }
}

/// 0초~끝 막대: 바탕은 빈 곳, 받은 구간만 강조색 (맥 다운로드 화면과 같은 모양)
private struct CoverageBar: View {
    let received: [ClosedRange<Double>]
    let duration: Double

    var body: some View {
        Canvas { context, size in
            let radius = size.height / 2
            let track = Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: radius)
            context.fill(track, with: .color(.secondary.opacity(0.2)))
            context.clip(to: track)
            guard duration > 0 else { return }
            for range in received {
                // 아주 짧은 조각도 동그란 점은 되게 (폭은 높이 이상)
                let width = max(size.height, size.width * (range.upperBound - range.lowerBound) / duration)
                let x = min(size.width * range.lowerBound / duration, size.width - width)
                context.fill(Path(roundedRect: CGRect(x: x, y: 0, width: width, height: size.height), cornerRadius: radius),
                             with: .color(.accentColor))
            }
        }
        .accessibilityLabel("받은 구간")
    }
}
