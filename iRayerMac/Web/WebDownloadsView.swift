import SwiftUI

/// 사이드바 [다운로드]: 웹에서 받는(받은) 영상 목록. 앱을 끄면 목록은 비고 받은 파일만 남는다.
/// 바뀜 (2026-11-08, 사용자): 탭마다의 재생하며 받기도 위에 함께 보인다 (받은 구간을 0초~끝 막대로)
/// 바뀜 (2026-11-10, 사용자): 폰처럼 iCloud 목록 전체 — 지금 받는 것은 아래처럼 바로바로, 그 밖(앱을 다시 켜기 전 것·탭을 닫아 빠진 것·
///   다른 맥의 것)은 iCloud 에 올라간 줄 그대로. 앱을 꺼도 목록이 남는다
struct WebDownloadsView: View {
    @State private var downloads = WebDownloads.shared
    @State private var tabs = WebTabs.shared
    @State private var status = WebDownloadStatus.shared

    typealias Row = (key: String, entry: MacDownloadEntry)

    private static func rows(_ entries: [String: MacDownloadEntry]) -> [Row] {
        let sorted: [(key: String, value: MacDownloadEntry)] = entries.sorted { $0.value.since > $1.value.since }
        return sorted.map { Row(key: $0.key, entry: $0.value) }
    }

    /// 이 맥의 지난 항목 (최근 것 먼저)
    private var pastRows: [Row] {
        Self.rows(status.extras.filter { $0.value.macID == status.macID })
    }

    /// 다른 맥의 항목 (맥마다, 이름 순)
    private var otherMacs: [(mac: String, rows: [Row])] {
        let others: [String: MacDownloadEntry] = status.extras.filter { $0.value.macID != status.macID }
        var byMac: [String: [String: MacDownloadEntry]] = [:]
        for (key, entry) in others { byMac[entry.macID, default: [:]][key] = entry }
        var groups: [(mac: String, rows: [Row])] = []
        for entries in byMac.values {
            let rows = Self.rows(entries)
            groups.append((mac: rows.first?.entry.macName ?? "Mac", rows: rows))
        }
        return groups.sorted { $0.mac.localizedStandardCompare($1.mac) == .orderedAscending }
    }

    /// 재생하며 받기를 켰거나 결과가 남아 있는 탭
    private var captures: [WebCapture] { tabs.tabs.map(\.capture).filter { $0.state != .off } }

    var body: some View {
        Group {
            // 바뀜 (2026-11-10, 사용자): 다른 맥 화면처럼 맨 위에 큰 제목
            if downloads.items.isEmpty && captures.isEmpty && status.extras.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    MacPageTitle("다운로드", inset: false)
                        .padding(.horizontal, 20)
                        .padding(.top, 12)
                    ContentUnavailableView("받은 영상 없음", systemImage: "arrow.down.circle",
                                           description: Text("웹 탐색에서 찾은 영상을 받으면 여기에 나타납니다."))
                }
            } else {
                List {
                    MacPageTitle("다운로드", inset: false)
                        .listRowSeparator(.hidden)
                    ForEach(captures, id: \.self) { capture in
                        CaptureDownloadRow(capture: capture)
                    }
                    ForEach(downloads.items) { item in
                        DownloadRow(item: item)
                    }
                    ForEach(pastRows, id: \.key) { row in
                        MacDownloadRow(entry: row.entry)
                    }
                    ForEach(otherMacs, id: \.mac) { group in
                        Section(group.mac) {
                            ForEach(group.rows, id: \.key) { row in
                                MacDownloadRow(entry: row.entry)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("다운로드")
        .toolbar {
            // 바뀜 (2026-11-10, 사용자): 아이폰·아이패드처럼 오른쪽에 (맥은 제목을 숨긴 창이라 동작 자리가 왼쪽부터 흐른다 — 늘어나는 빈칸을 먼저)
            ToolbarSpacer(.flexible)
            ToolbarItem(placement: .primaryAction) {
                // 바뀜 (2026-11-08, 사용자): 이 화면의 단추가 이것 하나라 ⓧ 대신 휴지통 그림 (목록에서만 지우고 파일은 그대로)
                Button("끝난 항목 지우기", systemImage: "trash") { downloads.clearFinished() }
                    .disabled(!downloads.items.contains { !$0.isActive } && !status.extras.values.contains { !$0.active })
                    .help("받는 중이 아닌 항목을 목록에서 지웁니다 (파일은 그대로)")
            }
        }
    }
}

private struct DownloadRow: View {
    let item: WebDownloads.Item
    @State private var downloads = WebDownloads.shared

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "film")
                .font(.title2)
                .foregroundStyle(.secondary)
                // 바뀜 (2026-11-10, 사용자): iCloud 줄(MacDownloadRow)과 그림 자리 폭을 같게
                .frame(width: 32)
            VStack(alignment: .leading, spacing: 4) {
                Text(item.file.lastPathComponent)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if item.state == .done {
                    Text("완료 · \(ByteCountFormatter.string(fromByteCount: item.received, countStyle: .file))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    WebDownloadProgress(item: item)
                }
            }
            Spacer()
            WebDownloadButton(media: item.media, item: item)
        }
        .padding(.vertical, 4)
        .contextMenu {
            Button("Finder 에서 보기") { downloads.reveal(item) }
            if !item.isActive && item.state != .done {
                Button("이어받기") { downloads.resume(item) }
                Divider()
                Button("받다 만 파일 지우기", role: .destructive) { downloads.discard(item) }
            }
        }
    }
}

/// 받기 단추 (감지 패널·다운로드 화면 같이): 받기 → 받는 중이면 [중지] → 멈췄거나 실패하면 [이어받기] → 끝나면 [Finder 에서 보기]
struct WebDownloadButton: View {
    let media: WebMedia
    let item: WebDownloads.Item?
    @State private var downloads = WebDownloads.shared

    var body: some View {
        Group {
            if let item {
                switch item.state {
                case .running, .retrying:
                    Button("중지", systemImage: "stop.circle") { downloads.stop(item) }
                        .help("멈춥니다. 받던 곳은 남겨 두고 나중에 이어 받을 수 있습니다.")
                case .stopped, .failed:
                    Button("이어받기", systemImage: "arrow.clockwise.circle") { downloads.resume(item) }
                        .help("받던 곳부터 이어 받습니다")
                case .done:
                    Button("Finder 에서 보기", systemImage: "magnifyingglass.circle") { downloads.reveal(item) }
                        .help("받은 파일을 Finder 에서 보기")
                }
            } else if media.capturesOnly {
                // 표준대로 못 받는 영상: 누르면 재생하며 받기 (새로고침 후 재생되는 그대로)
                // 바뀜 (2026-11-08): 지금 탭의 재생하며 받기 (감지 목록은 지금 탭 것)
                Button("재생하며 받기", systemImage: "record.circle") { WebTabs.shared.current.capture.start() }
                    .disabled(WebTabs.shared.current.capture.isOn)
                    .help(media.kind == .mse ? "받기 단추로 받을 수 없는 플레이어입니다. 누르면 지금 자리부터 재생되는 그대로 받습니다."
                          : media.kind == .dash ? "DASH 영상은 재생하며 받습니다. 누르면 지금 자리부터 재생되는 그대로 받습니다."
                          : "표준이 아닌 방식의 영상입니다. 누르면 지금 자리부터 재생되는 그대로 받습니다.")
            } else {
                Button("받기", systemImage: "arrow.down.circle") { downloads.start(media) }
                    .disabled(!media.isDownloadable)
                    .help(media.isDownloadable ? "받기" : media.unsupported.map { "\($0) 영상은 받을 수 없습니다" } ?? "\(media.kind.rawValue) 받기는 아직 준비 중입니다")
            }
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.plain)
        .font(.title3)
        .foregroundStyle(media.isDownloadable || item != nil ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
    }
}

/// 진행 막대 + "12.3 MB / 43.2 MB · 3.1 MB/s" (멈춤·실패·다시 시도 중이면 그 글)
struct WebDownloadProgress: View {
    let item: WebDownloads.Item

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            if let progress = item.progress {
                ProgressView(value: progress)
            } else if item.isActive {
                ProgressView().progressViewStyle(.linear)
            } else {
                // 바뀜 (2026-11-15, 사용자): 크기를 알기 전에 멈추거나 실패하면 왔다 갔다 하는 막대가 계속 움직였다 — 받는 중이 아니면 빈 막대로
                ProgressView(value: 0)
            }
            Text(status)
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(isFailure ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                .lineLimit(1)
                .help(status)
        }
        .controlSize(.small)
    }

    private var isFailure: Bool { if case .failed = item.state { true } else { false } }

    private var status: String {
        let size = { (n: Int64) in ByteCountFormatter.string(fromByteCount: n, countStyle: .file) }
        // HLS·DASH 는 조각 수로, 파일은 받은 양 / 전체
        let amount = item.segmentsTotal > 0
            ? "조각 \(item.segmentsDone)/\(item.segmentsTotal) · \(size(item.received))"
            : item.total.map { "\(size(item.received)) / \(size($0))" } ?? size(item.received)
        switch item.state {
        case .running:
            if let note = item.note { return "\(amount) · \(note)" }
            return item.speed > 0 ? "\(amount) · \(size(Int64(item.speed)))/s" : amount
        case .retrying(let attempt): return "\(amount) · 연결이 끊겨 다시 시도하는 중 (\(attempt)/4)"
        case .stopped: return "\(amount) · 멈춤"
        case .failed(let message): return "\(amount) · \(message)"
        case .done: return "완료 · \(size(item.received))"
        }
    }
}

/// 다운로드 화면의 재생하며 받기 한 줄 (2026-11-08, 사용자): 용량 대신 0초~영상 끝을 막대로 놓고 받은 구간은 파랗게, 빈 구간은 뚫린 채로
private struct CaptureDownloadRow: View {
    let capture: WebCapture

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "record.circle")
                .font(.title2)
                .foregroundStyle(.secondary)
                // 바뀜 (2026-11-10, 사용자): iCloud 줄(MacDownloadRow)과 그림 자리 폭을 같게
                .frame(width: 32)
            VStack(alignment: .leading, spacing: 4) {
                Text(capture.title.isEmpty ? "재생하며 받기" : capture.title)
                    .lineLimit(1)
                    .truncationMode(.middle)
                switch capture.state {
                case .waiting:
                    status("페이지에서 영상을 재생하면 받기 시작합니다")
                case .capturing:
                    if let duration = capture.playback?.duration {
                        CoverageBar(received: Self.received(gaps: capture.gaps, duration: duration), duration: duration)
                            .frame(height: 6)
                    } else {
                        ProgressView().progressViewStyle(.linear).controlSize(.small)
                    }
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        status(capturingText(now: context.date))
                    }
                case .saving:
                    ProgressView().progressViewStyle(.linear).controlSize(.small)
                    status("영상 묶는 중")
                case .saved(let files):
                    // 바뀜 (2026-11-09, 사용자): 빈 구간을 남기고 저장했으면 "완료 (빈 구간 4개)"
                    let holes = capture.savedHoles.isEmpty ? "" : " (빈 구간 \(capture.savedHoles.count)개)"
                    status(files.count == 1 ? "완료\(holes)" : "완료 · \(files.count)개\(holes)")
                case .failed(let message):
                    status(message).foregroundStyle(.red)
                case .off:
                    EmptyView()
                }
            }
            Spacer()
            trailingButton
                .labelStyle(.iconOnly)
                .buttonStyle(.plain)
                .font(.title3)
                .foregroundStyle(.tint)
        }
        .padding(.vertical, 4)
        .contextMenu {
            if capture.isOn {
                Button("여기까지 저장") { capture.stop(save: true) }
                Button("취소", role: .destructive) { capture.stop(save: false) }
            }
        }
    }

    @ViewBuilder
    private var trailingButton: some View {
        switch capture.state {
        case .waiting, .capturing:
            Button("여기까지 저장", systemImage: "stop.circle") { capture.stop(save: true) }
                .help("받은 데까지 저장합니다 (끝까지 재생하면 저절로 저장됩니다)")
        case .saved(let files):
            Button("Finder 에서 보기", systemImage: "magnifyingglass.circle") { NSWorkspace.shared.activateFileViewerSelecting(files) }
                .help("받은 파일을 Finder 에서 보기")
        default:
            EmptyView()
        }
    }

    private func status(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .monospacedDigit()
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .help(text)
    }

    /// "12:30 / 1:16:59 · 빈 구간 2개 · 경과 3:10"
    private func capturingText(now: Date) -> String {
        var parts: [String] = []
        if let playback = capture.playback {
            parts.append("\(playback.time.durationText) / \(playback.duration?.durationText ?? "-")")
        }
        if !capture.holes.isEmpty { parts.append("빈 구간 \(capture.holes.count)개") }
        if let since = capture.receivedSince { parts.append("경과 \(max(0, now.timeIntervalSince(since)).durationText)") }
        return parts.joined(separator: " · ")
    }

    /// 0 ~ 전체 길이에서 빈 구간(아직 안 받은 뒷부분 포함)을 뺀 곳 = 받은 구간
    static func received(gaps: [ClosedRange<Double>], duration: Double) -> [ClosedRange<Double>] {
        var result: [ClosedRange<Double>] = []
        var cursor = 0.0
        for gap in gaps.sorted(by: { $0.lowerBound < $1.lowerBound }) {
            if gap.lowerBound > cursor { result.append(cursor ... min(gap.lowerBound, duration)) }
            cursor = max(cursor, gap.upperBound)
        }
        if cursor < duration { result.append(cursor ... duration) }
        return result
    }
}

/// 0초~끝 막대: 바탕은 빈 곳, 받은 구간만 파랗게
/// 바뀜 (2026-11-08, 사용자): 조각마다 끝을 둥글게 (기본 진행바처럼), 창이 뒤에 있으면 파랑 대신 회색
private struct CoverageBar: View {
    let received: [ClosedRange<Double>]
    let duration: Double
    @Environment(\.controlActiveState) private var activeState

    var body: some View {
        let fill: Color = activeState == .inactive ? .secondary : .accentColor
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
                             with: .color(fill))
            }
        }
        .accessibilityLabel("받은 구간")
    }
}
