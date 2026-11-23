import Foundation

/// 동기화 기록 (2026-11-09): 못 읽은 레코드를 적고 앱 판이 바뀐 뒤 다시 받아 적용하는지 보려고.
/// 맥: ~/Library/Logs/iRayer/sync.log, 아이폰·아이패드: 앱 저장 공간의 Library/Logs/iRayer/sync.log (1MB 넘으면 새로)
enum SyncLog {
    nonisolated static let file = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        .appending(path: "Logs/iRayer/sync.log")
    nonisolated private static let queue = DispatchQueue(label: "irayer.synclog")

    nonisolated static func write(_ text: String) {
        let line = "[\(Date().formatted(.iso8601))] \(text)\n"
        queue.async {
            let manager = FileManager.default
            try? manager.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let size = (try? manager.attributesOfItem(atPath: file.path))?[.size] as? Int, size > 1_000_000 {
                try? manager.removeItem(at: file)
            }
            if !manager.fileExists(atPath: file.path) { manager.createFile(atPath: file.path, contents: nil) }
            guard let handle = try? FileHandle(forWritingTo: file) else { return }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data(line.utf8))
            try? handle.close()
        }
    }
}
