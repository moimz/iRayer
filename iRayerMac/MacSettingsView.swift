import SwiftUI

/// 맥 설정 창 (⌘,): 위쪽 탭으로 나눈다. 터치 제스처·자동 잠금처럼 아이폰에만 있는 항목은 뺀다.
struct MacSettingsView: View {
    var body: some View {
        TabView {
            Tab("일반", systemImage: "gearshape") { GeneralSettings() }
            Tab("자막", systemImage: "captions.bubble") { SubtitleSettings() }
            // 바뀜 (2026-11-08): 읽기(이미지뷰어·나중에 텍스트 뷰어) 공통 설정
            Tab("읽기", systemImage: "book") { ReadingSettings() }
            Tab("저장소", systemImage: "externaldrive.connected.to.line.below") { StorageSettings() }
            Tab("라이브러리", systemImage: "books.vertical") { LibrarySettings() }
            Tab("에이전트", systemImage: "sparkle.magnifyingglass") { AgentSettings() }
            Tab("동기화", systemImage: "icloud") { SyncSettings() }
            Tab("검색", systemImage: "magnifyingglass") { TMDBSettingsView().formStyle(.grouped) }
            Tab("캐시", systemImage: "internaldrive") { CacheSettings() }
        }
        // 바뀜 (2026-11-08): 읽기 탭이 늘어 탭이 넘쳐 » 가 생겼다 (사용자) → 520 → 660
        .frame(width: 660, height: 560)
        // 바뀜 (2026-11-16, 사용자): Mail 처럼 위 아이콘 탭줄에 띠(음영)가 보이게 — iSQL 과 같은 방법
        .background(SettingsWindowStyler())
    }
}

/// 설정 창(NSWindow)을 직접 다듬는다 (2026-11-16, 사용자, iSQL 에서 가져옴).
/// 맥 26 SwiftUI 설정 창은 내용이 탭줄 밑까지 깔려(fullSizeContentView) 창이 활성이면 탭줄 띠가 안 보인다.
/// `.toolbarBackgroundVisibility(.visible, for: .windowToolbar)` 는 효과가 없어 창을 잡아 직접 바꾼다.
private struct SettingsWindowStyler: NSViewRepresentable {
    final class Probe: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            DispatchQueue.main.async {
                window.styleMask.remove(.fullSizeContentView)
                window.titlebarAppearsTransparent = false
                window.titlebarSeparatorStyle = .line
                window.toolbarStyle = .preference
            }
        }
    }

    func makeNSView(context: Context) -> Probe { Probe() }
    func updateNSView(_ view: Probe, context: Context) {}
}

/// 읽기 공통 설정 (기기마다). 책마다 다른 것은 보기 화면의 설정 패널
private struct ReadingSettings: View {
    @Bindable private var settings = AppSettings.shared

    var body: some View {
        Form {
            Section("이미지뷰어") {
                Picker("자동 넘김 간격", selection: $settings.comicAutoSeconds) {
                    ForEach(AppSettings.comicAutoChoices, id: \.self) { Text("\($0)초").tag($0) }
                }
            }
            // 바뀜 (2026-11-08): 텍스트 뷰어 보기 설정 (보기 창의 설정과 같은 값)
            TextStyleSection()
        }
        .formStyle(.grouped)
    }
}

private struct GeneralSettings: View {
    @Bindable private var settings = AppSettings.shared
    @Bindable private var synced = SyncedSettings.shared
    @State private var askingPIN: PINSheet.Purpose?

    var body: some View {
        Form {
            Section {
                Picker("화면 모드", selection: $settings.appearance) {
                    ForEach(AppAppearance.allCases, id: \.self) { Text($0.title).tag($0) }
                }
            }
            Section("재생") {
                Stepper(value: $settings.skipSeconds, in: 5...60, step: 5) {
                    LabeledContent("← → 키로 건너뛰기", value: "\(settings.skipSeconds)초")
                }
                Toggle("하드웨어 디코딩", isOn: $settings.hardwareDecoding)
                Toggle("레터박스를 영상 색으로 채우기", isOn: $settings.ambientLetterbox)
                Picker("다음 회차 버튼", selection: $synced.nextEpisodeLead) {
                    ForEach(SyncedSettings.nextEpisodeLeadChoices, id: \.self) { Text("끝나기 \($0)초 전").tag($0) }
                }
            }
            AdultFilterSection(asking: $askingPIN)
            Section {
            } footer: {
                Text(versionText)
                    .frame(maxWidth: .infinity)
                    .textSelection(.enabled)
            }
        }
        .formStyle(.grouped)
        .adultFilterPINSheet($askingPIN)
    }

    /// 버전 정보: "버전 1.0 (빌드 62 · 0a1cd22)" — 빌드 번호는 git 커밋 수, 뒤는 커밋 해시
    private var versionText: String {
        let info = Bundle.main.infoDictionary ?? [:]
        // 시험판 브랜치(2.1b 등) 빌드는 "2.1b"
        let version = (info["CFBundleShortVersionString"] as? String ?? "-") + (info["IRayerBeta"] as? Bool == true ? "b" : "")
        let build = info["CFBundleVersion"] as? String ?? "-"
        let commit = info["IRayerCommit"] as? String
        return "버전 \(version) (빌드 \(build)\(commit.map { " · \($0)" } ?? ""))"
    }
}

/// 자막: 미리보기 + 글꼴·가장자리·크기
private struct SubtitleSettings: View {
    @Bindable private var settings = AppSettings.shared

    var body: some View {
        Form {
            Section {
                SubtitlePreview()
                    .clipShape(.rect(cornerRadius: 8))
            }
            Section {
                Picker("글꼴", selection: $settings.subtitleFont) {
                    ForEach(SubtitleFont.allCases) { font in
                        Text(font.name).font(font.font(size: 13)).tag(font)
                    }
                }
                Picker("가장자리", selection: $settings.subtitleEdge) {
                    ForEach(SubtitleEdge.allCases) { Text($0.name).tag($0) }
                }
                LabeledContent("크기") {
                    HStack {
                        Slider(value: $settings.subtitleScale, in: 0.6...1.6, step: 0.05)
                        Text("\(Int((settings.subtitleScale * 100).rounded()))%")
                            .monospacedDigit()
                            .frame(width: 44, alignment: .trailing)
                    }
                }
            } footer: {
                Text("영상 안에 들어 있는 자막에는 다음에 여는 영상부터 적용됩니다.\n나눔글꼴 © NAVER Corporation, SIL Open Font License 1.1")
            }
        }
        .formStyle(.grouped)
    }
}

private struct SyncSettings: View {
    @State private var sync = SyncEngine.shared

    var body: some View {
        Form {
            Section {
                LabeledContent("상태") {
                    if sync.isSyncing {
                        ProgressView().controlSize(.small)
                    } else if let error = sync.lastError {
                        Text(error).foregroundStyle(.red).lineLimit(2)
                    } else if let date = sync.lastSyncedAt {
                        Text(date.formatted(.relative(presentation: .named)))
                    } else {
                        Text("대기 중")
                    }
                }
                LabeledContent("") {
                    Button("지금 동기화") { Task { await sync.syncNow() } }
                        .disabled(sync.isSyncing)
                }
            } header: {
                Text("iCloud 동기화")
            } footer: {
                Text("이어보기·시청 기록·저장소·라이브러리 설정·에이전트·재생목록·즐겨찾기 인물·폴더 설정·이미지뷰어 설정을 같은 Apple ID 의 기기끼리 맞춥니다. 라이브러리의 파일 목록과 작품 정보는 기기마다 에이전트에게 받습니다. 비밀번호와 API 키는 iCloud 키체인으로 넘어갑니다. 화면·자막·플레이어 설정과 이 Mac 의 폴더는 기기마다 따로입니다. 맥은 앱이 앞에 있는 동안 30초마다 확인합니다.")
            }
            Section("파일") {
                LabeledContent("파일 작업 내역") {
                    Button("열기…") { TransferCenter.shared.showsList = true }
                }
            }
        }
        .formStyle(.grouped)
    }
}
