import UIKit

/// The native offerwall.
///
/// ```swift
/// Playndgain.initialize(appId: "YOUR_APP_ID")
/// Playndgain.setUser("4812") { appId, userId, completion in /* ask your server */ }
/// Playndgain.show()
/// ```
///
/// The SDK never holds your secret key. Your server signs, the app passes the
/// signature through. Rewards arrive at your server by postback; the SDK only
/// tells you when to look.
public enum Playndgain {
    public static let version = "1.0.0"

    static private(set) var appId: String?
    static private(set) var config = PlayndgainConfig()
    static private(set) var userId: String?
    static private(set) var signatureProvider: SignatureProvider?
    /// Bumped whenever the user or provider changes, so a signature cached
    /// for the previous user is never sent for the next one.
    static private(set) var userEpoch = 0

    /// Held weakly, like any UIKit delegate.
    public static weak var delegate: PlayndgainDelegate?

    /// Idempotent. A different app id resets the user.
    public static func initialize(appId: String, config: PlayndgainConfig = .init()) {
        let clean = appId.trimmingCharacters(in: .whitespacesAndNewlines)
        if let current = self.appId, current != clean { reset() }
        self.appId = clean
        self.config = config
    }

    /// Your own opaque, stable identifier: letters, digits and `_ - . @ : |`, at most 191 characters.
    public static func setUser(_ userId: String, signatureProvider: @escaping SignatureProvider) {
        guard Validation.isUserId(userId) else {
            // Never keep showing the previous player's wall after a rejected id.
            reset()
            emit(.invalidUserId)
            return
        }
        self.userId = userId
        self.signatureProvider = signatureProvider
        userEpoch += 1
    }

    /// Presents the wall full screen from `presenter`, or from the top-most view controller.
    public static func show(from presenter: UIViewController? = nil, options: PlayndgainOptions = .init()) {
        guard let appId = appId, !appId.isEmpty else { emit(.notInitialized); return }
        guard userId != nil, signatureProvider != nil else { emit(.userNotSet); return }
        guard options.subIds.count <= 5, options.subIds.allSatisfy(Validation.isSubId) else { emit(.invalidSubId); return }
        guard let host = presenter ?? topViewController() else { emit(.internal); return }

        Fonts.registerOnce()
        let wall = WallViewController(options: options)
        wall.modalPresentationStyle = .fullScreen
        host.present(wall, animated: true)
    }

    /// Forgets the user and the provider. Call it when the player logs out.
    public static func reset() {
        userId = nil
        signatureProvider = nil
        userEpoch += 1
    }

    /// Stored for a later version. In 1.0 nothing reads or sends an advertising ID.
    public static func setAdvertisingIdEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: "com.playndgain.adIdEnabled")
    }

    /// When true the advertising-ID switch is ignored for good.
    public static func setChildDirected(_ value: Bool) {
        UserDefaults.standard.set(value, forKey: "com.playndgain.childDirected")
    }

    static func emit(_ error: PlayndgainError) {
        DispatchQueue.main.async { delegate?.playndgainDidFail(error) }
    }

    private static func topViewController() -> UIViewController? {
        let window = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first { $0.isKeyWindow }
        var top = window?.rootViewController
        while let next = top?.presentedViewController { top = next }
        return top
    }
}

public struct PlayndgainConfig {
    /// Overridable for local testing.
    public var baseURL: URL
    /// Logs request outcomes. Never logs URLs (they carry the signature) or offer names.
    public var debugLogging: Bool

    public init(baseURL: URL = URL(string: "https://wall.playndgain.com")!, debugLogging: Bool = false) {
        self.baseURL = baseURL
        self.debugLogging = debugLogging
    }
}

public enum PlayndgainTheme { case app, light, dark, system }

public struct PlayndgainOptions {
    public var theme: PlayndgainTheme
    /// `en` or `ar`. Nil follows the device.
    public var language: String?
    /// Shown in the header, e.g. "1,200 coins".
    public var balance: String?
    /// Replaces the app name in the header.
    public var title: String?
    /// Up to five, each `[A-Za-z0-9._:@|-]{1,100}`. Echoed as {sub1}..{sub5} on the postback.
    public var subIds: [String]

    public init(theme: PlayndgainTheme = .app, language: String? = nil, balance: String? = nil, title: String? = nil, subIds: [String] = []) {
        self.theme = theme
        self.language = language
        self.balance = balance
        self.title = title
        self.subIds = subIds
    }
}

/// Ask your server for `sha256(appId + userId + secret)` and call `completion` once, on any
/// queue. Complete with an empty string if your app does not require signed walls.
public typealias SignatureProvider = (_ appId: String, _ userId: String, _ completion: @escaping (Result<String, Error>) -> Void) -> Void

public protocol PlayndgainDelegate: AnyObject {
    func playndgainDidOpen()
    func playndgainDidClose()
    /// The player came back from an offer. Refresh the balance from your server. Never credit from this.
    func playndgainRewardCheck()
    func playndgainDidFail(_ error: PlayndgainError)
}

public extension PlayndgainDelegate {
    func playndgainDidOpen() {}
    func playndgainDidClose() {}
    func playndgainRewardCheck() {}
    func playndgainDidFail(_ error: PlayndgainError) {}
}

public enum PlayndgainError: Error {
    case notInitialized, userNotSet, invalidUserId, invalidSubId
    case signatureUnavailable, network, rateLimited, wallUnavailable, `internal`
}
