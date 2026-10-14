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
    /// The two stops of `--wall-primary-fill`.
    var primaryHi: UIColor { Colors.mix(primary, .white, 0.84) }
    var primaryLo: UIColor { Colors.mix(primary, .black, 0.82) }
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

/// `--wall-primary-fill`: the publisher's colour as two stops at 135 degrees.
final class GradientView: UIView {
    override class var layerClass: AnyClass { CAGradientLayer.self }

    init(_ p: Palette) {
        super.init(frame: .zero)
        let g = layer as! CAGradientLayer
        g.colors = [p.primaryHi.cgColor, p.primaryLo.cgColor]
        g.startPoint = CGPoint(x: 0, y: 0)
        g.endPoint = CGPoint(x: 1, y: 1)
        isUserInteractionEnabled = false
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}

/// A pill filled with the primary gradient, the on-primary label over it, and
/// optionally the wall's one glow under it (`--wall-glow`: a 1px ring at 25%
/// and a soft drop of the same colour). Only Start carries the glow.
final class PrimaryButton: PressButton {
    private let fill: GradientView

    init(_ title: String, _ p: Palette, size: CGFloat = 15, glow: Bool = false) {
        fill = GradientView(p)
        super.init(frame: .zero)
        setTitle(title, for: .normal)
        titleLabel?.font = Fonts.font(size, 600)
        setTitleColor(p.onPrimary, for: .normal)
        fill.clipsToBounds = true
        insertSubview(fill, at: 0)
        if glow {
            fill.layer.borderWidth = 1
            fill.layer.borderColor = p.primary.withAlphaComponent(0.25).cgColor
            layer.shadowColor = p.primary.cgColor
            layer.shadowOpacity = 0.55
            layer.shadowOffset = CGSize(width: 0, height: 10)
            layer.shadowRadius = 12
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layoutSubviews() {
        super.layoutSubviews()
        fill.frame = bounds
        fill.layer.cornerRadius = bounds.height / 2
        if layer.shadowOpacity > 0 {
            layer.shadowPath = UIBezierPath(roundedRect: bounds, cornerRadius: bounds.height / 2).cgPath
        }
        sendSubviewToBack(fill)
    }
}

enum Symbols {
    /// An SF Symbol drawn in `color`, sized to sit with Sora at `size`.
    static func image(_ name: String, _ size: CGFloat, _ color: UIColor, weight: UIImage.SymbolWeight = .semibold) -> UIImage? {
        UIImage(systemName: name, withConfiguration: UIImage.SymbolConfiguration(pointSize: size, weight: weight))?
            .withTintColor(color, renderingMode: .alwaysOriginal)
    }
}

/// A filter pill that changes state in place: the selected category takes
/// the primary gradient, the rest are hairlines; a selected sort takes the tile.
final class ChipButton: PressButton {
    private var fill: GradientView?

    func style(on: Bool, ink: Bool, _ p: Palette) {
        if ink {
            if fill == nil {
                let g = GradientView(p)
                g.clipsToBounds = true
                insertSubview(g, at: 0)
                fill = g
            }
            fill?.isHidden = !on
            setTitleColor(on ? p.onPrimary : p.faint, for: .normal)
            layer.borderWidth = on ? 0 : 1
            layer.borderColor = p.line.cgColor
        } else {
            setTitleColor(on ? p.text : p.faint, for: .normal)
            backgroundColor = on ? p.tile : .clear
        }
        accessibilityTraits = on ? [.button, .selected] : .button
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard let f = fill else { return }
        f.frame = bounds
        f.layer.cornerRadius = bounds.height / 2
        sendSubviewToBack(f)
    }
}
