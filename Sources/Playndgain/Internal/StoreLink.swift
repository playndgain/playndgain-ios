import Foundation

/// Which URLs are an App Store product page. Pure, so the tests can pin it.
enum StoreLink {
    private static let webHosts: Set<String> = ["apps.apple.com", "itunes.apple.com"]
    private static let storeSchemes: Set<String> = ["itms-apps", "itms-appss"]

    /// The App Store item id the URL points at, or nil when it is not a
    /// product link. Web links count only on Apple's own hosts, compared
    /// whole, so `apps.apple.com.evil.example` is not one. The id is the
    /// `id123` path segment, or a numeric `id` query on the old iTunes links.
    static func appStoreID(_ url: URL) -> String? {
        guard let scheme = url.scheme?.lowercased() else { return nil }
        if scheme == "https" || scheme == "http" {
            guard let host = url.host?.lowercased(), webHosts.contains(host) else { return nil }
        } else if !storeSchemes.contains(scheme) {
            return nil
        }
        for segment in url.pathComponents.reversed() {
            if let id = digits(segment.lowercased(), after: "id") { return id }
        }
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        if let id = query.first(where: { $0.name == "id" })?.value, isNumericID(id) { return id }
        return nil
    }

    private static func digits(_ segment: String, after prefix: String) -> String? {
        guard segment.hasPrefix(prefix) else { return nil }
        let rest = String(segment.dropFirst(prefix.count))
        return isNumericID(rest) ? rest : nil
    }

    private static func isNumericID(_ s: String) -> Bool {
        !s.isEmpty && s.count <= 20 && s.allSatisfy { ("0"..."9").contains($0) }
    }
}
