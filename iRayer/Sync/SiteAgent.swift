import Foundation
import WebKit

/// 사이트별 User-Agent (2026-11-12, 사용자: 어떤 사이트의 플레이어가 사파리에서만 재생 안 됨 — 크롬에서는 됨).
/// 광고 차단 규칙 칸에 `사이트$ua=값` 한 줄 (광고 차단을 꺼도 적용). 값은 chrome·firefox·safari·iphone 또는 UA 글 그대로.
/// 본 페이지 주소의 사이트로 정한다 — 웹뷰 하나에 UA 하나라 그 페이지 안의 iframe 도 같은 UA (끼워 넣은 플레이어는 바깥 사이트로 적는다).
/// UA 가 바뀌어야 하면 그 이동을 멈추고 새 UA 로 다시 연다 (GET 만). chrome 이면 navigator.vendor·window.chrome 도 크롬처럼
enum SiteAgent {
    struct Rule: Equatable {
        let host: String
        let agent: String
        let preset: String?
    }

    /// `host$ua=값` 줄 — 광고 차단 변환에서는 뺀다
    static func isRule(_ line: String) -> Bool { line.contains("$ua=") }

    static func rules(_ text: String) -> [Rule] {
        text.split(whereSeparator: \.isNewline).compactMap { raw in
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.hasPrefix("!"), let range = line.range(of: "$ua=") else { return nil }
            let host = line[..<range.lowerBound].replacingOccurrences(of: "||", with: "")
                .trimmingCharacters(in: CharacterSet(charactersIn: "^/ ")).lowercased()
            let value = line[range.upperBound...].trimmingCharacters(in: .whitespaces)
            guard !host.isEmpty, !value.isEmpty else { return nil }
            let preset = value.lowercased()
            if let agent = presets[preset] { return Rule(host: host, agent: agent, preset: preset) }
            // 이름이 아니면 UA 글 그대로 (공백이 든 긴 글만)
            guard value.contains("/") else { return nil }
            return Rule(host: host, agent: value, preset: nil)
        }
    }

    #if os(macOS)
    static let presets: [String: String] = [
        "chrome": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/142.0.0.0 Safari/537.36",
        "firefox": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10.15; rv:145.0) Gecko/20100101 Firefox/145.0",
        "safari": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Safari/605.1.15",
        "iphone": "Mozilla/5.0 (iPhone; CPU iPhone OS 26_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Mobile/15E148 Safari/604.1",
    ]
    #else
    /// 아이폰·아이패드의 chrome·firefox 는 안드로이드 것 (모바일 화면 그대로, 사파리가 아닌 길로). safari 는 맥 사파리 (데스크톱 화면)
    static let presets: [String: String] = [
        "chrome": "Mozilla/5.0 (Linux; Android 15; Pixel 9) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/142.0.0.0 Mobile Safari/537.36",
        "firefox": "Mozilla/5.0 (Android 15; Mobile; rv:145.0) Gecko/145.0 Firefox/145.0",
        "safari": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Safari/605.1.15",
        "iphone": "Mozilla/5.0 (iPhone; CPU iPhone OS 26_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Mobile/15E148 Safari/604.1",
    ]
    #endif

    static func rule(for url: URL?) -> Rule? {
        guard let host = url?.host()?.lowercased() else { return nil }
        return AdBlock.shared.agentRules.first { host == $0.host || host.hasSuffix("." + $0.host) }
    }

    private static let marker = "/* irayer-site-agent */"
    private static let chromeScript = WKUserScript(source: marker + """
    (function () {
      try { Object.defineProperty(Navigator.prototype, 'vendor', { get: function () { return 'Google Inc.'; }, configurable: true }); } catch (e) {}
      try { if (!window.chrome) window.chrome = { runtime: {}, app: {}, csi: function () {}, loadTimes: function () {} }; } catch (e) {}
      try { delete window.safari; } catch (e) {}
    })();
    """, injectionTime: .atDocumentStart, forMainFrameOnly: false)

    /// 본 페이지 이동 직전에. UA 를 바꿔야 해서 이 이동을 멈췄으면 다시 열 요청을 돌려준다 (호출한 쪽이 cancel 하고 연다)
    static func prepare(_ webView: WKWebView, for action: WKNavigationAction) -> URLRequest? {
        guard let url = action.request.url, url.scheme?.hasPrefix("http") == true else { return nil }
        let rule = rule(for: url)
        updateScript(webView.configuration.userContentController, chrome: rule?.preset == "chrome")
        let wanted = rule?.agent ?? ""
        guard (webView.customUserAgent ?? "") != wanted else { return nil }
        webView.customUserAgent = wanted
        // 뒤로·앞으로·POST 는 다시 열지 않고 그대로 (다음 이동부터 새 UA)
        guard action.navigationType != .backForward, (action.request.httpMethod ?? "GET") == "GET" else { return nil }
        return action.request
    }

    private static func updateScript(_ controller: WKUserContentController, chrome: Bool) {
        let installed = controller.userScripts.contains { $0.source.hasPrefix(marker) }
        guard installed != chrome else { return }
        let others = controller.userScripts.filter { !$0.source.hasPrefix(marker) }
        controller.removeAllUserScripts()
        others.forEach(controller.addUserScript)
        if chrome { controller.addUserScript(chromeScript) }
    }
}
