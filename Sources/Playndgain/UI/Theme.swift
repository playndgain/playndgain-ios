import CoreText
import UIKit

/// The wall's palette, derived the way `resources/css/wall-ui.css` derives it
/// from the six values the publisher controls. Nothing here is a new colour.
struct Palette {
    let primary: UIColor, onPrimary: UIColor, bg: UIColor, card: UIColor, text: UIColor
    let dark: Bool
    let radius: CGFloat

    var muted: UIColor { Colors.mix(text, bg, 0.74) }
    var faint: UIColor { Colors.mix(text, bg, 0.64) }
    var line: UIColor { text.withAlphaComponent(0.10) }
    var lineStrong: UIColor { text.withAlphaComponent(0.18) }
    var tile: UIColor { Colors.mix(text, card, 0.08) }
    var raise: UIColor { Colors.mix(text, card, 0.04) }
    var primarySoft: UIColor { Colors.mix(primary, card, 0.14) }
    var ink: UIColor { text }
    var onInk: UIColor { bg }

    init(_ t: ThemeInfo) {
        primary = t.primary; onPrimary = t.onPrimary; bg = t.background; card = t.card; text = t.text
        dark = t.dark; radius = t.radius
    }

    static let fallback = Palette(ThemeInfo(
        primary: Colors.rgb(0xFFB020), onPrimary: Colors.rgb(0x0B0D10), background: Colors.rgb(0x0A0B14),
        card: Colors.rgb(0x11131F), text: Colors.rgb(0xF4F5FA), radius: 14, dark: true
    ))
}

/// The type roles, and nothing between them: title 22/700, sheet title
/// 18/700, row title 15/600, body 13/400, label 12/600, reward 19/700, and
/// the currency's small capitals 11/600. Buttons are 15/600 (design.md §3).
enum Role {
    static let title: CGFloat = 22, sheetTitle: CGFloat = 18, rowTitle: CGFloat = 15
    static let body: CGFloat = 13, label: CGFloat = 12, reward: CGFloat = 19, caps: CGFloat = 11, button: CGFloat = 15
}

/// Motion tokens from `resources/css/wall.css`.
enum Motion {
    static let fast = 0.150, base = 0.260, enter = 0.640, exit = 0.200, stagger = 0.085
    static let staggerCap = 8
    /// --ease-out: cubic-bezier(0.22, 1, 0.36, 1).
    static let easeOut = CAMediaTimingFunction(controlPoints: 0.22, 1, 0.36, 1)
    static var enabled: Bool { !UIAccessibility.isReduceMotionEnabled }
}

/// Sora for Latin. Sora has no Arabic cut, so an RTL wall uses the system
/// face, the same rule `resources/css/wall-ui.css` applies to `[dir='rtl']`.
enum Fonts {
    static var rtl = false
    private static var registered = false

    static func registerOnce() {
        guard !registered else { return }
        registered = true
        for name in ["Sora-Regular", "Sora-SemiBold", "Sora-Bold"] {
            if let url = bundle.url(forResource: name, withExtension: "ttf") {
                CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
            }
        }
    }

    /// `Bundle.module` under SwiftPM, the `Playndgain` resource bundle under CocoaPods.
    static var bundle: Bundle {
        #if SWIFT_PACKAGE
        return Bundle.module
        #else
        let own = Bundle(for: WallViewController.self)
        if let url = own.url(forResource: "Playndgain", withExtension: "bundle"), let b = Bundle(url: url) { return b }
        return own
        #endif
    }

    /// Sora at `size`, scaled with the reader's text size (Dynamic Type) up
    /// to twice the base, past which the rows stop being rows.
    static func font(_ size: CGFloat, _ weight: Int) -> UIFont {
        UIFontMetrics.default.scaledFont(for: base(size, weight), maximumPointSize: size * 2)
    }

    private static func base(_ size: CGFloat, _ weight: Int) -> UIFont {
        if !rtl {
            let name = weight >= 700 ? "Sora-Bold" : weight >= 600 ? "Sora-SemiBold" : "Sora-Regular"
            if let f = UIFont(name: name, size: size) { return f }
        }
        let w: UIFont.Weight = weight >= 700 ? .bold : weight >= 600 ? .semibold : .regular
        return .systemFont(ofSize: size, weight: w)
    }
}

extension UILabel {
    convenience init(_ text: String?, _ size: CGFloat, _ weight: Int, _ color: UIColor, lines: Int = 1) {
        self.init()
        self.text = text
        font = Fonts.font(size, weight)
        textColor = color
        numberOfLines = lines
        adjustsFontForContentSizeCategory = true
        semanticContentAttribute = Fonts.rtl ? .forceRightToLeft : .forceLeftToRight
        textAlignment = .natural
    }
}

extension UIView {
    func rounded(_ color: UIColor, _ radius: CGFloat, border: UIColor? = nil) -> Self {
        backgroundColor = color
        layer.cornerRadius = radius
        if let border = border { layer.borderColor = border.cgColor; layer.borderWidth = 1 }
        return self
    }

    func fadeRise(index: Int) {
        guard Motion.enabled else { return }
        alpha = 0
        transform = CGAffineTransform(translationX: 0, y: 20)
        let delay = Motion.stagger * Double(min(index, Motion.staggerCap))
        UIView.animate(withDuration: Motion.enter, delay: delay, options: [.allowUserInteraction], animations: {
            CATransaction.setAnimationTimingFunction(Motion.easeOut)
            self.alpha = 1
            self.transform = .identity
        })
    }
}

final class PaddedLabel: UILabel {
    var insets = UIEdgeInsets(top: 6, left: 12, bottom: 6, right: 12)
    /// Fully rounded at whatever height the reader's text size gives it.
    var pill = false

    override func layoutSubviews() {
        super.layoutSubviews()
        if pill { layer.cornerRadius = bounds.height / 2 }
    }

    override func drawText(in rect: CGRect) { super.drawText(in: rect.inset(by: insets)) }
    override var intrinsicContentSize: CGSize {
        let s = super.intrinsicContentSize
        return CGSize(width: s.width + insets.left + insets.right, height: s.height + insets.top + insets.bottom)
    }
}

/// The pressed state every tappable shares: a short dim and a 0.97 scale over
/// `--motion-fast`, the dim alone under Reduce Motion. `rest` is the transform
/// the view keeps when not pressed (the RTL flip in a mirrored row).
enum Press {
    static let scale: CGFloat = 0.97
    static let dim: CGFloat = 0.85

    static func apply(_ v: UIView, _ down: Bool, rest: CGAffineTransform = .identity) {
        let changes = {
            v.alpha = down ? dim : 1
            if Motion.enabled { v.transform = down ? rest.scaledBy(x: scale, y: scale) : rest }
        }
        UIView.animate(withDuration: Motion.fast, delay: 0, options: [.allowUserInteraction, .beginFromCurrentState], animations: changes)
    }
}

class PressButton: UIButton {
    var rest: CGAffineTransform = .identity
    /// Extra touch area around a control drawn smaller than 44pt.
    var hitOutset: CGFloat = 0
    /// Fully rounded at whatever height the reader's text size gives it.
    var pill = false

    override func layoutSubviews() {
        super.layoutSubviews()
        if pill { layer.cornerRadius = bounds.height / 2 }
    }

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        bounds.insetBy(dx: -hitOutset, dy: -hitOutset).contains(point)
    }

    /// The title follows the reader's text size like every label does.
    override func setTitle(_ title: String?, for state: UIControl.State) {
        super.setTitle(title, for: state)
        titleLabel?.adjustsFontForContentSizeCategory = true
    }

    override var isHighlighted: Bool {
        didSet { if oldValue != isHighlighted { Press.apply(self, isHighlighted, rest: rest) } }
    }
}

/// A container that behaves like a button: the rail's cards.
final class PressControl: UIControl {
    var rest: CGAffineTransform = .identity

    override var isHighlighted: Bool {
        didSet { if oldValue != isHighlighted { Press.apply(self, isHighlighted, rest: rest) } }
    }
}

/// The primary action: a solid pill in the publisher's colour with the
/// on-primary label. No gradient, no glow, no shadow; it presses like every
/// other control.
final class PrimaryButton: PressButton {
    init(_ title: String, _ p: Palette, size: CGFloat = 15) {
        super.init(frame: .zero)
        setTitle(title, for: .normal)
        titleLabel?.font = Fonts.font(size, 600)
        setTitleColor(p.onPrimary, for: .normal)
        backgroundColor = p.primary
        pill = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}

enum Symbols {
    /// An SF Symbol drawn in `color`, sized to sit with Sora at `size`.
    static func image(_ name: String, _ size: CGFloat, _ color: UIColor, weight: UIImage.SymbolWeight = .semibold) -> UIImage? {
        UIImage(systemName: name, withConfiguration: UIImage.SymbolConfiguration(pointSize: size, weight: weight))?
            .withTintColor(color, renderingMode: .alwaysOriginal)
    }
}

/// A filter pill that changes state in place: a selected category or sort
/// takes the solid primary with the on-primary label; the categories at rest
/// are hairlines, the sorts at rest plain words.
final class ChipButton: PressButton {
    func style(on: Bool, ink: Bool, _ p: Palette) {
        setTitleColor(on ? p.onPrimary : p.faint, for: .normal)
        backgroundColor = on ? p.primary : .clear
        layer.borderWidth = ink && !on ? 1 : 0
        layer.borderColor = p.line.cgColor
        accessibilityTraits = on ? [.button, .selected] : .button
    }
}

/// Offers and History as one segmented control: a tile track with a thumb in
/// the primary tint that slides to the chosen segment over `--motion-base`
/// (at once under Reduce Motion). VoiceOver reads each segment the way it
/// reads a UISegmentedControl's: "Offers, selected, button, 1 of 2".
final class SegmentedTabs: UIControl {
    private let track = UIStackView()
    private let thumb = UIView()
    private var buttons: [UIButton] = []
    private let palette: Palette
    private(set) var selectedIndex: Int
    var onChange: ((Int) -> Void)?

    init(_ titles: [String], selected: Int, _ p: Palette, rtl: Bool) {
        palette = p
        selectedIndex = selected
        super.init(frame: .zero)
        backgroundColor = p.tile
        thumb.backgroundColor = p.primarySoft
        thumb.layer.borderWidth = 1
        thumb.layer.borderColor = p.primary.withAlphaComponent(0.35).cgColor
        thumb.isUserInteractionEnabled = false
        addSubview(thumb)
        track.axis = .horizontal
        track.distribution = .fillEqually
        track.semanticContentAttribute = rtl ? .forceRightToLeft : .forceLeftToRight
        track.translatesAutoresizingMaskIntoConstraints = false
        addSubview(track)
        NSLayoutConstraint.activate([
            track.topAnchor.constraint(equalTo: topAnchor, constant: 3),
            track.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -3),
            track.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 3),
            track.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -3),
            heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
        ])
        for (i, title) in titles.enumerated() {
            let b = UIButton(type: .custom)
            b.setTitle(title, for: .normal)
            b.titleLabel?.font = Fonts.font(Role.body, 600)
            b.titleLabel?.adjustsFontForContentSizeCategory = true
            b.contentEdgeInsets = UIEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)
            b.addAction(for: .touchUpInside) { [weak self] in self?.choose(i) }
            b.addAction(for: .touchDown) { [weak b] in UIView.animate(withDuration: Motion.fast) { b?.alpha = Press.dim } }
            b.addAction(for: [.touchUpInside, .touchUpOutside, .touchCancel]) { [weak b] in UIView.animate(withDuration: Motion.fast) { b?.alpha = 1 } }
            buttons.append(b)
            track.addArrangedSubview(b)
        }
        // Only the segments themselves, not their title labels a second time.
        accessibilityElements = buttons
        for (i, b) in buttons.enumerated() {
            b.accessibilityValue = rtl ? "\(i + 1) من \(titles.count)" : "\(i + 1) of \(titles.count)"
        }
        restyle()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isAccessibilityElement: Bool { get { false } set {} }

    override func layoutSubviews() {
        super.layoutSubviews()
        layer.cornerRadius = bounds.height / 2
        placeThumb()
    }

    private func placeThumb() {
        guard selectedIndex < buttons.count else { return }
        let f = convert(buttons[selectedIndex].frame, from: track)
        thumb.frame = f
        thumb.layer.cornerRadius = f.height / 2
    }

    private func choose(_ i: Int) {
        guard i != selectedIndex else { return }
        select(i, animated: true)
        onChange?(i)
    }

    func select(_ i: Int, animated: Bool) {
        selectedIndex = i
        restyle()
        layoutIfNeeded()
        guard animated, Motion.enabled else { return placeThumb() }
        UIView.animate(withDuration: Motion.base, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction], animations: {
            CATransaction.setAnimationTimingFunction(Motion.easeOut)
            self.placeThumb()
        })
    }

    private func restyle() {
        for (i, b) in buttons.enumerated() {
            let on = i == selectedIndex
            b.setTitleColor(on ? palette.text : palette.muted, for: .normal)
            b.accessibilityTraits = on ? [.button, .selected] : .button
        }
    }
}

/// A view rounded to a full pill at whatever height it ends up.
final class Pill: UIView {
    override func layoutSubviews() {
        super.layoutSubviews()
        layer.cornerRadius = bounds.height / 2
    }
}
