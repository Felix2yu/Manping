#if DEBUG
import ManpingCore
import XCTest

@testable import ManpingApp

@MainActor final class RecommendationFilterStoreTests: XCTestCase {
  func testRulesPersistAndFilterRecommendations() {
    let defaults = MemoryPreferences()
    let store = RecommendationFilterStore(defaults: defaults)
    let video = Video(bvid: "BV1fixture001", title: "Video", authorID: 42, author: "Creator")
    XCTAssertTrue(store.add(video, kind: .author))
    XCTAssertTrue(store.filters(video))
    let restored = RecommendationFilterStore(defaults: defaults)
    XCTAssertEqual(restored.filter, store.filter)
    XCTAssertTrue(restored.filters(video))
  }

  func testContextRuleRemovesOnlyTheSelectedRow() async {
    let feed = BrowseFeedModel(service: BiliService(transport: RecommendationOffline(), credentials: RecommendationNoCredentials()))
    let removed = Video(bvid: "BV-removed", title: "Removed", aid: 1)
    let retained = Video(bvid: "BV-retained", title: "Retained", aid: 2)
    feed.activate(key: "recommended", refreshToken: 0) { _ in
      BrowseVideoPage(items: [removed, retained], nextCursor: nil)
    }
    for _ in 0..<200 {
      if feed.state.items.count == 2 { break }
      await Task.yield()
    }
    feed.remove(videoID: removed.id)
    XCTAssertEqual(feed.state.items.map(\.id), [retained.id])
    feed.deactivate()
  }
}

private struct RecommendationOffline: AuthTransport {
  func send(_ request: URLRequest) async throws -> AuthHTTPResponse { throw URLError(.notConnectedToInternet) }
}

private struct RecommendationNoCredentials: AuthCredentialStore {
  func load() -> [HTTPCookie] { [] }
  func save(_ cookies: [HTTPCookie]) {}
  func loadToken() -> AppToken? { nil }
  func saveToken(_ value: AppToken?) {}
  func clear() {}
}
#endif
