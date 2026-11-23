import SwiftUI

/// 광고 차단 설정 (2026-11-12, 사용자): 켜고 끄기 + 규칙 글 편집. 아이폰·아이패드는 [설정] › 웹 탐색, 맥은 웹 탐색 설정 패널의 [규칙 편집…]
struct AdBlockSettings: View {
    @State private var adBlock = AdBlock.shared
    @State private var draft = AdBlock.shared.text
    @State private var saveTask: Task<Void, Never>?

    var body: some View {
        Form {
            Section {
                Toggle("광고 차단", isOn: Binding(get: { adBlock.enabled }, set: { adBlock.update(enabled: $0) }))
            } footer: {
                Text(status)
            }
            #if os(macOS)
            // 바뀜 (2026-11-12, 사용자): 팝업 가짜 창·스크립트 이동 묻기 (지금은 맥만)
            Section {
                Toggle("팝업 막기 (가짜 창 돌려주기)", isOn: Binding(get: { adBlock.fakePopups }, set: { adBlock.update(fakePopups: $0) }))
                Toggle("누르지 않은 이동은 묻기", isOn: Binding(get: { adBlock.confirmNavigation }, set: { adBlock.update(confirmNavigation: $0) }))
            } footer: {
                Text("스크립트가 연 팝업은 열지 않고 페이지에는 열린 것처럼 알려 줍니다. 누르지 않았는데 다른 곳으로 가려 하면 묻습니다 (폰에서 원격으로 연 탭은 묻지 않음). 예외(@@) 사이트는 둘 다 하지 않습니다. 다음에 여는 페이지부터.")
            }
            #endif
            Section {
                TextEditor(text: $draft)
                    .font(.system(.body, design: .monospaced))
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.asciiCapable)
                    #endif
                    .frame(minHeight: 260)
                    .onChange(of: draft) { scheduleSave() }
            } header: {
                Text("규칙")
            } footer: {
                Text("""
                한 줄에 하나. 다음에 여는 페이지부터 적용되고, iCloud 로 다른 기기와 같이 씁니다.
                ||ads.example.com^ — 그 도메인으로 가는 요청 막기
                example.com##.ad, #banner — 그 사이트에서 요소 숨기기
                ##.ad-slot — 모든 사이트에서 숨기기
                @@||example.com^ — 그 사이트는 막지 않기
                /ads/banner — 주소에 이 글이 들어가면 막기 (* 는 아무 글)
                example.com$ua=chrome — 그 사이트는 다른 브라우저인 척 (chrome·firefox·safari·iphone 또는 UA 글. 광고 차단을 꺼도 적용)
                ! 메모
                """)
            }
            if let error = adBlock.error {
                Section("적용 안 됨") {
                    Text(error).foregroundStyle(.red)
                }
            }
            if !adBlock.skippedLines.isEmpty {
                Section("읽지 못한 줄") {
                    ForEach(adBlock.skippedLines, id: \.self) { Text($0).font(.system(.body, design: .monospaced)) }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("광고 차단")
        // 다른 기기에서 바뀐 규칙이 오면 편집 칸도 바꾼다 (고치는 중이 아닐 때)
        .onChange(of: adBlock.text) { if saveTask == nil { draft = adBlock.text } }
        .onDisappear { flush() }
    }

    private var status: String {
        guard adBlock.enabled else { return "꺼짐" }
        if adBlock.error != nil { return "규칙에 문제가 있어 이전 규칙을 쓰는 중" }
        return adBlock.compiledCount == 0 ? "규칙 없음" : "규칙 \(adBlock.compiledCount)개 적용 중"
    }

    /// 치는 동안은 기다렸다가 멈추면 저장 (글자마다 웹킷 규칙을 새로 만들지 않게)
    private func scheduleSave() {
        guard draft != adBlock.text else { return }
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            flush()
        }
    }

    private func flush() {
        saveTask?.cancel()
        saveTask = nil
        if draft != adBlock.text { adBlock.update(text: draft) }
    }
}
