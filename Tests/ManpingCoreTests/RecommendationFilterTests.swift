import XCTest
@testable import ManpingCore

final class RecommendationFilterTests: XCTestCase {
  private func video(bvid: String = "BV1fixture001", aid: Int64? = nil,
    primary: Int? = 1, secondary: Int? = 24, author: Int64? = 42) -> Video {
    Video(bvid: bvid, title: "Video", author: "Creator", aid: aid, authorID: author,
      partitionID: primary, partitionName: "动画", subpartitionID: secondary, subpartitionName: "剪辑")
  }

  func testRulesFilterOnlyMatchingRecommendations() {
    var filter = RecommendationFilter()
    XCTAssertTrue(filter.add(RecommendationFilterRule(kind: .subpartition, valueID: 24, name: "剪辑")))
    XCTAssertTrue(filter.filters(video()))
    XCTAssertFalse(filter.filters(video(secondary: 25)))
    XCTAssertFalse(filter.filters(video(primary: 3, secondary: nil)))
  }

  func testPrimaryPartitionAndAuthorRulesAreIndependent() {
    var filter = RecommendationFilter()
    XCTAssertTrue(filter.add(RecommendationFilterRule(kind: .primaryPartition, valueID: 1, name: "动画")))
    XCTAssertTrue(filter.filters(video(secondary: nil)))
    XCTAssertTrue(filter.add(RecommendationFilterRule(kind: .author, valueID: 42, name: "Creator")))
    XCTAssertTrue(filter.filters(video(primary: 3, secondary: nil)))
    XCTAssertFalse(filter.filters(video(primary: 3, secondary: nil, author: 43)))
  }

  func testRulesRejectDuplicatesAndInvalidIDsAndCanBeRemoved() {
    var filter = RecommendationFilter()
    let rule = RecommendationFilterRule(kind: .author, valueID: 42, name: "Creator")
    XCTAssertTrue(filter.add(rule))
    XCTAssertFalse(filter.add(RecommendationFilterRule(kind: .author, valueID: 42, name: "Renamed")))
    XCTAssertFalse(filter.add(RecommendationFilterRule(kind: .author, valueID: 0, name: "Invalid")))
    XCTAssertFalse(filter.add(RecommendationFilterRule(kind: .author, valueID: 43, name: "")))
    filter.remove(id: rule.id)
    XCTAssertTrue(filter.rules.isEmpty)
  }

  func testLegacyPartitionRuleAlsoMatchesFeedsWithoutV2Metadata() {
    var filter = RecommendationFilter()
    XCTAssertTrue(filter.add(RecommendationFilterRule(kind: .subpartition, valueID: 24, name: "剪辑")))
    XCTAssertTrue(filter.filters(video(primary: 24, secondary: nil)))
  }

  func testRecommendationCardSeparatesCurrentPrimaryFromLegacyPartition() throws {
    let video = try BiliService.appVideo([
      "param": "123", "title": "A",
      "args": ["tid": "24", "tname": "剪辑", "tid_v2": "1", "tname_v2": "动画"],
    ])
    XCTAssertEqual(video.partitionID, 1)
    XCTAssertEqual(video.partitionName, "动画")
    XCTAssertEqual(video.subpartitionID, 24)
    XCTAssertEqual(video.subpartitionName, "剪辑")
  }

  func testWebVideoParsesPartitionsWithoutTreatingMissingIDsAsZero() throws {
    let parsed = try Video.parse([
      "bvid": "BV1fixture001", "title": "A", "tid": 3, "tname": "音乐",
      "tid_v2": "31", "tname_v2": "翻唱",
    ])
    XCTAssertEqual(parsed.partitionID, 31)
    XCTAssertEqual(parsed.partitionName, "翻唱")
    XCTAssertEqual(parsed.subpartitionID, 3)
    XCTAssertEqual(parsed.subpartitionName, "音乐")
    let missing = try Video.parse(["bvid": "BV1fixture002", "title": "B"])
    XCTAssertNil(missing.partitionID)
    XCTAssertNil(missing.subpartitionID)
  }

  func testExplicitSecondaryPartitionOverridesLegacyMetadata() throws {
    let parsed = try Video.parse([
      "bvid": "BV1fixture003", "title": "A", "tid": 3, "tname": "音乐",
      "tid_v2": "31", "tname_v2": "翻唱", "sub_tid": 32, "sub_tname": "演奏",
    ])
    XCTAssertEqual(parsed.partitionID, 31)
    XCTAssertEqual(parsed.subpartitionID, 32)
    XCTAssertEqual(parsed.subpartitionName, "演奏")
  }

  func testPersistedFilterDropsInvalidAndDuplicateRules() throws {
    let data = Data("""
      {"rules":[
        {"id":"00000000-0000-0000-0000-000000000001","kind":"author","valueID":42,"name":"Creator"},
        {"id":"00000000-0000-0000-0000-000000000002","kind":"author","valueID":42,"name":"Duplicate"},
        {"id":"00000000-0000-0000-0000-000000000003","kind":"author","valueID":0,"name":"Invalid"},
        {"id":"00000000-0000-0000-0000-000000000004","kind":"author","valueID":43,"name":"   "}
      ]}
      """.utf8)
    let filter = try JSONDecoder().decode(RecommendationFilter.self, from: data)
    XCTAssertEqual(filter.rules.count, 1)
    XCTAssertEqual(filter.rules.first?.valueID, 42)
  }

  func testLegacyFilterWithoutVideoFeedbackStillDecodes() throws {
    let data = Data("""
      {"rules":[{"id":"00000000-0000-0000-0000-000000000001","kind":"author","valueID":42,"name":"Creator"}]}
      """.utf8)
    let filter = try JSONDecoder().decode(RecommendationFilter.self, from: data)
    XCTAssertEqual(filter.rules.count, 1)
    XCTAssertTrue(filter.hiddenVideos.isEmpty)
    XCTAssertTrue(filter.filters(video()))
  }

  func testHiddenVideoPrefersBVIDAndFallsBackToPositiveAID() {
    var filter = RecommendationFilter()
    XCTAssertTrue(filter.hide(video(bvid: "BV1fixture001", aid: 1)))
    XCTAssertTrue(filter.filters(video(bvid: " BV1fixture001 ", aid: 999)))
    XCTAssertFalse(filter.filters(video(bvid: "", aid: 1)))

    XCTAssertTrue(filter.hide(video(bvid: "", aid: 2)))
    XCTAssertTrue(filter.filters(video(bvid: "", aid: 2)))
    XCTAssertFalse(filter.filters(video(bvid: "", aid: 3)))
    XCTAssertFalse(filter.hide(video(bvid: "", aid: nil)))
    XCTAssertFalse(filter.hide(video(bvid: "   ", aid: 0)))
    XCTAssertEqual(filter.hiddenVideos.map(\.id), ["bvid:BV1fixture001", "av:2"])
  }

  func testHiddenVideoDeduplicationIsIndependentFromRules() {
    var filter = RecommendationFilter()
    let hidden = video(aid: 1)
    XCTAssertTrue(filter.hide(hidden))
    XCTAssertFalse(filter.hide(video(aid: 2)))
    XCTAssertEqual(filter.hiddenVideos.count, 1)

    let rule = RecommendationFilterRule(kind: .author, valueID: 42, name: "Creator")
    XCTAssertTrue(filter.add(rule))
    XCTAssertTrue(filter.removeHiddenVideo(id: "bvid:BV1fixture001"))
    XCTAssertFalse(filter.hides(hidden))
    XCTAssertTrue(filter.filters(hidden))
    filter.remove(id: rule.id)
    XCTAssertFalse(filter.filters(hidden))
  }

  func testPersistedVideoFeedbackDropsDuplicatesAndInvalidIdentities() throws {
    let data = Data("""
      {"rules":[],"hiddenVideos":[
        {"bvid":"BV1fixture001","aid":1,"title":"First"},
        {"bvid":"BV1fixture001","aid":2,"title":"Duplicate"},
        {"bvid":"","aid":7,"title":"Fallback"},
        {"bvid":"   ","aid":0,"title":"Invalid"}
      ]}
      """.utf8)
    let filter = try JSONDecoder().decode(RecommendationFilter.self, from: data)
    XCTAssertEqual(filter.hiddenVideos.map(\.id), ["bvid:BV1fixture001", "av:7"])
    XCTAssertEqual(filter.hiddenVideos.first?.title, "First")
    XCTAssertTrue(filter.filters(video(bvid: "", aid: 7)))
  }
}
