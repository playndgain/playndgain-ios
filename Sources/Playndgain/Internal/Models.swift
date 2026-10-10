import Foundation
import UIKit

/// The `/sdk/v1` envelope, parsed once. The UI never touches raw JSON.
struct WallResponse {
    let status: String
    let http: Int
    let app: AppInfo?
    let strings: Strings
    let notice: Notice?
    var offers: [OfferCard] = []
    var categories: [String] = []
    var detail: OfferDetail?
    var history: [HistoryRow] = []
    /// Set when the envelope is shown but the host app should also hear a failure.
    var error: PlayndgainError?
}

struct AppInfo {
    let name: String
    let currencyName: String
    let rtl: Bool
    let theme: ThemeInfo
    let balance: String?
}

struct ThemeInfo {
    let primary: UIColor, onPrimary: UIColor, background: UIColor, card: UIColor, text: UIColor
    let radius: CGFloat
    let dark: Bool
}

struct Notice { let key: String; let title: String; let body: String }

struct OfferCard {
    let id: Int, name: String, instructions: String, rewardLabel: String
    let multiReward: Bool, stepsLabel: String?, peopleLabel: String?
    let featured: Bool, test: Bool, categories: [String], iconURL: URL?, clickURL: URL?
}

struct OfferDetail {
    let id: Int, name: String, rewardLabel: String
    let steps: [(String, String)], stepsNote: String?, notes: [String]
    let devices: [String], countries: [String], osMin: String?, important: [String]
    let iconURL: URL?, clickURL: URL?
}

struct HistoryRow {
    let name: String, iconURL: URL?, at: String?, statusLabel: String
    let rewardLabel: String?, reason: String?, partner: String?
}

/// Dotted lookups into the server's `strings`, with a fallback for an older server.
struct Strings {
    let root: [String: Any]?

    subscript(_ path: String) -> String { lookup(path) ?? "" }

    func or(_ path: String, _ fallback: String) -> String {
        guard let v = lookup(path), !v.isEmpty else { return fallback }
        return v
    }

    private func lookup(_ path: String) -> String? {
        var node: Any? = root
        for part in path.split(separator: ".") { node = (node as? [String: Any])?[String(part)] }
        return node as? String
    }
}

enum Parser {
    static func parse(http: Int, data: Data) throws -> WallResponse {
        // No `status` key means it is not our envelope, whatever else it holds.
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any], json["status"] is String else {
            throw PlayndgainError.internal
        }
        let d = json["data"] as? [String: Any]
        var r = WallResponse(
            status: json["status"] as? String ?? "",
            http: http,
            app: (json["app"] as? [String: Any]).map(app),
            strings: Strings(root: json["strings"] as? [String: Any]),
            notice: (json["notice"] as? [String: Any]).map { Notice(key: s($0["key"]), title: s($0["title"]), body: s($0["body"])) }
        )
        // An offer without a usable id cannot open a detail or a click.
        r.offers = (d?["offers"] as? [[String: Any]] ?? []).compactMap(offer)
        r.categories = d?["categories"] as? [String] ?? []
        if let d = d, d["steps"] != nil { r.detail = detail(d) }
        r.history = (d?["rows"] as? [[String: Any]] ?? []).map(row)
        return r
    }

    private static func app(_ o: [String: Any]) -> AppInfo {
        let t = o["theme"] as? [String: Any] ?? [:]
        return AppInfo(
            name: s(o["name"]), currencyName: s(o["currency_name"]), rtl: o["rtl"] as? Bool ?? false,
            theme: ThemeInfo(
                primary: Colors.parse(t["primary"] as? String, fallback: 0xFFB020),
                onPrimary: Colors.parse(t["on_primary"] as? String, fallback: 0x0B0D10),
                background: Colors.parse(t["background"] as? String, fallback: 0x0A0B14),
                card: Colors.parse(t["card"] as? String, fallback: 0x11131F),
                text: Colors.parse(t["text"] as? String, fallback: 0xF4F5FA),
                radius: CGFloat(t["radius"] as? Int ?? 14),
                dark: t["dark"] as? Bool ?? true
            ),
            balance: o["balance"] as? String
        )
    }

    private static func offer(_ o: [String: Any]) -> OfferCard? {
        guard let id = o["id"] as? Int, id > 0 else { return nil }
        return OfferCard(
            id: id, name: s(o["name"]), instructions: s(o["instructions"]), rewardLabel: s(o["reward_label"]),
            multiReward: o["multi_reward"] as? Bool ?? false, stepsLabel: o["steps_label"] as? String, peopleLabel: o["people_label"] as? String,
            featured: o["featured"] as? Bool ?? false, test: o["test"] as? Bool ?? false,
            categories: o["categories"] as? [String] ?? [], iconURL: url(o["icon_url"]), clickURL: url(o["click_url"])
        )
    }

    private static func detail(_ o: [String: Any]) -> OfferDetail {
        OfferDetail(
            id: o["id"] as? Int ?? 0, name: s(o["name"]), rewardLabel: s(o["reward_label"]),
            steps: (o["steps"] as? [[String: Any]] ?? []).map { (s($0["name"]), s($0["reward"])) },
            stepsNote: o["steps_note"] as? String, notes: o["notes"] as? [String] ?? [],
            devices: o["devices"] as? [String] ?? [],
            countries: (o["countries"] as? [[String: Any]] ?? []).map { s($0["name"]) },
            osMin: o["os_min_version"] as? String, important: o["important"] as? [String] ?? [],
            iconURL: url(o["icon_url"]), clickURL: url(o["click_url"])
        )
    }

    private static func row(_ o: [String: Any]) -> HistoryRow {
        HistoryRow(
            name: s(o["name"]), iconURL: url(o["icon_url"]), at: o["at"] as? String, statusLabel: s(o["status_label"]),
            rewardLabel: o["reward_label"] as? String, reason: o["reason"] as? String, partner: o["partner"] as? String
        )
    }

    private static func s(_ v: Any?) -> String { v as? String ?? "" }
    private static func url(_ v: Any?) -> URL? { (v as? String).flatMap(URL.init(string:)) }
}

enum Colors {
    /// `#RGB`, `#RRGGBB` or `#RRGGBBAA`, the forms the wall's theme allows.
    static func parse(_ hex: String?, fallback: UInt32) -> UIColor {
        guard var h = hex?.trimmingCharacters(in: .whitespaces), h.hasPrefix("#") else { return rgb(fallback) }
        h.removeFirst()
        if h.count == 3 { h = h.map { "\($0)\($0)" }.joined() }
        guard let v = UInt64(h, radix: 16) else { return rgb(fallback) }
        switch h.count {
        case 6: return rgb(UInt32(v))
        case 8: return UIColor(red: CGFloat((v >> 24) & 0xFF) / 255, green: CGFloat((v >> 16) & 0xFF) / 255,
                               blue: CGFloat((v >> 8) & 0xFF) / 255, alpha: CGFloat(v & 0xFF) / 255)
        default: return rgb(fallback)
        }
    }

    static func rgb(_ v: UInt32) -> UIColor {
        UIColor(red: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255, blue: CGFloat(v & 0xFF) / 255, alpha: 1)
    }

    /// `color-mix(in srgb, a p%, b)`.
    static func mix(_ a: UIColor, _ b: UIColor, _ p: CGFloat) -> UIColor {
        var (ar, ag, ab, aa) = (CGFloat(0), CGFloat(0), CGFloat(0), CGFloat(0))
        var (br, bg, bb, ba) = (CGFloat(0), CGFloat(0), CGFloat(0), CGFloat(0))
        a.getRed(&ar, green: &ag, blue: &ab, alpha: &aa)
        b.getRed(&br, green: &bg, blue: &bb, alpha: &ba)
        return UIColor(red: ar * p + br * (1 - p), green: ag * p + bg * (1 - p), blue: ab * p + bb * (1 - p), alpha: 1)
    }
}
