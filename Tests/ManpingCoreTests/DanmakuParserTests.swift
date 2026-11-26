import XCTest
@testable import ManpingCore

final class DanmakuParserTests: XCTestCase {
  func testLimitSamplesDeterministicallyAndKeepsChronologicalOrder() throws {
    let xml = "<i>" + (0..<5_000).reversed().map { index in
      "<d p=\"\(index),1,25,16777215,0,0,hash,\(index),0\">Line \(index)</d>"
    }.joined() + "</i>"
    let data = Data(xml.utf8)
    let first = try DanmakuParser.parse(data, limit: 1_000)
    let second = try DanmakuParser.parse(data, limit: 1_000)

    XCTAssertEqual(first.count, 1_000)
    XCTAssertEqual(first, second)
    XCTAssertEqual(first.map(\.time), first.map(\.time).sorted())
    XCTAssertTrue(first.allSatisfy { $0.text.hasPrefix("Line ") && $0.userHash == "hash" })
  }

  func testParsingKeepsExactXMLTextAndDoesNotInventDisplayAggregation() throws {
    let xml = """
      <i><d p="1,1,25,16777215,0,0,user,1,0">干杯</d>
      <d p="1.1,1,25,16777215,0,0,user,2,0">干杯</d>
      <d p="1.2,5,25,16777215,0,0,user,3,0">  原文 &amp; 符号  </d></i>
      """
    let comments = try DanmakuParser.parse(Data(xml.utf8))
    XCTAssertEqual(comments.map(\.text), ["干杯", "干杯", "  原文 & 符号  "])
    XCTAssertTrue(comments.allSatisfy { $0.displayText == nil && $0.displayedText == $0.text })
    XCTAssertEqual(comments.last?.mode, 5)
  }
}
