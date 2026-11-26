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

  func testContinueWatchingUsesLatestValidPartAndSortsByViewingTime() {
    let card = RPCVideoCard(aid: 1, bvid: "BV1", cid: 2, title: "标题", cover: nil,
      author: RPCUser(mid: 3, name: "UP", avatar: nil), duration: 100, views: 0, uri: "")
    let older = RPCHistoryItem(id: 1, oid: 1, business: "archive", title: "标题", uri: "",
      viewedAt: 100, content: .video(card, progress: 80))
    let latest = RPCHistoryItem(id: 2, oid: 1, business: "archive", title: "标题", uri: "",
      viewedAt: 200, content: .video(card, progress: 25))
    let otherCard = RPCVideoCard(aid: 4, bvid: "BV2", cid: 5, title: "另一个", cover: nil,
      author: nil, duration: 200, views: 0, uri: "")
    let other = RPCHistoryItem(id: 3, oid: 4, business: "archive", title: "另一个", uri: "",
      viewedAt: 150, content: .video(otherCard, progress: 60))
    let items = ContinueWatchingItem.entries(from: [older, other, latest])
    XCTAssertEqual(items.map(\.id), ["BV1", "BV2"])
    XCTAssertEqual(items[0].progress, 25)
    XCTAssertEqual(items[0].video.cid, 2)
    XCTAssertEqual(items[0].video.subtitle, "看到 00:25")
    XCTAssertEqual(items[1].fraction, 0.3, accuracy: 0.0001)
    XCTAssertEqual(ContinueWatchingItem.entries(from: [older, other, latest], limit: 1).map(\.id), ["BV1"])
  }

  func testContinueWatchingExcludesCompletedInvalidAndNonVideoHistory() {
    let card = RPCVideoCard(aid: 1, bvid: "BV1", cid: 2, title: "标题", cover: nil,
      author: nil, duration: 100, views: 0, uri: "")
    func item(_ id: Int64, _ progress: Int64, viewedAt: Int64 = 100) -> RPCHistoryItem {
      RPCHistoryItem(id: id, oid: 1, business: "archive", title: "标题", uri: "",
        viewedAt: viewedAt, content: .video(card, progress: progress))
    }
    let finished = item(9, 100, viewedAt: 300)
    XCTAssertTrue(ContinueWatchingItem.entries(from: [item(1, 40), finished]).isEmpty)
    for progress in [0, -1, 101] as [Int64] { XCTAssertTrue(ContinueWatchingItem.entries(from: [item(1, progress)]).isEmpty) }
    let episode = RPCHistoryItem(id: 2, oid: 2, business: "archive", title: "剧集", uri: "",
      viewedAt: 400, content: .episode(cover: nil, progress: 10, duration: 100, subtitle: ""))
    let live = RPCHistoryItem(id: 3, oid: 3, business: "live", title: "直播", uri: "",
      viewedAt: 500, content: .video(card, progress: 10))
    let invalidCard = RPCVideoCard(aid: 0, bvid: "BV2", cid: 0, title: "无效", cover: nil,
      author: nil, duration: 100, views: 0, uri: "")
    let invalid = RPCHistoryItem(id: 4, oid: 0, business: "archive", title: "无效", uri: "",
      viewedAt: 600, content: .video(invalidCard, progress: 10))
    XCTAssertTrue(ContinueWatchingItem.entries(from: [episode, live, invalid]).isEmpty)
    XCTAssertTrue(ContinueWatchingItem.entries(from: [item(1, 10)], limit: 0).isEmpty)
  }

  func testContinueWatchingStartPositionRequiresTheSameUnfinishedPart() {
    XCTAssertEqual(ContinueWatchingItem.validStart(25, duration: 100, cid: 2, expectedCID: 2), 25)
    XCTAssertEqual(ContinueWatchingItem.validStart(25, duration: 100, cid: 2, expectedCID: 3), 0)
    for position in [0.0, -1, 100, 101, .infinity, .nan] {
      XCTAssertEqual(ContinueWatchingItem.validStart(position, duration: 100, cid: 2, expectedCID: 2), 0)
    }
    XCTAssertEqual(ContinueWatchingItem.validStart(25, duration: 0, cid: 2, expectedCID: 2), 0)
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

  func testCacheFilesAreSharedAcrossLoginStatesAndSeparatedByAppVariant() {
    let debug = WatchHistoryCache.cacheFileURL("watch-history", variant: "-debug")
    let release = WatchHistoryCache.cacheFileURL("watch-history", variant: "")
    XCTAssertEqual(debug?.lastPathComponent, "watch-history-guest-debug.json")
    XCTAssertEqual(release?.lastPathComponent, "watch-history-guest.json")
    XCTAssertNotEqual(debug, release)
  }

  func testTokenRoundTrip() {
    // Outside the app bundle the vault is memory-only, so this never touches a user's secrets.
    XCTAssertTrue(BiliHistoryConfig.writeToken("  secret  "))
    XCTAssertEqual(BiliHistoryConfig.readToken(), "secret")
    XCTAssertTrue(BiliHistoryConfig.writeToken(""))
    XCTAssertEqual(BiliHistoryConfig.readToken(), "")
  }
}
