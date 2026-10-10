import Foundation
import UIKit

enum Validation {
    private static let userId = try! NSRegularExpression(pattern: "^[A-Za-z0-9._:@|\\-]{1,191}$")
    private static let subId = try! NSRegularExpression(pattern: "^[A-Za-z0-9._:@|\\-]{1,100}$")

    static func isUserId(_ s: String) -> Bool { matches(userId, s) }
    static func isSubId(_ s: String) -> Bool { matches(subId, s) }

    /// Same alphabet and length the wall accepts for `model`.
    static func model(_ raw: String) -> String {
        String(raw.unicodeScalars.filter { CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789 ._()+,-").contains($0) }).trimmingCharacters(in: .whitespaces).prefix(64).description
    }

    /// Same alphabet and length the wall accepts for `dh`.
    static func hint(_ parts: [String]) -> String {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789 ._:/|,()+-")
        return String(String(parts.joined(separator: "|").unicodeScalars.filter { allowed.contains($0) }).prefix(256))
    }

    private static func matches(_ re: NSRegularExpression, _ s: String) -> Bool {
        re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil
    }
}

/// Everything the SDK sends about the device. Fraud parity with the iframe is
/// the rule: the wall reads the User-Agent, so the SDK sends the shape a
/// WKWebView in this app would send, plus the build hint the emulator check reads.
struct DeviceInfo {
    let userAgent: String
    let model: String
    let hint: String
    let ds: String

    static let current: DeviceInfo = {
        let machine = DeviceInfo.machine()
        let device = UIDevice.current
        let os = device.systemVersion.replacingOccurrences(of: ".", with: "_")
        let ua = Fields.userAgent(isPad: device.userInterfaceIdiom == .pad, osVersion: os, sdkVersion: Playndgain.version)
        return DeviceInfo(
            userAgent: ua,
            model: Validation.model(machine),
            hint: Validation.hint([machine]),
            ds: Fields.ds(
                renderer: "ios:" + machine,
                cores: ProcessInfo.processInfo.activeProcessorCount,
                memoryGB: Fields.bucketMemory(Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824),
                ratio: Double(UIScreen.main.scale)
            )
        )
    }()

    /// `utsname.machine`, e.g. `iPhone15,2`. On the simulator, `arm64` or `x86_64`.
    static func machine() -> String {
        var info = utsname()
        uname(&info)
        return withUnsafeBytes(of: &info.machine) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
    }
}

/// Pure functions, so the unit tests can pin the wire format.
enum Fields {
    static func userAgent(isPad: Bool, osVersion: String, sdkVersion: String) -> String {
        let platform = isPad ? "iPad; CPU OS" : "iPhone; CPU iPhone OS"
        return "Mozilla/5.0 (\(platform) \(osVersion) like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148 PlayndgainSDK/\(sdkVersion)"
    }

    /// The browser's `navigator.deviceMemory` buckets, which is what the web wall sends.
    static func bucketMemory(_ gb: Double) -> Double {
        guard gb > 0 else { return 0 }
        return [0.25, 0.5, 1, 2, 4, 8].min { abs($0 - gb) < abs($1 - gb) } ?? 8
    }

    /// The `ds` token in the shape `App\Identity\DeviceSignals::decode()` accepts.
    static func ds(renderer: String, cores: Int, memoryGB: Double, ratio: Double) -> String {
        let payload: [String: Any] = [
            "c": cores, "m": memoryGB, "p": ratio,
            "r": String(renderer.prefix(80)), "t": 5, "w": 0,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]) else { return "" }
        let token = data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return token.count <= 256 ? token : ""
    }

    static func query(
        appId: String, userId: String, sig: String?, options: PlayndgainOptions,
        model: String, hint: String, ds: String, version: String,
        deviceLanguage: String = Locale.preferredLanguages.first ?? "en",
        systemDark: Bool = false, extra: [(String, String)] = []
    ) -> [URLQueryItem] {
        let lang = (options.language ?? deviceLanguage).lowercased().hasPrefix("ar") ? "ar" : "en"
        let theme: String?
        switch options.theme {
        case .app: theme = nil
        case .light: theme = "light"
        case .dark: theme = "dark"
        case .system: theme = systemDark ? "dark" : "light"
        }
        var pairs: [(String, String?)] = [
            ("appid", appId), ("userid", userId), ("sig", sig.flatMap { $0.isEmpty ? nil : $0 }),
            ("lang", lang), ("theme", theme), ("balance", options.balance),
            ("sdk", "ios"), ("sdk_v", version),
            ("model", model.isEmpty ? nil : model), ("dh", hint.isEmpty ? nil : hint), ("ds", ds.isEmpty ? nil : ds),
        ]
        for (i, s) in options.subIds.prefix(5).enumerated() { pairs.append(("sub\(i + 1)", s)) }
        pairs += extra.map { ($0.0, $0.1) }
        return pairs.compactMap { k, v in v.flatMap { $0.isEmpty ? nil : URLQueryItem(name: k, value: $0) } }
    }
}
