import SwiftUI

/// 이 기기에 둔 캐시 (Caches 폴더). 지워도 필요할 때 다시 만들거나 받는다.
/// 때에 따라 비우고 싶을 만한 것만 하나씩 비우게 하고, 포스터·인물 사진(거의 비울 일 없음)은 "모두 비우기"에만 넣는다.
enum AppCache: CaseIterable, Identifiable {
    case thumbnails, covers, resumeFrames, rar

    var id: Self { self }

    var title: String {
        switch self {
        case .thumbnails: "영상 썸네일"
        case .covers: "만화책·폴더 표지"
        case .resumeFrames: "이어보기 장면"
        case .rar: "받아 둔 RAR 만화책"
        }
    }

    var directories: [URL] {
        switch self {
        case .thumbnails: [AppPaths.caches.appending(path: "Thumbnails")]
        case .covers: [AppPaths.caches.appending(path: "Covers2")]
        case .resumeFrames: [AppPaths.caches.appending(path: "ResumeFrames")]
        case .rar: [RarCache.root]
        }
    }

    func clear() async {
        switch self {
        case .thumbnails: ThumbnailService.shared.clear()
        case .covers: await CoverService.shared.clear()
        case .resumeFrames: ResumeFrames.shared.clear()
        case .rar: RarCache.clear()
        }
    }

    /// 하나씩 비우는 것 말고 "모두 비우기"에만 드는 곳: 포스터·인물 사진, 받은 자막 복사본
    static var otherDirectories: [URL] {
        [AppPaths.caches.appending(path: "Images"), AppPaths.caches.appending(path: "Subtitles")]
    }

    static func clearAll() async {
        for cache in allCases { await cache.clear() }
        ImageCache.shared.clear()
        try? FileManager.default.removeItem(at: AppPaths.caches.appending(path: "Subtitles"))
    }

    /// 폴더들의 크기 (바이트)
    nonisolated static func size(of directories: [URL]) async -> Int64 {
        await Task.detached { measure(directories) }.value
    }

    nonisolated private static func measure(_ directories: [URL]) -> Int64 {
        var total: Int64 = 0
        for directory in directories {
            guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.totalFileAllocatedSizeKey]) else { continue }
            while let url = enumerator.nextObject() as? URL {
                total += Int64((try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize) ?? 0)
            }
        }
        return total
    }
}

/// 설정 → 캐시: 종류마다 크기와 비우기
struct CacheSettings: View {
    @State private var sizes: [AppCache: Int64] = [:]
    @State private var otherSize: Int64?
    @State private var confirmingAll = false

    var body: some View {
        Form {
            Section {
                ForEach(AppCache.allCases) { cache in
                    LabeledContent(cache.title) {
                        HStack {
                            Text(sizes[cache].map(Self.format) ?? "…")
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                            Button("비우기") {
                                Task {
                                    await cache.clear()
                                    await measure()
                                }
                            }
                            .disabled((sizes[cache] ?? 0) == 0)
                        }
                    }
                }
            } footer: {
                Text("지워도 필요할 때 다시 만듭니다. 영상 썸네일을 비우면 검게 나온 썸네일도 새로 만듭니다. 받아 둔 RAR 은 다시 열 때 저장소에서 다시 받습니다.")
            }

            Section {
                Button("모든 캐시 비우기", role: .destructive) { confirmingAll = true }
                    .confirmationDialog("모든 캐시를 비울까요?", isPresented: $confirmingAll, titleVisibility: .visible) {
                        Button("모두 비우기", role: .destructive) {
                            Task {
                                await AppCache.clearAll()
                                await measure()
                            }
                        }
                    } message: {
                        Text("위 항목과 함께 포스터·인물 사진도 지웁니다. 포스터는 화면에 나올 때 다시 받습니다.")
                    }
            } footer: {
                if let otherSize {
                    Text("포스터·인물 사진 등 \(Self.format(otherSize))")
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("캐시")
        .inlineNavigationTitle()
        .task { await measure() }
    }

    private func measure() async {
        for cache in AppCache.allCases {
            sizes[cache] = await AppCache.size(of: cache.directories)
        }
        otherSize = await AppCache.size(of: AppCache.otherDirectories)
    }

    nonisolated private static func format(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
