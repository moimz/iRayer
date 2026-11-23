import Foundation
import Observation
import WebKit

/// 웹 탐색 광고 차단 (2026-11-12, 사용자): 직접 적은 규칙을 웹킷 콘텐츠 차단 규칙(WKContentRuleList)으로 바꿔 모든 웹 탐색 웹뷰에 붙인다.
/// 규칙 글은 iCloud 로 아이폰·아이패드·맥이 같이 쓴다. 규칙을 찾아 주는 기능은 두지 않는다 (사용자가 셀렉터를 직접 적는다).
///
/// 한 줄에 규칙 하나 (AdBlock 문법의 작은 부분):
///   `||ads.example.com^`        그 도메인(하위 도메인 포함)으로 가는 요청을 막는다. `||host/path` 처럼 경로까지 적어도 된다
///   `example.com##.ad, #banner` 그 사이트(하위 도메인 포함)에서 셀렉터에 맞는 요소를 숨긴다
///   `##.ad-slot`                 모든 사이트에서 숨긴다
///   `@@||example.com^`           그 사이트에서는 아무것도 막지 않는다 (예외)
///   `/ads/banner`                주소에 이 글이 들어간 요청을 막는다 (`*` 는 아무 글)
///   `! 메모`                     무시 (빈 줄도)
@Observable
final class AdBlock {
    static let shared = AdBlock()
    static let syncKind = "adBlock"

    struct Stored: Codable {
        var enabled: Bool
        var text: String
        var updatedAt: Date
        // 바뀜 (2026-11-12): 팝업 가짜 창·스크립트 이동 묻기 (앞서 올린 기록에는 없다 → nil 이면 켬)
        var fakePopups: Bool?
        var confirmNavigation: Bool?
    }

    /// 켜져 있는지 (끄면 규칙을 모두 뗀다)
    private(set) var enabled = true
    /// 사용자가 적은 규칙 글 그대로
    private(set) var text = ""
    /// 바뀜 (2026-11-12, 사용자): 클릭 아닌 window.open 은 막되, 페이지에는 가짜 창을 돌려줘 막힌 줄 모르게 (맥)
    private(set) var fakePopups = true
    /// 바뀜 (2026-11-12, 사용자): 누르지 않았는데 페이지가 다른 곳으로 가려 하면 묻는다 (맥)
    private(set) var confirmNavigation = true
    /// 사이트별 User-Agent (`host$ua=값` 줄, 2026-11-12). 광고 차단을 꺼도 쓴다
    private(set) var agentRules: [SiteAgent.Rule] = []
    /// 예외 사이트 (`@@||host^` 줄): 광고 차단·가짜 창·이동 묻기를 모두 하지 않는다
    private(set) var exceptionHosts: [String] = []
    /// 마지막으로 만든 웹킷 규칙 수 (설정 화면에 보인다)
    private(set) var compiledCount = 0
    /// 규칙을 웹킷 규칙으로 바꾸지 못한 까닭 (잘못된 셀렉터 등). nil 이면 괜찮음
    private(set) var error: String?
    /// 웹킷이 받아들이지 않은 줄 (변환 단계에서 거른 것)
    private(set) var skippedLines: [String] = []

    @ObservationIgnored private var updatedAt = Date.distantPast
    @ObservationIgnored private let defaults = UserDefaults.standard
    @ObservationIgnored private static let storeKey = "adBlock"
    @ObservationIgnored private static let recordKey = "rules"
    @ObservationIgnored private static let listID = "iRayer.adBlock"
    /// 지금 붙어 있는 규칙 (새로 만들면 바꿔 단다)
    @ObservationIgnored private var list: WKContentRuleList?
    /// 규칙을 붙일 웹뷰들의 글 상자 (웹뷰가 사라지면 저절로 빠진다)
    @ObservationIgnored private let controllers = NSHashTable<WKUserContentController>.weakObjects()
    @ObservationIgnored private var compileTask: Task<Void, Never>?

    private init() {
        if let data = defaults.data(forKey: Self.storeKey), let stored = try? JSONDecoder().decode(Stored.self, from: data) {
            enabled = stored.enabled
            text = stored.text
            updatedAt = stored.updatedAt
            fakePopups = stored.fakePopups ?? true
            confirmNavigation = stored.confirmNavigation ?? true
        }
        rebuild()
    }

    /// 웹뷰를 만들 때 그 설정의 글 상자를 넘긴다 — 규칙이 있으면 바로 붙고, 바뀌면 다시 붙는다 (다음에 여는 페이지부터)
    func attach(_ controller: WKUserContentController) {
        controllers.add(controller)
        if let list { controller.add(list) }
        if let hidingScript { controller.addUserScript(hidingScript) }
    }

    func update(enabled: Bool? = nil, text: String? = nil, fakePopups: Bool? = nil, confirmNavigation: Bool? = nil) {
        if let enabled { self.enabled = enabled }
        if let text { self.text = text }
        if let fakePopups { self.fakePopups = fakePopups }
        if let confirmNavigation { self.confirmNavigation = confirmNavigation }
        updatedAt = .now
        save()
        SyncEngine.shared.changed(Self.syncKind, key: Self.recordKey)
        rebuild()
    }

    private var stored: Stored {
        Stored(enabled: enabled, text: text, updatedAt: updatedAt, fakePopups: fakePopups, confirmNavigation: confirmNavigation)
    }

    private func save() {
        defaults.set(try? JSONEncoder().encode(stored), forKey: Self.storeKey)
    }

    /// 이 주소의 사이트가 예외인지 (하위 도메인 포함)
    func isException(_ url: URL?) -> Bool {
        guard let host = url?.host()?.lowercased() else { return false }
        return exceptionHosts.contains { host == $0 || host.hasSuffix("." + $0) }
    }

    /// 글을 웹킷 규칙으로 바꿔 모든 웹뷰에 바꿔 단다
    private func rebuild() {
        compileTask?.cancel()
        let converted = Self.convert(text)
        skippedLines = converted.skipped
        exceptionHosts = converted.exceptions
        agentRules = SiteAgent.rules(text)
        replaceHidingScript()
        guard enabled, !converted.rules.isEmpty,
              let data = try? JSONSerialization.data(withJSONObject: converted.rules),
              let json = String(data: data, encoding: .utf8) else {
            replace(with: nil)
            compiledCount = 0
            error = nil
            return
        }
        compileTask = Task {
            do {
                let list = try await WKContentRuleListStore.default().compileContentRuleList(forIdentifier: Self.listID,
                                                                                              encodedContentRuleList: json)
                guard !Task.isCancelled else { return }
                replace(with: list)
                compiledCount = converted.rules.count
                error = nil
            } catch {
                guard !Task.isCancelled else { return }
                // 잘못된 규칙이 하나라도 있으면 웹킷은 목록 전체를 거부한다 — 앞서 붙인 것은 그대로 둔다
                self.error = error.localizedDescription
            }
        }
    }

    private func replace(with newList: WKContentRuleList?) {
        for controller in controllers.allObjects {
            if let list { controller.remove(list) }
            if let newList { controller.add(newList) }
        }
        list = newList
    }

    // MARK: - 스크립트로 숨기기

    /// 바뀜 (2026-11-12, 사용자: 어떤 사이트의 .banner-static 이 ##.banner-static 으로 안 숨겨짐 — ##header 는 됨):
    /// 웹킷의 숨기기(css-display-none)는 사이트 CSS 와 같은 단계라, 사이트가 더 구체적인 셀렉터나 인라인 style 로
    /// display 를 !important 로 주면 진다. 그래서 ## 규칙은 스크립트로도 건다:
    /// 모든 프레임에 <style> 을 넣고, 맞는 요소에는 인라인 display:none !important 를 직접 단다 (바뀌면 다시).
    /// 새로 생기는 shadow root 에도 같은 스타일을 넣는다. 잘못된 셀렉터는 그 줄만 건너뛴다
    @ObservationIgnored private var hidingScript: WKUserScript?
    @ObservationIgnored private static let hidingMarker = "/* irayer-adblock-hide */"

    private func replaceHidingScript() {
        let rules = enabled ? Self.hidingRules(text) : []
        let newScript = rules.isEmpty ? nil : Self.makeHidingScript(rules, exceptions: exceptionHosts)
        for controller in controllers.allObjects {
            let others = controller.userScripts.filter { !$0.source.hasPrefix(Self.hidingMarker) }
            controller.removeAllUserScripts()
            others.forEach(controller.addUserScript)
            if let newScript { controller.addUserScript(newScript) }
        }
        hidingScript = newScript
    }

    /// ## 줄만: [사이트들, 셀렉터]
    static func hidingRules(_ text: String) -> [[Any]] {
        text.split(whereSeparator: \.isNewline).compactMap { raw -> [Any]? in
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.hasPrefix("!"), let range = line.range(of: "##") else { return nil }
            let selector = line[range.upperBound...].trimmingCharacters(in: .whitespaces)
            guard !selector.isEmpty else { return nil }
            let domains = line[..<range.lowerBound].split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
                .filter { !$0.isEmpty }
            return [domains, selector]
        }
    }

    private static func makeHidingScript(_ rules: [[Any]], exceptions: [String]) -> WKUserScript? {
        guard let rulesData = try? JSONSerialization.data(withJSONObject: rules),
              let exceptionsData = try? JSONSerialization.data(withJSONObject: exceptions),
              let rulesJSON = String(data: rulesData, encoding: .utf8),
              let exceptionsJSON = String(data: exceptionsData, encoding: .utf8) else { return nil }
        let source = hidingMarker + """
        (function () {
          if (window.__irayerHide) return;
          window.__irayerHide = true;
          var rules = \(rulesJSON), exceptions = \(exceptionsJSON);
          var host = location.hostname;
          if (!host) { try { host = window.top.location.hostname; } catch (e) {} }
          host = (host || '').toLowerCase();
          function matches(d) { return host === d || host.slice(-(d.length + 1)) === '.' + d; }
          if (exceptions.some(matches)) return;
          var probe = document.createDocumentFragment();
          var selectors = rules.filter(function (r) { return r[0].length === 0 || r[0].some(matches); })
            .map(function (r) { return r[1]; })
            .filter(function (s) { try { probe.querySelector(s); return true; } catch (e) { return false; } });
          if (!selectors.length) return;
          var joined = selectors.join(',');
          var css = selectors.map(function (s) { return s + '{display:none!important}'; }).join('\n');
          function addStyle(root) {
            var target = root === document ? (document.head || document.documentElement) : root;
            if (!target) { document.addEventListener('DOMContentLoaded', function () { addStyle(root); }); return; }
            var style = document.createElement('style');
            style.textContent = css;
            target.appendChild(style);
          }
          function hide(el) {
            if (el.style.getPropertyValue('display') !== 'none' || el.style.getPropertyPriority('display') !== 'important')
              el.style.setProperty('display', 'none', 'important');
          }
          var roots = [document];
          function scan() {
            pending = false;
            roots.forEach(function (root) { try { root.querySelectorAll(joined).forEach(hide); } catch (e) {} });
          }
          var pending = false;
          var observer = new MutationObserver(function () {
            if (pending) return;
            pending = true;
            (window.requestAnimationFrame || setTimeout)(scan);
          });
          var options = { childList: true, subtree: true, attributes: true, attributeFilter: ['class', 'id', 'style'] };
          var attachShadow = Element.prototype.attachShadow;
          if (attachShadow) {
            Element.prototype.attachShadow = function () {
              var root = attachShadow.apply(this, arguments);
              try { addStyle(root); roots.push(root); observer.observe(root, options); } catch (e) {}
              return root;
            };
          }
          addStyle(document);
          observer.observe(document, options);
          document.addEventListener('DOMContentLoaded', scan);
          scan();
        })();
        """
        return WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: false)
    }

    // MARK: - 변환

    /// 한 줄씩 웹킷 규칙(JSON 객체)으로. 예외(@@)는 웹킷 규칙상 맨 뒤에 와야 앞의 규칙을 무를 수 있다
    static func convert(_ text: String) -> (rules: [[String: Any]], skipped: [String], exceptions: [String]) {
        var blocks: [[String: Any]] = []
        var exceptions: [[String: Any]] = []
        var skipped: [String] = []
        var hosts: [String] = []
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("!") || SiteAgent.isRule(line) { continue }
            if let range = line.range(of: "##") {
                let selector = line[range.upperBound...].trimmingCharacters(in: .whitespaces)
                let domains = line[..<range.lowerBound].split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
                    .filter { !$0.isEmpty }
                guard !selector.isEmpty else { skipped.append(line); continue }
                var trigger: [String: Any] = ["url-filter": ".*"]
                if !domains.isEmpty { trigger["if-domain"] = domains.map { "*" + $0 } }
                blocks.append(["trigger": trigger, "action": ["type": "css-display-none", "selector": selector]])
            } else if line.hasPrefix("@@") {
                let host = String(line.dropFirst(2)).replacingOccurrences(of: "||", with: "")
                    .trimmingCharacters(in: CharacterSet(charactersIn: "^/")).lowercased()
                guard !host.isEmpty, !host.contains("/") else { skipped.append(line); continue }
                exceptions.append(["trigger": ["url-filter": ".*", "if-domain": ["*" + host]], "action": ["type": "ignore-previous-rules"]])
                hosts.append(host)
            } else if line.hasPrefix("||") {
                var rest = String(line.dropFirst(2))
                if rest.hasSuffix("^") { rest.removeLast() }
                guard !rest.isEmpty else { skipped.append(line); continue }
                let (host, path) = rest.firstIndex(of: "/").map { (String(rest[..<$0]), String(rest[$0...])) } ?? (rest, "")
                // 스킴 뒤, 하위 도메인은 있어도 되고, 도메인 다음은 포트·경로 (웹킷은 주소를 "host/" 처럼 늘 / 를 붙여 준다. 정규식 | 는 못 쓴다)
                let filter = "^[^:]+://+([^:/]+\\.)?" + escape(host.lowercased()) + (path.isEmpty ? "[:/?#]" : escape(path))
                blocks.append(["trigger": ["url-filter": filter], "action": ["type": "block"]])
            } else {
                blocks.append(["trigger": ["url-filter": escape(line)], "action": ["type": "block"]])
            }
        }
        return (blocks + exceptions, skipped, hosts)
    }

    /// 웹킷 정규식의 특수 글자를 글자 그대로로. `*` 만은 "아무 글"
    private static func escape(_ string: String) -> String {
        var result = ""
        for character in string {
            switch character {
            case "*": result += ".*"
            case ".", "+", "?", "(", ")", "[", "]", "{", "}", "|", "\\", "^", "$": result += "\\" + String(character)
            default: result.append(character)
            }
        }
        return result
    }

    // MARK: - iCloud

    var syncKinds: [SyncEngine.Kind] {
        [
            SyncEngine.Kind(name: Self.syncKind) {
                [Self.recordKey]
            } payload: { [unowned self] key in
                guard key == Self.recordKey, updatedAt > .distantPast else { return nil }
                return try? JSONEncoder().encode(stored)
            } date: { [unowned self] _ in
                updatedAt > .distantPast ? updatedAt : nil
            } apply: { [unowned self] key, data in
                guard key == Self.recordKey, let stored = try? JSONDecoder().decode(Stored.self, from: data) else { return false }
                // 이 기기에서 더 나중에 고친 것이 있으면 그대로 둔다
                guard stored.updatedAt >= updatedAt else { return true }
                enabled = stored.enabled
                text = stored.text
                updatedAt = stored.updatedAt
                fakePopups = stored.fakePopups ?? true
                confirmNavigation = stored.confirmNavigation ?? true
                save()
                rebuild()
                return true
            } delete: { _ in },
        ]
    }
}
