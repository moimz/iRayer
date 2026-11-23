import Foundation
import Observation

/// 텍스트 읽기 상태 (아이폰·아이패드·맥 같이): 읽은 위치(글자), 인코딩 바꾸기, 저장
@Observable
final class TextReaderModel {
    private(set) var book: TextBook
    /// 이 파일에 고른 인코딩 (자동이면 .auto)
    private(set) var chosenEncoding: TextEncoding
    var showsControls = false
    /// 화면 맨 위 글자의 위치 비율 (0~1, 아래 막대·% 표시)
    private(set) var fraction: Double = 0
    /// 글이 바뀐 횟수 (인코딩을 바꾸면 늘어 보기 화면이 글을 다시 넣는다)
    private(set) var revision = 0
    /// 전체 글자 수 (UTF-16, TextKit 위치와 같은 단위)
    private(set) var length: Int

    /// 화면 맨 위 줄의 첫 글자 위치
    @ObservationIgnored private(set) var topOffset: Int
    /// 보기 화면이 넣어 둔다: 그 글자가 맨 위에 오게 옮기기
    @ObservationIgnored var scrollTo: ((Int) -> Void)?

    init(book: TextBook) {
        self.book = book
        chosenEncoding = TextSettingsStore.shared.settings(for: book.file).encoding
        let length = (book.text as NSString).length
        self.length = length
        let state = PlaybackStateStore.shared.state(for: book.file.stateKey)
        // 다 읽은 파일은 처음부터
        let saved = Int(state.position)
        let top = saved > 0 && saved < length - 1 ? saved : 0
        topOffset = top
        fraction = Double(top) / Double(max(length, 1))
    }

    /// 보기 화면이 스크롤할 때마다 알려 준다
    func updateTop(_ offset: Int, atEnd: Bool = false) {
        topOffset = atEnd ? length : min(max(offset, 0), length)
        let value = Double(topOffset) / Double(max(length, 1))
        if abs(value - fraction) > 0.0005 { fraction = value }
    }

    /// 아래 막대로 옮기기
    func jump(toFraction value: Double) {
        let offset = Int(Double(length) * min(max(value, 0), 1))
        scrollTo?(min(offset, max(length - 1, 0)))
    }

    /// 위치 = 맨 위 글자, 길이 = 전체 글자 수 (폴더 카드 진행 막대·iCloud)
    func saveProgress() {
        let position = Double(topOffset), duration = Double(length)
        PlaybackStateStore.shared.update(book.file.stateKey) {
            $0.position = position
            $0.duration = duration
        }
        // 홈의 이어 보기 (끝까지 읽으면 다 읽음)
        WatchHistory.shared.record(book.file, finished: topOffset >= length)
    }

    /// 인코딩 바꾸기: 파일에 기억하고 다시 푼다. 위치는 비율로 이어 간다 (인코딩이 바뀌면 글자 위치가 달라진다)
    func setEncoding(_ choice: TextEncoding) {
        guard choice != chosenEncoding else { return }
        chosenEncoding = choice
        var settings = TextSettingsStore.shared.settings(for: book.file)
        settings.encoding = choice
        TextSettingsStore.shared.save(settings, for: book.file)
        guard let decoded = TextEncoding.decode(book.data, as: choice) else { return }
        let keep = fraction
        book.text = decoded.text
        book.encoding = decoded.used
        length = (decoded.text as NSString).length
        topOffset = Int(Double(length) * keep)
        revision += 1
    }
}
