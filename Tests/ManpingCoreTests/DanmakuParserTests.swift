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
}
