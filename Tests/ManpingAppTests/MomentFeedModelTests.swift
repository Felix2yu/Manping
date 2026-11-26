#if DEBUG
import AppKit
import GRPCCore
import ManpingCore
import SwiftProtobuf
import XCTest

@testable import ManpingApp

private struct MomentNoCredentials: AuthCredentialStore {
  func load() -> [HTTPCookie] { [] }
  func save(_ cookies: [HTTPCookie]) {}
  func loadToken() -> AppToken? {
    AppToken(mid: 123, accessToken: "fixture-access", refreshToken: "fixture-refresh", expiresAt: 9_999_999_999)
  }
  func saveToken(_ value: AppToken?) {}
  func clear() {}
}

private struct MomentOffline: AuthTransport {
  func send(_ request: URLRequest) async throws -> AuthHTTPResponse { throw URLError(.notConnectedToInternet) }
}

private final class MomentDynamicTransport: BiliRPCTransport, @unchecked Sendable {
  private let lock = NSLock()
  private var requestCount = 0
  private var held = false
  private var waiters: Set<UUID> = []

  var count: Int { lock.withLock { requestCount } }
  func hold() { lock.withLock { held = true } }
  func release() {
    lock.withLock {
      held = false
      waiters.removeAll()
    }
  }
  func unary<Request: SwiftProtobuf.Message, Response: SwiftProtobuf.Message>(
    _ request: Request, response: Response.Type, descriptor: MethodDescriptor, metadata: Metadata
  ) async throws -> Response {
    let shouldHold: Bool = lock.withLock {
      requestCount += 1
      let shouldHold = held; held = false
      if shouldHold { waiters.insert(UUID()) }
      return shouldHold
    }
    if shouldHold {
      let waiter = lock.withLock { waiters.first! }
      defer { _ = lock.withLock { waiters.remove(waiter) } }
      while lock.withLock({ waiters.contains(waiter) }) { try await Task.sleep(for: .milliseconds(5)) }
    }
    return Response()
  }
  func shutdown(grace: Duration) async {}
}

private actor MomentPagedRPCService: BiliRPCService {
  private let pages: [RPCDynamicPage]
  private(set) var offsets: [String] = []

  init(pages: [RPCDynamicPage]) { self.pages = pages }

  func dynamics(_ query: RPCDynamicQuery) async throws -> RPCDynamicPage {
    let offset: String
    switch query {
    case .all(let value, _), .video(let value, _): offset = value
    default: fatalError("Unexpected dynamic query")
    }
    offsets.append(offset)
    let index = offsets.count - 1
    guard pages.indices.contains(index) else { throw BiliRPCError.invalidPayload("test page") }
    return pages[index]
  }
  func comments(oid: Int64, targetType: Int32, sort: RPCCommentSort, next: Int64) async throws -> RPCCommentPage { fatalError() }
  func commentDetails(oid: Int64, targetType: Int32, root: Int64, sort: RPCCommentSort, next: Int64) async throws -> RPCCommentPage { fatalError() }
  func history(business: String, max: Int64) async throws -> RPCHistoryPage { fatalError() }
  func popular(index: Int64, version: String) async throws -> RPCPopularPage { fatalError() }
  func ranking(region: Int32) async throws -> [RPCVideoCard] { fatalError() }
  func shutdown() async {}
}

private func momentRows(_ count: Int, start: Int = 0, video: Bool = false) throws -> [RPCDynamic] {
  try (start..<(start + count)).map { id in
    let content = try JSONEncoder().encode(video ? RPCDynamicContent.video(
      RPCVideoCard(aid: Int64(id), bvid: "BV\(id)", cid: Int64(id), title: "视频 \(id)", cover: nil,
        author: nil, duration: 60, views: 1, uri: "")) : RPCDynamicContent.text)
    let json = """
      {"id":"\(id)","author":{"mid":7,"name":"作者","avatar":null},"timeLabel":"刚刚","text":"","emotes":[],"likes":8,"replies":0,"reposts":0,"liked":false,"commentTargetType":1,"commentTargetID":"\(id)","content":\(String(decoding: content, as: UTF8.self))}
      """
    return try JSONDecoder().decode(RPCDynamic.self, from: Data(json.utf8))
  }
}

@MainActor final class MomentFeedModelTests: XCTestCase {
  private func model(transport: BiliRPCTransport) async throws -> AppModel {
    _ = NSApplication.shared
    let service = BiliService(transport: MomentOffline(), credentials: MomentNoCredentials())
    try await service.restoreCookies()
    return AppModel(probeService: service, libraryRPCTransport: transport, observeIdentity: false)
  }

  private func model(rpc: any BiliRPCService) async throws -> AppModel {
    _ = NSApplication.shared
    let service = BiliService(transport: MomentOffline(), credentials: MomentNoCredentials())
    try await service.restoreCookies()
    let app = AppModel(probeService: service, observeIdentity: false)
    app.libraryStandardRPC = rpc
    return app
  }

  private func settle() async {
    for _ in 0..<40 { await Task.yield() }
  }

  private func eventually(_ condition: () -> Bool) async throws {
    for _ in 0..<200 {
      if condition() { return }
      try await Task.sleep(for: .milliseconds(5))
    }
    XCTFail("Timed out waiting for the moment feed")
  }

  func testVideoBatchMatchesViewportCapacity() {
    XCTAssertEqual(MomentVideoGridMetrics.batchSize(for: CGSize(width: 400, height: 400)), 4)
    XCTAssertEqual(MomentVideoGridMetrics.batchSize(for: CGSize(width: 600, height: 600)), 12)
    XCTAssertEqual(MomentVideoGridMetrics.batchSize(for: CGSize(width: 1200, height: 1000)), 32)
    XCTAssertEqual(MomentVideoGridMetrics.batchSize(for: CGSize(width: 2000, height: 1200)), 70)
    XCTAssertEqual(MomentVideoGridMetrics.batchSize(for: CGSize(width: 0, height: 600)), 2)
  }

  func testVideoFeedAppendsViewportSizedBatchesWithoutExtraRequests() async throws {
    let rows = try momentRows(45, video: true)
    let rpc = MomentPagedRPCService(pages: [
      RPCDynamicPage(items: rows, historyOffset: "end", updateBaseline: "", hasMore: false)
    ])
    let app = try await model(rpc: rpc)
    defer { app.shutdown() }
    let feed = MomentFeedModel(model: app)
    feed.updateViewport(CGSize(width: 600, height: 600))

    await feed.start(section: .video)
    XCTAssertEqual(feed.items, Array(rows.prefix(12)))
    XCTAssertTrue(feed.hasMore)
    await settle()
    let initialOffsets = await rpc.offsets
    XCTAssertEqual(initialOffsets, [""])

    await feed.loadNext()
    XCTAssertEqual(feed.items, Array(rows.prefix(24)))
    await feed.loadNext()
    XCTAssertEqual(feed.items, Array(rows.prefix(36)))
    await feed.loadNext()
    XCTAssertEqual(feed.items, rows)
    XCTAssertFalse(feed.hasMore)
    XCTAssertFalse(feed.loading)
    let finalOffsets = await rpc.offsets
    XCTAssertEqual(finalOffsets, [""])
    feed.cancel()
  }

  func testLargerViewportConsumesExistingBufferWithoutAnotherRequest() async throws {
    let rows = try momentRows(45, video: true)
    let rpc = MomentPagedRPCService(pages: [
      RPCDynamicPage(items: rows, historyOffset: "end", updateBaseline: "", hasMore: false)
    ])
    let app = try await model(rpc: rpc)
    defer { app.shutdown() }
    let feed = MomentFeedModel(model: app)
    feed.updateViewport(CGSize(width: 600, height: 600))

    await feed.start(section: .video)
    XCTAssertEqual(feed.items.count, 12)
    feed.updateViewport(CGSize(width: 1200, height: 1000))
    XCTAssertEqual(feed.items, Array(rows.prefix(32)))
    let offsetsAfterResize = await rpc.offsets
    XCTAssertEqual(offsetsAfterResize, [""])

    feed.updateViewport(CGSize(width: 600, height: 600))
    XCTAssertEqual(feed.items.count, 32, "shrinking the viewport must not discard visible rows")
    await feed.loadNext()
    XCTAssertEqual(feed.items, Array(rows.prefix(44)))
    await feed.loadNext()
    XCTAssertEqual(feed.items, rows)
    let finalOffsets = await rpc.offsets
    XCTAssertEqual(finalOffsets, [""])
    feed.cancel()
  }

  func testVideoFeedRequestsNextRemotePageOnlyAfterBufferedItemsAreConsumed() async throws {
    let first = try momentRows(45, video: true)
    let second = try momentRows(5, start: 45, video: true)
    let rpc = MomentPagedRPCService(pages: [
      RPCDynamicPage(items: first, historyOffset: "next", updateBaseline: "baseline", hasMore: true),
      RPCDynamicPage(items: second, historyOffset: "end", updateBaseline: "baseline", hasMore: false)
    ])
    let app = try await model(rpc: rpc)
    defer { app.shutdown() }
    let feed = MomentFeedModel(model: app)
    feed.updateViewport(CGSize(width: 600, height: 600))

    await feed.start(section: .video)
    await feed.loadNext()
    await feed.loadNext()
    await feed.loadNext()
    XCTAssertEqual(feed.items.count, 45)
    let initialOffsets = await rpc.offsets
    XCTAssertEqual(initialOffsets, [""])

    await feed.loadNext()
    XCTAssertEqual(feed.items, first + second)
    XCTAssertFalse(feed.hasMore)
    let offsets = await rpc.offsets
    XCTAssertEqual(offsets, ["", "next"])
    feed.cancel()
  }

  func testBufferedAndRemotePagesDeduplicateWithoutSkippingNewItems() async throws {
    let first = try momentRows(25, video: true)
    let second = try momentRows(6, start: 24, video: true)
    let rpc = MomentPagedRPCService(pages: [
      RPCDynamicPage(items: first, historyOffset: "next", updateBaseline: "", hasMore: true),
      RPCDynamicPage(items: second, historyOffset: "end", updateBaseline: "", hasMore: false)
    ])
    let app = try await model(rpc: rpc)
    defer { app.shutdown() }
    let feed = MomentFeedModel(model: app)
    feed.updateViewport(CGSize(width: 600, height: 600))

    await feed.start(section: .video)
    await feed.loadNext()
    await feed.loadNext()
    await feed.loadNext()
    XCTAssertEqual(feed.items, first + second.dropFirst())
    XCTAssertFalse(feed.hasMore)
    let offsets = await rpc.offsets
    XCTAssertEqual(offsets, ["", "next"])
    feed.cancel()
  }

  func testRefreshDiscardsBufferedItemsFromPreviousPage() async throws {
    let first = try momentRows(45)
    let refreshed = try momentRows(3, start: 100)
    let rpc = MomentPagedRPCService(pages: [
      RPCDynamicPage(items: first, historyOffset: "next", updateBaseline: "", hasMore: true),
      RPCDynamicPage(items: refreshed, historyOffset: "end", updateBaseline: "", hasMore: false)
    ])
    let app = try await model(rpc: rpc)
    defer { app.shutdown() }
    let feed = MomentFeedModel(model: app)
    feed.updateViewport(CGSize(width: 600, height: 1200))

    await feed.start(section: .comprehensive)
    XCTAssertEqual(feed.items.count, 10)
    await feed.refresh()
    XCTAssertEqual(feed.items, refreshed)
    XCTAssertFalse(feed.hasMore)
    let offsets = await rpc.offsets
    XCTAssertEqual(offsets, ["", ""])
    feed.cancel()
  }

  func testSuspendAndReactivateKeepRowsCursorAndUsersWithoutRequesting() async throws {
    let transport = MomentDynamicTransport()
    let app = try await model(transport: transport)
    defer { app.shutdown() }
    let feed = MomentFeedModel(model: app)
    await feed.start(section: .comprehensive)
    try await eventually { !feed.loading }
    XCTAssertEqual(transport.count, 1, feed.error ?? "no error")
    feed.cancel()
    await settle()
    XCTAssertTrue(feed.items.isEmpty)
    let row = try JSONDecoder().decode(RPCDynamic.self, from: Data(#"{"id":"100","author":{"mid":7,"name":"作者","avatar":null},"timeLabel":"刚刚","text":"","emotes":[],"likes":8,"replies":0,"reposts":0,"liked":false,"commentTargetType":1,"commentTargetID":"100","content":{"text":{}}}"#.utf8))
    let page = RPCDynamicPage(items: [row], historyOffset: "cursor-1", updateBaseline: "baseline-1",
      hasMore: false, users: [RPCDynamicProfile(id: 7, name: "作者", avatar: nil, hasUnread: true, isLive: false)])
    feed.debugRestore(page)
    feed.suspend()
    await settle()
    XCTAssertEqual(transport.count, 1)
    XCTAssertEqual(feed.items, page.items)
    XCTAssertEqual(feed.users, page.users)
    await feed.activate()
    await settle()
    XCTAssertEqual(transport.count, 1)
    feed.cancel()
  }

  func testReturnRetriesAnInterruptedInitialPageWithoutClearingCompletedRows() async throws {
    let transport = MomentDynamicTransport()
    let app = try await model(transport: transport)
    defer { app.shutdown() }
    let feed = MomentFeedModel(model: app)
    transport.hold()
    let initial = Task { await feed.start(section: .comprehensive) }
    try await eventually { transport.count == 1 && feed.loading }
    XCTAssertEqual(transport.count, 1, feed.error ?? "no error")
    feed.suspend()
    await initial.value
    XCTAssertTrue(feed.items.isEmpty)
    XCTAssertTrue(feed.hasMore)
    await feed.activate()
    try await eventually { transport.count == 2 && !feed.loading }
    transport.release()
    try await eventually { !feed.loading }
    XCTAssertEqual(transport.count, 2)
    feed.suspend()
    await feed.activate()
    await settle()
    XCTAssertEqual(transport.count, 2)
    feed.cancel()
  }
}
#endif
