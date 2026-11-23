import SwiftUI

/// 재생 화면의 `…` 메뉴: 자막 선택·불러오기, 자막/오디오 싱크, 오디오 트랙, 배속
struct PlayerMenuView: View {
    @Bindable var model: PlayerModel
    @State private var showSubtitlePicker = false
    @Environment(\.dismiss) private var dismiss

    private let rates: [Float] = [0.5, 0.75, 1, 1.25, 1.5, 2]

    var body: some View {
        #if os(macOS)
        // 맥은 재생 창 팝오버: 제목 줄 없이 시스템 설정 같은 묶음 상자로
        // (기본 폼은 이름 칸·값 칸 두 열이라 좁은 팝오버에서 이름이 잘리고 줄이 어긋났다)
        form
            .formStyle(.grouped)
        #else
        NavigationStack {
            form
                .navigationTitle("재생 설정")
                .inlineNavigationTitle()
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("완료") { dismiss() }
                    }
                }
        }
        #endif
    }

    private var form: some View {
        Form {
            // 바뀜 (2026-11-08, 사용자): 맥에서 묶음 사이 여백·굵은 제목 (FormHeader)
            Section {
                Picker("자막", selection: Binding(
                    get: { model.selectedSubtitle },
                    set: { model.selectSubtitle($0) }
                )) {
                    ForEach(model.subtitleOptions) { option in
                        Text(option.name).tag(option.choice)
                    }
                }
                Button("자막 불러오기…", systemImage: "doc.badge.plus") {
                    showSubtitlePicker = true
                }
                DelayRow(title: "자막 싱크", milliseconds: $model.subtitleDelay)
            } header: {
                FormHeader("자막", isFirst: true)
            }

            Section {
                Picker("오디오 트랙", selection: Binding(
                    get: { model.selectedAudioID },
                    set: { model.selectAudio($0) }
                )) {
                    ForEach(model.audioTracks) { track in
                        Text(track.name).tag(track.id)
                    }
                }
                DelayRow(title: "오디오 싱크", milliseconds: $model.audioDelay)
            } header: {
                FormHeader("오디오")
            }

            // 분할 단추가 이미 틀이라 목록 상자 없이 놓는다
            #if os(macOS)
            // 맥 묶음 폼은 줄 배경을 못 지워서 제목 자리에 둔다 (줄 없는 묶음은 상자를 그리지 않는다)
            Section {
            } header: {
                VStack(alignment: .leading, spacing: 8) {
                    FormHeader("재생 속도")
                    // 제목 자리는 상자 안 글자만큼 들여 있어서 양옆으로 넓힌다 (상자 끝보다 조금 안쪽까지).
                    // SwiftUI 분할 Picker 는 맥에서 제 폭을 고집해 늘지 않아 칸을 고르게 채우는 AppKit 분할 단추로
                    FillSegmentedPicker(options: rates.map { ($0.formatted() + "x", $0) }, selection: $model.rate, controlSize: .regular)
                        .padding(.horizontal, -4)
                }
            }
            #else
            Section("재생 속도") {
                ratePicker
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
            }
            #endif

            if model.videoSize != .zero {
                Section {
                    LabeledContent("해상도", value: "\(Int(model.videoSize.width)) × \(Int(model.videoSize.height))")
                    LabeledContent("하드웨어 디코딩", value: AppSettings.shared.hardwareDecoding ? "사용" : "끔")
                } header: {
                    FormHeader("정보")
                }
            }
        }
        .fileImporter(isPresented: $showSubtitlePicker, allowedContentTypes: [.item]) { result in
            if case .success(let url) = result {
                model.loadSubtitle(from: url)
            }
        }
    }
}

extension PlayerMenuView {
    /// 배속 분할 단추 (묶음 제목이 이미 "재생 속도"라 이름은 숨긴다)
    var ratePicker: some View {
        Picker("재생 속도", selection: $model.rate) {
            ForEach(rates, id: \.self) { rate in
                Text(rate.formatted() + "x").tag(rate)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
    }
}

/// 싱크 조절 한 줄: -0.1초 / 현재 값 / +0.1초 / 초기화
/// 바뀜 (2026-11-17, 사용자): 초기화 단추 없앰 — 값 칸에 0 을 넣으면 된다
private struct DelayRow: View {
    let title: String
    @Binding var milliseconds: Int

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            button("-0.1", systemImage: "minus") { milliseconds -= 100 }
            // 바뀜 (2026-11-17, 사용자): 1분 넘게 어긋나는 자막도 있어 값을 직접 입력할 수 있게 — 글자 대신 입력 칸
            TextField(title, text: $text)
                .labelsHidden()
                .multilineTextAlignment(.center)
                .monospacedDigit()
                .textFieldStyle(.roundedBorder)
                // 바뀜 (2026-11-17, 사용자): 자리를 덜 차지하게 "+120.5" 만 보이므로 칸도 좁게
                .frame(width: 72)
                .focused($editing)
                #if os(iOS)
                .keyboardType(.numbersAndPunctuation)
                .submitLabel(.done)
                #endif
                .onSubmit(commit)
                .onChange(of: editing) { if !editing { commit() } }
                .onChange(of: milliseconds) { if !editing { text = Self.format(milliseconds) } }
                .onAppear { text = Self.format(milliseconds) }
            button("+0.1", systemImage: "plus") { milliseconds += 100 }
        }
        .buttonStyle(.bordered)
    }

    @State private var text = ""
    @FocusState private var editing: Bool

    /// 입력한 값을 넣는다. 못 읽으면 원래 값으로 되돌린다
    private func commit() {
        // 고치지 않고 칸을 떠나면 그대로 (보이는 값은 0.1초로 반올림돼 있어 다시 읽으면 조금 바뀔 수 있다)
        if text != Self.format(milliseconds), let value = Self.parse(text) { milliseconds = value }
        text = Self.format(milliseconds)
    }

    /// 보이는 값: 1분 안쪽은 "+1.5초", 넘으면 "-1분 15.0초"
    /// 바뀜 (2026-11-17, 사용자): 자리를 덜 차지하게 초만 "+120.5" 로 (입력은 분:초 도 그대로 읽는다)
    static func format(_ milliseconds: Int) -> String {
        String(format: "%+.1f", Double(milliseconds) / 1000)
    }

    /// 입력: "75", "-75.5", "+1:15", "-1:15.5", "1분 15초", "-2분" 처럼 초 또는 분:초 (부호는 지금 표시와 같은 뜻)
    static func parse(_ input: String) -> Int? {
        var s = input.replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "초", with: "")
        s = s.replacingOccurrences(of: "분", with: ":")
        var sign = 1.0
        if s.hasPrefix("-") || s.hasPrefix("−") { sign = -1; s.removeFirst() } else if s.hasPrefix("+") { s.removeFirst() }
        let parts = s.split(separator: ":", omittingEmptySubsequences: false)
        guard (1...2).contains(parts.count) else { return nil }
        var seconds = 0.0
        for (i, part) in parts.enumerated() {
            let isLast = i == parts.count - 1
            if part.isEmpty, isLast, parts.count == 2 { continue } // "2분" → "2:"
            guard let value = Double(part), value >= 0 else { return nil }
            seconds = seconds * 60 + value
        }
        if parts.count == 2, parts[1].isEmpty { seconds *= 60 }
        guard seconds <= 3600 else { return nil }
        return Int((sign * seconds * 1000).rounded())
    }

    /// 아이콘 단추: 그림 높이가 달라도(− 는 얇다) 단추 크기가 같게 칸을 정해 둔다
    private func button(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .frame(width: 22, height: 22)
        }
        .accessibilityLabel(title)
    }
}
