import Foundation

/// HLS 재생 목록 (RFC 8216) 해석. 마스터 목록(화질별 목록·소리 트랙)과 미디어 목록(조각) 둘 다.
enum HLSPlaylist: Equatable {
    case master(variants: [Variant], audio: [Rendition])
    case media(Media)

    struct Variant: Equatable {
        let url: URL
        let bandwidth: Int
        let width: Int?
        let height: Int?
        let codecs: String?
        /// EXT-X-MEDIA TYPE=AUDIO 의 GROUP-ID (따로 있는 소리 트랙)
        let audioGroup: String?
    }

    struct Rendition: Equatable {
        let groupID: String
        let url: URL?
        let isDefault: Bool
        let language: String?
        let name: String?
    }

    struct Media: Equatable {
        let segments: [Segment]
        /// EXT-X-ENDLIST 가 없으면 라이브 (목록이 계속 늘어난다)
        let isLive: Bool
        let targetDuration: Double
        /// AES-128 이 아닌 암호(SAMPLE-AES 등 = DRM)가 있다
        let hasDRM: Bool
        var duration: Double { segments.reduce(0) { $0 + $1.duration } }
    }

    struct Segment: Equatable {
        let url: URL
        let duration: Double
        /// 미디어 순번 (IV 가 없을 때 IV 로 쓴다)
        let sequence: Int
        let byteRange: ByteRange?
        let key: Key?
        /// fMP4 초기화 조각 (EXT-X-MAP)
        let map: Map?
    }

    struct ByteRange: Equatable {
        let length: Int64
        let offset: Int64
        var header: String { "bytes=\(offset)-\(offset + length - 1)" }
    }

    struct Key: Equatable {
        /// AES-128 만 푼다
        let url: URL
        let iv: Data?
    }

    struct Map: Equatable {
        let url: URL
        let byteRange: ByteRange?
    }

    /// 목록 글을 해석한다 (#EXTM3U 가 아니면 nil)
    static func parse(_ text: String, base: URL) -> HLSPlaylist? {
        let lines = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
        guard lines.first?.hasPrefix("#EXTM3U") == true else { return nil }
        if lines.contains(where: { $0.hasPrefix("#EXT-X-STREAM-INF") }) {
            return parseMaster(lines, base: base)
        }
        return .media(parseMedia(lines, base: base))
    }

    private static func parseMaster(_ lines: [String], base: URL) -> HLSPlaylist {
        var variants: [Variant] = []
        var audio: [Rendition] = []
        var pending: [String: String]?
        for line in lines {
            if line.hasPrefix("#EXT-X-STREAM-INF:") {
                pending = attributes(line)
            } else if line.hasPrefix("#EXT-X-MEDIA:") {
                let a = attributes(line)
                guard a["TYPE"] == "AUDIO", let group = a["GROUP-ID"] else { continue }
                audio.append(Rendition(groupID: group, url: a["URI"].flatMap { URL(string: $0, relativeTo: base)?.absoluteURL },
                                       isDefault: a["DEFAULT"] == "YES", language: a["LANGUAGE"], name: a["NAME"]))
            } else if let a = pending, !line.hasPrefix("#"), !line.isEmpty, let url = URL(string: line, relativeTo: base)?.absoluteURL {
                let size = a["RESOLUTION"]?.split(separator: "x").compactMap { Int($0) }
                variants.append(Variant(url: url, bandwidth: Int(a["BANDWIDTH"] ?? "") ?? 0,
                                        width: size?.count == 2 ? size?[0] : nil, height: size?.count == 2 ? size?[1] : nil,
                                        codecs: a["CODECS"], audioGroup: a["AUDIO"]))
                pending = nil
            }
        }
        return .master(variants: variants, audio: audio)
    }

    private static func parseMedia(_ lines: [String], base: URL) -> Media {
        var segments: [Segment] = []
        var sequence = 0
        var duration = 0.0
        var target = 0.0
        var isLive = true
        var hasDRM = false
        var key: Key?
        var map: Map?
        var range: ByteRange?
        /// BYTERANGE 에 시작이 없으면 앞 조각이 끝난 곳부터
        var nextOffset: [URL: Int64] = [:]
        var pendingRange: (length: Int64, offset: Int64?)?
        for line in lines {
            if line.hasPrefix("#EXT-X-MEDIA-SEQUENCE:") {
                sequence = Int(line.dropFirst(22)) ?? 0
            } else if line.hasPrefix("#EXT-X-TARGETDURATION:") {
                target = Double(line.dropFirst(22)) ?? 0
            } else if line.hasPrefix("#EXT-X-ENDLIST") {
                isLive = false
            } else if line.hasPrefix("#EXT-X-PLAYLIST-TYPE:VOD") {
                isLive = false
            } else if line.hasPrefix("#EXTINF:") {
                duration = Double(line.dropFirst(8).split(separator: ",").first ?? "") ?? 0
            } else if line.hasPrefix("#EXT-X-KEY:") {
                let a = attributes(line)
                switch a["METHOD"] {
                case "NONE", nil:
                    key = nil
                case "AES-128":
                    if let uri = a["URI"], let url = URL(string: uri, relativeTo: base)?.absoluteURL {
                        key = Key(url: url, iv: a["IV"].flatMap(hexData))
                    }
                default:
                    // SAMPLE-AES·SAMPLE-AES-CTR 등은 DRM (FairPlay·Widevine)
                    hasDRM = true
                }
            } else if line.hasPrefix("#EXT-X-MAP:") {
                let a = attributes(line)
                if let uri = a["URI"], let url = URL(string: uri, relativeTo: base)?.absoluteURL {
                    let r = a["BYTERANGE"].flatMap { byteRange($0) }.map { ByteRange(length: $0.length, offset: $0.offset ?? 0) }
                    map = Map(url: url, byteRange: r)
                }
            } else if line.hasPrefix("#EXT-X-BYTERANGE:") {
                pendingRange = byteRange(String(line.dropFirst(17)))
            } else if !line.hasPrefix("#"), !line.isEmpty, let url = URL(string: line, relativeTo: base)?.absoluteURL {
                if let pr = pendingRange {
                    let offset = pr.offset ?? nextOffset[url] ?? 0
                    range = ByteRange(length: pr.length, offset: offset)
                    nextOffset[url] = offset + pr.length
                } else {
                    range = nil
                }
                segments.append(Segment(url: url, duration: duration, sequence: sequence, byteRange: range, key: key, map: map))
                sequence += 1
                pendingRange = nil
                duration = 0
            }
        }
        return Media(segments: segments, isLive: isLive, targetDuration: target, hasDRM: hasDRM)
    }

    /// 'A=1,B="x,y",C=0x12' → 사전 (따옴표 안의 쉼표는 나누지 않는다)
    static func attributes(_ line: String) -> [String: String] {
        guard let colon = line.firstIndex(of: ":") else { return [:] }
        var result: [String: String] = [:]
        var name = "", value = "", inName = true, quoted = false
        func flush() {
            if !name.isEmpty { result[name.trimmingCharacters(in: .whitespaces)] = value }
            name = ""; value = ""; inName = true
        }
        for c in line[line.index(after: colon)...] {
            if inName {
                if c == "=" { inName = false } else if c != "," { name.append(c) }
            } else if c == "\"" {
                quoted.toggle()
            } else if c == ",", !quoted {
                flush()
            } else {
                value.append(c)
            }
        }
        flush()
        return result
    }

    /// "길이[@시작]"
    private static func byteRange(_ text: String) -> (length: Int64, offset: Int64?)? {
        let parts = text.split(separator: "@")
        guard let length = Int64(parts.first ?? "") else { return nil }
        return (length, parts.count > 1 ? Int64(parts[1]) : nil)
    }

    /// "0x0123…" → 16바이트
    private static func hexData(_ text: String) -> Data? {
        var hex = text.lowercased()
        if hex.hasPrefix("0x") { hex.removeFirst(2) }
        guard hex.count == 32 else { return nil }
        var data = Data(capacity: 16)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            data.append(byte)
            index = next
        }
        return data
    }
}

extension HLSPlaylist.Variant {
    /// 화질 이름 ("1080p", 모르면 비트레이트)
    var label: String {
        if let height { return "\(height)p" }
        return "\(bandwidth / 1000)kbps"
    }
}

extension Array where Element == HLSPlaylist.Variant {
    /// 가장 좋은 화질: 해상도(높이) → 비트레이트 순
    var best: HLSPlaylist.Variant? {
        self.max { ($0.height ?? 0, $0.bandwidth) < ($1.height ?? 0, $1.bandwidth) }
    }
}
