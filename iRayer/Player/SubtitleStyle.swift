import SwiftUI

/// 자막 글꼴. 시스템 글꼴 + 앱에 넣은 나눔글꼴(일반 굵기, SIL OFL 1.1 — Fonts/Nanum-OFL.txt).
/// rawValue 는 글꼴의 PostScript 이름 (VLC 가 그리는 자막에는 같은 이름을 글꼴 패밀리로 넘긴다).
enum SubtitleFont: String, CaseIterable, Identifiable {
    case system
    case nanumGothic = "NanumGothicOTF"
    case nanumBarunGothic = "NanumBarunGothicOTF"
    case nanumMyeongjo = "NanumMyeongjoOTF"
    case nanumBarunpen = "NanumBarunpen"
    /// 바뀜 (2026-11-08, 사용자): 마루부리 (네이버, SIL OFL 1.1 — 텍스트 뷰어로 글 읽기에 좋다). PostScript 이름과 패밀리 이름이 달라 VLC 에는 vlcFamily
    case maruBuri = "MaruBuriot-Regular"

    var id: String { rawValue }

    var name: String {
        switch self {
        case .system: "시스템 기본"
        case .nanumGothic: "나눔고딕"
        case .nanumBarunGothic: "나눔바른고딕"
        case .nanumMyeongjo: "나눔명조"
        case .nanumBarunpen: "나눔바른펜"
        case .maruBuri: "마루부리"
        }
    }

    /// VLC(freetype-font)에 넘길 글꼴 패밀리 이름
    var vlcFamily: String {
        self == .maruBuri ? "MaruBuriOTF" : rawValue
    }

    /// 시스템 글꼴은 잘 읽히도록 약간 굵게, 나눔글꼴은 일반 굵기만 넣었으므로 그대로
    func font(size: CGFloat) -> Font {
        self == .system ? .system(size: size, weight: .semibold) : .custom(rawValue, fixedSize: size)
    }
}

/// 자막 글자 가장자리 모양
enum SubtitleEdge: String, CaseIterable, Identifiable {
    /// 사방 테두리 + 옅은 그림자 (기본)
    case outlineShadow
    /// 테두리만
    case outline
    /// 테두리 없이 오른쪽 아래로 떨어지는 그림자만
    case dropShadow

    var id: String { rawValue }

    var name: String {
        switch self {
        case .outlineShadow: "외곽선 + 그림자"
        case .outline: "외곽선"
        case .dropShadow: "그림자 (오른쪽 아래)"
        }
    }
}

/// 자막 글자 한 덩어리: 흰 글자 + 가장자리(설정). 플레이어·TV·설정 미리보기가 같이 쓴다.
struct SubtitleText: View {
    let text: String
    /// 기준 크기 (자막 크기 설정을 곱하기 전)
    let baseSize: CGFloat

    @State private var settings = AppSettings.shared

    @ViewBuilder
    var body: some View {
        let size = baseSize * settings.subtitleScale
        let text = Text(text)
            .font(settings.subtitleFont.font(size: size))
            .foregroundStyle(.white)
            .multilineTextAlignment(.center)
        switch settings.subtitleEdge {
        case .outlineShadow:
            outlined(text).shadow(color: .black.opacity(0.6), radius: 3)
        case .outline:
            outlined(text)
        case .dropShadow:
            // 글자 크기에 맞춰 오른쪽 아래로 떨어지는 그림자 (살짝 번진 것과 또렷한 것을 겹친다)
            let offset = max(size * 0.07, 1.5)
            text
                .shadow(color: .black.opacity(0.9), radius: 0, x: offset, y: offset)
                .shadow(color: .black.opacity(0.5), radius: offset, x: offset, y: offset)
        }
    }

    /// 테두리 대신 사방으로 그림자를 겹쳐 밝은 화면에서도 읽히게 한다
    private func outlined(_ text: some View) -> some View {
        text
            .shadow(color: .black, radius: 0, x: 1, y: 1)
            .shadow(color: .black, radius: 0, x: -1, y: -1)
            .shadow(color: .black, radius: 0, x: 1, y: -1)
            .shadow(color: .black, radius: 0, x: -1, y: 1)
    }

    /// 화면 크기에 따른 기준 크기: 가로 화면이 기준(짧은 변의 5.5%), 세로 화면은 영상이 작게 보이므로 70%
    static func baseSize(for size: CGSize) -> CGFloat {
        let isPortrait = size.height > size.width
        return min(size.width, size.height) * 0.055 * (isPortrait ? 0.7 : 1)
    }

    /// 작은 플레이어(앱 안 PiP)용: 위 식이면 너무 작아 읽을 수 없어서 PiP 높이에 맞춰 키우고, 최소 10pt
    static func compactBaseSize(for size: CGSize) -> CGFloat {
        max(size.height * 0.09, 10)
    }
}
