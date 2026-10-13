import StoreKit
import UIKit
import WebKit

/// How one click ended, for the wall's reward check.
enum OfferFlowEnd {
    /// The player closed the in-app store or browser sheet: check now.
    case returned
    /// The click left the app: the check waits for the foreground.
    case leftApp
    /// Nothing loaded: the wall stays and says the offer could not be opened.
    case failed
}

/// One offer click inside the app: a loading cover while `OfferOpener`
/// follows the click, then the App Store sheet, another app, or the opener's
/// own web view as a browser sheet. Never a second browser: Safari would
/// request the click chain again in another cookie jar.
final class OfferFlow: NSObject, SKStoreProductViewControllerDelegate, UIAdaptivePresentationControllerDelegate {
    private weak var host: UIViewController?
    private let palette: Palette
    private let closeLabel: String
    private let leaving: (Bool) -> Void
    private let ended: (OfferFlowEnd) -> Void
    private var opener: OfferOpener?
    private var sheet: OfferSheet?
    private var finished = false
    /// The store sheet on screen is the click's own outcome, not a tap
    /// inside a revealed page, so closing it ends the click.
    private var storeEndsClick = false
    /// The store sheet while its product loads. Held here: nothing else keeps
    /// it alive until it is presented, and a released sheet reads as a failed
    /// load, which sent every store click outside the app.
    private(set) var pendingStore: SKStoreProductViewController?

    /// `leaving(true)` comes just before the click leaves the app, and
    /// `leaving(false)` if the system then refuses to open it. `ended` is
    /// called once.
    init(host: UIViewController, palette: Palette, closeLabel: String,
         leaving: @escaping (Bool) -> Void, ended: @escaping (OfferFlowEnd) -> Void) {
        self.host = host
        self.palette = palette
        self.closeLabel = closeLabel
        self.leaving = leaving
        self.ended = ended
    }

    func start(_ url: URL, base: URL) -> Bool {
        guard let host = host, opener == nil else { return false }
        let opener = OfferOpener(
            onResolve: { [weak self] in self?.resolved($0) },
            onIntercept: { [weak self] in self?.intercepted($0) }
        )
        opener.onGone = { [weak self] in self?.finish(.returned) }
        let sheet = OfferSheet(webView: opener.webView, palette: palette, closeLabel: closeLabel) { [weak self] in
            self?.finish(.returned)
        }
        sheet.translatesAutoresizingMaskIntoConstraints = false
        // No keyboard from the wall's search field over the page.
        host.view.endEditing(true)
        host.view.addSubview(sheet)
        NSLayoutConstraint.activate([
            sheet.topAnchor.constraint(equalTo: host.view.topAnchor),
            sheet.bottomAnchor.constraint(equalTo: host.view.bottomAnchor),
            sheet.leadingAnchor.constraint(equalTo: host.view.leadingAnchor),
            sheet.trailingAnchor.constraint(equalTo: host.view.trailingAnchor),
        ])
        self.opener = opener
        self.sheet = sheet
        guard opener.start(url, base: base) else {
            opener.cancel()
            sheet.removeFromSuperview()
            return false
        }
        return true
    }

    private func resolved(_ o: OfferOutcome) {
        switch o {
        case .store(let id, let url): storeEndsClick = true; showStore(id, url)
        case .app(let url): openApp(url)
        case .landing, .timeout: sheet?.reveal()
        case .failed: finish(.failed)
        }
    }

    /// A store or app link tapped in the revealed page. The page stays under it.
    private func intercepted(_ o: OfferOutcome) {
        switch o {
        case .store(let id, let url): storeEndsClick = false; showStore(id, url)
        case .app(let url): UIApplication.shared.open(url, options: [:], completionHandler: nil)
        default: break
        }
    }

    private func openApp(_ url: URL) {
        leaving(true)
        UIApplication.shared.open(url, options: [:]) { [weak self] ok in
            guard let self = self else { return }
            if ok { self.finish(.leftApp) } else { self.leaving(false); self.opener?.appUnopened() }
        }
    }

    // MARK: Store

    func showStore(_ id: String, _ url: URL) {
        let store = SKStoreProductViewController()
        store.delegate = self
        pendingStore = store
        store.loadProduct(withParameters: [SKStoreProductParameterITunesItemIdentifier: id]) { [weak self, weak store] ok, _ in
            DispatchQueue.main.async {
                // Only the newest sheet counts: a second store tap replaces the first.
                guard let self = self, !self.finished, let store = store, self.pendingStore === store else { return }
                self.pendingStore = nil
                if ok, let host = self.host {
                    // Over whatever is on top: the browser sheet lives inside the wall's view.
                    host.present(store, animated: true)
                    // A swipe down closes the sheet without Done.
                    store.presentationController?.delegate = self
                } else {
                    self.openStoreOutside(StoreLink.fallbackURLs(url, id: id))
                }
            }
        }
    }

    /// No product sheet (the simulator has no App Store): the store app,
    /// outside. The link as the chain gave it first, then the plain App
    /// Store page for the same id, which opens wherever `itms-apps` cannot.
    private func openStoreOutside(_ urls: [URL]) {
        guard let url = urls.first else {
            if storeEndsClick { leaving(false); finish(.failed) }
            return
        }
        if storeEndsClick { leaving(true) }
        UIApplication.shared.open(url, options: [:]) { [weak self] ok in
            guard let self = self else { return }
            if !ok { self.openStoreOutside(Array(urls.dropFirst())) } else if self.storeEndsClick { self.finish(.leftApp) }
        }
    }

    func productViewControllerDidFinish(_ store: SKStoreProductViewController) {
        store.presentingViewController?.dismiss(animated: true)
        storeClosed()
    }

    func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
        storeClosed()
    }

    private func storeClosed() {
        if storeEndsClick { finish(.returned) }
    }

    // MARK: End

    private func finish(_ end: OfferFlowEnd) {
        guard !finished else { return }
        finished = true
        pendingStore = nil
        opener?.cancel()
        sheet?.dismiss()
        ended(end)
    }
}

/// The loading cover and the in-app browser sheet for one click, as one view
/// over the wall. While the click resolves, the web view sits in the sheet at
/// almost zero opacity under the cover. It stays in the window and is not
/// hidden, so WebKit keeps running the page's timers the redirects use.
final class OfferSheet: UIView {
    private let panel = UIView()
    private let cover = UIView()
    private let webView: WKWebView
    private let palette: Palette

    init(webView: WKWebView, palette: Palette, closeLabel: String, onClose: @escaping () -> Void) {
        self.webView = webView
        self.palette = palette
        super.init(frame: .zero)
        let p = palette
        // The same scrim the Android SDK puts behind its sheets.
        backgroundColor = UIColor.black.withAlphaComponent(0.55)
        semanticContentAttribute = Fonts.rtl ? .forceRightToLeft : .forceLeftToRight
        // VoiceOver stays on the cover or the sheet, not the wall behind.
        accessibilityViewIsModal = true

        _ = panel.rounded(p.card, p.radius * 1.8)
        panel.layer.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        panel.clipsToBounds = true
        panel.alpha = 0.01
        panel.isUserInteractionEnabled = false
        panel.accessibilityElementsHidden = true

        let close = UIButton(type: .custom)
        close.setTitle(closeLabel, for: .normal)
        close.titleLabel?.font = Fonts.font(15, 600)
        close.setTitleColor(p.text, for: .normal)
        close.contentEdgeInsets = UIEdgeInsets(top: 0, left: 20, bottom: 0, right: 20)
        close.accessibilityIdentifier = "playndgain.offer.close"
        close.addAction(for: .touchUpInside, onClose)
        let header = UIStackView(arrangedSubviews: [UIView(), close])
        header.semanticContentAttribute = semanticContentAttribute
        header.heightAnchor.constraint(equalToConstant: 52).isActive = true
        let rule = UIView()
        rule.backgroundColor = p.line
        rule.heightAnchor.constraint(equalToConstant: 1).isActive = true

        webView.isOpaque = false
        webView.backgroundColor = p.card
        webView.scrollView.backgroundColor = p.card
        let col = UIStackView(arrangedSubviews: [header, rule, webView])
        col.axis = .vertical
        col.translatesAutoresizingMaskIntoConstraints = false
        panel.addSubview(col)
        panel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(panel)

        // The wall's own loading spinner, on a card so it reads on the scrim.
        let spinner = UIActivityIndicatorView(style: .medium)
        spinner.color = p.muted
        spinner.startAnimating()
        spinner.translatesAutoresizingMaskIntoConstraints = false
        _ = cover.rounded(p.card, p.radius)
        cover.addSubview(spinner)
        cover.translatesAutoresizingMaskIntoConstraints = false
        addSubview(cover)

        NSLayoutConstraint.activate([
            panel.topAnchor.constraint(equalTo: safeAreaLayoutGuide.topAnchor, constant: 12),
            panel.bottomAnchor.constraint(equalTo: bottomAnchor),
            panel.leadingAnchor.constraint(equalTo: leadingAnchor),
            panel.trailingAnchor.constraint(equalTo: trailingAnchor),
            col.topAnchor.constraint(equalTo: panel.topAnchor),
            col.bottomAnchor.constraint(equalTo: panel.safeAreaLayoutGuide.bottomAnchor),
            col.leadingAnchor.constraint(equalTo: panel.leadingAnchor),
            col.trailingAnchor.constraint(equalTo: panel.trailingAnchor),
            cover.centerXAnchor.constraint(equalTo: centerXAnchor),
            cover.centerYAnchor.constraint(equalTo: centerYAnchor),
            cover.widthAnchor.constraint(equalToConstant: 64),
            cover.heightAnchor.constraint(equalToConstant: 64),
            spinner.centerXAnchor.constraint(equalTo: cover.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: cover.centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// The click landed on a web page: the sheet rises with it.
    func reveal() {
        cover.removeFromSuperview()
        panel.isUserInteractionEnabled = true
        panel.accessibilityElementsHidden = false
        webView.allowsBackForwardNavigationGestures = true
        guard Motion.enabled else { panel.alpha = 1; return }
        layoutIfNeeded()
        panel.transform = CGAffineTransform(translationX: 0, y: bounds.height)
        panel.alpha = 1
        UIView.animate(withDuration: Motion.base, delay: 0, options: [], animations: {
            CATransaction.setAnimationTimingFunction(Motion.easeOut)
            self.panel.transform = .identity
        })
    }

    func dismiss() {
        let done = { [weak self] in
            self?.webView.removeFromSuperview()
            self?.removeFromSuperview()
        }
        guard Motion.enabled else { return done() }
        UIView.animate(withDuration: Motion.exit, animations: { self.alpha = 0 }, completion: { _ in done() })
    }
}
