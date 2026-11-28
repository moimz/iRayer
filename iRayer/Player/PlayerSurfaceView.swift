import AVFoundation
import MediaPlayer
import SwiftUI
import UIKit

/// 영상이 그려지는 화면 + nPlayer 방식 제스처
struct PlayerSurface: UIViewRepresentable {
    let model: PlayerModel

    func makeUIView(context: Context) -> PlayerSurfaceView {
        PlayerSurfaceView(model: model)
    }

    func updateUIView(_ view: PlayerSurfaceView, context: Context) {
        view.videoSizeChanged(model.videoSize)
    }
}

final class PlayerSurfaceView: UIView, UIGestureRecognizerDelegate {
    /// 화면 크기 상태: contain(기본) / cover(꽉 채움, 이동 불가) / custom(핀치 확대, 드래그로 이동)
    enum ZoomMode {
        case contain, cover, custom
    }

    private enum PanMode {
        /// 아직 방향을 정하지 않음 (decisionDistance 만큼 움직일 때까지 지켜본다)
        case undecided
        case seek, brightness, volume, move
    }

    /// 이만큼 움직인 뒤에 가로·세로 중 더 많이 간 쪽으로 정한다. 처음 몇 pt 는 손가락이 닿으며 흔들려 방향이 잘 안 맞는다.
    private var decisionDistance: CGFloat { settings.gestureDecisionDistance }

    private let model: PlayerModel
    private let settings = AppSettings.shared
    /// VLC 가 영상을 그리는 뷰. 확대·이동은 이 뷰의 transform 으로 처리한다.
    private let videoView = UIView()
    /// 시스템 볼륨 조절용. 화면에 붙이지 않아서 볼륨을 바꾸면 iOS 기본 볼륨 표시가 뜬다 (볼륨 버튼을 누를 때와 같게).
    private let volumeView = MPVolumeView(frame: CGRect(x: -100, y: -100, width: 10, height: 10))

    private var zoomMode = ZoomMode.contain
    private var zoomScale: CGFloat = 1
    private var zoomOffset = CGPoint.zero
    private var videoSize = CGSize.zero

    private var panMode = PanMode.seek
    private var panStartTime: Double = 0
    private var panStartValue: Float = 0
    private var panStartOffset = CGPoint.zero
    private var panStartPoint = CGPoint.zero
    private var panStartBrightness: Float = 0.5
    private var pinchStartScale: CGFloat = 1
    private var ownRecognizers: [UIGestureRecognizer] = []

    init(model: PlayerModel) {
        self.model = model
        super.init(frame: .zero)
        backgroundColor = .black
        clipsToBounds = true

        videoView.isUserInteractionEnabled = false
        addSubview(videoView)
        model.attach(to: videoView)

        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap))
        doubleTap.numberOfTapsRequired = 2
        let singleTap = UITapGestureRecognizer(target: self, action: #selector(handleSingleTap))
        singleTap.require(toFail: doubleTap)
        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan))
        pan.maximumNumberOfTouches = 1
        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch))
        ownRecognizers = [doubleTap, singleTap, pan, pinch]
        ownRecognizers.forEach {
            $0.delegate = self
            addGestureRecognizer($0)
        }
    }

    /// 아래쪽 컨트롤(진행률 바·버튼) 위의 터치는 화면 제스처(드래그 탐색·탭)가 가져가지 않게 한다.
    /// 그대로 두면 이 뷰의 인식기가 먼저 잡아서 SwiftUI 진행률 바의 드래그가 동작하지 않는다.
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        guard let window else { return true }
        let point = touch.location(in: window)
        // 화면 위아래 가장자리에서 시작한 드래그는 시스템 몫 (홈 바·앱 전환, 알림 센터·제어 센터): 볼륨·밝기·탐색이 같이 움직이지 않게
        if gestureRecognizer is UIPanGestureRecognizer {
            let edge = window.safeAreaInsets
            if point.y > window.bounds.height - max(edge.bottom, 20) - Self.edgeGuard || point.y < max(edge.top, 20) + Self.edgeGuard {
                return false
            }
        }
        guard model.controlsVisible else { return true }
        return ![model.bottomControlsFrame, model.topControlsFrame].contains { $0.insetBy(dx: -8, dy: -12).contains(point) }
    }

    /// 위아래 가장자리 안전지대 (안전 영역 바깥 + 이만큼)
    private static let edgeGuard: CGFloat = 30

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError()
    }

    /// VLC 의 영상 뷰가 상위 뷰(이 뷰)에 자기 탭 인식기를 붙이는데, 그게 탭을 먼저 가져가 UI 표시 탭이 무시된다.
    /// 직접 만든 인식기만 붙인다.
    override func addGestureRecognizer(_ gestureRecognizer: UIGestureRecognizer) {
        guard ownRecognizers.contains(gestureRecognizer) else { return }
        super.addGestureRecognizer(gestureRecognizer)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        videoView.bounds = CGRect(origin: .zero, size: bounds.size)
        videoView.center = CGPoint(x: bounds.midX, y: bounds.midY)
        applyZoom()
    }

    /// 바뀜 (2026-11-28, 사용자: 기기 안 영상이 가로에서 1~2초 작게 나왔다 커짐): 플레이어가 뜨며 이 뷰가 작게 시작해 커지는데,
    /// 마지막 크기 변경(0.27초쯤) 뒤 layoutSubviews 가 불리지 않아 영상 뷰(VLC 가 그리는 뷰)가 처음의 작은 크기로 남았다
    /// (조작 단추가 숨으며 다시 배치될 때 4초쯤에야 맞춰짐, 화면 크기 기록으로 확인). 크기가 다르면 바로 다시 배치한다.
    /// 첫 장면이 늦게 나오는 NAS 영상은 그동안 화면이 까매서 안 보였다. PlayerModel 이 재생 상태를 갱신할 때마다 부른다.
    func syncVideoViewSize() {
        guard videoView.bounds.size != bounds.size else { return }
        setNeedsLayout()
        layoutIfNeeded()
    }

    override var bounds: CGRect {
        didSet { if bounds.size != oldValue.size { setNeedsLayout() } }
    }

    override var frame: CGRect {
        didSet { if frame.size != oldValue.size { setNeedsLayout() } }
    }

    func videoSizeChanged(_ size: CGSize) {
        guard size != videoSize else { return }
        videoSize = size
        applyZoom()
    }

    // MARK: - 탭

    @objc private func handleSingleTap() {
        model.toggleControls()
    }

    /// 화면을 가로 3등분: 왼쪽 = 뒤로, 가운데 = 화면 크기 전환, 오른쪽 = 앞으로
    @objc private func handleDoubleTap(_ gesture: UITapGestureRecognizer) {
        let x = gesture.location(in: self).x
        let third = bounds.width / 3
        if x < third {
            model.skip(by: -Double(settings.skipSeconds))
        } else if x > third * 2 {
            model.skip(by: Double(settings.skipSeconds))
        } else {
            switch zoomMode {
            case .contain:
                zoomMode = .cover
            case .cover, .custom:
                zoomMode = .contain
            }
            zoomOffset = .zero
            UIView.animate(withDuration: 0.25) { self.applyZoom() }
        }
    }

    // MARK: - 드래그

    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        let translation = gesture.translation(in: self)

        switch gesture.state {
        case .began:
            if zoomMode == .custom {
                panMode = .move
                panStartOffset = zoomOffset
            } else {
                panMode = .undecided
                panStartPoint = gesture.location(in: self)
                panStartTime = model.currentTime
                panStartBrightness = Float(window?.windowScene?.screen.brightness ?? 0.5)
                panStartValue = AVAudioSession.sharedInstance().outputVolume
            }

        case .changed:
            // 충분히 움직이면 더 많이 간 쪽으로 정한다 (한 번 정하면 손을 뗄 때까지 그대로).
            // 정하기 전에 움직인 만큼도 그대로 반영된다 (시작 값을 처음 닿은 때로 잡아 두었으므로).
            if panMode == .undecided {
                guard hypot(translation.x, translation.y) >= decisionDistance else { return }
                if abs(translation.x) > abs(translation.y) {
                    panMode = .seek
                    model.beginScrub()
                } else if panStartPoint.x < bounds.midX {
                    panMode = .brightness
                    panStartValue = panStartBrightness
                } else {
                    panMode = .volume
                }
            }
            switch panMode {
            case .undecided:
                break
            case .seek:
                model.updateScrub(to: panStartTime + Double(translation.x) * settings.seekSecondsPerPoint)
            case .brightness:
                let value = adjusted(panStartValue, by: translation.y)
                window?.windowScene?.screen.brightness = CGFloat(value)
                model.level = .init(kind: .brightness, value: value)
            case .volume:
                let value = adjusted(panStartValue, by: translation.y)
                // 표시는 iOS 기본 볼륨 표시가 한다 (밝기는 기본 표시가 없어서 우리가 그린다)
                volumeSlider?.value = value
            case .move:
                zoomOffset = CGPoint(x: panStartOffset.x + translation.x, y: panStartOffset.y + translation.y)
                applyZoom()
            }

        case .ended, .cancelled, .failed:
            if panMode == .seek {
                model.endScrub()
            }
            model.level = nil

        default:
            break
        }
    }

    /// 위로 올리면 증가. 화면 높이의 80% 를 드래그하면 0 → 1
    private func adjusted(_ start: Float, by dy: CGFloat) -> Float {
        let delta = Float(-dy / max(bounds.height * 0.8, 1))
        return min(max(start + delta, 0), 1)
    }

    private var volumeSlider: UISlider? {
        volumeView.subviews.compactMap { $0 as? UISlider }.first
    }

    // MARK: - 핀치

    @objc private func handlePinch(_ gesture: UIPinchGestureRecognizer) {
        switch gesture.state {
        case .began:
            pinchStartScale = currentScale
            if zoomMode == .cover {
                zoomScale = coverScale
            }
            zoomMode = .custom
        case .changed:
            zoomScale = min(max(pinchStartScale * gesture.scale, 1), maxScale)
            applyZoom()
        case .ended, .cancelled:
            if zoomScale <= 1.01 {
                zoomMode = .contain
                zoomOffset = .zero
                UIView.animate(withDuration: 0.2) { self.applyZoom() }
            }
        default:
            break
        }
    }

    // MARK: - 확대 계산

    /// 화면 안에 영상이 contain 으로 맞춰졌을 때의 영역
    private var fittedSize: CGSize {
        guard videoSize.width > 0, videoSize.height > 0 else { return bounds.size }
        return AVMakeRect(aspectRatio: videoSize, insideRect: bounds).size
    }

    /// cover 가 되려면 contain 에서 몇 배 키워야 하는지
    private var coverScale: CGFloat {
        let fitted = fittedSize
        guard fitted.width > 0, fitted.height > 0 else { return 1 }
        return max(bounds.width / fitted.width, bounds.height / fitted.height)
    }

    private var maxScale: CGFloat {
        max(CGFloat(settings.maxZoomScale), coverScale)
    }

    private var currentScale: CGFloat {
        switch zoomMode {
        case .contain: 1
        case .cover: coverScale
        case .custom: zoomScale
        }
    }

    private func applyZoom() {
        let scale = currentScale
        if zoomMode == .custom {
            // 영상 가장자리가 화면 안쪽으로 들어오지 않도록 이동 범위를 제한
            let fitted = fittedSize
            let limitX = max((fitted.width * scale - bounds.width) / 2, 0)
            let limitY = max((fitted.height * scale - bounds.height) / 2, 0)
            zoomOffset = CGPoint(
                x: min(max(zoomOffset.x, -limitX), limitX),
                y: min(max(zoomOffset.y, -limitY), limitY)
            )
        } else {
            zoomOffset = .zero
        }
        videoView.transform = CGAffineTransform(translationX: zoomOffset.x, y: zoomOffset.y).scaledBy(x: scale, y: scale)

        // 보이는 영상의 위치 (레터박스를 영상 색으로 채울 때 영상 자리는 비워 둔다)
        let size = CGSize(width: fittedSize.width * scale, height: fittedSize.height * scale)
        let frame = CGRect(x: bounds.midX + zoomOffset.x - size.width / 2, y: bounds.midY + zoomOffset.y - size.height / 2,
                           width: size.width, height: size.height).integral
        if model.videoFrame != frame || model.surfaceSize != bounds.size {
            model.videoFrame = frame
            model.surfaceSize = bounds.size
        }

        // 자막을 보이는 영상 아래쪽에 붙이기 위해, 화면 아래에서 영상 아래쪽 가장자리까지의 거리를 알린다
        let videoBottom = bounds.midY + zoomOffset.y + fittedSize.height * scale / 2
        let inset = max(bounds.height - videoBottom, 0).rounded()
        if model.videoBottomInset != inset {
            model.videoBottomInset = inset
        }
    }
}

extension PlayerSurfaceView {
}
