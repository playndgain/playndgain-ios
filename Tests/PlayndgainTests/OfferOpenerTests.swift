import XCTest
@testable import Playndgain

final class OfferResolutionTests: XCTestCase {
    private let click = URL(string: "https://wall.example/click/7?t=1")!
    private let tracker = URL(string: "https://tracker.example/c/abc")!
    private let store = URL(string: "https://apps.apple.com/us/app/x/id123")!
    private let deepLink = URL(string: "game://open?ref=1")!

    func testClassifiesEachKindOfNavigation() {
        XCTAssertEqual(OfferResolution.classify(click), .web)
        XCTAssertEqual(OfferResolution.classify(store), .store(id: "123", url: store))
        XCTAssertEqual(OfferResolution.classify(URL(string: "itms-apps://apps.apple.com/app/id9")!), .store(id: "9", url: URL(string: "itms-apps://apps.apple.com/app/id9")!))
        XCTAssertEqual(OfferResolution.classify(deepLink), .app(deepLink))
        // A store scheme without an id is still something the system can open.
        XCTAssertEqual(OfferResolution.classify(URL(string: "itms-apps://apps.apple.com/")!), .app(URL(string: "itms-apps://apps.apple.com/")!))
        XCTAssertEqual(OfferResolution.classify(URL(string: "about:blank")!), .quiet)
        XCTAssertEqual(OfferResolution.classify(URL(string: "file:///etc/hosts")!), .blocked)
        XCTAssertEqual(OfferResolution.classify(URL(string: "https://apps.apple.com.evil.example/app/id1")!), .web)
    }

    func testRedirectChainToTheStoreResolvesOnceAndCancels() {
        var r = OfferResolution()
        XCTAssertEqual(r.navigate(to: click, mainFrame: true), .allow)
        XCTAssertEqual(r.navigate(to: tracker, mainFrame: true), .allow)
        XCTAssertEqual(r.navigate(to: store, mainFrame: true), .resolve(.store(id: "123", url: store)))
        XCTAssertEqual(r.phase, .done)
        // Nothing after the resolution is followed or reported again.
        XCTAssertEqual(r.navigate(to: tracker, mainFrame: true), .cancel)
        XCTAssertEqual(r.navigate(to: store, mainFrame: true), .cancel)
        XCTAssertNil(r.didFail())
        XCTAssertNil(r.timedOut())
        XCTAssertNil(r.didFinish())
    }

    func testAStoreLinkInAFrameStillResolves() {
        var r = OfferResolution()
        _ = r.navigate(to: click, mainFrame: true)
        XCTAssertEqual(r.navigate(to: store, mainFrame: false), .resolve(.store(id: "123", url: store)))
    }

    func testAnAppLinkResolvesInTheMainFrameOnly() {
        var r = OfferResolution()
        _ = r.navigate(to: click, mainFrame: true)
        XCTAssertEqual(r.navigate(to: deepLink, mainFrame: false), .cancel)
        XCTAssertEqual(r.phase, .resolving)
        XCTAssertEqual(r.navigate(to: deepLink, mainFrame: true), .resolve(.app(deepLink)))
    }

    func testAFinishedPageIsTheLandingOnlyIfNothingFollowsIt() {
        var r = OfferResolution()
        _ = r.navigate(to: click, mainFrame: true)
        r.didCommit()
        let first = r.didFinish()!
        // A script redirect inside the wait makes the first ticket stale.
        XCTAssertEqual(r.navigate(to: tracker, mainFrame: true), .allow)
        XCTAssertNil(r.settled(first))
        XCTAssertEqual(r.phase, .resolving)
        let second = r.didFinish()!
        XCTAssertEqual(r.settled(second), .landing)
        XCTAssertEqual(r.phase, .revealed)
        XCTAssertNil(r.settled(second))
        XCTAssertNil(r.timedOut())
    }

    func testAFrameLoadingDoesNotPostponeTheLanding() {
        var r = OfferResolution()
        _ = r.navigate(to: click, mainFrame: true)
        let ticket = r.didFinish()!
        XCTAssertEqual(r.navigate(to: URL(string: "https://frame.example/x")!, mainFrame: false), .allow)
        XCTAssertEqual(r.settled(ticket), .landing)
    }

    func testTimeoutRevealsAndLaterStoreTapsAreInterceptedEachTime() {
        var r = OfferResolution()
        _ = r.navigate(to: click, mainFrame: true)
        XCTAssertEqual(r.timedOut(), .timeout)
        XCTAssertEqual(r.phase, .revealed)
        XCTAssertNil(r.timedOut())
        XCTAssertEqual(r.navigate(to: tracker, mainFrame: true), .allow)
        XCTAssertEqual(r.navigate(to: store, mainFrame: true), .intercept(.store(id: "123", url: store)))
        XCTAssertEqual(r.navigate(to: store, mainFrame: true), .intercept(.store(id: "123", url: store)))
        XCTAssertEqual(r.navigate(to: deepLink, mainFrame: true), .intercept(.app(deepLink)))
        XCTAssertEqual(r.phase, .revealed)
        // The page is the user's now: a failed load there is not the click failing.
        XCTAssertNil(r.didFail())
    }

    func testAnErrorBeforeOrAfterTheFirstPageFails() {
        var fresh = OfferResolution()
        _ = fresh.navigate(to: click, mainFrame: true)
        XCTAssertEqual(fresh.didFail(), .failed)
        XCTAssertEqual(fresh.phase, .done)

        // Mid-chain, after a page: still failed, so no error page for a
        // partner's address is ever revealed.
        var mid = OfferResolution()
        _ = mid.navigate(to: click, mainFrame: true)
        mid.didCommit()
        _ = mid.navigate(to: tracker, mainFrame: true)
        XCTAssertEqual(mid.didFail(), .failed)
        XCTAssertNil(mid.timedOut())
    }

    func testAnUnopenedAppFallsBackToWhatLoadedOnce() {
        var none = OfferResolution()
        _ = none.navigate(to: click, mainFrame: true)
        _ = none.navigate(to: deepLink, mainFrame: true)
        XCTAssertEqual(none.appUnopened(), .failed)
        XCTAssertNil(none.appUnopened())

        var loaded = OfferResolution()
        _ = loaded.navigate(to: click, mainFrame: true)
        loaded.didCommit()
        _ = loaded.navigate(to: deepLink, mainFrame: true)
        XCTAssertEqual(loaded.appUnopened(), .landing)
        XCTAssertEqual(loaded.phase, .revealed)
        XCTAssertNil(loaded.appUnopened())

        // Not after a store resolution, a cancel or an intercepted tap.
        var stored = OfferResolution()
        _ = stored.navigate(to: store, mainFrame: true)
        XCTAssertNil(stored.appUnopened())
        var cancelled = OfferResolution()
        _ = cancelled.navigate(to: deepLink, mainFrame: true)
        cancelled.cancel()
        XCTAssertNil(cancelled.appUnopened())
        var revealed = OfferResolution()
        _ = revealed.timedOut()
        _ = revealed.navigate(to: deepLink, mainFrame: true)
        XCTAssertNil(revealed.appUnopened())
    }

    func testCancelStopsEverything() {
        var r = OfferResolution()
        _ = r.navigate(to: click, mainFrame: true)
        r.cancel()
        XCTAssertEqual(r.navigate(to: tracker, mainFrame: true), .cancel)
        XCTAssertEqual(r.navigate(to: store, mainFrame: true), .cancel)
        XCTAssertNil(r.timedOut())
        XCTAssertNil(r.didFail())
    }

    func testQuietAndFileNavigationsNeverResolve() {
        var r = OfferResolution()
        XCTAssertEqual(r.navigate(to: URL(string: "about:blank")!, mainFrame: true), .allow)
        XCTAssertEqual(r.navigate(to: URL(string: "file:///etc/hosts")!, mainFrame: true), .cancel)
        XCTAssertEqual(r.phase, .resolving)
    }

    func testOwnCancellationsAreNotFailures() {
        XCTAssertTrue(OfferOpener.isOwnCancellation(NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled)))
        XCTAssertTrue(OfferOpener.isOwnCancellation(NSError(domain: "WebKitErrorDomain", code: 102)))
        XCTAssertFalse(OfferOpener.isOwnCancellation(NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet)))
        XCTAssertFalse(OfferOpener.isOwnCancellation(NSError(domain: NSURLErrorDomain, code: NSURLErrorCannotFindHost)))
    }
}

final class OfferOpenerTests: XCTestCase {
    private let base = URL(string: "https://wall.example")!

    func testStartLoadsOnlyTheWallsClickRouteAndOnlyOnce() {
        let opener = OfferOpener(onResolve: { _ in }, onIntercept: { _ in })
        XCTAssertFalse(opener.start(URL(string: "https://tracker.example/click/1")!, base: base))
        XCTAssertFalse(opener.start(URL(string: "http://wall.example/click/1")!, base: base))
        XCTAssertTrue(opener.start(URL(string: "https://wall.example/click/1")!, base: base))
        XCTAssertFalse(opener.start(URL(string: "https://wall.example/click/1")!, base: base), "a second load of the click")
        XCTAssertFalse(opener.start(URL(string: "https://wall.example/click/2")!, base: base))
        opener.cancel()
        XCTAssertEqual(opener.phase, .done)
    }

    func testACancelledOpenerCannotStart() {
        let opener = OfferOpener(onResolve: { _ in }, onIntercept: { _ in })
        opener.cancel()
        XCTAssertFalse(opener.start(URL(string: "https://wall.example/click/1")!, base: base))
    }
}
