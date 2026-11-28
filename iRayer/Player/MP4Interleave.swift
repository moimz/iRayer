import Foundation

/// MP4·MOV 의 목차(moov)만 읽어, 같은 순간의 소리와 영상이 파일 안에서 얼마나 떨어져 있는지 잰다 (2026-11-10, 사용자).
/// 보통 파일은 0.5~1초씩 번갈아 저장(인터리빙)하지만, 소리를 몇 분씩 앞서 저장한 파일(Non-Interleaved)은
/// 네트워크로 재생할 때 파일의 먼 두 곳을 번갈아 읽어야 한다. 파일 정보의 오디오 코덱 뒤에 * 로 표시한다.
nonisolated enum MP4Interleave {
    /// 이만큼(초) 넘게 어긋나면 Non-Interleaved 로 본다
    static let threshold: Double = 5

    /// 범위 읽기 (WebDAV·SMB·로컬 파일 공통)
    typealias Reader = @Sendable (Range<Int64>) async throws -> Data

    /// 소리·영상의 최대 어긋남 (초). MP4 가 아니거나 목차를 못 읽으면 nil
    static func skew(size: Int64, read: Reader) async -> Double? {
        guard let moov = try? await findMoov(size: size, read: read) else { return nil }
        let tracks = parseTracks(moov)
        guard let video = tracks.first(where: { $0.kind == "vide" }), let audio = tracks.first(where: { $0.kind == "soun" }),
              !video.chunks.isEmpty, !audio.chunks.isEmpty else { return nil }
        // 소리 덩어리마다, 파일에서 바로 앞에 있는 영상 덩어리와 시각을 비교한다
        let videoOffsets = video.chunks.map(\.offset)
        var worst: Double = 0
        for chunk in audio.chunks {
            var low = 0, high = videoOffsets.count
            while low < high {
                let mid = (low + high) / 2
                if videoOffsets[mid] <= chunk.offset { low = mid + 1 } else { high = mid }
            }
            let near = video.chunks[max(low - 1, 0)]
            worst = max(worst, abs(chunk.time - near.time))
        }
        return worst
    }

    /// 트랙(영상·소리)마다 덩어리의 (파일 위치, 시각) 표. 버퍼 막대의 바이트→시간 표용 (2026-11-28, ByteTimeline)
    static func chunkTables(size: Int64, read: Reader) async -> [[(offset: Int64, time: Double)]]? {
        guard let moov = try? await findMoov(size: size, read: read) else { return nil }
        let tables = parseTracks(moov).map { $0.chunks.map { (offset: $0.offset, time: $0.time) } }.filter { !$0.isEmpty }
        return tables.isEmpty ? nil : tables
    }

    // MARK: - 목차 찾기

    /// 맨 위 상자들을 따라가며 moov 를 찾아 통째로 읽는다 (앞에 있으면 한두 번, 뒤에 있으면 mdat 를 건너뛰어)
    private static func findMoov(size: Int64, read: Reader) async throws -> Data? {
        var offset: Int64 = 0
        for _ in 0..<32 {
            guard offset + 8 <= size else { return nil }
            let header = try await read(offset..<min(offset + 16, size))
            guard header.count >= 8 else { return nil }
            var boxSize = Int64(header.uint32(at: 0))
            let type = header.fourCC(at: 4)
            var headerSize: Int64 = 8
            if boxSize == 1 {
                guard header.count >= 16 else { return nil }
                boxSize = Int64(header.uint64(at: 8))
                headerSize = 16
            } else if boxSize == 0 {
                boxSize = size - offset
            }
            guard boxSize >= headerSize else { return nil }
            if type == "moov" {
                // 목차가 이상하게 크면 읽지 않는다
                guard boxSize <= 64 << 20, offset + boxSize <= size else { return nil }
                let data = try await read(offset + headerSize..<offset + boxSize)
                return data.count == Int(boxSize - headerSize) ? data : nil
            }
            offset += boxSize
        }
        return nil
    }

    // MARK: - 트랙 해석

    private struct Chunk {
        let offset: Int64
        let time: Double
    }

    private struct Track {
        var kind = ""
        var timescale: UInt32 = 0
        var chunks: [Chunk] = []
    }

    private static func parseTracks(_ moov: Data) -> [Track] {
        boxes(in: moov, 0..<moov.count).filter { $0.type == "trak" }.compactMap { trak in
            parseTrack(moov, trak.body)
        }
    }

    private static func parseTrack(_ data: Data, _ range: Range<Int>) -> Track? {
        guard let mdia = boxes(in: data, range).first(where: { $0.type == "mdia" })?.body else { return nil }
        let mdiaBoxes = boxes(in: data, mdia)
        var track = Track()
        if let hdlr = mdiaBoxes.first(where: { $0.type == "hdlr" })?.body, hdlr.count >= 12 {
            track.kind = data.fourCC(at: hdlr.lowerBound + 8)
        }
        if let mdhd = mdiaBoxes.first(where: { $0.type == "mdhd" })?.body, mdhd.count >= 24 {
            let version = data[data.startIndex + mdhd.lowerBound]
            track.timescale = data.uint32(at: mdhd.lowerBound + (version == 1 ? 20 : 12))
        }
        guard track.kind == "vide" || track.kind == "soun", track.timescale > 0,
              let minf = mdiaBoxes.first(where: { $0.type == "minf" })?.body,
              let stbl = boxes(in: data, minf).first(where: { $0.type == "stbl" })?.body else { return nil }
        let stblBoxes = boxes(in: data, stbl)
        func body(_ type: String) -> Range<Int>? { stblBoxes.first { $0.type == type }?.body }

        // 덩어리 위치 (stco 32비트, co64 64비트)
        var offsets: [Int64] = []
        if let stco = body("stco") {
            let count = Int(data.uint32(at: stco.lowerBound + 4))
            guard stco.lowerBound + 8 + count * 4 <= stco.upperBound else { return nil }
            offsets = (0..<count).map { Int64(data.uint32(at: stco.lowerBound + 8 + $0 * 4)) }
        } else if let co64 = body("co64") {
            let count = Int(data.uint32(at: co64.lowerBound + 4))
            guard co64.lowerBound + 8 + count * 8 <= co64.upperBound else { return nil }
            offsets = (0..<count).map { Int64(data.uint64(at: co64.lowerBound + 8 + $0 * 8)) }
        }
        guard !offsets.isEmpty, let stsc = body("stsc"), let stts = body("stts") else { return nil }

        // 덩어리마다 첫 샘플 번호 (stsc: 첫 덩어리 번호, 덩어리당 샘플 수)
        let stscCount = Int(data.uint32(at: stsc.lowerBound + 4))
        guard stsc.lowerBound + 8 + stscCount * 12 <= stsc.upperBound, stscCount > 0 else { return nil }
        var firstSamples: [Int64] = []
        firstSamples.reserveCapacity(offsets.count)
        var sample: Int64 = 0
        for entry in 0..<stscCount {
            let base = stsc.lowerBound + 8 + entry * 12
            let firstChunk = Int(data.uint32(at: base)) - 1
            let perChunk = Int64(data.uint32(at: base + 4))
            let nextChunk = entry + 1 < stscCount ? Int(data.uint32(at: base + 12)) - 1 : offsets.count
            guard firstChunk >= firstSamples.count else { continue }
            for _ in firstChunk..<max(firstChunk, min(nextChunk, offsets.count)) {
                firstSamples.append(sample)
                sample += perChunk
            }
        }
        guard firstSamples.count == offsets.count else { return nil }

        // 샘플 번호 → 시각 (stts: 샘플 수, 샘플 길이)
        let sttsCount = Int(data.uint32(at: stts.lowerBound + 4))
        guard stts.lowerBound + 8 + sttsCount * 8 <= stts.upperBound else { return nil }
        var entry = 0, entryStart: Int64 = 0, entryTime: Int64 = 0
        let scale = Double(track.timescale)
        for (index, first) in firstSamples.enumerated() {
            while entry < sttsCount {
                let count = Int64(data.uint32(at: stts.lowerBound + 8 + entry * 8))
                let delta = Int64(data.uint32(at: stts.lowerBound + 12 + entry * 8))
                if first < entryStart + count { break }
                entryStart += count
                entryTime += count * delta
                entry += 1
            }
            let delta = entry < sttsCount ? Int64(data.uint32(at: stts.lowerBound + 12 + entry * 8)) : 0
            let time = Double(entryTime + (first - entryStart) * delta) / scale
            track.chunks.append(Chunk(offset: offsets[index], time: time))
        }
        track.chunks.sort { $0.offset < $1.offset }
        return track
    }

    /// range 안의 상자들 (종류와 내용 범위)
    private static func boxes(in data: Data, _ range: Range<Int>) -> [(type: String, body: Range<Int>)] {
        var result: [(String, Range<Int>)] = []
        var offset = range.lowerBound
        while offset + 8 <= range.upperBound {
            var size = Int(data.uint32(at: offset))
            var header = 8
            if size == 1, offset + 16 <= range.upperBound {
                size = Int(data.uint64(at: offset + 8))
                header = 16
            } else if size == 0 {
                size = range.upperBound - offset
            }
            guard size >= header, offset + size <= range.upperBound else { break }
            result.append((data.fourCC(at: offset + 4), offset + header..<offset + size))
            offset += size
        }
        return result
    }
}

nonisolated private extension Data {
    func uint32(at index: Int) -> UInt32 {
        let i = startIndex + index
        return UInt32(self[i]) << 24 | UInt32(self[i + 1]) << 16 | UInt32(self[i + 2]) << 8 | UInt32(self[i + 3])
    }

    func uint64(at index: Int) -> UInt64 {
        UInt64(uint32(at: index)) << 32 | UInt64(uint32(at: index + 4))
    }

    func fourCC(at index: Int) -> String {
        let i = startIndex + index
        return String(decoding: self[i..<i + 4], as: UTF8.self)
    }
}
