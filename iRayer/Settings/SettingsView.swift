import SwiftUI

/// [설정] 탭
struct SettingsView: View {
    @Bindable private var settings = AppSettings.shared
    @Bindable private var synced = SyncedSettings.shared
    @State private var tmdb = TMDBSettings.shared
    @State private var sync = SyncEngine.shared
    @State private var adBlock = AdBlock.shared
    @State private var askingPIN: PINSheet.Purpose?
    @State private var noticeOn = UserDefaults.standard.bool(forKey: Notice.enabledKey)
    @State private var noticeError: String?

    var body: some View {
        NavigationStack {
            Form {
                // 영상을 가져오는 곳 → 그 안의 라이브러리·폴더 → 작품을 물어볼 곳
                Section {
                    NavigationLink {
                        StorageSettings()
                    } label: {
                        Label("저장소", systemImage: "externaldrive.connected.to.line.below")
                    }
                    NavigationLink {
                        LibrarySettings()
                    } label: {
                        Label("라이브러리·폴더", systemImage: "books.vertical")
                    }
                    NavigationLink {
                        AgentSettings()
                    } label: {
                        Label("에이전트", systemImage: "sparkle.magnifyingglass")
                    }
                }

                Section("화면") {
                    Picker("화면 모드", selection: $settings.appearance) {
                        ForEach(AppAppearance.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                }

                AdultFilterSection(asking: $askingPIN)

                Section("플레이어") {
                    Stepper(value: $settings.skipSeconds, in: 5...60, step: 5) {
                        LabeledContent("더블탭 건너뛰기", value: "\(settings.skipSeconds)초")
                    }
                    Toggle("하드웨어 디코딩", isOn: $settings.hardwareDecoding)
                    Picker("네트워크 버퍼", selection: $settings.networkBufferSeconds) {
                        ForEach([1, 3, 5, 10, 20, 30, 60], id: \.self) { Text("\($0)초").tag($0) }
                    }
                    Toggle("앱 사용 중 자동 잠금 끄기", isOn: $settings.keepScreenOn)
                    Toggle("레터박스를 영상 색으로 채우기", isOn: $settings.ambientLetterbox)
                    Picker("다음 회차 버튼", selection: $synced.nextEpisodeLead) {
                        ForEach(SyncedSettings.nextEpisodeLeadChoices, id: \.self) { Text("끝나기 \($0)초 전").tag($0) }
                    }
                    VStack(alignment: .leading) {
                        LabeledContent("탐색 감도", value: "1pt 당 \(settings.seekSecondsPerPoint.formatted(.number.precision(.fractionLength(2))))초")
                        Slider(value: $settings.seekSecondsPerPoint, in: 0.02...1, step: 0.01)
                        Text("화면을 좌우로 끌어 탐색할 때 손가락 1pt 에 움직일 시간.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    VStack(alignment: .leading) {
                        LabeledContent("제스처 방향 판단 거리", value: "\(Int(settings.gestureDecisionDistance))pt")
                        Slider(value: $settings.gestureDecisionDistance, in: 5...60, step: 5)
                        Text("화면을 끌 때 이만큼 움직인 뒤 가로(탐색)·세로(밝기·볼륨) 중 더 많이 간 쪽으로 정합니다. 짧으면 반응이 빠르고, 길면 방향이 덜 헷갈립니다.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    VStack(alignment: .leading) {
                        LabeledContent("최대 확대", value: "\(settings.maxZoomScale.formatted(.number.precision(.fractionLength(1))))배")
                        Slider(value: $settings.maxZoomScale, in: 1.5...5, step: 0.5)
                    }
                }

                Section {
                    LabeledContent("상태") {
                        if sync.isSyncing {
                            ProgressView()
                        } else if let error = sync.lastError {
                            Text(error).foregroundStyle(.red).lineLimit(2)
                        } else if let date = sync.lastSyncedAt {
                            Text(date.formatted(.relative(presentation: .named)))
                        } else {
                            Text("대기 중")
                        }
                    }
                    Button("지금 동기화") { Task { await sync.syncNow() } }
                        .disabled(sync.isSyncing)
                } header: {
                    Text("iCloud 동기화")
                } footer: {
                    Text("이어보기·시청 기록·저장소·라이브러리 설정·에이전트·재생목록·즐겨찾기 인물·폴더 설정·이미지뷰어 설정을 같은 Apple ID 의 기기끼리 맞춥니다. 라이브러리의 파일 목록과 작품 정보는 기기마다 에이전트에게 받습니다. 비밀번호와 API 키는 iCloud 키체인으로 넘어갑니다. 화면·자막·플레이어 설정과 이 기기의 폴더는 기기마다 따로입니다.")
                }

                Section("파일") {
                    NavigationLink {
                        TransferListView(showsCloseButton: false)
                    } label: {
                        Label("파일 작업 내역", systemImage: "arrow.up.arrow.down")
                    }
                    NavigationLink {
                        CacheSettings()
                    } label: {
                        Label("캐시", systemImage: "internaldrive")
                    }
                }

                // 바뀜 (2026-11-12, 사용자): 웹 탐색 광고 차단 (규칙은 iCloud 로 맥과 같이 쓴다)
                Section("웹 탐색") {
                    NavigationLink {
                        AdBlockSettings()
                    } label: {
                        LabeledContent("광고 차단", value: adBlock.enabled ? "켬" : "끔")
                    }
                }

                #if os(iOS)
                // 바뀜 (2026-11-12, 사용자): 앱 잠금 (Face ID + 기기 암호)
                AppLockSection()

                // 바뀜 (2026-11-12, 사용자): 맥에서 받기가 끝나면 이 기기에 알림
                Section {
                    Toggle("맥 받기 알림", isOn: Binding(get: { noticeOn }, set: { on in
                        noticeOn = on
                        Task { noticeError = await Notice.setEnabled(on) }
                    }))
                    if let noticeError { Text(noticeError).foregroundStyle(.red) }
                } header: {
                    Text("알림")
                } footer: {
                    Text("맥 웹 탐색에서 받기·재생하며 받기가 끝나거나 실패하면 알립니다. 켜고 끄면 같은 iCloud 의 아이폰·아이패드 모두에 적용되고, 이 기기만 끄려면 iOS 설정 › 알림 › iRayer.")
                }

                #endif
                Section("검색") {
                    NavigationLink {
                        TMDBSettingsView()
                    } label: {
                        LabeledContent("TMDB", value: tmdb.isActive ? "사용 중" : tmdb.isEnabled ? "키 없음" : "끔")
                    }
                }

                // 바뀜 (2026-11-08): 이미지뷰어(만화책) 공통 설정 — 책마다 다른 것(읽는 방향·반 자르기)은 보기 화면의 설정 패널
                Section("이미지뷰어") {
                    Picker("자동 넘김 간격", selection: $settings.comicAutoSeconds) {
                        ForEach(AppSettings.comicAutoChoices, id: \.self) { Text("\($0)초").tag($0) }
                    }
                }

                // 바뀜 (2026-11-08): 텍스트 뷰어 보기 설정 (기기마다) — 보기 화면의 설정 패널과 같은 값
                Section("텍스트 뷰어") {
                    NavigationLink {
                        Form { TextStyleSection(isFirst: true) }
                            .navigationTitle("텍스트 뷰어")
                    } label: {
                        LabeledContent("글꼴·크기·배경", value: "\(settings.textTheme.title) · \(Int(settings.textSize))")
                    }
                }

                Section("자막") {
                    NavigationLink {
                        SubtitleSettingsView()
                    } label: {
                        LabeledContent("글꼴·크기·가장자리", value: "\(settings.subtitleFont.name) · \(Int((settings.subtitleScale * 100).rounded()))%")
                    }
                }

                // 이 앱에 관하여: 오픈 소스·TMDB 고지 (2026-11-23, 사용자)
                Section {
                    NavigationLink("이 앱에 관하여") {
                        ScrollView { AboutView().frame(maxWidth: 480) }
                            .frame(maxWidth: .infinity)
                            .navigationTitle("이 앱에 관하여")
                            #if os(iOS)
                            .navigationBarTitleDisplayMode(.inline)
                            #endif
                    }
                } footer: {
                    Text(versionText)
                        .frame(maxWidth: .infinity)
                        .textSelection(.enabled)
                }
            }
            .navigationTitle("설정")
            .adultFilterPINSheet($askingPIN)
        }
    }

    /// 맨 아래 버전 정보: "버전 0.1 (빌드 43 · fa0e978)" — 빌드 번호는 git 커밋 수, 뒤는 커밋 해시 ("+" 는 커밋 전 변경 포함)
    private var versionText: String {
        let info = Bundle.main.infoDictionary ?? [:]
        // beta 브랜치 빌드는 "1.0b"
        let version = (info["CFBundleShortVersionString"] as? String ?? "-") + (info["IRayerBeta"] as? Bool == true ? "b" : "")
        let build = info["CFBundleVersion"] as? String ?? "-"
        let commit = info["IRayerCommit"] as? String
        return "버전 \(version) (빌드 \(build)\(commit.map { " · \($0)" } ?? ""))"
    }
}

/// 자막 글꼴·크기 설정. 미리보기를 위에 고정해 두고 바꾸는 대로 바로 보이게 한다.
struct SubtitleSettingsView: View {
    @Bindable private var settings = AppSettings.shared

    var body: some View {
        VStack(spacing: 0) {
            SubtitlePreview()
                .clipShape(.rect(cornerRadius: 12))
                .padding()
            Form {
                Section("글꼴") {
                    ForEach(SubtitleFont.allCases) { font in
                        Button {
                            settings.subtitleFont = font
                        } label: {
                            HStack {
                                Text(font.name)
                                    .font(font.font(size: 17))
                                Spacer()
                                if settings.subtitleFont == font {
                                    Image(systemName: "checkmark").foregroundStyle(Color.accentColor)
                                }
                            }
                        }
                        // 버튼 글자를 파란색이 아닌 일반 글자색으로 (각 글꼴 모양이 잘 보이게)
                        .tint(.primary)
                    }
                }
                Section("가장자리") {
                    Picker("가장자리", selection: $settings.subtitleEdge) {
                        ForEach(SubtitleEdge.allCases) { Text($0.name).tag($0) }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                }
                Section {
                    VStack(alignment: .leading) {
                        LabeledContent("크기", value: "\(Int((settings.subtitleScale * 100).rounded()))%")
                        Slider(value: $settings.subtitleScale, in: 0.6...1.6, step: 0.05)
                    }
                } footer: {
                    Text("가로 화면 기준이며, 세로 화면에서는 70% 크기로 보입니다. 영상 안에 들어 있는 자막에는 다음에 여는 영상부터 적용됩니다.\n\n나눔글꼴 © NAVER Corporation, SIL Open Font License 1.1")
                }
            }
        }
        .background(Color.groupedBackground)
        .navigationTitle("자막")
        .inlineNavigationTitle()
    }
}

/// 자막 설정 미리보기: 가로 화면을 줄여 놓은 16:9 장면에 지금 설정의 자막을 같은 비율로 그린다
struct SubtitlePreview: View {
    var body: some View {
        Color.clear
            .aspectRatio(16 / 9, contentMode: .fit)
            .background {
                // 밝은 부분과 어두운 부분이 섞인 장면 (테두리 그림자가 잘 보이는지 함께 확인)
                LinearGradient(colors: [Color(red: 0.35, green: 0.55, blue: 0.8), Color(red: 0.85, green: 0.8, blue: 0.65), Color(red: 0.2, green: 0.25, blue: 0.2)],
                               startPoint: .top, endPoint: .bottom)
            }
            .overlay(alignment: .bottom) {
                GeometryReader { geometry in
                    VStack {
                        Spacer()
                        SubtitleText(text: "자막은 이렇게 보입니다\nThe quick brown fox 123",
                                     baseSize: SubtitleText.baseSize(for: geometry.size))
                            .padding(.horizontal, 12)
                            .padding(.bottom, geometry.size.height * 0.06)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .clipped()
    }
}
