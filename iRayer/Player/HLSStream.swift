#if os(iOS)
import AVFoundation
import CoreImage
import CoreImage.CIFilterBuiltins
import CoreMedia
import MobileVLCKit
import SwiftUI
import UniformTypeIdentifiers
import VideoToolbox

/// AirPlay 로 보낼 HLS. 모든 파일을 한 길로: VLC 가 풀고 자막을 입힌 장면과 소리를 받아
/// 하드웨어 압축기로 H.264·AAC 로 다시 압축하고, HLS 조각(fMP4)으로 만들어 중계 서버로 내보낸다.
/// 재생목록은 처음부터 영상 전체 길이만큼 2초 조각을 다 적은 VOD 라서, TV 가 길이·위치를 보통 영화처럼 보여 주고 TV 에서도 탐색할 수 있다.
/// 조각은 TV 가 달라고 할 때 만든다: 만들고 있는 곳 근처면 기다렸다 주고, 멀면 그 조각 자리부터 VLC 를 다시 열어 만든다.
@MainActor
final class HLSStream {
    let token = UUID().uuidString
    let segmenter: HLSSegmenter
    private var session: EncodeSession?
    private let makeMedia: (Double) -> (VLCMedia, DirectReader?)
    private let probe: () async -> VideoProbe.Info?
    private var probed = false
    /// start 가 첫 만들기를 시작했다 (그 전에 TV 가 조각을 달라고 해도 따로 시작하지 않는다: 같은 자리를 두 번 열게 된다)
    private var started = false
    private let audioTrack: Int32?
    private let subtitle: Subtitle

    /// 장면에 입힐 자막
    enum Subtitle {
        case off
        /// 영상 안 자막 (VLC 가 그려 입힌다)
        case embedded(Int32)
        /// 앱이 그리는 외부 자막 (설정의 글꼴·크기·가장자리로 그려 입힌다). delay: 밀리초
        case app([SubtitleCue], delay: Int)
    }

    /// NAS·폰 안 파일. NAS 는 폰 재생과 같이 앱이 직접 받아 넘긴다 (DirectReader). duration: 영상 길이 (재생목록에 적는다)
    init(file: VideoFile, duration: Double, audioTrack: Int32?, subtitle: Subtitle) {
        self.audioTrack = audioTrack
        self.subtitle = subtitle
        segmenter = HLSSegmenter(duration: duration)
        makeMedia = { start in
            let source: DirectReader.Source? = switch file.url.scheme {
            case "http", "https": .http(RemoteAccess.request(file.url, serverID: file.serverID))
            case "smb": .smb(file.url, serverID: file.serverID)
            default: nil
            }
            var reader: DirectReader?
            let media: VLCMedia
            if let source, file.size > 0, let made = Optional(DirectReader(source: source, size: file.size)), let direct = made.makeMedia() {
                // 실시간으로만 만들므로 많이 미리 받을 필요는 없다
                made.setReadAhead(64 << 20)
                reader = made
                media = direct
            } else {
                media = RemoteAccess.media(for: file.url, serverID: file.serverID)
            }
            PlayerModel.configure(media, for: file, direct: reader != nil)
            if start > 0 { media.addOption(":start-time=\(start)") }
            return (media, reader)
        }
        probe = {
            switch file.url.scheme {
            case "file": await VideoProbe.read(file.url)
            case "http", "https": await VideoProbe.read(file.url, request: RemoteAccess.request(file.url, serverID: file.serverID))
            case "smb": await VideoProbe.read(data: try? await SMBClient.shared.read(file.url, range: 0..<min(file.size, Int64(VideoProbe.headLength)), serverID: file.serverID))
            default: nil
            }
        }
        segmenter.onNeed = { [weak self] index in
            Task { @MainActor in
                guard let self, self.started else { return }
                self.begin(segment: index)
            }
        }
    }

    /// position(초)이 든 조각부터 만들기 시작한다
    func start(at position: Double) async {
        if !probed {
            probed = true
            // 실제 화면 크기와 HDR 여부 (VLC 는 디코더가 맞춘 크기만 알려 주고 색 방식은 알려 주지 않는다)
            let info = await probe()
            segmenter.source = info
        }
        started = true
        begin(segment: Int(position / HLSSegmenter.segmentSeconds))
    }

    func stop() {
        session?.stop()
        session = nil
        segmenter.stop()
    }

    /// 그 조각 자리부터 VLC 를 새로 열어 만든다
    private func begin(segment index: Int) {
        session?.stop()
        let generation = segmenter.restart(at: index)
        let start = Double(index) * HLSSegmenter.segmentSeconds
        let (media, reader) = makeMedia(start)
        let session = EncodeSession(media: media, reader: reader, segmenter: segmenter, generation: generation,
                                    audioTrack: audioTrack, subtitle: subtitle)
        self.session = session
        Task { await session.start() }
    }
}

/// VLC 로 한 자리부터 풀어 압축기로 넘기는 한 번 (탐색으로 다시 만들면 새로 연다)
@MainActor
private final class EncodeSession {
    private let player = VLCMediaPlayer()
    private let reader: DirectReader?
    private let segmenter: HLSSegmenter
    private let generation: Int
    private let audioTrack: Int32?
    private let subtitle: HLSStream.Subtitle
    private var frameTap: FrameTap?
    private var audioTap: AudioTap?
    private var task: Task<Void, Never>?

    init(media: VLCMedia, reader: DirectReader?, segmenter: HLSSegmenter, generation: Int, audioTrack: Int32?, subtitle: HLSStream.Subtitle) {
        player.media = media
        self.reader = reader
        self.segmenter = segmenter
        self.generation = generation
        self.audioTrack = audioTrack
        self.subtitle = subtitle
    }

    func start() async {
        guard let vlc = LibVLC.shared, let audio = LibVLCAudio.shared, let mp = LibVLC.playerInstance(player) else {
            NSLog("[HLS] VLC 함수를 찾지 못함")
            return
        }
        let segmenter = segmenter, generation = generation
        let frameTap = FrameTap { buffer in
            segmenter.append(video: buffer, at: CMClockGetTime(CMClockGetHostTimeClock()), generation: generation)
        }
        self.frameTap = frameTap
        vlc.setCallbacks(mp, tap: frameTap)
        // 하드웨어 디코더가 NV12 로 내놓게 한다 (PiP 와 같게)
        vlc.setOwn(mp, "videotoolbox-cvpx-chroma", "420v")
        let audioTap = AudioTap(segmenter: segmenter, generation: generation)
        self.audioTap = audioTap
        audio.setCallbacks(mp, tap: audioTap)
        player.play()
        await selectTracks()
        follow()
    }

    func stop() {
        task?.cancel()
        player.stop()
        reader?.cancel()
        // VLC 가 출력을 닫을 때까지 잠깐 더 살려 둔다
        // 바뀜 (2026-11-12): 메인에서 놓으면 VLC 가 닫다 멈출 때 앱이 굳는다 — 재생기는 뒤쪽 스레드에서 놓고, 콜백들은 그다음에
        VLCRelease.later(player, keeping: [frameTap, audioTap, reader])
    }

    /// 소리·자막 트랙은 파일을 연 뒤에 목록이 생긴다 (트랙 번호는 폰 재생과 같다)
    private func selectTracks() async {
        for _ in 0..<40 {
            if !player.audioTrackIndexes.isEmpty { break }
            try? await Task.sleep(for: .milliseconds(250))
        }
        if let audioTrack, audioTrack >= 0 { player.currentAudioTrackIndex = audioTrack }
        switch subtitle {
        case .embedded(let id):
            player.currentVideoSubTitleIndex = id
        case .off, .app:
            player.currentVideoSubTitleIndex = -1
        }
    }

    /// 앱 자막은 이 VLC 의 재생 시각을 따라 바뀔 때마다 그림으로 그려 입히게 하고, 영상이 끝나면 마지막 조각을 내보낸다
    private func follow() {
        var cues: [SubtitleCue] = [], delay = 0
        if case .app(let list, let ms) = subtitle { cues = list; delay = ms }
        task = Task { [weak self] in
            var shown: String?
            while !Task.isCancelled, let self {
                if !cues.isEmpty {
                    let time = Double(self.player.time.intValue) / 1000 - Double(delay) / 1000
                    let text = SubtitleParser.text(in: cues, at: time)
                    if text != shown {
                        shown = text
                        self.segmenter.subtitle = text.flatMap { Self.render($0, for: self.segmenter.outputSize) }
                    }
                }
                if self.player.state == .ended || self.player.state == .stopped && self.player.position > 0.99 {
                    self.segmenter.finishFile(generation: self.generation)
                    break
                }
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    /// 화면 자막과 같은 모양(설정의 글꼴·크기·가장자리). 크기는 내보내는 장면(TV) 기준.
    private static func render(_ text: String, for size: CGSize) -> CGImage? {
        let content = SubtitleText(text: text, baseSize: SubtitleText.baseSize(for: size))
            .frame(maxWidth: size.width * 0.9)
            .padding(8)
        let renderer = ImageRenderer(content: content)
        renderer.scale = 1
        return renderer.cgImage
    }
}

/// VLC 가 스피커 대신 넘겨주는 소리 (16비트 정수, 48kHz 스테레오로 VLC 가 바꿔 준다)
nonisolated final class AudioTap: @unchecked Sendable {
    static let sampleRate = 48_000
    static let channels = 2
    private let segmenter: HLSSegmenter
    private let generation: Int

    init(segmenter: HLSSegmenter, generation: Int) {
        self.segmenter = segmenter
        self.generation = generation
    }

    /// pts: 이 소리를 낼 시각 (VLC 시계, 마이크로초 = 호스트 시계)
    func play(_ samples: UnsafeRawPointer, count: Int, pts: Int64) {
        segmenter.append(audio: samples, frames: count, at: CMTime(value: pts, timescale: 1_000_000), generation: generation)
    }
}

/// 장면·소리를 압축해 HLS 조각으로. 영상은 VideoToolbox 로 직접 압축해 키프레임을 정확히 2초 경계마다 넣고
/// (재생목록에 적은 조각 자리와 실제 조각이 어긋나지 않게), AVAssetWriter 의 HLS 출력이 그 키프레임마다 조각을 자른다.
/// 조각 시각은 영상 안 위치 그대로다 (조각 k = k×2초). 조각은 임시 폴더에 파일로 두고, 오래 지난 것은 지운다.
nonisolated final class HLSSegmenter: NSObject, AVAssetWriterDelegate, @unchecked Sendable {
    /// 조각 길이 (초)
    static let segmentSeconds = 2.0
    /// 지금 자리에서 이만큼 뒤 조각까지는 지우지 않는다 (TV 가 조금 되감을 때)
    private static let keepBehind = 300
    private let queue = DispatchQueue(label: "hls.segmenter")
    private let lock = NSLock()
    let directory: URL
    /// 영상 길이 (초)
    let duration: Double
    /// 멀리 있는 조각을 달라고 하면 그 자리부터 다시 만들게 한다 (HLSStream)
    var onNeed: ((Int) -> Void)?

    // 큐에서만
    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var audioInput: AVAssetWriterInput?
    private var encoder: VTCompressionSession?
    /// 소리 압축기 (PCM → AAC). 출력기는 영상을 그대로 넣을 때 소리 압축을 같이 하지 못해서 직접 한다.
    private var audioConverter: AVAudioConverter?
    /// AAC 형식 (압축기의 설정값 포함: 이게 없으면 init.mp4 에 esds 가 빠져 삼성 TV 등이 소리를 못 풀고 재생을 멈춘다)
    private var aacFormat: CMAudioFormatDescription?
    private let pcmFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: Double(AudioTap.sampleRate),
                                          channels: AVAudioChannelCount(AudioTap.channels), interleaved: true)!
    private var pending = Data()
    /// 이번 출력기의 첫 소리 시각과 그 뒤로 내보낸 AAC 묶음 수 (묶음 하나 = 1024 샘플)
    private var audioStart: CMTime?
    private var audioPackets: Int64 = 0
    /// 이번 출력기에 영상을 넣었다 (첫 키프레임 앞에서는 조각을 자르지 않는다)
    private var wroteVideo = false
    private var converter: FrameConverter?
    /// 이번에 만들기 시작한 자리 (초)와 그때 첫 장면의 호스트 시각
    private var sessionStart = CMTime.zero
    private var firstHost: CMTime?
    private var lastVideo = CMTime.invalid
    /// 다음 키프레임을 넣을 시각
    private var nextKey = CMTime.zero
    /// 2초 경계라서 키프레임을 넣으라고 한 장면들 (이 키프레임에서만 조각을 자른다:
    /// 새 압축기의 첫 장면도 키프레임으로 나오는데, 거기서 자르면 경계가 아닌 곳에서 조각이 시작돼 조각 번호가 어긋난다)
    private var boundaryKeys: [CMTime] = []
    /// 압축돼 출력기에 들어간 마지막 장면 시각
    private var lastOutput = CMTime.invalid
    private var queueGeneration = 0

    // lock
    private var generation = 0
    /// 이번에 만들기 시작한 조각과, 다음에 나올 조각
    private var startIndex = 0
    private var nextIndex = 0
    private var made: Set<Int> = []
    private var hasInit = false
    private var lastRestartRequest: (index: Int, at: Date)?
    /// 가장 최근에 TV 가 달라고 한 조각 (탐색 전의 오래된 요청이 다시 만들기를 부르지 않게)
    private var latestRequest = 0
    /// 지금 쓰는 출력기 (출력기 알림은 append 안에서 같은 큐로 바로 올 수 있어 큐가 아니라 잠금으로 본다)
    private var currentWriter: ObjectIdentifier?
    private var storedSource: VideoProbe.Info?
    private var storedSubtitle: CGImage?
    private var storedOutputSize = CGSize(width: 1920, height: 1080)

    /// 파일에서 읽은 실제 화면 크기·색 방식 (첫 장면 전에 정한다)
    var source: VideoProbe.Info? {
        get { lock.withLock { storedSource } }
        set { lock.withLock { storedSource = newValue } }
    }
    /// 장면에 입힐 앱 자막 그림 (없으면 nil)
    var subtitle: CGImage? {
        get { lock.withLock { storedSubtitle } }
        set { lock.withLock { storedSubtitle = newValue } }
    }
    /// 내보내는 장면 크기 (압축기를 만들기 전에는 1080p 로 본다)
    var outputSize: CGSize { lock.withLock { storedOutputSize } }

    private var segmentCount: Int { max(1, Int((duration / Self.segmentSeconds).rounded(.up))) }

    init(duration: Double) {
        self.duration = duration
        directory = FileManager.default.temporaryDirectory.appending(path: "hls-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        super.init()
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: - 다시 만들기

    /// 조각 index 자리부터 새로 만든다 (지금 압축기는 버린다). 새 세대 번호를 돌려준다 (이전 세대의 장면·소리는 버린다).
    func restart(at index: Int) -> Int {
        let generation = lock.withLock {
            self.generation += 1
            startIndex = index
            nextIndex = index
            return self.generation
        }
        queue.async { [self] in
            closeWriter(cancel: true)
            queueGeneration = generation
            sessionStart = CMTime(seconds: Double(index) * Self.segmentSeconds, preferredTimescale: 90_000)
            nextKey = sessionStart
            boundaryKeys = []
            lastOutput = .invalid
            firstHost = nil
            lastVideo = .invalid
        }
        return generation
    }

    func stop() {
        lock.withLock { generation += 1 }
        queue.async { [self] in closeWriter(cancel: true) }
    }

    /// 영상 끝: 남은 장면을 마지막 조각으로 내보낸다
    func finishFile(generation: Int) {
        queue.async { [self] in
            guard generation == queueGeneration else { return }
            closeWriter(cancel: false)
        }
    }

    private func closeWriter(cancel: Bool) {
        if let encoder {
            if !cancel { VTCompressionSessionCompleteFrames(encoder, untilPresentationTimeStamp: .invalid) }
            VTCompressionSessionInvalidate(encoder)
        }
        encoder = nil
        if let writer, writer.status == .writing {
            if cancel {
                writer.cancelWriting()
            } else {
                videoInput?.markAsFinished()
                audioInput?.markAsFinished()
                writer.finishWriting {}
            }
        }
        writer = nil
        videoInput = nil
        audioInput = nil
        audioConverter = nil
        pending = Data()
        audioStart = nil
        audioPackets = 0
        wroteVideo = false
        lock.withLock { currentWriter = nil }
    }

    // MARK: - 받기

    func append(video buffer: CVPixelBuffer, at host: CMTime, generation: Int) {
        queue.async { [self] in
            guard generation == queueGeneration else { return }
            if converter == nil { makeConverter(width: CVPixelBufferGetWidth(buffer), height: CVPixelBufferGetHeight(buffer)) }
            if encoder == nil { makeEncoder() }
            guard let converter, let encoder else { return }
            if firstHost == nil { firstHost = host }
            guard let firstHost else { return }
            // 영상 안 위치 = 시작 자리 + 첫 장면부터 지난 시간
            let pts = sessionStart + (host - firstHost)
            guard !lastVideo.isValid || pts > lastVideo else { return }
            guard let frame = converter.convert(buffer, subtitle: subtitle) else { return }
            lastVideo = pts
            // 2초 경계를 넘은 첫 장면을 키프레임으로 (조각 경계)
            var properties: CFDictionary?
            if pts >= nextKey {
                properties = [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary
                let step = CMTime(seconds: Self.segmentSeconds, preferredTimescale: 90_000)
                while nextKey <= pts { nextKey = nextKey + step }
                boundaryKeys.append(pts)
            }
            let status = VTCompressionSessionEncodeFrame(encoder, imageBuffer: frame, presentationTimeStamp: pts, duration: .invalid,
                                                         frameProperties: properties, infoFlagsOut: nil) { [self] status, _, sample in
                queue.async { [self] in
                    guard generation == queueGeneration else { return }
                    guard status == noErr, let sample else { return encoderFailed(status, encoder) }
                    appendEncoded(sample)
                }
            }
            if status != noErr { encoderFailed(status, encoder) }
        }
    }

    private func appendEncoded(_ sample: CMSampleBuffer) {
        if writer == nil {
            guard let format = CMSampleBufferGetFormatDescription(sample) else { return }
            makeWriter(videoFormat: format)
        }
        if writer?.status == .failed { return recoverFromFailure() }
        guard let writer, writer.status == .writing, let videoInput, videoInput.isReadyForMoreMediaData else { return }
        // 키프레임(2초 경계) 앞에서 지금까지를 한 조각으로 내보낸다
        let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[CFString: Any]]
        let isKey = !(attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool ?? false)
        let pts = CMSampleBufferGetPresentationTimeStamp(sample)
        let boundary = isKey && boundaryKeys.contains(pts)
        boundaryKeys.removeAll { $0 <= pts }
        if boundary, wroteVideo { writer.flushSegment() }
        lastOutput = pts
        if videoInput.append(sample) { wroteVideo = true }
    }

    /// 압축기가 멈췄다 (앱이 백그라운드로 가면 iOS 가 하드웨어 압축기를 끊는다): 새로 만들고, 다음 2초 경계부터 다시 넣는다
    /// (경계 전 장면은 버린다: 새 압축기의 첫 키프레임이 조각 경계에 오게)
    private func encoderFailed(_ status: OSStatus, _ failed: VTCompressionSession) {
        // 버린 압축기에서 늦게 온 오류는 넘긴다
        guard let encoder, encoder == failed else { return }
        NSLog("[HLS] 압축기 오류 \(status), 새로 만든다 (마지막 장면 \(String(format: "%.2f", lastVideo.seconds)))")
        VTCompressionSessionInvalidate(encoder)
        self.encoder = nil
        // 버린 압축기 안에 있던 장면은 사라진다: 그중 경계 키프레임이 있었으면 다음 장면에 다시 넣는다
        let step = CMTime(seconds: Self.segmentSeconds, preferredTimescale: 90_000)
        nextKey = sessionStart
        if lastOutput.isValid { while nextKey <= lastOutput { nextKey = nextKey + step } }
        boundaryKeys.removeAll { !lastOutput.isValid || $0 > lastOutput }
    }

    /// 출력기가 멈췄다: 이유를 남기고, 아직 못 만든 조각 자리부터 다시 만들게 한다 (그대로 두면 TV 가 기다리다 실패한다)
    private func recoverFromFailure() {
        NSLog("[HLS] 출력기 실패: \(String(describing: writer?.error))")
        closeWriter(cancel: true)
        // 다시 만들기 전까지 이번 장면·소리는 버린다
        queueGeneration = -1
        let index = lock.withLock { nextIndex }
        onNeed?(index)
    }

    func append(audio samples: UnsafeRawPointer, frames: Int, at host: CMTime, generation: Int) {
        let data = Data(bytes: samples, count: frames * AudioTap.channels * 2)
        queue.async { [self] in
            guard generation == queueGeneration, let writer, let firstHost else { return }
            if writer.status == .failed { return recoverFromFailure() }
            guard writer.status == .writing else { return }
            let pts = sessionStart + (host - firstHost)
            guard pts >= sessionStart else { return }
            // 소리는 이어 붙인다: 첫 덩어리 시각부터 샘플 수로 시각을 센다
            if audioStart == nil { audioStart = pts }
            pending.append(data)
            encodeAudio()
        }
    }

    /// 쌓인 PCM 을 1024 샘플씩 AAC 로 압축해 출력기에 넣는다
    private func encodeAudio() {
        guard let audioConverter, let audioInput, let audioStart else { return }
        let frameBytes = AudioTap.channels * 2
        let chunk = 1024
        while pending.count >= chunk * frameBytes {
            guard let input = AVAudioPCMBuffer(pcmFormat: pcmFormat, frameCapacity: AVAudioFrameCount(chunk)) else { return }
            input.frameLength = AVAudioFrameCount(chunk)
            pending.prefix(chunk * frameBytes).withUnsafeBytes { raw in
                memcpy(input.int16ChannelData![0], raw.baseAddress!, chunk * frameBytes)
            }
            pending.removeFirst(chunk * frameBytes)
            let output = AVAudioCompressedBuffer(format: audioConverter.outputFormat, packetCapacity: 4,
                                                 maximumPacketSize: max(audioConverter.maximumOutputPacketSize, 1536))
            var given = false
            var error: NSError?
            audioConverter.convert(to: output, error: &error) { _, status in
                if given {
                    status.pointee = .noDataNow
                    return nil
                }
                given = true
                status.pointee = .haveData
                return input
            }
            guard output.packetCount > 0, let descriptions = output.packetDescriptions,
                  let format = aacFormat else { continue }
            let count = Int(output.packetCount)
            let bytes = Int(output.byteLength)
            var block: CMBlockBuffer?
            CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: bytes, blockAllocator: nil,
                                               customBlockSource: nil, offsetToData: 0, dataLength: bytes, flags: 0, blockBufferOut: &block)
            guard let block else { continue }
            CMBlockBufferReplaceDataBytes(with: output.data, blockBuffer: block, offsetIntoDestination: 0, dataLength: bytes)
            // AAC 압축기는 앞에 2112 샘플(준비분)을 더 내놓으므로 그만큼 앞당긴다
            let samples = audioPackets * Int64(chunk) - 2112
            let pts = audioStart + CMTime(value: samples, timescale: CMTimeScale(AudioTap.sampleRate))
            var sample: CMSampleBuffer?
            CMAudioSampleBufferCreateReadyWithPacketDescriptions(allocator: nil, dataBuffer: block, formatDescription: format,
                                                                 sampleCount: count, presentationTimeStamp: pts,
                                                                 packetDescriptions: descriptions, sampleBufferOut: &sample)
            audioPackets += Int64(count)
            guard let sample, pts >= sessionStart, audioInput.isReadyForMoreMediaData else { continue }
            audioInput.append(sample)
        }
    }

    /// 첫 장면 크기를 보고 장면 손보기를 정한다. 1080p 보다 크면 1080p 안으로 줄이고,
    /// 디코더가 붙인 여백(1080 → 1088 등)은 파일의 실제 크기로 잘라 내고, HDR 은 SDR 로 바꾼다.
    private func makeConverter(width: Int, height: Int) {
        let source = source
        var visibleWidth = width, visibleHeight = height
        if let source, source.width > 0, source.height > 0, source.width <= width, source.height <= height {
            visibleWidth = source.width
            visibleHeight = source.height
        }
        // 바뀜 (2026-11-11, 사용자: 1080p 를 AirPlay 하면 아래 1% 쯤 깨진 줄): 파일 앞 4MB 에서 크기를 못 읽으면(목차가 끝에 있는 MP4 등)
        // 또는 파일에도 여백 크기가 적혀 있으면 1088 을 그대로 1080 에 줄여 넣어 아래 8줄 여백이 보였다.
        // 흔한 높이에 16 배수 여백이 붙은 꼴(1088·544·368)이면 잘라 낸다
        let padded = [1080, 540, 360]
        if visibleHeight % 16 == 0, padded.contains(visibleHeight - 8) { visibleHeight -= 8 }
        NSLog("[HLS] 장면 \(width)x\(height) → 보이는 크기 \(visibleWidth)x\(visibleHeight) (파일 정보 \(source?.description ?? "없음"))")
        let scale = min(1, min(1920 / Double(visibleWidth), 1080 / Double(visibleHeight)))
        let outWidth = Int(Double(visibleWidth) * scale) & ~1, outHeight = Int(Double(visibleHeight) * scale) & ~1
        // 앱 자막도 여기서 입히므로 늘 거친다 (내보내는 크기로 줄인 뒤라 자막 크기가 TV 화면 기준으로 일정하다)
        converter = FrameConverter(visible: CGSize(width: visibleWidth, height: visibleHeight),
                                   output: CGSize(width: outWidth, height: outHeight), hdr: source?.hdr)
        lock.withLock { storedOutputSize = CGSize(width: outWidth, height: outHeight) }
    }

    /// 하드웨어 H.264 압축기. 키프레임은 직접 넣으므로 저절로는 넣지 않게 한다.
    private func makeEncoder() {
        let size = outputSize
        var session: VTCompressionSession?
        VTCompressionSessionCreate(allocator: nil, width: Int32(size.width), height: Int32(size.height), codecType: kCMVideoCodecType_H264,
                                   encoderSpecification: [kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder: true] as CFDictionary,
                                   imageBufferAttributes: nil, compressedDataAllocator: nil, outputCallback: nil, refcon: nil,
                                   compressionSessionOut: &session)
        guard let session else {
            NSLog("[HLS] 압축기를 만들지 못함")
            return
        }
        let properties: [CFString: Any] = [
            kVTCompressionPropertyKey_RealTime: true,
            kVTCompressionPropertyKey_ProfileLevel: kVTProfileLevel_H264_High_AutoLevel,
            kVTCompressionPropertyKey_AverageBitRate: 10_000_000,
            kVTCompressionPropertyKey_AllowFrameReordering: false,
            kVTCompressionPropertyKey_MaxKeyFrameInterval: 100_000,
            kVTCompressionPropertyKey_ExpectedFrameRate: 30,
            kVTCompressionPropertyKey_ColorPrimaries: kCVImageBufferColorPrimaries_ITU_R_709_2,
            kVTCompressionPropertyKey_TransferFunction: kCVImageBufferTransferFunction_ITU_R_709_2,
            kVTCompressionPropertyKey_YCbCrMatrix: kCVImageBufferYCbCrMatrix_ITU_R_709_2,
        ]
        for (key, value) in properties { VTSessionSetProperty(session, key: key, value: value as CFTypeRef) }
        VTCompressionSessionPrepareToEncodeFrames(session)
        encoder = session
    }

    /// 압축한 영상의 형식을 보고 조각 출력기를 만든다 (영상은 그대로 넣고 소리만 AAC 로 압축)
    private func makeWriter(videoFormat: CMFormatDescription) {
        let writer = AVAssetWriter(contentType: UTType(AVFileType.mp4.rawValue)!)
        writer.outputFileTypeProfile = .mpeg4AppleHLS
        // 조각은 키프레임마다 직접 자른다 (자동 자르기는 영상·소리를 둘 다 그대로 넣을 때 쓸 수 없다)
        writer.preferredOutputSegmentInterval = .indefinite
        writer.initialSegmentStartTime = sessionStart
        writer.delegate = self

        let video = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: videoFormat)
        video.expectsMediaDataInRealTime = true

        var aacDescription = AudioStreamBasicDescription(mSampleRate: Double(AudioTap.sampleRate), mFormatID: kAudioFormatMPEG4AAC,
                                                         mFormatFlags: 0, mBytesPerPacket: 0, mFramesPerPacket: 1024, mBytesPerFrame: 0,
                                                         mChannelsPerFrame: UInt32(AudioTap.channels), mBitsPerChannel: 0, mReserved: 0)
        guard let aac = AVAudioFormat(streamDescription: &aacDescription), let converter = AVAudioConverter(from: pcmFormat, to: aac) else {
            NSLog("[HLS] 소리 압축기를 만들지 못함")
            return
        }
        converter.bitRate = 192_000
        var format: CMAudioFormatDescription?
        let cookie = converter.magicCookie ?? Data()
        cookie.withUnsafeBytes { raw in
            _ = CMAudioFormatDescriptionCreate(allocator: nil, asbd: &aacDescription, layoutSize: 0, layout: nil,
                                               magicCookieSize: raw.count, magicCookie: raw.baseAddress, extensions: nil,
                                               formatDescriptionOut: &format)
        }
        guard let format else {
            NSLog("[HLS] 소리 형식을 만들지 못함")
            return
        }
        audioConverter = converter
        aacFormat = format
        let audio = AVAssetWriterInput(mediaType: .audio, outputSettings: nil, sourceFormatHint: format)
        audio.expectsMediaDataInRealTime = true

        guard writer.canAdd(video), writer.canAdd(audio) else {
            NSLog("[HLS] 입력을 붙이지 못함")
            return
        }
        writer.add(video)
        writer.add(audio)
        guard writer.startWriting() else {
            NSLog("[HLS] 시작 실패: \(String(describing: writer.error))")
            return
        }
        writer.startSession(atSourceTime: sessionStart)
        lock.withLock { currentWriter = ObjectIdentifier(writer) }
        self.writer = writer
        videoInput = video
        audioInput = audio
    }

    // MARK: - 조각

    func assetWriter(_ writer: AVAssetWriter, didOutputSegmentData segmentData: Data, segmentType: AVAssetSegmentType,
                     segmentReport: AVAssetSegmentReport?) {
        // 버린 출력기(다시 만들기 전)의 조각은 쓰지 않는다
        let current = lock.withLock { currentWriter == ObjectIdentifier(writer) }
        switch segmentType {
        case .initialization:
            guard current else { return }
            try? segmentData.write(to: directory.appending(path: "init.mp4"), options: .atomic)
            lock.withLock { hasInit = true }
        case .separable:
            let start = segmentReport?.trackReports.first { $0.mediaType == .video }?.earliestPresentationTimeStamp.seconds
            let index = lock.withLock { start.map { Int(($0 / Self.segmentSeconds).rounded()) } ?? nextIndex }
            try? segmentData.write(to: directory.appending(path: "seg\(index).m4s"), options: .atomic)
            let removed: [Int] = lock.withLock {
                made.insert(index)
                if current { nextIndex = max(nextIndex, index + 1) }
                let old = made.filter { $0 < index - Self.keepBehind }
                made.subtract(old)
                return Array(old)
            }
            for old in removed { try? FileManager.default.removeItem(at: directory.appending(path: "seg\(old).m4s")) }
        @unknown default:
            break
        }
    }

    /// 재생목록: 처음부터 끝까지 2초 조각을 다 적은 VOD (TV 가 길이·위치를 알고 탐색도 한다)
    func playlist() -> String {
        var text = """
        #EXTM3U
        #EXT-X-VERSION:7
        #EXT-X-TARGETDURATION:\(Int(Self.segmentSeconds))
        #EXT-X-MEDIA-SEQUENCE:0
        #EXT-X-PLAYLIST-TYPE:VOD
        #EXT-X-INDEPENDENT-SEGMENTS
        #EXT-X-MAP:URI="init.mp4"

        """
        let count = segmentCount
        for index in 0..<count {
            let length = index == count - 1 ? duration - Double(index) * Self.segmentSeconds : Self.segmentSeconds
            text += "#EXTINF:\(String(format: "%.3f", max(length, 0.1))),\nseg\(index).m4s\n"
        }
        text += "#EXT-X-ENDLIST\n"
        return text
    }

    /// 조각 파일 (init.mp4, segN.m4s). 아직 없으면 만들어질 때까지 기다리고, 만드는 곳에서 멀면 그 자리부터 다시 만들게 한다.
    func data(named name: String) async -> Data? {
        let url = directory.appending(path: name)
        let index: Int?
        if name == "init.mp4" {
            index = nil
        } else if name.hasPrefix("seg"), name.hasSuffix(".m4s"), let value = Int(name.dropFirst(3).dropLast(4)) {
            index = value
        } else {
            return nil
        }
        if let index { lock.withLock { latestRequest = index } }
        for attempt in 0..<120 {
            if let data = try? Data(contentsOf: url), !data.isEmpty { return data }
            if let index {
                // 이미 지나간 조각인데 없다 (만들다 빠졌다): 몇 초 기다려 보고 그 자리부터 다시 만든다
                if attempt == 16, lock.withLock({ index == latestRequest && index >= startIndex && index < nextIndex - 1 }) {
                    NSLog("[HLS] 조각 \(index) 이 빠졌다 (다음 조각 \(lock.withLock { nextIndex })), 다시 만든다")
                    onNeed?(index)
                }
                // 그 뒤에 멀리 떨어진 조각을 달라고 했으면 (탐색) 이 요청은 버린다
                let stale = lock.withLock { abs(latestRequest - index) > 8 }
                if stale { return nil }
                requestIfFar(index)
            }
            try? await Task.sleep(for: .milliseconds(250))
        }
        return nil
    }

    /// 만드는 곳(시작 ~ 다음 조각 + 몇 개) 밖의 조각이면 그 자리부터 다시 만들게 한다 (같은 곳을 여러 번 부탁하지 않게)
    private func requestIfFar(_ index: Int) {
        let request: Bool = lock.withLock {
            // TV 가 여러 조각을 한꺼번에 달라고 할 때 (탐색 직후) 가장 최근 요청만 다시 만들기를 부른다 (서로 번갈아 다시 만들지 않게)
            if index != latestRequest { return false }
            if index >= startIndex && index <= nextIndex + 4 { return false }
            if let last = lastRestartRequest, index >= last.index, index <= last.index + 4, Date().timeIntervalSince(last.at) < 10 { return false }
            lastRestartRequest = (index, Date())
            return true
        }
        if request { onNeed?(index) }
    }
}

/// 장면 손보기 (CoreImage): 디코더 여백 자르기, HDR(PQ·HLG) → SDR 톤 매핑, 내보낼 크기로 줄이기, 앱 자막 입히기.
/// VLC 는 HDR 영상을 색 방식 표시 없이 8비트로 넘겨서, 그대로 압축하면 물 빠진 색이 된다.
nonisolated final class FrameConverter {
    private let context = CIContext(options: [.cacheIntermediates: false])
    private let visible: CGSize
    private let output: CGSize
    private let hdr: VideoProbe.HDR?
    private var pool: CVPixelBufferPool?
    private let sdr = CGColorSpace(name: CGColorSpace.itur_709)!

    init(visible: CGSize, output: CGSize, hdr: VideoProbe.HDR?) {
        self.visible = visible
        self.output = output
        self.hdr = hdr
        let attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: Int(output.width),
            kCVPixelBufferHeightKey as String: Int(output.height),
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
            kCVBufferPropagatedAttachmentsKey as String: [
                kCVImageBufferColorPrimariesKey as String: kCVImageBufferColorPrimaries_ITU_R_709_2,
                kCVImageBufferTransferFunctionKey as String: kCVImageBufferTransferFunction_ITU_R_709_2,
                kCVImageBufferYCbCrMatrixKey as String: kCVImageBufferYCbCrMatrix_ITU_R_709_2,
            ],
        ]
        CVPixelBufferPoolCreate(nil, [kCVPixelBufferPoolMinimumBufferCountKey: 4] as CFDictionary, attributes as CFDictionary, &pool)
    }

    func convert(_ buffer: CVPixelBuffer, subtitle: CGImage?) -> CVPixelBuffer? {
        if let hdr {
            CVBufferSetAttachment(buffer, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_2020, .shouldPropagate)
            CVBufferSetAttachment(buffer, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_2020, .shouldPropagate)
            CVBufferSetAttachment(buffer, kCVImageBufferTransferFunctionKey,
                                  hdr == .pq ? kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ : kCVImageBufferTransferFunction_ITU_R_2100_HLG,
                                  .shouldPropagate)
        }
        var image = CIImage(cvPixelBuffer: buffer)
        // 여백은 아래쪽·오른쪽에 붙는다 (CoreImage 는 아래가 0)
        let height = CGFloat(CVPixelBufferGetHeight(buffer))
        image = image.cropped(to: CGRect(x: 0, y: height - visible.height, width: visible.width, height: visible.height))
            .transformed(by: CGAffineTransform(translationX: 0, y: visible.height - height))
        image = image.transformed(by: CGAffineTransform(scaleX: output.width / visible.width, y: output.height / visible.height))
        if hdr != nil {
            // 밝은 곳(1000니트, SDR 기준 203니트의 약 5배)을 SDR 범위 안으로 눌러 담는다
            let filter = CIFilter.toneMapHeadroom()
            filter.inputImage = image
            filter.sourceHeadroom = 1000 / 203
            filter.targetHeadroom = 1
            image = filter.outputImage ?? image
        }
        if let subtitle {
            // 아래 가운데, 높이의 5% 위 (화면 자막과 같은 자리)
            let x = ((output.width - CGFloat(subtitle.width)) / 2).rounded()
            let overlay = CIImage(cgImage: subtitle).transformed(by: CGAffineTransform(translationX: x, y: (output.height * 0.05).rounded()))
            image = overlay.composited(over: image)
        }
        guard let pool else { return nil }
        var out: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &out)
        guard let out else { return nil }
        context.render(image, to: out, bounds: CGRect(origin: .zero, size: output), colorSpace: sdr)
        return out
    }
}

/// 파일 앞부분에서 실제 화면 크기와 HDR 여부를 읽는다 (MKV 트랙 정보, MP4 의 colr·영상 항목)
nonisolated enum VideoProbe {
    enum HDR: String, Sendable { case pq = "HDR10(PQ)", hlg = "HLG" }

    struct Info: Sendable, CustomStringConvertible {
        var width = 0
        var height = 0
        var hdr: HDR?
        var description: String { "\(width)x\(height)\(hdr.map { " \($0.rawValue)" } ?? "")" }
    }

    static let headLength = 4 << 20

    static func read(data: Data?) -> Info? {
        guard let data else { return nil }
        let bytes = [UInt8](data)
        if bytes.starts(with: [0x1A, 0x45, 0xDF, 0xA3]) { return matroska(bytes) }
        return mp4(bytes)
    }

    static func read(_ url: URL, request: URLRequest? = nil) async -> Info? {
        let length = headLength
        let data: Data
        if url.isFileURL {
            guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
            defer { try? handle.close() }
            data = (try? handle.read(upToCount: length)) ?? Data()
        } else {
            var request = request ?? URLRequest(url: url)
            request.setValue("bytes=0-\(length - 1)", forHTTPHeaderField: "Range")
            guard let (body, _) = try? await URLSession.shared.data(for: request) else { return nil }
            data = body
        }
        return read(data: data)
    }

    private static func transfer(_ value: Int) -> HDR? {
        switch value {
        case 16: .pq
        case 18: .hlg
        default: nil
        }
    }

    // MARK: MKV (EBML)

    private static func vint(_ b: [UInt8], _ i: Int, mask: Bool) -> (Int, Int)? {
        guard i < b.count else { return nil }
        let first = b[i]
        var n = 1, m: UInt8 = 0x80
        while n <= 8 && first & m == 0 { n += 1; m >>= 1 }
        guard n <= 8, i + n <= b.count else { return nil }
        var value = mask ? Int(first & (m &- 1)) : Int(first)
        for k in 1..<n { value = value << 8 | Int(b[i + k]) }
        if mask && value == (1 << (7 * n)) - 1 { value = -1 }
        return (value, n)
    }

    /// (id, 내용 시작, 크기) 를 차례로
    private static func elements(_ b: [UInt8], _ start: Int, _ end: Int) -> [(Int, Int, Int)] {
        var out: [(Int, Int, Int)] = []
        var i = start
        let end = min(end, b.count)
        while i < end - 2, let (id, n1) = vint(b, i, mask: false), let (size, n2) = vint(b, i + n1, mask: true) {
            let data = i + n1 + n2
            out.append((id, data, size))
            if size < 0 { break }
            i = data + size
        }
        return out
    }

    private static func uint(_ b: [UInt8], _ start: Int, _ size: Int) -> Int {
        guard size > 0, start + size <= b.count else { return 0 }
        return b[start..<start + size].reduce(0) { $0 << 8 | Int($1) }
    }

    private static func matroska(_ b: [UInt8]) -> Info? {
        guard let segment = elements(b, 0, b.count).first(where: { $0.0 == 0x18538067 }) else { return nil }
        for (id, data, size) in elements(b, segment.1, b.count) {
            if id == 0x1F43B675 { break } // 클러스터 (영상 데이터)
            guard id == 0x1654AE6B else { continue } // 트랙
            for (entryID, entry, entrySize) in elements(b, data, data + size) where entryID == 0xAE {
                for (fieldID, field, fieldSize) in elements(b, entry, entry + entrySize) where fieldID == 0xE0 {
                    var info = Info()
                    for (videoID, video, videoSize) in elements(b, field, field + fieldSize) {
                        switch videoID {
                        case 0xB0: info.width = uint(b, video, videoSize)
                        case 0xBA: info.height = uint(b, video, videoSize)
                        case 0x55B0:
                            for (colorID, color, colorSize) in elements(b, video, video + videoSize) where colorID == 0x55BA {
                                info.hdr = transfer(uint(b, color, colorSize))
                            }
                        default: break
                        }
                    }
                    return info
                }
            }
        }
        return nil
    }

    // MARK: MP4

    private static func find(_ b: [UInt8], _ tag: String) -> [Int] {
        let t = Array(tag.utf8)
        var out: [Int] = []
        var i = 0
        while i + 4 <= b.count {
            if b[i] == t[0] && b[i + 1] == t[1] && b[i + 2] == t[2] && b[i + 3] == t[3] { out.append(i) }
            i += 1
        }
        return out
    }

    private static func mp4(_ b: [UInt8]) -> Info? {
        var info = Info()
        for tag in ["avc1", "hvc1", "hev1", "dvh1", "dvhe"] {
            // 영상 항목: 이름 뒤 24바이트 다음이 폭·높이 (2바이트씩)
            if let at = find(b, tag).first(where: { $0 + 32 <= b.count && uint(b, $0 + 28, 2) > 0 }) {
                info.width = uint(b, at + 28, 2)
                info.height = uint(b, at + 30, 2)
                break
            }
        }
        if let at = find(b, "colr").first(where: { $0 + 10 <= b.count && Array(b[$0 + 4..<$0 + 8]) == Array("nclx".utf8) }) {
            info.hdr = transfer(uint(b, at + 10, 2))
        }
        return info.width > 0 || info.hdr != nil ? info : nil
    }
}

/// libvlc 소리 받기 (MobileVLCKit 에 있지만 공개되지 않은 C 함수를 dlsym 으로)
nonisolated final class LibVLCAudio {
    static let shared = LibVLCAudio()

    private typealias PlayCallback = @convention(c) (UnsafeMutableRawPointer?, UnsafeRawPointer?, UInt32, Int64) -> Void
    private typealias TimeCallback = @convention(c) (UnsafeMutableRawPointer?, Int64) -> Void
    private typealias DrainCallback = @convention(c) (UnsafeMutableRawPointer?) -> Void

    private let setCallbacksFunction: @convention(c) (OpaquePointer, PlayCallback?, TimeCallback?, TimeCallback?, TimeCallback?, DrainCallback?, UnsafeMutableRawPointer?) -> Void
    private let setFormatFunction: @convention(c) (OpaquePointer, UnsafePointer<CChar>, UInt32, UInt32) -> Void

    private init?() {
        let handle = UnsafeMutableRawPointer(bitPattern: -2) // RTLD_DEFAULT
        guard let setCallbacks = dlsym(handle, "libvlc_audio_set_callbacks"),
              let setFormat = dlsym(handle, "libvlc_audio_set_format") else { return nil }
        setCallbacksFunction = unsafeBitCast(setCallbacks, to: (@convention(c) (OpaquePointer, PlayCallback?, TimeCallback?, TimeCallback?, TimeCallback?, DrainCallback?, UnsafeMutableRawPointer?) -> Void).self)
        setFormatFunction = unsafeBitCast(setFormat, to: (@convention(c) (OpaquePointer, UnsafePointer<CChar>, UInt32, UInt32) -> Void).self)
    }

    /// 소리를 스피커 대신 tap 으로. 재생 전에 정해야 한다. tap 은 부르는 쪽이 살려 둔다.
    func setCallbacks(_ player: OpaquePointer, tap: AudioTap) {
        setCallbacksFunction(player, { opaque, samples, count, pts in
            guard let opaque, let samples else { return }
            Unmanaged<AudioTap>.fromOpaque(opaque).takeUnretainedValue().play(samples, count: Int(count), pts: pts)
        }, nil, nil, nil, nil, Unmanaged.passUnretained(tap).toOpaque())
        setFormatFunction(player, "S16N", UInt32(AudioTap.sampleRate), UInt32(AudioTap.channels))
    }
}
#endif
