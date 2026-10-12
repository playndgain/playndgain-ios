import XCTest
@testable import Playndgain

final class StoreLinkTests: XCTestCase {
    private func id(_ s: String) -> String? { StoreLink.appStoreID(URL(string: s)!) }

    func testAppStoreWebLinksGiveTheItemId() {
        XCTAssertEqual(id("https://apps.apple.com/us/app/some-game/id1234567890"), "1234567890")
        XCTAssertEqual(id("https://apps.apple.com/app/id42?mt=8"), "42")
        XCTAssertEqual(id("https://APPS.Apple.com/gb/app/x/ID77"), "77")
        XCTAssertEqual(id("http://itunes.apple.com/us/app/x/id99?ls=1"), "99")
        XCTAssertEqual(id("https://itunes.apple.com/WebObjects/MZStore.woa/wa/viewSoftware?id=31"), "31")
    }

    func testStoreSchemesGiveTheItemId() {
        XCTAssertEqual(id("itms-apps://apps.apple.com/app/id555"), "555")
        XCTAssertEqual(id("itms-appss://itunes.apple.com/app/x/id556"), "556")
        XCTAssertEqual(id("ITMS-APPS://itunes.apple.com/app/id557"), "557")
        XCTAssertEqual(id("itms-apps://?action=lookup&id=558"), "558")
    }

    func testLookalikeHostsAreNotTheStore() {
        XCTAssertNil(id("https://apps.apple.com.evil.example/app/id123"))
        XCTAssertNil(id("https://evil.example/apps.apple.com/app/id123"))
        XCTAssertNil(id("https://fakeapps.apple.com/app/id123"))
        XCTAssertNil(id("https://apple.com/app/id123"))
        XCTAssertNil(id("https://tracker.example/id123?next=apps.apple.com"))
        XCTAssertNil(id("https://apps.apple.com@evil.example/app/id123"))
    }

    func testStoreLinksWithoutANumericIdAreNotProducts() {
        XCTAssertNil(id("https://apps.apple.com/us/app/some-game"))
        XCTAssertNil(id("https://apps.apple.com/us/developer/x/idabc"))
        XCTAssertNil(id("https://apps.apple.com/app/id"))
        XCTAssertNil(id("https://apps.apple.com/app/id12x"))
        XCTAssertNil(id("itms-apps://apps.apple.com/"))
        XCTAssertNil(id("itms-apps://?id=abc"))
    }

    func testOtherSchemesAreNotTheStore() {
        XCTAssertNil(id("ftp://apps.apple.com/app/id1"))
        XCTAssertNil(id("game://apps.apple.com/app/id1"))
        XCTAssertNil(id("javascript:location='https://apps.apple.com/app/id1'"))
    }
}
