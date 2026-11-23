import AppKit
import SwiftUI

/// 맥 텍스트 보기: 만화처럼 따로 뜬 창. 마우스를 움직이면 위(제목·보기 설정)·아래(% 막대) 조작이 보이고 조금 뒤 숨는다.
/// 글은 NSTextView (TextKit 2), ↑↓·Page Up/Down·스페이스로 넘기고 글을 골라 복사할 수 있다
@MainActor
final class TextWindowHost: NSObject, NSWindowDelegate {
    static let shared = TextWindowHost()

    private var window: NSWindow?
    private var model: TextReaderModel?

    func show(_ book: TextBook) {
        model?.saveProgress()
        let window = self.window ?? makeWindow()
        self.window = window
        let model = TextReaderModel(book: book)
        self.model = model
        window.title = book.file.title
        window.contentView = NSHostingView(rootView: MacTextReaderView(model: model, window: window))
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 900),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.collectionBehavior = [.fullScreenPrimary]
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 360, height: 300)
        window.delegate = self
        window.setFrameAutosaveName("TextWindow")
        if !window.setFrameUsingName("TextWindow") { window.center() }
        return window
    }

    func windowWillClose(_ notification: Notification) {
        model?.saveProgress()
        if let model { ReturnHighlight.shared.returned(from: model.book.file) }
        model = nil
        window?.contentView = nil
    }
}

/// 창의 내용: 글 + 마우스를 움직이면 보이는 조작
struct MacTextReaderView: View {
    let model: TextReaderModel
    weak var window: NSWindow?
    @State private var settings = AppSettings.shared
    @State private var showsSettings = false
    @State private var hideTask: Task<Void, Never>?
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let dark = settings.textAppearance.isDark(colorScheme)
        let colors = settings.textTheme.colors(dark: dark)
        ZStack {
            colors.background
            MacTextPageView(model: model, style: TextStyle.current, dark: dark)
                .padding(.top, 28)
            if model.showsControls || showsSettings {
                controls(text: colors.text)
                    .transition(.opacity)
            }
        }
        .ignoresSafeArea()
        .animation(.easeInOut(duration: 0.2), value: model.showsControls)
        .onContinuousHover { phase in
            if case .active = phase { touchControls() }
        }
        .onAppear { touchControls() }
        .onChange(of: model.showsControls) { _, visible in
            window?.standardWindowButton(.closeButton)?.superview?.animator().alphaValue = visible || showsSettings ? 1 : 0
        }
        .onChange(of: showsSettings) {
            if !showsSettings { touchControls() }
        }
    }

    private func controls(text: Color) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                Text(model.book.file.title)
                    .font(.headline)
                    .lineLimit(1)
                Spacer()
                // 바뀜 (2026-11-08, 사용자): 아이폰·아이패드와 같은 톱니 (가가 → 톱니)
                Button { showsSettings.toggle() } label: { Image(systemName: "gearshape.fill") }
                    .help("보기 설정")
                    .popover(isPresented: $showsSettings, arrowEdge: .bottom) {
                        TextSettingsForm(model: model)
                            .font(.body)
                            .frame(width: 360, height: 470)
                    }
            }
            .buttonStyle(.borderless)
            .font(.system(size: 15, weight: .medium))
            .foregroundStyle(text)
            .padding(.leading, 84)
            .padding(.trailing, 16)
            .frame(minHeight: 28)
            .padding(.top, 6)
            .onHover { if $0 { holdControls() } }
            Spacer()
            HStack(spacing: 14) {
                Text("\(Int(model.fraction * 100))%")
                    .monospacedDigit()
                    .frame(minWidth: 44, alignment: .leading)
                MacPositionSlider(model: model)
                // 자동 스크롤: 자리만 (기능은 나중에, 사용자)
                Button {} label: { Image(systemName: "play.fill") }
                    .disabled(true)
                    .help("자동 스크롤 (준비 중)")
            }
            .buttonStyle(.borderless)
            .font(.system(size: 15, weight: .medium))
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .glassEffect(in: .capsule)
            .frame(maxWidth: 620)
            .padding(16)
            .onHover { if $0 { holdControls() } else { touchControls() } }
        }
    }

    /// 조작을 보이고 조금 뒤 숨긴다
    private func touchControls() {
        if !model.showsControls { model.showsControls = true }
        hideTask?.cancel()
        hideTask = Task {
            try? await Task.sleep(for: .seconds(2.5))
            guard !Task.isCancelled, !showsSettings else { return }
            model.showsControls = false
        }
    }

    private func holdControls() {
        hideTask?.cancel()
        model.showsControls = true
    }
}

private struct MacPositionSlider: View {
    let model: TextReaderModel
    @State private var dragging: Double?

    var body: some View {
        Slider(value: Binding(get: { dragging ?? model.fraction }, set: { dragging = $0 }), in: 0...1) { editing in
            if !editing, let dragging {
                model.jump(toFraction: dragging)
                self.dragging = nil
            }
        }
        .controlSize(.small)
    }
}

/// 읽기 전용 글 상자 (스크롤 막대는 숨기고 아래 % 막대)
private struct MacTextPageView: NSViewRepresentable {
    let model: TextReaderModel
    let style: TextStyle
    let dark: Bool

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = false
        scroll.drawsBackground = false
        scroll.contentView.postsBoundsChangedNotifications = true
        let text = NSTextView(usingTextLayoutManager: true)
        text.isEditable = false
        text.isSelectable = true
        text.drawsBackground = false
        text.isVerticallyResizable = true
        text.isHorizontallyResizable = false
        text.autoresizingMask = [.width]
        text.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        text.textContainer?.widthTracksTextView = true
        text.textContainer?.lineFragmentPadding = 0
        scroll.documentView = text
        context.coordinator.scroll = scroll
        context.coordinator.text = text
        NotificationCenter.default.addObserver(context.coordinator, selector: #selector(Coordinator.scrolled),
                                               name: NSView.boundsDidChangeNotification, object: scroll.contentView)
        model.scrollTo = { [weak coordinator = context.coordinator] offset in coordinator?.scroll(to: offset) }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.apply(style: style, dark: dark, revision: model.revision)
    }

    static func dismantleNSView(_ scroll: NSScrollView, coordinator: Coordinator) {
        NotificationCenter.default.removeObserver(coordinator)
    }

    final class Coordinator: NSObject {
        let model: TextReaderModel
        weak var scroll: NSScrollView?
        weak var text: NSTextView?
        private var applied: (style: TextStyle, dark: Bool, revision: Int)?
        private var saveTask: Task<Void, Never>?

        init(model: TextReaderModel) { self.model = model }

        func apply(style: TextStyle, dark: Bool, revision: Int) {
            guard let text else { return }
            if let applied, applied.style == style, applied.dark == dark, applied.revision == revision { return }
            let keep = applied == nil || applied?.revision != revision ? model.topOffset : currentTop() ?? model.topOffset
            applied = (style, dark, revision)
            text.textContainerInset = NSSize(width: CGFloat(style.margin), height: 16)
            text.textStorage?.setAttributedString(NSAttributedString(string: model.book.text, attributes: style.attributes(dark: dark)))
            scroll(to: keep)
        }

        func scroll(to offset: Int) {
            place(offset)
            DispatchQueue.main.async { [weak self] in
                self?.place(offset)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { self?.place(offset) }
            }
        }

        private func place(_ offset: Int) {
            guard let scroll, let text, let layout = text.textLayoutManager, let content = layout.textContentManager else { return }
            let documentStart = content.documentRange.location
            guard offset > 0, let location = content.location(documentStart, offsetBy: offset) else {
                scroll.contentView.scroll(to: .zero)
                scroll.reflectScrolledClipView(scroll.contentView)
                model.updateTop(0)
                return
            }
            layout.ensureLayout(for: NSTextRange(location: location))
            guard let fragment = layout.textLayoutFragment(for: location) else { return }
            let paragraphStart = content.offset(from: documentStart, to: fragment.rangeInElement.location)
            let inParagraph = offset - paragraphStart
            let line = fragment.textLineFragments.last { $0.characterRange.location <= inParagraph } ?? fragment.textLineFragments.first
            let y = fragment.layoutFragmentFrame.minY + (line?.typographicBounds.minY ?? 0) + text.textContainerInset.height
            let maxY = max(text.frame.height - scroll.contentView.bounds.height, 0)
            scroll.contentView.scroll(to: NSPoint(x: 0, y: min(y, maxY)))
            scroll.reflectScrolledClipView(scroll.contentView)
            model.updateTop(offset)
        }

        func currentTop() -> Int? {
            guard let scroll, let text, let layout = text.textLayoutManager, let content = layout.textContentManager else { return nil }
            let y = scroll.contentView.bounds.minY - text.textContainerInset.height
            guard let fragment = layout.textLayoutFragment(for: CGPoint(x: 1, y: max(y, 0) + 1)) else { return nil }
            let paragraphStart = content.offset(from: content.documentRange.location, to: fragment.rangeInElement.location)
            let inFragment = y - fragment.layoutFragmentFrame.minY
            let line = fragment.textLineFragments.first { $0.typographicBounds.maxY > inFragment } ?? fragment.textLineFragments.last
            return paragraphStart + (line?.characterRange.location ?? 0)
        }

        @objc func scrolled() {
            guard applied != nil, let scroll, let text, let top = currentTop() else { return }
            let atEnd = scroll.contentView.bounds.maxY >= text.frame.height - 4
            model.updateTop(top, atEnd: atEnd)
            // 멈춘 뒤 저장
            saveTask?.cancel()
            saveTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }
                self?.model.saveProgress()
            }
        }
    }
}
