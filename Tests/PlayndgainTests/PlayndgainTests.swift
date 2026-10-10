import UIKit
import XCTest
@testable import Playndgain

final class FieldsTests: XCTestCase {
    private func dict(_ items: [URLQueryItem]) -> [String: String] {
        Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
    }

    func testQueryCarriesEveryWallParameterAndTheSdkEvidence() {
        let q = dict(Fields.query(
            appId: "10000", userId: "USER_1", sig: "abc",
            options: PlayndgainOptions(theme: .dark, language: "ar", balance: "1,200 coins", subIds: ["camp", "b"]),
            model: "iPhone15,2", hint: "iPhone15,2", ds: "tok", version: "1.0.0"
        ))
        XCTAssertEqual(q["appid"], "10000")
        XCTAssertEqual(q["sig"], "abc")
        XCTAssertEqual(q["lang"], "ar")
        XCTAssertEqual(q["theme"], "dark")
        XCTAssertEqual(q["sdk"], "ios")
        XCTAssertEqual(q["sdk_v"], "1.0.0")
        XCTAssertEqual(q["model"], "iPhone15,2")
        XCTAssertEqual(q["dh"], "iPhone15,2")
        XCTAssertEqual(q["ds"], "tok")
        XCTAssertEqual(q["sub1"], "camp")
        XCTAssertEqual(q["sub2"], "b")
        XCTAssertNil(q["sub3"])
    }

    func testAppThemeAndAnEmptySignatureSendNothing() {
        let q = dict(Fields.query(appId: "1", userId: "U", sig: "", options: .init(), model: "", hint: "", ds: "", version: "1.0.0", deviceLanguage: "fr"))
        XCTAssertNil(q["theme"])
        XCTAssertNil(q["sig"])
        XCTAssertEqual(q["lang"], "en")
    }

    /// The wall's DeviceDetector has to place this as iOS with its version,
    /// the same way it places a WKWebView in the app.
    func testUserAgentIsTheWebViewShapePlusTheSdkMarker() {
        let ua = Fields.userAgent(isPad: false, osVersion: "17_4", sdkVersion: "1.0.0").lowercased()
        XCTAssertTrue(ua.contains("iphone"))
        XCTAssertTrue(ua.contains("iphone os 17_4"))
        XCTAssertTrue(ua.hasSuffix("playndgainsdk/1.0.0"))
        XCTAssertTrue(Fields.userAgent(isPad: true, osVersion: "17_4", sdkVersion: "1.0.0").contains("iPad; CPU OS 17_4"))
    }

    func testDsTokenHasTheShapeTheWallDecodes() throws {
        let token = Fields.ds(renderer: "ios:" + String(repeating: "x", count: 200), cores: 6, memoryGB: 8, ratio: 3)
        XCTAssertLessThanOrEqual(token.count, 256)
        var b64 = token.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b64.count % 4 != 0 { b64 += "=" }
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(Data(base64Encoded: b64))) as? [String: Any])
        XCTAssertEqual(Set(json.keys), ["c", "m", "p", "r", "t", "w"])
        XCTAssertEqual((json["r"] as? String)?.count, 80)
        XCTAssertEqual(json["w"] as? Int, 0)
    }

    func testMemoryBucketsLikeTheBrowser() {
        XCTAssertEqual(Fields.bucketMemory(11.5), 8)
        XCTAssertEqual(Fields.bucketMemory(3.7), 4)
        XCTAssertEqual(Fields.bucketMemory(0), 0)
    }

    func testValidationMatchesTheWall() {
        XCTAssertTrue(Validation.isUserId("u_4812:a@b|c-d.e"))
        XCTAssertFalse(Validation.isUserId("has space"))
        XCTAssertFalse(Validation.isUserId(String(repeating: "x", count: 192)))
        XCTAssertTrue(Validation.isSubId("spring_promo"))
        XCTAssertFalse(Validation.isSubId(String(repeating: "x", count: 101)))
        XCTAssertEqual(Validation.model("iPhone15,2<x>"), "iPhone15,2x")
        XCTAssertEqual(Validation.hint([String(repeating: "a", count: 300)]).count, 256)
    }

    func testFontsRegisterFromTheBundle() {
        Fonts.registerOnce()
        for name in ["Sora-Regular", "Sora-SemiBold", "Sora-Bold"] {
            XCTAssertNotNil(UIFont(name: name, size: 12), name)
        }
    }
}

final class ParserTests: XCTestCase {
    private func fixture(_ name: String) throws -> Data {
        let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
        return try Data(contentsOf: url)
    }

    func testParsesTheWall() throws {
        let data = try fixture("wall_ok")
        let r = try Parser.parse(http: 200, data: data)
        XCTAssertEqual(r.status, "ok")
        XCTAssertEqual(r.app?.currencyName, "Coins")
        XCTAssertEqual(r.app?.theme.radius, 14)
        XCTAssertFalse(r.offers.isEmpty)
        XCTAssertTrue(r.offers[0].clickURL?.path.hasPrefix("/click/") ?? false)
        XCTAssertEqual(r.strings["earn"], "Earn Coins")
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("\"payout\""))
    }

    func testParsesDetailHistoryABlockAndAnInvalidLink() throws {
        let d = try XCTUnwrap(try Parser.parse(http: 200, data: fixture("offer_ok")).detail)
        XCTAssertEqual(d.important.count, 4)
        XCTAssertFalse(d.steps.isEmpty)

        let h = try Parser.parse(http: 200, data: fixture("history_ok"))
        XCTAssertEqual(h.history.first?.partner, "Partner wall")
        XCTAssertEqual(h.history.first?.statusLabel, "Credited")

        let b = try Parser.parse(http: 403, data: fixture("blocked"))
        XCTAssertEqual(b.status, "blocked")
        XCTAssertEqual(b.notice?.key, "blocked_unavailable")
        XCTAssertTrue(b.offers.isEmpty)

        XCTAssertEqual(try Parser.parse(http: 200, data: fixture("unplaced")).status, "unplaced")
        XCTAssertEqual(try Parser.parse(http: 400, data: fixture("invalid")).status, "invalid")
    }

    func testColoursParseEveryFormTheWallThemeAllows() {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        Colors.parse("#FA0", fallback: 0).getRed(&r, green: &g, blue: &b, alpha: &a)
        XCTAssertEqual(r, 1, accuracy: 0.01)
        XCTAssertEqual(g, 0xAA / 255, accuracy: 0.01)
        Colors.parse("#FFB02080", fallback: 0).getRed(&r, green: &g, blue: &b, alpha: &a)
        XCTAssertEqual(a, 0x80 / 255, accuracy: 0.01)
    }
}

final class SetUserTests: XCTestCase {
    override func tearDown() { Playndgain.reset() }

    func testAnInvalidIdClearsThePreviousUserAndProvider() {
        Playndgain.setUser("PLAYER_1") { _, _, done in done(.success("abc")) }
        XCTAssertEqual(Playndgain.userId, "PLAYER_1")
        XCTAssertNotNil(Playndgain.signatureProvider)
        let before = Playndgain.userEpoch

        Playndgain.setUser("has space") { _, _, done in done(.success("abc")) }
        XCTAssertNil(Playndgain.userId)
        XCTAssertNil(Playndgain.signatureProvider)
        // A cached signature is keyed to the epoch, so it is dropped too.
        XCTAssertNotEqual(Playndgain.userEpoch, before)
    }

    func testInitializeTrimsNewlinesFromTheAppId() {
        Playndgain.initialize(appId: " 10000\n")
        XCTAssertEqual(Playndgain.appId, "10000")
        Playndgain.setUser("PLAYER_1") { _, _, done in done(.success("")) }
        Playndgain.initialize(appId: "10000\n")
        XCTAssertEqual(Playndgain.userId, "PLAYER_1", "the same app id with a trailing newline must not reset the user")
    }
}

final class OutcomeTests: XCTestCase {
    private func json(_ s: String) -> Data { Data(s.utf8) }

    func testHtmlOnA200IsWallUnavailable() {
        let r = ApiClient.outcome(http: 200, data: json("<!DOCTYPE html><html><body>Just a moment</body></html>"), failed: false)
        guard case .failure(let e) = r else { return XCTFail("expected a failure") }
        XCTAssertEqual(e, .wallUnavailable)
    }

    func testAnyNonEnvelopeIsWallUnavailableExceptABare429() {
        for code in [200, 302, 400, 403, 404, 500, 502] {
            guard case .failure(let e) = ApiClient.outcome(http: code, data: json("{\"message\":\"x\"}"), failed: false) else { return XCTFail("\(code)") }
            XCTAssertEqual(e, .wallUnavailable, "\(code)")
        }
        guard case .failure(let e) = ApiClient.outcome(http: 429, data: json("Too Many Requests"), failed: false) else { return XCTFail() }
        XCTAssertEqual(e, .rateLimited)
        guard case .failure(let n) = ApiClient.outcome(http: 0, data: nil, failed: true) else { return XCTFail() }
        XCTAssertEqual(n, .network)
    }

    func testRateLimitedEnvelopeReportsAndKeepsTheNotice() throws {
        let body = #"{"status":"rate_limited","strings":{},"notice":{"key":"rate_limited","title":"Slow down","body":"Try again in a minute."}}"#
        let r = try ApiClient.outcome(http: 429, data: json(body), failed: false).get()
        XCTAssertEqual(r.status, "rate_limited")
        XCTAssertEqual(r.error, .rateLimited)
        XCTAssertEqual(r.notice?.title, "Slow down")
    }

    func testInvalidEnvelopePassesThroughWithAnError() throws {
        let signed = try ApiClient.outcome(http: 403, data: json(#"{"status":"invalid"}"#), failed: false).get()
        XCTAssertEqual(signed.error, .signatureUnavailable)
        let body = #"{"status":"invalid","notice":{"key":"invalid","title":"Link not valid","body":"Ask the app to reopen it."}}"#
        let bad = try ApiClient.outcome(http: 400, data: json(body), failed: false).get()
        XCTAssertEqual(bad.error, .wallUnavailable)
        XCTAssertEqual(bad.notice?.title, "Link not valid")
    }

    func testOkEnvelopeHasNoError() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "wall_ok", withExtension: "json", subdirectory: "Fixtures"))
        let r = try ApiClient.outcome(http: 200, data: Data(contentsOf: url), failed: false).get()
        XCTAssertNil(r.error)
        XCTAssertFalse(r.offers.isEmpty)
    }

    func testOffersWithoutAnIdAreSkipped() throws {
        let body = #"{"status":"ok","data":{"offers":[{"id":0,"name":"a"},{"name":"b"},{"id":"7","name":"c"},{"id":12,"name":"d"}]}}"#
        let r = try Parser.parse(http: 200, data: json(body))
        XCTAssertEqual(r.offers.map(\.id), [12])
    }
}

final class GuardTests: XCTestCase {
    func testOnlyTheNewestLoadIsCurrent() {
        var gate = LoadTickets()
        let wall = gate.next()          // Offers, featured sort
        let history = gate.next()       // tab switched before the wall answered
        XCTAssertFalse(gate.isCurrent(wall), "a wall answer must not render into History")
        XCTAssertTrue(gate.isCurrent(history))
        let older = gate.next(), newer = gate.next()
        XCTAssertFalse(gate.isCurrent(older), "an older sort must not overwrite a newer one")
        XCTAssertTrue(gate.isCurrent(newer))
    }

    func testClicksAndIconsOnlyFollowWebUrls() {
        let prod = URL(string: "https://wall.playndgain.com")!
        XCTAssertTrue(Links.isAllowedClick(URL(string: "https://wall.playndgain.com/click/1?x=1")!, base: prod))
        XCTAssertFalse(Links.isAllowedClick(URL(string: "http://wall.playndgain.com/click/1")!, base: prod))
        XCTAssertFalse(Links.isAllowedClick(URL(string: "https://elsewhere.example/click/1")!, base: prod))
        XCTAssertFalse(Links.isAllowedClick(URL(string: "javascript:alert(1)")!, base: prod))
        let local = URL(string: "http://localhost:8765")!
        XCTAssertTrue(Links.isAllowedClick(URL(string: "http://localhost:8765/click/1")!, base: local))

        XCTAssertTrue(Links.isWebURL(URL(string: "https://wall.playndgain.com/i/1.png")!))
        XCTAssertFalse(Links.isWebURL(URL(string: "file:///etc/hosts")!))
        XCTAssertFalse(Links.isWebURL(URL(string: "data:image/png;base64,AAAA")!))
    }
}
