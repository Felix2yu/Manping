import XCTest
@testable import ManpingCore

final class RecommendationFilterTests: XCTestCase {
  private func video(primary: Int? = 1, secondary: Int? = 24, author: Int64? = 42) -> Video {
    Video(bvid: "BV1fixture001", title: "Video", author: "Creator", authorID: author,
      partitionID: primary, partitionName: "动画", subpartitionID: secondary, subpartitionName: "剪辑")
  }

  func testRulesFilterOnlyMatchingHomeRecommendations() {
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
}
