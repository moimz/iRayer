import SwiftUI
import Observation

/// 텍스트 파일 열기 (폴더에서). 통째로 받아 인코딩을 알아내고 보기 화면을 띄운다.
/// 보기 화면은 앱 맨 위에서 띄운다 (아이폰·아이패드: 전체 화면, 맥: 따로 뜬 창)
@Observable
final class TextLauncher {
    static let shared = TextLauncher()

    /// 지금 보는 파일
    var book: TextBook?
    var errorMessage: String?
    /// 받는 중 (이름, 받은 비율)
    var downloading: (name: String, fraction: Double)?

    private init() {}

    func open(_ file: VideoFile) async {
        guard file.size <= TextBook.maxBytes else {
            errorMessage = "텍스트 파일이 너무 큽니다 (\(file.size.fileSizeText)). \(TextBook.maxBytes.fileSizeText) 까지 열 수 있습니다."
            return
        }
        do {
            let data = try await read(file)
            let choice = TextSettingsStore.shared.settings(for: file).encoding
            guard let decoded = TextEncoding.decode(data, as: choice) ?? TextEncoding.decode(data, as: .auto) else {
                errorMessage = "글자를 풀 수 없는 파일입니다."
                return
            }
            book = TextBook(file: file, data: data, text: decoded.text, encoding: decoded.used)
        } catch is CancellationError {
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// 파일을 통째로 (로컬은 바로, NAS 는 조각으로 받으며 진행률)
    private func read(_ file: VideoFile) async throws -> Data {
        if file.url.isFileURL { return try Data(contentsOf: file.url) }
        downloading = (file.name, 0)
        defer { downloading = nil }
        var data = Data()
        data.reserveCapacity(Int(file.size))
        let chunk: Int64 = 2 << 20
        var offset: Int64 = 0
        while offset < file.size {
            try Task.checkCancellation()
            let part = try await FileOperations.read(file.url, range: offset..<min(offset + chunk, file.size), serverID: file.serverID)
            guard !part.isEmpty else { break }
            data.append(part)
            offset += Int64(part.count)
            downloading = (file.name, Double(offset) / Double(max(file.size, 1)))
        }
        return data
    }
}

/// 텍스트 보기 화면과 받는 중 표시·오류를 붙인다 (앱 맨 위에 한 번)
struct TextLauncherPresentations: ViewModifier {
    @State private var launcher = TextLauncher.shared

    func body(content: Content) -> some View {
        content
            #if os(macOS)
            .onChange(of: launcher.book?.id) {
                guard let book = launcher.book else { return }
                launcher.book = nil
                TextWindowHost.shared.show(book)
            }
            #else
            .fullScreenCover(item: $launcher.book) { book in
                TextReaderView(book: book)
                    .onDisappear { ReturnHighlight.shared.returned(from: book.file) }
            }
            #endif
            .overlay(alignment: .top) {
                if let downloading = launcher.downloading {
                    HStack(spacing: 10) {
                        ProgressView(value: downloading.fraction)
                            .progressViewStyle(.circular)
                        VStack(alignment: .leading, spacing: 0) {
                            Text("받는 중 \(Int(downloading.fraction * 100))%").font(.footnote.weight(.semibold))
                            Text(downloading.name).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .glassEffect(.regular, in: .capsule)
                    .padding(.top, 8)
                    .padding(.horizontal)
                }
            }
            .alert("열 수 없습니다", isPresented: Binding(
                get: { launcher.errorMessage != nil },
                set: { if !$0 { launcher.errorMessage = nil } }
            )) {
                Button("확인", role: .cancel) {}
            } message: {
                Text(launcher.errorMessage ?? "")
            }
    }
}
