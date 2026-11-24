import XCTest
@testable import ManpingCore

final class WatchHistoryTests: XCTestCase {
  func testBaseURLNormalization() {
    XCTAssertEqual(BiliHistoryConfig.normalizedBaseURL("http://192.168.1.10:8899/"), "http://192.168.1.10:8899")
    XCTAssertEqual(BiliHistoryConfig.normalizedBaseURL("https://example.com/api"), "https://example.com")
    XCTAssertEqual(BiliHistoryConfig.normalizedBaseURL("  http://localhost:8899  "), "http://localhost:8899")
    XCTAssertEqual(BiliHistoryConfig.normalizedBaseURL(""), "")
    XCTAssertNil(BiliHistoryConfig.normalizedBaseURL("ftp://example.com"))
    XCTAssertNil(BiliHistoryConfig.normalizedBaseURL("example.com"))
    XCTAssertNil(BiliHistoryConfig.normalizedBaseURL("http://user:pass@example.com"))
  }

  func testEndpointUsesExternalAPIRoot() {
    XCTAssertEqual(
      BiliHistoryConfig.endpoint("http://localhost:8899/", path: "query")?.absoluteString,
      "http://localhost:8899/api/watch-progress/query")
    XCTAssertNil(BiliHistoryConfig.endpoint("", path: "ping"))
  }

  func testWatchRecordFraction() {
    let partial = WatchRecord(bvid: "BV1", watched: true, progress: 90, duration: 300,
      finished: false, viewAt: 1)
    XCTAssertEqual(partial.fraction, 0.3, accuracy: 0.0001)
    let done = WatchRecord(bvid: "BV2", watched: true, progress: -1, duration: 240,
      finished: true, viewAt: 2)
    XCTAssertEqual(done.fraction, 1)
    let unseen = WatchRecord(bvid: "BV3", watched: false, progress: 0, duration: 240,
      finished: false, viewAt: 3)
    XCTAssertEqual(unseen.fraction, 0)
  }

  func testServerPreferenceAcceptsPartialInput() {
    var settings = MacSettings()
    XCTAssertTrue(settings.set(.historyServer, .text("http://192."), capabilities: [.historyServer]))
    XCTAssertEqual(settings.text(.historyServer), "http://192.")
    XCTAssertTrue(settings.set(.historySync, .bool(true), capabilities: [.historySync]))
    XCTAssertTrue(settings.bool(.historySync))
  }

  func testBackoffGrowsToThirtyMinutes() {
    XCTAssertEqual(BiliHistoryConfig.backoffSeconds(afterFailures: 0), 0)
    XCTAssertEqual(BiliHistoryConfig.backoffSeconds(afterFailures: 1), 60)
    XCTAssertEqual(BiliHistoryConfig.backoffSeconds(afterFailures: 2), 120)
    XCTAssertEqual(BiliHistoryConfig.backoffSeconds(afterFailures: 4), 480)
    XCTAssertEqual(BiliHistoryConfig.backoffSeconds(afterFailures: 9), 1800)
  }

  func testMergePrefersTheMoreRecentViewing() {
    let old = WatchRecord(bvid: "BV1", watched: true, progress: 30, duration: 100,
      finished: false, viewAt: 100)
    let newer = WatchRecord(bvid: "BV1", watched: true, progress: 80, duration: 100,
      finished: false, viewAt: 200)
    XCTAssertEqual(WatchHistoryMerge.choose(old, newer).progress, 80)
    XCTAssertEqual(WatchHistoryMerge.choose(newer, old).progress, 80)

    let finished = WatchRecord(bvid: "BV1", watched: true, progress: 100, duration: 100,
      finished: true, viewAt: 200)
    XCTAssertTrue(WatchHistoryMerge.choose(finished, newer).finished)
  }

  func testOfficialHistoryMapsVideoCardsOnly() {
    let card = RPCVideoCard(aid: 1, bvid: "BV1", cid: 2, title: "标题", cover: nil,
      author: RPCUser(mid: 3, name: "UP", avatar: nil), duration: 100, views: 0, uri: "")
    let video = RPCHistoryItem(id: 1, oid: 1, business: "archive", title: "标题", uri: "",
      viewedAt: 123, content: .video(card, progress: 40))
    let episode = RPCHistoryItem(id: 2, oid: 2, business: "archive", title: "剧集", uri: "",
      viewedAt: 124, content: .episode(cover: nil, progress: 10, duration: 100, subtitle: ""))
    let page = RPCHistoryPage(items: [video, episode], max: 0, hasMore: false)

    let records = OfficialWatchHistory.records(from: page)
    XCTAssertEqual(records.count, 1)
    XCTAssertEqual(records["BV1"]?.progress, 40)
    XCTAssertEqual(records["BV1"]?.viewAt, 123)
  }

  func testDiskCacheRoundTripKeepsEveryEntry() {
    let url = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("manping-watch-cache-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: url) }

    var records: [String: WatchRecord] = [:]
    for index in 0..<5000 {
      let bvid = "BV\(String(format: "%05d", index))"
      records[bvid] = WatchRecord(bvid: bvid, watched: true, progress: index, duration: 1000,
        finished: false, viewAt: Int64(index))
    }
    XCTAssertEqual(WatchHistoryCache.save(records, to: url).count, 5000)
    let loaded = WatchHistoryCache.load(from: url)
    XCTAssertEqual(loaded.count, 5000)
    XCTAssertEqual(loaded["BV00000"]?.progress, 0)
    XCTAssertEqual(loaded["BV04999"]?.progress, 4999)
  }

  func testTokenRoundTrip() {
    // Outside the app bundle the vault is memory-only, so this never touches a user's secrets.
    XCTAssertTrue(BiliHistoryConfig.writeToken("  secret  "))
    XCTAssertEqual(BiliHistoryConfig.readToken(), "secret")
    XCTAssertTrue(BiliHistoryConfig.writeToken(""))
    XCTAssertEqual(BiliHistoryConfig.readToken(), "")
  }
}
