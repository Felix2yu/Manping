#if DEBUG
import Combine
import ManpingCore
import XCTest

@testable import ManpingApp

@MainActor final class RecommendationFilterStoreTests: XCTestCase {
  func testRulesPersistAndFilterRecommendations() {
    let defaults = MemoryPreferences()
    let store = RecommendationFilterStore(defaults: defaults)
    let video = Video(bvid: "BV1fixture001", title: "Video", author: "Creator", authorID: 42)
    XCTAssertEqual(store.add(video: video, kind: .author), .added)
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

  func testSingleVideoHidePersistsAndUndoRestoresIt() {
    let defaults = MemoryPreferences()
    let store = RecommendationFilterStore(defaults: defaults)
    let video = Video(bvid: "BV1fixture001", title: "Video", aid: 1)
    XCTAssertTrue(store.hide(video: video))
    XCTAssertEqual(store.lastHide?.id, "bvid:BV1fixture001")
    XCTAssertTrue(store.filters(video))
    XCTAssertTrue(RecommendationFilterStore(defaults: defaults).filters(video))

    XCTAssertTrue(store.undoLastHide())
    XCTAssertNil(store.lastHide)
    XCTAssertFalse(store.filters(video))
    XCTAssertFalse(RecommendationFilterStore(defaults: defaults).filters(video))
    XCTAssertFalse(store.undoLastHide())
  }

  func testSingleVideoIdentityFallsBackToAIDOnlyWithoutBVID() {
    let store = RecommendationFilterStore(defaults: MemoryPreferences())
    XCTAssertTrue(store.hide(video: Video(bvid: "BV1fixture001", title: "BV", aid: 7)))
    XCTAssertFalse(store.filters(Video(bvid: "", title: "AV", aid: 7)))
    XCTAssertTrue(store.hide(video: Video(bvid: "", title: "AV", aid: 8)))
    XCTAssertTrue(store.filters(Video(bvid: "", title: "AV", aid: 8)))
    XCTAssertFalse(store.hide(video: Video(bvid: "", title: "Invalid")))
    XCTAssertEqual(store.filter.hiddenVideos.map(\.id), ["bvid:BV1fixture001", "av:8"])
  }

  func testUndoOnlyRemovesTheMostRecentHide() {
    let store = RecommendationFilterStore(defaults: MemoryPreferences())
    let first = Video(bvid: "BV-first", title: "First")
    let second = Video(bvid: "BV-second", title: "Second")
    XCTAssertTrue(store.hide(video: first))
    XCTAssertTrue(store.hide(video: second))
    XCTAssertEqual(store.lastHide?.id, "bvid:BV-second")
    XCTAssertTrue(store.undoLastHide())
    XCTAssertFalse(store.filters(second))
    XCTAssertTrue(store.filters(first))
    XCTAssertNil(store.lastHide)
    XCTAssertFalse(store.undoLastHide())
  }

  func testUndoStatePublishesHideAndRemoval() {
    let store = RecommendationFilterStore(defaults: MemoryPreferences())
    let observer = RecommendationHideObserver()
    let cancellable = store.$lastHide.sink { observer.append($0) }
    XCTAssertTrue(store.hide(video: Video(bvid: "BV-observed", title: "Observed")))
    XCTAssertTrue(store.undoLastHide())
    withExtendedLifetime(cancellable) {}
    XCTAssertEqual(observer.values.count, 3)
    XCTAssertNil(observer.values[0])
    XCTAssertEqual(observer.values[1]?.id, "bvid:BV-observed")
    XCTAssertNil(observer.values[2])
  }

  func testClearVideoFeedbackKeepsRulesAndPersists() {
    let defaults = MemoryPreferences()
    let store = RecommendationFilterStore(defaults: defaults)
    let video = Video(bvid: "BV-clear", title: "Clear", author: "Creator", authorID: 42)
    XCTAssertEqual(store.add(video: video, kind: .author), .added)
    XCTAssertTrue(store.hide(video: video))
    XCTAssertTrue(store.clearVideoFeedback())
    XCTAssertTrue(store.filter.hiddenVideos.isEmpty)
    XCTAssertEqual(store.filter.rules.count, 1)
    XCTAssertNil(store.lastHide)
    XCTAssertTrue(store.filters(video))
    let restored = RecommendationFilterStore(defaults: defaults)
    XCTAssertTrue(restored.filter.hiddenVideos.isEmpty)
    XCTAssertEqual(restored.filter.rules.count, 1)
  }

  func testHidePersistenceFailureRollsBackFilterAndUndoState() {
    let defaults = RecommendationFailingPreferences()
    let store = RecommendationFilterStore(defaults: defaults)
    let first = Video(bvid: "BV-first", title: "First")
    let second = Video(bvid: "BV-second", title: "Second")
    XCTAssertTrue(store.hide(video: first))
    let previousFilter = store.filter
    let previousUndo = store.lastHide
    let previousData = defaults.data(forKey: RecommendationFilterStore.key)

    defaults.rejectsWrites = true
    XCTAssertFalse(store.hide(video: second))
    XCTAssertEqual(store.filter, previousFilter)
    XCTAssertEqual(store.lastHide, previousUndo)
    XCTAssertEqual(defaults.data(forKey: RecommendationFilterStore.key), previousData)
  }

  func testUndoPersistenceFailureRollsBackFilterAndUndoState() {
    let defaults = RecommendationFailingPreferences()
    let store = RecommendationFilterStore(defaults: defaults)
    let video = Video(bvid: "BV-undo", title: "Undo")
    XCTAssertTrue(store.hide(video: video))
    let previousFilter = store.filter
    let previousUndo = store.lastHide
    let previousData = defaults.data(forKey: RecommendationFilterStore.key)

    defaults.rejectsWrites = true
    XCTAssertFalse(store.undoLastHide())
    XCTAssertEqual(store.filter, previousFilter)
    XCTAssertEqual(store.lastHide, previousUndo)
    XCTAssertEqual(defaults.data(forKey: RecommendationFilterStore.key), previousData)
  }

  func testClearPersistenceFailureRollsBackFilterAndUndoState() {
    let defaults = RecommendationFailingPreferences()
    let store = RecommendationFilterStore(defaults: defaults)
    XCTAssertTrue(store.hide(video: Video(bvid: "BV-clear", title: "Clear")))
    let previousFilter = store.filter
    let previousUndo = store.lastHide
    let previousData = defaults.data(forKey: RecommendationFilterStore.key)

    defaults.rejectsWrites = true
    XCTAssertFalse(store.clearVideoFeedback())
    XCTAssertEqual(store.filter, previousFilter)
    XCTAssertEqual(store.lastHide, previousUndo)
    XCTAssertEqual(defaults.data(forKey: RecommendationFilterStore.key), previousData)
  }
}

private final class RecommendationHideObserver: @unchecked Sendable {
  private let lock = NSLock()
  private var observed: [RecommendationHiddenVideo?] = []

  func append(_ value: RecommendationHiddenVideo?) { lock.withLock { observed.append(value) } }
  var values: [RecommendationHiddenVideo?] { lock.withLock { observed } }
}

private final class RecommendationFailingPreferences: PreferencesStore, @unchecked Sendable {
  private let storage = MemoryPreferences()
  private let lock = NSLock()
  private var writingFails = false

  var rejectsWrites: Bool {
    get { lock.withLock { writingFails } }
    set { lock.withLock { writingFails = newValue } }
  }

  func object(forKey defaultName: String) -> Any? { storage.object(forKey: defaultName) }
  func string(forKey defaultName: String) -> String? { storage.string(forKey: defaultName) }
  func data(forKey defaultName: String) -> Data? { storage.data(forKey: defaultName) }
  func integer(forKey defaultName: String) -> Int { storage.integer(forKey: defaultName) }
  func float(forKey defaultName: String) -> Float { storage.float(forKey: defaultName) }
  func double(forKey defaultName: String) -> Double { storage.double(forKey: defaultName) }
  func bool(forKey defaultName: String) -> Bool { storage.bool(forKey: defaultName) }
  func url(forKey defaultName: String) -> URL? { storage.url(forKey: defaultName) }
  func set(_ value: Any?, forKey defaultName: String) {
    guard !rejectsWrites else { return }
    storage.set(value, forKey: defaultName)
  }
  func set(_ value: Int, forKey defaultName: String) { set(value as Any, forKey: defaultName) }
  func set(_ value: Float, forKey defaultName: String) { set(value as Any, forKey: defaultName) }
  func set(_ value: Double, forKey defaultName: String) { set(value as Any, forKey: defaultName) }
  func set(_ value: Bool, forKey defaultName: String) { set(value as Any, forKey: defaultName) }
  func set(_ url: URL?, forKey defaultName: String) { set(url as Any?, forKey: defaultName) }
  func removeObject(forKey defaultName: String) { set(nil as Any?, forKey: defaultName) }
  func register(defaults registrationDictionary: [String: Any]) {
    guard !rejectsWrites else { return }
    storage.register(defaults: registrationDictionary)
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
