import Foundation
import ManpingCore
import XCTest

@testable import ManpingApp

@MainActor final class VideoPresentationTests: XCTestCase {
  func testWebLinkPrefersBVOverAID() {
    let video = Video(bvid: "BV1sample001", title: "视频", aid: 123)
    XCTAssertEqual(CardActions.webURL(video)?.absoluteString, "https://www.bilibili.com/video/BV1sample001")
  }

  func testWebLinkFallsBackToAIDOnlyWithoutBV() {
    let video = Video(bvid: "", title: "视频", aid: 123)
    XCTAssertEqual(CardActions.webURL(video)?.absoluteString, "https://www.bilibili.com/video/av123")
    XCTAssertNil(CardActions.webURL(Video(bvid: "", title: "视频")))
  }

  func testDynamicVideoUsesDescriptionWhenTitleIsMissing() throws {
    let item = try dynamic(text: "动态正文", title: "  ")
    XCTAssertEqual(MomentVideoCard.title(for: item), "动态正文")
  }

  func testDynamicVideoKeepsItsOwnTitleAndHasAFinalFallback() throws {
    let titled = try dynamic(text: "动态正文", title: "视频标题")
    let untitled = try dynamic(text: " ", title: "")
    XCTAssertEqual(MomentVideoCard.title(for: titled), "视频标题")
    XCTAssertEqual(MomentVideoCard.title(for: untitled), "视频")
  }

  private func dynamic(text: String, title: String) throws -> RPCDynamic {
    let json = """
    {"id":"dynamic-1","timeLabel":"","text":\(jsonString(text)),"emotes":[],"likes":0,
    "replies":0,"reposts":0,"liked":false,"commentTargetType":1,"commentTargetID":"1",
    "content":{"video":{"_0":{"aid":123,"bvid":"BV1sample001","cid":456,"title":\(jsonString(title)),
    "duration":60,"views":10,"uri":""}}}}
    """
    return try JSONDecoder().decode(RPCDynamic.self, from: Data(json.utf8))
  }

  private func jsonString(_ value: String) -> String {
    String(decoding: try! JSONEncoder().encode(value), as: UTF8.self)
  }
}
