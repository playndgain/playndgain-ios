import UIKit

/// The whole offerwall on iOS: Offers and History, a detail sheet, and the
/// consent, notice and offline screens. Built in code so the SDK ships no
/// storyboard or nib a host app could collide with.
final class WallViewController: UIViewController, UITableViewDataSource, UITableViewDelegate, UISearchBarDelegate {
    private enum Section { case offers, history }
    private enum Row { case offer(OfferCard), rail([OfferCard]), empty(String, String) }

    private let options: PlayndgainOptions
    private let api: ApiClient
    private var palette = Palette.fallback
    private var strings = Strings(root: nil)
    private var last: WallResponse?
    private var section = Section.offers
    private var sort: String?
    private var category: String?
    private var query = ""
    private var rows: [Row] = []
    private var opened = false
    private var closed = false
    private var pendingRewardCheck = false
    private var animatedUpTo = 0
    /// Every load takes a ticket; an answer whose ticket is not the newest is
    /// dropped, so a slow wall answer never lands in History and an older
    /// sort never overwrites a newer one.
    private var gate = LoadTickets()
    private var openingDetail = false
    private var offerFlow: OfferFlow?

    private let stack = UIStackView()
    private let table = UITableView(frame: .zero, style: .plain)

    init(options: PlayndgainOptions) {
        self.options = options
        self.api = ApiClient(options: options)
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = palette.bg
        stack.axis = .vertical
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        table.dataSource = self
        table.delegate = self
        table.separatorStyle = .none
        table.backgroundColor = .clear
        table.contentInset = UIEdgeInsets(top: 8, left: 0, bottom: 32, right: 0)
        table.register(UITableViewCell.self, forCellReuseIdentifier: "c")
        NotificationCenter.default.addObserver(self, selector: #selector(didBecomeActive), name: UIApplication.didBecomeActiveNotification, object: nil)
        showLoading()
        load()
    }

    override var preferredStatusBarStyle: UIStatusBarStyle { palette.dark ? .lightContent : .darkContent }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if isBeingDismissed || presentingViewController == nil { emitClosedOnce() }
    }

    @objc private func didBecomeActive() {
        guard pendingRewardCheck else { return }
        pendingRewardCheck = false
        rewardCheck()
    }

    private func rewardCheck() {
        Playndgain.delegate?.playndgainRewardCheck()
        load()
    }

    private func emitClosedOnce() {
        guard !closed else { return }
        closed = true
        Playndgain.delegate?.playndgainDidClose()
    }

    private var systemDark: Bool { traitCollection.userInterfaceStyle == .dark }

    // MARK: Loading

    private func load() {
        let ticket = gate.next()
        let done: (Result<WallResponse, PlayndgainError>) -> Void = { [weak self] r in self?.handle(r, ticket: ticket) }
        if section == .offers { api.wall(sort: sort, systemDark: systemDark, done) } else { api.history(systemDark: systemDark, done) }
    }

    private func handle(_ result: Result<WallResponse, PlayndgainError>, ticket: Int) {
        guard gate.isCurrent(ticket) else { return }
        switch result {
        case .failure(let e):
            Playndgain.emit(e)
            e == .network ? showOffline() : showNotice(nil, retry: true)
        case .success(let r):
            if let e = r.error { Playndgain.emit(e) }
            render(r)
        }
    }

    private func render(_ r: WallResponse) {
        // Every screen below needs the app's theme and header. An envelope
        // without it has nothing to draw: report it, and offer retry and close.
        if r.app == nil, ["ok", "unplaced", "consent_required"].contains(r.status) {
            strings = r.strings
            Playndgain.emit(.wallUnavailable)
            showNotice(nil, retry: true)
            return
        }
        last = r
        strings = r.strings
        if let app = r.app {
            palette = Palette(app.theme)
            Fonts.rtl = app.rtl
            view.semanticContentAttribute = app.rtl ? .forceRightToLeft : .forceLeftToRight
            view.backgroundColor = palette.bg
            setNeedsStatusBarAppearanceUpdate()
        }
        switch r.status {
        case "ok", "unplaced":
            if !opened { opened = true; Playndgain.delegate?.playndgainDidOpen() }
            buildChrome(r)
            if section == .offers { buildOffers(r) } else { buildHistory(r.history) }
        case "consent_required": showConsent()
        default: showNotice(r)
        }
    }

    // MARK: Chrome

    private func buildChrome(_ r: WallResponse) {
        guard let app = r.app else { return }
        clear()
        let p = palette
        let name = options.title ?? app.name

        let bar = UIStackView()
        bar.axis = .horizontal
        bar.alignment = .center
        bar.spacing = 10
        bar.isLayoutMarginsRelativeArrangement = true
        bar.layoutMargins = UIEdgeInsets(top: 12, left: 16, bottom: 10, right: 12)
        bar.semanticContentAttribute = view.semanticContentAttribute

        let mark = UILabel(String(name.prefix(1)).uppercased(), 16, 700, p.primary)
        mark.textAlignment = .center
        _ = mark.rounded(p.tile, p.radius * 0.6)
        mark.clipsToBounds = true
        mark.widthAnchor.constraint(equalToConstant: 36).isActive = true
        mark.heightAnchor.constraint(equalToConstant: 36).isActive = true
        mark.isAccessibilityElement = false
        bar.addArrangedSubview(mark)

        let titles = UIStackView(arrangedSubviews: [UILabel(name, 15, 600, p.text), UILabel(strings["earn"], 12, 400, p.muted)])
        titles.axis = .vertical
        titles.spacing = 3
        bar.addArrangedSubview(titles)
        titles.setContentHuggingPriority(.defaultLow, for: .horizontal)

        if let bal = options.balance ?? app.balance {
            let pill = PaddedLabel(bal, 13, 600, p.onPrimary)
            _ = pill.rounded(p.primary, 14)
            pill.clipsToBounds = true
            bar.addArrangedSubview(pill)
        }

        let close = UIButton(type: .system)
        close.setTitle("✕", for: .normal)
        close.titleLabel?.font = Fonts.font(16, 600)
        close.tintColor = p.muted
        close.accessibilityLabel = strings.or("offer.close", "Close")
        _ = close.rounded(p.raise, 22)
        close.widthAnchor.constraint(equalToConstant: 44).isActive = true
        close.heightAnchor.constraint(equalToConstant: 44).isActive = true
        close.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)
        bar.addArrangedSubview(close)
        stack.addArrangedSubview(bar)

        let tabs = UIStackView()
        tabs.axis = .horizontal
        tabs.spacing = 6
        tabs.isLayoutMarginsRelativeArrangement = true
        tabs.layoutMargins = UIEdgeInsets(top: 4, left: 16, bottom: 8, right: 16)
        tabs.semanticContentAttribute = view.semanticContentAttribute
        for (t, label) in [(Section.offers, strings.or("tabs.offers", "Offers")), (Section.history, strings.or("tabs.history", "History"))] {
            let on = t == section
            let b = UIButton(type: .custom)
            b.setTitle(label, for: .normal)
            b.titleLabel?.font = Fonts.font(14, on ? 600 : 400)
            b.setTitleColor(on ? p.text : p.muted, for: .normal)
            b.contentEdgeInsets = UIEdgeInsets(top: 0, left: 16, bottom: 0, right: 16)
            b.heightAnchor.constraint(equalToConstant: 40).isActive = true
            if on { _ = b.rounded(p.primarySoft, 20) }
            b.accessibilityTraits = on ? [.button, .selected] : .button
            b.addAction(for: .touchUpInside) { [weak self] in if !on { self?.switchTab(t) } }
            tabs.addArrangedSubview(b)
        }
        tabs.addArrangedSubview(UIView())
        stack.addArrangedSubview(tabs)

        let rule = UIView()
        rule.backgroundColor = p.line
        rule.heightAnchor.constraint(equalToConstant: 1).isActive = true
        stack.addArrangedSubview(rule)
    }

    @objc private func closeTapped() {
        emitClosedOnce()
        dismiss(animated: true)
    }

    private func switchTab(_ t: Section) {
        section = t
        if let r = last { buildChrome(r) }
        let spinner = UIActivityIndicatorView(style: .medium)
        spinner.color = palette.muted
        spinner.startAnimating()
        stack.addArrangedSubview(spinner)
        load()
    }

    // MARK: Offers

    private func buildOffers(_ r: WallResponse) {
        let p = palette
        let search = UISearchBar()
        search.searchBarStyle = .minimal
        search.placeholder = strings.or("search_placeholder", "Search...")
        search.text = query
        search.delegate = self
        search.searchTextField.font = Fonts.font(14, 400)
        search.searchTextField.textColor = p.text
        search.searchTextField.backgroundColor = p.card
        search.semanticContentAttribute = view.semanticContentAttribute
        let searchWrap = UIStackView(arrangedSubviews: [search])
        searchWrap.isLayoutMarginsRelativeArrangement = true
        searchWrap.layoutMargins = UIEdgeInsets(top: 8, left: 8, bottom: 2, right: 8)
        stack.addArrangedSubview(searchWrap)

        if !r.categories.isEmpty {
            var chips: [(String, Bool, () -> Void)] = [(strings.or("all", "All"), category == nil, { [weak self] in self?.pickCategory(nil) })]
            for c in r.categories {
                chips.append((c.prefix(1).uppercased() + c.dropFirst(), category == c, { [weak self] in self?.pickCategory(c) }))
            }
            stack.addArrangedSubview(chipRow(chips, ink: true))
        }

        let sorts: [(String?, String)] = [(nil, strings.or("sort.featured", "Featured")), ("reward", strings.or("sort.reward", "Top reward")), ("trending", strings.or("sort.trending", "Trending"))]
        let sortRow = chipRow(sorts.map { key, label in
            (label, self.sort == key, { [weak self] in
                guard let self = self, self.sort != key else { return }
                self.sort = key
                self.load()
            })
        }, ink: false)
        sortRow.accessibilityLabel = strings.or("sort.label", "Sort offers")
        stack.addArrangedSubview(sortRow)

        stack.addArrangedSubview(table)
        refilter()
    }

    private func chipRow(_ chips: [(String, Bool, () -> Void)], ink: Bool) -> UIView {
        let p = palette
        let scroll = UIScrollView()
        scroll.showsHorizontalScrollIndicator = false
        let row = UIStackView()
        row.axis = .horizontal
        row.spacing = 8
        row.translatesAutoresizingMaskIntoConstraints = false
        row.semanticContentAttribute = view.semanticContentAttribute
        scroll.addSubview(row)
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: 6),
            row.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -6),
            row.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor, constant: 16),
            row.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: -16),
            row.heightAnchor.constraint(equalTo: scroll.frameLayoutGuide.heightAnchor, constant: -12),
            scroll.heightAnchor.constraint(equalToConstant: ink ? 48 : 42),
        ])
        for (label, on, action) in chips {
            let b = UIButton(type: .custom)
            b.setTitle(label, for: .normal)
            b.titleLabel?.font = Fonts.font(ink ? 13 : 12, on ? 600 : 400)
            b.contentEdgeInsets = UIEdgeInsets(top: 0, left: ink ? 14 : 10, bottom: 0, right: ink ? 14 : 10)
            if ink {
                b.setTitleColor(on ? p.onInk : p.muted, for: .normal)
                _ = on ? b.rounded(p.ink, 18) : b.rounded(p.card, 18, border: p.line)
            } else {
                b.setTitleColor(on ? p.text : p.muted, for: .normal)
                if on { _ = b.rounded(p.tile, 15) }
            }
            b.addAction(for: .touchUpInside, action)
            row.addArrangedSubview(b)
        }
        mirrorForRTL(scroll, row)
        return scroll
    }

    /// The selected chip has to redraw, so the offers screen is rebuilt from
    /// the response already in hand. No refetch.
    private func pickCategory(_ c: String?) {
        guard let r = last else { return }
        category = c
        buildChrome(r)
        buildOffers(r)
    }

    private func refilter() {
        guard let r = last else { return }
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        let visible = r.offers.filter { o in
            (category == nil || o.categories.contains(category!)) &&
                (q.isEmpty || o.name.lowercased().contains(q) || o.instructions.lowercased().contains(q))
        }
        let test = visible.filter(\.test)
        let rest = visible.filter { !$0.test }
        let featured = rest.filter(\.featured)
        let rail = featured.count >= 2 && category == nil && q.isEmpty
        rows = test.map(Row.offer)
        if rail { rows.append(.rail(featured)) }
        rows += (rail ? rest.filter { !$0.featured } : rest).map(Row.offer)
        if rows.isEmpty {
            let filtered = !q.isEmpty || category != nil
            rows = [filtered ? .empty(strings.or("no_results.title", "No offers match that"), strings["no_results.body"])
                    : r.status == "unplaced" ? .empty(strings["unplaced.title"], strings["unplaced.body"])
                    : .empty(strings["empty.title"], strings["empty.body"])]
        }
        animatedUpTo = 0
        table.reloadData()
    }

    func searchBar(_ searchBar: UISearchBar, textDidChange searchText: String) {
        query = searchText
        refilter()
    }

    func numberOfSections(in tableView: UITableView) -> Int { 1 }
    func tableView(_ tableView: UITableView, numberOfRowsInSection _: Int) -> Int { self.section == .offers ? rows.count : historyRows.count }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "c", for: indexPath)
        cell.backgroundColor = .clear
        cell.selectionStyle = .none
        cell.contentView.subviews.forEach { $0.removeFromSuperview() }
        cell.contentView.semanticContentAttribute = view.semanticContentAttribute

        let content: UIView
        var insets = UIEdgeInsets(top: 4, left: 16, bottom: 4, right: 16)
        if section == .history {
            content = historyCell(historyRows[indexPath.row])
            insets = .zero
        } else {
            switch rows[indexPath.row] {
            case .offer(let o): content = offerCard(o)
            case .rail(let offers): content = rail(offers); insets = UIEdgeInsets(top: 4, left: 0, bottom: 8, right: 0)
            case .empty(let t, let b): content = emptyView(t, b)
            }
        }
        content.translatesAutoresizingMaskIntoConstraints = false
        cell.contentView.addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: cell.contentView.topAnchor, constant: insets.top),
            content.bottomAnchor.constraint(equalTo: cell.contentView.bottomAnchor, constant: -insets.bottom),
            content.leadingAnchor.constraint(equalTo: cell.contentView.leadingAnchor, constant: insets.left),
            content.trailingAnchor.constraint(equalTo: cell.contentView.trailingAnchor, constant: -insets.right),
        ])
        if indexPath.row >= animatedUpTo {
            content.fadeRise(index: indexPath.row)
            animatedUpTo = indexPath.row + 1
        }
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        guard section == .offers, case .offer(let o) = rows[indexPath.row] else { return }
        openDetail(o.id)
    }

    private func offerCard(_ o: OfferCard) -> UIView {
        let p = palette
        let card = UIStackView()
        card.axis = .horizontal
        card.alignment = .center
        card.spacing = 12
        card.isLayoutMarginsRelativeArrangement = true
        card.layoutMargins = UIEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        card.semanticContentAttribute = view.semanticContentAttribute
        let bg = UIView().rounded(p.card, p.radius, border: p.line)
        card.insertSubview(bg, at: 0)
        bg.frame = card.bounds
        bg.autoresizingMask = [.flexibleWidth, .flexibleHeight]

        card.addArrangedSubview(iconTile(o.name, o.iconURL, 48))

        let text = UIStackView()
        text.axis = .vertical
        text.spacing = 4
        text.addArrangedSubview(UILabel(o.name, 15, 600, p.text))
        if !o.instructions.isEmpty { text.addArrangedSubview(UILabel(o.instructions, 12.5, 400, p.muted, lines: 2)) }
        let meta = [o.test ? strings.or("test_badge", "Test offer") : nil,
                    !o.test && o.featured ? strings["featured"] : nil,
                    o.stepsLabel ?? (o.multiReward ? strings["multi_reward"] : nil),
                    o.peopleLabel].compactMap { $0 }.filter { !$0.isEmpty }
        if !meta.isEmpty { text.addArrangedSubview(UILabel(meta.joined(separator: "  ·  "), 11.5, 400, p.faint)) }
        text.setContentHuggingPriority(.defaultLow, for: .horizontal)
        text.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        card.addArrangedSubview(text)

        card.addArrangedSubview(rewardStack(o.rewardLabel, upTo: o.multiReward))

        let go = UIButton(type: .custom)
        go.setTitle(Fonts.rtl ? "‹" : "›", for: .normal)
        go.titleLabel?.font = Fonts.font(18, 700)
        go.setTitleColor(p.onInk, for: .normal)
        _ = go.rounded(p.ink, 16)
        go.widthAnchor.constraint(equalToConstant: 32).isActive = true
        go.heightAnchor.constraint(equalToConstant: 32).isActive = true
        go.isAccessibilityElement = false
        go.addAction(for: .touchUpInside) { [weak self] in self?.startOffer(o.clickURL) }
        card.addArrangedSubview(go)

        card.isAccessibilityElement = true
        card.accessibilityLabel = "\(o.name), \(o.rewardLabel) \(last?.app?.currencyName ?? "")"
        card.accessibilityTraits = .button
        return card
    }

    private func rewardStack(_ label: String, upTo: Bool) -> UIView {
        let p = palette
        let v = UIStackView()
        v.axis = .vertical
        v.alignment = Fonts.rtl ? .leading : .trailing
        if upTo { v.addArrangedSubview(UILabel(strings.or("up_to", "Up to"), 10.5, 400, p.faint)) }
        let fig = UILabel(label, 16, 700, p.text)
        fig.font = fig.font.withMonospacedDigits()
        v.addArrangedSubview(fig)
        let cur = last?.app?.currencyName ?? ""
        let c = UILabel(Fonts.rtl ? cur : cur.uppercased(), 10, 600, p.faint)
        if !Fonts.rtl { c.attributedText = NSAttributedString(string: cur.uppercased(), attributes: [.kern: 0.6]) }
        v.addArrangedSubview(c)
        return v
    }

    private func rail(_ offers: [OfferCard]) -> UIView {
        let p = palette
        let wrap = UIStackView()
        wrap.axis = .vertical
        wrap.spacing = 8
        let title = UILabel(strings.or("featured_offers", "Featured Offers"), 13, 600, p.muted)
        title.textAlignment = .natural
        title.semanticContentAttribute = view.semanticContentAttribute
        let tw = UIStackView(arrangedSubviews: [title])
        tw.isLayoutMarginsRelativeArrangement = true
        tw.layoutMargins = UIEdgeInsets(top: 4, left: 16, bottom: 0, right: 16)
        wrap.addArrangedSubview(tw)

        let scroll = UIScrollView()
        scroll.showsHorizontalScrollIndicator = false
        let row = UIStackView()
        row.axis = .horizontal
        row.spacing = 8
        row.alignment = .fill
        row.semanticContentAttribute = view.semanticContentAttribute
        row.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(row)
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
            row.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
            row.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor, constant: 16),
            row.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: -16),
            row.heightAnchor.constraint(equalTo: scroll.frameLayoutGuide.heightAnchor),
            scroll.heightAnchor.constraint(equalToConstant: 140),
        ])
        for o in offers {
            let card = UIStackView()
            card.axis = .vertical
            card.spacing = 4
            card.isLayoutMarginsRelativeArrangement = true
            card.layoutMargins = UIEdgeInsets(top: 14, left: 14, bottom: 14, right: 14)
            let bg = UIView().rounded(p.card, p.radius, border: p.line)
            card.insertSubview(bg, at: 0)
            bg.frame = card.bounds
            bg.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            let top = UIStackView(arrangedSubviews: [iconTile(o.name, o.iconURL, 44), UIView(), rewardStack(o.rewardLabel, upTo: o.multiReward)])
            top.alignment = .center
            top.semanticContentAttribute = view.semanticContentAttribute
            card.addArrangedSubview(top)
            card.setCustomSpacing(12, after: top)
            card.addArrangedSubview(UILabel(o.name, 15, 600, p.text))
            card.addArrangedSubview(UILabel(o.instructions, 12.5, 400, p.muted))
            // Height comes from the row's `.fill` alignment once the card is in
            // it; a constraint to the row before that has no common ancestor.
            card.widthAnchor.constraint(equalToConstant: 220).isActive = true
            card.isUserInteractionEnabled = true
            card.addGestureRecognizer(Tap { [weak self] in self?.openDetail(o.id) })
            card.isAccessibilityElement = true
            card.accessibilityLabel = "\(o.name), \(o.rewardLabel) \(last?.app?.currencyName ?? "")"
            card.accessibilityTraits = .button
            row.addArrangedSubview(card)
        }
        mirrorForRTL(scroll, row)
        wrap.addArrangedSubview(scroll)
        return wrap
    }

    private func iconTile(_ name: String, _ url: URL?, _ size: CGFloat) -> UIView {
        let p = palette
        let tile = UIView().rounded(p.tile, p.radius * 0.6)
        tile.clipsToBounds = true
        tile.widthAnchor.constraint(equalToConstant: size).isActive = true
        tile.heightAnchor.constraint(equalToConstant: size).isActive = true
        let letter = UILabel(String(name.prefix(1)).uppercased(), size * 0.4, 700, p.muted)
        letter.textAlignment = .center
        letter.frame = CGRect(x: 0, y: 0, width: size, height: size)
        tile.addSubview(letter)
        let img = UIImageView(frame: letter.frame)
        img.contentMode = .scaleAspectFill
        img.isHidden = true
        tile.addSubview(img)
        ImageLoader.load(url) { image in
            guard let image = image else { return }
            img.image = image
            img.isHidden = false
            letter.isHidden = true
        }
        return tile
    }

    private func emptyView(_ title: String, _ body: String) -> UIView {
        let p = palette
        let v = UIStackView(arrangedSubviews: [UILabel(title, 17, 600, p.text), UILabel(body, 13.5, 400, p.muted, lines: 0)])
        v.axis = .vertical
        v.spacing = 8
        v.alignment = .center
        v.isLayoutMarginsRelativeArrangement = true
        v.layoutMargins = UIEdgeInsets(top: 56, left: 32, bottom: 32, right: 32)
        (v.arrangedSubviews as? [UILabel])?.forEach { $0.textAlignment = .center }
        return v
    }

    // MARK: Detail

    private func openDetail(_ id: Int) {
        // One sheet at a time: a second tap while the first is loading or open does nothing.
        guard !openingDetail, presentedViewController == nil else { return }
        openingDetail = true
        api.offer(id, systemDark: systemDark) { [weak self] result in
            guard let self = self else { return }
            self.openingDetail = false
            guard self.presentedViewController == nil, self.viewIfLoaded?.window != nil else { return }
            let r: WallResponse
            switch result {
            case .failure(let e):
                // A tap must never look dead: the sheet says it failed.
                Playndgain.emit(e)
                r = WallResponse(status: "unavailable", http: 0, app: nil, strings: self.strings, notice: nil)
            case .success(let ok):
                r = ok
                if let e = r.error { Playndgain.emit(e) }
            }
            do {
                // Never asked (the answer was reset since the list loaded): ask
                // now, and retire any page load in flight so it cannot replace it.
                if r.status == "consent_required" { _ = self.gate.next(); self.showConsent(); return }
                let sheet = DetailViewController(response: r, palette: self.palette, strings: r.strings.root == nil ? self.strings : r.strings, currency: self.last?.app?.currencyName ?? "") { [weak self] url in
                    self?.dismiss(animated: true) { self?.startOffer(url) }
                }
                if #available(iOS 15.0, *), let s = sheet.sheetPresentationController {
                    s.detents = [.large()]
                    s.prefersGrabberVisible = true
                    s.preferredCornerRadius = self.palette.radius * 1.8
                }
                self.present(sheet, animated: true)
            }
        }
    }

    // MARK: Clicks

    /// Inside the app: `OfferFlow` follows `/click/{offer}` once, so the
    /// wall's own pre-click checks, the click row and the redirect to the
    /// advertiser all happen exactly as in the iframe, then shows the store
    /// sheet or the page it landed on.
    private func startOffer(_ url: URL?) {
        let base = Playndgain.config.baseURL
        guard offerFlow == nil, let url = url, Links.isAllowedClick(url, base: base) else {
            Playndgain.emit(.internal)
            return
        }
        let flow = OfferFlow(host: self, palette: palette, closeLabel: closeLabel,
                             leaving: { [weak self] in self?.pendingRewardCheck = $0 }) { [weak self] end in
            guard let self = self else { return }
            self.offerFlow = nil
            switch end {
            case .returned: self.rewardCheck()
            case .leftApp: break
            case .failed: Playndgain.emit(.network); self.showOffline()
            }
        }
        offerFlow = flow
        if !flow.start(url, base: base) { offerFlow = nil; Playndgain.emit(.internal) }
    }

    // MARK: History

    private var historyRows: [HistoryRow] = []

    private func buildHistory(_ rows: [HistoryRow]) {
        historyRows = rows
        if rows.isEmpty {
            stack.addArrangedSubview(emptyView(strings["history.empty.title"], strings["history.empty.body"]))
            stack.addArrangedSubview(UIView())
            return
        }
        stack.addArrangedSubview(table)
        animatedUpTo = 0
        table.reloadData()
    }

    private func historyCell(_ r: HistoryRow) -> UIView {
        let p = palette
        let row = UIStackView()
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = 12
        row.isLayoutMarginsRelativeArrangement = true
        row.layoutMargins = UIEdgeInsets(top: 12, left: 16, bottom: 12, right: 16)
        row.semanticContentAttribute = view.semanticContentAttribute
        row.addArrangedSubview(iconTile(r.name, r.iconURL, 40))
        let t = UIStackView()
        t.axis = .vertical
        t.spacing = 3
        t.addArrangedSubview(UILabel(r.name, 14.5, 600, p.text))
        // Status is a word, never a colour: the one colour here is the credited
        // amount, because it is the money.
        let meta = [r.partner, r.at.map { String($0.prefix(10)) }, r.statusLabel].compactMap { $0 }.joined(separator: "  ·  ")
        t.addArrangedSubview(UILabel(meta, 11.5, 400, p.muted))
        if let reason = r.reason { t.addArrangedSubview(UILabel(reason, 11, 400, p.faint, lines: 0)) }
        t.setContentHuggingPriority(.defaultLow, for: .horizontal)
        row.addArrangedSubview(t)
        if let reward = r.rewardLabel {
            let l = UILabel("+" + reward, 15, 700, p.primary)
            l.font = l.font.withMonospacedDigits()
            row.addArrangedSubview(l)
        }
        row.isAccessibilityElement = true
        row.accessibilityLabel = [r.name, r.statusLabel, r.rewardLabel].compactMap { $0 }.joined(separator: ", ")
        let line = UIView()
        line.backgroundColor = p.line
        line.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(line)
        NSLayoutConstraint.activate([
            line.heightAnchor.constraint(equalToConstant: 1),
            line.bottomAnchor.constraint(equalTo: row.bottomAnchor),
            line.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 16),
            line.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -16),
        ])
        return row
    }

    // MARK: Consent, notice, offline, loading

    private func showConsent() {
        clear()
        let p = palette
        let col = UIStackView()
        col.axis = .vertical
        col.spacing = 6
        col.isLayoutMarginsRelativeArrangement = true
        col.layoutMargins = UIEdgeInsets(top: 32, left: 24, bottom: 24, right: 24)
        col.addArrangedSubview(UILabel(strings["consent.title"], 22, 700, p.text, lines: 0))
        col.addArrangedSubview(UILabel(strings["consent.intro"], 14, 400, p.muted, lines: 0))
        for k in ["what", "why", "who"] {
            let label = UILabel(strings["consent.\(k)_label"], 13, 600, p.text)
            col.addArrangedSubview(label)
            col.setCustomSpacing(4, after: label)
            col.addArrangedSubview(UILabel(strings["consent.\(k)"], 13.5, 400, p.muted, lines: 0))
        }
        // Two buttons of equal weight. Decline is a real answer.
        let buttons = UIStackView()
        buttons.axis = .horizontal
        buttons.spacing = 10
        buttons.distribution = .fillEqually
        for (accept, label) in [(true, strings["consent.accept"]), (false, strings["consent.decline"])] {
            let b = UIButton(type: .custom)
            b.setTitle(label, for: .normal)
            b.titleLabel?.font = Fonts.font(15, 600)
            b.setTitleColor(p.text, for: .normal)
            _ = b.rounded(p.card, 26, border: p.line)
            b.heightAnchor.constraint(equalToConstant: 52).isActive = true
            b.addAction(for: .touchUpInside) { [weak self] in
                guard let self = self else { return }
                self.showLoading()
                let ticket = self.gate.next()
                self.api.consent(accept: accept, systemDark: self.systemDark) { [weak self] r in self?.handle(r, ticket: ticket) }
            }
            buttons.addArrangedSubview(b)
        }
        col.setCustomSpacing(28, after: col.arrangedSubviews.last!)
        col.addArrangedSubview(buttons)
        col.setCustomSpacing(12, after: buttons)
        col.addArrangedSubview(UILabel(strings["consent.note"], 12, 400, p.faint, lines: 0))
        let scroll = UIScrollView()
        col.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(col)
        NSLayoutConstraint.activate([
            col.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
            col.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
            col.leadingAnchor.constraint(equalTo: scroll.frameLayoutGuide.leadingAnchor),
            col.trailingAnchor.constraint(equalTo: scroll.frameLayoutGuide.trailingAnchor),
        ])
        stack.addArrangedSubview(scroll)
    }

    /// Bundled text for screens drawn before, or without, the server's strings.
    private var arabic: Bool { (options.language ?? Locale.preferredLanguages.first ?? "en").hasPrefix("ar") }
    private var closeLabel: String { strings.or("offer.close", arabic ? "إغلاق" : "Close") }
    private var retryLabel: String { arabic ? "حاول مرة أخرى" : "Try again" }

    /// A full-page notice. A refusal from the wall gets Close; a failure that
    /// can pass (unavailable, rate limited, a bad answer) also gets Try again.
    /// Close is always there: the wall is a full-screen modal with no other exit.
    private func showNotice(_ r: WallResponse?, retry: Bool = false) {
        let title: String, body: String
        if let n = r?.notice, !(n.title.isEmpty && n.body.isEmpty) { title = n.title; body = n.body }
        else {
            title = strings.or("notice.unavailable.title", arabic ? "العروض غير متاحة" : "Offers unavailable")
            body = strings.or("notice.unavailable.body", arabic ? "لا يمكن عرض العروض الآن. يرجى المحاولة لاحقا." : "Offers cannot be shown right now. Please try again later.")
        }
        var buttons: [(String, Bool, () -> Void)] = []
        if retry || r?.status == "rate_limited" { buttons.append((retryLabel, true, { [weak self] in self?.showLoading(); self?.load() })) }
        buttons.append((closeLabel, false, { [weak self] in self?.closeTapped() }))
        centered(title, body, buttons)
    }

    private func showOffline() {
        centered(arabic ? "أنت غير متصل" : "You are offline",
                 arabic ? "تحقق من اتصالك ثم حاول مرة أخرى." : "Check your connection and try again.",
                 [(retryLabel, true, { [weak self] in self?.showLoading(); self?.load() }),
                  (closeLabel, false, { [weak self] in self?.closeTapped() })])
    }

    private func centered(_ title: String, _ body: String, _ actions: [(String, Bool, () -> Void)]) {
        clear()
        let p = palette
        let t = UILabel(title, 19, 700, p.text, lines: 0); t.textAlignment = .center
        let b = UILabel(body, 14, 400, p.muted, lines: 0); b.textAlignment = .center
        let col = UIStackView(arrangedSubviews: [t, b])
        for (label, filled, tap) in actions {
            let btn = UIButton(type: .custom)
            btn.setTitle(label, for: .normal)
            btn.titleLabel?.font = Fonts.font(14, 600)
            btn.setTitleColor(filled ? p.onPrimary : p.text, for: .normal)
            _ = filled ? btn.rounded(p.primary, 24) : btn.rounded(p.card, 24, border: p.line)
            btn.contentEdgeInsets = UIEdgeInsets(top: 0, left: 28, bottom: 0, right: 28)
            btn.heightAnchor.constraint(equalToConstant: 48).isActive = true
            btn.addAction(for: .touchUpInside, tap)
            col.addArrangedSubview(btn)
        }
        col.axis = .vertical
        col.alignment = .center
        col.spacing = 10
        col.setCustomSpacing(24, after: b)
        let wrap = UIView()
        col.translatesAutoresizingMaskIntoConstraints = false
        wrap.addSubview(col)
        NSLayoutConstraint.activate([
            col.centerYAnchor.constraint(equalTo: wrap.centerYAnchor, constant: -40),
            col.leadingAnchor.constraint(equalTo: wrap.leadingAnchor, constant: 32),
            col.trailingAnchor.constraint(equalTo: wrap.trailingAnchor, constant: -32),
        ])
        stack.addArrangedSubview(wrap)
    }

    private func showLoading() {
        clear()
        let spinner = UIActivityIndicatorView(style: .medium)
        spinner.color = palette.muted
        spinner.startAnimating()
        stack.addArrangedSubview(spinner)
    }

    private func clear() {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
    }
}

// MARK: - Small UIKit helpers

/// UIScrollView does not mirror for RTL: it starts at the left and so shows the
/// end of a right-to-left row first. Flip the scroller and flip each item back,
/// so the first item sits at the right edge and reads normally.
private func mirrorForRTL(_ scroll: UIScrollView, _ row: UIStackView) {
    guard Fonts.rtl else { return }
    let flip = CGAffineTransform(scaleX: -1, y: 1)
    row.semanticContentAttribute = .forceLeftToRight
    scroll.transform = flip
    row.arrangedSubviews.forEach { $0.transform = flip }
}

private final class Tap: UITapGestureRecognizer {
    private let action: () -> Void
    init(_ action: @escaping () -> Void) {
        self.action = action
        super.init(target: nil, action: nil)
        addTarget(self, action: #selector(fire))
    }
    @objc private func fire() { action() }
}

private var actionKey: UInt8 = 0

extension UIControl {
    func addAction(for event: UIControl.Event, _ action: @escaping () -> Void) {
        let box = ActionBox(action)
        addTarget(box, action: #selector(ActionBox.fire), for: event)
        var boxes = objc_getAssociatedObject(self, &actionKey) as? [ActionBox] ?? []
        boxes.append(box)
        objc_setAssociatedObject(self, &actionKey, boxes, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }
}

private final class ActionBox: NSObject {
    let action: () -> Void
    init(_ action: @escaping () -> Void) { self.action = action }
    @objc func fire() { action() }
}

extension UILabel {
    /// Natural alignment follows the label's own direction; set it from the wall's.
    func reading(_ rtl: Bool) -> Self {
        semanticContentAttribute = rtl ? .forceRightToLeft : .forceLeftToRight
        textAlignment = .natural
        return self
    }
}

extension PaddedLabel {
    convenience init(_ text: String?, _ size: CGFloat, _ weight: Int, _ color: UIColor) {
        self.init(frame: .zero)
        self.text = text
        font = Fonts.font(size, weight)
        textColor = color
    }
}

extension UIFont {
    func withMonospacedDigits() -> UIFont {
        let d = fontDescriptor.addingAttributes([.featureSettings: [[
            UIFontDescriptor.FeatureKey.featureIdentifier: kNumberSpacingType,
            UIFontDescriptor.FeatureKey.typeIdentifier: kMonospacedNumbersSelector,
        ]]])
        return UIFont(descriptor: d, size: pointSize)
    }
}
