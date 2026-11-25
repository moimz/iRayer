import SwiftUI
import AVFoundation
import VideoToolbox
import MediaToolbox

/// Finder 미리보기 (1.2~): 앱에 넣은 QuickLook Video(QLVideo, GPL-2.0 이상) 확장의 켜짐 상태를 보여 준다.
/// - 미디어 확장 2개(형식 읽기·영상 디코더)가 켜져 있으면 Finder 썸네일·스페이스바 미리보기·QuickTime 이 MKV·AVI·WMV 등을 연다.
/// - Spotlight 플러그인은 영상 길이·코덱 같은 정보를 Spotlight·Finder 정보 창에 넣는다.
/// - 켜고 끄기는 macOS 가 앱에 맡기지 않는다 → 시스템 설정(일반 › 로그인 항목 및 확장 프로그램)을 연다.
/// - 상태는 앱에 넣은 작은 VP8 WebM(qlvideo-test.webm, macOS 기본으로는 못 여는 형식)을 AVFoundation 으로 열어 본다
///   (QLVideo 앱이 쓰는 방법 그대로). 다른 앱(QuickLook Video 앱 등)의 확장이 처리 중이면 그 이름을 보여 준다.
@MainActor @Observable
final class FinderPreview {
    static let shared = FinderPreview()

    enum State: Equatable {
        case checking
        case on                 // iRayer 의 확장이 처리
        case otherApp(String)   // 다른 앱의 확장이 처리 (그 앱 이름)
        case off
        case unknown            // 형식 읽기가 꺼져 있어 디코더는 확인할 수 없음
    }

    private(set) var formats: State = .checking
    private(set) var codecs: State = .checking
    private(set) var spotlight: State = .checking

    private var registered = false

    func refresh() async {
        if !registered {
            // 앱이 미디어 확장을 쓰겠다고 알려야 AVFoundation 이 확장을 부른다
            MTRegisterProfessionalVideoWorkflowFormatReaders()
            VTRegisterProfessionalVideoWorkflowVideoDecoders()
            registered = true
        }
        formats = .checking; codecs = .checking; spotlight = .checking
        async let media = Self.checkMedia()
        async let importer = Self.checkSpotlight()
        (formats, codecs) = await media
        spotlight = await importer
    }

    /// 시스템 설정 › 일반 › 로그인 항목 및 확장 프로그램
    static func openSystemSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.ExtensionsPreferences") {
            NSWorkspace.shared.open(url)
        }
    }

    private static let ownBundle = Bundle.main.bundleURL.standardizedFileURL.path

    private static func state(containingBundle url: URL?, name: String?) -> State {
        guard let url else { return .off }
        if url.standardizedFileURL.path == ownBundle { return .on }
        return .otherApp(name ?? url.deletingPathExtension().lastPathComponent)
    }

    /// 형식 읽기·영상 디코더. 매번 새 AVURLAsset 으로 연다 (시스템 설정에서 바꾼 것이 바로 보이게)
    nonisolated private static func checkMedia() async -> (State, State) {
        guard let url = Bundle.main.url(forResource: "qlvideo-test", withExtension: "webm") else { return (.unknown, .unknown) }
        let asset = AVURLAsset(url: url)
        guard let tracks = try? await asset.load(.tracks), !tracks.isEmpty else { return (.off, .unknown) }
        let reader = asset.mediaExtensionProperties
        let formats = await state(containingBundle: reader?.containingBundleURL, name: reader?.containingBundleName)
        // 디코더: 영상 트랙의 형식 설명으로 VideoToolbox 에 어느 확장이 풀지 묻는다
        guard let video = tracks.first(where: { $0.mediaType == .video }),
              let desc = try? await video.load(.formatDescriptions).first else { return (formats, .unknown) }
        guard let dict = try? VTVideoDecoderExtensionProperties(desc) else { return (formats, .off) }
        let codecs = await state(containingBundle: dict[.containingBundleURL] as? URL,
                                 name: dict[.containingBundleName] as? String)
        return (formats, codecs)
    }

    /// Spotlight 플러그인: `mdimport -L` 이 보여 주는 플러그인 목록에 우리 것이 있으면 켜짐
    nonisolated private static func checkSpotlight() async -> State {
        let p = Process()
        p.executableURL = URL(filePath: "/usr/bin/mdimport")
        p.arguments = ["-L"]
        let pipe = Pipe()
        p.standardOutput = pipe; p.standardError = pipe
        guard (try? p.run()) != nil else { return .unknown }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let out = String(decoding: data, as: UTF8.self)
        let own = await ownBundle
        if out.contains(own + "/Contents/Library/Spotlight/QLVideo Metadata.mdimporter") { return .on }
        if out.contains("QLVideo Metadata.mdimporter") { return .otherApp("QuickLook Video") }
        return .off
    }
}

/// 설정 › 일반 › Finder 미리보기
struct FinderPreviewSection: View {
    private var model = FinderPreview.shared

    var body: some View {
        Section {
            row("영상 형식 읽기", detail: "MKV·AVI·WMV·FLV·WebM 등", model.formats)
            row("영상 코덱", detail: "VP8·MPEG-4·WMV·RealVideo 등", model.codecs)
            row("Spotlight 정보", detail: "길이·해상도·코덱을 검색·정보 창에", model.spotlight)
            LabeledContent {
                HStack(spacing: 8) {
                    Button("다시 확인") { Task { await model.refresh() } }
                    Button("시스템 설정 열기…") { FinderPreview.openSystemSettings() }
                }
            } label: { EmptyView() }
        } header: {
            Text("Finder 미리보기")
        } footer: {
            Text("""
            켜 두면 Finder 썸네일, 스페이스바 미리보기, QuickTime 이 macOS 가 원래 못 여는 영상도 엽니다. \
            켜고 끄기는 시스템 설정 › 일반 › 로그인 항목 및 확장 프로그램 › iRayer 에서 합니다. \
            QuickLook Video(Jonathan Harris, GPL-2.0)의 확장을 그대로 넣었으므로, QuickLook Video 앱은 따로 깔지 않아도 됩니다.
            """)
        }
        .task { await model.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await model.refresh() }
        }
    }

    private func row(_ title: String, detail: String, _ state: FinderPreview.State) -> some View {
        LabeledContent {
            switch state {
            case .checking: ProgressView().controlSize(.small)
            case .on: Label("켜짐", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            case .otherApp(let name): Label("\(name) 이(가) 처리 중", systemImage: "arrow.triangle.branch").foregroundStyle(.orange)
            case .off: Label("꺼짐", systemImage: "circle").foregroundStyle(.secondary)
            case .unknown: Text("형식 읽기를 켜야 확인 가능").foregroundStyle(.secondary)
            }
        } label: {
            Text(title)
            Text(detail)
        }
    }
}
