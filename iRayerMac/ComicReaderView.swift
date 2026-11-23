import AppKit
import SwiftUI

/// 맥 만화 보기: 영상처럼 따로 뜬 창에서 본다.
/// 창이 가로로 넓으면 두 쪽을 펼치고, ←→·스페이스·스크롤·창 왼쪽/오른쪽 클릭으로 넘긴다.
@MainActor
final class ComicWindowHost: NSObject, NSWindowDelegate {
    static let shared = ComicWindowHost()

    private var window: NSWindow?
    private var reader: MacComicReader?
    private var scrollMonitor: Any?

    func show(_ book: ComicBook) {
        reader?.close()
        let window = self.window ?? makeWindow()
        self.window = window
        let reader = MacComicReader(book: book, window: window)
        self.reader = reader
        window.title = book.file.title
        window.contentView = NSHostingView(rootView: ComicReaderView(reader: reader))
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
        AppSettings.shared.applyIdleTimer(playing: true)
        watchScroll()
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 800),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.backgroundColor = .black
        window.collectionBehavior = [.fullScreenPrimary]
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 360, height: 300)
        window.delegate = self
        window.setFrameAutosaveName("ComicWindow")
        if !window.setFrameUsingName("ComicWindow") { window.center() }
        return window
    }

    /// 마우스 휠·트랙패드로 넘기기 (SwiftUI 에는 스크롤 받는 곳이 없어서 창으로 오는 것을 본다)
    private func watchScroll() {
        guard scrollMonitor == nil else { return }
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self, let window, event.window === window, let reader, !reader.showsGrid else { return event }
            reader.scrolled(event)
            return nil
        }
    }

    func windowWillClose(_ notification: Notification) {
        reader?.close()
        reader = nil
        window?.contentView = nil
        if let scrollMonitor { NSEvent.removeMonitor(scrollMonitor) }
        scrollMonitor = nil
        AppSettings.shared.applyIdleTimer(playing: false)
    }

    func windowDidEnterFullScreen(_ notification: Notification) { reader?.isFullScreen = true }
    func windowDidExitFullScreen(_ notification: Notification) { reader?.isFullScreen = false }
    func windowDidResize(_ notification: Notification) { reader?.windowResized() }
}

/// 책 읽기 상태: 화면 순서, 지금 화면, 넘기기, 이어 읽기 저장
@MainActor
@Observable
final class MacComicReader {
    private(set) var book: ComicBook
    private(set) var settings: ComicSettings
    /// 지금 화면 순서. units.count 면 끝 화면 ("끝까지 읽었습니다")
    private(set) var index = 0
    /// 지금 화면에 보일 그림 (읽는 중이면 앞 그림을 그대로 두고 loading)
    private(set) var image: CGImage?
    private(set) var loading = false
    private(set) var units: [ComicUnit] = []
    var showsControls = true {
        didSet { if showsControls != oldValue { restartAutoAdvance() } }
    }
    var showsGrid = false {
        didSet { if showsGrid != oldValue { restartAutoAdvance() } }
    }
    /// 보기 설정 패널 (2026-11-08, 사용자: 메뉴 대신 폴더 설정처럼 오른쪽에 겹쳐 뜨는 패널)
    var showsSettings = false {
        didSet { if showsSettings != oldValue { restartAutoAdvance() } }
    }
    /// 자동 넘김 켜짐 (▶/■, 이 책을 보는 동안만 — 저장하지 않는다)
    private(set) var autoAdvancing = false
    @ObservationIgnored private var autoTask: Task<Void, Never>?
    var isFullScreen = false
    var errorMessage: String?
    /// 다음 권에 암호가 걸려 있어 묻는 중
    var askingPassword: (file: VideoFile, archive: any ComicArchive)?
    var nextPassword = ""

    @ObservationIgnored weak var window: NSWindow?
    @ObservationIgnored private(set) var cache: ComicPageCache
    @ObservationIgnored private var spread = false
    @ObservationIgnored private var known: [Int: Bool] = [:]
    @ObservationIgnored private var renderTask: Task<Void, Never>?
    @ObservationIgnored private var hideTask: Task<Void, Never>?
    /// 트랙패드로 민 거리 (한 번 넘길 만큼 모이면 넘긴다)
    @ObservationIgnored private var scrollAmount: CGPoint = .zero
    @ObservationIgnored private var scrollTurned = false

    var pageCount: Int { book.pages.count }
    var isAtEnd: Bool { index >= units.count }

    /// 지금 보이는 마지막 쪽 (1부터)
    var pageNumber: Int {
        units.indices.contains(index) ? (units[index].pages.last ?? 0) + 1 : pageCount
    }

    init(book: ComicBook, window: NSWindow) {
        self.book = book
        self.window = window
        settings = ComicSettingsStore.shared.settings(for: book.file)
        cache = ComicPageCache(book: book, maxPixel: Self.maxPixel)
        spread = Self.isWide(window)
        relayout()
        storeCover()
        show(units.firstIndex { $0.pages.contains(resumePage) } ?? 0)
        touchControls()
    }

    /// 화면 긴 변 × 배율 × 1.5, 너무 크면 메모리를 많이 쓰므로 4096 까지
    private static var maxPixel: Int {
        let screen = NSScreen.main
        let size = screen?.frame.size ?? CGSize(width: 1920, height: 1080)
        return min(Int(max(size.width, size.height) * (screen?.backingScaleFactor ?? 2) * 1.5), 4096)
    }

    private static func isWide(_ window: NSWindow?) -> Bool {
        guard let size = window?.contentView?.bounds.size ?? window?.frame.size else { return false }
        return size.width > size.height
    }

    /// 암호가 걸린 책·받지 않았던 RAR 은 목록에서 표지를 만들 수 없으니 여기서 만든다
    private func storeCover(force: Bool = false) {
        let book = self.book
        Task { await CoverService.shared.rebuild(book.file, archive: book.archive, password: book.password, onlyIfMissing: !force) }
    }

    /// 이어 읽을 쪽 (0부터). 다 읽은 책은 처음부터.
    private var resumePage: Int {
        let state = PlaybackStateStore.shared.state(for: book.file.stateKey)
        let page = Int(state.position) - 1
        return page >= 0 && page < pageCount - 1 ? page : 0
    }

    func saveProgress() {
        // 진행률 막대(폴더 카드)에 그대로 쓰이도록 위치 = 본 쪽 수, 길이 = 전체 쪽 수
        PlaybackStateStore.shared.update(book.file.stateKey) {
            $0.position = Double(pageNumber)
            $0.duration = Double(pageCount)
        }
        WatchHistory.shared.record(book.file, finished: pageNumber >= pageCount)
    }

    func close() {
        renderTask?.cancel()
        hideTask?.cancel()
        autoTask?.cancel()
        saveProgress()
        ReturnHighlight.shared.returned(from: book.file)
    }

    /// 보기 설정을 바꾸고 이 책(과 폴더)에 기억한다
    func set(_ setting: WritableKeyPath<ComicSettings, Bool>, _ value: Bool) {
        let page = units.indices.contains(index) ? units[index].pages[0] : pageCount - 1
        settings[keyPath: setting] = value
        ComicSettingsStore.shared.save(settings, for: book.file)
        storeCover(force: true)
        relayout()
        jump(to: page)
    }

    // MARK: 배치

    /// 창 모양이 바뀌었다: 가로로 넓으면 두 쪽 펼침
    func windowResized() {
        let wide = Self.isWide(window)
        guard wide != spread else { return }
        let page = units.indices.contains(index) ? units[index].pages[0] : nil
        spread = wide
        relayout()
        if let page { jump(to: page) }
    }

    private func relayout() {
        let known = self.known
        units = ComicUnit.layout(count: pageCount, isWide: { known[$0] }, split: settings.split && !spread, spread: spread)
    }

    /// 가로로 긴 그림을 새로 알게 됐으면 배치를 다시 한다 (지금 보는 쪽은 그대로)
    private func learned(_ wide: [Int: Bool]) {
        guard wide != known.filter({ wide.keys.contains($0.key) }) else { return }
        let current = units.indices.contains(index) ? units[index] : nil
        known.merge(wide) { $1 }
        relayout()
        guard let current else { return }
        if let same = units.firstIndex(of: current) {
            index = same
        } else {
            jump(to: current.pages[0])
        }
    }

    // MARK: 넘기기

    func jump(to page: Int) {
        show(units.firstIndex { $0.pages.contains(page) } ?? 0)
    }

    /// 화면 왼쪽·오른쪽으로 넘긴다 (오른쪽에서 왼쪽으로 읽는 책은 왼쪽이 다음)
    func turn(left: Bool) {
        step(forward: left == settings.rightToLeft)
    }

    func step(forward: Bool) {
        let target = index + (forward ? 1 : -1)
        guard target >= 0, target <= units.count else { return }
        show(target)
    }

    private func show(_ target: Int) {
        index = min(max(target, 0), units.count)
        renderTask?.cancel()
        // 쪽이 바뀌면(직접·막대·자동) 자동 넘김 시간을 처음부터
        restartAutoAdvance()
        guard units.indices.contains(index) else {
            image = nil
            loading = false
            // 끝 화면이면 자동 넘김을 끈다 (다음 권·닫기는 하지 않는다)
            autoAdvancing = false
            return
        }
        let unit = units[index]
        let cache = self.cache
        let rightToLeft = settings.rightToLeft, swapHalves = settings.swapHalves
        loading = true
        renderTask = Task {
            let rendered = try? await cache.render(unit, rightToLeft: rightToLeft, swapHalves: swapHalves)
            guard !Task.isCancelled else { return }
            if let rendered { image = rendered }
            loading = false
            learned(await cache.knownWide())
        }
        Task { await cache.keep(max(0, unit.pages[0] - 6)...unit.pages[0] + 8) }
        prefetch()
    }

    /// 앞뒤 몇 장을 미리 읽어 둔다 (넘길 때 기다리지 않게, 가로로 긴 그림을 미리 알게)
    private func prefetch() {
        let pages = units[max(0, index - 1)..<min(units.count, index + 4)].flatMap(\.pages)
        let cache = self.cache
        Task {
            for page in Set(pages).sorted() { _ = try? await cache.image(page) }
            learned(await cache.knownWide())
        }
    }

    /// 창을 눌렀다: 왼쪽·오른쪽 30% 는 넘기기, 가운데는 조작 보이기·숨기기
    /// 바뀜 (2026-11-08): 설정 패널이 열려 있으면 먼저 패널만 닫는다
    func clicked(atFraction x: CGFloat) {
        if showsSettings {
            showsSettings = false
            return
        }
        if x < 0.3 {
            turn(left: true)
        } else if x > 0.7 {
            turn(left: false)
        } else {
            showsControls.toggle()
            if showsControls { touchControls() }
        }
    }

    /// 마우스 휠은 한 칸에 한 장, 트랙패드는 한 번 쓸 때 한 장
    func scrolled(_ event: NSEvent) {
        guard event.hasPreciseScrollingDeltas else {
            let delta = abs(event.scrollingDeltaY) >= abs(event.scrollingDeltaX) ? event.scrollingDeltaY : -event.scrollingDeltaX
            if delta != 0 { step(forward: delta < 0) }
            return
        }
        if event.phase == .began {
            scrollAmount = .zero
            scrollTurned = false
        }
        guard !scrollTurned, event.momentumPhase == [] else { return }
        scrollAmount.x += event.scrollingDeltaX
        scrollAmount.y += event.scrollingDeltaY
        if abs(scrollAmount.x) > 50 && abs(scrollAmount.x) > abs(scrollAmount.y) {
            // 손가락을 오른쪽으로 쓸면 왼쪽 쪽이 들어온다
            turn(left: scrollAmount.x > 0)
            scrollTurned = true
        } else if abs(scrollAmount.y) > 50 {
            step(forward: scrollAmount.y < 0)
            scrollTurned = true
        }
    }

    // MARK: 자동 넘김 (2026-11-08, 사용자)

    /// ▶/■. 켜면 조작은 평소처럼 조금 뒤 숨고, 숨은 뒤부터 센다
    func toggleAutoAdvance() {
        autoAdvancing.toggle()
        restartAutoAdvance()
    }

    /// 처음부터 다시 센다. 맥에는 "누르고 있는 동안" 대신 조작이 보이는 동안(마우스를 움직이면 보임)·설정 패널·모아보기가 떠 있는 동안 멈춘다
    private func restartAutoAdvance() {
        autoTask?.cancel()
        autoTask = nil
        guard autoAdvancing, !showsControls, !showsSettings, !showsGrid else { return }
        let seconds = AppSettings.shared.comicAutoSeconds
        autoTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled, let self else { return }
            self.step(forward: true)
        }
    }

    // MARK: 조작 보이기

    /// 조작을 보이고 조금 뒤 숨긴다
    func touchControls() {
        if !showsControls { showsControls = true }
        hideTask?.cancel()
        hideTask = Task {
            try? await Task.sleep(for: .seconds(2.5))
            guard !Task.isCancelled, !showsGrid, !showsSettings else { return }
            showsControls = false
        }
    }

    /// 조작 위에 마우스가 있는 동안은 숨기지 않는다
    func holdControls() {
        hideTask?.cancel()
        showsControls = true
    }

    func toggleFullScreen() {
        window?.toggleFullScreen(nil)
    }

    // MARK: 다음 권

    func openNext() async {
        guard let next = book.nextVolume else { return }
        do {
            let archive = try await ComicLauncher.shared.load(next)
            if archive.isEncrypted, !(await archive.check(password: book.password ?? "")) {
                nextPassword = ""
                askingPassword = (next, archive)
                return
            }
            await open(next, archive: archive, password: book.password)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func open(_ file: VideoFile, archive: any ComicArchive, password: String?) async {
        var archive = archive
        if archive.isEncrypted {
            guard await archive.check(password: password ?? ""),
                  let unlocked = try? await ComicLauncher.unlock(archive, password: password ?? "") else {
                errorMessage = ZipError.wrongPassword.localizedDescription
                return
            }
            archive = unlocked
            if let password { ComicLauncher.shared.remember(password, for: file) }
        }
        let next = ComicBook(file: file, archive: archive, password: password, siblings: book.siblings)
        guard !next.pages.isEmpty else {
            errorMessage = "이미지가 없는 압축 파일입니다."
            return
        }
        saveProgress()
        ReturnHighlight.shared.returned(from: book.file)
        book = next
        window?.title = file.title
        settings = ComicSettingsStore.shared.settings(for: file)
        cache = ComicPageCache(book: next, maxPixel: Self.maxPixel)
        known = [:]
        image = nil
        relayout()
        storeCover()
        show(units.firstIndex { $0.pages.contains(resumePage) } ?? 0)
    }
}

/// 만화 창의 내용: 그림 + 마우스를 올리면 보이는 조작
struct ComicReaderView: View {
    let reader: MacComicReader
    @FocusState private var focused: Bool

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color.black
                page
                    .contentShape(.rect)
                    .onTapGesture { location in
                        reader.clicked(atFraction: location.x / max(geometry.size.width, 1))
                    }
                if reader.showsControls {
                    controls
                        .transition(.opacity)
                }
            }
        }
        .ignoresSafeArea()
        .animation(.easeInOut(duration: 0.2), value: reader.showsControls)
        .onContinuousHover { phase in
            if case .active = phase { reader.touchControls() }
        }
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onAppear {
            focused = true
            setWindowButtons(visible: reader.showsControls)
        }
        .onChange(of: reader.showsControls) { _, visible in
            setWindowButtons(visible: visible)
            if !visible { NSCursor.setHiddenUntilMouseMoves(true) }
        }
        .onKeyPress(.leftArrow) { reader.turn(left: true); return .handled }
        .onKeyPress(.rightArrow) { reader.turn(left: false); return .handled }
        .onKeyPress(.downArrow) { reader.step(forward: true); return .handled }
        .onKeyPress(.upArrow) { reader.step(forward: false); return .handled }
        .onKeyPress(.space, phases: .down) { press in
            reader.step(forward: !press.modifiers.contains(.shift))
            return .handled
        }
        .onKeyPress("f") { reader.toggleFullScreen(); return .handled }
        .onKeyPress(.return) {
            if !reader.isFullScreen { reader.toggleFullScreen() }
            return .handled
        }
        .onKeyPress(.escape) {
            // 바뀜 (2026-11-08): 설정이 열려 있으면 먼저 닫는다
            if reader.showsSettings {
                reader.showsSettings = false
                return .handled
            }
            guard reader.isFullScreen else { return .ignored }
            reader.toggleFullScreen()
            return .handled
        }
        .sheet(isPresented: Binding(get: { reader.showsGrid }, set: { reader.showsGrid = $0 })) {
            ComicGridView(reader: reader) { page in
                reader.showsGrid = false
                reader.jump(to: page)
            }
            .frame(minWidth: 640, minHeight: 520)
        }
        .alert("암호", isPresented: Binding(get: { reader.askingPassword != nil }, set: { if !$0 { reader.askingPassword = nil } })) {
            SecureField("암호", text: Binding(get: { reader.nextPassword }, set: { reader.nextPassword = $0 }))
            Button("취소", role: .cancel) {}
            Button("확인") {
                guard let pending = reader.askingPassword else { return }
                Task { await reader.open(pending.file, archive: pending.archive, password: reader.nextPassword) }
            }
        } message: {
            Text("'\(reader.askingPassword?.file.name ?? "")'에 암호가 걸려 있습니다.")
        }
        .alert("열 수 없습니다", isPresented: Binding(get: { reader.errorMessage != nil }, set: { if !$0 { reader.errorMessage = nil } })) {
            Button("확인", role: .cancel) {}
        } message: {
            Text(reader.errorMessage ?? "")
        }
        .preferredColorScheme(.dark)
    }

    @ViewBuilder
    private var page: some View {
        if reader.isAtEnd {
            ComicEndView(reader: reader)
        } else {
            ZStack {
                if let image = reader.image {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .interpolation(.high)
                        .scaledToFit()
                }
                if reader.loading {
                    ProgressView().controlSize(.large)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// 신호등(닫기·최소화·전체 화면)은 조작과 함께 보였다 숨는다
    private func setWindowButtons(visible: Bool) {
        reader.window?.standardWindowButton(.closeButton)?.superview?.animator().alphaValue = visible ? 1 : 0
    }

    private var controls: some View {
        VStack(spacing: 0) {
            // 위: 제목 (신호등 오른쪽) + 쪽 모아보기·보기 설정
            HStack(spacing: 14) {
                Text(reader.book.file.title)
                    .font(.headline)
                    .lineLimit(1)
                Spacer()
                Button { reader.showsGrid = true } label: { Image(systemName: "square.grid.3x3.fill") }
                    .help("쪽 모아보기")
                // 바뀜 (2026-11-08, 사용자): 메뉴 → 오른쪽 겹친 패널(톱니를 덮어 닫기 어려웠다) → 동영상 플레이어 설정처럼 톱니에서 뜨는 풍선(popover).
                //   바깥을 누르거나 esc 로 닫힌다
                Button { reader.showsSettings.toggle() } label: { Image(systemName: "gearshape.fill") }
                    .help("보기 설정")
                    .popover(isPresented: Binding(get: { reader.showsSettings }, set: { reader.showsSettings = $0 }), arrowEdge: .bottom) {
                        ComicSettingsForm(settings: reader.settings, set: { reader.set($0, $1) },
                                          spreadNote: "창이 가로로 넓으면 두 쪽을 펼쳐 보여줍니다.")
                            .font(.body) // 바뀜 (2026-11-08): 위 막대 단추 글자(15pt 굵게)를 물려받아 설정 글자가 컸다 (사용자)
                            .frame(width: 320, height: 320)
                    }
            }
            .buttonStyle(.borderless)
            .font(.system(size: 15, weight: .medium))
            .padding(.leading, 84)
            .padding(.trailing, 16)
            .frame(minHeight: 28)
            .padding(.top, 6)
            .padding(.bottom, 40)
            .background(LinearGradient(colors: [.black.opacity(0.75), .black.opacity(0.35), .clear], startPoint: .top, endPoint: .bottom))
            .onHover { if $0 { reader.holdControls() } }
            Spacer()
            ComicControlBar(reader: reader)
                .padding(16)
        }
        .foregroundStyle(.white)
    }

}

/// 아래 조작 막대: 쪽 번호 · 쪽 이동 막대 · 다음 권 · 전체 화면
private struct ComicControlBar: View {
    let reader: MacComicReader
    @State private var dragging: Double?

    var body: some View {
        HStack(spacing: 14) {
            Text("\(dragging.map { Int($0) + 1 } ?? reader.pageNumber) / \(reader.pageCount)")
                .monospacedDigit()
                .frame(minWidth: 70)
            // 오른쪽에서 왼쪽으로 읽으면 막대도 뒤집는다
            Slider(value: Binding(
                get: { dragging ?? Double(reader.pageNumber - 1) },
                set: { dragging = $0 }
            ), in: 0...Double(max(reader.pageCount - 1, 1)), step: 1) { editing in
                if !editing, let dragging {
                    reader.jump(to: Int(dragging))
                    self.dragging = nil
                }
            }
            .controlSize(.small)
            .scaleEffect(x: reader.settings.rightToLeft ? -1 : 1)
            .disabled(reader.pageCount < 2)
            // 바뀜 (2026-11-08, 사용자): 자동 넘김 ▶/■
            Button { reader.toggleAutoAdvance() } label: {
                Image(systemName: reader.autoAdvancing ? "stop.fill" : "play.fill")
            }
            .help(reader.autoAdvancing ? "자동 넘김 끄기" : "자동 넘김 켜기 (\(AppSettings.shared.comicAutoSeconds)초마다)")
            if let next = reader.book.nextVolume {
                Button {
                    Task { await reader.openNext() }
                } label: {
                    Label("다음 권", systemImage: "forward.end.fill")
                }
                .help("다음 권: \(next.title)")
            }
            Button { reader.toggleFullScreen() } label: {
                Image(systemName: reader.isFullScreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
            }
            .help("전체 화면 (F)")
        }
        .buttonStyle(.borderless)
        .font(.system(size: 15, weight: .medium))
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .glassEffect(in: .capsule)
        .frame(maxWidth: 720)
        .onHover { if $0 { reader.holdControls() } else { reader.touchControls() } }
    }
}

/// 마지막 장 다음: 다 읽었다 + 다음 권
private struct ComicEndView: View {
    let reader: MacComicReader

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "checkmark.circle")
                .font(.system(size: 48))
                .foregroundStyle(.white.opacity(0.8))
            Text("끝까지 읽었습니다")
                .font(.title3.bold())
                .foregroundStyle(.white)
            if let next = reader.book.nextVolume {
                Button {
                    Task { await reader.openNext() }
                } label: {
                    Label("다음 권: \(next.title)", systemImage: "forward.end.fill")
                        .font(.headline)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                }
                .buttonStyle(.glassProminent)
            }
            Button("닫기") { reader.window?.performClose(nil) }
                .buttonStyle(.glass)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// 쪽 모아보기: 쪽 썸네일 격자. 누르면 그 쪽으로 간다. 왼쪽으로 읽는 책은 격자도 오른쪽에서 왼쪽으로.
private struct ComicGridView: View {
    let reader: MacComicReader
    let onSelect: (Int) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: 4)], spacing: 4) {
                        ForEach(0..<reader.pageCount, id: \.self) { page in
                            Button {
                                onSelect(page)
                            } label: {
                                ComicThumbnail(cache: reader.cache, page: page, isCurrent: page == reader.pageNumber - 1)
                            }
                            .buttonStyle(.plain)
                            .id(page)
                        }
                    }
                    .padding(4)
                    .environment(\.layoutDirection, reader.settings.rightToLeft ? .rightToLeft : .leftToRight)
                }
                .onAppear { proxy.scrollTo(reader.pageNumber - 1, anchor: .center) }
            }
            .navigationTitle(reader.book.file.title)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("완료") { dismiss() }
                        .keyboardShortcut(.cancelAction)
                }
            }
        }
    }
}

/// 쪽 모아보기의 한 칸: 정사각형에 꽉 채운 작은 그림 + 쪽 번호
private struct ComicThumbnail: View {
    let cache: ComicPageCache
    let page: Int
    let isCurrent: Bool

    @State private var image: CGImage?

    var body: some View {
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .background(.quaternary)
            .overlay {
                if let image {
                    Image(decorative: image, scale: 1).resizable().scaledToFill()
                }
            }
            .overlay(alignment: .bottomTrailing) {
                Text("\(page + 1)")
                    .font(.caption2.monospacedDigit().weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(.black.opacity(0.6), in: .rect(cornerRadius: 4))
                    .padding(4)
            }
            .overlay {
                if isCurrent { Rectangle().strokeBorder(.tint, lineWidth: 3) }
            }
            .clipped()
            .contentShape(.rect)
            .task(id: page) {
                image = try? await cache.thumbnail(page)
            }
    }
}
