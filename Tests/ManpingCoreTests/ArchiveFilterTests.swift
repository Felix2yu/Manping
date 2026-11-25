import Foundation
import XCTest
@testable import ManpingCore

final class ArchiveFilterTests: XCTestCase {
  func testDurationPresetsCoverEveryPositiveBoundary() {
    let expected: [(ArchiveDurationFilter, Int?, Int?)] = [
      (.all, nil, nil), (.upTo5Minutes, 1, 300), (.fiveToTwentyMinutes, 301, 1200),
      (.twentyToSixtyMinutes, 1201, 3600), (.overSixtyMinutes, 3601, nil),
    ]
    for (filter, minimum, maximum) in expected {
      XCTAssertEqual(filter.minimumSeconds, minimum)
      XCTAssertEqual(filter.maximumSeconds, maximum)
    }
    XCTAssertTrue(ArchiveDurationFilter.all.contains(0))
    for filter in ArchiveDurationFilter.allCases where filter != .all {
      XCTAssertFalse(filter.contains(0))
      XCTAssertFalse(filter.contains(-1))
    }
    for duration in 1...7200 {
      let matches = ArchiveDurationFilter.allCases.filter { $0 != .all && $0.contains(duration) }
      XCTAssertEqual(matches.count, 1, "duration \(duration) must belong to exactly one preset")
    }
  }

  func testFilterStateCountsMainCategoryAndDurationOnce() {
    var filter = ArchiveHistoryFilter()
    XCTAssertTrue(filter.isEmpty)
    filter.subCategory = "科普"
    XCTAssertTrue(filter.isEmpty)
    XCTAssertEqual(filter.activeCount, 0)
    filter.mainCategory = "知识"
    filter.duration = .fiveToTwentyMinutes
    XCTAssertFalse(filter.isEmpty)
    XCTAssertEqual(filter.activeCount, 2)
  }

  func testNewArchivePageDecodesPartitionsAndFilteringCapability() throws {
    let page = try JSONDecoder().decode(ArchivePage.self, from: Data(#"{"records":[{"bvid":"BVfilter","title":"样本","cover":"","author":"作者","author_mid":12,"duration":600,"progress":60,"view_at":100,"finished":false,"main_category":"知识","sub_category":"科普"}],"next":200,"supports_filtering":true}"#.utf8))
    let video = try XCTUnwrap(page.records.first)
    XCTAssertEqual(video.mainCategory, "知识")
    XCTAssertEqual(video.subCategory, "科普")
    XCTAssertEqual(video.video.partitionName, "知识")
    XCTAssertEqual(video.video.subpartitionName, "科普")
    XCTAssertEqual(page.next, 200)
    XCTAssertEqual(page.supportsFiltering, true)
  }

  func testOldArchiveResponsesRemainDecodableWithoutFilteringFields() throws {
    let page = try JSONDecoder().decode(ArchivePage.self, from: Data(#"{"records":[{"bvid":"BVold","title":"旧样本","cover":"","author":"作者","author_mid":12,"duration":600,"progress":60,"view_at":100,"finished":false}],"next":0}"#.utf8))
    XCTAssertNil(page.records[0].mainCategory)
    XCTAssertNil(page.records[0].subCategory)
    XCTAssertNil(page.supportsFiltering)
    XCTAssertEqual(ArchivePage(records: [], next: 0).supportsFiltering, nil)
  }

  func testWatchLaterDecodesPartitionsForSharedCards() throws {
    let item = try JSONDecoder().decode(ArchiveWatchLaterItem.self, from: Data(#"{"bvid":"BVlater","title":"稍后再看样本","cover":"","author":"作者","duration":600,"add_at":300,"view":1,"main_category":"知识","sub_category":"科普"}"#.utf8))
    XCTAssertEqual(item.mainCategory, "知识")
    XCTAssertEqual(item.subCategory, "科普")
    XCTAssertEqual(item.video.partitionName, "知识")
    XCTAssertEqual(item.video.subpartitionName, "科普")
  }

  func testCategoryDirectoryDecodesSubcategoryIDs() throws {
    let categories = try JSONDecoder().decode([ArchiveCategory].self, from: Data(#"[{"name":"动画","sub_categories":[{"name":"MAD·AMV","alias":"MAD","tid":24}]}]"#.utf8))
    let animation = try XCTUnwrap(categories.first)
    XCTAssertEqual(animation.id, "动画")
    XCTAssertEqual(animation.subCategories.first?.id, "MAD·AMV")
    XCTAssertEqual(animation.subCategories.first?.tid, 24)
  }
}
