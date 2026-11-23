import SwiftUI

/// 설정 > TMDB: 키 발급 링크, 액세스 토큰·API 키, 국가·언어
struct TMDBSettingsView: View {
    @Bindable private var settings = TMDBSettings.shared
    @State private var checking = false
    @State private var checkResult: Result<Void, Error>?

    var body: some View {
        Form {
            Section {
                Toggle("TMDB 사용", isOn: $settings.isEnabled)
            } footer: {
                Text(settings.isEnabled && !settings.isConfigured
                     ? "아래에 키를 넣으면 검색에 \"다른 곳에서 찾기\"가 나옵니다."
                     : "켜면 검색 결과 아래에 \"다른 곳에서 찾기\"(TMDB 작품 정보와 볼 수 있는 곳)가 나옵니다.")
            }

            Section {
                Link(destination: TMDBSettings.keyPageURL) {
                    Label("키 발급받기", systemImage: "key")
                }
            } footer: {
                Text("TMDB 에 가입한 뒤 설정 > API 에서 개인용 키를 받습니다. 받은 키를 아래에 붙여 넣으세요.")
            }

            Section {
                SecureField("API 읽기 액세스 토큰", text: $settings.accessToken)
                    .plainTextInput()
                    .textContentType(.oneTimeCode)
                SecureField("API 키", text: $settings.apiKey)
                    .plainTextInput()
                    .textContentType(.oneTimeCode)
                Button {
                    Task { await check() }
                } label: {
                    HStack {
                        Text("연결 확인")
                        Spacer()
                        if checking {
                            ProgressView()
                        } else if case .success = checkResult {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                        } else if case .failure = checkResult {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
                        }
                    }
                }
                .disabled(!settings.isConfigured || checking)
            } header: {
                Text("키")
            } footer: {
                if case .failure(let error) = checkResult {
                    Text(error.localizedDescription).foregroundStyle(.red)
                } else {
                    Text("둘 중 하나만 있어도 됩니다 (토큰을 먼저 씁니다). 이 기기 키체인에만 저장됩니다.")
                }
            }

            Section {
                Picker("국가", selection: $settings.region) {
                    ForEach(TMDBSettings.regions, id: \.code) { Text($0.name).tag($0.code) }
                }
                Picker("언어", selection: $settings.language) {
                    ForEach(TMDBSettings.languages, id: \.code) { Text($0.name).tag($0.code) }
                }
            } header: {
                Text("지역")
            } footer: {
                Text("국가는 볼 수 있는 곳(구독·대여·구매)을, 언어는 제목·줄거리를 정합니다.")
            }

            Section {
            } footer: {
                Text("이 제품은 TMDB API 를 사용하지만 TMDB 가 보증하거나 인증한 것은 아닙니다. 볼 수 있는 곳 정보는 JustWatch 제공입니다.")
            }
        }
        .navigationTitle("TMDB")
        .inlineNavigationTitle()
        .onChange(of: settings.accessToken) { checkResult = nil }
        .onChange(of: settings.apiKey) { checkResult = nil }
    }

    private func check() async {
        checking = true
        defer { checking = false }
        do {
            try await TMDBClient.check()
            checkResult = .success(())
        } catch {
            checkResult = .failure(error)
        }
    }
}

/// 검색의 "다른 곳에서 찾기" 한 줄: 포스터 + 제목 + 종류·연도 (보관함에 있으면 표시)
struct TMDBRow: View {
    let title: TMDBTitle
    var inLibrary = false

    var body: some View {
        HStack(spacing: 12) {
            TMDBPoster(path: title.posterPath)
                .frame(width: 44, height: 66)
                .clipShape(.rect(cornerRadius: 4))
            VStack(alignment: .leading, spacing: 3) {
                Text(title.displayTitle)
                    .lineLimit(2)
                Text([title.kindName, title.year.map(String.init)].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if inLibrary {
                    Label("보관함에 있음", systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.green)
                }
            }
            Spacer(minLength: 0)
        }
        .contentShape(.rect)
    }
}

struct TMDBPoster: View {
    let path: String?
    var size = "w185"

    var body: some View {
        AsyncImage(url: TMDBClient.imageURL(path, size: size)) { image in
            image.resizable().scaledToFill()
        } placeholder: {
            Rectangle().fill(.quaternary)
                .overlay { Image(systemName: "film").foregroundStyle(.secondary) }
        }
    }
}

/// 작품 시트: 그림·줄거리와 설정한 국가에서 볼 수 있는 곳 (구독·무료·광고·대여·구매)
struct TMDBDetailSheet: View {
    let title: TMDBTitle
    /// 보관함에 있으면 그 화면으로 가는 동작
    var openInLibrary: (() -> Void)?

    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var options: TMDBWatchOptions?
    @State private var loaded = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(alignment: .top, spacing: 14) {
                        TMDBPoster(path: title.posterPath, size: "w342")
                            .frame(width: 110, height: 165)
                            .clipShape(.rect(cornerRadius: 8))
                        VStack(alignment: .leading, spacing: 6) {
                            Text(title.displayTitle)
                                .font(.title3.bold())
                            if let original = title.originalDisplayTitle, original != title.displayTitle {
                                Text(original)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                            Text([title.kindName, title.year.map(String.init)].compactMap { $0 }.joined(separator: " · "))
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                            if let vote = title.voteAverage, vote > 0 {
                                Label(String(format: "%.1f", vote), systemImage: "star.fill")
                                    .font(.subheadline)
                                    .foregroundStyle(.orange)
                            }
                        }
                    }

                    if let openInLibrary {
                        Button("보관함에서 보기", systemImage: "play.rectangle") {
                            dismiss()
                            openInLibrary()
                        }
                        .buttonStyle(.glassProminent)
                        .controlSize(.large)
                    }

                    if let overview = title.overview, !overview.isEmpty {
                        Text(overview)
                            .font(.body)
                    }

                    watchSection
                }
                .padding()
            }
            .navigationTitle("다른 곳에서 찾기")
            .inlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .closeBar) {
                    CloseButton { dismiss() }
                }
            }
            .task {
                do {
                    options = try await TMDBClient.watchOptions(title)
                } catch {
                    errorMessage = error.localizedDescription
                }
                loaded = true
            }
        }
        .presentationDetents([.medium, .large])
    }

    private var regionName: String {
        let code = TMDBSettings.shared.region
        return TMDBSettings.regions.first { $0.code == code }?.name ?? code
    }

    @ViewBuilder
    private var watchSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("\(regionName)에서 볼 수 있는 곳")
                .font(.headline)
            if !loaded {
                ProgressView()
            } else if let errorMessage {
                Text(errorMessage).foregroundStyle(.secondary)
            } else if let options, !options.isEmpty {
                providerRow("구독", options.flatrate)
                providerRow("무료", options.free)
                providerRow("광고 포함 무료", options.ads)
                providerRow("대여", options.rent)
                providerRow("구매", options.buy)
                Text("JustWatch 제공")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("볼 수 있는 곳 정보가 없습니다.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func providerRow(_ label: String, _ providers: [TMDBProvider]?) -> some View {
        if let providers, !providers.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text(label)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                PagingScrollView(spacing: 12) {
                    ForEach(providers) { provider in
                        Button {
                            // 서비스별 바로가기 주소는 JustWatch 만 알고 있다 → TMDB 시청처 페이지(JustWatch 로 이어짐)
                            if let link = options?.link, let url = URL(string: link) { openURL(url) }
                        } label: {
                            VStack(spacing: 4) {
                                TMDBPoster(path: provider.logoPath, size: "w92")
                                    .frame(width: 48, height: 48)
                                    .clipShape(.rect(cornerRadius: 10))
                                Text(provider.providerName)
                                    .font(.caption2)
                                    .lineLimit(1)
                                    .frame(width: 64)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }
}
