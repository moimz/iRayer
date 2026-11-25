import CoreGraphics
import FFmpeg
import Foundation

/// FFmpeg 로 영상 파일에서 한 장면을 뽑는다. iNAS 파일 제공 확장의 VideoFrame.swift 에서 가져와
/// NAS(SMB) 읽기 대신 로컬 파일을 읽게 바꿨다 (2026-11-25).
/// iNAS 의 최소 FFmpeg 는 file 프로토콜이 빠져 있어(경로로 열면 AVERROR_PROTOCOL_NOT_FOUND) 읽기·찾기 콜백으로 넘긴다.
enum VideoFrame {
    /// AVERROR_EOF = -MKTAG('E','O','F',' ')
    private static let eof: Int32 = -0x2046_4F45

    static func image(path: String, maxPixels: Int) -> CGImage? {
        guard let reader = FileReader(path: path) else { return nil }
        let opaque = Unmanaged.passUnretained(reader).toOpaque()
        let bufferSize: Int32 = 64 << 10
        guard let buffer = av_malloc(Int(bufferSize))?.assumingMemoryBound(to: UInt8.self) else { return nil }
        let read: @convention(c) (UnsafeMutableRawPointer?, UnsafeMutablePointer<UInt8>?, Int32) -> Int32 = { opaque, buf, size in
            guard let opaque, let buf else { return VideoFrame.eof }
            let reader = Unmanaged<FileReader>.fromOpaque(opaque).takeUnretainedValue()
            let count = reader.read(into: buf, count: Int(size))
            return count > 0 ? Int32(count) : VideoFrame.eof
        }
        let seek: @convention(c) (UnsafeMutableRawPointer?, Int64, Int32) -> Int64 = { opaque, offset, whence in
            guard let opaque else { return -1 }
            let reader = Unmanaged<FileReader>.fromOpaque(opaque).takeUnretainedValue()
            switch whence & ~AVSEEK_FORCE {
            case AVSEEK_SIZE: return reader.size
            case SEEK_SET: reader.position = offset
            case SEEK_CUR: reader.position += offset
            case SEEK_END: reader.position = reader.size + offset
            default: return -1
            }
            return reader.position
        }
        guard var io = avio_alloc_context(buffer, bufferSize, 0, opaque, read, nil, seek) else {
            av_free(buffer)
            return nil
        }
        defer {
            av_freep(&io.pointee.buffer)
            var ioPointer: UnsafeMutablePointer<AVIOContext>? = io
            avio_context_free(&ioPointer)
        }

        var format = avformat_alloc_context()
        format?.pointee.pb = io
        format?.pointee.flags |= AVFMT_FLAG_CUSTOM_IO
        format?.pointee.probesize = 4 << 20
        format?.pointee.max_analyze_duration = 2 * Int64(AV_TIME_BASE)
        guard avformat_open_input(&format, nil, nil, nil) == 0, let context = format else { return nil }
        defer { avformat_close_input(&format) }
        guard avformat_find_stream_info(context, nil) >= 0 else { return nil }

        var codec: UnsafePointer<AVCodec>?
        let index = av_find_best_stream(context, AVMEDIA_TYPE_VIDEO, -1, -1, &codec, 0)
        guard index >= 0, let codec, let stream = context.pointee.streams[Int(index)] else { return nil }
        var decoder = avcodec_alloc_context3(codec)
        defer { avcodec_free_context(&decoder) }
        guard let decoder, avcodec_parameters_to_context(decoder, stream.pointee.codecpar) >= 0 else { return nil }
        // 확장은 메모리 한도가 작다 → 디코딩 스레드 하나 (스레드마다 프레임 버퍼를 따로 잡는다)
        decoder.pointee.thread_count = 1
        // 바뀜 (2026-11-25, 사용자: iNAS 썸네일 실패 정리 반영): iNAS 와 같이 썸네일이니 화질 보정 생략 → 메모리·시간 덜 씀
        decoder.pointee.flags2 |= AV_CODEC_FLAG2_FAST
        decoder.pointee.skip_loop_filter = AVDISCARD_ALL
        guard avcodec_open2(decoder, codec, nil) >= 0 else { return nil }

        var packet = av_packet_alloc()
        var frame = av_frame_alloc()
        defer {
            av_packet_free(&packet)
            av_frame_free(&frame)
        }
        guard let packet, let frame else { return nil }

        // 앞쪽 검은 화면을 피해 전체의 10% (최대 30초) 근처 키프레임으로
        // 바뀜 (2026-11-25, 사용자: iNAS 썸네일 실패 정리 반영): iNAS 처럼 최대 2분, 장면이 거의 검으면 1분씩 뒤로 두 번 더.
        // 찾은 뒤 디코더를 비운다 (전에 넣은 패킷이 남아 엉뚱한 장면이 나오지 않게)
        let duration = context.pointee.duration
        let base = duration > 0 ? min(duration / 10, 120 * Int64(AV_TIME_BASE)) : 0
        var fallback: CGImage?
        for attempt in 0..<3 {
            let target = base + Int64(attempt) * 60 * Int64(AV_TIME_BASE)
            if duration > 0, target < duration {
                avformat_seek_file(context, -1, Int64.min, target, target, 0)
                avcodec_flush_buffers(decoder)
            } else if attempt > 0 {
                break
            }
            guard let image = decode(context: context, decoder: decoder, stream: index, packet: packet, frame: frame,
                                     maxPixels: maxPixels) else { break }
            if !isDark(image) { return image }
            fallback = fallback ?? image
        }
        return fallback
    }

    /// 지금 위치에서 처음 나오는 영상 프레임 하나
    private static func decode(context: UnsafeMutablePointer<AVFormatContext>, decoder: UnsafeMutablePointer<AVCodecContext>,
                               stream index: Int32, packet: UnsafeMutablePointer<AVPacket>, frame: UnsafeMutablePointer<AVFrame>,
                               maxPixels: Int) -> CGImage? {
        var packets = 0
        while packets < 600, av_read_frame(context, packet) >= 0 {
            defer { av_packet_unref(packet) }
            guard packet.pointee.stream_index == index else { continue }
            packets += 1
            guard avcodec_send_packet(decoder, packet) >= 0 else { continue }
            if avcodec_receive_frame(decoder, frame) == 0 {
                return image(from: frame, maxPixels: maxPixels)
            }
        }
        // 남은 프레임 꺼내기
        avcodec_send_packet(decoder, nil)
        if avcodec_receive_frame(decoder, frame) == 0 { return image(from: frame, maxPixels: maxPixels) }
        return nil
    }

    /// 거의 검은 화면인지 (16x16 으로 줄여 밝기 평균, iNAS 와 같은 기준)
    private static func isDark(_ image: CGImage) -> Bool {
        var pixels = [UInt8](repeating: 0, count: 16 * 16 * 4)
        let drawn = pixels.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(data: raw.baseAddress, width: 16, height: 16, bitsPerComponent: 8, bytesPerRow: 64,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: 16, height: 16))
            return true
        }
        guard drawn else { return false }
        var total = 0
        for i in stride(from: 0, to: pixels.count, by: 4) { total += Int(pixels[i]) + Int(pixels[i + 1]) + Int(pixels[i + 2]) }
        return total / (16 * 16 * 3) < 24
    }

    /// 디코딩한 프레임을 긴 변 maxPixels 이하 RGBA CGImage 로
    private static func image(from frame: UnsafeMutablePointer<AVFrame>, maxPixels: Int) -> CGImage? {
        let width = Int(frame.pointee.width), height = Int(frame.pointee.height)
        guard width > 0, height > 0 else { return nil }
        // 화면 비율(SAR) 반영
        let sar = frame.pointee.sample_aspect_ratio
        let displayWidth = sar.num > 0 && sar.den > 0 ? Double(width) * Double(sar.num) / Double(sar.den) : Double(width)
        let scale = min(1, Double(maxPixels) / max(displayWidth, Double(height)))
        let outWidth = max(1, Int(displayWidth * scale)), outHeight = max(1, Int(Double(height) * scale))
        guard let sws = sws_getContext(Int32(width), Int32(height), AVPixelFormat(frame.pointee.format),
                                       Int32(outWidth), Int32(outHeight), AV_PIX_FMT_RGBA,
                                       Int32(SWS_BILINEAR.rawValue), nil, nil, nil) else { return nil }
        defer { sws_freeContext(sws) }
        let bytesPerRow = outWidth * 4
        var pixels = Data(count: bytesPerRow * outHeight)
        let ok = pixels.withUnsafeMutableBytes { raw -> Bool in
            var destination: [UnsafeMutablePointer<UInt8>?] = [raw.baseAddress?.assumingMemoryBound(to: UInt8.self), nil, nil, nil]
            var strides: [Int32] = [Int32(bytesPerRow), 0, 0, 0]
            let source = withUnsafePointer(to: &frame.pointee.data) {
                $0.withMemoryRebound(to: UnsafePointer<UInt8>?.self, capacity: 8) { Array(UnsafeBufferPointer(start: $0, count: 8)) }
            }
            let sourceStrides = withUnsafePointer(to: &frame.pointee.linesize) {
                $0.withMemoryRebound(to: Int32.self, capacity: 8) { Array(UnsafeBufferPointer(start: $0, count: 8)) }
            }
            return sws_scale(sws, source, sourceStrides, 0, Int32(height), &destination, &strides) > 0
        }
        guard ok, let provider = CGDataProvider(data: pixels as CFData) else { return nil }
        return CGImage(width: outWidth, height: outHeight, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: bytesPerRow,
                       space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}

/// FFmpeg 읽기·찾기 콜백용 로컬 파일 (pread 라 위치는 따로 들고 다닌다)
private final class FileReader {
    let fd: Int32
    let size: Int64
    var position: Int64 = 0

    init?(path: String) {
        fd = open(path, O_RDONLY)
        guard fd >= 0 else { return nil }
        var info = stat()
        guard fstat(fd, &info) == 0 else { close(fd); return nil }
        size = Int64(info.st_size)
    }

    deinit { close(fd) }

    /// 바뀜 (2026-11-25, 사용자: iNAS 썸네일 실패 정리 반영): 이상한 파일에서 오래 붙잡혀 다음 썸네일을 막지 않게
    /// 열고 30초가 지나면 끝난 것처럼 답해 FFmpeg 가 그만두게 한다 (iNAS 는 FFmpeg 90초·읽기 20초, 여기는 로컬 파일이라 짧게)
    private let deadline = Date().addingTimeInterval(30)

    /// 지금 위치부터 최대 count 바이트. 끝이면 0, 실패면 -1.
    func read(into buffer: UnsafeMutablePointer<UInt8>, count: Int) -> Int {
        guard position < size, Date() < deadline else { return 0 }
        let n = pread(fd, buffer, count, off_t(position))
        if n > 0 { position += Int64(n) }
        return n
    }
}
