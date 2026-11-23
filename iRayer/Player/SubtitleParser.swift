import Foundation

/// 자막 한 줄 (표시 시작·끝은 초)
struct SubtitleCue {
    let start: Double
    let end: Double
    let text: String
}

/// 앱이 직접 그리는 외부 자막(SRT, SMI, VTT) 파서.
/// 직접 그려야 UI 표시 여부에 따라 자막 위치를 옮기거나 스타일을 바꿀 수 있다. ASS 등 나머지는 VLC 가 그린다.
enum SubtitleParser {
    static let extensions: Set<String> = ["srt", "smi", "sami", "vtt"]

    static func canParse(_ url: URL) -> Bool {
        extensions.contains(url.subtitleExtension.lowercased())
    }

    static func parse(_ url: URL, serverID: UUID?) async -> [SubtitleCue]? {
        guard let data = try? await RemoteAccess.data(of: url, serverID: serverID), let text = SubtitleLoader.decode(data) else { return nil }
        return parse(text, fileExtension: url.subtitleExtension)
    }

    static func parse(_ text: String, fileExtension: String) -> [SubtitleCue] {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        switch fileExtension.lowercased() {
        case "smi", "sami": return parseSAMI(normalized)
        default: return parseSRT(normalized)
        }
    }

    /// 지금 표시할 자막. 여러 줄이 겹치면 이어서 보여준다.
    static func text(in cues: [SubtitleCue], at time: Double) -> String? {
        // 시작 시각이 time 이하인 마지막 자막 위치를 이분 탐색으로 찾는다
        var low = 0, high = cues.count
        while low < high {
            let mid = (low + high) / 2
            if cues[mid].start <= time { low = mid + 1 } else { high = mid }
        }
        var lines: [String] = []
        var index = low - 1
        // 길게 걸쳐 있는 자막도 잡기 위해 몇 줄 앞까지 확인
        while index >= 0, low - index <= 5 {
            if cues[index].end > time { lines.insert(cues[index].text, at: 0) }
            index -= 1
        }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    // MARK: - SRT / VTT

    private static func parseSRT(_ text: String) -> [SubtitleCue] {
        var cues: [SubtitleCue] = []
        var block: [String] = []

        func flush() {
            defer { block.removeAll() }
            guard let timeIndex = block.firstIndex(where: { $0.contains("-->") }) else { return }
            let parts = block[timeIndex].components(separatedBy: "-->")
            guard parts.count == 2,
                  let start = parseTime(parts[0]),
                  let endToken = parts[1].split(separator: " ", omittingEmptySubsequences: true).first,
                  let end = parseTime(String(endToken)) else { return }
            let body = clean(block[(timeIndex + 1)...].joined(separator: "\n"))
            if !body.isEmpty {
                cues.append(SubtitleCue(start: start, end: end, text: body))
            }
        }

        for line in text.components(separatedBy: "\n") {
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                flush()
            } else {
                block.append(line)
            }
        }
        flush()
        return cues.sorted { $0.start < $1.start }
    }

    /// "00:01:02,345", "01:02.345" 형식
    private static func parseTime(_ string: String) -> Double? {
        let parts = string.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".").split(separator: ":")
        guard (2...3).contains(parts.count) else { return nil }
        var seconds = 0.0
        for part in parts {
            guard let value = Double(part) else { return nil }
            seconds = seconds * 60 + value
        }
        return seconds
    }

    // MARK: - SMI (SAMI)

    private static func parseSAMI(_ text: String) -> [SubtitleCue] {
        guard let syncRegex = try? NSRegularExpression(pattern: #"<sync[^>]*start\s*=\s*["']?(\d+)[^>]*>"#, options: .caseInsensitive),
              let paragraphRegex = try? NSRegularExpression(pattern: #"<p\b([^>]*)>"#, options: .caseInsensitive),
              let classRegex = try? NSRegularExpression(pattern: #"class\s*=\s*["']?(\w+)"#, options: .caseInsensitive)
        else { return [] }

        let nsText = text as NSString
        let syncs = syncRegex.matches(in: text, range: NSRange(location: 0, length: nsText.length))

        // 동기화 지점마다 언어(class)별 내용을 모은다
        var entries: [(start: Double, byClass: [String: String])] = []
        var classOrder: [String] = []
        for (index, match) in syncs.enumerated() {
            let start = Double(nsText.substring(with: match.range(at: 1))) ?? 0
            let contentStart = match.range.location + match.range.length
            let contentEnd = index + 1 < syncs.count ? syncs[index + 1].range.location : nsText.length
            let content = nsText.substring(with: NSRange(location: contentStart, length: contentEnd - contentStart))

            var byClass: [String: String] = [:]
            let nsContent = content as NSString
            let paragraphs = paragraphRegex.matches(in: content, range: NSRange(location: 0, length: nsContent.length))
            if paragraphs.isEmpty {
                byClass[""] = content
            }
            for (pIndex, paragraph) in paragraphs.enumerated() {
                let attributes = nsContent.substring(with: paragraph.range(at: 1))
                let className = classRegex.firstMatch(in: attributes, range: NSRange(location: 0, length: (attributes as NSString).length))
                    .map { (attributes as NSString).substring(with: $0.range(at: 1)) } ?? ""
                let bodyStart = paragraph.range.location + paragraph.range.length
                let bodyEnd = pIndex + 1 < paragraphs.count ? paragraphs[pIndex + 1].range.location : nsContent.length
                byClass[className] = nsContent.substring(with: NSRange(location: bodyStart, length: bodyEnd - bodyStart))
                if !classOrder.contains(className) { classOrder.append(className) }
            }
            entries.append((start / 1000, byClass))
        }

        // 한국어 자막(KRCC 등)을 우선, 없으면 처음 나온 언어
        let preferred = classOrder.first { $0.uppercased().contains("KR") || $0.uppercased().contains("KO") } ?? classOrder.first ?? ""

        var cues: [SubtitleCue] = []
        for (index, entry) in entries.enumerated() {
            guard let raw = entry.byClass[preferred] ?? entry.byClass[""] else { continue }
            let body = clean(raw)
            guard !body.isEmpty else { continue }
            let end = index + 1 < entries.count ? entries[index + 1].start : entry.start + 5
            cues.append(SubtitleCue(start: entry.start, end: end, text: body))
        }
        return cues.sorted { $0.start < $1.start }
    }

    // MARK: - 공통

    /// 태그 제거, 줄바꿈·HTML 엔티티 처리
    private static func clean(_ raw: String) -> String {
        var text = raw.replacingOccurrences(of: #"<br\s*/?>"#, with: "\n", options: [.regularExpression, .caseInsensitive])
        text = text.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: #"\{\\[^}]*\}"#, with: "", options: .regularExpression)
        let entities = ["&nbsp;": " ", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#39;": "'", "&amp;": "&"]
        for (entity, value) in entities {
            text = text.replacingOccurrences(of: entity, with: value, options: .caseInsensitive)
        }
        return text
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }
}
