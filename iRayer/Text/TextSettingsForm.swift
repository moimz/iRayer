import SwiftUI

/// 텍스트 보기 설정 (기기마다, AppSettings): 글꼴·크기·줄 간격·좌우 여백·배경 테마.
/// 앱 설정과 보기 화면의 설정 패널이 같이 쓴다 (보면서 맞추기)
struct TextStyleSection: View {
    var isFirst = false
    @Bindable private var settings = AppSettings.shared

    var body: some View {
        Section {
            // 바뀜 (2026-11-08, 사용자): 앱 화면 모드와 따로 밝게·어둡게
            Picker("밝기", selection: $settings.textAppearance) {
                ForEach(TextAppearance.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            ThemePicker(selection: $settings.textTheme)
            Picker("글꼴", selection: $settings.textFont) {
                ForEach(SubtitleFont.allCases) { Text($0.name).tag($0) }
            }
            Stepper(value: $settings.textSize, in: AppSettings.textSizeRange, step: 1) {
                LabeledContent("글자 크기", value: "\(Int(settings.textSize))")
            }
            Stepper(value: $settings.textLineSpacing, in: AppSettings.textLineSpacingRange, step: 0.1) {
                LabeledContent("줄 간격", value: settings.textLineSpacing.formatted(.number.precision(.fractionLength(1))))
            }
            Stepper(value: $settings.textMargin, in: AppSettings.textMarginRange, step: 4) {
                LabeledContent("좌우 여백", value: "\(Int(settings.textMargin))")
            }
        } header: {
            FormHeader("보기", isFirst: isFirst)
        } footer: {
            Text("이 기기의 모든 텍스트 파일에 씁니다.")
        }
    }
}

/// 배경 테마 고르기: 테마 색 동그라미에 "가" (애플 도서 앱처럼)
struct ThemePicker: View {
    @Binding var selection: ReadingTheme
    @Environment(\.colorScheme) private var colorScheme
    @State private var settings = AppSettings.shared

    var body: some View {
        HStack(spacing: 0) {
            ForEach(ReadingTheme.allCases) { theme in
                let colors = theme.colors(dark: settings.textAppearance.isDark(colorScheme))
                Button {
                    selection = theme
                } label: {
                    VStack(spacing: 4) {
                        Text("가")
                            .font(.system(size: 17, weight: theme.isBold ? .bold : .regular))
                            .foregroundStyle(colors.text)
                            .frame(width: 40, height: 40)
                            .background(colors.background, in: .circle)
                            .overlay {
                                Circle().strokeBorder(selection == theme ? Color.accentColor : Color.secondary.opacity(0.3),
                                                      lineWidth: selection == theme ? 2.5 : 1)
                            }
                        Text(theme.title)
                            .font(.caption2)
                            .foregroundStyle(selection == theme ? .primary : .secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(theme.title)
                .accessibilityAddTraits(selection == theme ? .isSelected : [])
            }
        }
        .padding(.vertical, 4)
    }
}

/// 보기 화면의 설정 패널: 이 파일(인코딩, iCloud) + 보기(이 기기)
struct TextSettingsForm: View {
    let model: TextReaderModel

    var body: some View {
        Form {
            Section {
                Picker("인코딩", selection: Binding(get: { model.chosenEncoding }, set: { model.setEncoding($0) })) {
                    ForEach(TextEncoding.allCases) { encoding in
                        Text(encoding == .auto ? "자동 (\(model.book.encoding.title))" : encoding.title).tag(encoding)
                    }
                }
            } header: {
                FormHeader("이 파일", isFirst: true)
            } footer: {
                Text("글자가 깨져 보이면 인코딩을 바꿔 보세요.")
            }
            TextStyleSection()
        }
        .formStyle(.grouped)
    }
}
