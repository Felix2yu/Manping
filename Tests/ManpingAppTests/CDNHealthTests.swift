import XCTest

@testable import ManpingApp

final class CDNHealthTests: XCTestCase {
  private let host = "example.bilivideo.com"

  func testPausedOrEndedPlaybackDoesNotShowAWarning() {
    let stalled = CDNHealth(bufferAhead: 0)
    XCTAssertFalse(stalled.isVisible(activeHost: host, paused: true, eofReached: false))
    XCTAssertFalse(stalled.isVisible(activeHost: host, paused: false, eofReached: true))
    XCTAssertTrue(stalled.isVisible(activeHost: host, paused: false, eofReached: false))
  }

  func testLowBufferShowsMatchingPlaybackWarning() {
    XCTAssertEqual(CDNHealth(bufferAhead: 0), .stalled)
    XCTAssertEqual(CDNHealth(bufferAhead: 7.9), .tight)
    XCTAssertTrue(CDNHealth(bufferAhead: 0).isVisible(activeHost: host, paused: false, eofReached: false))
    XCTAssertTrue(CDNHealth(bufferAhead: 7.9).isVisible(activeHost: host, paused: false, eofReached: false))
  }

  func testHealthyBufferOrMissingHostDoesNotShowAWarning() {
    XCTAssertEqual(CDNHealth(bufferAhead: 8), .smooth)
    XCTAssertFalse(CDNHealth(bufferAhead: 8).isVisible(activeHost: host, paused: false, eofReached: false))
    XCTAssertFalse(CDNHealth(bufferAhead: 0).isVisible(activeHost: nil, paused: false, eofReached: false))
  }
}
