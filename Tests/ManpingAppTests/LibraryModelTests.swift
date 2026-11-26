#if DEBUG
import ManpingCore
import XCTest

@testable import ManpingApp

private struct LibraryNoCredentials: AuthCredentialStore {
  func load() -> [HTTPCookie] { [] }
  func save(_ cookies: [HTTPCookie]) {}
  func loadToken() -> AppToken? { nil }
  func saveToken(_ value: AppToken?) {}
  func clear() {}
}

private actor LibraryIdentityTransport: AuthTransport {
  private var continuation: CheckedContinuation<Void, Never>?
  private var released = false
  func release() { released = true; continuation?.resume(); continuation = nil }
  private(set) var searches = 0
  func send(_ request: URLRequest) async throws -> AuthHTTPResponse {
    let url = request.url!
    let data: [String: Any]
    switch url.path {
    case "/x/web-interface/nav":
      data = ["wbi_img": ["img_url": "https://fixture.invalid/00000000000000000000000000000000.png",
        "sub_url": "https://fixture.invalid/11111111111111111111111111111111.png"]]
    case "/x/web-interface/wbi/search/type":
      searches += 1
      let version = searches
      if version > 1 && !released { await withCheckedContinuation { continuation = $0 } }
      data = ["result": [["id": version, "title": "Account \(version)"]], "numPages": 1, "numResults": 1]
    default: throw URLError(.notConnectedToInternet)
    }
    return AuthHTTPResponse(body: try JSONSerialization.data(withJSONObject: ["code": 0, "data": data]),
      response: HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
  }
}

private actor LibrarySearchTransport: AuthTransport {
  private var requests: [[String: String]] = []
  private var continuations: [String: CheckedContinuation<Void, Never>] = [:]
  private var blocked = false
  private var released = false
  func release() {
    released = true
    continuations.values.forEach { $0.resume() }
    continuations.removeAll()
  }
  func send(_ request: URLRequest) async throws -> AuthHTTPResponse {
    let url = request.url!
    let fields = Dictionary(uniqueKeysWithValues: (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
    let data: [String: Any]
    if url.path == "/x/web-interface/nav" {
      data = ["wbi_img": ["img_url": "https://fixture.invalid/00000000000000000000000000000000.png",
        "sub_url": "https://fixture.invalid/11111111111111111111111111111111.png"]]
    } else {
      requests.append(fields)
      if fields["keyword"] == "old",
        fields["search_type"] == "video" || fields["search_type"] == "bili_user",
        !released {
        blocked = true
        await withCheckedContinuation { continuations[fields["search_type"] ?? "unknown"] = $0 }
      }
      let keyword = fields["keyword"] ?? "fixture"
      let item: [String: Any]
      if fields["search_type"] == "bili_user" {
        item = ["mid": 123, "uname": keyword, "sign": "user", "fans": 12, "level": 6]
      } else {
        item = ["id": keyword.utf8.reduce(0) { $0 + Int($1) }, "title": keyword,
          "duration": 1200, "pubdate": 1_760_000_000, "tid": 161, "mid": 123, "author": "owner"]
      }
      data = ["result": fields["page"] == "2" ? [] : [item], "numPages": 2, "numResults": 1]
    }
    return AuthHTTPResponse(body: try JSONSerialization.data(withJSONObject: ["code": 0, "data": data]),
      response: HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
  }
  func searchRequests() -> [[String: String]] { requests }
  func isBlocked() -> Bool { blocked }
}

@MainActor final class LibraryModelTests: XCTestCase {
  private func eventually(_ condition: () async -> Bool) async throws {
    for _ in 0..<200 {
      if await condition() { return }
      try await Task.sleep(for: .milliseconds(5))
    }
    XCTFail("Timed out waiting for the library task")
  }

  func testRetainedLibraryClearsOldAccountRowsAndReloadsOnIdentityVersionChange() async throws {
    let transport = LibraryIdentityTransport()
    let service = BiliService(transport: transport, credentials: LibraryNoCredentials())
    let library = LibraryModel(service: service)
    for _ in 0..<20 { await Task.yield() }
    await library.load(.search("Account scoped", .article, .relevance))
    XCTAssertEqual(library.entries.map(\.title), ["Account 1"])
    let version = library.identityVersion
    _ = await service.beginLogin()
    // A retained hidden page does not call cancel(); its normal identity observer stays alive.
    for _ in 0..<200 {
      if library.identityVersion > version { break }
      try await Task.sleep(for: .milliseconds(5))
    }
    XCTAssertGreaterThan(library.identityVersion, version)
    XCTAssertTrue(library.entries.isEmpty, "old account rows must disappear before the next request finishes")
    await transport.release()
    for _ in 0..<200 {
      if !library.isLoading && library.entries.first?.title == "Account 2" { break }
      try await Task.sleep(for: .milliseconds(5))
    }
    XCTAssertEqual(library.entries.map(\.title), ["Account 2"])
    XCTAssertNil(library.error)
    library.cancel()
  }

  func testSearchFilterChangeClearsRowsResetsPageAndRejectsOldResponse() async throws {
    let transport = LibrarySearchTransport()
    let service = BiliService(transport: transport, credentials: LibraryNoCredentials())
    let library = LibraryModel(service: service, observeIdentity: false)
    await library.load(.search("initial", .article, .relevance))
    await library.loadNext()
    XCTAssertEqual(library.entries.map(\.title), ["initial"])

    let oldQuery = LibrarySearchQuery(term: "old", type: .video, order: .views,
      filters: LibraryVideoSearchFilters(duration: 2, pubtime: 3, tid: 161))
    let oldTask = Task { await library.load(.filteredSearch(oldQuery)) }
    try await eventually { await transport.isBlocked() }
    XCTAssertTrue(library.entries.isEmpty); XCTAssertTrue(library.relatedUsers.isEmpty)
    XCTAssertEqual(library.total, 0); XCTAssertTrue(library.hasMore); XCTAssertTrue(library.isLoading)

    await library.load(.search("new", .article, .newest))
    XCTAssertEqual(library.entries.map(\.title), ["new"])
    await transport.release(); await oldTask.value
    XCTAssertEqual(library.entries.map(\.title), ["new"], "a stale response cannot replace the new query")
    XCTAssertNil(library.error); XCTAssertFalse(library.isLoading)
    let requests = await transport.searchRequests()
    let oldVideos = requests.filter { $0["keyword"] == "old" && $0["search_type"] == "video" }
    XCTAssertEqual(oldVideos.map { $0["page"] }, ["1"], "changing filters must restart at page one")
    let newArticles = requests.filter { $0["keyword"] == "new" && $0["search_type"] == "article" }
    XCTAssertEqual(newArticles.map { $0["page"] }, ["1"])
    library.cancel()
  }

  func testFilteredVideoAndUserPagingRetainQueryState() async throws {
    let transport = LibrarySearchTransport()
    let service = BiliService(transport: transport, credentials: LibraryNoCredentials())
    let library = LibraryModel(service: service, observeIdentity: false)
    let filters = LibraryVideoSearchFilters(duration: 2, pubtime: 3, tid: 161)
    await library.load(.filteredSearch(LibrarySearchQuery(term: "filtered", order: .views, filters: filters)))
    await library.loadNext()
    let video = try XCTUnwrap(library.entries.first)
    XCTAssertEqual(video.title, "filtered")
    if case .video(let media) = video.destination {
      XCTAssertEqual(media.duration, 1200); XCTAssertEqual(media.partitionID, 161)
    } else { XCTFail("Expected video result") }

    await library.load(.filteredSearch(LibrarySearchQuery(term: "people", type: .user, userOrder: .level)))
    XCTAssertTrue(library.entries.isEmpty); XCTAssertEqual(library.users.map(\.name), ["people"])
    await library.loadNext()
    let requests = await transport.searchRequests()
    let videos = requests.filter { $0["search_type"] == "video" }
    XCTAssertEqual(videos.map { $0["page"] }, ["1", "2"])
    for fields in videos {
      XCTAssertEqual(fields["duration"], "2"); XCTAssertEqual(fields["pubtime"], "3")
      XCTAssertEqual(fields["tid"], "161"); XCTAssertEqual(fields["order"], "click")
    }
    let users = requests.filter { $0["keyword"] == "people" && $0["search_type"] == "bili_user" }
    XCTAssertEqual(users.map { $0["page"] }, ["1", "2"])
    XCTAssertTrue(users.allSatisfy { $0["order"] == "level" })
    for fields in users {
      XCTAssertNil(fields["duration"]); XCTAssertNil(fields["pubtime"]); XCTAssertNil(fields["tid"])
    }
    library.cancel()
  }
}
#endif
