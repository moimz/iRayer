import Foundation

/// DASH 목록(MPD)에서 감지 목록 정리에 필요한 것만 읽는다: 조각 주소가 시작하는 곳(BaseURL·SegmentTemplate·SegmentList)과 DRM 여부.
/// 조각을 받지는 않는다 (DASH 는 재생하며 받기로 받는다).
struct DASHManifest {
    /// 이 주소들로 시작하는 파일은 이 목록의 조각이다 (감지 목록에서 숨긴다)
    var segmentPrefixes: Set<String> = []
    /// ContentProtection 이 있으면 DRM (Widevine·PlayReady 등) — 받을 수 없다
    var hasDRM = false
    var isLive = false

    static func parse(_ data: Data, url: URL) -> DASHManifest? {
        let reader = Reader()
        let parser = XMLParser(data: data)
        parser.delegate = reader
        guard parser.parse(), reader.sawMPD else { return nil }
        var manifest = DASHManifest(hasDRM: reader.hasDRM, isLive: reader.isLive)
        // 조각은 보통 목록이 있는 폴더 아래, 또는 BaseURL 아래에 있다
        let folder = url.deletingLastPathComponent()
        var bases = [folder]
        bases += reader.baseURLs.compactMap { URL(string: $0, relativeTo: url)?.absoluteURL }
        for base in bases {
            manifest.segmentPrefixes.insert(base.absoluteString)
            for template in reader.templates {
                // "$RepresentationID$/seg-$Number$.m4s" → "$" 앞까지를 시작으로
                let head = String(template.prefix { $0 != "$" })
                if !head.isEmpty, let prefix = URL(string: head, relativeTo: base)?.absoluteString {
                    manifest.segmentPrefixes.insert(prefix)
                }
            }
        }
        return manifest
    }

    private final class Reader: NSObject, XMLParserDelegate {
        var sawMPD = false
        var hasDRM = false
        var isLive = false
        var baseURLs: [String] = []
        var templates: [String] = []
        private var text = ""
        private var inBaseURL = false

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?,
                    attributes: [String: String] = [:]) {
            let local = name.split(separator: ":").last.map(String.init) ?? name
            switch local {
            case "MPD":
                sawMPD = true
                isLive = attributes["type"] == "dynamic"
            case "ContentProtection":
                hasDRM = true
            case "BaseURL":
                inBaseURL = true
                text = ""
            case "SegmentTemplate":
                templates += [attributes["media"], attributes["initialization"]].compactMap { $0 }
            case "SegmentURL":
                templates += [attributes["media"]].compactMap { $0 }
            case "Initialization":
                templates += [attributes["sourceURL"]].compactMap { $0 }
            default:
                break
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            if inBaseURL { text += string }
        }

        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            if name.hasSuffix("BaseURL") {
                inBaseURL = false
                let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !value.isEmpty { baseURLs.append(value) }
            }
        }
    }
}
