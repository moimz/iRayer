#if os(iOS)
import SwiftUI
import UIKit

/// 텍스트 보기 화면 (아이폰·아이패드): 세로로 읽기, 가운데를 누르면 조작, 아래 막대는 글자 위치 % (늘 왼→오).
/// 글은 읽기 전용 UITextView (TextKit 2 — 보이는 곳만 배치해 수 MB 소설도 괜찮다)
struct TextReaderView: View {
    @State private var model: TextReaderModel
    @State private var showsSettings = false
    @State private var settings = AppSettings.shared
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme

    init(book: TextBook) {
        _model = State(initialValue: TextReaderModel(book: book))
    }

    var body: some View {
        let dark = settings.textAppearance.isDark(colorScheme)
        let colors = settings.textTheme.colors(dark: dark)
        NavigationStack {
            ZStack {
                colors.background.ignoresSafeArea()
                // 조작(제목 막대)을 띄우고 숨길 때 글이 밀리지 않게 안전 영역을 무시하고, 노치·홈 막대만 글 상자가 직접 피한다
                TextPageView(model: model, style: TextStyle.current, dark: dark)
                    .ignoresSafeArea()
                if model.showsControls {
                    controls
                        .transition(.opacity)
                }
            }
            .navigationTitle(model.book.file.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("닫기", systemImage: "xmark") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    // 바뀜 (2026-11-08, 사용자): 만화와 같은 톱니
                    Button("보기 설정", systemImage: "gearshape.fill") { showsSettings = true }
                }
            }
            .toolbarVisibility(model.showsControls ? .visible : .hidden, for: .navigationBar)
            .toolbarBackgroundVisibility(.hidden, for: .navigationBar)
            // 위 그라데이션 위라 흰 단추 (만화와 같게)
            .toolbarColorScheme(.dark, for: .navigationBar)
        }
        .animation(.easeInOut(duration: 0.2), value: model.showsControls)
        .statusBarHidden(!model.showsControls)
        .persistentSystemOverlays(.hidden)
        .defersSystemGestures(on: UIDevice.current.userInterfaceIdiom == .phone ? .bottom : [])
        .onAppear { AppSettings.shared.applyIdleTimer(playing: true) }
        .onDisappear {
            model.saveProgress()
            AppSettings.shared.applyIdleTimer(playing: false)
        }
        .sheet(isPresented: $showsSettings) {
            NavigationStack {
                TextSettingsForm(model: model)
                    .navigationTitle("보기 설정")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("완료", systemImage: "checkmark") { showsSettings = false }
                        }
                    }
            }
            .presentationDetents([.medium, .large])
            // 시트 뒤 글이 보이며 바로 바뀌게 (흐리게 덮지 않는다)
            .presentationBackgroundInteraction(.enabled(upThrough: .medium))
        }
    }

    /// 바뀜 (2026-11-08, 사용자): 만화 보기와 같은 모양 — 위아래 그라데이션, 아래에 "37%" 줄 + 막대 + 유리 ▶
    private var controls: some View {
        ZStack {
            VStack(spacing: 0) {
                LinearGradient(colors: [.black.opacity(0.6), .clear], startPoint: .top, endPoint: .bottom)
                    .frame(height: 140)
                Spacer()
                LinearGradient(colors: [.clear, .black.opacity(0.7)], startPoint: .top, endPoint: .bottom)
                    .frame(height: 180)
            }
            .ignoresSafeArea()
            .allowsHitTesting(false)

            VStack {
                Spacer()
                VStack(spacing: 8) {
                    HStack {
                        Text("\(Int(model.fraction * 100))%")
                            .font(.subheadline.monospacedDigit().weight(.semibold))
                            .foregroundStyle(.white)
                        Spacer()
                    }
                    HStack(spacing: 12) {
                        PositionSlider(model: model)
                        // 자동 스크롤: 자리만 (기능은 나중에, 사용자)
                        Button {
                        } label: {
                            Image(systemName: "play.fill")
                                .font(.body.weight(.semibold))
                                .frame(width: 24, height: 24)
                        }
                        .buttonStyle(.glass)
                        .buttonBorderShape(.circle)
                        .disabled(true)
                        .accessibilityLabel("자동 스크롤 (준비 중)")
                    }
                }
            }
            .padding()
        }
    }
}

/// 글자 위치 막대 (0~100%, 늘 왼→오). 끄는 동안은 % 만 보이고 손을 떼면 옮긴다
private struct PositionSlider: View {
    let model: TextReaderModel
    @State private var dragging: Double?

    var body: some View {
        Slider(value: Binding(get: { dragging ?? model.fraction }, set: { dragging = $0 }), in: 0...1) { editing in
            if !editing, let dragging {
                model.jump(toFraction: dragging)
                self.dragging = nil
            }
        }
        .tint(.white)
    }
}

/// 폭·안전 영역이 바뀌면 알려 주는 글 상자
private final class ReaderTextView: UITextView {
    var onGeometryChange: (() -> Void)?
    private var lastWidth: CGFloat = 0
    private var lastSafe: UIEdgeInsets = .zero

    override func layoutSubviews() {
        super.layoutSubviews()
        let safe = window?.safeAreaInsets ?? .zero
        guard bounds.width > 0, bounds.width != lastWidth || safe != lastSafe else { return }
        lastWidth = bounds.width
        lastSafe = safe
        // 바뀜 (2026-11-08): 처음 배치 때도 알린다 — 글을 넣을 때는 아직 창에 붙기 전이라 노치(다이내믹 아일랜드) 높이를 0 으로 읽어
        //   첫 줄이 가려졌는데, 처음 한 번을 건너뛰어 다시 맞추지 않았다 (사용자)
        DispatchQueue.main.async { [weak self] in self?.onGeometryChange?() }
    }
}

/// 읽기 전용 글 상자
private struct TextPageView: UIViewRepresentable {
    let model: TextReaderModel
    let style: TextStyle
    let dark: Bool

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    func makeUIView(context: Context) -> UITextView {
        let view = ReaderTextView(usingTextLayoutManager: true)
        view.contentInsetAdjustmentBehavior = .never
        view.onGeometryChange = { [weak coordinator = context.coordinator] in coordinator?.geometryChanged() }
        view.isEditable = false
        view.isSelectable = false
        view.alwaysBounceVertical = true
        // 스크롤 막대는 TextKit 2 가 아직 배치하지 않은 곳의 높이를 어림해 흔들리므로 숨기고 아래 % 막대를 쓴다
        view.showsVerticalScrollIndicator = false
        view.delegate = context.coordinator
        view.addGestureRecognizer(UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.tapped)))
        context.coordinator.view = view
        model.scrollTo = { [weak coordinator = context.coordinator] offset in coordinator?.scroll(to: offset) }
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        context.coordinator.apply(style: style, dark: dark, revision: model.revision)
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        let model: TextReaderModel
        weak var view: UITextView?
        private var applied: (style: TextStyle, dark: Bool, revision: Int)?
        private var margin: CGFloat = 20

        init(model: TextReaderModel) { self.model = model }

        /// 노치·홈 막대(창의 안전 영역, 제목 막대는 빼고)만큼 비우고, 좌우는 여백 + 가로 화면의 노치
        private func applyInsets() {
            guard let view else { return }
            let safe = view.window?.safeAreaInsets ?? .zero
            view.contentInset = UIEdgeInsets(top: safe.top, left: 0, bottom: safe.bottom, right: 0)
            view.textContainerInset = UIEdgeInsets(top: 12, left: margin + safe.left, bottom: 40, right: margin + safe.right)
        }

        /// 회전·창 크기·안전 영역이 바뀌었다: 다시 배치되므로 보던 줄을 맨 위로
        func geometryChanged() {
            guard applied != nil else { return }
            let keep = model.topOffset
            applyInsets()
            scroll(to: keep)
        }

        /// 글·모양이 바뀌었으면 다시 넣고, 보던 글자가 맨 위에 오게 한다
        func apply(style: TextStyle, dark: Bool, revision: Int) {
            guard let view else { return }
            if let applied, applied.style == style, applied.dark == dark, applied.revision == revision { return }
            let keep = applied == nil ? model.topOffset : (applied?.revision == revision ? currentTop() ?? model.topOffset : model.topOffset)
            applied = (style, dark, revision)
            let colors = style.theme.platformColors(dark: dark)
            view.backgroundColor = colors.background
            margin = CGFloat(style.margin)
            applyInsets()
            view.textContainer.lineFragmentPadding = 0
            view.attributedText = NSAttributedString(string: model.book.text, attributes: style.attributes(dark: dark))
            scroll(to: keep)
        }

        /// 그 글자가 든 줄을 맨 위로. 멀리 있는 곳은 배치하며 높이가 바뀌므로 한 번 더 맞춘다
        func scroll(to offset: Int) {
            place(offset)
            DispatchQueue.main.async { [weak self] in
                self?.place(offset)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { self?.place(offset) }
            }
        }

        private func place(_ offset: Int) {
            guard let view, let layout = view.textLayoutManager, let content = layout.textContentManager else { return }
            let documentStart = content.documentRange.location
            guard offset > 0, let location = content.location(documentStart, offsetBy: offset) else {
                view.setContentOffset(CGPoint(x: 0, y: -view.adjustedContentInset.top), animated: false)
                model.updateTop(0)
                return
            }
            layout.ensureLayout(for: NSTextRange(location: location))
            guard let fragment = layout.textLayoutFragment(for: location) else { return }
            let paragraphStart = content.offset(from: documentStart, to: fragment.rangeInElement.location)
            let inParagraph = offset - paragraphStart
            let line = fragment.textLineFragments.last { $0.characterRange.location <= inParagraph } ?? fragment.textLineFragments.first
            let y = fragment.layoutFragmentFrame.minY + (line?.typographicBounds.minY ?? 0)
            let target = y + view.textContainerInset.top - view.adjustedContentInset.top
            let maxY = max(view.contentSize.height - view.bounds.height + view.adjustedContentInset.bottom, -view.adjustedContentInset.top)
            view.setContentOffset(CGPoint(x: 0, y: min(target, maxY)), animated: false)
            model.updateTop(offset)
        }

        /// 화면 맨 위 줄의 첫 글자
        func currentTop() -> Int? {
            guard let view, let layout = view.textLayoutManager, let content = layout.textContentManager else { return nil }
            let y = view.contentOffset.y + view.adjustedContentInset.top - view.textContainerInset.top
            guard let fragment = layout.textLayoutFragment(for: CGPoint(x: 1, y: max(y, 0) + 1)) else { return nil }
            let paragraphStart = content.offset(from: content.documentRange.location, to: fragment.rangeInElement.location)
            let inFragment = y - fragment.layoutFragmentFrame.minY
            let line = fragment.textLineFragments.first { $0.typographicBounds.maxY > inFragment } ?? fragment.textLineFragments.last
            return paragraphStart + (line?.characterRange.location ?? 0)
        }

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            guard applied != nil, let top = currentTop() else { return }
            let atEnd = scrollView.contentOffset.y + scrollView.bounds.height >= scrollView.contentSize.height + scrollView.adjustedContentInset.bottom - 4
            model.updateTop(top, atEnd: atEnd)
        }

        func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) { model.saveProgress() }
        func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
            if !decelerate { model.saveProgress() }
        }

        @objc func tapped() {
            model.showsControls.toggle()
        }
    }
}
#endif
