import SwiftUI

/// iRayer 정보 (2026-11-23, 사용자: iSQL 처럼). 맥은 메뉴 iRayer > iRayer에 관하여 창, 아이폰·아이패드는 설정 맨 아래.
/// 아이콘·이름·버전 + 둥근 상자 안에 TMDB 출처 표기와 오픈 소스 목록. 라이선스 전문은 앱에 넣은 글 파일(Licenses·Fonts)을 시트로 보여 준다.
/// 같은 내용이 소스의 THIRD_PARTY_NOTICES.md 에도 있다 (하나를 고치면 같이 고친다)
struct AboutView: View {
    static let windowID = "about"

    @State private var license: LicenseText?

    var body: some View {
        VStack(spacing: 0) {
            appIcon
                .resizable()
                .frame(width: 96, height: 96)
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                .padding(.top, 8)
            Text("iRayer").font(.title2.bold()).padding(.top, 10)
            Text(Self.versionText).font(.callout).foregroundStyle(.secondary).padding(.top, 4)
                .textSelection(.enabled)

            VStack(alignment: .leading, spacing: 12) {
                section("영화·TV 정보") {
                    Text("포스터·줄거리 같은 영화·TV 정보는 TMDB 에서 가져옵니다. 이 앱은 TMDB API 를 쓰지만 TMDB 의 보증이나 인증을 받지 않았습니다.")
                    Text("This product uses the TMDB API but is not endorsed or certified by TMDB.")
                        .foregroundStyle(.tertiary)
                    link("themoviedb.org", "https://www.themoviedb.org")
                }
                section("오픈소스") {
                    item("VLCKit · MobileVLCKit (LGPL 2.1)", "영상 재생", "https://code.videolan.org/videolan/VLCKit")
                    #if os(macOS)
                    item("FFmpeg (LGPL 2.1)", "웹에서 받은 영상 조각 묶기", "https://ffmpeg.org")
                    item("Sparkle (MIT)", "자동 업데이트", "https://sparkle-project.org")
                    // 바뀜 (2026-11-25, 사용자: QuickLook Video 흡수): Finder 미리보기 확장
                    item("QuickLook Video (GPL 2.0 이상)", "Finder 미리보기 확장, Jonathan Harris", "https://github.com/Marginal/QuickLookVideo")
                    #endif
                    item("AMSMB2 · libsmb2 (LGPL 2.1)", "SMB 공유 폴더 접속", "https://github.com/amosavian/AMSMB2")
                    item("Unrar.swift (MIT) · UnRAR (UnRAR 라이선스)", "RAR 만화 압축 풀기", "https://github.com/mtgto/Unrar.swift")
                    item("나눔글꼴 · 마루부리 (SIL OFL 1.1)", "자막·텍스트 뷰어 글꼴, 네이버", "https://hangeul.naver.com")
                    Text("LGPL 라이브러리는 앱 안에 따로 된 프레임워크·실행 파일로 들어 있어 바꿔 넣을 수 있고, 소스는 각 주소에서 받을 수 있습니다. iRayer 코드는 MIT 라이선스입니다.")
                        .padding(.top, 2)
                    #if os(macOS)
                    Text("QuickLook Video 의 확장(Contents/Extensions·Library/Spotlight)과 FFmpeg 라이브러리는 공식 배포판을 그대로 넣은 별개 프로그램으로, GPL 을 따르며 소스는 위 주소에서 받을 수 있습니다.")
                    #endif
                }
                section("라이선스 전문") {
                    FlowButtons(texts: LicenseText.all) { license = $0 }
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.05)))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.08)))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .padding(.top, 18)
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 20)
        #if os(macOS)
        .frame(width: 380)
        #endif
        .sheet(item: $license) { LicenseTextView(text: $0) }
    }

    private var appIcon: Image {
        #if os(macOS)
        Image(nsImage: NSApp.applicationIconImage)
        #else
        // 앱 아이콘은 이름으로 바로 못 불러서 Info.plist 의 아이콘 파일 이름으로 찾는다
        let icons = Bundle.main.infoDictionary?["CFBundleIcons"] as? [String: Any]
        let primary = icons?["CFBundlePrimaryIcon"] as? [String: Any]
        let name = (primary?["CFBundleIconFiles"] as? [String])?.last ?? "AppIcon"
        return Image(uiImage: UIImage(named: name) ?? UIImage())
        #endif
    }

    /// "버전 2.3 (빌드 433 · 58d077b)" — 설정 맨 아래와 같은 모양
    static var versionText: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = (info["CFBundleShortVersionString"] as? String ?? "-") + (info["IRayerBeta"] as? Bool == true ? "b" : "")
        let build = info["CFBundleVersion"] as? String ?? "-"
        let commit = info["IRayerCommit"] as? String
        return "버전 \(version) (빌드 \(build)\(commit.map { " · \($0)" } ?? ""))"
    }

    private func section<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).fontWeight(.semibold).foregroundStyle(.primary.opacity(0.75))
            content()
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func item(_ name: String, _ what: String, _ url: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("·")
            if let url = URL(string: url) {
                Link(destination: url) { Text(name) + Text(" — " + what).foregroundStyle(.tertiary) }
                    .buttonStyle(.plain)
            }
        }
    }

    private func link(_ title: String, _ url: String) -> some View {
        Link(title, destination: URL(string: url)!)
    }
}

/// 앱에 넣은 라이선스 글 파일 하나
struct LicenseText: Identifiable {
    let title: String
    let file: String
    var id: String { file }

    static let all: [LicenseText] = {
        var texts: [LicenseText] = [.init(title: "LGPL 2.1", file: "LGPL-2.1")]
        #if os(macOS)
        texts.append(.init(title: "Sparkle (MIT)", file: "Sparkle-MIT"))
        texts.append(.init(title: "GPL 2.0", file: "GPL-2.0"))
        #endif
        return texts + rest
    }()

    private static let rest: [LicenseText] = [
        .init(title: "UnRAR", file: "UnRAR-License"),
        .init(title: "Unrar.swift (MIT)", file: "Unrar.swift-MIT"),
        .init(title: "나눔글꼴 (OFL)", file: "Nanum-OFL"),
        .init(title: "마루부리 (OFL)", file: "MaruBuri-OFL"),
    ]

    var body: String {
        guard let url = Bundle.main.url(forResource: file, withExtension: "txt"),
              let data = try? Data(contentsOf: url) else { return "(파일을 찾지 못했습니다: \(file).txt)" }
        // 글꼴 라이선스 파일 중에는 UTF-8 이 아닌 것도 있을 수 있다
        return String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
    }
}

/// 라이선스 단추들 (상자 폭에 맞춰 줄을 바꾼다)
private struct FlowButtons: View {
    let texts: [LicenseText]
    let open: (LicenseText) -> Void

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 6) { buttons }
            VStack(alignment: .leading, spacing: 6) { buttons }
        }
    }

    @ViewBuilder private var buttons: some View {
        ForEach(texts) { text in
            Button(text.title) { open(text) }
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
    }
}

/// 라이선스 전문 보기 (시트)
private struct LicenseTextView: View {
    let text: LicenseText
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                Text(text.body)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            }
            .navigationTitle(text.title)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("닫기") { dismiss() } }
            }
        }
        #if os(macOS)
        .frame(width: 560, height: 520)
        #endif
    }
}
