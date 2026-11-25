import XCTest
@testable import ManpingCore

final class BiliLinkParserTests: XCTestCase {
  func testWebLinks() {
    XCTAssertEqual(BiliLinkParser.parse("https://www.bilibili.com/video/BV1fK4y1t7hj/?spm_id_from=333&p=2"), .video(bvid: "BV1fK4y1t7hj", part: 2))
    XCTAssertEqual(BiliLinkParser.parse("https://m.bilibili.com/video/av170001"), .archive(aid: 170001))
    XCTAssertEqual(BiliLinkParser.parse("https://www.bilibili.com/bangumi/play/ep837204"), .episode(837204))
    XCTAssertEqual(BiliLinkParser.parse("https://www.bilibili.com/bangumi/play/ss12345?from=x"), .season(12345))
    XCTAssertEqual(BiliLinkParser.parse("https://live.bilibili.com/24530995?visit_id=1"), .live(24530995))
    XCTAssertEqual(BiliLinkParser.parse("https://live.bilibili.com/h5/7734200"), .live(7734200))
    XCTAssertEqual(BiliLinkParser.parse("https://space.bilibili.com/2/dynamic"), .space(2))
    XCTAssertEqual(BiliLinkParser.parse("https://www.bilibili.com/read/cv123456/"), .article(123456))
    XCTAssertEqual(BiliLinkParser.parse("https://b23.tv/AbC123"), .short(URL(string: "https://b23.tv/AbC123")!))
    XCTAssertEqual(BiliLinkParser.parse("https://search.bilibili.com/all?keyword=%E6%B5%8B%E8%AF%95"), .search("测试"))
    XCTAssertEqual(BiliLinkParser.parse("https://www.bilibili.com/v/channel/188"), .region(188))
  }

  func testShareTextIdentifiersAndAppScheme() {
    XCTAssertEqual(BiliLinkParser.parse("【4K 120FPS】你的设备顶得住吗？ https://b23.tv/xyz 复制打开"), .short(URL(string: "https://b23.tv/xyz")!))
    XCTAssertEqual(BiliLinkParser.parse("  bv1fK4y1t7hj "), .video(bvid: "BV1fK4y1t7hj"))
    XCTAssertEqual(BiliLinkParser.parse("AV170001"), .archive(aid: 170001))
    XCTAssertEqual(BiliLinkParser.parse("ss456"), .season(456))
    XCTAssertEqual(BiliLinkParser.parse("manpingx://video/BV1fK4y1t7hj"), .video(bvid: "BV1fK4y1t7hj"))
    XCTAssertEqual(BiliLinkParser.parse("manpingx://live/24530995"), .live(24530995))
    XCTAssertEqual(BiliLinkParser.parse("manpingx://article/cv42"), .article(42))
    XCTAssertEqual(BiliLinkParser.parse("manpingx://search?keyword=Swift"), .search("Swift"))
    XCTAssertEqual(BiliLinkParser.parse("manpingx://region/129"), .region(129))
    XCTAssertEqual(BiliLinkParser.parse("bilibili://video/BV1fK4y1t7hj"), .video(bvid: "BV1fK4y1t7hj"))
    XCTAssertEqual(BiliLinkParser.parse("bilibili://space/42"), .space(42))
    XCTAssertEqual(BiliLinkParser.parse("https://www.bilibili.com/video/BV1fK4y1t7hj?p=3&t=90.5"),
      .video(bvid: "BV1fK4y1t7hj", part: 3, startAt: 90.5))
    XCTAssertEqual(BiliLinkParser.parse("manpingx://video/BV1fK4y1t7hj?p=2&t=45"),
      .video(bvid: "BV1fK4y1t7hj", part: 2, startAt: 45))
    XCTAssertEqual(BiliLinkParser.parse("https://www.bilibili.com/video/BV1fK4y1t7hj?p=0&t=nan"),
      .video(bvid: "BV1fK4y1t7hj"))
  }

  func testRejectsForeignAndMalformedLinks() {
    for text in ["https://evil.example/video/BV1fK4y1t7hj", "https://www.bilibili.com.evil.example/video/BV1fK4y1t7hj",
      "https://user:pass@www.bilibili.com/video/BV1fK4y1t7hj", "ftp://www.bilibili.com/video/BV1fK4y1t7hj",
      "https://www.bilibili.com/video/BV1short", "av0", "ep-1", "manpingx://video/../../etc", "manpingx://unknown/1",
      "https://b23.tv/a/b", "manpingx://search?keyword=", "manpingx://region/0", "bilibili://unknown/1", "随便一段文字", "", String(repeating: "a", count: 3000)] {
      XCTAssertNil(BiliLinkParser.parse(text), text)
    }
    XCTAssertTrue(BiliLinkParser.isBilibili(URL(string: "https://www.bilibili.com/video/BV1fK4y1t7hj")!))
    XCTAssertFalse(BiliLinkParser.isBilibili(URL(string: "https://bilibili.com.evil.example/")!))
    XCTAssertFalse(BiliLinkParser.isBilibili(URL(string: "http://notbilibili.com/")!))
  }
}
