import Foundation

/// 파일 바이트 위치 → 영상 시각 표 (버퍼 막대용, 2026-11-28 사용자: 앞으로 탐색하다 보면 버퍼 막대가 안 보임).
/// 버퍼는 바이트로 받는데 재생 막대는 시간이라, 받아 둔 끝 바이트를 파일 크기로 나눠 그리면 지나온 부분이 평균보다 가벼운
/// 영상(가변 비트레이트)에서 바이트 비율이 시간 비율보다 뒤처져 막대가 재생 위치 밑에 묻혔다. 평균 비트레이트로 나눠도 가변이면 어긋난다.
/// 그래서 파일의 목차로 정확히 바꾼다: MP4 는 moov 의 덩어리 위치·시각, MKV 는 Cues(키프레임마다 클러스터 위치·시각).
/// 목차는 VLC 가 재생을 시작하며 이미 읽어 간 것을 DirectReader 에서 꺼내 쓴다 (NAS 에 따로 요청하지 않음).
nonisolated struct ByteTimeline: Sendable {
    enum Kind: Sendable {
        case mp4, matroska

        var name: String {
            switch self {
            case .mp4: "MP4 목차"
            case .matroska: "MKV Cues"
            }
        }
    }

    let kind: Kind
    /// 트랙마다 (위치, 시각) — 위치 순
    private let tables: [[(offset: Int64, time: Double)]]

    /// 이 바이트 앞까지 받아 두었을 때 끊김 없이 재생할 수 있는 시각. 트랙(영상·소리)마다 받아 둔 끝 시각 중 가장 이른 것
    func time(atByte byte: Int64) -> Double {
        tables.map { table -> Double in
            var low = 0, high = table.count
            while low < high {
                let mid = (low + high) / 2
                if table[mid].offset <= byte { low = mid + 1 } else { high = mid }
            }
            return low == 0 ? 0 : table[low - 1].time
        }.min() ?? 0
    }

    /// 범위 읽기 (받아 둔 것만, 없으면 throw)
    typealias Reader = MP4Interleave.Reader

    static func kind(for file: VideoFile) -> Kind? {
        if file.isMP4Family { return .mp4 }
        let ext = (file.name as NSString).pathExtension.lowercased()
        return ["mkv", "webm", "mka"].contains(ext) ? .matroska : nil
    }

    static func load(_ kind: Kind, size: Int64, read: Reader) async -> ByteTimeline? {
        switch kind {
        case .mp4:
            guard let tables = await MP4Interleave.chunkTables(size: size, read: read) else { return nil }
            return ByteTimeline(kind: .mp4, tables: tables.map { $0.sorted { $0.offset < $1.offset } })
        case .matroska:
            guard let table = try? await matroskaCues(size: size, read: read), table.count > 1 else { return nil }
            return ByteTimeline(kind: .matroska, tables: [table])
        }
    }

    // MARK: - MKV

    private static let segmentID = 0x18538067
    private static let seekHeadID = 0x114D9B74
    private static let infoID = 0x1549A966
    private static let cuesID = 0x1C53BB6B
    private static let clusterID = 0x1F43B675

    /// MKV 의 Cues → (클러스터 파일 위치, 시각) 표
    private static func matroskaCues(size: Int64, read: Reader) async throws -> [(offset: Int64, time: Double)]? {
        // EBML 머리 다음이 Segment
        let first = try await read(0..<min(64, size))
        guard let ebml = Element(first, at: 0), ebml.id == 0x1A45DFA3, let ebmlSize = ebml.size else { return nil }
        let segmentAt = Int64(ebml.headerLength) + ebmlSize
        let segmentHead = try await read(segmentAt..<min(segmentAt + 16, size))
        guard let segment = Element(segmentHead, at: 0), segment.id == segmentID else { return nil }
        let segmentStart = segmentAt + Int64(segment.headerLength)

        // Segment 안의 맨 위 요소들: 목차 위치(SeekHead), 시간 단위(Info), 앞에 있으면 Cues. 클러스터가 나오면 그만
        var timecodeScale: Double = 1_000_000
        var cuesAt: Int64?
        var offset = segmentStart
        for _ in 0..<32 {
            guard offset + 2 < size else { break }
            let head = try await read(offset..<min(offset + 16, size))
            guard let element = Element(head, at: 0), let length = element.size else { break }
            let body = offset + Int64(element.headerLength)
            switch element.id {
            case seekHeadID where length < 1 << 20:
                let data = try await read(body..<body + length)
                for seek in children(data) where seek.id == 0x4DBB {
                    let fields = children(data, seek.range)
                    guard let id = fields.first(where: { $0.id == 0x53AB }), let position = fields.first(where: { $0.id == 0x53AC }) else { continue }
                    if uint(data, id.range) == cuesID { cuesAt = segmentStart + Int64(uint(data, position.range)) }
                }
            case infoID where length < 1 << 20:
                let data = try await read(body..<body + length)
                if let scale = children(data).first(where: { $0.id == 0x2AD7B1 }) { timecodeScale = Double(uint(data, scale.range)) }
            case cuesID:
                cuesAt = offset
            case clusterID:
                break
            default:
                break
            }
            if element.id == clusterID || cuesAt == offset { break }
            offset = body + length
        }

        guard let cuesAt, timecodeScale > 0 else { return nil }
        let head = try await read(cuesAt..<min(cuesAt + 16, size))
        guard let cues = Element(head, at: 0), cues.id == cuesID, let length = cues.size, length < 64 << 20 else { return nil }
        let start = cuesAt + Int64(cues.headerLength)
        let data = try await read(start..<start + length)
        var table: [(offset: Int64, time: Double)] = []
        for point in children(data) where point.id == 0xBB {
            let fields = children(data, point.range)
            guard let time = fields.first(where: { $0.id == 0xB3 }) else { continue }
            let positions = fields.filter { $0.id == 0xB7 }.compactMap { track in
                children(data, track.range).first { $0.id == 0xF1 }.map { Int64(uint(data, $0.range)) }
            }
            guard let position = positions.min() else { continue }
            table.append((segmentStart + position, Double(uint(data, time.range)) * timecodeScale / 1_000_000_000))
        }
        return table.sorted { $0.offset < $1.offset }
    }

    /// EBML 요소 머리 (ID, 내용 크기)
    private struct Element {
        let id: Int
        /// 크기를 모름(끝까지)이면 nil
        let size: Int64?
        let headerLength: Int
        var range: Range<Int> = 0..<0

        init?(_ data: Data, at index: Int) {
            guard let (id, idLength) = ByteTimeline.vint(data, index, keepMarker: true),
                  let (size, sizeLength) = ByteTimeline.vint(data, index + idLength, keepMarker: false) else { return nil }
            self.id = id
            let allOnes = (1 << (7 * sizeLength)) - 1
            self.size = size == allOnes ? nil : Int64(size)
            headerLength = idLength + sizeLength
        }
    }

    /// 가변 길이 정수 (ID 는 표시 비트를 남기고, 크기는 뺀다)
    private static func vint(_ data: Data, _ index: Int, keepMarker: Bool) -> (Int, Int)? {
        guard index < data.count else { return nil }
        let first = Int(data[data.startIndex + index])
        guard first != 0 else { return nil }
        let length = first.leadingZeroBitCount - (Int.bitWidth - 8) + 1
        guard length <= 8, index + length <= data.count else { return nil }
        var value = keepMarker ? first : first & ((1 << (8 - length)) - 1)
        for i in 1..<length { value = value << 8 | Int(data[data.startIndex + index + i]) }
        return (value, length)
    }

    /// range 안의 요소들
    private static func children(_ data: Data, _ range: Range<Int>? = nil) -> [Element] {
        let range = range ?? 0..<data.count
        var out: [Element] = []
        var index = range.lowerBound
        while index < range.upperBound, var element = Element(data, at: index), let size = element.size {
            let start = index + element.headerLength
            let end = start + Int(size)
            guard end <= range.upperBound else { break }
            element.range = start..<end
            out.append(element)
            index = end
        }
        return out
    }

    private static func uint(_ data: Data, _ range: Range<Int>) -> Int {
        guard range.count <= 8 else { return 0 }
        return range.reduce(0) { $0 << 8 | Int(data[data.startIndex + $1]) }
    }
}
