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

@MainActor final class MomentFeedModelTests: XCTestCase {
  private func model(transport: BiliRPCTransport) async throws -> AppModel {
    _ = NSApplication.shared
    let service = BiliService(transport: MomentOffline(), credentials: MomentNoCredentials())
    try await service.restoreCookies()
    return AppModel(probeService: service, libraryRPCTransport: transport, observeIdentity: false)
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
