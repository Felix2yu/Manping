import Foundation
import XCTest

@testable import ManpingCore

final class AppIdentityTests: XCTestCase {
  func testBundleVariantsStayUnderTheNewIdentity() {
    XCTAssertEqual(AppIdentity.bundleIdentifier, "im.yufei.manping")
    XCTAssertEqual(AppIdentity.variant(for: AppIdentity.bundleIdentifier), "")
    XCTAssertEqual(AppIdentity.variant(for: AppIdentity.debugBundleIdentifier), "-debug")
    XCTAssertEqual(AppIdentity.variant(for: AppIdentity.perfBundleIdentifier), "-perf")
    XCTAssertNil(AppIdentity.variant(for: "io.github.pidean.manping"))
    XCTAssertNil(AppIdentity.variant(for: nil))
  }

  func testPersistentStorageDoesNotUseTheOriginalProductDirectory() {
    XCTAssertEqual(AppIdentity.applicationSupportDirectory.lastPathComponent, "im.yufei.manping")
    XCTAssertEqual(AppIdentity.cachesDirectory.lastPathComponent, "im.yufei.manping")
    XCTAssertNotEqual(AppIdentity.applicationSupportDirectory.lastPathComponent, "Manping")
  }

  func testLinksUseTheNewScheme() {
    XCTAssertEqual(AppIdentity.urlScheme, "manpingx")
    XCTAssertEqual(BiliLinkParser.parse("manpingx://video/BV1fK4y1t7hj"), .video(bvid: "BV1fK4y1t7hj"))
    XCTAssertNil(BiliLinkParser.parse("manping://video/BV1fK4y1t7hj"))
  }
}
