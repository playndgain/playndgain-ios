import Foundation
import UIKit

/// `/sdk/v1` over one shared ephemeral `URLSession`: no cookies, no cache.
final class ApiClient {
    /// One session for every wall screen, so a dismissed screen leaves nothing behind.
    static let session: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 15
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        cfg.urlCache = nil
        cfg.httpCookieStorage = nil
        cfg.httpShouldSetCookies = false
        return URLSession(configuration: cfg)
    }()

    private let options: PlayndgainOptions
    private let device = DeviceInfo.current
    /// The signature and the user generation it was taken for.
    private var sig: (value: String, epoch: Int)?

    init(options: PlayndgainOptions) {
        self.options = options
    }

    func wall(sort: String?, systemDark: Bool, _ done: @escaping (Result<WallResponse, PlayndgainError>) -> Void) {
        request("GET", "wall", extra: sort.map { [("sort", $0)] } ?? [], systemDark: systemDark, done)
    }
    func offer(_ id: Int, systemDark: Bool, _ done: @escaping (Result<WallResponse, PlayndgainError>) -> Void) {
        request("GET", "offers/\(id)", systemDark: systemDark, done)
    }
    func history(systemDark: Bool, _ done: @escaping (Result<WallResponse, PlayndgainError>) -> Void) {
        request("GET", "history", systemDark: systemDark, done)
    }
    func consent(accept: Bool, systemDark: Bool, _ done: @escaping (Result<WallResponse, PlayndgainError>) -> Void) {
        request("POST", "consent", form: "action=" + (accept ? "accept" : "decline"), systemDark: systemDark, done)
    }

    private func request(_ method: String, _ path: String, extra: [(String, String)] = [], form: String? = nil,
                         systemDark: Bool, _ done: @escaping (Result<WallResponse, PlayndgainError>) -> Void) {
        signature { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .failure(let e): DispatchQueue.main.async { done(.failure(e)) }
            case .success(let sig):
                // The query carries appid, userid and sig: https only, except
                // a loopback wall for local testing (same rule as clicks).
                guard Links.isAllowedBase(Playndgain.config.baseURL) else {
                    DispatchQueue.main.async { done(.failure(.internal)) }
                    return
                }
                guard var comps = URLComponents(url: Playndgain.config.baseURL.appendingPathComponent("sdk/v1/" + path), resolvingAgainstBaseURL: false) else {
                    DispatchQueue.main.async { done(.failure(.internal)) }
                    return
                }
                // Everything in the query, the POST included: the wall's per-app
                // rate limiter keys on the query string's appid.
                comps.queryItems = Fields.query(
                    appId: Playndgain.appId ?? "", userId: Playndgain.userId ?? "", sig: sig, options: self.options,
                    model: self.device.model, hint: self.device.hint, ds: self.device.ds, version: Playndgain.version,
                    systemDark: systemDark, extra: extra
                )
                // `+` is literal in a query component; the wall reads it as a space.
                comps.percentEncodedQuery = comps.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
                guard let url = comps.url else {
                    DispatchQueue.main.async { done(.failure(.internal)) }
                    return
                }
                var req = URLRequest(url: url)
                req.httpMethod = method
                req.setValue("application/json", forHTTPHeaderField: "Accept")
                req.setValue(self.device.userAgent, forHTTPHeaderField: "User-Agent")
                if let form = form {
                    req.httpBody = form.data(using: .utf8)
                    req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
                }
                ApiClient.session.dataTask(with: req) { [weak self] data, response, error in
                    let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                    self?.log("\(method) \(path) -> \(code)")
                    let out = ApiClient.outcome(http: code, data: data, failed: error != nil)
                    DispatchQueue.main.async { done(out) }
                }.resume()
            }
        }
    }

    /// Maps one HTTP exchange to what the screen gets.
    ///
    /// The body decides, not the status code. A JSON envelope is passed through
    /// so its notice can show; a status the host app should also hear about is
    /// carried in `WallResponse.error`. Anything that is not our envelope (a
    /// challenge page, a proxy error, an HTML 200) is `.wallUnavailable`,
    /// except a bare 429, which is `.rateLimited`.
    static func outcome(http code: Int, data: Data?, failed: Bool) -> Result<WallResponse, PlayndgainError> {
        if failed { return .failure(.network) }
        guard let data = data, var r = try? Parser.parse(http: code, data: data) else {
            return .failure(code == 429 ? .rateLimited : .wallUnavailable)
        }
        switch r.status {
        case "rate_limited":
            r.error = .rateLimited
        case "invalid" where r.app == nil:
            // The wall answers a refused signature with 403. A malformed user,
            // an unknown app or path (400/404/405) is not the signature's fault.
            r.error = code == 403 ? .signatureUnavailable : .wallUnavailable
        default:
            break
        }
        return .success(r)
    }

    /// Asks the host app once per screen and user. The provider may answer on
    /// any queue; `finish` only ever runs on main, so `finished` and `sig`
    /// have a single owner and `done` runs once.
    private func signature(_ done: @escaping (Result<String, PlayndgainError>) -> Void) {
        let epoch = Playndgain.userEpoch
        if let sig = sig, sig.epoch == epoch { done(.success(sig.value)); return }
        sig = nil
        guard let provider = Playndgain.signatureProvider else { done(.failure(.userNotSet)); return }
        var finished = false
        let finish: (Result<String, PlayndgainError>) -> Void = { [weak self] r in
            guard !finished else { return }
            finished = true
            if case .success(let s) = r, Playndgain.userEpoch == epoch { self?.sig = (s, epoch) }
            done(r)
        }
        DispatchQueue.main.async {
            provider(Playndgain.appId ?? "", Playndgain.userId ?? "") { result in
                let mapped: Result<String, PlayndgainError> = result
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
                    .mapError { _ in .signatureUnavailable }
                if Thread.isMainThread { finish(mapped) } else { DispatchQueue.main.async { finish(mapped) } }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { finish(.failure(.signatureUnavailable)) }
    }

    private func log(_ message: String) {
        // Never the URL: it carries the signature.
        if Playndgain.config.debugLogging { NSLog("Playndgain: %@", message) }
    }
}

/// Offer icons: small, proxied by the wall, cached in memory only.
enum ImageLoader {
    private static let cache = NSCache<NSURL, UIImage>()
    private static let session: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 15
        cfg.urlCache = nil
        cfg.httpCookieStorage = nil
        cfg.httpShouldSetCookies = false
        return URLSession(configuration: cfg)
    }()

    static func load(_ url: URL?, _ done: @escaping (UIImage?) -> Void) {
        guard let url = url, Links.isWebURL(url) else { done(nil); return }
        if let hit = cache.object(forKey: url as NSURL) { done(hit); return }
        session.dataTask(with: url) { data, _, _ in
            // Icons are small; anything bigger is not an icon and is not decoded.
            let img = data.flatMap { $0.count <= 2 * 1024 * 1024 ? UIImage(data: $0) : nil }
            if let img = img { cache.setObject(img, forKey: url as NSURL) }
            DispatchQueue.main.async { done(img) }
        }.resume()
    }
}

/// Which server-sent URLs the SDK acts on.
enum Links {
    /// Icons: http or https with a host. Never `file:`, `data:` or an app scheme.
    static func isWebURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), url.host?.isEmpty == false else { return false }
        return scheme == "https" || scheme == "http"
    }

    /// The wall itself: `https`, or plain http to a loopback host only.
    static func isAllowedBase(_ base: URL) -> Bool {
        guard let host = base.host?.lowercased(), !host.isEmpty else { return false }
        switch base.scheme?.lowercased() {
        case "https": return true
        case "http": return ["localhost", "127.0.0.1", "::1"].contains(host)
        default: return false
        }
    }

    /// Clicks leave the app only for `https` on the wall's own host. Plain http
    /// passes only when the configured base is itself an http loopback wall,
    /// which is local testing.
    static func isAllowedClick(_ url: URL, base: URL) -> Bool {
        guard let host = url.host?.lowercased(), host == base.host?.lowercased() else { return false }
        switch url.scheme?.lowercased() {
        case "https": return true
        case "http": return base.scheme?.lowercased() == "http" && ["localhost", "127.0.0.1", "::1"].contains(host)
        default: return false
        }
    }
}

/// Tags each screen load so only the newest answer is rendered.
struct LoadTickets {
    private(set) var current = 0

    mutating func next() -> Int {
        current += 1
        return current
    }

    func isCurrent(_ ticket: Int) -> Bool { ticket == current }
}
