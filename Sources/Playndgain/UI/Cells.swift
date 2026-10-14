import UIKit

/// What a row needs from the screen to draw itself: the palette, the words,
/// the currency, the direction and whether the reader's text is at an
/// accessibility size. Cells build their views once and only configure them.
struct RowStyle {
    let palette: Palette
    let strings: Strings
    let currency: String
    let rtl: Bool
    let big: Bool

    var direction: UISemanticContentAttribute { rtl ? .forceRightToLeft : .forceLeftToRight }

    func speech(_ name: String, _ reward: String, upTo: Bool) -> String {
        let up = upTo ? strings.or("up_to", "Up to") + " " : ""
        return "\(name), \(up)\(reward) \(currency)"
    }

    /// 11/600 small capitals: the currency and "Up to".
    func caps(_ label: UILabel, _ text: String) {
        label.font = Fonts.font(Role.caps, 600)
        label.textColor = palette.faint
        if rtl {
            label.attributedText = nil
            label.text = text
        } else {
            label.attributedText = NSAttributedString(string: text.uppercased(), attributes: [.kern: 0.6, .font: label.font!, .foregroundColor: palette.faint])
        }
    }
}

/// The offer's icon over its letter, at a fixed size whatever the reading size.
final class IconTile: UIView {
    private let letter = UILabel(nil, 16, 700, .clear)
    private let image = UIImageView()
    private var url: URL?
    private let side: CGFloat

    init(_ side: CGFloat) {
        self.side = side
        super.init(frame: .zero)
        clipsToBounds = true
        isAccessibilityElement = false
        widthAnchor.constraint(equalToConstant: side).isActive = true
        heightAnchor.constraint(equalToConstant: side).isActive = true
        letter.adjustsFontForContentSizeCategory = false
        letter.adjustsFontSizeToFitWidth = true
        letter.textAlignment = .center
        letter.frame = CGRect(x: 0, y: 0, width: side, height: side)
        image.frame = letter.frame
        image.contentMode = .scaleAspectFill
        addSubview(letter)
        addSubview(image)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func configure(_ name: String, _ url: URL?, _ p: Palette) {
        backgroundColor = p.tile
        layer.cornerRadius = p.radius * 0.6
        letter.text = String(name.prefix(1)).uppercased()
        letter.font = UIFont(name: Fonts.rtl ? "" : "Sora-Bold", size: side * 0.4) ?? .systemFont(ofSize: side * 0.4, weight: .bold)
        letter.textColor = p.muted
        guard url != self.url || image.image == nil else { return }
        self.url = url
        image.image = nil
        image.isHidden = true
        letter.isHidden = false
        ImageLoader.load(url, points: side) { [weak self] img in
            // A reused tile may have moved on to another offer since.
            guard let self = self, self.url == url, let img = img else { return }
            self.image.image = img
            self.image.isHidden = false
            self.letter.isHidden = true
        }
    }
}

/// The ledger column: "Up to", "+6,125" and the currency, stacked and flush
/// to the row's end, or on one baseline at the accessibility sizes.
final class Ledger: UIStackView {
    private let upTo = UILabel(nil, Role.caps, 600, .clear)
    private let figure = UILabel(nil, Role.reward, 700, .clear)
    private let unit = UILabel(nil, Role.caps, 600, .clear)
    private var snug: NSLayoutConstraint!
    private var floor: NSLayoutConstraint!

    init() {
        super.init(frame: .zero)
        [upTo, figure, unit].forEach(addArrangedSubview)
        // "+6,125" keeps its sign in front on the Arabic wall too.
        figure.semanticContentAttribute = .forceLeftToRight
        [upTo, figure, unit].forEach {
            $0.setContentCompressionResistancePriority(.required, for: .horizontal)
            $0.setContentHuggingPriority(.required, for: .horizontal)
        }
        // A stack has no intrinsic size, so hugging does not hold it: pin the
        // column to 72, growing only when a figure needs more.
        floor = widthAnchor.constraint(greaterThanOrEqualToConstant: 72)
        snug = widthAnchor.constraint(equalToConstant: 72)
        snug.priority = .defaultHigh
    }

    required init(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func configure(_ label: String, upTo up: Bool, inline: Bool, size: CGFloat = Role.reward, color: UIColor? = nil, sign: String = "+", _ s: RowStyle) {
        upTo.isHidden = !up
        if up { s.caps(upTo, s.strings.or("up_to", "Up to")) }
        figure.text = sign + label
        figure.font = Fonts.font(size, 700).withMonospacedDigits()
        figure.textColor = color ?? s.palette.text
        s.caps(unit, s.currency)
        if inline {
            axis = .horizontal
            alignment = .firstBaseline
            spacing = 6
            semanticContentAttribute = s.direction
            floor.isActive = false
            snug.isActive = false
        } else {
            axis = .vertical
            alignment = s.rtl ? .leading : .trailing
            spacing = 0
            floor.isActive = true
            snug.isActive = true
        }
    }
}

/// One offer in the list. The whole row is the button; the chevron is
/// decoration. Built once, configured for every offer it shows.
final class OfferCell: UITableViewCell {
    static let id = "offer"
    let card = UIStackView()
    private let bg = UIView()
    private let edge = UIView()
    private let icon = IconTile(48)
    private let inner = UIStackView()
    private let text = UIStackView()
    private let name = UILabel(nil, Role.rowTitle, 600, .clear, lines: 2)
    private let note = UILabel(nil, Role.body, 400, .clear, lines: 2)
    private let meta = UILabel(nil, Role.label, 400, .clear)
    private let ledger = Ledger()
    private let disc = UIView()
    private let glyph = UIImageView()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        backgroundColor = .clear
        selectionStyle = .none
        card.axis = .horizontal
        card.alignment = .center
        card.spacing = 12
        card.isLayoutMarginsRelativeArrangement = true
        card.layoutMargins = UIEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        card.insertSubview(bg, at: 0)
        bg.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        bg.layer.borderWidth = 1

        // A pinned offer carries the primary on its leading edge, inset like
        // the web wall's, so the row's words stay on every other row's axis.
        edge.layer.cornerRadius = 1.5
        edge.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(edge)
        NSLayoutConstraint.activate([
            edge.widthAnchor.constraint(equalToConstant: 3),
            edge.topAnchor.constraint(equalTo: card.topAnchor, constant: 12),
            edge.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -12),
            edge.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 2),
        ])

        text.axis = .vertical
        text.spacing = 4
        [name, note, meta].forEach {
            $0.lineBreakMode = .byTruncatingTail
            $0.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            text.addArrangedSubview($0)
        }
        text.setContentHuggingPriority(.defaultLow, for: .horizontal)
        text.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        inner.addArrangedSubview(text)
        inner.addArrangedSubview(ledger)
        inner.setContentHuggingPriority(.defaultLow, for: .horizontal)

        // Decoration only: never starts the offer, hidden from accessibility.
        disc.layer.cornerRadius = 14
        disc.isUserInteractionEnabled = false
        disc.isAccessibilityElement = false
        glyph.translatesAutoresizingMaskIntoConstraints = false
        disc.addSubview(glyph)
        NSLayoutConstraint.activate([
            disc.widthAnchor.constraint(equalToConstant: 28),
            disc.heightAnchor.constraint(equalToConstant: 28),
            glyph.centerXAnchor.constraint(equalTo: disc.centerXAnchor),
            glyph.centerYAnchor.constraint(equalTo: disc.centerYAnchor),
        ])

        card.addArrangedSubview(icon)
        card.addArrangedSubview(inner)
        card.setCustomSpacing(8, after: inner)
        card.addArrangedSubview(disc)
        card.isAccessibilityElement = true
        card.accessibilityTraits = .button
        card.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(card)
        NSLayoutConstraint.activate([
            card.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 4),
            card.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -4),
            card.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            card.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func prepareForReuse() {
        super.prepareForReuse()
        card.layer.removeAllAnimations()
        card.alpha = 1
        card.transform = .identity
    }

    /// The row presses like a button.
    override func setHighlighted(_ highlighted: Bool, animated: Bool) {
        super.setHighlighted(highlighted, animated: animated)
        Press.apply(card, highlighted)
    }

    func configure(_ o: OfferCard, metaParts: [String], _ s: RowStyle) {
        let p = s.palette
        contentView.semanticContentAttribute = s.direction
        card.semanticContentAttribute = s.direction
        inner.semanticContentAttribute = s.direction
        bg.backgroundColor = p.card
        bg.layer.cornerRadius = p.radius
        bg.layer.borderColor = p.line.cgColor
        edge.backgroundColor = p.primary
        edge.isHidden = !(o.featured && !o.test)
        icon.configure(o.name, o.iconURL, p)

        name.text = o.name
        name.font = Fonts.font(Role.rowTitle, 600)
        name.textColor = p.text
        note.text = o.instructions
        note.font = Fonts.font(Role.body, 400)
        note.textColor = p.muted
        note.isHidden = o.instructions.isEmpty
        meta.attributedText = OfferCell.metaLine(metaParts, people: o.peopleLabel, font: Fonts.font(Role.label, 400), color: p.faint)
        meta.isHidden = metaParts.isEmpty && o.peopleLabel == nil
        [name, note, meta].forEach { $0.semanticContentAttribute = s.direction; $0.textAlignment = .natural }

        // At the accessibility sizes the figure goes under the words, so
        // neither has to squeeze the other into a column of letters.
        inner.axis = s.big ? .vertical : .horizontal
        inner.alignment = s.big ? (s.rtl ? .trailing : .leading) : .center
        inner.spacing = s.big ? 8 : 12
        ledger.configure(o.rewardLabel, upTo: o.upTo, inline: s.big, s)

        disc.backgroundColor = p.tile
        glyph.image = Symbols.image("chevron.right", 11, p.text, weight: .bold)?.imageFlippedForRightToLeftLayoutDirection()
        glyph.semanticContentAttribute = s.direction
        card.accessibilityLabel = s.speech(o.name, o.rewardLabel, upTo: o.upTo)
    }

    /// "Featured · 4 steps · (person) 12": the people count wears a person
    /// glyph, so "+12" reads as people who joined rather than a reward.
    static func metaLine(_ parts: [String], people: String?, font: UIFont, color: UIColor) -> NSAttributedString {
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
}

/// The featured rail: a title and a sideways row of cards. The cards are
/// rebuilt only when the offers or the style behind them change.
final class RailCell: UITableViewCell {
    static let id = "rail"
    private let title = UILabel(nil, Role.label, 600, .clear)
    private let scroll = UIScrollView()
    private let row = UIStackView()
    private var key = ""

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        backgroundColor = .clear
        selectionStyle = .none
        let titleWrap = UIStackView(arrangedSubviews: [title])
        titleWrap.isLayoutMarginsRelativeArrangement = true
        titleWrap.layoutMargins = UIEdgeInsets(top: 4, left: 16, bottom: 0, right: 16)
        scroll.showsHorizontalScrollIndicator = false
        row.axis = .horizontal
        row.spacing = 8
        row.alignment = .fill
        row.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(row)
        let wrap = UIStackView(arrangedSubviews: [titleWrap, scroll])
        wrap.axis = .vertical
        wrap.spacing = 8
        wrap.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(wrap)
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
            row.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
            row.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor, constant: 16),
            row.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: -16),
            // As tall as its tallest card at the reader's text size.
            scroll.contentLayoutGuide.heightAnchor.constraint(equalTo: scroll.frameLayoutGuide.heightAnchor),
            scroll.heightAnchor.constraint(equalTo: row.heightAnchor),
            wrap.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 4),
            wrap.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -8),
            wrap.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            wrap.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func configure(_ offers: [OfferCard], _ s: RowStyle, open: @escaping (Int) -> Void) {
        let p = s.palette
        title.text = s.strings.or("featured_offers", "Featured offers")
        title.font = Fonts.font(Role.label, 600)
        title.textColor = p.muted
        title.semanticContentAttribute = s.direction
        title.textAlignment = .natural
        let key = offers.map { "\($0.id)" }.joined(separator: ",") + "|\(s.rtl)|\(s.big)|\(s.currency)|\(p.radius)|\(p.dark)"
        guard key != self.key else { return }
        self.key = key
        row.arrangedSubviews.forEach { $0.removeFromSuperview() }
        scroll.transform = .identity
        row.semanticContentAttribute = s.direction
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
            let icon = IconTile(44)
            icon.configure(o.name, o.iconURL, p)
            let ledger = Ledger()
            ledger.configure(o.rewardLabel, upTo: o.upTo, inline: false, s)
            let top = UIStackView(arrangedSubviews: [icon, UIView(), ledger])
            top.alignment = .center
            top.semanticContentAttribute = s.direction
            card.addArrangedSubview(top)
            card.setCustomSpacing(12, after: top)
            card.addArrangedSubview(UILabel(o.name, Role.rowTitle, 600, p.text))
            card.addArrangedSubview(UILabel(o.instructions, Role.body, 400, p.muted))
            control.widthAnchor.constraint(equalToConstant: 220).isActive = true
            control.addAction(for: .touchUpInside) { open(o.id) }
            control.isAccessibilityElement = true
            control.accessibilityLabel = s.speech(o.name, o.rewardLabel, upTo: o.upTo)
            control.accessibilityTraits = .button
            row.addArrangedSubview(control)
        }
        mirrorForRTL(scroll, row)
    }
}

/// A title and a line under it, centred: the empty and no-results states.
final class EmptyContent: UIStackView {
    private let title = UILabel(nil, Role.sheetTitle, 700, .clear, lines: 0)
    private let body = UILabel(nil, Role.body, 400, .clear, lines: 0)

    init() {
        super.init(frame: .zero)
        axis = .vertical
        spacing = 8
        alignment = .center
        isLayoutMarginsRelativeArrangement = true
        layoutMargins = UIEdgeInsets(top: 56, left: 32, bottom: 32, right: 32)
        [title, body].forEach { $0.textAlignment = .center; addArrangedSubview($0) }
        title.accessibilityTraits = .header
    }

    required init(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func configure(_ t: String, _ b: String, _ p: Palette) {
        title.text = t
        title.font = Fonts.font(Role.sheetTitle, 700)
        title.textColor = p.text
        body.text = b
        body.font = Fonts.font(Role.body, 400)
        body.textColor = p.muted
    }
}

final class EmptyCell: UITableViewCell {
    static let id = "empty"
    let content = EmptyContent()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        backgroundColor = .clear
        selectionStyle = .none
        content.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: contentView.topAnchor),
            content.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            content.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}

/// One History row: the offer, a status pill and the date, and the money.
final class HistoryCell: UITableViewCell {
    static let id = "history"
    let row = UIStackView()
    private let icon = IconTile(40)
    private let name = UILabel(nil, Role.rowTitle, 600, .clear)
    private let pill = PaddedLabel(nil, Role.caps, 600, .clear)
    private let when = UILabel(nil, Role.label, 400, .clear)
    private let reason = UILabel(nil, Role.label, 400, .clear, lines: 0)
    private let meta = UIStackView()
    private let text = UIStackView()
    private let ledger = Ledger()
    private let line = UIView()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        backgroundColor = .clear
        selectionStyle = .none
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = 12
        row.isLayoutMarginsRelativeArrangement = true
        row.layoutMargins = UIEdgeInsets(top: 12, left: 16, bottom: 12, right: 16)
        name.lineBreakMode = .byTruncatingTail
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        pill.insets = UIEdgeInsets(top: 3, left: 8, bottom: 3, right: 8)
        pill.pill = true
        pill.clipsToBounds = true
        pill.setContentCompressionResistancePriority(.required, for: .horizontal)
        when.lineBreakMode = .byTruncatingTail
        when.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        meta.addArrangedSubview(pill)
        meta.addArrangedSubview(when)
        meta.spacing = 8
        meta.alignment = .center
        text.axis = .vertical
        text.spacing = 4
        [name, meta, reason].forEach(text.addArrangedSubview)
        text.setContentHuggingPriority(.defaultLow, for: .horizontal)
        text.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        [icon, text, ledger].forEach(row.addArrangedSubview)
        row.isAccessibilityElement = true
        line.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(line)
        row.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(row)
        NSLayoutConstraint.activate([
            line.heightAnchor.constraint(equalToConstant: 1),
            line.bottomAnchor.constraint(equalTo: row.bottomAnchor),
            line.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 16),
            line.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -16),
            row.topAnchor.constraint(equalTo: contentView.topAnchor),
            row.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            row.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func prepareForReuse() {
        super.prepareForReuse()
        row.layer.removeAllAnimations()
        row.alpha = 1
        row.transform = .identity
    }

    func configure(_ r: HistoryRow, date: String?, _ s: RowStyle) {
        let p = s.palette
        [row, meta].forEach { $0.semanticContentAttribute = s.direction }
        text.alignment = s.rtl ? .trailing : .leading
        icon.configure(r.name, r.iconURL, p)
        name.text = r.name
        name.font = Fonts.font(Role.rowTitle, 600)
        name.textColor = p.text

        // Status is a word on a quiet pill, never a new colour: credited takes
        // the primary, waiting the faint text, refused the muted text.
        pill.text = r.statusLabel
        pill.font = Fonts.font(Role.caps, 600)
        pill.textColor = HistoryCell.statusColor(r.status, p)
        pill.backgroundColor = p.tile
        let whenText = [r.partner, date].compactMap { $0 }.joined(separator: "  ·  ")
        when.text = whenText
        when.font = Fonts.font(Role.label, 400)
        when.textColor = p.muted
        when.isHidden = whenText.isEmpty
        reason.text = r.reason
        reason.font = Fonts.font(Role.label, 400)
        reason.textColor = p.faint
        reason.isHidden = r.reason == nil
        [name, when, reason].forEach { $0.semanticContentAttribute = s.direction; $0.textAlignment = .natural }

        var spoken = [r.name, r.statusLabel]
        if let reward = r.rewardLabel {
            // Money keeps the primary. A reversed amount is taken back: a
            // minus sign and the muted colour, with the word beside it.
            let reversed = r.status == "reversed"
            ledger.isHidden = false
            ledger.configure(reward, upTo: false, inline: false, size: Role.rowTitle, color: reversed ? p.muted : p.primary, sign: reversed ? "\u{2212}" : "+", s)
            spoken.append("\(reversed ? "\u{2212}" : "+")\(reward) \(s.currency)")
        } else {
            ledger.isHidden = true
        }
        line.backgroundColor = p.line
        row.accessibilityLabel = spoken.joined(separator: ", ")
    }

    static func statusColor(_ status: String, _ p: Palette) -> UIColor {
        switch status {
        case "approved": return p.primary
        case "rejected", "reversed": return p.muted
        default: return p.faint
        }
    }
}

/// UIScrollView does not mirror for RTL: it starts at the left and so shows the
/// end of a right-to-left row first. Flip the scroller and flip each item back,
/// so the first item sits at the right edge and reads normally.
func mirrorForRTL(_ scroll: UIScrollView, _ row: UIStackView) {
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
