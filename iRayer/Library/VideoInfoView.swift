import SwiftUI

/// 영상을 고르면 바로 재생하지 않고 먼저 보여주는 정보 화면 (일반 파일: 기본 정보만)
struct VideoInfoView: View {
    let file: VideoFile

    @State private var header: UIImage?
    @State private var player = PlayerHost.shared
    @State private var frames = ResumeFrames.shared

    /// 이어보기 위치 (재생을 닫으면 바로 바뀐다)
    private var state: VideoPlaybackState {
        PlaybackStateStore.shared.state(for: file.stateKey)
    }

    /// 이 영상을 지금 재생하고 있는지 (작은 플레이어로 재생 중에도 이 화면을 볼 수 있다)
    private var isPlayingThis: Bool {
        player.isOpen(file)
    }

    var body: some View {
        DetailPage {
            player.play(file, resume: true)
        } artwork: {
            if let header {
                Image(uiImage: header).resizable().scaledToFill()
            }
        } content: {
            Text(file.title)
                .font(.title2.bold())

            // 바뀜 (2026-11-11): 다 본 것으로 = 이어보기 위치를 지우고 다 본 기록 (라이브러리 영화와 같게)
            ResumeControls(state: state, watched: PlaybackStateStore.shared.isWatched(file.stateKey)) {
                player.play(file, resume: true)
            } restart: {
                player.play(file, resume: false)
            } markWatched: {
                LibraryData.markWatched(file)
            } unwatch: {
                file.clearPlaybackRecord()
            }

            VStack(spacing: 0) {
                InfoRow(label: "파일명", value: file.name)
                Divider()
                InfoRow(label: "재생 시간", value: ThumbnailService.shared.duration(for: file)?.durationText ?? "-")
                Divider()
                InfoRow(label: "파일 크기", value: file.size.fileSizeText)
                Divider()
                InfoRow(label: "수정한 날짜", value: file.modifiedAt.formatted(date: .abbreviated, time: .shortened))
            }
            .background(.background.secondary, in: .rect(cornerRadius: 12))
        }
        .inlineNavigationTitle()
        .onDisappear { ReturnHighlight.shared.returned(from: file) }
        // 이어보기 위치가 바뀌거나 닫을 때 찍은 장면이 준비되면 그림을 다시 고른다
        .task(id: "\(state.position)|\(frames.pending.contains(file.stateKey))|\(isPlayingThis)") {
            await loadHeader()
        }
    }

    /// 마지막 재생 위치의 장면, 재생 기록이 없으면 목록 썸네일
    private func loadHeader() async {
        // 재생하는 동안에는 그대로 두고, 닫을 때 찍는 장면을 기다린다
        if isPlayingThis, header != nil { return }
        if frames.pending.contains(file.stateKey) { return }
        if state.position > 0, state.duration > 0 {
            if let image = frames.image(for: file.stateKey, position: state.position) {
                header = image
                return
            }
            let position = Float(state.position / state.duration)
            if let image = await ThumbnailService.shared.snapshot(of: file, at: position) {
                // 기다리는 사이 위치가 바뀌었으면(다시 고르는 중) 덮어쓰지 않는다
                guard !Task.isCancelled else { return }
                header = image
                return
            }
        }
        let thumbnail = await ThumbnailService.shared.thumbnail(for: file)
        guard !Task.isCancelled else { return }
        header = thumbnail
    }
}

/// 재생 기록이 있을 때 정보 화면에 보이는 진행 막대와 버튼: [▶ 1:03:31부터] [↺ 처음부터] [✓ 다 본 것으로]
/// 아이콘만 있는 버튼은 길게 누르면 이름이 보인다.
/// 바뀜 (2026-11-11, 사용자): 다 본 영상은 [▶ 처음부터 다시 보기] [↺ 다 본 표시 지우기] (다 본 영상은 재생 기록을 남기지 않으므로 진행 막대 없음)
struct ResumeControls: View {
    let state: VideoPlaybackState
    var watched = false
    let resume: () -> Void
    let restart: () -> Void
    let markWatched: () -> Void
    var unwatch: () -> Void = {}

    var body: some View {
        if watched {
            HStack {
                Button("처음부터 다시 보기", systemImage: "play.fill", action: restart)
                    .buttonStyle(.glassProminent)
                iconButton("다 본 표시 지우기", systemImage: "arrow.counterclockwise", action: unwatch)
            }
            .controlSize(.large)
        } else if state.position > 0, state.duration > 0 {
            VStack(alignment: .leading, spacing: 8) {
                ProgressBar(fraction: state.position / state.duration)
                    .clipShape(.capsule)
                HStack {
                    Button("\(state.position.durationText)부터", systemImage: "play.fill", action: resume)
                        .buttonStyle(.glassProminent)
                    iconButton("처음부터", systemImage: "arrow.counterclockwise", action: restart)
                    iconButton("다 본 것으로 표시", systemImage: "checkmark", action: markWatched)
                }
                // 다른 버튼과 같은 보통 높이 (유리 버튼)
                .controlSize(.large)
            }
        }
    }

    private func iconButton(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .labelStyle(.iconOnly)
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.circle)
        .contextMenu {
            Button(title, systemImage: systemImage, action: action)
        }
    }
}

extension VideoFile {
    /// 재생(읽기) 기록을 지운다: 이어보기 위치를 없애고 홈 이어보기에서도 뺀다
    /// 바뀜 (2026-11-11): 다 본 표시(영구)도 지운다
    func clearPlaybackRecord() {
        PlaybackStateStore.shared.update(stateKey) {
            $0.position = 0
            $0.watchedAt = nil
        }
        WatchHistory.shared.remove(stateKey)
    }
}

/// 영상 정보 화면의 틀 (Infuse 처럼): 맨 위 그림이 화면 폭을 꽉 채우고 상태 표시줄·제목 줄 뒤까지 올라간다.
/// 그림 높이는 세로 화면에서 폭의 80%(화면 높이의 절반까지), 가로 화면에서는 화면 높이 전체 — 가운데 재생 버튼이 화면 가운데 온다.
/// 가로형 그림(배경 이미지·영상 장면)을 칸에 맞춰 채우고 넘치는 부분은 자른다. 아래 내용은 노치(안전 영역)만큼 들여 쓴다.
struct DetailPage<Artwork: View, Content: View>: View {
    var playEnabled = true
    let onPlay: () -> Void
    @ViewBuilder let artwork: Artwork
    @ViewBuilder let content: Content
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var pagePosition = ScrollPosition()

    /// 그림 높이. 아이패드처럼 넓은 화면은 16:9 (화면 높이의 60%까지) — 가로 화면에서 그림이 화면을 다 차지해 글이 안 보이지 않게.
    private func artworkHeight(width: CGFloat, height: CGFloat) -> CGFloat {
        if sizeClass == .regular { return min(width * 9 / 16, height * 0.6) }
        return width > height ? height : min(width * 0.8, height * 0.5)
    }

    var body: some View {
        GeometryReader { geometry in
            // 사이드바(맥·아이패드)·가로 화면 노치 아래로 그림을 넓히지 않는다 (가장자리 비추기로 채움): 좌우 안전 영역은 쓰지 않는다.
            // 사이드바를 숨기면 안전 영역이 없어져 그림이 화면 폭을 꽉 채운다 (HIG: Apple TV·음악 앱처럼)
            let width = geometry.size.width
            let height = geometry.size.height + geometry.safeAreaInsets.top + geometry.safeAreaInsets.bottom
            // 안쪽 뷰가 이 화면의 세로 스크롤을 옮길 수 있게 (회차 찾기, 2026-11-07)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Button(action: onPlay) {
                        Color.clear
                            // 그림이 가로로 긴(16:9 안팎) 것들이라 세로 화면에서 너무 높으면 좌우가 많이 잘린다
                            .frame(width: width, height: artworkHeight(width: width, height: height))
                            .background(.quaternary)
                            .overlay { artwork }
                            // 그림은 내용 영역에 두고, 사이드바 유리 아래는 그림 가장자리를 비춰 채운다 (Apple TV 앱처럼)
                            .backgroundExtensionEffect()
                            // 아래 내용과 자연스럽게 이어지도록 배경색으로 흐려지게
                            .overlay(alignment: .bottom) {
                                LinearGradient(colors: [.clear, Color.screenBackground], startPoint: .top, endPoint: .bottom)
                                    .frame(height: 80)
                            }
                            .overlay {
                                Image(systemName: "play.circle.fill")
                                    .font(.system(size: 64))
                                    .symbolRenderingMode(.palette)
                                    .foregroundStyle(.white, .black.opacity(0.4))
                            }
                            .clipped()
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .disabled(!playEnabled)

                    VStack(alignment: .leading, spacing: 16) {
                        content
                    }
                    // 사이드바·노치는 안전 영역이 비켜 주므로 여백은 양쪽 16 만
                    .frame(maxWidth: .infinity, alignment: .leading)
                    // 가로로 넘기는 줄이 이 여백을 넘어 화면 끝까지 가도록 알려 준다 (BleedingRow)
                    .environment(\.pageMargins, EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
                    .padding(.horizontal, 16)
                    .padding(.bottom, 16)
                }
                .coordinateSpace(.named(PageScroll.space))
            }
            .scrollPosition($pagePosition)
            .ignoresSafeArea(edges: .top)
            #if os(iOS)
            // 키보드가 올라와도 iOS 가 알아서 줄이거나 넘기지 않게 (회차 찾기 칸은 우리가 올린다, 둘이 같이 움직여 덜컥거렸다)
            .ignoresSafeArea(.keyboard)
            #endif
            .environment(\.pageScroll, PageScroll(topInset: geometry.safeAreaInsets.top) { offset in
                withAnimation(.easeOut(duration: 0.25)) { pagePosition.scrollTo(y: offset) }
            })
        }
        #if os(iOS)
        // 제목은 그림 아래 내용에 크게 있으니 제목 막대에는 띄우지 않는다 (그림 위에 큰 제목이 겹쳤다).
        // 화면 이름(navigationTitle)은 그대로 두어 뒤로 가기 기록에는 남는다.
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) { Color.clear.frame(width: 1, height: 1) }
        }
        #endif
    }
}

private struct InfoRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .top) {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: 90, alignment: .leading)
            Text(value)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        }
        .font(.subheadline)
        .padding(.horizontal)
        .padding(.vertical, 10)
    }
}
