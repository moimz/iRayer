import SwiftUI

/// 다 보면 이어서 재생할 영상들: 시리즈 회차(시즌 순, 스페셜 빼고)와 재생목록.
/// 그 밖의 재생(폴더·홈의 영화 등)은 대기열이 없어 끝나면 멈춘다.
struct PlayQueue {
    enum Kind { case series, list }

    let kind: Kind
    let files: [VideoFile]
    private(set) var index: Int

    var current: VideoFile { files[index] }
    var next: VideoFile? { files.indices.contains(index + 1) ? files[index + 1] : nil }
    var previous: VideoFile? { files.indices.contains(index - 1) ? files[index - 1] : nil }

    /// 이 대기열 안의 다른 영상으로 옮긴 대기열 (없는 영상이면 nil)
    func moved(to file: VideoFile) -> PlayQueue? {
        guard let found = files.firstIndex(where: { $0.stateKey == file.stateKey }) else { return nil }
        var queue = self
        queue.index = found
        return queue
    }

    /// 재생목록: 보이는 순서대로 (한 개뿐이어도 재생목록으로 본다 — 시리즈 회차여도 다음 회차로 넘어가지 않게)
    static func list(_ files: [VideoFile], startingAt index: Int) -> PlayQueue? {
        guard files.indices.contains(index) else { return nil }
        return PlayQueue(kind: .list, files: files, index: index)
    }

    /// 시리즈 회차면 같은 작품의 회차들 (같은 라이브러리, 시즌 → 회차 순, 스페셜(시즌 0) 빼고).
    /// 어디서 틀었든(작품 화면·홈 이어보기·폴더) 라이브러리에 든 회차면 다음 회차로 이어진다.
    static func series(for file: VideoFile) -> PlayQueue? {
        guard file.hash != nil, let found = LibraryData.file(forKey: file.stateKey), let itemKey = found.file.itemKey,
              found.file.episode != nil, found.file.season != 0,
              let item = LibraryData.item(itemKey), item.isSeries else { return nil }
        let ordered = LibraryData.files(ofItem: itemKey, in: found.library.id)
            .filter { $0.episode != nil && $0.season != 0 }
            .sorted(by: LibraryData.episodeOrder)
        guard ordered.count > 1, let index = ordered.firstIndex(where: { $0.path == found.file.path }) else { return nil }
        var files = ordered.map { LibraryData.videoFile($0, in: found.library, title: LibraryData.playTitle(item, $0)) }
        // 지금 영상은 부른 쪽이 넘긴 그대로 (자막 등 찾아 둔 것이 있을 수 있다)
        files[index] = file
        return PlayQueue(kind: .series, files: files, index: index)
    }
}

/// 다음 화 버튼 (넷플릭스처럼 오른쪽 아래에 하나만). 끝나기 조금 전(엔딩 크레딧)부터 떠서 누르면 바로 넘어가고,
/// 떠 있는 내내 버튼이 차오르다가 영상이 끝나고 몇 초 뒤 다 차면 저절로 넘어간다 (멀리서 봐도 넘어갈 것을 알 수 있게).
/// 차오르는 것은 재생 시간을 따른다 (일시 정지하면 멈춘다). 취소 단추는 없다 (안 볼 거면 플레이어를 닫는다).
struct NextUpButton: View {
    let kind: PlayQueue.Kind
    let time: Double
    let duration: Double
    /// 영상이 끝났다 (남은 몇 초를 마저 채운다)
    let ended: Bool
    let onPlay: () -> Void

    /// 끝나기 몇 초 전부터 띄울지: 엔딩 크레딧을 1분쯤으로 본다. 짧은 영상은 길이의 10% 까지만
    /// 바뀜 (2026-11-07): 60초 대신 설정값(동기화, 기본 60초). 10% 상한은 그대로
    static func window(duration: Double) -> Double {
        min(Double(SyncedSettings.shared.nextEpisodeLead), duration * 0.1)
    }

    static func shows(duration: Double, time: Double) -> Bool {
        duration > 0 && duration - time <= window(duration: duration)
    }

    /// 끝난 뒤 넘어가기까지
    static let delay = 3.0
    @State private var fill: CGFloat = 0

    /// 끝나기 전: 버튼이 뜬 뒤 지난 재생 시간만큼 (전체 = 띄우는 시간 + 끝난 뒤 기다림)
    private var playedFill: CGFloat {
        let window = Self.window(duration: duration)
        let played = time - (duration - window)
        return CGFloat(min(max(played / (window + Self.delay), 0), 1))
    }

    var body: some View {
        Button(action: onPlay) {
            Label(kind == .series ? "다음 화" : "다음 영상", systemImage: "play.fill")
                .labelStyle(.titleAndIcon)
                .font(.headline)
                .foregroundStyle(.black)
                .padding(.horizontal, 22)
                .padding(.vertical, 12)
                .background {
                    // 흰 버튼 위로 옅은 회색이 왼쪽부터 차오른다 (넘어가기까지 남은 시간)
                    GeometryReader { geometry in
                        Color.white
                            .overlay(alignment: .leading) {
                                Color.black.opacity(0.18).frame(width: geometry.size.width * fill)
                            }
                    }
                }
                .clipShape(.rect(cornerRadius: 8))
                .contentShape(.rect(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .shadow(color: .black.opacity(0.3), radius: 8, y: 2)
        .onAppear { fill = playedFill }
        .onChange(of: time) {
            guard !ended else { return }
            // 재생 시간은 0.2초쯤마다 바뀌므로 그 사이를 부드럽게
            withAnimation(.linear(duration: 0.25)) { fill = playedFill }
        }
        .task(id: ended) {
            guard ended else { return }
            // 끝난 뒤 남은 부분을 기다리는 시간 동안 마저 채운다
            // (버튼 전체 = 띄우는 시간 + 기다림 이므로 남은 비율 × 전체 시간, 길어도 기다림만큼)
            let remaining = min(max(Double(1 - fill) * (Self.window(duration: duration) + Self.delay), 0.3), Self.delay)
            withAnimation(.linear(duration: remaining)) { fill = 1 }
            try? await Task.sleep(for: .seconds(remaining))
            if !Task.isCancelled { onPlay() }
        }
    }
}
