import WebKit

/// 팝업 가짜 창 (2026-11-12, 사용자): 클릭이 아닌 window.open 은 열지 않되, 페이지에는 열린 것처럼 보이는 빈 창 객체를 돌려준다.
/// null 을 받으면 "팝업이 차단됨" 안내를 띄우거나 페이지째 다른 곳으로 보내는 사이트가 있어서.
/// 링크(target=_blank)·사용자가 누른 window.open 은 WebBrowser 의 createWebViewWith 가 지금처럼 같은 화면에서 연다.
/// 스크립트는 바뀔 수 없으므로, 본 페이지로 이동할 때마다 그 사이트에 맞게 (넣거나 빼서) 다시 단다.
enum PopupGuard {
    /// 우리 스크립트인지 알아보는 표시 (맨 앞 주석)
    private static let marker = "/* irayer-popup-guard */"

    private static let script = WKUserScript(source: marker + """
    (function () {
      if (window.__irayerPopupGuard) return;
      window.__irayerPopupGuard = true;
      var realOpen = window.open;
      function noop() {}
      function fakeWindow(url) {
        var loc = { href: 'about:blank', assign: noop, replace: noop, reload: noop, toString: function () { return 'about:blank'; } };
        var doc = { write: noop, writeln: noop, close: noop, title: '', body: null, head: null,
                    open: function () { return doc; },
                    createElement: function (t) { return document.createElement(t); },
                    getElementById: function () { return null; },
                    querySelector: function () { return null; } };
        var w = { closed: false, opener: window, name: '', document: doc, length: 0, frames: [],
                  focus: noop, blur: noop, postMessage: noop, addEventListener: noop, removeEventListener: noop,
                  moveTo: noop, moveBy: noop, resizeTo: noop, resizeBy: noop, scrollTo: noop, print: noop, stop: noop,
                  screenX: 0, screenY: 0, innerWidth: 800, innerHeight: 600, outerWidth: 800, outerHeight: 600,
                  close: function () { w.closed = true; } };
        Object.defineProperty(w, 'location', { get: function () { return loc; }, set: noop });
        w.window = w; w.self = w; w.top = w; w.parent = w;
        return w;
      }
      var open = function (url, target) {
        // 같은 창으로 여는 것은 팝업이 아니다
        if (target === '_self' || target === '_top' || target === '_parent') return realOpen.apply(this, arguments);
        return fakeWindow(url);
      };
      open.toString = function () { return 'function open() {\\n    [native code]\\n}'; };
      window.open = open;
    })();
    """, injectionTime: .atDocumentStart, forMainFrameOnly: false)

    /// 본 페이지를 그 주소로 옮기기 직전에: 설정·예외에 따라 스크립트를 넣거나 뺀다 (다른 스크립트 — 재생하며 받기 등 — 는 그대로)
    static func update(_ controller: WKUserContentController, for url: URL?) {
        let wanted = AdBlock.shared.fakePopups && !AdBlock.shared.isException(url)
        let installed = controller.userScripts.contains { $0.source.hasPrefix(marker) }
        guard wanted != installed else { return }
        let others = controller.userScripts.filter { !$0.source.hasPrefix(marker) }
        controller.removeAllUserScripts()
        others.forEach(controller.addUserScript)
        if wanted { controller.addUserScript(script) }
    }
}
