import Foundation
import ManpingCore

/// Reads bili-history's client channel. Kept out of `WatchHistoryStore` on
/// purpose: that store owns the cover marks, the retry backoff and the report
/// outbox, and adding list paging to it would make one object responsible for
/// two unrelated jobs.
///
/// Every call is a plain read, returns an empty result when the server has no
/// database for that part of the archive, and throws only when the server is
/// unreachable or answers with an error envelope.
@MainActor final class ClientHistoryService {
  private let baseURL: String
  private let token: String
  private let transport: @MainActor (URLRequest) async throws -> (Data, URLResponse)

  init(
    baseURL: String, token: String,
    transport: @escaping @MainActor (URLRequest) async throws -> (Data, URLResponse) = {
      try await URLSession.shared.data(for: $0)
    }
  ) {
    self.baseURL = baseURL
    self.token = token
    self.transport = transport
  }

  /// False when 设置 › 隐私 › bili-history 的服务器地址 is empty; the archive UI hides
  /// itself instead of showing an error for a feature the user never enabled.
  var isConfigured: Bool { !(BiliHistoryConfig.normalizedBaseURL(baseURL) ?? "").isEmpty }

  // MARK: Reads

  func recent(limit: Int = 30) async throws -> [ArchiveVideo] {
    let page: RecentPage = try await post("recent", body: ["limit": limit])
    return page.records
  }

  func history(cursor: Int64 = 0, limit: Int = 40, keyword: String = "", business: String = "", year: Int = 0,
    filter: ArchiveHistoryFilter = ArchiveHistoryFilter()) async throws -> ArchivePage
  {
    var body: [String: Any] = ["cursor": cursor, "limit": limit]
    if !keyword.isEmpty { body["keyword"] = keyword }
    if !business.isEmpty { body["business"] = business }
    if year > 0 { body["year"] = year }
    if !filter.mainCategory.isEmpty { body["main_category"] = filter.mainCategory }
    if !filter.subCategory.isEmpty { body["sub_category"] = filter.subCategory }
    if let minimum = filter.duration.minimumSeconds { body["min_duration"] = minimum }
    if let maximum = filter.duration.maximumSeconds { body["max_duration"] = maximum }
    return try await post("history", body: body)
  }

  func categories() async throws -> [ArchiveCategory] {
    let page: CategoryPage = try await get("categories")
    return page.categories
  }

  /// Which of these videos the archive has marked as deleted. Answered from the
  /// server's cache, so it costs one request no matter how many ids are sent.
  func deletedVideos(_ bvids: [String]) async throws -> Set<String> {
    guard !bvids.isEmpty else { return [] }
    let data = try await postRaw("video-status", body: ["bvids": Array(bvids.prefix(500))])
    let page = try decode(StatusPage.self, from: data)
    return Set(page.deleted)
  }

  func summary(year: Int, month: Int) async throws -> ArchiveSummary {
    try await get("summary?year=\(year)&month=\(month)")
  }

  func watchLater(page: Int = 1, size: Int = 40,
    filter: ArchiveHistoryFilter = ArchiveHistoryFilter()) async throws -> WatchLaterPage
  {
    var query = "page=\(page)&size=\(size)"
    if !filter.mainCategory.isEmpty { query += "&main_category=\(Self.queryValue(filter.mainCategory))" }
    if !filter.subCategory.isEmpty { query += "&sub_category=\(Self.queryValue(filter.subCategory))" }
    if let minimum = filter.duration.minimumSeconds { query += "&min_duration=\(minimum)" }
    if let maximum = filter.duration.maximumSeconds { query += "&max_duration=\(maximum)" }
    return try await get("watchlater?" + query)
  }

  func favorites() async throws -> [ArchiveFavoriteFolder] {
    let page: FolderPage = try await get("favorites")
    return page.folders
  }

  func favoriteContents(mediaID: Int64, page: Int = 1, size: Int = 40) async throws -> PagedList<ArchiveFavoriteItem> {
    try await get("favorites/contents?media_id=\(mediaID)&page=\(page)&size=\(size)")
  }

  /// Used by the AI panel: a keyword search over the permanent archive.
  func search(_ keyword: String, limit: Int = 20) async throws -> [ArchiveVideo] {
    let trimmed = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return [] }
    return try await history(cursor: 0, limit: limit, keyword: trimmed).records
  }

  // MARK: Wire

  struct PagedList<T: Decodable & Sendable>: Decodable, Sendable {
    let records: [T]
    let total: Int
  }
  struct WatchLaterPage: Decodable, Sendable {
    let records: [ArchiveWatchLaterItem]
    let total: Int
    /// Older servers omit this; read-only filtering stays unavailable until the
    /// page explicitly confirms the server applies the query.
    let supportsFiltering: Bool?

    enum CodingKeys: String, CodingKey {
      case records, total
      case supportsFiltering = "supports_filtering"
    }
  }
  private struct RecentPage: Decodable { let records: [ArchiveVideo] }
  private struct StatusPage: Decodable { let deleted: [String] }
  private struct CategoryPage: Decodable { let categories: [ArchiveCategory] }
  private struct FolderPage: Decodable { let folders: [ArchiveFavoriteFolder] }
  private struct Envelope<T: Decodable>: Decodable {
    let status: String
    let message: String?
    let data: T?
  }
  /// The same envelope without a payload, for the cases where the body is an error.
  private struct MessageEnvelope: Decodable {
    let status: String?
    let message: String?
  }

  private enum Failure: LocalizedError {
    case notConfigured, badResponse, http(Int), api(String)
    var errorDescription: String? {
      switch self {
      case .notConfigured: "还没有填写 bili-history 服务器地址。"
      case .badResponse: "bili-history 返回了无法识别的数据。"
      case .http(let code): "bili-history 返回错误（HTTP \(code)）。"
      case .api(let message): message.isEmpty ? "bili-history 返回了错误。" : message
      }
    }
  }

  private static func queryValue(_ value: String) -> String {
    var allowed = CharacterSet.urlQueryAllowed
    allowed.remove(charactersIn: "&+=#?")
    return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
  }

  private func request(path: String, method: String) throws -> URLRequest {
    guard let url = BiliHistoryConfig.clientEndpoint(baseURL, path: path) else { throw Failure.notConfigured }
    var request = URLRequest(url: url)
    request.httpMethod = method
    // A list read is allowed to be slower than the 3 s cover probe, but it must
    // still give up: an off-VPN Mac should fall back to the account list quickly.
    request.timeoutInterval = 8
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    if !token.isEmpty { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
    return request
  }

  private func post<T: Decodable>(_ path: String, body: [String: Any]) async throws -> T {
    let data = try await postRaw(path, body: body)
    return try decode(T.self, from: data)
  }

  private func postRaw(_ path: String, body: [String: Any]) async throws -> Data {
    var request = try request(path: path, method: "POST")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try JSONSerialization.data(withJSONObject: body)
    return try await send(request)
  }

  private func get<T: Decodable>(_ path: String) async throws -> T {
    let data = try await send(try request(path: path, method: "GET"))
    return try decode(T.self, from: data)
  }

  private func send(_ request: URLRequest) async throws -> Data {
    let (data, response) = try await transport(request)
    guard let http = response as? HTTPURLResponse else { throw Failure.badResponse }
    guard (200..<300).contains(http.statusCode) else {
      // A 400 carries the server's own reason ("一次最多查询 500 个视频"); the bare
      // status code would hide the one sentence that explains it.
      if let envelope = try? JSONDecoder().decode(MessageEnvelope.self, from: data),
        let message = envelope.message, !message.isEmpty
      {
        throw Failure.api(message)
      }
      throw Failure.http(http.statusCode)
    }
    return data
  }

  private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
    let envelope: Envelope<T>
    do { envelope = try JSONDecoder().decode(Envelope<T>.self, from: data) }
    catch { throw Failure.badResponse }
    // The channel answers 200 with an error envelope for query failures, the same
    // convention the web UI uses; surface the server's own message.
    guard envelope.status == "success", let payload = envelope.data else {
      throw Failure.api(envelope.message ?? "")
    }
    return payload
  }
}
