import UIKit

/// The offer detail as a sheet: steps, notes, who it is for, the Important
/// box, and a Start button that leaves the app. The sheet is as tall as what
/// it says, up to the large detent; a notice is a short sheet with one way back.
final class DetailViewController: UIViewController {
    private let response: WallResponse
    private let palette: Palette
    private let strings: Strings
    private let currency: String
    private let onStart: (URL?, String, String?) -> Void
    private let haptic = UIImpactFeedbackGenerator(style: .light)
    private let scroll = UIScrollView()
    private let col = UIStackView()
    private var footer: UIView?
    /// What the sheet needs to show everything, for the content-sized detent.
    private(set) var fittingHeight: CGFloat = 0

    init(response: WallResponse, palette: Palette, strings: Strings, currency: String, onStart: @escaping (URL?, String, String?) -> Void) {
        self.response = response
        self.palette = palette
        self.strings = strings
        self.currency = currency
        self.onStart = onStart
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// A detent the height of the content, under the large one. iOS 15 has
    /// no custom detents: medium for a notice, large for an offer there.
    func configureSheet(width: CGFloat) {
        // Measure before presenting, so the first detent asked for is the
        // right one and the sheet does not open tall and then settle.
        loadViewIfNeeded()
        view.frame = CGRect(x: 0, y: 0, width: width, height: 1000)
        view.layoutIfNeeded()
        guard let s = sheetPresentationController else { return }
        s.prefersGrabberVisible = true
        s.preferredCornerRadius = palette.radius * 1.8
        if #available(iOS 16.0, *) {
            let fit = UISheetPresentationController.Detent.custom(identifier: .init("playndgain.fit")) { [weak self] ctx in
                guard let self = self, self.fittingHeight > 0 else { return ctx.maximumDetentValue }
                return min(self.fittingHeight, ctx.maximumDetentValue)
            }
            s.detents = [fit, .large()]
        } else {
            s.detents = response.status == "ok" && response.detail != nil ? [.large()] : [.medium()]
        }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        let p = palette
        view.backgroundColor = p.card
        view.semanticContentAttribute = Fonts.rtl ? .forceRightToLeft : .forceLeftToRight
        overrideUserInterfaceStyle = p.dark ? .dark : .light

        col.axis = .vertical
        col.spacing = 6
        col.isLayoutMarginsRelativeArrangement = true
        col.layoutMargins = UIEdgeInsets(top: 28, left: 20, bottom: 16, right: 20)
        col.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(col)
        NSLayoutConstraint.activate([
            col.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
            col.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
            col.leadingAnchor.constraint(equalTo: scroll.frameLayoutGuide.leadingAnchor),
            col.trailingAnchor.constraint(equalTo: scroll.frameLayoutGuide.trailingAnchor),
        ])

        if response.status == "ok", let d = response.detail { buildOffer(d) } else { buildNotice() }

        var parts: [UIView] = [scroll]
        if let footer = footer { parts.append(footer) }
        let outer = UIStackView(arrangedSubviews: parts)
        outer.axis = .vertical
        outer.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(outer)
        NSLayoutConstraint.activate([
            outer.topAnchor.constraint(equalTo: view.topAnchor),
            outer.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            outer.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
            outer.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
        ])
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let width = view.bounds.width - view.safeAreaInsets.left - view.safeAreaInsets.right
        let content = col.systemLayoutSizeFitting(CGSize(width: width, height: 0),
                                                  withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel).height
        let foot = footer?.systemLayoutSizeFitting(CGSize(width: width, height: 0),
                                                   withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel).height ?? 0
        // A custom detent's height leaves out the bottom safe area.
        let height = ceil(content + foot)
        guard abs(height - fittingHeight) > 0.5 else { return }
        fittingHeight = height
        if #available(iOS 16.0, *), let s = sheetPresentationController {
            s.animateChanges { s.invalidateDetents() }
        }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        haptic.prepare()
        UIAccessibility.post(notification: .screenChanged, argument: col.arrangedSubviews.first)
    }

    // MARK: Offer

    private func buildOffer(_ d: OfferDetail) {
        let p = palette
        let head = UIStackView()
        head.spacing = 14
        head.alignment = .center
        head.semanticContentAttribute = view.semanticContentAttribute
        head.addArrangedSubview(iconTile(d.name, d.iconURL, 56))

        // The figure as the row has it: "Up to", then "+6,125", then the currency.
        let reward = UIStackView()
        reward.alignment = .firstBaseline
        reward.spacing = 6
        reward.semanticContentAttribute = view.semanticContentAttribute
        if d.upTo { reward.addArrangedSubview(caps(strings.or("up_to", "Up to"))) }
        reward.addArrangedSubview(figure("+" + d.rewardLabel, Role.reward))
        reward.addArrangedSubview(caps(currency))
        reward.addArrangedSubview(UIView())
        if traitCollection.preferredContentSizeCategory.isAccessibilityCategory {
            reward.axis = .vertical
            reward.alignment = Fonts.rtl ? .trailing : .leading
            reward.spacing = 0
        }
        let title = UILabel(d.name, Role.sheetTitle, 700, p.text, lines: 2)
        title.accessibilityTraits = .header
        let ht = UIStackView(arrangedSubviews: [title, reward])
        ht.axis = .vertical
        ht.spacing = 4
        head.addArrangedSubview(ht)
        col.addArrangedSubview(head)

        section(strings.or("offer.steps", "What you have to do"))
        for (i, step) in d.steps.enumerated() {
            let num = UILabel("\(i + 1)", Role.label, 700, p.text)
            num.textAlignment = .center
            num.adjustsFontForContentSizeCategory = false
            _ = num.rounded(p.tile, 13)
            num.clipsToBounds = true
            num.widthAnchor.constraint(equalToConstant: 26).isActive = true
            num.heightAnchor.constraint(equalToConstant: 26).isActive = true
            let name = UILabel(step.name, Role.body, 400, p.text, lines: 0)
            name.setContentHuggingPriority(.defaultLow, for: .horizontal)
            name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            // The same trailing column as the list, so the step figures line
            // up. A step that pays nothing on its own says so in words.
            let figureLabel = step.required
                ? UILabel(step.reward.isEmpty ? strings.or("offer.required", "Required") : step.reward, Role.label, 600, p.muted)
                : figure("+" + step.reward, Role.body)
            let column = UIStackView(arrangedSubviews: [figureLabel])
            column.axis = .vertical
            column.alignment = Fonts.rtl ? .leading : .trailing
            column.pinLedgerWidth(72)
            let row = UIStackView(arrangedSubviews: [num, name, column])
            row.spacing = 12
            row.alignment = .center
            row.semanticContentAttribute = view.semanticContentAttribute
            col.addArrangedSubview(row)
        }
        if let note = d.stepsNote { col.addArrangedSubview(UILabel(note, Role.label, 400, p.faint, lines: 0)) }

        if !d.notes.isEmpty {
            section(strings.or("offer.how", "Before you start"))
            for n in d.notes { col.addArrangedSubview(UILabel("•  " + n, Role.body, 400, p.text, lines: 0)) }
        }

        section(strings.or("offer.requirements", "Who this is for"))
        let devices = !d.deviceLabels.isEmpty ? d.deviceLabels.joined(separator: ", ")
            : d.devices.isEmpty ? strings.or("offer.any_device", "Any device")
            : d.devices.map { strings.or("device.\($0.lowercased())", $0) }.joined(separator: ", ")
        let countries = d.countries.isEmpty ? strings.or("offer.worldwide", "Worldwide")
            : d.countries.prefix(8).joined(separator: ", ") + (d.countries.count > 8 ? " +\(d.countries.count - 8)" : "")
        var facts = [(strings.or("offer.devices", "Devices"), devices), (strings.or("offer.countries", "Countries"), countries)]
        if let os = d.osMin { facts.append((strings.or("offer.os", "Minimum OS"), os)) }
        for (k, v) in facts {
            let key = UILabel(k, Role.body, 400, p.muted)
            let row = UIStackView(arrangedSubviews: [key, UILabel(v, Role.body, 400, p.text, lines: 0)])
            // Side by side, or the value under its name at the accessibility sizes.
            if traitCollection.preferredContentSizeCategory.isAccessibilityCategory {
                row.axis = .vertical
                row.spacing = 2
            } else {
                key.widthAnchor.constraint(equalToConstant: 120).isActive = true
                row.alignment = .firstBaseline
            }
            row.semanticContentAttribute = view.semanticContentAttribute
            col.addArrangedSubview(row)
        }

        let box = UIStackView(arrangedSubviews: [UILabel(strings.or("offer.notes", "Important"), Role.label, 600, p.text)]
            + d.important.map { UILabel($0, Role.body, 400, p.muted, lines: 0) })
        box.axis = .vertical
        box.spacing = 6
        box.isLayoutMarginsRelativeArrangement = true
        box.layoutMargins = UIEdgeInsets(top: 12, left: 14, bottom: 12, right: 14)
        let boxBg = UIView().rounded(p.raise, p.radius, border: p.line)
        box.insertSubview(boxBg, at: 0)
        boxBg.frame = box.bounds
        boxBg.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        col.setCustomSpacing(20, after: col.arrangedSubviews.last!)
        col.addArrangedSubview(box)

        // The one primary on the sheet.
        let start = PrimaryButton(strings.or("offer.start", "Start this offer"), p, size: Role.button)
        start.heightAnchor.constraint(greaterThanOrEqualToConstant: 52).isActive = true
        start.titleLabel?.numberOfLines = 0
        start.addAction(for: .touchUpInside) { [weak self] in
            self?.haptic.impactOccurred()
            self?.onStart(d.clickURL, d.name, d.openingLabel)
        }
        let terms = UILabel(strings["offer.terms"], Role.caps, 400, p.faint, lines: 0)
        terms.textAlignment = .center
        footer = foot([start, terms])
    }

    // MARK: Notice

    /// Always says something: the server's notice, else its strings. One way
    /// out, back to the offers, as the sheet's primary.
    private func buildNotice() {
        let p = palette
        let n = response.notice
        let hasNotice = !(n?.title.isEmpty ?? true) || !(n?.body.isEmpty ?? true)
        let title = UILabel(hasNotice ? n?.title : strings.or("notice.unavailable.title", "Offers unavailable"), Role.sheetTitle, 700, p.text, lines: 0)
        title.accessibilityTraits = .header
        col.addArrangedSubview(title)
        col.setCustomSpacing(8, after: title)
        col.addArrangedSubview(UILabel(hasNotice ? n?.body : strings.or("notice.unavailable.body", "Offers cannot be shown right now. Please try again later."), Role.body, 400, p.muted, lines: 0))
        let back = PrimaryButton(strings.or("notice.back", "Back to offers"), p, size: Role.button)
        back.heightAnchor.constraint(greaterThanOrEqualToConstant: 52).isActive = true
        back.accessibilityIdentifier = "playndgain.detail.back"
        back.addAction(for: .touchUpInside) { [weak self] in self?.dismiss(animated: true) }
        footer = foot([back])
    }

    // MARK: Parts

    private func foot(_ views: [UIView]) -> UIView {
        let f = UIStackView(arrangedSubviews: views)
        f.axis = .vertical
        f.spacing = 10
        f.isLayoutMarginsRelativeArrangement = true
        f.layoutMargins = UIEdgeInsets(top: 12, left: 20, bottom: 12, right: 20)
        return f
    }

    private func section(_ title: String) {
        let l = UILabel(title, Role.label, 600, palette.muted)
        l.accessibilityTraits = .header
        col.setCustomSpacing(20, after: col.arrangedSubviews.last!)
        col.addArrangedSubview(l)
        col.setCustomSpacing(8, after: l)
    }

    /// The offer's own icon over its letter, the same tile the list draws.
    private func iconTile(_ name: String, _ url: URL?, _ size: CGFloat) -> UIView {
        let p = palette
        let tile = UIView().rounded(p.tile, p.radius * 0.6)
        tile.clipsToBounds = true
        tile.widthAnchor.constraint(equalToConstant: size).isActive = true
        tile.heightAnchor.constraint(equalToConstant: size).isActive = true
        let letter = UILabel(String(name.prefix(1)).uppercased(), size * 0.4, 700, p.muted)
        letter.adjustsFontForContentSizeCategory = false
        letter.textAlignment = .center
        letter.frame = CGRect(x: 0, y: 0, width: size, height: size)
        tile.addSubview(letter)
        let img = UIImageView(frame: letter.frame)
        img.contentMode = .scaleAspectFill
        img.isHidden = true
        tile.addSubview(img)
        tile.isAccessibilityElement = false
        ImageLoader.load(url) { image in
            guard let image = image else { return }
            img.image = image
            img.isHidden = false
            letter.isHidden = true
        }
        return tile
    }

    private func figure(_ text: String, _ size: CGFloat) -> UILabel {
        let l = UILabel(text, size, 700, palette.text)
        l.font = l.font.withMonospacedDigits()
        // "+6,125" keeps its sign in front on the Arabic wall too.
        l.semanticContentAttribute = .forceLeftToRight
        l.setContentCompressionResistancePriority(.required, for: .horizontal)
        return l
    }

    private func caps(_ text: String) -> UILabel {
        let l = UILabel(text, Role.caps, 600, palette.faint)
        if !Fonts.rtl {
            l.attributedText = NSAttributedString(string: text.uppercased(), attributes: [.kern: 0.6, .font: l.font!, .foregroundColor: palette.faint])
        }
        return l
    }
}
