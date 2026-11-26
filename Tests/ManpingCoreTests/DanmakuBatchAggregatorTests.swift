import XCTest
@testable import ManpingCore

final class DanmakuBatchAggregatorTests: XCTestCase {
  func testElevenIdenticalLiveVotesBecomeOneDisplayLineWithoutChangingChatOrXML() throws {
    var aggregator = DanmakuBatchAggregator()
    var history = LiveChatHistory()
    let xml = "<i>" + (0..<11).map { index in
      "<d p=\"10,1,25,16777215,0,0,user\(index),\(index),0\">干杯</d>"
    }.joined() + "</i>"
    let parsed = try DanmakuParser.parse(Data(xml.utf8))
    for (index, message) in parsed.enumerated() {
      let live = LiveDanmaku(uid: Int64(index + 1), user: "用户\(index)", text: message.text,
        color: message.color, mode: Int64(message.mode))
      history.add(live, accountMid: nil)
      XCTAssertTrue(aggregator.ingest(live, at: 10))
    }

    XCTAssertEqual(history.lines.count, 11)
    XCTAssertEqual(parsed.map(\.text), Array(repeating: "干杯", count: 11))
    XCTAssertTrue(parsed.allSatisfy { $0.displayText == nil })
    XCTAssertTrue(aggregator.flush(at: 10.09).isEmpty)
    let output = aggregator.flush(at: 11)
    XCTAssertEqual(output.count, 1)
    XCTAssertEqual(output.first?.text, "干杯")
    XCTAssertEqual(output.first?.displayText, "干杯 ×11")
    XCTAssertEqual(output.first?.time, 11)
    XCTAssertTrue(aggregator.flush(at: 11.1).isEmpty, "a published group must not be emitted again")
  }

  func testWindowIsMediaClockBasedAndCommentsAtTheBoundaryStartANewGroup() {
    var aggregator = DanmakuBatchAggregator()
    for time in [5.0, 5.5, 5.999] {
      aggregator.ingest(DanmakuComment(time: time, text: "干杯"), at: time)
    }
    aggregator.ingest(DanmakuComment(time: 6, text: "干杯"), at: 6)

    let first = aggregator.flush(at: 6)
    XCTAssertEqual(first.map(\.displayText), ["干杯 ×3"])
    XCTAssertEqual(first.map(\.time), [6])
    XCTAssertEqual(aggregator.pendingCount, 1)
    let second = aggregator.flush(at: 7)
    XCTAssertEqual(second.map(\.displayText), [nil], "a single line keeps its original text")
    XCTAssertEqual(second.map(\.text), ["干杯"])
  }

  func testPauseDoesNotAdvanceTheWindowAcrossWallClockFlushes() {
    var aggregator = DanmakuBatchAggregator()
    aggregator.ingest(DanmakuComment(time: 20, text: "暂停也计数"), at: 20)
    for _ in 0..<100 { XCTAssertTrue(aggregator.flush(at: 20).isEmpty) }
    XCTAssertTrue(aggregator.flush(at: 20.999).isEmpty)
    let output = aggregator.flush(at: 21)
    XCTAssertEqual(output.count, 1)
    XCTAssertEqual(output.first?.displayText, nil)
  }

  func testExactTextColorAndModeKeysKeepDifferentGroupsSeparate() {
    var aggregator = DanmakuBatchAggregator()
    let comments = [
      DanmakuComment(time: 0, color: 0xffffff, text: "干杯"),
      DanmakuComment(time: 0.1, color: 0xffffff, text: "干杯"),
      DanmakuComment(time: 0.2, color: 0xff0000, text: "干杯"),
      DanmakuComment(time: 0.3, color: 0xff0000, text: "干杯"),
      DanmakuComment(time: 0.4, color: 0xffffff, text: "干杯 "),
      DanmakuComment(time: 0.5, color: 0xffffff, text: "干杯 "),
    ]
    for (index, comment) in comments.enumerated() {
      XCTAssertTrue(aggregator.ingest(comment, at: comment.time), "ingest \(index)")
      XCTAssertEqual(aggregator.pendingCount, [1, 1, 2, 2, 3, 3][index], "groups after \(index)")
    }
    let output = aggregator.flush(at: 1.4)
    XCTAssertEqual(output.map(\.displayText), ["干杯 ×2", "干杯 ×2", "干杯  ×2"])
    XCTAssertEqual(output.map(\.color), [0xffffff, 0xff0000, 0xffffff])
  }

  func testSpecialModesEmotesRepliesAndUnknownTypesPassThrough() {
    var aggregator = DanmakuBatchAggregator()
    let messages = [
      LiveDanmaku(user: "a", text: "顶部", mode: 5),
      LiveDanmaku(user: "b", text: "底部", mode: 4),
      LiveDanmaku(user: "c", text: "高级", mode: 7),
      LiveDanmaku(user: "d", text: "表情", emotes: .object(["1": .string("url")])),
      LiveDanmaku(user: "e", text: "房间表情", roomEmote: .object(["1": .string("url")])),
      LiveDanmaku(user: "f", text: "回复", reply: .object(["reply_mid": .integer(1)])),
      LiveDanmaku(user: "g", text: "特殊", dmType: 1),
      LiveDanmaku(user: "h", text: "专属表情", emoticonUnique: "emoticon-1"),
    ]
    for (index, message) in messages.enumerated() {
      XCTAssertTrue(aggregator.ingest(message, at: Double(index) / 10))
      XCTAssertTrue(aggregator.ingest(message, at: Double(index) / 10))
    }
    let output = aggregator.flush(at: 0.9)
    XCTAssertEqual(output.count, 16)
    XCTAssertTrue(output.allSatisfy { $0.displayText == nil })
    XCTAssertEqual(output.map(\.text), messages.flatMap { [$0.text, $0.text] })
    XCTAssertEqual(aggregator.pendingCount, 0)
  }

  func testDisabledAggregationKeepsEveryOriginalLine() {
    var aggregator = DanmakuBatchAggregator(configuration: .init(enabled: false))
    for _ in 0..<11 { aggregator.ingest(LiveDanmaku(user: "u", text: "干杯"), at: 3) }
    let output = aggregator.flush(at: 3.1)
    XCTAssertEqual(output.count, 11)
    XCTAssertTrue(output.allSatisfy { $0.text == "干杯" && $0.displayText == nil })
  }

  func testGroupLimitPassesNewKeysThroughAndCountLimitSealsWithoutDropping() {
    var limitedGroups = DanmakuBatchAggregator(configuration: .init(maximumGroups: 2))
    limitedGroups.ingest(DanmakuComment(time: 0, text: "A"), at: 0)
    limitedGroups.ingest(DanmakuComment(time: 0, text: "A"), at: 0)
    limitedGroups.ingest(DanmakuComment(time: 0, text: "B"), at: 0)
    limitedGroups.ingest(DanmakuComment(time: 0, text: "C"), at: 0)
    XCTAssertEqual(limitedGroups.pendingCount, 2)
    let output = limitedGroups.flush(at: 1)
    XCTAssertEqual(output.map(\.displayText), ["A ×2", nil, nil])
    XCTAssertEqual(output.map(\.text), ["A", "B", "C"])

    var limitedCount = DanmakuBatchAggregator(configuration: .init(maximumCount: 3))
    for _ in 0..<7 { limitedCount.ingest(DanmakuComment(time: 2, text: "投票"), at: 2) }
    XCTAssertEqual(limitedCount.flush(at: 2.1).map(\.displayText), ["投票 ×3", "投票 ×3"])
    XCTAssertEqual(limitedCount.pendingCount, 1)
    XCTAssertEqual(limitedCount.flush(at: 3.1).map(\.displayText), [nil])
  }

  func testConfigurationDefaultsAndStoredLimitsAreBounded() {
    let defaults = MemoryPreferences()
    XCTAssertEqual(DanmakuBatchAggregator.Configuration.load(from: defaults), .init())
    defaults.set(false, forKey: DanmakuBatchAggregator.Configuration.enabledKey)
    defaults.set(-10, forKey: DanmakuBatchAggregator.Configuration.maximumGroupsKey)
    defaults.set(Int.max, forKey: DanmakuBatchAggregator.Configuration.maximumCountKey)
    let loaded = DanmakuBatchAggregator.Configuration.load(from: defaults)
    XCTAssertFalse(loaded.enabled)
    XCTAssertEqual(loaded.maximumGroups, 1)
    XCTAssertEqual(loaded.maximumCount, DanmakuBatchAggregator.Configuration.maximumAllowedCount)
  }

  func testResetClearsPendingSealedAndDirectOutputsAndAllowsClockRestart() {
    var aggregator = DanmakuBatchAggregator(configuration: .init(maximumCount: 2))
    aggregator.ingest(DanmakuComment(time: 50, text: "待合并"), at: 50)
    aggregator.ingest(DanmakuComment(time: 50, text: "已封口"), at: 50)
    aggregator.ingest(DanmakuComment(time: 50, text: "已封口"), at: 50)
    aggregator.ingest(DanmakuComment(time: 51, mode: 5, text: "直通"), at: 51)
    aggregator.reset()
    XCTAssertEqual(aggregator.pendingCount, 0)
    XCTAssertTrue(aggregator.flush(at: 0).isEmpty)
    XCTAssertTrue(aggregator.ingest(DanmakuComment(time: 0, text: "新流"), at: 0))
    XCTAssertEqual(aggregator.flush(at: 1).map(\.text), ["新流"])
  }

  func testOutputAndIngestRejectBackwardMediaTime() {
    var aggregator = DanmakuBatchAggregator()
    aggregator.ingest(DanmakuComment(time: 4, text: "现在"), at: 4)
    XCTAssertEqual(aggregator.flush(at: 5).map(\.time), [5])
    XCTAssertFalse(aggregator.ingest(DanmakuComment(time: 4.5, text: "陈旧"), at: 4.5))
    XCTAssertTrue(aggregator.flush(at: 4.5).isEmpty)
    aggregator.ingest(DanmakuComment(time: 5.1, mode: 5, text: "下一条"), at: 5.1)
    XCTAssertEqual(aggregator.flush(at: 5.2).map(\.time), [5.2])
  }

  func testFilteringAndAIMaterialUseOriginalTextWhileLaneWidthUsesDisplayText() throws {
    let comment = DanmakuComment(time: 0, text: "干杯", displayText: "干杯 ×11")
    XCTAssertTrue(DanmakuFilter(rules: ["/×11/"]).compiled().allows(comment))
    XCTAssertFalse(DanmakuFilter(rules: ["/^干杯$/"]).compiled().allows(comment))
    XCTAssertGreaterThan(DanmakuTimeline.estimatedLength(comment.displayedText),
      DanmakuTimeline.estimatedLength(comment.text))

    let short = DanmakuComment(time: 0, text: "干杯")
    let next = DanmakuComment(time: 0.9, text: "x")
    let original = DanmakuTimeline(comments: [short, next])
    let aggregated = DanmakuTimeline(comments: [comment, next])
    XCTAssertEqual(original.visible(at: 1.2).last?.lane, 0)
    XCTAssertEqual(aggregated.visible(at: 1.2).last?.lane, 1,
      "the count suffix must reserve a wider lane before placement")

    let originals = (0..<20).map { DanmakuComment(time: Double($0), text: "原文\($0)", displayText: "展示文本 ×11") }
    let digest = try XCTUnwrap(AIDanmakuDigest.make(originals, duration: 20))
    XCTAssertTrue(digest.allQuotes.allSatisfy { $0.text.hasPrefix("原文") && !$0.text.contains("×11") })
  }
}
