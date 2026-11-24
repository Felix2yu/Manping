import Foundation
import ManpingCore
import SwiftUI

/// Environment entry used by video cards to read the cached viewing state without
/// each card owning a network client. Nil outside the main window.
extension EnvironmentValues {
  @Entry var watchHistory: WatchHistoryStore? = nil
}

private enum HistoryError: LocalizedError {
  case badAddress, http(Int), api(String)
  var errorDescription: String? {
    switch self {
    case .badAddress: "服务器地址无效。"
    case .http(let code): "服务器返回错误（HTTP \(code)）。"
    case .api(let message): message.isEmpty ? "服务器返回了无法识别的数据。" : message
    }
  }
}

/// Talks to one bili-history server: batches cover queries so a screenful of cards
/// costs one request, and writes back the positions the player already reports to
/// Bilibili. Failures are silent on cards (no decimation by error badges) and only
/// surfaced by the settings window's 测试连接 button.
@MainActor final class WatchHistoryStore: ObservableObject {
  @Published private(set) var records: [String: WatchRecord] = [:]
  @Published private(set) var token = ""
  @Published var tokenDraft = ""
  @Published private(set) var testStatus: String?

  private(set) var enabled = false
  private(set) var baseURL = ""
  private var requested: Set<String> = []
  private var pending: Set<String> = []
  private var flushTask: Task<Void, Never>?
  private let cacheURL = WatchHistoryCache.fileURL()
  private var configuredOnce = false

  /// Bilibili's own history is the live increment; bili-history is the permanent base.
  private let fetchOfficial: @MainActor () async -> [String: WatchRecord]
  private var officialTask: Task<Void, Never>?
  /// An office Mac can stay off VPN for eight hours. Failures back off exponentially up to
  /// 30 minutes; a successful report or 测试连接 clears it immediately.
  private var failureCount = 0
  private var blockedUntil: Date?
  private var officialBlockedUntil: Date?
  private var persistTask: Task<Void, Never>?

  /// Shown in settings so a user off VPN understands where the marks come from.
  var serverStatus: String? {
    guard isBlocked else { return nil }
    return "bili-history 暂不可达，正在使用 B 站官方历史。连上网络后可点「测试连接」立即恢复。"
  }

  init(fetchOfficial: @escaping @MainActor () async -> [String: WatchRecord] = { [:] }) {
    self.fetchOfficial = fetchOfficial
    if let cacheURL { records = WatchHistoryCache.load(from: cacheURL) }
  }

  private var isBlocked: Bool {
    guard let blockedUntil else { return false }
    if Date() < blockedUntil { return true }
    self.blockedUntil = nil; failureCount = 0
    return false
  }

  var canConnect: Bool {
    guard enabled else { return false }
    return !(BiliHistoryConfig.normalizedBaseURL(baseURL) ?? "").isEmpty
  }

  /// Called from settings and at launch. The first call only adopts the settings; changing
  /// server or token afterwards means a different data set, so the saved cache is dropped.
  func configure(enabled: Bool, baseURL: String, token: String? = nil) {
    let normalized = BiliHistoryConfig.normalizedBaseURL(baseURL) ?? ""
    let nextToken = token ?? self.token
    let addressChanged = self.baseURL != normalized || self.token != nextToken
    let changed = self.enabled != enabled || addressChanged
    self.enabled = enabled
    self.baseURL = normalized
    self.token = nextToken
    if token == nil, tokenDraft != nextToken { tokenDraft = nextToken }
    guard changed else { return }
    let shouldDropCache = configuredOnce && addressChanged
    configuredOnce = true
    guard shouldDropCache else { return }
    flushTask?.cancel(); flushTask = nil
    pending.removeAll(); requested.removeAll(); records.removeAll(); testStatus = nil
    failureCount = 0; blockedUntil = nil
    persist(immediate: true)
  }

  /// Wipes the on-disk states so the next appearance of each card reads the server again.
  func clearCache() {
    flushTask?.cancel(); flushTask = nil
    pending.removeAll(); requested.removeAll(); records.removeAll()
    failureCount = 0; blockedUntil = nil
    refreshOfficial(force: true)
    persist(immediate: true)
  }

  /// One task owns the disk write. A screenful of cards and a 30-second report otherwise
  /// rewrite the whole (unbounded) cache on the main actor several times per minute.
  private func persist(immediate: Bool = false) {
    guard let cacheURL else { return }
    if immediate {
      persistTask?.cancel(); persistTask = nil
      records = WatchHistoryCache.save(records, to: cacheURL)
      return
    }
    guard persistTask == nil else { return }
    persistTask = Task { [weak self] in
      try? await Task.sleep(for: .milliseconds(800))
      guard let self, !Task.isCancelled, let cacheURL = self.cacheURL else { return }
      self.records = WatchHistoryCache.save(self.records, to: cacheURL)
      self.persistTask = nil
    }
  }

  private func noteSuccess() { failureCount = 0; blockedUntil = nil }

  private func noteFailure() {
    failureCount += 1
    blockedUntil = Date().addingTimeInterval(BiliHistoryConfig.backoffSeconds(afterFailures: failureCount))
  }

  func setTokenDraft(_ value: String) {
    tokenDraft = value
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard BiliHistoryConfig.writeToken(trimmed) else {
      testStatus = "令牌未能保存，请检查本机存储权限。"
      return
    }
    configure(enabled: enabled, baseURL: baseURL, token: trimmed)
  }

  /// A card asks for its state on appear; requests from one screen coalesce. Cached records are
  /// shown right away but are revalidated once per launch, so another Mac's newer progress
  /// arrives on the next launch instead of being hidden by a stale disk entry forever.
  func request(_ bvid: String) {
    guard canConnect, !bvid.isEmpty, !isBlocked,
      !requested.contains(bvid), !pending.contains(bvid) else { return }
    ensureOfficialLoaded()
    pending.insert(bvid)
    if pending.count >= 100 { flushTask?.cancel(); flushTask = nil; Task { await self.flushPending() }; return }
    guard flushTask == nil else { return }
    flushTask = Task { [weak self] in
      try? await Task.sleep(for: .milliseconds(150))
      guard let self, !Task.isCancelled else { return }
      await self.flushPending()
    }
  }

  /// Loads the live official history once per session. It stays useful when the intranet
  /// server is unreachable, and fills the hour bili-history has not crawled yet.
  private func ensureOfficialLoaded() {
    guard officialTask == nil else { return }
    refreshOfficial()
  }

  func refreshOfficial(force: Bool = false) {
    if !force, let until = officialBlockedUntil, Date() < until { return }
    officialTask?.cancel()
    officialTask = Task { [weak self] in
      guard let self else { return }
      let fetched = await self.fetchOfficial()
      guard !Task.isCancelled else { return }
      if fetched.isEmpty {
        // Signed out or offline: do not retry on every screen for a minute.
        self.officialBlockedUntil = Date().addingTimeInterval(60)
      } else {
        self.officialBlockedUntil = nil
        for (bvid, record) in fetched {
          self.records[bvid] = WatchHistoryMerge.choose(self.records[bvid], record)
        }
      }
      self.persist()
      self.officialTask = nil
    }
  }

  func record(_ bvid: String) -> WatchRecord? { canConnect ? records[bvid] : nil }

  /// Mirrors the position already being sent to Bilibili into bili-history. The local
  /// cache updates first so the next card the user sees is already marked correctly.
  func report(_ item: WatchProgressReporter.Item, seconds: Int) {
    guard canConnect, !item.bvid.isEmpty, seconds >= 0 else { return }
    let finished = item.duration > 0 && seconds >= item.duration
    let now = Int64(Date().timeIntervalSince1970)
    // Reuse the viewing session's timestamp from official history when it is close to now;
    // a raw device clock can be minutes off and would poison every merge by view_at.
    let viewAt = (records[item.bvid]?.viewAt).flatMap { existing in
      (existing > now - 7200 && existing < now + 7200) ? existing : nil
    } ?? now
    records[item.bvid] = WatchRecord(bvid: item.bvid, watched: true, progress: seconds,
      duration: item.duration, finished: finished, viewAt: viewAt)
    requested.insert(item.bvid)
    persist()
    let body = ReportBody(bvid: item.bvid, aid: item.aid, cid: item.cid, title: item.title,
      author: item.author, authorMid: item.authorID, cover: item.cover, duration: item.duration,
      progress: seconds, viewAt: viewAt)
    guard !isBlocked else { return }
    Task { [weak self] in
      guard let self else { return }
      do { _ = try await self.send(path: "report", body: body); self.noteSuccess() }
      catch { self.noteFailure() }
    }
  }

  @discardableResult func testConnection() async -> String {
    guard canConnect else {
      let message = "请先开启同步并填写服务器地址。"
      testStatus = message
      return message
    }
    do {
      let data = try await send(path: "ping", body: EmptyBody())
      let response = try JSONDecoder().decode(PingResponse.self, from: data)
      guard response.status == "success" else { throw HistoryError.api(response.message ?? "") }
      noteSuccess() // a manual probe is the user's way to end the backoff immediately
      testStatus = "连接成功。"
    } catch {
      testStatus = "连接失败：\(error.localizedDescription)"
    }
    return testStatus ?? ""
  }

  // MARK: Network

  private struct EmptyBody: Encodable {}
  private struct ReportBody: Encodable {
    let bvid: String
    let aid: Int64
    let cid: Int64
    let title: String
    let author: String
    let authorMid: Int64
    let cover: String
    let duration: Int
    let progress: Int
    let viewAt: Int64
    enum CodingKeys: String, CodingKey {
      case bvid, aid, cid, title, author, cover, duration, progress
      case authorMid = "author_mid", viewAt = "view_at"
    }
  }
  private struct QueryResponse: Decodable {
    let status: String
    let message: String?
    let data: [String: WatchRecord]?
  }
  private struct PingResponse: Decodable {
    let status: String
    let message: String?
  }

  private func request(for path: String) throws -> URLRequest {
    guard let url = BiliHistoryConfig.endpoint(baseURL, path: path) else { throw HistoryError.badAddress }
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.timeoutInterval = 3
    if !token.isEmpty { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
    return request
  }

  private func send<E: Encodable>(path: String, body: E) async throws -> Data {
    var request = try request(for: path)
    request.httpBody = try JSONEncoder().encode(body)
    let (data, response) = try await URLSession.shared.data(for: request)
    guard let http = response as? HTTPURLResponse else { throw HistoryError.badAddress }
    guard (200..<300).contains(http.statusCode) else { throw HistoryError.http(http.statusCode) }
    return data
  }

  private func flushPending() async {
    flushTask = nil
    let ids = Array(pending.prefix(200))
    guard !ids.isEmpty else { return }
    for id in ids { pending.remove(id); requested.insert(id) }
    guard var urlRequest = try? request(for: "query") else { noteFailure(); return }
    urlRequest.httpBody = try? JSONEncoder().encode(["bvids": ids])
    do {
      let (data, response) = try await URLSession.shared.data(for: urlRequest)
      guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
        noteFailure(); return
      }
      let decoded = try JSONDecoder().decode(QueryResponse.self, from: data)
      guard decoded.status == "success" else { noteFailure(); return }
      for (bvid, record) in decoded.data ?? [:] where ids.contains(bvid) {
        records[bvid] = WatchHistoryMerge.choose(records[bvid], record)
      }
      noteSuccess(); persist()
    } catch { noteFailure() }
  }
}
