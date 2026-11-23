import Foundation

/// 재생 버퍼(MSE)에 들어온 fMP4 데이터를 상자 단위로 읽어 색인을 만든다 (재생하며 받기).
/// 들어온 순서 그대로 트랙 파일에 쓰되, 초기화 조각(ftyp+moov)과 미디어 조각(moof+mdat)의 자리·시각을 적어 두고,
/// 저장할 때 시각 순으로 정렬하고 겹치는 조각을 버려 다시 쓴다 — 앞뒤로 건너뛰거나 플레이어가 같은 조각을 다시 넣어도 순서가 꼬이지 않는다.
/// fMP4 가 아니면(WebM·TS 를 넣는 플레이어) 색인을 포기하고 들어온 순서 그대로 쓴다.
/// 쓰기는 쓰기 큐에서, 받은 구간 읽기는 메인에서 — 잠금으로 지킨다.
final class FMP4Index: @unchecked Sendable {
    private let lock = NSLock()

    /// 초기화 조각 (ftyp 부터 moov 끝까지)
    struct Init: Equatable {
        let range: Range<Int64>
        /// 내용이 같은 초기화 조각끼리 같은 번호 (화질·코덱이 바뀌면 새 번호)
        let number: Int
        /// track_ID → 시간 단위 (mdhd timescale)
        let timescales: [UInt32: UInt32]
        /// track_ID → 기본 표본 길이 (mvex/trex, trun·tfhd 에 없을 때)
        let defaultDurations: [UInt32: UInt32]
        /// 영상 크기 (tkhd 의 폭·높이, 영상 트랙이 있으면)
        let height: Int?
    }

    /// 미디어 조각 (moof 부터 mdat 끝까지)
    struct Fragment {
        let range: Range<Int64>
        /// 이 조각이 따르는 초기화 조각 번호
        let initNumber: Int
        /// 시작·길이 (초)
        let start: Double
        let duration: Double
        /// 들어온 차례 (시각이 같으면 먼저 들어온 것)
        let order: Int
        var end: Double { start + duration }
    }

    private(set) var inits: [Init] = []
    private(set) var fragments: [Fragment] = []
    /// fMP4 로 읽을 수 없는 데이터 (들어온 순서 그대로 쓴다)
    private(set) var unreadable = false

    /// 아직 상자 하나가 다 안 들어와 남겨 둔 것과 그 시작 자리
    private var pending = Data()
    private var pendingOffset: Int64 = 0
    private var initStart: Int64?
    private var initContents: [Data] = []
    private var currentInit: Int?
    private var moof: (offset: Int64, start: Double, duration: Double)?
    private var written: Int64 = 0

    /// 트랙 파일 끝에 붙여 쓴 데이터를 읽는다
    func feed(_ data: Data) {
        lock.lock()
        defer { lock.unlock() }
        guard !unreadable else { return }
        if pending.isEmpty { pendingOffset = written }
        pending.append(data)
        written += Int64(data.count)
        var cursor = 0
        while pending.count - cursor >= 8 {
            let header = pending.subdata(in: pending.startIndex + cursor ..< pending.startIndex + cursor + 8)
            var size = Int64(Self.uint32(header, 0))
            let type = String(decoding: header[header.startIndex + 4 ..< header.startIndex + 8], as: UTF8.self)
            var headerSize = 8
            if size == 1 {
                guard pending.count - cursor >= 16 else { break }
                size = Int64(Self.uint64(pending, cursor + 8))
                headerSize = 16
            }
            guard size >= Int64(headerSize), Self.knownTopLevel.contains(type) else {
                unreadable = true
                pending = Data()
                return
            }
            guard Int64(pending.count - cursor) >= size else { break }
            let offset = pendingOffset + Int64(cursor)
            let body = pending.subdata(in: pending.startIndex + cursor + headerSize ..< pending.startIndex + cursor + Int(size))
            handle(type: type, offset: offset, size: size, body: body)
            cursor += Int(size)
        }
        pending = pending.subdata(in: pending.startIndex + cursor ..< pending.endIndex)
        pendingOffset += Int64(cursor)
    }

    private static let knownTopLevel: Set<String> = ["ftyp", "styp", "moov", "moof", "mdat", "sidx", "emsg", "prft", "free", "skip", "uuid", "mfra", "meta"]

    private func handle(type: String, offset: Int64, size: Int64, body: Data) {
        switch type {
        case "ftyp":
            initStart = offset
        case "moov":
            let start = initStart ?? offset
            initStart = nil
            let content = body
            let number = initContents.firstIndex(of: content) ?? {
                initContents.append(content)
                return initContents.count - 1
            }()
            currentInit = number
            let info = Self.parseMoov(body)
            inits.append(Init(range: start ..< offset + size, number: number, timescales: info.timescales,
                              defaultDurations: info.defaults, height: info.height))
        case "moof":
            guard let initNumber = currentInit, let info = inits.last(where: { $0.number == initNumber }) else { return }
            let timing = Self.parseMoof(body, timescales: info.timescales, defaults: info.defaultDurations)
            moof = (offset, timing.start, timing.duration)
        case "mdat":
            guard let moof, let initNumber = currentInit else { return }
            fragments.append(Fragment(range: moof.offset ..< offset + size, initNumber: initNumber,
                                      start: moof.start, duration: moof.duration, order: fragments.count))
            self.moof = nil
        default:
            break
        }
    }

    // MARK: - 저장용

    /// 가장 높은 화질 (영상 트랙의 초기화 조각 높이 중 최대, 소리만이면 nil)
    private var bestHeight: Int? { inits.compactMap(\.height).max() }

    /// 가장 높은 화질의 조각인지 (화질을 모르면 모두)
    private func isBest(_ fragment: Fragment) -> Bool {
        guard let best = bestHeight else { return true }
        return inits.first { $0.number == fragment.initNumber }?.height == best
    }

    /// 받은 구간 (겹친 것은 합침). 가장 높은 화질의 조각만 센다 — 낮은 화질로 받은 곳은 빈 구간으로 보아 다시 받게 한다
    var covered: [ClosedRange<Double>] {
        lock.lock()
        defer { lock.unlock() }
        var result: [ClosedRange<Double>] = []
        for fragment in fragments.filter(isBest).sorted(by: { $0.start < $1.start }) {
            if let last = result.last, fragment.start <= last.upperBound + 0.1 {
                result[result.count - 1] = last.lowerBound ... max(last.upperBound, fragment.end)
            } else {
                result.append(fragment.start ... fragment.end)
            }
        }
        return result
    }

    /// 시각 순으로 정렬하고 겹친 조각을 뺀 차례. 가장 높은 화질 조각이 먼저 자리를 잡고, 그래도 빈 곳만 낮은 화질로 채운다
    /// (같은 화질에서 시각이 같으면 먼저 들어온 것)
    func ordered() -> [Fragment] {
        var result: [Fragment] = []
        var end = -Double.infinity
        let best = fragments.filter(isBest)
        let bestRanges = best.map { $0.start ... $0.end }
        // 낮은 화질 조각은 높은 화질 조각과 절반 넘게 겹치지 않을 때만
        let lower = fragments.filter { fragment in
            !isBest(fragment) && !bestRanges.contains { min($0.upperBound, fragment.end) - max($0.lowerBound, fragment.start) > fragment.duration / 2 }
        }
        for fragment in (best + lower).sorted(by: { ($0.start, $0.order) < ($1.start, $1.order) }) {
            // 앞 조각과 거의 같은 데서 시작하거나 이미 받은 구간 안이면 버린다 (조각 길이의 절반 넘게 겹치면)
            // 바뀜 (2026-11-09): 이미 받은 구간 안에 다 들어가는 조각도 길이와 상관없이 버린다 — 0.1초보다 짧은 조각(소리 1~2프레임)은
            //   위 조건에 안 걸려, 멈춘 플레이어가 같은 조각을 수천 번 다시 넣은 것이 다 남아 ffmpeg 가 0.6초에 10분치를 몰아 넣었다 (사용자 파일)
            if fragment.start < end - max(0.05, fragment.duration / 2) || fragment.end <= end + 0.01 { continue }
            result.append(fragment)
            end = max(end, fragment.end)
        }
        return result
    }

    /// 들어온 초기화 조각의 내용 (moov 바이트) — 새로고침한 페이지의 트랙이 앞서 받은 트랙과 같은 영상인지 견줄 때 (2026-11-09)
    var initBodies: [Data] {
        lock.lock()
        defer { lock.unlock() }
        return initContents
    }

    /// 지금까지의 초기화 조각·미디어 조각 (여러 트랙을 합칠 때)
    func snapshot() -> (inits: [Init], fragments: [Fragment]) {
        lock.lock()
        defer { lock.unlock() }
        return (inits, fragments)
    }

    /// 여러 트랙(같은 영상의 같은 종류인데 플레이어가 재생 버퍼를 새로 만들어 따로 들어온 것)을 하나로 합쳐 쓴다 (2026-11-07).
    /// 순서·겹침·화질 규칙은 ordered() 와 같다 (가장 높은 화질이 먼저, 시각이 같으면 먼저 들어온 트랙·조각).
    /// 초기화 조각이 바뀌는 곳마다(트랙이 바뀌는 곳 포함) 따로 쓴 파일들을 시각 순으로 돌려준다.
    static func writeMerged(_ parts: [(index: FMP4Index, file: URL)], into folder: URL, name: String) throws -> [URL] {
        let snapshots = parts.map { $0.index.snapshot() }
        let best = snapshots.flatMap { $0.inits.compactMap(\.height) }.max()
        func height(_ part: Int, _ fragment: Fragment) -> Int? {
            snapshots[part].inits.first { $0.number == fragment.initNumber }?.height
        }
        func isBest(_ part: Int, _ fragment: Fragment) -> Bool { best == nil || height(part, fragment) == best }
        let all = snapshots.enumerated().flatMap { part, snapshot in snapshot.fragments.map { (part: part, fragment: $0) } }
        let bestRanges = all.filter { isBest($0.part, $0.fragment) }.map { $0.fragment.start ... $0.fragment.end }
        let candidates = all.filter { entry in
            isBest(entry.part, entry.fragment) || !bestRanges.contains {
                min($0.upperBound, entry.fragment.end) - max($0.lowerBound, entry.fragment.start) > entry.fragment.duration / 2
            }
        }
        let sorted = candidates.sorted { a, b in
            let aBest = isBest(a.part, a.fragment), bBest = isBest(b.part, b.fragment)
            if aBest != bBest, abs(a.fragment.start - b.fragment.start) < 0.05 { return aBest }
            return (a.fragment.start, a.part, a.fragment.order) < (b.fragment.start, b.part, b.fragment.order)
        }
        var chosen: [(part: Int, fragment: Fragment)] = []
        var end = -Double.infinity
        for entry in sorted {
            // 바뀜 (2026-11-09): 이미 받은 구간 안에 다 들어가는 짧은 조각도 버린다 (ordered() 와 같은 까닭)
            if entry.fragment.start < end - max(0.05, entry.fragment.duration / 2) || entry.fragment.end <= end + 0.01 { continue }
            chosen.append(entry)
            end = max(end, entry.fragment.end)
        }

        let inputs = try parts.map { try FileHandle(forReadingFrom: $0.file) }
        defer { inputs.forEach { try? $0.close() } }
        func read(_ part: Int, _ range: Range<Int64>) throws -> Data {
            try inputs[part].seek(toOffset: UInt64(range.lowerBound))
            return try inputs[part].read(upToCount: Int(range.upperBound - range.lowerBound)) ?? Data()
        }
        var outputs: [URL] = []
        var handle: FileHandle?
        var run: (part: Int, initNumber: Int)?
        for entry in chosen {
            if run?.part != entry.part || run?.initNumber != entry.fragment.initNumber {
                try handle?.close()
                handle = nil
                guard let initRange = snapshots[entry.part].inits.first(where: { $0.number == entry.fragment.initNumber })?.range else { continue }
                let url = folder.appending(path: "\(name)-\(outputs.count + 1).mp4")
                FileManager.default.createFile(atPath: url.path, contents: nil)
                handle = try FileHandle(forWritingTo: url)
                try handle?.write(contentsOf: read(entry.part, initRange))
                outputs.append(url)
                run = (entry.part, entry.fragment.initNumber)
            }
            try handle?.write(contentsOf: read(entry.part, entry.fragment.range))
        }
        try handle?.close()
        return outputs
    }

    /// 정렬한 트랙을 파일들로 쓴다: 초기화 조각이 바뀌는 곳마다 따로 (화질이 바뀐 구간). 쓴 파일들을 시각 순으로 돌려준다
    func writeOrdered(from source: URL, into folder: URL, name: String) throws -> [URL] {
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        func read(_ range: Range<Int64>) throws -> Data {
            try input.seek(toOffset: UInt64(range.lowerBound))
            return try input.read(upToCount: Int(range.upperBound - range.lowerBound)) ?? Data()
        }
        var outputs: [URL] = []
        var handle: FileHandle?
        var runInit: Int?
        for fragment in ordered() {
            if fragment.initNumber != runInit {
                try handle?.close()
                guard let initRange = inits.first(where: { $0.number == fragment.initNumber })?.range else { continue }
                let url = folder.appending(path: "\(name)-\(outputs.count + 1).mp4")
                FileManager.default.createFile(atPath: url.path, contents: nil)
                handle = try FileHandle(forWritingTo: url)
                try handle?.write(contentsOf: read(initRange))
                outputs.append(url)
                runInit = fragment.initNumber
            }
            try handle?.write(contentsOf: read(fragment.range))
        }
        try handle?.close()
        return outputs
    }

    // MARK: - 상자 읽기

    private static func uint32(_ data: Data, _ at: Int) -> UInt32 {
        let i = data.startIndex + at
        return UInt32(data[i]) << 24 | UInt32(data[i + 1]) << 16 | UInt32(data[i + 2]) << 8 | UInt32(data[i + 3])
    }

    private static func uint64(_ data: Data, _ at: Int) -> UInt64 {
        UInt64(uint32(data, at)) << 32 | UInt64(uint32(data, at + 4))
    }

    /// 안쪽 상자들 (type, 내용)
    private static func children(_ data: Data) -> [(String, Data)] {
        var result: [(String, Data)] = []
        var cursor = 0
        while data.count - cursor >= 8 {
            var size = Int(uint32(data, cursor))
            let type = String(decoding: data[data.startIndex + cursor + 4 ..< data.startIndex + cursor + 8], as: UTF8.self)
            var header = 8
            if size == 1, data.count - cursor >= 16 { size = Int(uint64(data, cursor + 8)); header = 16 }
            if size == 0 { size = data.count - cursor }
            guard size >= header, cursor + size <= data.count else { break }
            result.append((type, data.subdata(in: data.startIndex + cursor + header ..< data.startIndex + cursor + size)))
            cursor += size
        }
        return result
    }

    /// moov: 트랙마다 timescale (mdhd), 영상 높이 (tkhd)
    private static func parseMoov(_ body: Data) -> (timescales: [UInt32: UInt32], defaults: [UInt32: UInt32], height: Int?) {
        var timescales: [UInt32: UInt32] = [:]
        var defaults: [UInt32: UInt32] = [:]
        var height: Int?
        for (type, mvex) in children(body) where type == "mvex" {
            for (inner, trex) in children(mvex) where inner == "trex" && trex.count >= 24 {
                defaults[uint32(trex, 4)] = uint32(trex, 12)
            }
        }
        for (type, trak) in children(body) where type == "trak" {
            var trackID: UInt32?
            var scale: UInt32?
            for (inner, content) in children(trak) {
                if inner == "tkhd", content.count >= 84 {
                    let version = content[content.startIndex]
                    trackID = uint32(content, version == 1 ? 20 : 12)
                    let h = Int(uint32(content, content.count - 4) >> 16)
                    if h > 0 { height = max(height ?? 0, h) }
                } else if inner == "mdia" {
                    for (m, mdhd) in children(content) where m == "mdhd" && mdhd.count >= 24 {
                        scale = uint32(mdhd, mdhd[mdhd.startIndex] == 1 ? 20 : 12)
                    }
                }
            }
            if let trackID, let scale, scale > 0 { timescales[trackID] = scale }
        }
        return (timescales, defaults, height)
    }

    /// moof: 첫 traf 의 시작 시각(tfdt)과 길이(trun 표본 길이 합, 없으면 tfhd 기본 길이 × 표본 수)
    private static func parseMoof(_ body: Data, timescales: [UInt32: UInt32], defaults: [UInt32: UInt32]) -> (start: Double, duration: Double) {
        for (type, traf) in children(body) where type == "traf" {
            var trackID: UInt32 = 0
            var defaultDuration: UInt32 = 0
            var decodeTime: UInt64 = 0
            var total: UInt64 = 0
            for (inner, content) in children(traf) {
                switch inner {
                case "tfhd" where content.count >= 8:
                    let flags = uint32(content, 0) & 0xFFFFFF
                    trackID = uint32(content, 4)
                    defaultDuration = defaults[trackID] ?? 0
                    var at = 8
                    if flags & 0x01 != 0 { at += 8 }   // base-data-offset
                    if flags & 0x02 != 0 { at += 4 }   // sample-description-index
                    if flags & 0x08 != 0, content.count >= at + 4 { defaultDuration = uint32(content, at) }
                case "tfdt" where content.count >= 8:
                    decodeTime = content[content.startIndex] == 1 && content.count >= 12 ? uint64(content, 4) : UInt64(uint32(content, 4))
                case "trun" where content.count >= 8:
                    let flags = uint32(content, 0) & 0xFFFFFF
                    let count = Int(uint32(content, 4))
                    var at = 8
                    if flags & 0x01 != 0 { at += 4 }   // data-offset
                    if flags & 0x04 != 0 { at += 4 }   // first-sample-flags
                    let perSample = (flags & 0x100 != 0 ? 4 : 0) + (flags & 0x200 != 0 ? 4 : 0) + (flags & 0x400 != 0 ? 4 : 0) + (flags & 0x800 != 0 ? 4 : 0)
                    if flags & 0x100 != 0 {
                        for i in 0..<count where content.count >= at + i * perSample + 4 {
                            total += UInt64(uint32(content, at + i * perSample))
                        }
                    } else {
                        total += UInt64(defaultDuration) * UInt64(count)
                    }
                default:
                    break
                }
            }
            let scale = Double(timescales[trackID] ?? timescales.values.first ?? 90000)
            return (Double(decodeTime) / scale, Double(total) / scale)
        }
        return (0, 0)
    }
}
