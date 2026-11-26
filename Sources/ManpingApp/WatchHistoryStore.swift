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
  private var outbox: [String: ReportBody] = [:]
  private var sessions: [String: UUID] = [:]
  private var seenSessions: [String: Set<UUID>] = [:]
  private var flushTask: Task<Void, Never>?
  private var reportTask: Task<Void, Never>?
  private var retryTask: Task<Void, Never>?
  private let fixedCacheURL: URL?
  private let fixedOutboxURL: URL?
  private var cacheURL: URL?
  private var outboxURL: URL?
  private var accountID: Int64?
  private var storageGeneration: UInt64 = 0
  private let transport: @MainActor (URLRequest) async throws -> (Data, URLResponse)
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

  init(
    fetchOfficial: @escaping @MainActor () async -> [String: WatchRecord] = { [:] },
    cacheURL: URL? = WatchHistoryCache.fileURL(),
    outboxURL: URL? = nil,
    transport: @escaping @MainActor (URLRequest) async throws -> (Data, URLResponse) = {
      try await URLSession.shared.data(for: $0)
    }
  ) {
    self.fetchOfficial = fetchOfficial
    self.fixedCacheURL = cacheURL
    let resolvedOutboxURL = outboxURL ?? cacheURL.map {
      $0.deletingLastPathComponent().appendingPathComponent(
        $0.lastPathComponent.replacingOccurrences(of: "watch-history", with: "watch-history-outbox"))
    }
    self.fixedOutboxURL = resolvedOutboxURL
    self.cacheURL = cacheURL ?? WatchHistoryCache.fileURL()
    self.outboxURL = resolvedOutboxURL ?? WatchHistoryCache.outboxFileURL()
    self.transport = transport
    if let cacheURL { records = WatchHistoryCache.load(from: cacheURL) }
    if let url = self.outboxURL,
      let data = try? Data(contentsOf: url),
      let saved = try? JSONDecoder().decode([String: ReportBody].self, from: data) {
      outbox = saved
    }
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
  func configure(enabled: Bool, baseURL: String, token: String? = nil, accountID: Int64? = nil) {
    if self.accountID != accountID { switchAccount(to: accountID) }
    let normalized = BiliHistoryConfig.normalizedBaseURL(baseURL) ?? ""
    let nextToken = token ?? self.token
    let addressChanged = self.baseURL != normalized || self.token != nextToken
    let changed = self.enabled != enabled || addressChanged
    self.enabled = enabled
    self.baseURL = normalized
    self.token = nextToken
    if token == nil, tokenDraft != nextToken { tokenDraft = nextToken }
    guard changed else {
      if canConnect { flushOutbox() }
      return
    }
    let shouldDropCache = configuredOnce && addressChanged
    configuredOnce = true
    guard shouldDropCache else {
      if canConnect { flushOutbox() }
      return
    }
    storageGeneration &+= 1
    flushTask?.cancel(); flushTask = nil
    reportTask?.cancel(); reportTask = nil
    retryTask?.cancel(); retryTask = nil
    officialTask?.cancel(); officialTask = nil
    pending.removeAll(); requested.removeAll(); outbox.removeAll(); records.removeAll(); sessions.removeAll(); seenSessions.removeAll(); testStatus = nil
    failureCount = 0; blockedUntil = nil
    persistOutbox()
    persist(immediate: true)
    flushOutbox()
  }

  private func switchAccount(to nextAccountID: Int64?) {
    persist(immediate: true)
    persistOutbox()
    storageGeneration &+= 1
    flushTask?.cancel(); flushTask = nil
    reportTask?.cancel(); reportTask = nil
    retryTask?.cancel(); retryTask = nil
    officialTask?.cancel(); officialTask = nil
    accountID = nextAccountID
    cacheURL = fixedCacheURL ?? WatchHistoryCache.fileURL(accountID: nextAccountID)
    outboxURL = fixedOutboxURL ?? WatchHistoryCache.outboxFileURL(accountID: nextAccountID)
    records = cacheURL.map { WatchHistoryCache.load(from: $0) } ?? [:]
    outbox = loadOutbox()
    pending.removeAll(); requested.removeAll(); sessions.removeAll(); seenSessions.removeAll()
    failureCount = 0; blockedUntil = nil; officialBlockedUntil = nil; testStatus = nil
  }

  /// Wipes the on-disk states so the next appearance of each card reads the server again.
  func clearCache() {
    storageGeneration &+= 1
    flushTask?.cancel(); flushTask = nil
    reportTask?.cancel(); reportTask = nil
    retryTask?.cancel(); retryTask = nil
    officialTask?.cancel(); officialTask = nil
    pending.removeAll(); requested.removeAll(); records.removeAll(); sessions.removeAll(); seenSessions.removeAll()
    failureCount = 0; blockedUntil = nil
    refreshOfficial(force: true)
    flushOutbox()
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

  private func loadOutbox() -> [String: ReportBody] {
    guard let outboxURL,
      let data = try? Data(contentsOf: outboxURL),
      let saved = try? JSONDecoder().decode([String: ReportBody].self, from: data) else { return [:] }
    return saved
  }

  private func persistOutbox() {
    guard let outboxURL else { return }
    do {
      try FileManager.default.createDirectory(at: outboxURL.deletingLastPathComponent(), withIntermediateDirectories: true)
      try JSONEncoder().encode(outbox).write(to: outboxURL, options: .atomic)
    } catch {
      // Records remain queued in memory and are persisted again after the next outcome.
    }
  }

  private func noteSuccess() { failureCount = 0; blockedUntil = nil }

  private func noteFailure() {
    failureCount += 1
    blockedUntil = Date().addingTimeInterval(BiliHistoryConfig.backoffSeconds(afterFailures: failureCount))
    scheduleRetry()
  }

  private func scheduleRetry() {
    retryTask?.cancel()
    let delay = BiliHistoryConfig.backoffSeconds(afterFailures: failureCount)
    retryTask = Task { [weak self] in
      try? await Task.sleep(for: .seconds(delay))
      guard let self, !Task.isCancelled else { return }
      self.blockedUntil = nil
      await self.flushPending()
      self.flushOutbox()
    }
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
    guard canConnect, !bvid.isEmpty,
      !requested.contains(bvid), !pending.contains(bvid) else { return }
    ensureOfficialLoaded()
    pending.insert(bvid)
    guard !isBlocked else { return }
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
    let generation = storageGeneration
    let sessionsAtRequest = sessions
    officialTask = Task { [weak self] in
      guard let self else { return }
      let fetched = await self.fetchOfficial()
      guard !Task.isCancelled, generation == self.storageGeneration else { return }
      if fetched.isEmpty {
        // Signed out or offline: do not retry on every screen for a minute.
        self.officialBlockedUntil = Date().addingTimeInterval(60)
      } else {
        self.officialBlockedUntil = nil
        for (bvid, record) in fetched where sessionsAtRequest[bvid] == self.sessions[bvid] {
          self.records[bvid] = WatchHistoryMerge.choose(self.records[bvid], record)
        }
      }
      self.persist()
      self.officialTask = nil
    }
  }

  func record(_ bvid: String) -> WatchRecord? { records[bvid] }
  func flushLocal() { persist(immediate: true) }
  #if DEBUG
  func debugSeed(_ records: [String: WatchRecord]) { self.records.merge(records) { _, new in new } }
  #endif

  /// Mirrors the position already being sent to Bilibili into the local cache; only the
  /// server upload depends on sync being enabled.
  func report(_ item: WatchProgressReporter.Item, seconds: Int, sessionID: UUID = UUID()) {
    guard !item.bvid.isEmpty, seconds >= 0,
      seenSessions[item.bvid]?.contains(sessionID) != true else { return }
    let startedNewSession = sessions[item.bvid] != sessionID
    sessions[item.bvid] = sessionID
    seenSessions[item.bvid, default: []].insert(sessionID)
    let finished = item.duration > 0 && seconds >= item.duration
    let now = Int64(Date().timeIntervalSince1970)
    // Reuse the viewing session's timestamp from official history when it is close to now;
    // a raw device clock can be minutes off and would poison every merge by view_at.
    let viewAt = startedNewSession ? now : (records[item.bvid]?.viewAt).flatMap { existing in
      (existing > now - 7200 && existing < now + 7200) ? existing : nil
    } ?? now
    records[item.bvid] = WatchRecord(bvid: item.bvid, watched: true, progress: seconds,
      duration: item.duration, finished: finished, viewAt: viewAt)
    requested.insert(item.bvid)
    persist()
    guard canConnect else { return }
    let body = ReportBody(bvid: item.bvid, aid: item.aid, cid: item.cid, title: item.title,
      author: item.author, authorMid: item.authorID, cover: item.cover, duration: item.duration,
      progress: seconds, viewAt: viewAt)
    outbox[item.bvid] = body
    persistOutbox()
    guard !isBlocked else { return }
    flushOutbox()
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
      retryTask?.cancel(); retryTask = nil
      testStatus = "连接成功。"
      await flushPending()
      flushOutbox()
    } catch {
      testStatus = "连接失败：\(error.localizedDescription)"
    }
    return testStatus ?? ""
  }

  // MARK: Network

  private struct EmptyBody: Encodable {}
  private struct ReportBody: Codable, Equatable {
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
    let (data, response) = try await transport(request)
    guard let http = response as? HTTPURLResponse else { throw HistoryError.badAddress }
    guard (200..<300).contains(http.statusCode) else { throw HistoryError.http(http.statusCode) }
    return data
  }

  private func flushPending() async {
    flushTask = nil
    let ids = Array(pending.prefix(200))
    guard !ids.isEmpty, canConnect, !isBlocked else { return }
    let generation = storageGeneration
    let sessionsAtRequest = sessions
    for id in ids { pending.remove(id); requested.remove(id) }
    guard var urlRequest = try? request(for: "query") else { failPending(ids); return }
    urlRequest.httpBody = try? JSONEncoder().encode(["bvids": ids])
    do {
      let (data, response) = try await transport(urlRequest)
      guard generation == storageGeneration else { return }
      guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
        failPending(ids); return
      }
      let decoded = try JSONDecoder().decode(QueryResponse.self, from: data)
      guard decoded.status == "success" else { failPending(ids); return }
      for (bvid, record) in decoded.data ?? [:] where ids.contains(bvid)
        && sessionsAtRequest[bvid] == self.sessions[bvid] {
        records[bvid] = WatchHistoryMerge.choose(records[bvid], record)
      }
      requested.formUnion(ids)
      noteSuccess(); persist()
    } catch {
      guard generation == storageGeneration else { return }
      failPending(ids)
    }
  }

  private func failPending(_ ids: [String]) {
    pending.formUnion(ids)
    noteFailure()
  }

  private func flushOutbox() {
    guard canConnect, reportTask == nil, !outbox.isEmpty, !isBlocked else { return }
    let generation = storageGeneration
    reportTask = Task { [weak self] in
      guard let self else { return }
      while generation == self.storageGeneration, !self.outbox.isEmpty {
        guard !self.isBlocked, let entry = self.outbox.first else { break }
        do {
          _ = try await self.send(path: "report", body: entry.value)
          guard generation == self.storageGeneration else { break }
          if self.outbox[entry.key] == entry.value { self.outbox.removeValue(forKey: entry.key) }
          self.persistOutbox()
          self.noteSuccess()
        } catch {
          guard generation == self.storageGeneration else { break }
          self.noteFailure()
          break
        }
      }
      if generation == self.storageGeneration { self.reportTask = nil }
    }
  }
}
