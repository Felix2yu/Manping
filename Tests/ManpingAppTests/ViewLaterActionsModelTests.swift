import Foundation
import ManpingCore
import XCTest

@testable import ManpingApp

private final class ViewLaterTestStore: AuthCredentialStore, @unchecked Sendable {
  private let token: AppToken?
  init(authenticated: Bool) {
    token = authenticated ? AppToken(mid: 123, accessToken: "fixture-later-access",
      refreshToken: "fixture-later-refresh", expiresAt: 9_999_999_999) : nil
  }
  func load() -> [HTTPCookie] { [] }
  func save(_ cookies: [HTTPCookie]) {}
  func loadToken() -> AppToken? { token }
  func saveToken(_ value: AppToken?) {}
  func clear() {}
}

private actor ViewLaterTestTransport: AuthTransport {
  private(set) var requests: [URLRequest] = []
  private var pending: CheckedContinuation<Void, Never>?
  private var waiter: CheckedContinuation<Void, Never>?
  private var held = false
  init(held: Bool = false) { self.held = held }
  func waitForRequest() async {
    if !requests.isEmpty { return }
    await withCheckedContinuation { waiter = $0 }
  }
  func release() { held = false; pending?.resume(); pending = nil }
  func send(_ request: URLRequest) async throws -> AuthHTTPResponse {
    requests.append(request); waiter?.resume(); waiter = nil
    if held { await withCheckedContinuation { pending = $0 } }
    return AuthHTTPResponse(body: Data(#"{"code":0,"data":{}}"#.utf8),
      response: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
  }
}

@MainActor final class ViewLaterActionsModelTests: XCTestCase {
  private func service(_ transport: ViewLaterTestTransport, authenticated: Bool) async throws -> BiliService {
    let service = BiliService(transport: transport, credentials: ViewLaterTestStore(authenticated: authenticated),
      now: { Date(timeIntervalSince1970: 1000) })
    try await service.restoreCookies()
    return service
  }

  func testSignedOutAdditionRequestsLoginWithoutSending() async throws {
    let transport = ViewLaterTestTransport()
    let model = ViewLaterActionsModel(service: try await service(transport, authenticated: false))
    var requestedLogin = false
    await model.add(8) { requestedLogin = true }
    XCTAssertTrue(requestedLogin)
    XCTAssertTrue(model.busyAIDs.isEmpty)
    XCTAssertNil(model.notice)
    let requests = await transport.requests
    XCTAssertTrue(requests.isEmpty)
  }

  func testConcurrentClicksSendOnceAndSuccessReportsNotice() async throws {
    let transport = ViewLaterTestTransport(held: true)
    let model = ViewLaterActionsModel(service: try await service(transport, authenticated: true))
    let first = Task { await model.add(8) {} }
    await transport.waitForRequest()
    XCTAssertTrue(model.isBusy(8))
    await model.add(8) {}
    await transport.release()
    await first.value
    await model.add(8) {}
    XCTAssertEqual(model.notice, "已加入稍后再看")
    XCTAssertFalse(model.isBusy(8))
    XCTAssertNil(model.error(for: 8))
    let requests = await transport.requests
    XCTAssertEqual(requests.count, 2)
    XCTAssertTrue(requests.allSatisfy { $0.url?.path == "/x/v2/history/toview/add" })
  }

  func testInvalidIdentifierNeverSendsOrRequestsLogin() async throws {
    let transport = ViewLaterTestTransport()
    let model = ViewLaterActionsModel(service: try await service(transport, authenticated: false))
    var requestedLogin = false
    await model.add(0) { requestedLogin = true }
    XCTAssertFalse(requestedLogin)
    XCTAssertNil(model.notice)
    let requests = await transport.requests
    XCTAssertTrue(requests.isEmpty)
  }
}
