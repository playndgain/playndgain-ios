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
            // The user's money, as the one filled pill in the header.
            let pill = PrimaryButton(bal, p, size: 13)
            pill.contentEdgeInsets = UIEdgeInsets(top: 6, left: 12, bottom: 6, right: 12)
            pill.isUserInteractionEnabled = false
            pill.accessibilityTraits = .staticText
            bar.addArrangedSubview(pill)
        }

        let close = PressButton(type: .custom)
        close.setImage(Symbols.image("xmark", 14, p.muted), for: .normal)
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
            let b = PressButton(type: .custom)
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
            // The selected category takes the primary fill, as on the web wall;
            // the rest are hairline pills. Sort keeps its quieter tile.
            let b: PressButton = ink && on ? PrimaryButton(label, p, size: 13) : PressButton(type: .custom)
            b.setTitle(label, for: .normal)
            b.contentEdgeInsets = UIEdgeInsets(top: 0, left: ink ? 14 : 10, bottom: 0, right: ink ? 14 : 10)
            if ink {
                b.titleLabel?.font = Fonts.font(13, 600)
                if !on {
                    b.setTitleColor(p.faint, for: .normal)
                    _ = b.rounded(.clear, 18, border: p.line)
                }
            } else {
                b.titleLabel?.font = Fonts.font(12, on ? 600 : 400)
                b.setTitleColor(on ? p.text : p.muted, for: .normal)
                if on { _ = b.rounded(p.tile, 15) }
            }
            b.accessibilityTraits = on ? [.button, .selected] : .button
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
        // A new filter starts at the top of its own list.
        view.layoutIfNeeded()
        if !rows.isEmpty { table.scrollToRow(at: IndexPath(row: 0, section: 0), at: .top, animated: false) }
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

    /// The whole row is the button: it presses like one.
    func tableView(_ tableView: UITableView, shouldHighlightRowAt indexPath: IndexPath) -> Bool {
        guard section == .offers, indexPath.row < rows.count, case .offer = rows[indexPath.row] else { return false }
        return true
    }

    func tableView(_ tableView: UITableView, didHighlightRowAt indexPath: IndexPath) {
        tableView.cellForRow(at: indexPath)?.contentView.subviews.first.map { Press.apply($0, true) }
    }

    func tableView(_ tableView: UITableView, didUnhighlightRowAt indexPath: IndexPath) {
        tableView.cellForRow(at: indexPath)?.contentView.subviews.first.map { Press.apply($0, false) }
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

        // A pinned offer carries the primary on its leading edge, inset like
        // the web wall's, so the row's words stay on every other row's axis.
        if o.featured && !o.test {
            let edge = UIView().rounded(p.primary, 1.5)
            edge.translatesAutoresizingMaskIntoConstraints = false
            card.addSubview(edge)
            NSLayoutConstraint.activate([
                edge.widthAnchor.constraint(equalToConstant: 3),
                edge.topAnchor.constraint(equalTo: card.topAnchor, constant: 12),
                edge.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -12),
                edge.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 2),
            ])
        }

        card.addArrangedSubview(iconTile(o.name, o.iconURL, 48))

        let text = UIStackView()
        text.axis = .vertical
        text.spacing = 4
        let name = UILabel(o.name, 15, 600, p.text)
        name.lineBreakMode = .byTruncatingTail
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        text.addArrangedSubview(name)
        if !o.instructions.isEmpty {
            let note = UILabel(o.instructions, 12.5, 400, p.muted, lines: 2)
            note.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            text.addArrangedSubview(note)
        }
        let meta = [o.test ? strings.or("test_badge", "Test offer") : nil,
                    !o.test && o.featured ? strings["featured"] : nil,
                    o.stepsLabel ?? (o.multiReward ? strings["multi_reward"] : nil),
                    o.peopleLabel].compactMap { $0 }.filter { !$0.isEmpty }
        if !meta.isEmpty {
            let m = UILabel(meta.joined(separator: "  ·  "), 11.5, 400, p.faint)
            m.lineBreakMode = .byTruncatingTail
            m.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            text.addArrangedSubview(m)
        }
        text.setContentHuggingPriority(.defaultLow, for: .horizontal)
        text.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        card.addArrangedSubview(text)

        let reward = rewardStack(o.rewardLabel, upTo: o.multiReward)
        card.addArrangedSubview(reward)
        card.setCustomSpacing(8, after: reward)
        card.addArrangedSubview(chevron())

        card.isAccessibilityElement = true
        card.accessibilityLabel = rewardSpeech(o.name, o.rewardLabel, upTo: o.multiReward)
        card.accessibilityTraits = .button
        return card
    }

    private func rewardSpeech(_ name: String, _ reward: String, upTo: Bool) -> String {
        let up = upTo ? strings.or("up_to", "Up to") + " " : ""
        return "\(name), \(up)\(reward) \(last?.app?.currencyName ?? "")"
    }

    /// Decoration only: the whole row is the button, and this never starts
    /// the offer. A tile disc with the text colour, mirrored on an RTL wall.
    private func chevron() -> UIView {
        let p = palette
        let disc = UIView().rounded(p.tile, 14)
        disc.isUserInteractionEnabled = false
        disc.isAccessibilityElement = false
        let img = UIImageView(image: Symbols.image("chevron.right", 11, p.text, weight: .bold)?.imageFlippedForRightToLeftLayoutDirection())
        img.semanticContentAttribute = view.semanticContentAttribute
        img.translatesAutoresizingMaskIntoConstraints = false
        disc.addSubview(img)
        NSLayoutConstraint.activate([
            disc.widthAnchor.constraint(equalToConstant: 28),
            disc.heightAnchor.constraint(equalToConstant: 28),
            img.centerXAnchor.constraint(equalTo: disc.centerXAnchor),
            img.centerYAnchor.constraint(equalTo: disc.centerYAnchor),
        ])
        return disc
    }

    /// The ledger column: one fixed inline size on every row, so the figures
    /// share an edge. It never gives way; the name beside it truncates instead.
    private func rewardStack(_ label: String, upTo: Bool) -> UIView {
        let p = palette
        let v = UIStackView()
        v.axis = .vertical
        v.alignment = Fonts.rtl ? .leading : .trailing
        if upTo { v.addArrangedSubview(capsLabel(strings.or("up_to", "Up to"))) }
        let fig = figure("+" + label, 19, p.text)
        v.addArrangedSubview(fig)
        v.addArrangedSubview(capsLabel(last?.app?.currencyName ?? ""))
        v.pinLedgerWidth(72)
        return v
    }

    /// A figure reads the same in both directions: "+6,125" keeps its sign in
    /// front on the Arabic wall too.
    private func figure(_ text: String, _ size: CGFloat, _ color: UIColor) -> UILabel {
        let l = UILabel(text, size, 700, color)
        l.font = l.font.withMonospacedDigits()
        l.semanticContentAttribute = .forceLeftToRight
        l.setContentCompressionResistancePriority(.required, for: .horizontal)
        l.setContentHuggingPriority(.required, for: .horizontal)
        return l
    }

    /// 11/600 small capitals in the faint colour: the currency and "Up to".
    private func capsLabel(_ text: String) -> UILabel {
        let l = UILabel(text, 11, 600, palette.faint)
        if !Fonts.rtl {
            l.attributedText = NSAttributedString(string: text.uppercased(), attributes: [.kern: 0.6, .font: l.font!, .foregroundColor: palette.faint])
        }
        l.setContentCompressionResistancePriority(.required, for: .horizontal)
        return l
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
            let control = PressControl()
            _ = control.rounded(p.card, p.radius, border: p.line)
            let card = UIStackView()
            card.axis = .vertical
            card.spacing = 4
            card.isLayoutMarginsRelativeArrangement = true
            card.layoutMargins = UIEdgeInsets(top: 14, left: 14, bottom: 14, right: 14)
            card.isUserInteractionEnabled = false
            card.translatesAutoresizingMaskIntoConstraints = false
            control.addSubview(card)
            NSLayoutConstraint.activate([
                card.topAnchor.constraint(equalTo: control.topAnchor),
                card.bottomAnchor.constraint(equalTo: control.bottomAnchor),
                card.leadingAnchor.constraint(equalTo: control.leadingAnchor),
                card.trailingAnchor.constraint(equalTo: control.trailingAnchor),
            ])
            let top = UIStackView(arrangedSubviews: [iconTile(o.name, o.iconURL, 44), UIView(), rewardStack(o.rewardLabel, upTo: o.multiReward)])
            top.alignment = .center
            top.semanticContentAttribute = view.semanticContentAttribute
            card.addArrangedSubview(top)
            card.setCustomSpacing(12, after: top)
            card.addArrangedSubview(UILabel(o.name, 15, 600, p.text))
            card.addArrangedSubview(UILabel(o.instructions, 12.5, 400, p.muted))
            // Height comes from the row's `.fill` alignment once the card is in
            // it; a constraint to the row before that has no common ancestor.
            control.widthAnchor.constraint(equalToConstant: 220).isActive = true
            control.addAction(for: .touchUpInside) { [weak self] in self?.openDetail(o.id) }
            control.isAccessibilityElement = true
            control.accessibilityLabel = rewardSpeech(o.name, o.rewardLabel, upTo: o.multiReward)
            control.accessibilityTraits = .button
            row.addArrangedSubview(control)
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
                self.presentDetail(r)
            }
        }
    }

    private func presentDetail(_ r: WallResponse) {
        let sheet = DetailViewController(response: r, palette: palette, strings: r.strings.root == nil ? strings : r.strings, currency: last?.app?.currencyName ?? "") { [weak self] url, name in
            self?.dismiss(animated: true) { self?.startOffer(url, name: name) }
        }
        if #available(iOS 15.0, *), let s = sheet.sheetPresentationController {
            s.detents = [.large()]
            s.prefersGrabberVisible = true
            s.preferredCornerRadius = palette.radius * 1.8
        }
        present(sheet, animated: true)
    }

    // MARK: Clicks

    /// The click reached nothing: the wall stays, and the detail sheet's own
    /// notice says this offer could not be opened.
    private func showOfferNotice() {
        let n = Notice(key: "blocked", title: strings.or("notice.blocked.title", "Offer unavailable"),
                       body: strings.or("notice.blocked.body", "We could not open this offer. Please go back and try a different one."))
        presentDetail(WallResponse(status: "blocked", http: 0, app: nil, strings: strings, notice: n))
    }

    /// Inside the app: `OfferFlow` follows `/click/{offer}` once, so the
    /// wall's own pre-click checks, the click row and the redirect to the
    /// advertiser all happen exactly as in the iframe, then shows the store
    /// sheet or the page it landed on.
    private func startOffer(_ url: URL?, name: String) {
        let base = Playndgain.config.baseURL
        guard offerFlow == nil, let url = url, Links.isAllowedClick(url, base: base) else {
            Playndgain.emit(.internal)
            return
        }
        let flow = OfferFlow(host: self, palette: palette, copy: coverCopy(name),
                             leaving: { [weak self] in self?.pendingRewardCheck = $0 }) { [weak self] end in
            guard let self = self else { return }
            self.offerFlow = nil
            switch end {
            case .returned: self.rewardCheck()
            case .leftApp, .cancelled: break
            case .failed: Playndgain.emit(.network); self.showOfferNotice()
            }
        }
        offerFlow = flow
        if !flow.start(url, base: base) { offerFlow = nil; Playndgain.emit(.internal) }
    }

    /// The cover's words: the wall's own strings first (`offer.opening` with
    /// `:name`, `offer.still_opening`, `offer.still_opening_body`,
    /// `offer.keep_waiting`), then the bundled English or Arabic.
    private func coverCopy(_ name: String) -> CoverCopy {
        let opening = strings.or("offer.opening", arabic ? "جارٍ فتح :name…" : "Opening :name…")
        return CoverCopy(
            opening: opening.replacingOccurrences(of: ":name", with: name),
            stalledTitle: strings.or("offer.still_opening", arabic ? "لا يزال العرض قيد الفتح…" : "Still opening…"),
            stalledBody: strings.or("offer.still_opening_body", arabic
                ? "يستغرق هذا العرض وقتا أطول من المعتاد. يمكنك الانتظار أو إغلاقه."
                : "This offer is taking longer than usual. You can keep waiting or close it."),
            keepWaiting: strings.or("offer.keep_waiting", arabic ? "متابعة الانتظار" : "Keep waiting"),
            close: closeLabel
        )
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
        t.alignment = Fonts.rtl ? .trailing : .leading
        t.spacing = 4
        let name = UILabel(r.name, 15, 600, p.text)
        name.lineBreakMode = .byTruncatingTail
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        t.addArrangedSubview(name)

        // Status is a word on a quiet pill, never a new colour: credited takes
        // the primary, waiting the faint text, refused the muted text.
        let pill = PaddedLabel(r.statusLabel, 11, 600, statusColor(r.status))
        pill.insets = UIEdgeInsets(top: 3, left: 8, bottom: 3, right: 8)
        _ = pill.rounded(p.tile, 10)
        pill.clipsToBounds = true
        pill.setContentCompressionResistancePriority(.required, for: .horizontal)
        let meta = UIStackView(arrangedSubviews: [pill])
        meta.spacing = 8
        meta.alignment = .center
        meta.semanticContentAttribute = view.semanticContentAttribute
        let when = [r.partner, r.at.flatMap(shortDate)].compactMap { $0 }.joined(separator: "  ·  ")
        if !when.isEmpty {
            let w = UILabel(when, 12, 400, p.muted)
            w.lineBreakMode = .byTruncatingTail
            w.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            meta.addArrangedSubview(w)
        }
        t.addArrangedSubview(meta)
        if let reason = r.reason { t.addArrangedSubview(UILabel(reason, 12, 400, p.faint, lines: 0)) }
        t.setContentHuggingPriority(.defaultLow, for: .horizontal)
        t.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        row.addArrangedSubview(t)

        var spoken = [r.name, r.statusLabel]
        if let reward = r.rewardLabel {
            // Money keeps the primary. A reversed amount is taken back: a
            // minus sign and the muted colour, with the word beside it.
            let reversed = r.status == "reversed"
            let v = UIStackView()
            v.axis = .vertical
            v.alignment = Fonts.rtl ? .leading : .trailing
            v.addArrangedSubview(figure((reversed ? "\u{2212}" : "+") + reward, 15, reversed ? p.muted : p.primary))
            v.addArrangedSubview(capsLabel(last?.app?.currencyName ?? ""))
            v.pinLedgerWidth(72)
            row.addArrangedSubview(v)
            spoken.append("\(reversed ? "\u{2212}" : "+")\(reward) \(last?.app?.currencyName ?? "")")
        }
        row.isAccessibilityElement = true
        row.accessibilityLabel = spoken.joined(separator: ", ")
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

    private func statusColor(_ status: String) -> UIColor {
        switch status {
        case "approved": return palette.primary
        case "rejected", "reversed": return palette.muted
        default: return palette.faint
        }
    }

    /// "14 Oct" the way the wall's language writes it, not the device's. The
    /// day is the wall's own (the date part it sent), as on the web wall.
    private func shortDate(_ iso: String) -> String? {
        let utc = TimeZone(identifier: "UTC")
        let parse = DateFormatter()
        parse.locale = Locale(identifier: "en_US_POSIX")
        parse.timeZone = utc
        parse.dateFormat = "yyyy-MM-dd"
        let day = String(iso.prefix(10))
        guard let date = parse.date(from: day) else { return day }
        let f = DateFormatter()
        f.locale = Locale(identifier: last?.app?.locale ?? (arabic ? "ar" : "en"))
        f.timeZone = utc
        f.setLocalizedDateFormatFromTemplate("dMMM")
        return f.string(from: date)
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
            let b = PressButton(type: .custom)
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
            let btn: PressButton = filled ? PrimaryButton(label, p, size: 14) : PressButton(type: .custom)
            btn.setTitle(label, for: .normal)
            btn.titleLabel?.font = Fonts.font(14, 600)
            if !filled {
                btn.setTitleColor(p.text, for: .normal)
                _ = btn.rounded(p.card, 24, border: p.line)
            }
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
    row.arrangedSubviews.forEach { v in
        v.transform = flip
        (v as? PressButton)?.rest = flip
        (v as? PressControl)?.rest = flip
    }
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

extension UIStackView {
    /// A stack view has no intrinsic size, so hugging does not hold it: pin
    /// the column to `width`, growing only when a figure needs more.
    func pinLedgerWidth(_ width: CGFloat) {
        widthAnchor.constraint(greaterThanOrEqualToConstant: width).isActive = true
        let snug = widthAnchor.constraint(equalToConstant: width)
        snug.priority = .defaultHigh
        snug.isActive = true
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
