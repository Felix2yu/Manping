import Foundation
import ManpingCore
import XCTest
@testable import ManpingApp

private actor ArchiveFilterHTTP {
  struct Call: @unchecked Sendable {
    let path: String
    let query: [String: String]
    let body: [String: Any]
  }
  private(set) var calls: [Call] = []
  private var pauseCategory: String?
  private var paused = false
  private var releaseContinuation: CheckedContinuation<Void, Never>?
  private var observers: [CheckedContinuation<Void, Never>] = []

  init(pauseCategory: String? = nil) { self.pauseCategory = pauseCategory }

  func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
    let body = (try? JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any]) ?? [:]
    let query = Dictionary(uniqueKeysWithValues: URLComponents(
      url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.map { ($0.name, $0.value ?? "") } ?? [])
    calls.append(Call(path: request.url!.path, query: query, body: body))
    if request.url!.path == "/api/client/history", pauseCategory == body["main_category"] as? String {
      pauseCategory = nil
      paused = true
      observers.forEach { $0.resume() }
      observers = []
      await withCheckedContinuation { releaseContinuation = $0 }
    }
    let payload: String
    switch request.url!.path {
    case "/api/client/history":
      let cursor = body["cursor"] as? Int64 ?? 0
      let bvid = cursor == 0 ? "BVfirst" : "BVsecond"
      payload = "{\"status\":\"success\",\"data\":{\"records\":[{\"bvid\":\"\(bvid)\",\"title\":\"样本\",\"cover\":\"\",\"author\":\"作者\",\"author_mid\":12,\"duration\":600,\"progress\":60,\"view_at\":\(cursor == 0 ? 200 : 100),\"finished\":false,\"main_category\":\"知识\",\"sub_category\":\"科普\"}],\"next\":\(cursor == 0 ? 100 : 0),\"supports_filtering\":true}}"
    case "/api/client/categories":
      payload = #"{"status":"success","data":{"categories":[{"name":"知识","sub_categories":[{"name":"科普","tid":201}]}]}}"#
    case "/api/client/watchlater":
      payload = #"{"status":"success","data":{"records":[{"bvid":"BVlater","title":"稍后再看样本","cover":"","author":"作者","duration":600,"add_at":300,"view":1,"main_category":"知识","sub_category":"科普"}],"total":1,"supports_filtering":true}}"#
    case "/api/client/recent":
      payload = #"{"status":"success","data":{"records":[]}}"#
    case "/api/client/summary":
      payload = #"{"status":"success","data":{"year":2026,"month":11,"videos":1,"seconds":600,"unique_authors":1,"unique_days":1,"finished":0,"finished_rate":0,"late_night_ratio":0}}"#
    case "/api/client/video-status":
      payload = #"{"status":"success","data":{"deleted":[]}}"#
    default: throw URLError(.unsupportedURL)
    }
    return (Data(payload.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
  }

  func waitUntilPaused() async {
    if paused { return }
    await withCheckedContinuation { observers.append($0) }
  }

  func release() { releaseContinuation?.resume(); releaseContinuation = nil }
}

@MainActor final class ArchiveFilterServiceTests: XCTestCase {
  @MainActor private func makeService(_ http: ArchiveFilterHTTP) -> ClientHistoryService {
    ClientHistoryService(baseURL: "https://archive.fixture", token: "", transport: { try await http.send($0) })
  }

  func testHistorySendsCombinedSearchPartitionAndDurationParameters() async throws {
    let http = ArchiveFilterHTTP()
    let service = makeService(http)
    var filter = ArchiveHistoryFilter()
    filter.mainCategory = "知识"
    filter.subCategory = "科普"
    filter.duration = .twentyToSixtyMinutes
    let page = try await service.history(cursor: 42, limit: 40, keyword: "样本", filter: filter)
    XCTAssertEqual(page.supportsFiltering, true)
    XCTAssertEqual(page.records.first?.subCategory, "科普")
    let categories = try await service.categories()
    XCTAssertEqual(categories.first?.subCategories.first?.tid, 201)
    let calls = await http.calls
    XCTAssertEqual(calls.map(\.path), ["/api/client/history", "/api/client/categories"])
    let body = calls[0].body
    XCTAssertEqual(body["cursor"] as? Int64, 42)
    XCTAssertEqual(body["keyword"] as? String, "样本")
    XCTAssertEqual(body["main_category"] as? String, "知识")
    XCTAssertEqual(body["sub_category"] as? String, "科普")
    XCTAssertEqual(body["min_duration"] as? Int, 1201)
    XCTAssertEqual(body["max_duration"] as? Int, 3600)
  }

  func testWatchLaterSendsEncodedPartitionAndDurationFilters() async throws {
    let http = ArchiveFilterHTTP()
    let service = makeService(http)
    var filter = ArchiveHistoryFilter()
    filter.mainCategory = "知识"
    filter.subCategory = "科普"
    filter.duration = .fiveToTwentyMinutes
    let page = try await service.watchLater(page: 2, size: 20, filter: filter)
    XCTAssertEqual(page.supportsFiltering, true)
    XCTAssertEqual(page.records.first?.mainCategory, "知识")
    XCTAssertEqual(page.records.first?.video.partitionName, "知识")
    let calls = await http.calls
    XCTAssertEqual(calls.first?.path, "/api/client/watchlater")
    XCTAssertEqual(calls.first?.query["page"], "2")
    XCTAssertEqual(calls.first?.query["size"], "20")
    XCTAssertEqual(calls.first?.query["main_category"], "知识")
    XCTAssertEqual(calls.first?.query["sub_category"], "科普")
    XCTAssertEqual(calls.first?.query["min_duration"], "301")
    XCTAssertEqual(calls.first?.query["max_duration"], "1200")
  }

  @MainActor func testLaterFilterUsesItsOwnCriteria() async throws {
    let http = ArchiveFilterHTTP()
    let model = ArchiveBrowserModel(service: makeService(http))
    var filter = ArchiveHistoryFilter()
    filter.mainCategory = "知识"
    filter.subCategory = "科普"
    filter.duration = .upTo5Minutes
    await model.setFilter(filter, segment: .later)
    XCTAssertEqual(model.later.map(\.bvid), ["BVlater"])
    XCTAssertTrue(model.laterSupportsFiltering)
    XCTAssertEqual(model.laterFilter, filter)
    XCTAssertTrue(model.filter.isEmpty)
    let calls = await http.calls
    let call = try XCTUnwrap(calls.first { $0.path == "/api/client/watchlater" })
    XCTAssertEqual(call.query["main_category"], "知识")
    XCTAssertEqual(call.query["sub_category"], "科普")
    XCTAssertEqual(call.query["min_duration"], "1")
    XCTAssertEqual(call.query["max_duration"], "300")
  }

  @MainActor func testSearchFilterAndPaginationKeepCriteria() async throws {
    let http = ArchiveFilterHTTP()
    let model = ArchiveBrowserModel(service: makeService(http))
    var filter = ArchiveHistoryFilter()
    filter.mainCategory = "知识"
    filter.subCategory = "科普"
    filter.duration = .fiveToTwentyMinutes
    await model.setFilter(filter)
    await model.search(keyword: "  样本  ")
    await model.loadMore()
    XCTAssertEqual(model.history.map(\.bvid), ["BVfirst", "BVsecond"])
    XCTAssertEqual(model.keyword, "样本")
    XCTAssertFalse(model.canLoadMore)
    let bodies = await http.calls.filter { $0.path == "/api/client/history" }.map(\.body)
    XCTAssertEqual(bodies.count, 3)
    for body in bodies {
      XCTAssertEqual(body["keyword"] as? String, "样本")
      XCTAssertEqual(body["main_category"] as? String, "知识")
      XCTAssertEqual(body["sub_category"] as? String, "科普")
      XCTAssertEqual(body["min_duration"] as? Int, 301)
      XCTAssertEqual(body["max_duration"] as? Int, 1200)
    }
    XCTAssertEqual(bodies.map { $0["cursor"] as? Int64 }, [0, 0, 100])
  }

  @MainActor func testLateHistoryResponseCannotOverwriteNewFilter() async throws {
    let http = ArchiveFilterHTTP(pauseCategory: "动画")
    let model = ArchiveBrowserModel(service: makeService(http))
    var oldFilter = ArchiveHistoryFilter()
    oldFilter.mainCategory = "动画"
    let oldRequest = Task { await model.setFilter(oldFilter) }
    await http.waitUntilPaused()
    var newFilter = ArchiveHistoryFilter()
    newFilter.mainCategory = "知识"
    await model.setFilter(newFilter)
    XCTAssertEqual(model.history.map(\.bvid), ["BVfirst"])
    await http.release()
    await oldRequest.value
    XCTAssertEqual(model.history.map(\.bvid), ["BVfirst"])
    let categories = await http.calls
    let histories = categories.filter { $0.path == "/api/client/history" }
    XCTAssertEqual(histories.map { $0.body["main_category"] as? String }, ["动画", "知识"])
  }
}
