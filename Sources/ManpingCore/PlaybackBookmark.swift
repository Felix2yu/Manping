import Foundation

/// Stable identity for local notes. A cid belongs to one media item (including a PGC episode);
/// videos without one fall back to their bvid. An aid without a cid is deliberately not a key.
public struct PlaybackBookmarkMediaKey: RawRepresentable, Hashable, Codable, Sendable {
  public let rawValue: String

  public init?(rawValue: String) {
    guard Self.isValid(rawValue) else { return nil }
    self.rawValue = rawValue
  }

  private init(validatedRawValue: String) { self.rawValue = validatedRawValue }

  public init(aid: Int64?, cid: Int64?, bvid: String) throws {
    let videoID = bvid.trimmingCharacters(in: .whitespacesAndNewlines)
    if let aid, aid > 0, let cid, cid > 0 {
      self.init(validatedRawValue: "\(aid):\(cid)")
    } else if Self.isBVID(videoID) {
      self.init(validatedRawValue: "bvid:\(videoID)")
    } else {
      throw BiliError.invalidResponse("当前媒体缺少有效的 aid、cid 或 bvid")
    }
  }

  public static func isValid(_ rawValue: String) -> Bool {
    if let range = rawValue.range(of: #"^[1-9][0-9]*:[1-9][0-9]*$"#, options: .regularExpression) {
      return range == rawValue.startIndex..<rawValue.endIndex
    }
    guard rawValue.hasPrefix("bvid:") else { return false }
    return isBVID(String(rawValue.dropFirst("bvid:".count)))
  }

  private static func isBVID(_ value: String) -> Bool {
    guard value.count == 12, value.hasPrefix("BV") else { return false }
    return value.dropFirst(2).allSatisfy { character in
      guard let scalar = character.unicodeScalars.first, scalar.value < 128 else { return false }
      return CharacterSet.alphanumerics.contains(scalar)
    }
  }
}

/// A user-created timestamp and optional note. This is local-only and never sent to Bilibili.
public struct PlaybackBookmark: Identifiable, Codable, Equatable, Sendable {
  public static let schemaVersion = 1
  public static let maximumNotesPerMedia = 500
  public static let maximumNoteLength = 2_000

  private enum CodingKeys: String, CodingKey { case id, mediaKey, time, note, createdAt }

  public let id: UUID
  public let mediaKey: PlaybackBookmarkMediaKey
  public let time: Double
  public var note: String
  public let createdAt: Date

  private init(id: UUID, mediaKey: PlaybackBookmarkMediaKey, time: Double, note: String, createdAt: Date) {
    self.id = id; self.mediaKey = mediaKey; self.time = time; self.note = note; self.createdAt = createdAt
  }

  public init(mediaKey: PlaybackBookmarkMediaKey, time: Double, note: String = "", createdAt: Date = Date()) throws {
    try Self.validate(mediaKey: mediaKey, time: time, note: note, createdAt: createdAt)
    self.init(id: UUID(), mediaKey: mediaKey, time: time, note: note, createdAt: createdAt)
  }

  public init(from decoder: any Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    let id = try values.decode(UUID.self, forKey: .id)
    let mediaKey = try values.decode(PlaybackBookmarkMediaKey.self, forKey: .mediaKey)
    let time = try values.decode(Double.self, forKey: .time)
    let note = try values.decode(String.self, forKey: .note)
    let createdAt = try values.decode(Date.self, forKey: .createdAt)
    try Self.validate(mediaKey: mediaKey, time: time, note: note, createdAt: createdAt)
    self.init(id: id, mediaKey: mediaKey, time: time, note: note, createdAt: createdAt)
  }

  public func encode(to encoder: any Encoder) throws {
    var values = encoder.container(keyedBy: CodingKeys.self)
    try values.encode(id, forKey: .id); try values.encode(mediaKey, forKey: .mediaKey)
    try values.encode(time, forKey: .time); try values.encode(note, forKey: .note)
    try values.encode(createdAt, forKey: .createdAt)
  }

  fileprivate static func decodeAndValidate(_ bookmark: PlaybackBookmark) throws {
    try validate(mediaKey: bookmark.mediaKey, time: bookmark.time, note: bookmark.note, createdAt: bookmark.createdAt)
  }

  private static func validate(mediaKey: PlaybackBookmarkMediaKey, time: Double, note: String, createdAt: Date) throws {
    guard time.isFinite, time >= 0 else {
      throw BiliError.invalidResponse("书签时间必须是非负的有限数值")
    }
    guard note.count <= Self.maximumNoteLength else {
      throw BiliError.invalidResponse("书签笔记不能超过 \(Self.maximumNoteLength) 字")
    }
    guard createdAt.timeIntervalSince1970.isFinite else {
      throw BiliError.invalidResponse("书签创建时间无效")
    }
  }

  public func updating(time: Double? = nil, note: String? = nil) throws -> Self {
    guard time == nil || note == nil else {
      throw BiliError.invalidResponse("一次只能修改书签时间或笔记")
    }
    if let time {
      guard time.isFinite, time >= 0 else {
        throw BiliError.invalidResponse("书签时间必须是非负的有限数值")
      }
    }
    if let note {
      guard note.count <= Self.maximumNoteLength else {
        throw BiliError.invalidResponse("书签笔记不能超过 \(Self.maximumNoteLength) 字")
      }
    }
    return PlaybackBookmark(id: id, mediaKey: mediaKey, time: time ?? self.time,
      note: note ?? self.note, createdAt: createdAt)
  }
}

/// Versioned JSON document shared by every media bucket in one store.
struct PlaybackBookmarkDocument: Codable, Equatable, Sendable {
  var version: Int = PlaybackBookmark.schemaVersion
  var bookmarks: [String: [PlaybackBookmark]]

  init(bookmarks: [String: [PlaybackBookmark]] = [:]) { self.bookmarks = bookmarks }

  enum CodingKeys: String, CodingKey { case version, bookmarks }

  init(from decoder: any Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    guard try values.decode(Int.self, forKey: .version) == PlaybackBookmark.schemaVersion else {
      throw BiliError.invalidResponse("书签文件版本不受支持")
    }
    self.bookmarks = try values.decode([String: [PlaybackBookmark]].self, forKey: .bookmarks)
  }

  func encode(to encoder: any Encoder) throws {
    var values = encoder.container(keyedBy: CodingKeys.self)
    try values.encode(version, forKey: .version)
    try values.encode(bookmarks, forKey: .bookmarks)
  }
}

public enum PlaybackBookmarkStoreError: LocalizedError, Equatable {
  case invalidDocument
  case verificationFailed

  public var errorDescription: String? {
    switch self {
    case .invalidDocument: return "书签文件内容无效"
    case .verificationFailed: return "书签保存后校验失败"
    }
  }
}

/// One versioned JSON file per app variant. Every mutation is serialized, written atomically and
/// read back before it becomes visible. Invalid records are rejected instead of silently losing a
/// bucket when the app next saves another video's notes.
public final class PlaybackBookmarkStore: @unchecked Sendable {
  public private(set) var fileURL: URL?
  private let fileManager: FileManager
  private let lock = NSLock()
  private var document: PlaybackBookmarkDocument
  public private(set) var loadError: Error?

  /// Tests use an explicit URL. Production uses a variant-local URL; `url == nil` is memory only.
  public convenience init(url: URL? = PlaybackBookmarkStore.defaultURL, fileManager: FileManager = .default) throws {
    let resolved = url ?? PlaybackBookmarkStore.defaultURL
    try self.init(fileURL: resolved, memoryOnly: resolved == nil, fileManager: fileManager)
  }

  public convenience init(memoryOnly: Bool, fileManager: FileManager = .default) throws {
    try self.init(fileURL: memoryOnly ? nil : PlaybackBookmarkStore.defaultURL,
      memoryOnly: memoryOnly, fileManager: fileManager)
  }

  private init(fileURL: URL?, memoryOnly: Bool, fileManager: FileManager) throws {
    self.fileURL = fileURL; self.fileManager = fileManager
    if memoryOnly {
      document = PlaybackBookmarkDocument()
      return
    }
    guard let fileURL else { throw CocoaError(.fileNoSuchFile) }
    if fileManager.fileExists(atPath: fileURL.path) {
      document = try Self.decodeDocument(Data(contentsOf: fileURL))
    } else {
      document = PlaybackBookmarkDocument()
    }
  }

  public static var defaultURL: URL? {
    guard let variant = LocalSecretVault.appVariant else { return nil }
    return AppIdentity.applicationSupportDirectory
      .appendingPathComponent("playback-bookmarks\(variant).json")
  }

  public func bookmarks(for media: PlaybackBookmarkMediaKey) -> [PlaybackBookmark] {
    lock.withLock {
      (document.bookmarks[media.rawValue] ?? []).sorted {
        if $0.time != $1.time { return $0.time < $1.time }
        if $0.createdAt != $1.createdAt { return $0.createdAt < $1.createdAt }
        return $0.id.uuidString < $1.id.uuidString
      }
    }
  }

  public var isEmpty: Bool { lock.withLock { document.bookmarks.isEmpty } }

  @discardableResult
  public func add(time: Double, note: String = "", to media: PlaybackBookmarkMediaKey, createdAt: Date = Date()) throws -> PlaybackBookmark {
    let bookmark = try PlaybackBookmark(mediaKey: media, time: time, note: note, createdAt: createdAt)
    try mutate(media: media) { bookmarks in
      guard bookmarks.count < PlaybackBookmark.maximumNotesPerMedia else {
        throw BiliError.invalidResponse("每个媒体最多保存 \(PlaybackBookmark.maximumNotesPerMedia) 个书签")
      }
      bookmarks.append(bookmark)
      bookmarks.sort { $0.time < $1.time }
    }
    return bookmark
  }

  @discardableResult
  public func update(id: UUID, time: Double? = nil, note: String? = nil,
    in media: PlaybackBookmarkMediaKey) throws -> PlaybackBookmark {
    try mutate(media: media) { bookmarks in
      guard let index = bookmarks.firstIndex(where: { $0.id == id }) else {
        throw BiliError.invalidResponse("书签不存在或不属于当前媒体")
      }
      let updated = try bookmarks[index].updating(time: time, note: note)
      bookmarks[index] = updated
      bookmarks.sort { $0.time < $1.time }
    }
    return bookmarks(for: media).first { $0.id == id }!
  }

  public func remove(id: UUID, from media: PlaybackBookmarkMediaKey) throws {
    try mutate(media: media) { bookmarks in
      guard bookmarks.contains(where: { $0.id == id }) else {
        throw BiliError.invalidResponse("书签不存在或不属于当前媒体")
      }
      bookmarks.removeAll { $0.id == id }
    }
  }

  /// Loads malformed JSON for read-only display, allowing valid media to keep working. Mutations
  /// fail until the file is repaired, so a later write cannot overwrite the damaged user data.
  public static func recover(from url: URL? = PlaybackBookmarkStore.defaultURL) throws -> PlaybackBookmarkStore {
    let store = try PlaybackBookmarkStore(memoryOnly: true, fileManager: .default)
    guard let url else { return store }
    store.fileURL = url
    guard FileManager.default.fileExists(atPath: url.path) else { return store }
    do {
      store.document = try decodeDocument(Data(contentsOf: url))
    } catch {
      store.loadError = error
    }
    return store
  }

  private func mutate(media: PlaybackBookmarkMediaKey,
    _ change: (inout [PlaybackBookmark]) throws -> Void) throws {
    try lock.withLock {
      if loadError != nil { throw PlaybackBookmarkStoreError.invalidDocument }
      guard let fileURL else {
        try change(&document.bookmarks[media.rawValue, default: []])
        if document.bookmarks[media.rawValue]?.isEmpty == true { document.bookmarks.removeValue(forKey: media.rawValue) }
        return
      }

      var candidate = document
      try change(&candidate.bookmarks[media.rawValue, default: []])
      if candidate.bookmarks[media.rawValue]?.isEmpty == true { candidate.bookmarks.removeValue(forKey: media.rawValue) }
      candidate = try Self.validatedDocument(candidate)

      let encoder = JSONEncoder()
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
      encoder.dateEncodingStrategy = .secondsSince1970
      let data = try encoder.encode(candidate)
      // JSON dates are doubles: compare against the actual encoded representation, not the
      // pre-encoding Date values (whose last bit may differ after a round trip).
      let expected = try Self.decodeDocument(data)
      try fileManager.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700])
      try data.write(to: fileURL, options: .atomic)
      try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)

      let verified = try Self.decodeDocument(Data(contentsOf: fileURL))
      guard verified == expected else { throw PlaybackBookmarkStoreError.verificationFailed }
      document = verified
    }
  }

  private static func decodeDocument(_ data: Data) throws -> PlaybackBookmarkDocument {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .secondsSince1970
    return try validatedDocument(decoder.decode(PlaybackBookmarkDocument.self, from: data))
  }

  private static func validatedDocument(_ document: PlaybackBookmarkDocument) throws -> PlaybackBookmarkDocument {
    var result = PlaybackBookmarkDocument(bookmarks: [:])
    for (rawKey, rows) in document.bookmarks {
      guard let key = PlaybackBookmarkMediaKey(rawValue: rawKey), rows.count <= PlaybackBookmark.maximumNotesPerMedia,
        Set(rows.map(\.id)).count == rows.count else { throw PlaybackBookmarkStoreError.invalidDocument }
      let validated = try rows.map { row -> PlaybackBookmark in
        try PlaybackBookmark.decodeAndValidate(row)
        return row
      }
      guard validated.allSatisfy({ $0.mediaKey == key }) else { throw PlaybackBookmarkStoreError.invalidDocument }
      result.bookmarks[rawKey] = validated.sorted {
        if $0.time != $1.time { return $0.time < $1.time }
        return $0.id.uuidString < $1.id.uuidString
      }
    }
    return result
  }
}
