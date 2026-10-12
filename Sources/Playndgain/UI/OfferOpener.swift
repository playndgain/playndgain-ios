import UIKit
import WebKit

/// What following a click found. The ids and URLs are for the caller to act
/// on only: past the wall's own host they belong to a partner, so they are
/// never emitted to the delegate, logged or shown.
enum OfferOutcome: Equatable {
    /// An App Store product page: show the store sheet for `id`.
    case store(id: String, url: URL)
    /// Any other app scheme (a deep link): hand it to the system.
    case app(URL)
    /// A web page finished loading and stayed: reveal the web view.
    case landing
    /// No store in time: reveal the web view with whatever it holds.
    case timeout
    /// Nothing usable loaded: the wall's error path.
    case failed
}

/// The decisions behind `OfferOpener`, without a web view, so the tests can
/// drive every navigation. It only ever allows or cancels what the page asks
/// for; it has no way to start a load, which is what keeps `/click` to one
/// request.
struct OfferResolution {
    enum Phase: Equatable {
        /// Following the chain, web view not yet visible.
        case resolving
        /// Landing or timeout: the user sees the web view and browses.
        case revealed
        /// Resolved to the store, an app, a failure, or cancelled.
        case done
    }

    enum Step: Equatable {
        case allow
        case cancel
        /// Cancel, and this is the one resolution of the click.
        case resolve(OfferOutcome)
        /// Cancel: a store or app link tapped in the revealed page.
        case intercept(OfferOutcome)
    }

    enum Kind: Equatable {
        case web, quiet, blocked, store(id: String, url: URL), app(URL)
    }

    private(set) var phase = Phase.resolving
    private(set) var committed = false
    /// Main-frame web navigations so far. A settle wait carries the count it
    /// started at, and any later navigation makes it stale.
    private var navigations = 0
    /// Resolved to `.app` and waiting to hear whether the system opened it.
    private var awaitingApp = false

    static func classify(_ url: URL) -> Kind {
        guard let scheme = url.scheme?.lowercased() else { return .quiet }
        if let id = StoreLink.appStoreID(url) { return .store(id: id, url: url) }
        switch scheme {
        case "https", "http": return .web
        // Frames and scripts use these without leaving the page.
        case "about", "data", "blob", "javascript": return .quiet
        case "file": return .blocked
        default: return .app(url)
        }
    }

    mutating func navigate(to url: URL, mainFrame: Bool) -> Step {
        guard phase != .done else { return .cancel }
        switch Self.classify(url) {
        case .quiet:
            return .allow
        case .blocked:
            return .cancel
        case .web:
            if mainFrame { navigations += 1 }
            return .allow
        case .store(let id, let url):
            return conclude(.store(id: id, url: url))
        case .app(let url):
            // A frame probing for installed apps is not the offer.
            return mainFrame ? conclude(.app(url)) : .cancel
        }
    }

    /// The main frame showed its first content.
    mutating func didCommit() { committed = true }

    /// The main frame finished loading. Returns the ticket to pass to
    /// `settled(_:)` after a short wait, or nil when nothing is pending.
    func didFinish() -> Int? {
        phase == .resolving ? navigations : nil
    }

    /// The wait after a finished page ran out. Still on that page: it is the
    /// landing. A redirect since then made the ticket stale.
    mutating func settled(_ ticket: Int) -> OfferOutcome? {
        guard phase == .resolving, ticket == navigations else { return nil }
        phase = .revealed
        return .landing
    }

    /// A main-frame load error that is not our own cancellation. Failed even
    /// after an earlier page: the web view would otherwise show an error for
    /// a partner's address. Once revealed, the page is the user's.
    mutating func didFail() -> OfferOutcome? {
        guard phase == .resolving else { return nil }
        phase = .done
        return .failed
    }

    mutating func timedOut() -> OfferOutcome? {
        guard phase == .resolving else { return nil }
        phase = .revealed
        return .timeout
    }

    /// The system could not open the app link the click resolved to: show
    /// what has loaded, if anything did. Nil when the link was tapped in an
    /// already revealed page, which simply stays.
    mutating func appUnopened() -> OfferOutcome? {
        guard phase == .done, awaitingApp else { return nil }
        awaitingApp = false
        phase = committed ? .revealed : .done
        return committed ? .landing : .failed
    }

    mutating func cancel() {
        phase = .done
        awaitingApp = false
    }

    private mutating func conclude(_ outcome: OfferOutcome) -> Step {
        if phase == .revealed { return .intercept(outcome) }
        phase = .done
        if case .app = outcome { awaitingApp = true }
        return .resolve(outcome)
    }
}

/// Follows one offer click inside the app. Loads the allowed click URL once in
/// a web view that is not shown, watches every navigation, and reports where
/// it ended: the store, another app, a web landing, a timeout or a failure.
/// The caller shows `webView` itself for a landing or timeout, never a fresh
/// browser: that would request the click chain again in another cookie jar.
/// The caller adds `webView` to its window, hidden, before `start`: an
/// offscreen web view slows the script timers trackers redirect with.
///
/// Main thread only. The caller keeps the opener alive while it is in use.
final class OfferOpener: NSObject, WKNavigationDelegate, WKUIDelegate {
    let webView: WKWebView
    var phase: OfferResolution.Phase { resolution.phase }

    private var resolution = OfferResolution()
    private let timeout: TimeInterval
    private let settle: TimeInterval
    private let onResolve: (OfferOutcome) -> Void
    private let onIntercept: (OfferOutcome) -> Void
    private var clickURL: URL?
    private var timer: DispatchWorkItem?

    /// `onResolve` is called once per click, unless the opener is cancelled
    /// first; after `.app` it may be called once more, from `appUnopened()`. `onIntercept` is called for each store or app link
    /// the user follows from a revealed page.
    init(timeout: TimeInterval = 8, settle: TimeInterval = 1.5,
         onResolve: @escaping (OfferOutcome) -> Void,
         onIntercept: @escaping (OfferOutcome) -> Void) {
        let cfg = WKWebViewConfiguration()
        // The shared store, so a revealed page keeps the cookies the chain set.
        cfg.websiteDataStore = .default()
        webView = WKWebView(frame: .zero, configuration: cfg)
        self.timeout = timeout
        self.settle = settle
        self.onResolve = onResolve
        self.onIntercept = onIntercept
        super.init()
        webView.navigationDelegate = self
        webView.uiDelegate = self
    }

    /// The one load of the click. Returns false, and loads nothing, for a
    /// second call or a URL that is not the wall's own click route.
    @discardableResult
    func start(_ url: URL, base: URL) -> Bool {
        guard clickURL == nil, resolution.phase == .resolving, Links.isAllowedClick(url, base: base) else { return false }
        clickURL = url
        let work = DispatchWorkItem { [weak self] in
            guard let self = self, let o = self.resolution.timedOut() else { return }
            self.onResolve(o)
        }
        timer = work
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout, execute: work)
        webView.load(URLRequest(url: url))
        return true
    }

    /// The system refused the app link from `.app`: fall back to the page,
    /// reported through `onResolve` as `.landing`, or `.failed` if none loaded.
    func appUnopened() {
        guard clickURL != nil, let o = resolution.appUnopened() else { return }
        onResolve(o)
    }

    /// Stops everything. Nothing is reported after this.
    func cancel() {
        timer?.cancel()
        resolution.cancel()
        webView.stopLoading()
    }

    private func resolved(_ o: OfferOutcome) {
        timer?.cancel()
        // Store, app and failure end the chain here; the page is never shown.
        if resolution.phase == .done { webView.stopLoading() }
        onResolve(o)
    }


    // MARK: WKNavigationDelegate

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = action.request.url else { return decisionHandler(.cancel) }
        let step = resolution.navigate(to: url, mainFrame: action.targetFrame?.isMainFrame ?? true)
        // Answer WebKit first: the callback may present UI or cancel us.
        decisionHandler(step == .allow ? .allow : .cancel)
        switch step {
        case .allow, .cancel: break
        case .resolve(let o): resolved(o)
        case .intercept(let o): onIntercept(o)
        }
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        resolution.didCommit()
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard let ticket = resolution.didFinish() else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + settle) { [weak self] in
            guard let self = self, let o = self.resolution.settled(ticket) else { return }
            self.resolved(o)
        }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        failed(error)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        failed(error)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        if let o = resolution.didFail() { resolved(o) }
    }

    private func failed(_ error: Error) {
        guard !Self.isOwnCancellation(error), let o = resolution.didFail() else { return }
        resolved(o)
    }

    /// Our own `.cancel` comes back as an error; so does a superseded load.
    static func isOwnCancellation(_ error: Error) -> Bool {
        let e = error as NSError
        if e.domain == NSURLErrorDomain { return e.code == NSURLErrorCancelled }
        // 102: frame load interrupted by a policy change. 204: handed to a plug-in.
        return e.domain == "WebKitErrorDomain" && (e.code == 102 || e.code == 204)
    }

    // MARK: WKUIDelegate

    /// `target=_blank` and `window.open` stay in this one web view. The click
    /// URL itself is never loaded a second time.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if action.targetFrame == nil, let url = action.request.url, url.absoluteString != clickURL?.absoluteString, resolution.phase != .done {
            webView.load(action.request)
        }
        return nil
    }
}
