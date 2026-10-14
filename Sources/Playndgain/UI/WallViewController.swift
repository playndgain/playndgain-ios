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
        // Inside the safe area on every side but the bottom, where the list
        // runs under the home indicator. On a tablet the wall keeps a phone's
        // reading width, centred, rather than stretching rows across it.
        let safe = view.safeAreaLayoutGuide
        let fill = stack.widthAnchor.constraint(equalTo: safe.widthAnchor)
        fill.priority = .defaultHigh
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: safe.topAnchor),
            stack.centerXAnchor.constraint(equalTo: safe.centerXAnchor),
            stack.widthAnchor.constraint(lessThanOrEqualToConstant: 600),
            stack.widthAnchor.constraint(lessThanOrEqualTo: safe.widthAnchor),
            fill,
            stack.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        table.dataSource = self
        table.delegate = self
        table.separatorStyle = .none
        table.backgroundColor = .clear
        table.contentInset = UIEdgeInsets(top: 0, left: 0, bottom: 32, right: 0)
        table.keyboardDismissMode = .onDrag
        table.rowHeight = UITableView.automaticDimension
        table.estimatedRowHeight = 96
        table.register(UITableViewCell.self, forCellReuseIdentifier: "c")
        NotificationCenter.default.addObserver(self, selector: #selector(didBecomeActive), name: UIApplication.didBecomeActiveNotification, object: nil)
        showLoading()
        load()
    }

    override var preferredStatusBarStyle: UIStatusBarStyle { palette.dark ? .lightContent : .darkContent }

    /// The search and filters scroll away with the list as its header. A
    /// table header is sized by hand: fit it to the table's width.
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        guard let header = table.tableHeaderView, table.bounds.width > 0 else { return }
        let size = header.systemLayoutSizeFitting(CGSize(width: table.bounds.width, height: 0),
                                                  withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel)
        if header.frame.size != size {
            header.frame.size = size
            table.tableHeaderView = header
        }
    }

    /// A new reading size redraws the wall from the answer in hand.
    override func traitCollectionDidChange(_ previous: UITraitCollection?) {
        super.traitCollectionDidChange(previous)
        guard previous?.preferredContentSizeCategory != traitCollection.preferredContentSizeCategory,
              let r = last, ["ok", "unplaced"].contains(r.status) else { return }
        buildChrome(r)
        if section == .offers { buildOffers(r) } else { buildHistory(r.history) }
    }

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
            // System parts (keyboard, spinners, sheets) match the wall, not the phone.
            overrideUserInterfaceStyle = palette.dark ? .dark : .light
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

        let mark = UILabel(String(name.prefix(1)).uppercased(), Role.rowTitle, 700, p.primary)
        mark.textAlignment = .center
        _ = mark.rounded(p.tile, p.radius * 0.6)
        mark.clipsToBounds = true
        mark.widthAnchor.constraint(equalToConstant: 36).isActive = true
        mark.heightAnchor.constraint(equalToConstant: 36).isActive = true
        mark.isAccessibilityElement = false
        mark.adjustsFontForContentSizeCategory = false
        mark.adjustsFontSizeToFitWidth = true
        bar.addArrangedSubview(mark)

        let titles = UIStackView(arrangedSubviews: [UILabel(name, Role.rowTitle, 600, p.text), UILabel(strings["earn"], Role.label, 400, p.muted)])
        titles.axis = .vertical
        titles.spacing = 3
        bar.addArrangedSubview(titles)
        titles.setContentHuggingPriority(.defaultLow, for: .horizontal)

        if let bal = options.balance ?? app.balance {
            // The user's money, as the one filled pill in the header.
            let pill = PrimaryButton(bal, p, size: Role.body)
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
            b.titleLabel?.font = Fonts.font(Role.body, on ? 700 : 600)
            b.setTitleColor(on ? p.text : p.faint, for: .normal)
            b.contentEdgeInsets = UIEdgeInsets(top: 8, left: 16, bottom: 8, right: 16)
            b.heightAnchor.constraint(greaterThanOrEqualToConstant: 36).isActive = true
            b.hitOutset = 4
            b.pill = true
            if on {
                b.backgroundColor = p.primarySoft
                b.layer.borderWidth = 1
                b.layer.borderColor = p.primary.withAlphaComponent(0.35).cgColor
            }
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
        UIAccessibility.post(notification: .announcement, argument: t == .offers ? strings.or("tabs.offers", "Offers") : strings.or("tabs.history", "History"))
        if let r = last { buildChrome(r) }
        let spinner = UIActivityIndicatorView(style: .medium)
        spinner.color = palette.muted
        spinner.startAnimating()
        stack.addArrangedSubview(spinner)
        load()
    }

    // MARK: Offers

    private func buildOffers(_ r: WallResponse) {
        stack.addArrangedSubview(table)
        table.tableHeaderView = controls(r)
        refilter()
        view.setNeedsLayout()
    }

    /// Search, categories and sort: the list's header, so they scroll away
    /// and the offers get the screen, in landscape most of all.
    private func controls(_ r: WallResponse) -> UIView {
        let p = palette
        let search = UISearchBar()
        search.searchBarStyle = .minimal
        search.placeholder = strings.or("search_placeholder", "Search…")
        search.text = query
        search.delegate = self
        search.keyboardAppearance = p.dark ? .dark : .light
        search.returnKeyType = .search
        let field = search.searchTextField
        field.font = Fonts.font(Role.body, 400)
        field.adjustsFontForContentSizeCategory = true
        field.textColor = p.text
        field.tintColor = p.primary
        field.attributedPlaceholder = NSAttributedString(string: search.placeholder ?? "", attributes: [.foregroundColor: p.faint, .font: Fonts.font(Role.body, 400)])
        field.leftView?.tintColor = p.faint
        field.borderStyle = .none
        field.backgroundColor = p.card
        field.layer.cornerRadius = 18
        field.layer.borderWidth = 1
        field.layer.borderColor = p.line.cgColor
        field.clipsToBounds = true
        search.semanticContentAttribute = view.semanticContentAttribute
        let col = UIStackView(arrangedSubviews: [search])
        col.axis = .vertical
        col.isLayoutMarginsRelativeArrangement = true
        col.layoutMargins = UIEdgeInsets(top: 8, left: 0, bottom: 4, right: 0)
        col.setCustomSpacing(4, after: search)
        let searchInset = search.widthAnchor.constraint(equalTo: col.widthAnchor, constant: -16)
        searchInset.isActive = true

        if !r.categories.isEmpty {
            var chips: [(String, Bool, () -> Void)] = [(strings.or("all", "All"), category == nil, { [weak self] in self?.pickCategory(nil) })]
            for c in r.categories {
                chips.append((c.prefix(1).uppercased() + c.dropFirst(), category == c, { [weak self] in self?.pickCategory(c) }))
            }
            col.addArrangedSubview(chipRow(chips, ink: true))
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
        col.addArrangedSubview(sortRow)
        col.alignment = .center
        col.arrangedSubviews.dropFirst().forEach { $0.widthAnchor.constraint(equalTo: col.widthAnchor).isActive = true }
        return col
    }

    func searchBarSearchButtonClicked(_ searchBar: UISearchBar) {
        searchBar.resignFirstResponder()
    }

    private func chipRow(_ chips: [(String, Bool, () -> Void)], ink: Bool) -> UIView {
        let p = palette
        let scroll = UIScrollView()
        scroll.showsHorizontalScrollIndicator = false
        let row = UIStackView()
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = 8
        row.translatesAutoresizingMaskIntoConstraints = false
        row.semanticContentAttribute = view.semanticContentAttribute
        scroll.addSubview(row)
        // As tall as its chips at the reader's text size, never scrolling up and down.
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: 6),
            row.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -6),
            row.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor, constant: 16),
            row.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: -16),
            scroll.contentLayoutGuide.heightAnchor.constraint(equalTo: scroll.frameLayoutGuide.heightAnchor),
            scroll.heightAnchor.constraint(equalTo: row.heightAnchor, constant: 12),
        ])
        for (label, on, action) in chips {
            // The selected category takes the primary fill, as on the web wall;
            // the rest are hairline pills. Sort keeps its quieter tile.
            let b: PressButton = ink && on ? PrimaryButton(label, p, size: Role.label) : PressButton(type: .custom)
            b.setTitle(label, for: .normal)
            b.titleLabel?.font = Fonts.font(Role.label, 600)
            b.contentEdgeInsets = UIEdgeInsets(top: 9, left: ink ? 14 : 12, bottom: 9, right: ink ? 14 : 12)
            b.hitOutset = 5
            b.pill = true
            if ink {
                if !on {
                    b.setTitleColor(p.faint, for: .normal)
                    b.layer.borderWidth = 1
                    b.layer.borderColor = p.line.cgColor
                }
            } else {
                b.setTitleColor(on ? p.text : p.faint, for: .normal)
                if on { b.backgroundColor = p.tile }
            }
            b.accessibilityTraits = on ? [.button, .selected] : .button
            b.addAction(for: .touchUpInside, action)
            row.addArrangedSubview(b)
        }
        mirrorForRTL(scroll, row)
        return scroll
    }

    /// The selected chip has to redraw, so the controls are rebuilt from the
    /// response already in hand. No refetch, and the tabs stay as they are.
    private func pickCategory(_ c: String?) {
        guard let r = last else { return }
        category = c
        table.tableHeaderView = controls(r)
        refilter()
        view.setNeedsLayout()
        // A new filter starts at the top of its own list.
        view.layoutIfNeeded()
        table.setContentOffset(CGPoint(x: 0, y: -table.adjustedContentInset.top), animated: false)
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
        let name = UILabel(o.name, Role.rowTitle, 600, p.text, lines: 2)
        name.lineBreakMode = .byTruncatingTail
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        text.addArrangedSubview(name)
        if !o.instructions.isEmpty {
            let note = UILabel(o.instructions, Role.body, 400, p.muted, lines: 2)
            note.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            text.addArrangedSubview(note)
        }
        let meta = [o.test ? strings.or("test_badge", "Test offer") : nil,
                    !o.test && o.featured ? strings["featured"] : nil,
                    o.stepsLabel ?? (o.repeatable ? strings["multi_reward"] : nil)].compactMap { $0 }.filter { !$0.isEmpty }
        if !meta.isEmpty || o.peopleLabel != nil {
            let m = UILabel(nil, Role.label, 400, p.faint)
            m.attributedText = metaLine(meta, people: o.peopleLabel, font: m.font)
            m.lineBreakMode = .byTruncatingTail
            m.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            text.addArrangedSubview(m)
        }
        text.setContentHuggingPriority(.defaultLow, for: .horizontal)
        text.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        if bigText {
            // At the accessibility sizes the figure goes under the words, so
            // neither has to squeeze the other into a column of letters.
            let reward = rewardStack(o.rewardLabel, upTo: o.upTo, inline: true)
            let inner = UIStackView(arrangedSubviews: [text, reward])
            inner.axis = .vertical
            inner.alignment = Fonts.rtl ? .trailing : .leading
            inner.spacing = 8
            inner.setContentHuggingPriority(.defaultLow, for: .horizontal)
            card.addArrangedSubview(inner)
        } else {
            card.addArrangedSubview(text)
            let reward = rewardStack(o.rewardLabel, upTo: o.upTo)
            card.addArrangedSubview(reward)
            card.setCustomSpacing(8, after: reward)
        }
        card.addArrangedSubview(chevron())

        card.isAccessibilityElement = true
        card.accessibilityLabel = rewardSpeech(o.name, o.rewardLabel, upTo: o.upTo)
        card.accessibilityTraits = .button
        return card
    }

    /// "Featured · 4 steps · (person) 12": the people count wears a person
    /// glyph, so "+12" reads as people who joined rather than a reward.
    private func metaLine(_ parts: [String], people: String?, font: UIFont) -> NSAttributedString {
        let color = palette.faint
        let out = NSMutableAttributedString(string: parts.joined(separator: "  ·  "), attributes: [.font: font, .foregroundColor: color])
        guard let people = people?.trimmingCharacters(in: CharacterSet(charactersIn: "+ ")), !people.isEmpty else { return out }
        if out.length > 0 { out.append(NSAttributedString(string: "  ·  ", attributes: [.font: font, .foregroundColor: color])) }
        if let glyph = Symbols.image("person.fill", font.pointSize * 0.8, color) {
            let a = NSTextAttachment()
            a.image = glyph
            a.bounds = CGRect(x: 0, y: (font.capHeight - glyph.size.height) / 2, width: glyph.size.width, height: glyph.size.height)
            out.append(NSAttributedString(attachment: a))
        }
        out.append(NSAttributedString(string: "\u{2009}" + people, attributes: [.font: font, .foregroundColor: color]))
        return out
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
    private var bigText: Bool { traitCollection.preferredContentSizeCategory.isAccessibilityCategory }

    private func rewardStack(_ label: String, upTo: Bool, inline: Bool = false) -> UIView {
        let p = palette
        let v = UIStackView()
        if inline {
            v.axis = .horizontal
            v.alignment = .firstBaseline
            v.spacing = 6
            v.semanticContentAttribute = view.semanticContentAttribute
            if upTo { v.addArrangedSubview(capsLabel(strings.or("up_to", "Up to"))) }
            v.addArrangedSubview(figure("+" + label, Role.reward, p.text))
            v.addArrangedSubview(capsLabel(last?.app?.currencyName ?? ""))
            return v
        }
        v.axis = .vertical
        v.alignment = Fonts.rtl ? .leading : .trailing
        if upTo { v.addArrangedSubview(capsLabel(strings.or("up_to", "Up to"))) }
        let fig = figure("+" + label, Role.reward, p.text)
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
        let l = UILabel(text, Role.caps, 600, palette.faint)
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
        let title = UILabel(strings.or("featured_offers", "Featured offers"), Role.label, 600, p.muted)
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
            // As tall as its tallest card at the reader's text size.
            scroll.contentLayoutGuide.heightAnchor.constraint(equalTo: scroll.frameLayoutGuide.heightAnchor),
            scroll.heightAnchor.constraint(equalTo: row.heightAnchor),
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
            let top = UIStackView(arrangedSubviews: [iconTile(o.name, o.iconURL, 44), UIView(), rewardStack(o.rewardLabel, upTo: o.upTo)])
            top.alignment = .center
            top.semanticContentAttribute = view.semanticContentAttribute
            card.addArrangedSubview(top)
            card.setCustomSpacing(12, after: top)
            card.addArrangedSubview(UILabel(o.name, Role.rowTitle, 600, p.text))
            card.addArrangedSubview(UILabel(o.instructions, Role.body, 400, p.muted))
            // Height comes from the row's `.fill` alignment once the card is in
            // it; a constraint to the row before that has no common ancestor.
            control.widthAnchor.constraint(equalToConstant: 220).isActive = true
            control.addAction(for: .touchUpInside) { [weak self] in self?.openDetail(o.id) }
            control.isAccessibilityElement = true
            control.accessibilityLabel = rewardSpeech(o.name, o.rewardLabel, upTo: o.upTo)
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
        // A fixed tile: the letter stays its size whatever the reading size.
        let letter = UILabel(String(name.prefix(1)).uppercased(), size * 0.4, 700, p.muted)
        letter.adjustsFontForContentSizeCategory = false
        letter.adjustsFontSizeToFitWidth = true
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
        let v = UIStackView(arrangedSubviews: [UILabel(title, Role.sheetTitle, 700, p.text, lines: 0), UILabel(body, Role.body, 400, p.muted, lines: 0)])
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
        let sheet = DetailViewController(response: r, palette: palette, strings: r.strings.root == nil ? strings : r.strings, currency: last?.app?.currencyName ?? "") { [weak self] url, name, opening in
            self?.dismiss(animated: true) { self?.startOffer(url, name: name, opening: opening) }
        }
        sheet.configureSheet(width: min(view.bounds.width, 600))
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
    private func startOffer(_ url: URL?, name: String, opening: String?) {
        let base = Playndgain.config.baseURL
        guard offerFlow == nil, let url = url, Links.isAllowedClick(url, base: base) else {
            Playndgain.emit(.internal)
            return
        }
        let flow = OfferFlow(host: self, palette: palette, copy: coverCopy(name, opening: opening),
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

    /// The cover's words: the offer's own finished `opening_label`, else the
    /// wall's nameless `offer.opening_any`, else the bundled English or Arabic
    /// with the name; then `offer.still_opening`, `offer.still_opening_body`
    /// and `offer.keep_waiting` the same way.
    private func coverCopy(_ name: String, opening label: String?) -> CoverCopy {
        let bundled = (arabic ? "جارٍ فتح :name…" : "Opening :name…").replacingOccurrences(of: ":name", with: name)
        return CoverCopy(
            opening: label ?? strings.or("offer.opening_any", bundled),
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
        let name = UILabel(r.name, Role.rowTitle, 600, p.text)
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
        col.addArrangedSubview(UILabel(strings["consent.title"], Role.title, 700, p.text, lines: 0))
        col.addArrangedSubview(UILabel(strings["consent.intro"], Role.body, 400, p.muted, lines: 0))
        for k in ["what", "why", "who"] {
            let label = UILabel(strings["consent.\(k)_label"], Role.label, 600, p.text)
            col.addArrangedSubview(label)
            col.setCustomSpacing(4, after: label)
            col.addArrangedSubview(UILabel(strings["consent.\(k)"], Role.body, 400, p.muted, lines: 0))
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
            b.pill = true
            b.titleLabel?.numberOfLines = 0
            b.titleLabel?.textAlignment = .center
            b.heightAnchor.constraint(greaterThanOrEqualToConstant: 52).isActive = true
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
        let t = UILabel(title, Role.title, 700, p.text, lines: 0); t.textAlignment = .center
        let b = UILabel(body, Role.body, 400, p.muted, lines: 0); b.textAlignment = .center
        let col = UIStackView(arrangedSubviews: [t, b])
        for (label, filled, tap) in actions {
            let btn: PressButton = filled ? PrimaryButton(label, p, size: 14) : PressButton(type: .custom)
            btn.setTitle(label, for: .normal)
            btn.titleLabel?.font = Fonts.font(Role.button, 600)
            if !filled {
                btn.setTitleColor(p.text, for: .normal)
                _ = btn.rounded(p.card, 24, border: p.line)
            }
            btn.contentEdgeInsets = UIEdgeInsets(top: 10, left: 28, bottom: 10, right: 28)
            btn.pill = true
            btn.heightAnchor.constraint(greaterThanOrEqualToConstant: 48).isActive = true
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
        t.accessibilityTraits = .header
        UIAccessibility.post(notification: .screenChanged, argument: t)
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
