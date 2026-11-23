#if os(iOS)
import Accelerate
import AVKit
import CoreMedia
import CoreVideo
import MobileVLCKit
import SwiftUI
import UIKit

/// 아이폰 기본 PiP (시험판). 평소에는 VLC 가 직접 그리고, PiP 단추를 눌렀을 때만 VLC 출력을 장면 받기로 바꿔
/// 앱 자막(SRT·SMI)을 장면에 입힌 뒤 AVSampleBufferDisplayLayer 로 PiP 에 넘긴다. PiP 를 닫으면 다시 VLC 가 그린다.
/// 앱을 나갈 때 저절로 PiP 가 되지는 않는다 (사용자: PiP 는 단추로만).
@MainActor
final class SystemPiP: NSObject {
    private weak var model: PlayerModel?
    private let player: VLCMediaPlayer
    private let displayLayer = AVSampleBufferDisplayLayer()
    private var controller: AVPictureInPictureController?
    private var tap: FrameTap?
    private var possibleObservation: NSKeyValueObservation?
    /// VLC 출력을 바꾸기 전 값 (돌아갈 때 되돌린다)
    private var savedVars: [String: String] = [:]
    /// 크게 보기로 돌아왔다 (✕ 로 닫으면 false: 플레이어를 닫는다)
    private var restored = false
    private(set) var isActive = false

    init(model: PlayerModel, player: VLCMediaPlayer) {
        self.model = model
        self.player = player
        super.init()
        displayLayer.videoGravity = .resizeAspect
    }

    static var isSupported: Bool {
        AVPictureInPictureController.isPictureInPictureSupported() && LibVLC.shared != nil
    }

    // MARK: - 켜기·끄기

    /// PiP 단추: 장면 받기로 바꾸고, 첫 장면이 들어오면 PiP 를 띄운다
    func start(in view: UIView) {
        guard !isActive, let vlc = LibVLC.shared, let mp = LibVLC.playerInstance(player) else { return }
        isActive = true
        restored = false
        displayLayer.frame = view.bounds
        view.layer.addSublayer(displayLayer)
        displayLayer.sampleBufferRenderer.flush()

        let timebase = try? CMTimebase(sourceClock: CMClockGetHostTimeClock())
        displayLayer.controlTimebase = timebase
        updateTimebase()

        let tap = FrameTap(layer: displayLayer)
        self.tap = tap
        tap.onSetup = { [weak self] in
            Task { @MainActor in self?.renderSubtitle() }
        }
        tap.onFirstFrame = { [weak self] in
            Task { @MainActor in self?.startWhenPossible() }
        }

        for name in ["vout", "window", "avcodec-hw"] {
            if let value = vlc.getString(mp, name) { savedVars[name] = value }
        }
        vlc.setCallbacks(mp, tap: tap)
        // 장면 받기는 하드웨어 디코딩을 끄는데, 4K 를 소프트웨어로 풀면 버거우므로 원래대로 둔다
        if let hw = savedVars["avcodec-hw"] { vlc.setString(mp, "avcodec-hw", hw) }
        // 하드웨어 디코더가 NV12(비디오 범위)로 내놓게 한다: 4K·10비트도 BGRA(장면당 33MB) 대신 NV12(12MB), 변환은 디코더가 한다
        vlc.setOwn(mp, "videotoolbox-cvpx-chroma", "420v")
        restartVideoOutput()

        let source = AVPictureInPictureController.ContentSource(sampleBufferDisplayLayer: displayLayer, playbackDelegate: self)
        let controller = AVPictureInPictureController(contentSource: source)
        controller.delegate = self
        self.controller = controller
    }

    private func startWhenPossible() {
        guard isActive, let controller else { return }
        if controller.isPictureInPicturePossible {
            controller.startPictureInPicture()
        } else {
            possibleObservation = controller.observe(\.isPictureInPicturePossible, options: [.new]) { controller, _ in
                guard controller.isPictureInPicturePossible else { return }
                Task { @MainActor in controller.startPictureInPicture() }
            }
        }
    }

    /// PiP 가 끝나면 다시 VLC 가 직접 그린다
    private func finish() {
        model?.isOpeningPiP = false
        guard isActive else { return }
        isActive = false
        possibleObservation = nil
        controller = nil
        if let vlc = LibVLC.shared, let mp = LibVLC.playerInstance(player) {
            vlc.setString(mp, "vout", savedVars["vout"] ?? "")
            vlc.setString(mp, "window", savedVars["window"] ?? "")
            if let hw = savedVars["avcodec-hw"] { vlc.setString(mp, "avcodec-hw", hw) }
            // 원래 없던 설정이라 지운다 (빈 값으로 두면 VLC 가 잘못된 설정으로 보고 하드웨어 디코더를 쓰지 않는다)
            vlc.removeOwn(mp, "videotoolbox-cvpx-chroma")
            restartVideoOutput()
        }
        // VLC 가 장면 받기 출력을 닫을 때까지 잠깐 더 살려 둔다
        if let tap { DispatchQueue.main.asyncAfter(deadline: .now() + 3) { _ = tap } }
        tap = nil
        displayLayer.sampleBufferRenderer.flush(removingDisplayedImage: true, completionHandler: nil)
        displayLayer.removeFromSuperlayer()
    }

    /// VLC 3 은 출력 방식을 바꿔도 지금 출력은 그대로라, 영상 트랙을 껐다 켜서 새로 만든다 (소리는 계속 나온다).
    /// 다시 켠 영상은 다음 키프레임까지 장면이 없어 몇 초씩 까맣게 남으므로, 지금 위치로 다시 이동해 앞 키프레임부터 풀게 한다.
    private func restartVideoOutput() {
        let track = player.currentVideoTrackIndex
        guard player.media != nil, track >= 0 else { return }
        player.currentVideoTrackIndex = -1
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self, player] in
            player.currentVideoTrackIndex = track
            guard let time = self?.model?.currentTime else { return }
            self?.model?.seek(to: time)
        }
    }

    // MARK: - 플레이어 상태 → PiP

    func subtitleChanged(_ text: String?) {
        renderSubtitle()
    }

    /// 화면 자막과 같은 모양(설정의 글꼴·크기·가장자리)으로 자막을 그림으로 찍어 장면에 입히게 한다
    private func renderSubtitle() {
        guard let tap else { return }
        let size = tap.frameSize
        guard let text = model?.subtitleText, !text.isEmpty, size.width > 0 else {
            tap.subtitle = nil
            return
        }
        // PiP 창 크기에 맞춘 기준 크기 (장면을 원래 크기로 받으므로 장면 높이 기준)
        let content = SubtitleText(text: text, baseSize: SubtitleText.compactBaseSize(for: size))
            .frame(maxWidth: size.width * 0.9)
            .padding(8)
        let renderer = ImageRenderer(content: content)
        renderer.scale = 1
        guard let image = renderer.cgImage else { return }
        tap.subtitle = PiPSubtitle(image: image, frameWidth: Int(size.width), frameHeight: Int(size.height))
    }

    /// 재생·멈춤·이동이 바뀌면 PiP 의 진행 표시를 맞춘다
    func playbackChanged() {
        guard isActive else { return }
        updateTimebase()
        controller?.invalidatePlaybackState()
    }

    private func updateTimebase() {
        guard let timebase = displayLayer.controlTimebase, let model else { return }
        CMTimebaseSetTime(timebase, time: CMTime(seconds: model.currentTime, preferredTimescale: 1000))
        CMTimebaseSetRate(timebase, rate: model.isPlaying ? Double(model.rate) : 0)
    }
}

extension SystemPiP: AVPictureInPictureSampleBufferPlaybackDelegate {
    nonisolated func pictureInPictureController(_ controller: AVPictureInPictureController, setPlaying playing: Bool) {
        Task { @MainActor in
            guard let model else { return }
            if model.isPlaying != playing { model.togglePlay() }
            playbackChanged()
        }
    }

    nonisolated func pictureInPictureControllerTimeRangeForPlayback(_ controller: AVPictureInPictureController) -> CMTimeRange {
        MainActor.assumeIsolated {
            guard let duration = model?.duration, duration > 0 else {
                return CMTimeRange(start: .negativeInfinity, duration: .positiveInfinity)
            }
            return CMTimeRange(start: .zero, duration: CMTime(seconds: duration, preferredTimescale: 1000))
        }
    }

    nonisolated func pictureInPictureControllerIsPlaybackPaused(_ controller: AVPictureInPictureController) -> Bool {
        MainActor.assumeIsolated { !(model?.isPlaying ?? false) }
    }

    nonisolated func pictureInPictureController(_ controller: AVPictureInPictureController, didTransitionToRenderSize newRenderSize: CMVideoDimensions) {}

    nonisolated func pictureInPictureController(_ controller: AVPictureInPictureController, skipByInterval skipInterval: CMTime) async {
        await MainActor.run {
            model?.skip(by: skipInterval.seconds)
            playbackChanged()
        }
    }
}

extension SystemPiP: AVPictureInPictureControllerDelegate {
    nonisolated func pictureInPictureControllerDidStartPictureInPicture(_ controller: AVPictureInPictureController) {
        Task { @MainActor in
            model?.isOpeningPiP = false
            PlayerHost.shared.hideForSystemPiP()
        }
    }

    nonisolated func pictureInPictureController(_ controller: AVPictureInPictureController,
                                                restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void) {
        Task { @MainActor in
            restored = true
            PlayerHost.shared.showAfterSystemPiP()
            completionHandler(true)
        }
    }

    nonisolated func pictureInPictureControllerDidStopPictureInPicture(_ controller: AVPictureInPictureController) {
        Task { @MainActor in
            finish()
            // ✕ 로 닫으면 플레이어도 닫는다 (위치는 닫을 때 저장된다)
            if restored {
                PlayerHost.shared.showAfterSystemPiP()
            } else {
                PlayerHost.shared.close()
            }
        }
    }

    nonisolated func pictureInPictureController(_ controller: AVPictureInPictureController, failedToStartPictureInPictureWithError error: any Error) {
        Task { @MainActor in
            model?.errorMessage = "PiP 를 시작하지 못했습니다: \(error.localizedDescription)"
            finish()
        }
    }
}

// MARK: - VLC 장면 받기

/// VLC 가 장면을 그려 넣을 픽셀 버퍼를 빌려주고, 다 그리면 자막을 입혀 PiP 레이어로 보낸다 (VLC 의 영상 스레드에서 불린다).
/// 디코더가 내놓는 형식(NV12, 또는 BGRA) 그대로, 원래 크기로 받는다: 줄이거나 형식을 바꾸면 VLC 가 소프트웨어(C)로 변환해
/// CPU 를 크게 쓴다 (실기기 측정: 1080p 를 BGRA 로 줄여 받으면 PiP 중 iRayer 38%, 4K 를 BGRA 디코딩인데 NV12 로 받으면 59%,
/// 둘 다 대부분 swscale). 줄이는 것은 PiP 레이어가 GPU 로 한다.
nonisolated final class FrameTap: @unchecked Sendable {
    private let layer: AVSampleBufferDisplayLayer?
    /// 레이어 대신 장면을 받을 곳 (AirPlay 로 보낼 HLS 압축기). 자막을 입힌 뒤 넘긴다.
    private let sink: ((CVPixelBuffer) -> Void)?
    private let lock = NSLock()
    private var pool: CVPixelBufferPool?
    /// 자막을 입힐 복사본용 (VLC 가 받은 버퍼를 다음 장면의 참고로도 쓰므로 그 버퍼에 직접 그리면 자막 둘레가 깨진다)
    private var outputPool: CVPixelBufferPool?
    private var formatDescription: CMVideoFormatDescription?
    /// 하드웨어 디코더 장면 (VLC 가 디코더 버퍼에서 복사해 넣으므로 우리 버퍼를 다음 장면의 참고로 쓰지 않는다 → 자막을 바로 입혀도 된다)
    private var fromHardware = false
    private(set) var width = 0
    private(set) var height = 0
    private var sentFirstFrame = false
    var onFirstFrame: (() -> Void)?

    /// 받는 장면 크기가 정해지면 (자막 그림을 그 크기에 맞춰 다시 만든다)
    var onSetup: (() -> Void)?
    /// 받는 장면 크기 (setup 전에는 0)
    var frameSize: CGSize { lock.withLock { CGSize(width: width, height: height) } }

    /// 입힐 자막 (장면 크기에 맞춰 YUV 로 바꿔 둔 것, 없으면 nil)
    var subtitle: PiPSubtitle? {
        get { lock.withLock { storedSubtitle } }
        set { lock.withLock { storedSubtitle = newValue } }
    }
    private var storedSubtitle: PiPSubtitle?

    init(layer: AVSampleBufferDisplayLayer) {
        self.layer = layer
        self.sink = nil
    }

    init(sink: @escaping (CVPixelBuffer) -> Void) {
        self.layer = nil
        self.sink = sink
    }

    /// 디코더가 BGRA 로 내놓는 영상 (VLC 형식 이름: CVPX_BGRA 등)
    private static let rgbChromas: Set = ["CVPB", "BGRA", "RV32", "RGBA", "ARGB"]

    /// VLC 가 알려준 원본 크기·형식을 받아, 받을 형식(디코더 형식 그대로, 크기 그대로)을 정한다. 0 이면 실패.
    func setup(chroma: UnsafeMutablePointer<CChar>, width: UnsafeMutablePointer<UInt32>, height: UnsafeMutablePointer<UInt32>,
               pitches: UnsafeMutablePointer<UInt32>, lines: UnsafeMutablePointer<UInt32>) -> UInt32 {
        let w = Int(width.pointee), h = Int(height.pointee)
        guard w > 0, h > 0 else { return 0 }
        let source = String(bytes: (0..<4).map { UInt8(bitPattern: chroma[$0]) }, encoding: .ascii) ?? ""
        let rgb = Self.rgbChromas.contains(source)
        // HD 이상은 BT.709, 그 아래는 BT.601 (VLC 가 따로 알려 주지 않는다)
        let matrix = h >= 720 ? kCVImageBufferYCbCrMatrix_ITU_R_709_2 : kCVImageBufferYCbCrMatrix_ITU_R_601_4
        let attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: rgb ? kCVPixelFormatType_32BGRA : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferWidthKey as String: w,
            kCVPixelBufferHeightKey as String: h,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
            kCVBufferPropagatedAttachmentsKey as String: [
                kCVImageBufferYCbCrMatrixKey as String: matrix,
                kCVImageBufferColorPrimariesKey as String: kCVImageBufferColorPrimaries_ITU_R_709_2,
                kCVImageBufferTransferFunctionKey as String: kCVImageBufferTransferFunction_ITU_R_709_2,
            ],
        ]
        var pool: CVPixelBufferPool?, outputPool: CVPixelBufferPool?
        CVPixelBufferPoolCreate(nil, [kCVPixelBufferPoolMinimumBufferCountKey: 4] as CFDictionary, attributes as CFDictionary, &pool)
        CVPixelBufferPoolCreate(nil, [kCVPixelBufferPoolMinimumBufferCountKey: 3] as CFDictionary, attributes as CFDictionary, &outputPool)
        guard let pool, let outputPool else { return 0 }
        var sample: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &sample)
        guard let sample else { return 0 }
        lock.withLock {
            self.pool = pool
            self.outputPool = outputPool
            self.width = w
            self.height = h
            self.formatDescription = nil
            self.fromHardware = source.hasPrefix("CVP")
            self.storedSubtitle = nil
        }
        onSetup?()
        (rgb ? "BGRA" : "NV12").utf8CString.withUnsafeBufferPointer { name in
            for index in 0..<4 { chroma[index] = name[index] }
        }
        if rgb {
            pitches[0] = UInt32(CVPixelBufferGetBytesPerRow(sample))
            lines[0] = UInt32(h)
        } else {
            // 밝기 판 + 색 판(Cb·Cr 이 번갈아)
            for plane in 0..<2 {
                pitches[plane] = UInt32(CVPixelBufferGetBytesPerRowOfPlane(sample, plane))
                lines[plane] = UInt32(CVPixelBufferGetHeightOfPlane(sample, plane))
            }
        }
        return 3
    }

    /// 최근에 빌려준 버퍼 (VLC 가 장면을 버리면 display 없이 끝나므로, 여기서 잡고 있다가 오래된 것부터 놓는다)
    private var recent: [CVPixelBuffer] = []

    /// 그릴 버퍼를 빌려준다 (그림 id = 픽셀 버퍼)
    func lockBuffer(_ planes: UnsafeMutablePointer<UnsafeMutableRawPointer?>) -> UnsafeMutableRawPointer? {
        guard let pool = lock.withLock({ pool }) else { return nil }
        var buffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
        guard let buffer else { return nil }
        lock.withLock {
            recent.append(buffer)
            if recent.count > 8 { recent.removeFirst() }
        }
        CVPixelBufferLockBaseAddress(buffer, [])
        if CVPixelBufferIsPlanar(buffer) {
            planes[0] = CVPixelBufferGetBaseAddressOfPlane(buffer, 0)
            planes[1] = CVPixelBufferGetBaseAddressOfPlane(buffer, 1)
        } else {
            planes[0] = CVPixelBufferGetBaseAddress(buffer)
        }
        return Unmanaged.passUnretained(buffer).toOpaque()
    }

    /// VLC 가 다 그렸다
    func unlock(_ picture: UnsafeMutableRawPointer?) {
        guard let picture else { return }
        CVPixelBufferUnlockBaseAddress(Unmanaged<CVPixelBuffer>.fromOpaque(picture).takeUnretainedValue(), [])
    }

    /// 보여줄 장면: 자막을 입히고 PiP 레이어로 보낸다
    func display(_ picture: UnsafeMutableRawPointer) {
        let buffer: CVPixelBuffer? = lock.withLock {
            recent.first { Unmanaged.passUnretained($0).toOpaque() == picture }
        }
        guard let buffer else { return }
        // 자막: 하드웨어 디코더 장면은 그 버퍼에 바로, 소프트웨어 디코더 장면은 복사본에 (디코더가 다음 장면의 참고로 쓴다)
        if let subtitle, lock.withLock({ fromHardware }) {
            CVPixelBufferLockBaseAddress(buffer, [])
            subtitle.blend(into: buffer)
            CVPixelBufferUnlockBaseAddress(buffer, [])
            enqueue(buffer)
        } else if let subtitle, let copy = copyForSubtitle(buffer) {
            CVPixelBufferLockBaseAddress(copy, [])
            subtitle.blend(into: copy)
            CVPixelBufferUnlockBaseAddress(copy, [])
            enqueue(copy)
        } else {
            enqueue(buffer)
        }
    }

    /// 장면을 복사본 버퍼로 (판마다 줄 간격 그대로)
    private func copyForSubtitle(_ source: CVPixelBuffer) -> CVPixelBuffer? {
        guard let outputPool = lock.withLock({ outputPool }) else { return nil }
        var output: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, outputPool, &output)
        guard let output else { return nil }
        CVPixelBufferLockBaseAddress(source, .readOnly)
        CVPixelBufferLockBaseAddress(output, [])
        defer {
            CVPixelBufferUnlockBaseAddress(output, [])
            CVPixelBufferUnlockBaseAddress(source, .readOnly)
        }
        let planar = CVPixelBufferIsPlanar(source)
        for plane in 0..<(planar ? 2 : 1) {
            guard let from = planar ? CVPixelBufferGetBaseAddressOfPlane(source, plane) : CVPixelBufferGetBaseAddress(source),
                  let to = planar ? CVPixelBufferGetBaseAddressOfPlane(output, plane) : CVPixelBufferGetBaseAddress(output) else { return nil }
            let fromPitch = planar ? CVPixelBufferGetBytesPerRowOfPlane(source, plane) : CVPixelBufferGetBytesPerRow(source)
            let toPitch = planar ? CVPixelBufferGetBytesPerRowOfPlane(output, plane) : CVPixelBufferGetBytesPerRow(output)
            let rows = planar ? CVPixelBufferGetHeightOfPlane(source, plane) : CVPixelBufferGetHeight(source)
            if fromPitch == toPitch {
                memcpy(to, from, fromPitch * rows)
            } else {
                let bytes = min(fromPitch, toPitch)
                for row in 0..<rows { memcpy(to + row * toPitch, from + row * fromPitch, bytes) }
            }
        }
        return output
    }

    private func enqueue(_ buffer: CVPixelBuffer) {
        if let sink {
            sink(buffer)
            return
        }
        guard let layer else { return }
        let description: CMVideoFormatDescription? = lock.withLock {
            if formatDescription == nil {
                CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: buffer, formatDescriptionOut: &formatDescription)
            }
            return formatDescription
        }
        guard let description else { return }
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()), decodeTimeStamp: .invalid)
        var sampleBuffer: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: buffer, formatDescription: description,
                                                 sampleTiming: &timing, sampleBufferOut: &sampleBuffer)
        guard let sampleBuffer else { return }
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: true),
           CFArrayGetCount(attachments) > 0 {
            let dictionary = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(dictionary, Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        let renderer = layer.sampleBufferRenderer
        if renderer.status == .failed { renderer.flush() }
        renderer.enqueue(sampleBuffer)
        let first: (() -> Void)? = lock.withLock {
            guard !sentFirstFrame else { return nil }
            sentFirstFrame = true
            return onFirstFrame
        }
        first?()
    }
}

/// NV12 장면에 입힐 자막: 그림을 밝기·색 판으로 바꾸고 알파를 곱해 둔다 (자막이 바뀔 때 한 번).
/// 장면마다는 vImage 로 그 자리에 섞기만 한다.
nonisolated final class PiPSubtitle: @unchecked Sendable {
    /// 장면 안 자리 (왼쪽 위, 짝수)
    private let x: Int
    private let y: Int
    /// 크기 (짝수)
    private let width: Int
    private let height: Int
    /// 알파를 곱한 밝기·알파 (width × height), 알파를 곱한 Cb·Cr 번갈아·알파 (width × height/2)
    private var lumaTop: vImage_Buffer
    private var lumaAlpha: vImage_Buffer
    private var chromaTop: vImage_Buffer
    private var chromaAlpha: vImage_Buffer
    /// BGRA 장면용: 알파를 곱한 그림 그대로
    private var bgraTop: vImage_Buffer

    /// image: 화면 자막을 찍은 그림. 장면 아래 가운데, 높이의 5% 위에 놓는다.
    init?(image: CGImage, frameWidth: Int, frameHeight: Int) {
        let w = min(image.width, frameWidth) / 2 * 2, h = min(image.height, frameHeight) / 2 * 2
        guard w >= 2, h >= 2 else { return nil }
        width = w
        height = h
        x = max(0, (frameWidth - w) / 2) / 2 * 2
        y = max(0, frameHeight - h - frameHeight / 20) / 2 * 2

        // 1) 그림 → 알파를 곱하지 않은 BGRA (알파를 곱한 것은 BGRA 장면용으로 남겨 둔다)
        guard var bgra = try? vImage_Buffer(width: w, height: h, bitsPerPixel: 32),
              var premultiplied = try? vImage_Buffer(width: w, height: h, bitsPerPixel: 32) else { return nil }
        defer { bgra.free() }
        guard let context = CGContext(data: bgra.data, width: w, height: h, bitsPerComponent: 8, bytesPerRow: bgra.rowBytes,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else { return nil }
        // 새로 잡은 메모리에는 예전 값이 남아 있어 먼저 비운다 (안 비우면 투명한 자리에 그 값이 섞여 네모난 노이즈가 된다)
        context.clear(CGRect(x: 0, y: 0, width: w, height: h))
        context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        vImageCopyBuffer(&bgra, &premultiplied, 4, vImage_Flags(kvImageNoFlags))
        bgraTop = premultiplied
        vImageUnpremultiplyData_RGBA8888(&bgra, &bgra, vImage_Flags(kvImageNoFlags))

        // 2) BGRA → 밝기 판 + Cb·Cr 판 (비디오 범위, BT.601: 흰 글자·검은 테두리라 차이가 보이지 않는다)
        guard var luma = try? vImage_Buffer(width: w, height: h, bitsPerPixel: 8),
              var chroma = try? vImage_Buffer(width: w, height: h / 2, bitsPerPixel: 8),
              var alpha = try? vImage_Buffer(width: w, height: h, bitsPerPixel: 8),
              var halfAlpha = try? vImage_Buffer(width: w, height: h / 2, bitsPerPixel: 8) else { return nil }
        var range = vImage_YpCbCrPixelRange(Yp_bias: 16, CbCr_bias: 128, YpRangeMax: 235, CbCrRangeMax: 240,
                                            YpMax: 235, YpMin: 16, CbCrMax: 240, CbCrMin: 16)
        var info = vImage_ARGBToYpCbCr()
        vImageConvert_ARGBToYpCbCr_GenerateConversion(kvImage_ARGBToYpCbCrMatrix_ITU_R_601_4, &range, &info,
                                                      kvImageARGB8888, kvImage420Yp8_CbCr8, vImage_Flags(kvImageNoFlags))
        // 메모리 순서 B G R A → A R G B
        var permute: [UInt8] = [3, 2, 1, 0]
        vImageConvert_ARGB8888To420Yp8_CbCr8(&bgra, &luma, &chroma, &info, &permute, vImage_Flags(kvImageNoFlags))
        vImageExtractChannel_ARGB8888(&bgra, &alpha, 3, vImage_Flags(kvImageNoFlags))
        vImageScale_Planar8(&alpha, &halfAlpha, nil, vImage_Flags(kvImageNoFlags))

        // 3) 알파를 곱해 둔다 (섞을 때 위 + (1 - 알파) × 아래)
        vImagePremultiplyData_Planar8(&luma, &alpha, &luma, vImage_Flags(kvImageNoFlags))
        vImagePremultiplyData_Planar8(&chroma, &halfAlpha, &chroma, vImage_Flags(kvImageNoFlags))
        lumaTop = luma
        lumaAlpha = alpha
        chromaTop = chroma
        chromaAlpha = halfAlpha
    }

    deinit {
        lumaTop.free()
        lumaAlpha.free()
        chromaTop.free()
        chromaAlpha.free()
        bgraTop.free()
    }

    /// 잠근 버퍼(NV12 또는 BGRA)의 자막 자리에 섞는다
    func blend(into buffer: CVPixelBuffer) {
        guard CVPixelBufferGetWidth(buffer) >= x + width, CVPixelBufferGetHeight(buffer) >= y + height else { return }
        if !CVPixelBufferIsPlanar(buffer) {
            guard let base = CVPixelBufferGetBaseAddress(buffer) else { return }
            let pitch = CVPixelBufferGetBytesPerRow(buffer)
            var bottom = vImage_Buffer(data: base + y * pitch + x * 4, height: vImagePixelCount(height),
                                       width: vImagePixelCount(width), rowBytes: pitch)
            vImagePremultipliedAlphaBlend_BGRA8888(&bgraTop, &bottom, &bottom, vImage_Flags(kvImageNoFlags))
            return
        }
        guard CVPixelBufferGetWidth(buffer) >= x + width, CVPixelBufferGetHeight(buffer) >= y + height,
              let lumaBase = CVPixelBufferGetBaseAddressOfPlane(buffer, 0),
              let chromaBase = CVPixelBufferGetBaseAddressOfPlane(buffer, 1) else { return }
        let lumaPitch = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        let chromaPitch = CVPixelBufferGetBytesPerRowOfPlane(buffer, 1)
        var lumaBottom = vImage_Buffer(data: lumaBase + y * lumaPitch + x, height: vImagePixelCount(height),
                                       width: vImagePixelCount(width), rowBytes: lumaPitch)
        var chromaBottom = vImage_Buffer(data: chromaBase + (y / 2) * chromaPitch + x, height: vImagePixelCount(height / 2),
                                         width: vImagePixelCount(width), rowBytes: chromaPitch)
        vImagePremultipliedAlphaBlend_Planar8(&lumaTop, &lumaAlpha, &lumaBottom, &lumaBottom, vImage_Flags(kvImageNoFlags))
        vImagePremultipliedAlphaBlend_Planar8(&chromaTop, &chromaAlpha, &chromaBottom, &chromaBottom, vImage_Flags(kvImageNoFlags))
    }
}

// MARK: - libvlc (MobileVLCKit 3 안에 있지만 헤더가 없어 이름으로 찾는다)

nonisolated final class LibVLC {
    static let shared = LibVLC()

    private typealias LockCallback = @convention(c) (UnsafeMutableRawPointer?, UnsafeMutablePointer<UnsafeMutableRawPointer?>?) -> UnsafeMutableRawPointer?
    private typealias UnlockCallback = @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?, UnsafePointer<UnsafeMutableRawPointer?>?) -> Void
    private typealias DisplayCallback = @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> Void
    private typealias SetupCallback = @convention(c) (UnsafeMutablePointer<UnsafeMutableRawPointer?>?, UnsafeMutablePointer<CChar>?,
                                                       UnsafeMutablePointer<UInt32>?, UnsafeMutablePointer<UInt32>?,
                                                       UnsafeMutablePointer<UInt32>?, UnsafeMutablePointer<UInt32>?) -> UInt32
    private typealias CleanupCallback = @convention(c) (UnsafeMutableRawPointer?) -> Void

    private let setCallbacksFunction: @convention(c) (OpaquePointer, LockCallback?, UnlockCallback?, DisplayCallback?, UnsafeMutableRawPointer?) -> Void
    private let setFormatCallbacksFunction: @convention(c) (OpaquePointer, SetupCallback?, CleanupCallback?) -> Void
    /// var_SetChecked / var_GetChecked (vlc_value_t 는 8바이트 공용체라 정수로 넘긴다)
    private let varSet: @convention(c) (OpaquePointer, UnsafePointer<CChar>, Int32, UInt64) -> Int32
    private let varGet: @convention(c) (OpaquePointer, UnsafePointer<CChar>, Int32, UnsafeMutablePointer<UInt64>) -> Int32
    private let varCreate: @convention(c) (OpaquePointer, UnsafePointer<CChar>, Int32) -> Int32
    private let varDestroy: @convention(c) (OpaquePointer, UnsafePointer<CChar>) -> Void
    private static let stringType: Int32 = 0x0040

    private init?() {
        let handle = UnsafeMutableRawPointer(bitPattern: -2) // RTLD_DEFAULT
        guard let setCallbacks = dlsym(handle, "libvlc_video_set_callbacks"),
              let setFormat = dlsym(handle, "libvlc_video_set_format_callbacks"),
              let set = dlsym(handle, "var_SetChecked"), let get = dlsym(handle, "var_GetChecked"),
              let create = dlsym(handle, "var_Create"), let destroy = dlsym(handle, "var_Destroy") else { return nil }
        setCallbacksFunction = unsafeBitCast(setCallbacks, to: (@convention(c) (OpaquePointer, LockCallback?, UnlockCallback?, DisplayCallback?, UnsafeMutableRawPointer?) -> Void).self)
        setFormatCallbacksFunction = unsafeBitCast(setFormat, to: (@convention(c) (OpaquePointer, SetupCallback?, CleanupCallback?) -> Void).self)
        varSet = unsafeBitCast(set, to: (@convention(c) (OpaquePointer, UnsafePointer<CChar>, Int32, UInt64) -> Int32).self)
        varGet = unsafeBitCast(get, to: (@convention(c) (OpaquePointer, UnsafePointer<CChar>, Int32, UnsafeMutablePointer<UInt64>) -> Int32).self)
        varCreate = unsafeBitCast(create, to: (@convention(c) (OpaquePointer, UnsafePointer<CChar>, Int32) -> Int32).self)
        varDestroy = unsafeBitCast(destroy, to: (@convention(c) (OpaquePointer, UnsafePointer<CChar>) -> Void).self)
    }

    /// VLCMediaPlayer 안의 libvlc_media_player_t (비공개 속성 playerInstance)
    static func playerInstance(_ player: VLCMediaPlayer) -> OpaquePointer? {
        let selector = NSSelectorFromString("playerInstance")
        guard let method = class_getInstanceMethod(VLCMediaPlayer.self, selector) else { return nil }
        typealias Getter = @convention(c) (AnyObject, Selector) -> OpaquePointer?
        return unsafeBitCast(method_getImplementation(method), to: Getter.self)(player, selector)
    }

    func getString(_ object: OpaquePointer, _ name: String) -> String? {
        var value: UInt64 = 0
        guard varGet(object, name, Self.stringType, &value) == 0, let pointer = UnsafeMutablePointer<CChar>(bitPattern: UInt(value)) else { return nil }
        defer { free(pointer) }
        return String(cString: pointer)
    }

    /// 정한다 (플레이어에 있는 설정만)
    func setString(_ object: OpaquePointer, _ name: String, _ value: String) {
        value.withCString { pointer in
            _ = varSet(object, name, Self.stringType, UInt64(UInt(bitPattern: pointer)))
        }
    }

    /// 플레이어에 없는 설정을 만들어 정한다 (디코더는 위로 올라가며 찾아 쓴다). 되돌릴 때는 removeOwn 으로 지운다.
    func setOwn(_ object: OpaquePointer, _ name: String, _ value: String) {
        _ = varCreate(object, name, Self.stringType)
        setString(object, name, value)
    }

    func removeOwn(_ object: OpaquePointer, _ name: String) {
        varDestroy(object, name)
    }

    /// 장면 받기로 바꾼다. tap 은 부르는 쪽이 VLC 가 출력을 닫을 때까지 살려 둔다 (출력은 여러 번 다시 만들어질 수 있다).
    func setCallbacks(_ player: OpaquePointer, tap: FrameTap) {
        let opaque = Unmanaged.passUnretained(tap).toOpaque()
        setFormatCallbacksFunction(player, { opaque, chroma, width, height, pitches, lines in
            guard let opaque, let tapPointer = opaque.pointee, let chroma, let width, let height, let pitches, let lines else { return 0 }
            return Unmanaged<FrameTap>.fromOpaque(tapPointer).takeUnretainedValue()
                .setup(chroma: chroma, width: width, height: height, pitches: pitches, lines: lines)
        }, { _ in })
        setCallbacksFunction(player, { opaque, planes in
            guard let opaque, let planes else { return nil }
            return Unmanaged<FrameTap>.fromOpaque(opaque).takeUnretainedValue().lockBuffer(planes)
        }, { opaque, picture, _ in
            guard let opaque else { return }
            Unmanaged<FrameTap>.fromOpaque(opaque).takeUnretainedValue().unlock(picture)
        }, { opaque, picture in
            guard let opaque, let picture else { return }
            Unmanaged<FrameTap>.fromOpaque(opaque).takeUnretainedValue().display(picture)
        }, opaque)
    }
}
#endif
