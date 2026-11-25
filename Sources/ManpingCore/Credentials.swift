import Foundation

public protocol AuthCredentialStore: Sendable {
  func save(_ cookies: [HTTPCookie]) throws
  func load() throws -> [HTTPCookie]
  func saveToken(_ token: AppToken?) throws
  func loadToken() throws -> AppToken?
  func clear() throws
  /// Cookies and token in one read. Stores that keep both in one entry override this.
  func loadAll() throws -> (cookies: [HTTPCookie], token: AppToken?)
}

extension AuthCredentialStore {
  public func loadAll() throws -> (cookies: [HTTPCookie], token: AppToken?) { (try load(), try loadToken()) }
}

public final class CredentialStore: AuthCredentialStore, Sendable {
  enum Item: Sendable { case session }
  private static func entry(_ item: Item) -> String {
    switch item {
    case .session: "bilibili.session"
    }
  }
  fileprivate struct Session: Codable {
    var cookies: Data
    var token: AppToken?
    /// The proxy password shares this entry.
    var proxySecret: String?
  }
  /// Raw item access; the local vault in the app, memory in tests.
  struct Storage: Sendable {
    let read: @Sendable (Item) throws -> Data?
    let write: @Sendable (Item, Data) throws -> Void
    let delete: @Sendable (Item) throws -> Void
  }
  /// State shared by every store on the same storage. `lock` serializes each read-modify-write
  /// (and the cache update) across instances: the session item holds the account and the proxy
  /// password, so two unserialized writers could put back an account that was just signed out.
  final class Shared: @unchecked Sendable {
    let storage: Storage
    fileprivate let lock = NSRecursiveLock()
    /// The last session read or written by any instance; later reads in the same launch (the
    /// proxy password after the account) then need no second vault read.
    fileprivate var session: Session?
    init(storage: Storage) { self.storage = storage }
  }
  private static let vault = Shared(storage: Storage(
    read: { try LocalSecretVault.shared.read(CredentialStore.entry($0)) },
    write: { let entry = CredentialStore.entry($0); try LocalSecretVault.shared.write(entry, $1) },
    delete: { try LocalSecretVault.shared.delete(CredentialStore.entry($0)) }))
  private let shared: Shared

  public init() { shared = Self.vault }
  init(shared: Shared) { self.shared = shared }

  public func loadAll() throws -> (cookies: [HTTPCookie], token: AppToken?) {
    let session = try shared.lock.withLock { try readSession() ?? Session(cookies: Data("[]".utf8), token: nil) }
    let token = session.token.flatMap { $0.isComplete ? $0 : nil }
    return (try Self.decodeCookies(session.cookies), token)
  }
  public func load() throws -> [HTTPCookie] { try loadAll().cookies }
  public func loadToken() throws -> AppToken? { try loadAll().token }

  public func save(_ cookies: [HTTPCookie]) throws {
    let encoded = try Self.encodeCookies(cookies)
    try update { $0.cookies = encoded }
  }
  public func saveToken(_ token: AppToken?) throws {
    try update { $0.token = token }
  }
  /// The proxy password, or nil. Uses the session already read this launch when there is one.
  public func proxySecret() throws -> String? {
    try shared.lock.withLock {
      if let cached = shared.session { return cached.proxySecret }
      return try readSession()?.proxySecret
    }
  }
  public func saveProxySecret(_ value: String?) throws {
    let secret = (value ?? "").isEmpty ? nil : value
    try update { $0.proxySecret = secret }
  }

  public func clear() throws {
    try shared.lock.withLock {
      let proxySecret = (try? readSession())?.proxySecret
      try write(Session(cookies: Data("[]".utf8), token: nil, proxySecret: proxySecret))
    }
  }

  /// One read-modify-write of the session item. Account writes change only their field, so the
  /// proxy password (and the account, for proxy writes) carries over.
  private func update(_ change: (inout Session) -> Void) throws {
    try shared.lock.withLock {
      var session = try readSession() ?? Session(cookies: Data("[]".utf8), token: nil)
      change(&session)
      try write(session)
    }
  }
  /// Call with `shared.lock` held.
  private func readSession() throws -> Session? {
    guard let data = try shared.storage.read(.session) else { return nil }
    // Unreadable contents count as signed out; the next save replaces them.
    let session = (try? JSONDecoder().decode(Session.self, from: data)) ?? Session(cookies: Data("[]".utf8), token: nil)
    shared.session = session
    return session
  }
  /// Call with `shared.lock` held.
  private func write(_ session: Session) throws {
    try shared.storage.write(.session, try JSONEncoder().encode(session))
    shared.session = session
  }

  public static func encodeCookies(_ cookies: [HTTPCookie]) throws -> Data {
    let allowed = cookies.filter {
      $0.domain == "bilibili.com" || $0.domain.hasSuffix(".bilibili.com")
    }
    let records = allowed.map { cookie -> [String: String] in
      var record = [
        "name": cookie.name, "value": cookie.value, "domain": cookie.domain, "path": cookie.path,
        "secure": cookie.isSecure ? "TRUE" : "FALSE",
      ]
      if let expiry = cookie.expiresDate {
        record["expires"] = String(expiry.timeIntervalSince1970)
      }
      return record
    }
    return try JSONEncoder().encode(records)
  }
  public static func decodeCookies(_ data: Data) throws -> [HTTPCookie] {
    let records = try JSONDecoder().decode([[String: String]].self, from: data)
    return records.compactMap { record in
      var properties: [HTTPCookiePropertyKey: Any] = [
        .name: record["name"] ?? "", .value: record["value"] ?? "", .domain: record["domain"] ?? "",
        .path: record["path"] ?? "/", .secure: record["secure"] ?? "TRUE",
      ]
      if let raw = record["expires"], let expiry = Double(raw) {
        properties[.expires] = Date(timeIntervalSince1970: expiry)
      }
      return HTTPCookie(properties: properties)
    }.filter {
      ($0.domain == "bilibili.com" || $0.domain.hasSuffix(".bilibili.com"))
        && ($0.expiresDate ?? .distantFuture) > Date()
    }
  }
}
