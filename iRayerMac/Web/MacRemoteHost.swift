import Foundation

/// 맥 쪽 원격 웹 탐색 (2026-11-09, 사용자): 폰이 보낸 명령을 받아 탭에 페이지를 열고, 찾은 영상을 올리고, 고른 영상을 받는다.
/// 재생하며 받기는 아직 (맥에서 재생을 시켜야 해서 나중에, 사용자)
/// 바뀜 (2026-11-10, 사용자 A1): 명령·답은 동기화 엔진 대신 받은편지함·보낸편지함 레코드를 이름으로 읽고 쓴다 (RemoteMailbox) —
///   엔진으로는 명령이 3~4분 뒤에야 왔다. 평소 10초마다, 폰이 웹 탐색을 보고 있거나 명령이 오간 뒤 10분은 2초마다 받은편지함을 읽는다.
///   켜져 있음·탭 목록은 그대로 동기화 엔진 (느려도 된다)
@MainActor
final class MacRemoteHost {
    static let shared = MacRemoteHost()

    private let remote = MacRemote.shared
    private var macID: String { WebDownloadStatus.shared.macID }
    private let macName = Host.current().localizedName ?? "Mac"
    /// 폰이 보낸 페이지를 연 탭 → 그 명령
    private var remoteTabs: [UUID: String] = [:]
    /// 이미 한 명령 (받은편지함은 폰만 고쳐 쓰므로 맥은 한 것을 기억해 다시 하지 않는다)
    private var handled: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "remote.handled") ?? [])
    /// 이때까지 자주(2초) 읽는다
    private var busyUntil = Date.distantPast
    private var lastOutbox: RemoteMailbox.Outbox?
    private var timer: Timer?
    private var ticks = 0
    private var loop: Task<Void, Never>?

    private init() {}

    /// 원격 제어에 쓸지 (맥 웹 탐색 설정, 2026-11-10 사용자). 끄면 폰 목록에서 빠지고 받은편지함을 읽지 않는다
    static let enabledKey = "remote.enabled"
    static var isEnabled: Bool { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }

    /// 설정에서 켜고 끌 때
    func setEnabled(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: Self.enabledKey)
        if on { start() } else { stop() }
    }

    /// 원격 제어 끄기: 켜져 있음 기록을 지우고 보낸편지함을 비운다
    private func stop() {
        timer?.invalidate()
        timer = nil
        loop?.cancel()
        loop = nil
        remoteTabs = [:]
        lastOutbox = nil
        remote.presence.remove(macID)
        Task {
            await SyncEngine.shared.sendNow("원격: 끔")
            await RemoteMailbox.writeOutbox(macID, .init())
        }
        WebLog.write("원격: 원격 제어 끔")
    }

    /// 동기화를 시작한 뒤 한 번 (원격 제어를 껐으면 하지 않는다)
    func start() {
        guard timer == nil, Self.isEnabled else { return }
        publishPresence(force: true)
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { _ in
            MainActor.assumeIsolated { MacRemoteHost.shared.tick() }
        }
        loop = Task { [weak self] in
            // 지난번에 켰을 때 쓴 찾은 영상은 탭이 없어졌으니 비운다
            if let self { await RemoteMailbox.writeOutbox(self.macID, .init()) }
            while !Task.isCancelled {
                guard let self else { return }
                await self.checkInbox()
                let busy = Date.now < self.busyUntil
                try? await Task.sleep(for: .seconds(busy ? 2 : 10))
            }
        }
    }

    private func tick() {
        ticks += 1
        // 찾은 영상이 바뀌었으면 보낸편지함에 쓴다
        Task { await publishFound() }
        // 5분마다 켜져 있음 (탭이 바뀌었으면 바로)
        publishPresence(force: ticks % 100 == 0)
    }

    private var currentTabs: [MacPresence.Tab] {
        WebTabs.shared.tabs.map { tab in
            MacPresence.Tab(id: tab.id.uuidString, title: tab.title, url: tab.browser.url?.absoluteString, busy: tab.capture.isOn || tab.capture.state == .saving)
        }
    }

    private func publishPresence(force: Bool) {
        let tabs = currentTabs
        let old = remote.presence.values[macID]
        guard force || old?.tabs != tabs || old?.name != macName else { return }
        remote.presence.put(macID, MacPresence(macID: macID, name: macName, seenAt: .now, tabs: tabs))
        Task { await SyncEngine.shared.sendNow("원격: 켜져 있음") }
    }

    /// 폰이 보낸 페이지를 연 탭마다 찾은 영상 → 보낸편지함 (달라졌을 때만)
    private func publishFound() async {
        var outbox = RemoteMailbox.Outbox()
        for (tabID, commandID) in remoteTabs {
            guard let tab = WebTabs.shared.tabs.first(where: { $0.id == tabID }) else {
                remoteTabs[tabID] = nil
                continue
            }
            let browser = tab.browser
            let media = browser.detected.map { item in
                MacFound.Media(id: item.id, kind: item.kind.rawValue, name: item.fileName, quality: item.quality, size: item.size,
                               downloadable: item.isDownloadable && !item.capturesOnly, capturesOnly: item.capturesOnly,
                               unsupported: item.unsupported, started: WebDownloads.shared.item(for: item) != nil,
                               checking: item.inspecting)
            }
            var found = MacFound(macID: macID, tabID: tabID.uuidString, commandID: commandID, url: browser.url?.absoluteString,
                                 title: tab.title, loading: browser.isLoading, media: media)
            // 재생하며 받기 상태 (폰이 "맥에서 받기 시작됨" 을 보이게)
            let capture = tab.capture
            switch capture.state {
            case .off: found.capture = nil
            case .waiting: found.capture = "waiting"
            case .capturing: found.capture = "capturing"
            case .saving: found.capture = "saving"
            case .saved: found.capture = "saved"
            case .failed: found.capture = "failed"
            }
            if let duration = capture.playback?.duration, duration > 0, capture.frontier != nil {
                let missing = capture.gaps.reduce(0) { $0 + ($1.upperBound - $1.lowerBound) }
                found.captureFraction = (max(0, min(1, 1 - missing / duration)) * 100).rounded() / 100
            }
            outbox.found.append(found)
        }
        outbox.found.sort { $0.tabID < $1.tabID }
        outbox.tabs = currentTabs
        guard timer != nil, outbox != lastOutbox else { return }
        lastOutbox = outbox
        await RemoteMailbox.writeOutbox(macID, outbox)
    }

    /// 받은편지함을 읽고 아직 안 한 명령을 한다
    private func checkInbox() async {
        guard let inbox = await RemoteMailbox.inbox(macID) else { return }
        if let until = inbox.phoneActiveUntil, until > busyUntil { busyUntil = until }
        for command in inbox.commands where !handled.contains(command.id) {
            handled.insert(command.id)
            UserDefaults.standard.set(Array(handled.suffix(200)), forKey: "remote.handled")
            busyUntil = max(busyUntil, Date.now.addingTimeInterval(10 * 60))
            // 보내고 맥에 오기까지 걸린 시간
            WebLog.write("원격: \(command.from) 의 명령(\(command.action.rawValue))이 \(Int(Date.now.timeIntervalSince(command.sentAt)))초 만에 도착")
            guard Date.now.timeIntervalSince(command.sentAt) < MacRemote.commandLifetime else {
                WebLog.write("원격: \(command.from) 의 명령이 오래되어 하지 않음 (\(command.action.rawValue))")
                continue
            }
            switch command.action {
            case .open: open(command)
            case .download: download(command)
            case .capture: capture(command)
            case .click: click(command)
            case .close: close(command)
            }
        }
    }

    private func open(_ command: MacCommand) {
        guard let text = command.url else { return }
        let tabs = WebTabs.shared
        let target = command.tabID.flatMap(UUID.init(uuidString:)).flatMap { id in tabs.tabs.first { $0.id == id } }
        let tab: WebTab
        if let target, !target.capture.isOn, target.capture.state != .saving {
            tab = target
            tabs.currentID = target.id
        } else {
            tabs.add()
            tab = tabs.current
        }
        tab.browser.openedRemotely = true  // 바뀜 (2026-11-12): 이 탭은 스크립트 이동을 묻지 않는다
        tab.browser.open(text)
        remoteTabs[tab.id] = command.id
        WebLog.write("원격: \(command.from) 이 보낸 페이지를 \(target == nil ? "새 탭" : "탭") 에 엶 \(text)")
        Task { await publishFound() }
        publishPresence(force: true)
    }

    private func download(_ command: MacCommand) {
        guard let tabID = command.tabID.flatMap(UUID.init(uuidString:)),
              let tab = WebTabs.shared.tabs.first(where: { $0.id == tabID }),
              let media = tab.browser.detected.first(where: { $0.id == command.mediaID }) else {
            WebLog.write("원격: \(command.from) 이 고른 영상을 탭에서 찾지 못함")
            return
        }
        guard media.isDownloadable, !media.capturesOnly else { return }
        WebDownloads.shared.start(media)
        WebLog.write("원격: \(command.from) 이 고른 영상 받기 \(media.fileName)")
        Task { await publishFound() }
    }

    private func tab(for command: MacCommand) -> WebTab? {
        command.tabID.flatMap(UUID.init(uuidString:)).flatMap { id in WebTabs.shared.tabs.first { $0.id == id } }
    }

    /// 폰에서 닫은 탭 (재생하며 받는 중·저장 중이면 닫지 않는다)
    private func close(_ command: MacCommand) {
        guard let tab = tab(for: command) else { return }
        guard !tab.capture.isOn, tab.capture.state != .saving else {
            WebLog.write("원격: \(command.from) 이 재생하며 받는 탭을 닫으려 해 닫지 않음 (\(tab.title))")
            return
        }
        WebLog.write("원격: \(command.from) 이 탭을 닫음 (\(tab.title))")
        remoteTabs[tab.id] = nil
        WebTabs.shared.close(tab.id)
        Task { await publishFound() }
        publishPresence(force: true)
    }

    /// 재생하며 받기를 켜고 소리 없이 재생해 본다 (가장 큰 영상). 안 되면 폰에서 재생 단추를 누르게 한다
    private func capture(_ command: MacCommand) {
        guard let tab = tab(for: command) else {
            WebLog.write("원격: \(command.from) 의 재생하며 받기 — 탭을 찾지 못함")
            return
        }
        if !tab.capture.isOn { tab.capture.start() }
        WebLog.write("원격: \(command.from) 이 재생하며 받기를 켬 (\(tab.title))")
        Task {
            try? await Task.sleep(for: .seconds(1))
            let results = await tab.capture.run(Self.autoplayScript)
            WebLog.write("원격: 소리 없이 재생해 봄 → \(results.joined(separator: ", "))")
            await publishFound()
        }
    }

    /// 폰에서 누른 곳을 그 탭에서 똑같이 누른다 (선택자로 요소를 찾고, 못 찾으면 화면 속 위치로)
    private func click(_ command: MacCommand) {
        guard let tab = tab(for: command), let target = command.click else { return }
        if !tab.capture.isOn { tab.capture.start() }
        Task {
            let results = await tab.capture.run(Self.clickScript, arguments: ["selector": target.selector ?? "", "x": target.x, "y": target.y],
                                                frameURL: target.frameURL)
            WebLog.write("원격: \(command.from) 이 누른 곳(\(target.label ?? "-"))을 누름 → \(results.joined(separator: ", "))")
            await publishFound()
        }
    }

    /// 가장 큰 영상을 소리 끄고 재생 (소리를 끄면 브라우저가 자동 재생을 막지 않는다)
    private static let autoplayScript = """
    const videos = [...document.querySelectorAll('video')];
    let best = null, area = 0;
    for (const v of videos) { const r = v.getBoundingClientRect(); if (r.width * r.height > area) { area = r.width * r.height; best = v; } }
    if (!best) return 'video 없음 (' + location.host + ')';
    if (!best.paused) return '이미 재생 중';
    best.muted = true;
    try { await best.play(); return '재생됨 (' + location.host + ')'; } catch (e) { return '막힘: ' + e.name; }
    """

    /// 누르기: 선택자 → 위치 순으로 요소를 찾아 누름 이벤트를 차례로 보낸다. 누른 뒤에도 영상이 멈춰 있으면 소리 끄고 재생
    private static let clickScript = """
    let el = null;
    try { if (selector) el = document.querySelector(selector); } catch (e) {}
    const how = el ? '선택자' : '위치';
    if (!el) el = document.elementFromPoint(x * innerWidth, y * innerHeight);
    if (!el) return '누를 것 없음 (' + location.host + ')';
    el.scrollIntoView({ block: 'center' });
    const r = el.getBoundingClientRect(), cx = r.left + r.width / 2, cy = r.top + r.height / 2;
    for (const type of ['pointerdown', 'mousedown', 'pointerup', 'mouseup', 'click']) {
        const Kind = type.startsWith('pointer') ? PointerEvent : MouseEvent;
        el.dispatchEvent(new Kind(type, { bubbles: true, cancelable: true, composed: true, clientX: cx, clientY: cy, view: window }));
    }
    await new Promise(done => setTimeout(done, 800));
    const v = el.tagName === 'VIDEO' ? el : document.querySelector('video');
    if (v && v.paused) { v.muted = true; try { await v.play(); } catch (e) {} }
    return how + '로 ' + el.tagName.toLowerCase() + ' 누름, 영상 ' + (v ? (v.paused ? '멈춤' : '재생') : '없음') + ' (' + location.host + ')';
    """
}
