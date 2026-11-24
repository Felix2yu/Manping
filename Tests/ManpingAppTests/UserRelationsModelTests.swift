import Foundation
import ManpingCore
import XCTest

@testable import ManpingApp

private final class RelationTestStore: AuthCredentialStore, @unchecked Sendable {
  private let token: AppToken?
  init(authenticated: Bool) {
    token = authenticated ? AppToken(mid: 123, accessToken: "fixture-relation-access",
      refreshToken: "fixture-relation-refresh", expiresAt: 9_999_999_999) : nil
  }
  func load() -> [HTTPCookie] { [] }
  func save(_ cookies: [HTTPCookie]) {}
  func loadToken() -> AppToken? { token }
  func saveToken(_ value: AppToken?) {}
  func clear() {}
}

private actor RelationTestTransport: AuthTransport {
  private(set) var requests: [URLRequest] = []
  func send(_ request: URLRequest) async throws -> AuthHTTPResponse {
    requests.append(request)
    return AuthHTTPResponse(body: Data(#"{"code":0,"data":{"attribute":2}}"#.utf8),
      response: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
  }
}

@MainActor final class UserRelationsModelTests: XCTestCase {
  private func service(_ transport: RelationTestTransport, authenticated: Bool) async throws -> BiliService {
    let service = BiliService(transport: transport, credentials: RelationTestStore(authenticated: authenticated),
      now: { Date(timeIntervalSince1970: 1000) })
    try await service.restoreCookies()
    return service
  }

  func testUnknownSignedOutRelationOpensLoginInsteadOfDisablingTheButton() async throws {
    let transport = RelationTestTransport()
    let model = UserRelationsModel(service: try await service(transport, authenticated: false))
    defer { model.cancel() }
    var requestedLogin = false
    XCTAssertTrue(model.canToggle(42))
    await model.toggle(mid: 42) { requestedLogin = true }
    XCTAssertTrue(requestedLogin)
    XCTAssertTrue(model.canToggle(42))
    XCTAssertEqual(model.relations[42], .unknown)
    XCTAssertTrue(model.busy.isEmpty)
    let requests = await transport.requests
    XCTAssertTrue(requests.isEmpty)
  }

  func testUnknownSignedInRelationLoadsBeforeTheNextClickMutates() async throws {
    let transport = RelationTestTransport()
    let model = UserRelationsModel(service: try await service(transport, authenticated: true))
    defer { model.cancel() }
    var requestedLogin = false
    await model.toggle(mid: 42) { requestedLogin = true }
    XCTAssertFalse(requestedLogin)
    XCTAssertEqual(model.relations[42], .following)
    var requests = await transport.requests
    XCTAssertEqual(requests.map { $0.url?.path }, ["/x/relation"])

    await model.toggle(mid: 42) { requestedLogin = true }
    requests = await transport.requests
    XCTAssertEqual(requests.map { $0.url?.path }, ["/x/relation", "/x/relation/modify"])
    XCTAssertEqual(model.relations[42], .unfollowed)
  }
}
