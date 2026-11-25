import AppKit
import Foundation
import ManpingCore
import XCTest

@testable import ManpingApp

private final class HistoryTestStore: AuthCredentialStore, @unchecked Sendable {
  func load() -> [HTTPCookie] { [] }
  func save(_ cookies: [HTTPCookie]) {}
  func loadToken() -> AppToken? {
    AppToken(mid: 123, accessToken: "fixture-access", refreshToken: "fixture-refresh", expiresAt: 9_999_999_999)
  }
  func saveToken(_ value: AppToken?) {}
  func clear() {}
}

private actor HistoryTestTransport: AuthTransport {
  private(set) var requests: [URLRequest] = []
  private var failures = 0
  init(failures: Int = 0) { self.failures = failures }
  func send(_ request: URLRequest) async throws -> AuthHTTPResponse {
    requests.append(request)
    if failures > 0 {
      failures -= 1
      throw URLError(.notConnectedToInternet)
    }
    return AuthHTTPResponse(body: Data(#"{"code":0,"message":"0","ttl":1,"data":{}}"#.utf8),
      response: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
  }
}

@MainActor final class WatchHistorySyncTests: XCTestCase {
  private func temporaryURL(_ name: String) -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("Manping-\(name)-\(UUID().uuidString).json")
  }

  private func response(_ request: URLRequest, status: Int = 200, body: String) -> (Data, URLResponse) {
    (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
  }

  private func wait(_ condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(3))
    while !condition() {
      guard ContinuousClock.now < deadline else { throw URLError(.timedOut) }
      try await Task.sleep(for: .milliseconds(5))
    }
  }

  private func waitForRequests(_ count: Int, transport: HistoryTestTransport) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(3))
    while await transport.requests.count < count {
      guard ContinuousClock.now < deadline else { throw URLError(.timedOut) }
      try await Task.sleep(for: .milliseconds(5))
    }
  }

  func testFailedQueryIsReplayedAfterSuccessfulConnectionTest() async throws {
    let cacheURL = temporaryURL("history-cache")
    let outboxURL = temporaryURL("history-outbox")
    defer { try? FileManager.default.removeItem(at: cacheURL); try? FileManager.default.removeItem(at: outboxURL) }
    var requests: [URLRequest] = []
    var failQuery = true
    let store = WatchHistoryStore(cacheURL: cacheURL, outboxURL: outboxURL, transport: { request in
      requests.append(request)
      if request.url!.path.hasSuffix("/query") {
        if failQuery {
          failQuery = false
          return self.response(request, status: 500, body: "{}")
        }
        return self.response(request, body: #"{"status":"success","data":{"BV1fixture":{"bvid":"BV1fixture","watched":true,"progress":42,"duration":100,"finished":false,"view_at":1234}}}"#)
      }
      return self.response(request, body: #"{"status":"success"}"#)
    })
    store.configure(enabled: true, baseURL: "https://fixture.invalid")
    store.request("BV1fixture")
    try await wait { requests.filter { $0.url!.path.hasSuffix("/query") }.count == 1 }
    XCTAssertEqual(store.record("BV1fixture"), nil)

    let result = await store.testConnection()
    XCTAssertEqual(result, "连接成功。")
    XCTAssertEqual(requests.filter { $0.url!.path.hasSuffix("/query") }.count, 2)
    XCTAssertEqual(store.record("BV1fixture")?.progress, 42)
  }

  func testFailedReportPersistsAndReplaysAfterSuccessfulConnectionTest() async throws {
    let cacheURL = temporaryURL("history-cache")
    let outboxURL = temporaryURL("history-outbox")
    defer { try? FileManager.default.removeItem(at: cacheURL); try? FileManager.default.removeItem(at: outboxURL) }
    var requests: [URLRequest] = []
    var failReport = true
    let store = WatchHistoryStore(cacheURL: cacheURL, outboxURL: outboxURL, transport: { request in
      requests.append(request)
      if request.url!.path.hasSuffix("/report") {
        if failReport {
          failReport = false
          return self.response(request, status: 500, body: "{}")
        }
        return self.response(request, body: #"{"status":"success"}"#)
      }
      return self.response(request, body: #"{"status":"success"}"#)
    })
    store.configure(enabled: true, baseURL: "https://fixture.invalid")
    let item = WatchProgressReporter.Item(aid: 1, cid: 2, bvid: "BV1fixture", title: "Fixture")
    store.report(item, seconds: 42)
    try await wait { requests.count == 1 }
    try await wait { store.serverStatus != nil }
    let persisted = try String(contentsOf: outboxURL, encoding: .utf8)
    XCTAssertTrue(persisted.contains("BV1fixture"))
    XCTAssertTrue(store.serverStatus != nil)

    _ = await store.testConnection()
    try await wait { requests.filter { $0.url!.path.hasSuffix("/report") }.count == 2 }
    try await wait { (try? String(contentsOf: outboxURL, encoding: .utf8)) == "{}" }
    XCTAssertNil(store.serverStatus)
  }

  func testOfficialHistoryRetriesTheSamePositionAfterAFailure() async throws {
    let transport = HistoryTestTransport(failures: 1)
    let service = BiliService(transport: transport, credentials: HistoryTestStore(), now: { Date(timeIntervalSince1970: 1000) })
    try await service.restoreCookies()
    let snapshot = await service.authSnapshot()
    var reports = 0
    let reporter = WatchProgressReporter(service: service, enabled: { true }, onReport: { _, _, _ in reports += 1 })
    let player = PlayerModel()
    defer { player.shutdown() }
    player.time = 42
    let item = WatchProgressReporter.Item(aid: 1, cid: 2, bvid: "BV1fixture")

    reporter.begin(item, player: player, identity: snapshot)
    reporter.flush()
    try await waitForRequests(1, transport: transport)
    try await Task.sleep(for: .milliseconds(20))
    reporter.begin(item, player: player, identity: snapshot)
    reporter.flush()
    try await waitForRequests(2, transport: transport)
    XCTAssertEqual(reports, 2)
  }

  func testSavedProgressSurvivesANewStoreAndResumesTheNextOpen() async throws {
    let cacheURL = temporaryURL("resume-history-cache")
    let outboxURL = temporaryURL("resume-history-outbox")
    defer { try? FileManager.default.removeItem(at: cacheURL); try? FileManager.default.removeItem(at: outboxURL) }
    let transport: @MainActor @Sendable (URLRequest) async throws -> (Data, URLResponse) = { request in
      (Data(#"{"status":"success"}"#.utf8), HTTPURLResponse(url: request.url!, statusCode: 200,
        httpVersion: nil, headerFields: nil)!)
    }
    let store = WatchHistoryStore(cacheURL: cacheURL, outboxURL: outboxURL, transport: transport)
    store.configure(enabled: true, baseURL: "https://fixture.invalid")
    let item = WatchProgressReporter.Item(aid: 10, cid: 20, bvid: "BV1fixture", duration: 100)
    store.report(item, seconds: 42)
    store.flushLocal()
    XCTAssertTrue((try? String(contentsOf: cacheURL, encoding: .utf8))?.contains("BV1fixture") == true)

    let restored = WatchHistoryStore(cacheURL: cacheURL, outboxURL: outboxURL, transport: transport)
    restored.configure(enabled: true, baseURL: "https://fixture.invalid")
    XCTAssertEqual(restored.record(item.bvid)?.progress, 42)

    _ = NSApplication.shared
    let service = BiliService(transport: HistoryTestTransport(), credentials: HistoryTestStore())
    let app = AppModel(probeService: service, observeIdentity: false)
    app.debugSuppressPlaybackWindows = true
    app.debugSetDefaultOpenMode(.mainWindow)
    app.debugSetWatchHistory(restored)
    defer { app.shutdown() }
    let video = Video(bvid: item.bvid, title: "Resume fixture", cid: item.cid, aid: item.aid)
    app.open(video, mode: .mainWindow)
    await app.debugVideoLoadRequest?.value
    XCTAssertEqual(app.debugRequestedStart, 42)
    restored.report(item, seconds: 73, sessionID: UUID())
    app.open(video, mode: .mainWindow)
    await app.debugVideoLoadRequest?.value
    XCTAssertEqual(app.debugRequestedStart, 73)
  }

  func testExplicitStartLinkOverridesTheSavedHistoryPosition() async throws {
    _ = NSApplication.shared
    let service = BiliService(transport: HistoryTestTransport(), credentials: HistoryTestStore())
    let app = AppModel(probeService: service, observeIdentity: false)
    app.debugSuppressPlaybackWindows = true
    app.debugSetDefaultOpenMode(.mainWindow)
    defer { app.shutdown() }
    let store = WatchHistoryStore(cacheURL: nil, outboxURL: nil)
    store.configure(enabled: true, baseURL: "https://fixture.invalid")
    let item = WatchProgressReporter.Item(aid: 10, cid: 20, bvid: "BV1fixture", duration: 100)
    store.report(item, seconds: 42)
    app.debugSetWatchHistory(store)
    let video = Video(bvid: item.bvid, title: "Resume fixture", cid: item.cid, aid: item.aid)
    app.open(video, startAt: 7, part: 1, mode: .mainWindow)
    await app.debugVideoLoadRequest?.value
    XCTAssertEqual(app.debugRequestedStart, 7)
  }

  func testLocalProgressIsSavedWhileServerSyncIsDisabled() async throws {
    let cacheURL = temporaryURL("local-history-cache")
    defer { try? FileManager.default.removeItem(at: cacheURL) }
    var requests = 0
    let store = WatchHistoryStore(cacheURL: cacheURL, outboxURL: nil, transport: { request in
      requests += 1
      return self.response(request, body: #"{"status":"success"}"#)
    })
    store.configure(enabled: false, baseURL: "")
    store.report(WatchProgressReporter.Item(aid: 10, cid: 20, bvid: "BV1fixture", duration: 100), seconds: 42)
    XCTAssertEqual(store.record("BV1fixture")?.progress, 42)
    try await wait { (try? String(contentsOf: cacheURL, encoding: .utf8))?.contains("BV1fixture") == true }
    let restored = WatchHistoryStore(cacheURL: cacheURL, outboxURL: nil)
    restored.configure(enabled: false, baseURL: "")
    XCTAssertEqual(restored.record("BV1fixture")?.progress, 42)
    XCTAssertEqual(requests, 0)
  }

  func testRewatchStartsANewSessionAndRejectsTheOldSession() {
    let store = WatchHistoryStore(cacheURL: nil, outboxURL: nil)
    store.configure(enabled: true, baseURL: "https://fixture.invalid")
    let item = WatchProgressReporter.Item(aid: 1, cid: 2, bvid: "BV1fixture", duration: 100)
    let oldSession = UUID(), newSession = UUID()
    store.report(item, seconds: 90, sessionID: oldSession)
    store.report(item, seconds: 5, sessionID: newSession)
    XCTAssertEqual(store.record("BV1fixture")?.progress, 5)
    XCTAssertEqual(store.record("BV1fixture")?.finished, false)
    store.report(item, seconds: 90, sessionID: oldSession)
    XCTAssertEqual(store.record("BV1fixture")?.progress, 5)
  }

  func testLateOfficialHistoryCannotOverwriteANewViewingSession() async throws {
    let cacheURL = temporaryURL("history-cache")
    let outboxURL = temporaryURL("history-outbox")
    defer { try? FileManager.default.removeItem(at: cacheURL); try? FileManager.default.removeItem(at: outboxURL) }
    var continuation: CheckedContinuation<[String: WatchRecord], Never>?
    let store = WatchHistoryStore(fetchOfficial: {
      await withCheckedContinuation { continuation = $0 }
    }, cacheURL: cacheURL, outboxURL: outboxURL, transport: { request in
      self.response(request, body: #"{"status":"success"}"#)
    })
    store.configure(enabled: true, baseURL: "https://fixture.invalid")
    store.refreshOfficial()
    store.report(WatchProgressReporter.Item(aid: 1, cid: 2, bvid: "BV1fixture", duration: 100),
      seconds: 5, sessionID: UUID())
    continuation?.resume(returning: ["BV1fixture": WatchRecord(bvid: "BV1fixture", watched: true,
      progress: 90, duration: 100, finished: true, viewAt: 1)])
    try await Task.sleep(for: .milliseconds(20))
    XCTAssertEqual(store.record("BV1fixture")?.progress, 5)
  }
}
