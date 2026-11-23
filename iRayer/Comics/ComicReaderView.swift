import SwiftUI
import UIKit
import UIKit.UIGestureRecognizerSubclass

/// 만화 보기 화면: 한 장씩 넘기기(좌우 탭·쓸기), 확대, 반 자르기, 넘기는 방향, 가로 화면 두 쪽 펼침, 다음 권
struct ComicReaderView: View {
    @State private var book: ComicBook
    @State private var reader: ComicReader
    @Environment(\.dismiss) private var dismiss
    @State private var nextPassword = ""
    @State private var askingPassword: (file: VideoFile, archive: any ComicArchive)?
    @State private var errorMessage: String?
    @State private var showsGrid = false
    @State private var showsSettings = false

    init(book: ComicBook) {
        _book = State(initialValue: book)
        _reader = State(initialValue: ComicReader(book: book))
    }

    var body: some View {
        // 위쪽 버튼은 시스템 제목 막대에 둔다 (아이패드 창 모드의 창 제어 버튼을 시스템이 알아서 피한다)
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                ComicPager(reader: reader)
                    .ignoresSafeArea()
                if reader.showsControls {
                    controls
                        .transition(.opacity)
                }
            }
            .navigationTitle(book.file.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("닫기", systemImage: "xmark") { dismiss() }
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button("쪽 모아보기", systemImage: "square.grid.3x3.fill") { showsGrid = true }
                    // 바뀜 (2026-11-08, 사용자): 설정 메뉴 대신 반만 올라오는 설정 패널 (폴더 설정처럼)
                    Button("보기 설정", systemImage: "gearshape.fill") { showsSettings = true }
                }
            }
            .toolbarVisibility(reader.showsControls ? .visible : .hidden, for: .navigationBar)
            .toolbarBackgroundVisibility(.hidden, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
        }
        .animation(.easeInOut(duration: 0.2), value: reader.showsControls)
        .statusBarHidden(!reader.showsControls)
        .persistentSystemOverlays(.hidden)
        // 아래 가장자리에서 한 번 더 쓸어 올려야 홈으로 나간다 (책장을 넘기다 실수로 나가지 않게). 아이폰만 (플레이어와 같은 이유)
        .defersSystemGestures(on: UIDevice.current.userInterfaceIdiom == .phone ? .bottom : [])
        .onAppear {
            ComicReader.current = reader
            reader.onClose = { dismiss() }
            reader.onNextVolume = { Task { await openNext() } }
            AppSettings.shared.applyIdleTimer(playing: true)
        }
        .onDisappear {
            if ComicReader.current === reader { ComicReader.current = nil }
            reader.saveProgress()
            AppSettings.shared.applyIdleTimer(playing: false)
        }
        .sheet(isPresented: $showsSettings) {
            NavigationStack {
                ComicSettingsForm(settings: reader.settings) { reader.set($0, $1) }
                    .navigationTitle("보기 설정")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("완료", systemImage: "checkmark") { showsSettings = false }
                        }
                    }
            }
            .presentationDetents([.medium, .large])
        }
        // 패널·모아보기가 떠 있는 동안은 자동 넘김을 멈춘다
        .onChange(of: showsSettings || showsGrid) { reader.isBlocked = showsSettings || showsGrid }
        .sheet(isPresented: $showsGrid) {
            ComicGridView(reader: reader) { page in
                showsGrid = false
                reader.jump(to: page)
            }
        }
        .alert("암호", isPresented: Binding(get: { askingPassword != nil }, set: { if !$0 { askingPassword = nil } })) {
            SecureField("암호", text: $nextPassword)
            Button("취소", role: .cancel) {}
            Button("확인") {
                guard let pending = askingPassword else { return }
                Task { await open(pending.file, archive: pending.archive, password: nextPassword) }
            }
        } message: {
            Text("'\(askingPassword?.file.name ?? "")'에 암호가 걸려 있습니다.")
        }
        .alert("열 수 없습니다", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("확인", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    // MARK: - 조작

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
                        Text("\(reader.pageNumber) / \(book.pages.count)")
                            .font(.subheadline.monospacedDigit().weight(.semibold))
                            .foregroundStyle(.white)
                        Spacer()
                        if let next = book.nextVolume {
                            Button {
                                Task { await openNext() }
                            } label: {
                                Label("다음 권: \(next.title)", systemImage: "forward.end.fill")
                                    .font(.footnote.weight(.semibold))
                                    .lineLimit(1)
                            }
                            .buttonStyle(.glass)
                        }
                    }
                    // 바뀜 (2026-11-08, 사용자): 막대 오른쪽에 자동 넘김 ▶/■
                    HStack(spacing: 12) {
                        PageSlider(reader: reader)
                        // 바뀜 (2026-11-08): 그림 둘레를 눌러도 단추로 (plain 단추는 그림 자국만 눌려 나머지는 아래 넘기기 화면으로 갔다, 사용자)
                        // 바뀜 (2026-11-08): 너무 작아 제목 막대 단추처럼 유리 동그라미 단추로 (사용자)
                        Button {
                            reader.toggleAutoAdvance()
                        } label: {
                            // 바뀜 (2026-11-08): 제목 막대 단추보다 1.5배쯤 컸다 (사용자) → 크기 늘림을 빼고 기본 크기로 (≈44pt)
                            Image(systemName: reader.autoAdvancing ? "stop.fill" : "play.fill")
                                .font(.body.weight(.semibold))
                                .frame(width: 24, height: 24)
                        }
                        .buttonStyle(.glass)
                        .buttonBorderShape(.circle)
                        .accessibilityLabel(reader.autoAdvancing ? "자동 넘김 끄기" : "자동 넘김 켜기")
                    }
                }
            }
            .padding()
        }
    }

    // MARK: - 다음 권

    private func openNext() async {
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

    private func open(_ file: VideoFile, archive: any ComicArchive, password: String?) async {
        var archive = archive
        if archive.isEncrypted {
            guard await archive.check(password: password ?? ""),
                  let unlocked = try? await ComicLauncher.unlock(archive, password: password ?? "") else {
                errorMessage = ZipError.wrongPassword.localizedDescription
                return
            }
            archive = unlocked
        }
        reader.saveProgress()
        let next = ComicBook(file: file, archive: archive, password: password, siblings: book.siblings)
        guard !next.pages.isEmpty else {
            errorMessage = "이미지가 없는 압축 파일입니다."
            return
        }
        book = next
        reader.load(next)
    }
}

/// 쪽 이동 막대 (오른쪽에서 왼쪽으로 읽으면 막대도 뒤집는다)
private struct PageSlider: View {
    let reader: ComicReader
    @State private var dragging: Double?

    var body: some View {
        let count = max(reader.pageCount, 1)
        Slider(value: Binding(
            get: { dragging ?? Double(reader.pageNumber - 1) },
            set: { dragging = $0 }
        ), in: 0...Double(max(count - 1, 1)), step: 1) { editing in
            if !editing, let dragging {
                reader.jump(to: Int(dragging))
                self.dragging = nil
            }
        }
        .tint(.white)
        .scaleEffect(x: reader.settings.rightToLeft ? -1 : 1)
        .disabled(count < 2)
    }
}

// MARK: - 넘기기 (UIKit)

/// 책 읽기 상태와 넘기기 (UIPageViewController 의 dataSource·delegate)
@Observable
final class ComicReader: NSObject, UIPageViewControllerDataSource, UIPageViewControllerDelegate {
    /// 지금 열려 있는 보기 화면 (키보드 명령이 찾아 쓴다)
    @MainActor static weak var current: ComicReader?

    private(set) var book: ComicBook
    private(set) var settings: ComicSettings
    /// 지금 보이는 첫 쪽 (1부터)
    private(set) var pageNumber = 1
    var pageCount: Int { book.pages.count }
    var showsControls = false {
        didSet {
            guard showsControls != oldValue else { return }
            // 직접 숨기거나 다시 띄우면 ▶ 뒤 자동 숨기기는 그만둔다
            hideTask?.cancel()
            restartAutoAdvance()
        }
    }

    // MARK: 자동 넘김 (2026-11-08, 사용자)
    /// 켜져 있는지 (▶/■, 이 책을 보는 동안만 — 저장하지 않는다)
    private(set) var autoAdvancing = false
    /// 화면을 누르고 있는 중 (손을 뗄 때까지 멈춤)
    @ObservationIgnored private var touching = false
    /// 설정 패널·모아보기가 떠 있음 (닫힐 때까지 멈춤)
    @ObservationIgnored var isBlocked = false {
        didSet { if isBlocked != oldValue { restartAutoAdvance() } }
    }
    @ObservationIgnored private var autoTask: Task<Void, Never>?
    /// ▶ 를 누른 뒤 조작을 숨기기까지 (켜진 것을 보여 주려고)
    @ObservationIgnored private var hideTask: Task<Void, Never>?

    @ObservationIgnored var onClose: (() -> Void)?
    @ObservationIgnored var onNextVolume: (() -> Void)?
    @ObservationIgnored private(set) var cache: ComicPageCache
    @ObservationIgnored private var units: [ComicUnit] = []
    @ObservationIgnored private var spread = false
    @ObservationIgnored private var known: [Int: Bool] = [:]
    @ObservationIgnored weak var pager: UIPageViewController?
    /// 탭으로 넘기는 애니메이션 중. 그동안 들어온 탭은 하나만 기억했다가 끝나면 넘긴다 (빠르게 연달아 눌러도 화면과 쪽이 어긋나지 않게).
    @ObservationIgnored private var isTurning = false
    @ObservationIgnored private var pendingTurn: Bool?
    @ObservationIgnored private var turnID = 0

    init(book: ComicBook) {
        self.book = book
        settings = ComicSettingsStore.shared.settings(for: book.file)
        cache = ComicPageCache(book: book, maxPixel: Self.maxPixel)
        super.init()
        relayout()
        storeCover()
    }

    /// 암호가 걸린 책·받지 않았던 RAR 은 목록에서 표지를 만들 수 없으니 여기서 만든다.
    /// force: 읽는 방향·반 자르기를 바꿔 표지를 다시 만든다.
    private func storeCover(force: Bool = false) {
        let book = self.book
        Task {
            await CoverService.shared.rebuild(book.file, archive: book.archive, password: book.password, onlyIfMissing: !force)
        }
    }

    /// 화면 긴 변 × 배율 × 2 (확대해도 볼 만하게), 너무 크면 메모리를 많이 쓰므로 4096 까지
    private static var maxPixel: Int {
        let screen = UIScreen.main.bounds.size
        return min(Int(max(screen.width, screen.height) * UIScreen.main.scale * 1.5), 4096)
    }

    /// 다른 책으로 바꾼다 (다음 권)
    func load(_ book: ComicBook) {
        self.book = book
        settings = ComicSettingsStore.shared.settings(for: book.file)
        cache = ComicPageCache(book: book, maxPixel: Self.maxPixel)
        known = [:]
        relayout()
        storeCover()
        show(units.firstIndex { $0.pages.contains(resumePage) } ?? 0, direction: .forward, animated: false)
    }

    /// 이어 읽을 쪽 (0부터). 다 읽은 책은 처음부터.
    var resumePage: Int {
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
        // 홈의 이어보기
        WatchHistory.shared.record(book.file, finished: pageNumber >= pageCount)
    }

    /// 보기 설정을 바꾸고 이 책(과 폴더)에 기억한다
    func set(_ setting: WritableKeyPath<ComicSettings, Bool>, _ value: Bool) {
        settings[keyPath: setting] = value
        ComicSettingsStore.shared.save(settings, for: book.file)
        storeCover(force: true)
        relayout()
        show(currentIndex, direction: .forward, animated: false)
    }

    // MARK: 배치

    /// 화면 크기가 바뀌었다 (회전): 가로면 두 쪽 펼침
    func setSpread(_ spread: Bool) {
        guard spread != self.spread else { return }
        self.spread = spread
        relayout()
        show(currentIndex, direction: .forward, animated: false)
    }

    private func relayout() {
        let known = self.known
        units = ComicUnit.layout(count: pageCount, isWide: { known[$0] }, split: settings.split && !spread, spread: spread)
    }

    /// 그림을 읽고 나서 가로로 긴 그림을 새로 알게 됐으면 배치를 다시 한다 (지금 보이는 화면은 그대로)
    func learned(_ wide: [Int: Bool]) {
        guard wide != known.filter({ wide.keys.contains($0.key) }) else { return }
        known.merge(wide) { $1 }
        relayout()
        // 지금 화면이 새 배치에 없으면 (재생바로 건너뛴 쪽이 알고 보니 펼친 쪽이었다 등) 그 쪽이 든 화면으로 다시 놓는다
        if let current = currentUnit, !units.contains(current), !isTurning {
            show(currentIndex, direction: .forward, animated: false)
        }
    }

    private var currentUnit: ComicUnit? {
        (pager?.viewControllers?.first as? ComicPageController)?.unit
    }

    /// 지금 화면의 순서 (배치가 바뀌었으면 같은 쪽이 들어 있는 화면)
    private var currentIndex: Int {
        index(of: currentUnit) ?? units.firstIndex { $0.pages.contains(pageNumber - 1) } ?? 0
    }

    private func index(of unit: ComicUnit?) -> Int? {
        guard let unit else { return nil }
        return units.firstIndex(of: unit) ?? units.firstIndex { $0.pages.contains(unit.pages[0]) && ($0.half == nil || $0.half == unit.half) }
    }

    func jump(to page: Int) {
        guard let index = units.firstIndex(where: { $0.pages.contains(page) }) else { return }
        show(index, direction: index >= currentIndex ? .forward : .reverse, animated: false)
    }

    func controller(at index: Int) -> UIViewController? {
        if index == units.count { return ComicEndController(reader: self) }
        guard units.indices.contains(index) else { return nil }
        return ComicPageController(reader: self, unit: units[index])
    }

    func show(_ index: Int, direction: UIPageViewController.NavigationDirection, animated: Bool) {
        guard let pager, let controller = controller(at: index) else { return }
        // 오른쪽에서 왼쪽으로 읽으면 "다음" 이 왼쪽에서 들어온다
        let flipped: UIPageViewController.NavigationDirection = settings.rightToLeft ? (direction == .forward ? .reverse : .forward) : direction
        guard animated else {
            pager.setViewControllers([controller], direction: flipped, animated: false)
            didShow(controller)
            return
        }
        isTurning = true
        turnID += 1
        let id = turnID
        var finished = false
        let finish = { [weak self, weak pager] in
            guard !finished, let self, self.turnID == id else { return }
            finished = true
            // 애니메이션으로 바꾼 뒤 UIPageViewController 가 옆 화면을 예전 것으로 기억하는 문제가 있어 한 번 더 놓는다
            pager?.setViewControllers([controller], direction: flipped, animated: false)
            self.isTurning = false
            self.didShow(controller)
            if let left = self.pendingTurn {
                self.pendingTurn = nil
                self.turn(left: left)
            }
        }
        pager.setViewControllers([controller], direction: flipped, animated: true) { _ in
            DispatchQueue.main.async { finish() }
        }
        // 완료 알림이 오지 않는 경우가 있어 (화면이 뜨는 중에 넘기면 등) 조금 뒤 스스로 끝낸다
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { finish() }
    }

    private func didShow(_ controller: UIViewController?) {
        if let page = (controller as? ComicPageController)?.unit {
            pageNumber = (page.pages.last ?? 0) + 1
            Task { await cache.keep(max(0, page.pages[0] - 6)...page.pages[0] + 8) }
            prefetch(from: index(of: page) ?? 0)
        } else if controller is ComicEndController {
            pageNumber = pageCount
            if autoAdvancing { autoAdvancing = false }
        }
        restartAutoAdvance()
    }

    /// 앞뒤 몇 장을 미리 읽어 둔다 (넘길 때 기다리지 않게, 가로로 긴 그림을 미리 알게)
    private func prefetch(from index: Int) {
        let pages = units[max(0, index - 1)..<min(units.count, index + 4)].flatMap(\.pages)
        let cache = self.cache
        Task {
            for page in Set(pages).sorted() { _ = try? await cache.image(page) }
            learned(await cache.knownWide())
        }
    }

    // MARK: 자동 넘김

    /// ▶/■: 켜면 조작을 숨기고 간격만큼 기다렸다 다음 쪽으로
    /// 바뀜 (2026-11-08): 바로 숨기면 켜졌는지 모르겠다 (사용자) → 3초 뒤 숨긴다 (그 사이 가운데를 눌러 직접 숨겨도 됨).
    ///   조작이 보이는 동안은 세지 않으므로 숨긴 뒤부터 센다
    func toggleAutoAdvance() {
        autoAdvancing.toggle()
        hideTask?.cancel()
        if autoAdvancing {
            hideTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(3))
                guard !Task.isCancelled, let self, self.autoAdvancing else { return }
                self.showsControls = false
            }
        }
        restartAutoAdvance()
    }

    /// 처음부터 다시 센다: 쪽이 바뀔 때(직접 넘기기·막대·자동), 손을 뗄 때, 조작·패널이 닫힐 때.
    /// 누르고 있는 동안·조작이나 패널이 떠 있는 동안은 세지 않는다
    func restartAutoAdvance() {
        autoTask?.cancel()
        autoTask = nil
        guard autoAdvancing, !touching, !isBlocked, !showsControls else { return }
        let seconds = AppSettings.shared.comicAutoSeconds
        autoTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            self?.autoTurn()
        }
    }

    private func autoTurn() {
        // 끝 화면이면 멈춘다 (다음 권으로 넘어가거나 닫지 않는다)
        if pager?.viewControllers?.first is ComicEndController {
            autoAdvancing = false
            return
        }
        turn(left: settings.rightToLeft)
    }

    /// 화면에 손가락이 닿음·모두 뗌 (넘기기 화면 위 아무 곳이나)
    func touchChanged(down: Bool) {
        guard touching != down else { return }
        touching = down
        restartAutoAdvance()
    }

    // MARK: 탭

    /// 화면을 눌렀다: 왼쪽·오른쪽 1/3 은 넘기기, 가운데는 조작 보이기
    func tapped(atFraction x: CGFloat) {
        if x < 0.3 {
            turn(left: true)
        } else if x > 0.7 {
            turn(left: false)
        } else {
            showsControls.toggle()
        }
    }

    /// 키보드 ←→ (아이패드): 화면 왼쪽·오른쪽을 누른 것과 같다
    func turnByKey(left: Bool) {
        turn(left: left)
    }

    private func turn(left: Bool) {
        guard !isTurning else {
            pendingTurn = left
            return
        }
        let forward = left == settings.rightToLeft
        let current = pager?.viewControllers?.first
        let target = current is ComicEndController ? (forward ? nil : units.count - 1) : currentIndex + (forward ? 1 : -1)
        guard let target, target >= 0, target <= units.count else {
            if forward, current is ComicEndController { onClose?() }
            return
        }
        showsControls = false
        show(target, direction: forward ? .forward : .reverse, animated: true)
    }

    // MARK: UIPageViewControllerDataSource

    private func neighbor(of controller: UIViewController, forward: Bool) -> UIViewController? {
        if controller is ComicEndController { return forward ? nil : self.controller(at: units.count - 1) }
        guard let unit = (controller as? ComicPageController)?.unit, let index = index(of: unit) else { return nil }
        return self.controller(at: index + (forward ? 1 : -1))
    }

    func pageViewController(_ pageViewController: UIPageViewController, viewControllerBefore viewController: UIViewController) -> UIViewController? {
        neighbor(of: viewController, forward: settings.rightToLeft)
    }

    func pageViewController(_ pageViewController: UIPageViewController, viewControllerAfter viewController: UIViewController) -> UIViewController? {
        neighbor(of: viewController, forward: !settings.rightToLeft)
    }

    func pageViewController(_ pageViewController: UIPageViewController, didFinishAnimating finished: Bool,
                            previousViewControllers: [UIViewController], transitionCompleted completed: Bool) {
        if completed { didShow(pageViewController.viewControllers?.first) }
    }

    func pageViewController(_ pageViewController: UIPageViewController, willTransitionTo pendingViewControllers: [UIViewController]) {
        showsControls = false
    }
}

/// SwiftUI 에 UIPageViewController 를 놓는다
private struct ComicPager: UIViewControllerRepresentable {
    let reader: ComicReader

    func makeUIViewController(context: Context) -> ComicPagerHost {
        ComicPagerHost(reader: reader)
    }

    func updateUIViewController(_ controller: ComicPagerHost, context: Context) {
        controller.reader = reader
    }
}

/// 넘기기 화면을 담고, 회전하면 두 쪽 펼침을 켜고 끈다
final class ComicPagerHost: UIViewController {
    var reader: ComicReader {
        didSet {
            guard reader !== oldValue else { return }
            attach()
        }
    }

    private let pager = UIPageViewController(transitionStyle: .scroll, navigationOrientation: .horizontal,
                                             options: [.interPageSpacing: 12])

    init(reader: ComicReader) {
        self.reader = reader
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        addChild(pager)
        pager.view.frame = view.bounds
        pager.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(pager.view)
        pager.didMove(toParent: self)
        // 자동 넘김: 손가락이 닿아 있는 동안 멈추게 (넘기기·탭·확대는 그대로 받는다)
        view.addGestureRecognizer(TouchWatcher { [weak self] down in self?.reader.touchChanged(down: down) })
        attach()
    }

    private func attach() {
        pager.dataSource = reader
        pager.delegate = reader
        reader.pager = pager
        if view.bounds.width > 0 { reader.setSpread(isLandscape(view.bounds.size)) }
        reader.jump(to: reader.resumePage)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        // 처음부터 가로로 열었을 때
        if view.bounds.width > 0 { reader.setSpread(isLandscape(view.bounds.size)) }
    }

    override func viewWillTransition(to size: CGSize, with coordinator: any UIViewControllerTransitionCoordinator) {
        super.viewWillTransition(to: size, with: coordinator)
        coordinator.animate(alongsideTransition: nil) { _ in
            self.reader.setSpread(self.isLandscape(size))
        }
    }

    private func isLandscape(_ size: CGSize) -> Bool {
        size.width > size.height
    }
}

/// 손가락이 닿았는지·모두 뗐는지만 알려 주고 다른 제스처를 막지 않는 인식기 (늘 실패로 끝난다)
private final class TouchWatcher: UIGestureRecognizer {
    private let onChange: (Bool) -> Void
    private var count = 0

    init(onChange: @escaping (Bool) -> Void) {
        self.onChange = onChange
        super.init(target: nil, action: nil)
        cancelsTouchesInView = false
        delaysTouchesBegan = false
        delaysTouchesEnded = false
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        if count == 0 { onChange(true) }
        count += touches.count
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) { lift(touches) }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) { lift(touches) }

    private func lift(_ touches: Set<UITouch>) {
        count = max(0, count - touches.count)
        if count == 0 {
            onChange(false)
            state = .failed
        }
    }

    override func reset() {
        super.reset()
        if count > 0 {
            count = 0
            onChange(false)
        }
    }

    override func canPrevent(_ preventedGestureRecognizer: UIGestureRecognizer) -> Bool { false }
    override func canBePrevented(by preventingGestureRecognizer: UIGestureRecognizer) -> Bool { false }
}

/// 화면 한 장: 그림 + 확대 (두 손가락)
final class ComicPageController: UIViewController, UIScrollViewDelegate {
    let unit: ComicUnit
    private weak var reader: ComicReader?
    private let scrollView = UIScrollView()
    private let imageView = UIImageView()
    private let spinner = UIActivityIndicatorView(style: .large)
    private var loadTask: Task<Void, Never>?

    init(reader: ComicReader, unit: ComicUnit) {
        self.reader = reader
        self.unit = unit
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit { loadTask?.cancel() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        scrollView.frame = view.bounds
        scrollView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        scrollView.delegate = self
        scrollView.minimumZoomScale = 1
        scrollView.maximumZoomScale = 4
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.showsVerticalScrollIndicator = false
        scrollView.contentInsetAdjustmentBehavior = .never
        view.addSubview(scrollView)
        imageView.contentMode = .scaleAspectFit
        imageView.frame = scrollView.bounds
        scrollView.addSubview(imageView)
        spinner.color = .white
        spinner.center = CGPoint(x: view.bounds.midX, y: view.bounds.midY)
        spinner.autoresizingMask = [.flexibleLeftMargin, .flexibleRightMargin, .flexibleTopMargin, .flexibleBottomMargin]
        spinner.startAnimating()
        view.addSubview(spinner)

        let tap = UITapGestureRecognizer(target: self, action: #selector(tapped(_:)))
        view.addGestureRecognizer(tap)

        guard let reader else { return }
        let cache = reader.cache
        let unit = self.unit
        let rightToLeft = reader.settings.rightToLeft
        let swapHalves = reader.settings.swapHalves
        loadTask = Task { [weak self] in
            do {
                let image = try await cache.render(unit, rightToLeft: rightToLeft, swapHalves: swapHalves)
                self?.show(UIImage(cgImage: image))
                reader.learned(await cache.knownWide())
            } catch {
                self?.spinner.stopAnimating()
            }
        }
    }

    private func show(_ image: UIImage) {
        spinner.stopAnimating()
        imageView.image = image
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        if scrollView.zoomScale == 1 { imageView.frame = scrollView.bounds }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        scrollView.setZoomScale(1, animated: false)
    }

    @objc private func tapped(_ recognizer: UITapGestureRecognizer) {
        // 넘기는 중에는 이 화면이 움직이고 있으므로 창 기준으로 잰다
        let window: UIView = view.window ?? view
        reader?.tapped(atFraction: recognizer.location(in: window).x / max(window.bounds.width, 1))
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? {
        imageView
    }
}

/// 마지막 장 다음: 다 읽었다 + 다음 권
final class ComicEndController: UIHostingController<ComicEndView> {
    init(reader: ComicReader) {
        super.init(rootView: ComicEndView(next: reader.book.nextVolume, onNext: { reader.onNextVolume?() }, onClose: { reader.onClose?() }))
        view.backgroundColor = .black
    }

    @MainActor required dynamic init?(coder aDecoder: NSCoder) { fatalError() }
}

struct ComicEndView: View {
    let next: VideoFile?
    let onNext: () -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "checkmark.circle")
                .font(.system(size: 48))
                .foregroundStyle(.white.opacity(0.8))
            Text("끝까지 읽었습니다")
                .font(.title3.bold())
                .foregroundStyle(.white)
            if let next {
                Button(action: onNext) {
                    Label("다음 권: \(next.title)", systemImage: "forward.end.fill")
                        .font(.headline)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                }
                .buttonStyle(.glassProminent)
            }
            Button("닫기", action: onClose)
                .buttonStyle(.glass)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.black)
    }
}

/// 쪽 모아보기: 사진 앱처럼 쪽 썸네일 격자. 누르면 그 쪽으로 간다.
/// 왼쪽으로 읽는 책은 격자도 오른쪽에서 왼쪽으로 놓는다.
private struct ComicGridView: View {
    let reader: ComicReader
    let onSelect: (Int) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    // 사진 앱처럼 정사각형 칸에 꽉 채우고 넘치는 부분은 자른다
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 100), spacing: 2)], spacing: 2) {
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
                    .environment(\.layoutDirection, reader.settings.rightToLeft ? .rightToLeft : .leftToRight)
                }
                .onAppear { proxy.scrollTo(reader.pageNumber - 1, anchor: .center) }
            }
            .navigationTitle(reader.book.file.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("닫기", systemImage: "xmark") { dismiss() }
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

    @State private var image: UIImage?

    var body: some View {
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .background(.quaternary)
            .overlay {
                if let image {
                    Image(uiImage: image).resizable().scaledToFill()
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
            .task(id: page) {
                if let thumbnail = try? await cache.thumbnail(page) { image = UIImage(cgImage: thumbnail) }
            }
    }
}
