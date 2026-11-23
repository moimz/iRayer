import Foundation

/// 앱 안의 최소 ffmpeg (Contents/Helpers/ffmpeg): 받아 둔 로컬 파일을 다시 묶기만 한다 (-c copy, 네트워크·인코더 없음)
enum FFmpeg {
    static var executable: URL {
        Bundle.main.bundleURL.appending(path: "Contents/Helpers/ffmpeg")
    }

    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { "영상을 묶지 못했습니다: \(message)" }
    }

    /// 실행하고 끝날 때까지 기다린다 (취소하면 프로세스를 끈다)
    static func run(_ arguments: [String]) async throws {
        let process = Process()
        process.executableURL = executable
        process.arguments = ["-hide_banner", "-loglevel", "error", "-nostdin", "-y"] + arguments
        let errors = Pipe()
        process.standardError = errors
        process.standardOutput = FileHandle.nullDevice
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                process.terminationHandler = { process in
                    let text = String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                    if process.terminationStatus == 0 {
                        continuation.resume()
                    } else {
                        let last = text.split(whereSeparator: \.isNewline).last.map(String.init) ?? "종료 코드 \(process.terminationStatus)"
                        continuation.resume(throwing: Failure(message: last))
                    }
                }
                do { try process.run() } catch { continuation.resume(throwing: error) }
            }
        } onCancel: {
            process.terminate()
        }
    }

    /// 같은 트랙의 여러 파일(화질이 바뀐 구간마다)을 시각 순으로 이어 한 파일로 (-c copy).
    /// 화질마다 코덱 설정(SPS 등)이 달라 MP4 하나에 그대로 이으면 뒤쪽이 깨진다 → 구간마다 TS 로 바꿔(설정이 영상 안에 들어감) 이은 TS 를 돌려준다
    static func concat(_ files: [URL], to output: URL) async throws -> URL {
        var parts: [URL] = []
        for (index, file) in files.enumerated() {
            let part = output.deletingLastPathComponent().appending(path: "\(output.deletingPathExtension().lastPathComponent)-\(index).ts")
            try await run(["-i", file.path, "-c", "copy", "-f", "mpegts", part.path])
            parts.append(part)
        }
        let joined = output.deletingPathExtension().appendingPathExtension("ts")
        let list = output.deletingPathExtension().appendingPathExtension("txt")
        let lines = parts.map { "file '\($0.path.replacingOccurrences(of: "'", with: "'\\''"))'" }.joined(separator: "\n")
        try lines.write(to: list, atomically: true, encoding: .utf8)
        try await run(["-f", "concat", "-safe", "0", "-i", list.path, "-c", "copy", "-f", "mpegts", joined.path])
        return joined
    }

    /// 트랙들(영상·소리)을 한 파일로. MP4 에 안 맞는 코덱이면 MKV 로. 만든 파일을 돌려준다
    static func mux(_ inputs: [URL], to output: URL) async throws -> URL {
        var arguments: [String] = []
        for input in inputs { arguments += ["-i", input.path] }
        for index in inputs.indices { arguments += ["-map", "\(index)"] }
        arguments += ["-c", "copy"]
        do {
            try await run(arguments + ["-movflags", "+faststart", "-f", "mp4", output.path])
            return output
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            let mkv = output.deletingPathExtension().appendingPathExtension("mkv")
            try? FileManager.default.removeItem(at: output)
            try await run(arguments + ["-f", "matroska", mkv.path])
            return mkv
        }
    }
}
