import SwiftUI

/// 이미지뷰어(만화책) 설정 패널 (2026-11-08, 사용자): 예전의 설정 메뉴 대신 폴더 설정처럼 패널로.
/// 위는 이 책에만(읽는 방향·반 자르기, iCloud 로 다른 기기에도), 아래는 모든 책 공통(자동 넘김 간격, 이 기기 — 앱 설정과 같은 값).
/// 아이폰·아이패드는 반만 올라오는 시트, 맥은 보기 창 오른쪽에 겹쳐 뜨는 패널에 넣는다.
struct ComicSettingsForm: View {
    let settings: ComicSettings
    let set: (WritableKeyPath<ComicSettings, Bool>, Bool) -> Void
    /// 가로로 넓은 화면에서 펼쳐 보이는 것에 대한 안내 (아이폰·아이패드: 가로 화면, 맥: 넓은 창)
    var spreadNote = "가로 화면에서는 두 쪽을 펼쳐 보여줍니다."
    @Bindable private var app = AppSettings.shared

    var body: some View {
        Form {
            Section {
                Picker("읽는 방향", selection: Binding(get: { settings.rightToLeft }, set: { set(\.rightToLeft, $0) })) {
                    Text("왼쪽으로").tag(true)
                    Text("오른쪽으로").tag(false)
                }
                Toggle(isOn: Binding(get: { settings.split }, set: { set(\.split, $0) })) {
                    Label("반으로 자르기", systemImage: "rectangle.split.2x1")
                }
                if settings.split {
                    Toggle(isOn: Binding(get: { settings.swapHalves }, set: { set(\.swapHalves, $0) })) {
                        Label("반쪽 순서 바꾸기", systemImage: "arrow.left.arrow.right")
                    }
                }
            } header: {
                FormHeader("이 책", isFirst: true)
            } footer: {
                footer(spreadNote)
            }
            Section {
                Picker("자동 넘김 간격", selection: $app.comicAutoSeconds) {
                    ForEach(AppSettings.comicAutoChoices, id: \.self) { Text("\($0)초").tag($0) }
                }
            } header: {
                FormHeader("모든 책")
            } footer: {
                footer(Self.autoNote)
            }
        }
        .formStyle(.grouped)
    }

    /// 바뀜 (2026-11-08): 맥 풍선(popover) 안에서는 머리·꼬리 글이 본문과 같은 크기·밝기로 나와 위계가 없었다 (사용자) →
    ///   꼬리 글은 작고 흐리게, 머리 글은 맥에서 굵게 (아이폰 시트는 원래 모양이 같아 그대로)
    /// 바뀜 (2026-11-08): 머리 글은 FormHeader (묶음 사이 여백도, 재생 설정과 같이)
    private func footer(_ text: String) -> some View {
        Text(text)
            .font(.footnote)
            .foregroundStyle(.secondary)
    }

    /// 자동 넘김 안내 (맥은 누르고 있기 대신 조작이 보이는 동안 멈춘다)
    private static var autoNote: String {
        #if os(macOS)
        "아래 막대의 ▶ 로 켜고 끕니다. 조작이 보이는 동안은 멈추고, 직접 넘기면 다시 셉니다."
        #else
        "아래 막대의 ▶ 로 켜고 끕니다. 화면을 누르고 있는 동안은 멈추고, 직접 넘기면 다시 셉니다."
        #endif
    }
}
