import UIKit

/// The offer detail as a sheet: steps, notes, who it is for, the Important
/// box, and a Start button that leaves the app.
final class DetailViewController: UIViewController {
    private let response: WallResponse
    private let palette: Palette
    private let strings: Strings
    private let currency: String
    private let onStart: (URL?) -> Void

    init(response: WallResponse, palette: Palette, strings: Strings, currency: String, onStart: @escaping (URL?) -> Void) {
        self.response = response
        self.palette = palette
        self.strings = strings
        self.currency = currency
        self.onStart = onStart
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        let p = palette
        view.backgroundColor = p.card
        view.semanticContentAttribute = Fonts.rtl ? .forceRightToLeft : .forceLeftToRight

        guard response.status == "ok", let d = response.detail else {
            // Always says something: the server's notice, else its strings.
            let n = response.notice
            let hasNotice = !(n?.title.isEmpty ?? true) || !(n?.body.isEmpty ?? true)
            let title = hasNotice ? n?.title : strings.or("notice.unavailable.title", "Offers unavailable")
            let body = hasNotice ? n?.body : strings.or("notice.unavailable.body", "Offers cannot be shown right now. Please try again later.")
            let col = UIStackView(arrangedSubviews: [UILabel(title, 17, 700, p.text, lines: 0), UILabel(body, 13.5, 400, p.muted, lines: 0)])
            col.axis = .vertical
            col.spacing = 8
            place(col, in: view, top: 32)
            return
        }

        let col = UIStackView()
        col.axis = .vertical
        col.spacing = 6
        col.isLayoutMarginsRelativeArrangement = true
        col.layoutMargins = UIEdgeInsets(top: 24, left: 20, bottom: 16, right: 20)

        let head = UIStackView()
        head.spacing = 14
        head.alignment = .center
        head.semanticContentAttribute = view.semanticContentAttribute
        let tile = UILabel(String(d.name.prefix(1)).uppercased(), 22, 700, p.muted)
        tile.textAlignment = .center
        _ = tile.rounded(p.tile, p.radius * 0.6)
        tile.clipsToBounds = true
        tile.widthAnchor.constraint(equalToConstant: 56).isActive = true
        tile.heightAnchor.constraint(equalToConstant: 56).isActive = true
        head.addArrangedSubview(tile)
        let upTo = d.steps.count > 1 ? strings.or("up_to", "Up to") + " " : ""
        let ht = UIStackView(arrangedSubviews: [UILabel(d.name, 18, 700, p.text, lines: 2), UILabel("\(upTo)\(d.rewardLabel) \(currency)", 14, 600, p.muted)])
        ht.axis = .vertical
        ht.spacing = 4
        head.addArrangedSubview(ht)
        col.addArrangedSubview(head)

        func section(_ title: String) {
            let l = UILabel(title, 13, 600, p.muted)
            col.setCustomSpacing(20, after: col.arrangedSubviews.last!)
            col.addArrangedSubview(l)
            col.setCustomSpacing(8, after: l)
        }

        section(strings.or("offer.steps", "What you have to do"))
        for (i, step) in d.steps.enumerated() {
            let num = UILabel("\(i + 1)", 12, 700, p.text)
            num.textAlignment = .center
            _ = num.rounded(p.tile, 13)
            num.clipsToBounds = true
            num.widthAnchor.constraint(equalToConstant: 26).isActive = true
            num.heightAnchor.constraint(equalToConstant: 26).isActive = true
            let name = UILabel(step.0, 14, 400, p.text, lines: 0)
            name.setContentHuggingPriority(.defaultLow, for: .horizontal)
            let reward = UILabel(step.1, 14, 600, p.text)
            reward.font = reward.font.withMonospacedDigits()
            let row = UIStackView(arrangedSubviews: [num, name, reward])
            row.spacing = 12
            row.alignment = .center
            row.semanticContentAttribute = view.semanticContentAttribute
            col.addArrangedSubview(row)
        }
        if let note = d.stepsNote { col.addArrangedSubview(UILabel(note, 12.5, 400, p.faint, lines: 0)) }

        if !d.notes.isEmpty {
            section(strings.or("offer.how", "Before you start"))
            for n in d.notes { col.addArrangedSubview(UILabel("•  " + n, 13.5, 400, p.text, lines: 0)) }
        }

        section(strings.or("offer.requirements", "Who this is for"))
        let devices = d.devices.isEmpty ? strings.or("offer.any_device", "Any device") : d.devices.map { strings.or("device.\($0)", $0) }.joined(separator: ", ")
        let countries = d.countries.isEmpty ? strings.or("offer.worldwide", "Worldwide")
            : d.countries.prefix(8).joined(separator: ", ") + (d.countries.count > 8 ? " +\(d.countries.count - 8)" : "")
        var facts = [(strings.or("offer.devices", "Devices"), devices), (strings.or("offer.countries", "Countries"), countries)]
        if let os = d.osMin { facts.append((strings.or("offer.os", "Minimum OS"), os)) }
        for (k, v) in facts {
            let key = UILabel(k, 13, 400, p.muted)
            key.widthAnchor.constraint(equalToConstant: 120).isActive = true
            let row = UIStackView(arrangedSubviews: [key, UILabel(v, 13, 400, p.text, lines: 0)])
            row.semanticContentAttribute = view.semanticContentAttribute
            col.addArrangedSubview(row)
        }

        let box = UIStackView(arrangedSubviews: [UILabel(strings.or("offer.notes", "Important"), 13, 600, p.text)] + d.important.map { UILabel($0, 12.5, 400, p.muted, lines: 0) })
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

        let scroll = UIScrollView()
        col.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(col)
        NSLayoutConstraint.activate([
            col.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
            col.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
            col.leadingAnchor.constraint(equalTo: scroll.frameLayoutGuide.leadingAnchor),
            col.trailingAnchor.constraint(equalTo: scroll.frameLayoutGuide.trailingAnchor),
        ])

        let start = UIButton(type: .custom)
        start.setTitle(strings.or("offer.start", "Start this offer"), for: .normal)
        start.titleLabel?.font = Fonts.font(15, 600)
        start.setTitleColor(p.onPrimary, for: .normal)
        _ = start.rounded(p.primary, 26)
        start.heightAnchor.constraint(equalToConstant: 52).isActive = true
        start.addAction(for: .touchUpInside) { [weak self] in self?.onStart(d.clickURL) }
        let terms = UILabel(strings["offer.terms"], 11, 400, p.faint, lines: 0)
        terms.textAlignment = .center

        let footer = UIStackView(arrangedSubviews: [start, terms])
        footer.axis = .vertical
        footer.spacing = 10
        footer.isLayoutMarginsRelativeArrangement = true
        footer.layoutMargins = UIEdgeInsets(top: 8, left: 20, bottom: 12, right: 20)

        let outer = UIStackView(arrangedSubviews: [scroll, footer])
        outer.axis = .vertical
        outer.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(outer)
        NSLayoutConstraint.activate([
            outer.topAnchor.constraint(equalTo: view.topAnchor),
            outer.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            outer.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            outer.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
        ])
    }

    private func place(_ v: UIView, in parent: UIView, top: CGFloat) {
        v.translatesAutoresizingMaskIntoConstraints = false
        parent.addSubview(v)
        NSLayoutConstraint.activate([
            v.topAnchor.constraint(equalTo: parent.topAnchor, constant: top),
            v.leadingAnchor.constraint(equalTo: parent.leadingAnchor, constant: 24),
            v.trailingAnchor.constraint(equalTo: parent.trailingAnchor, constant: -24),
        ])
    }
}
