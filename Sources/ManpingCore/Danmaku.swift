import Foundation

public struct DanmakuComment: Equatable, Sendable {
  public let time: Double
  public let mode: Int
  public let color: UInt32
  /// Exact source text. Filtering, density and AI material always use this, never `displayText`.
  public let text: String
  /// Presentation-only text (for example `干杯 ×11`). Nil means the source text is displayed.
  public let displayText: String?
  /// Server smart-shield weight (0–11) when the source provides it.
  public let weight: Int?
  /// The sender's hashed id (list.so `p[6]`), used by account user shields.
  public let userHash: String?
  public init(time: Double, mode: Int = 1, color: UInt32 = 0xffffff, text: String, weight: Int? = nil,
    userHash: String? = nil, displayText: String? = nil) {
    self.time = time
    self.mode = mode
    self.color = color
    self.text = text
    self.displayText = displayText
    self.weight = weight
    self.userHash = userHash
  }
  /// Text used only for lane measurement and glyph rasterization.
  public var displayedText: String { displayText ?? text }
}

/// Batches live, plain scrolling comments for presentation only. The source chat and downloaded
/// XML are never changed. Windows use the media clock supplied by the caller, not wall time: a
/// paused player may flush every 100 ms without closing a window.
///
/// A group covers the half-open interval `[first media time, first + 1 second)`. Its key is the
/// exact text, color and mode; sender identity is deliberately absent. Non-scrolling, rich and
/// unknown comments pass through. At the group limit a new key passes through unchanged; at the
/// count limit a group is sealed and later comments start another group, so neither limit silently
/// discards a line. Published comments are values and are never rewritten by a later ingest.
public struct DanmakuBatchAggregator: Sendable {
  public struct Configuration: Sendable, Equatable {
    public static let enabledKey = "Manping.liveDanmakuAggregation"
    public static let maximumGroupsKey = "Manping.liveDanmakuAggregationMaxGroups"
    public static let maximumCountKey = "Manping.liveDanmakuAggregationMaxCount"
    public static let defaultMaximumGroups = 64
    public static let defaultMaximumCount = 100
    public static let maximumAllowedGroups = 256
    public static let maximumAllowedCount = 1_000

    public var enabled: Bool
    public var maximumGroups: Int
    public var maximumCount: Int

    public init(enabled: Bool = true, maximumGroups: Int = Self.defaultMaximumGroups,
      maximumCount: Int = Self.defaultMaximumCount) {
      self.enabled = enabled
      self.maximumGroups = min(Self.maximumAllowedGroups, max(1, maximumGroups))
      self.maximumCount = min(Self.maximumAllowedCount, max(2, maximumCount))
    }

    /// Reads the live-only aggregation controls without affecting archived danmaku. Missing keys
    /// use the defaults; malformed or out-of-range stored limits are clamped.
    public static func load(from defaults: any PreferencesStore) -> Configuration {
      let enabled = defaults.object(forKey: enabledKey) == nil ? true : defaults.bool(forKey: enabledKey)
      return Configuration(enabled: enabled,
        maximumGroups: defaults.object(forKey: maximumGroupsKey) == nil ? defaultMaximumGroups
          : defaults.integer(forKey: maximumGroupsKey),
        maximumCount: defaults.object(forKey: maximumCountKey) == nil ? defaultMaximumCount
          : defaults.integer(forKey: maximumCountKey))
    }
  }

  private struct Key: Hashable, Sendable {
    let text: String
    let color: UInt32
    let mode: Int
  }
  private struct Group {
    let key: Key
    let comment: DanmakuComment
    let startedAt: Double
    let sequence: UInt64
    var count: Int
  }
  private struct Output {
    let comment: DanmakuComment
    let mediaTime: Double
    let sequence: UInt64
  }

  public static let window: TimeInterval = 1
  public let configuration: Configuration
  private var groups: [Key: Group] = [:]
  private var order: [Key] = []
  private var ready: [Output] = []
  private var direct: [Output] = []
  private var lastMediaTime = -Double.infinity
  private var nextSequence: UInt64 = 0
  /// Active aggregation groups; sealed and passthrough outputs await the next explicit flush.
  public var pendingCount: Int { groups.count }

  public init(configuration: Configuration = Configuration()) {
    self.configuration = configuration
  }

  /// Adds one presentation comment. Returns false for invalid or stale media timestamps; callers
  /// must `reset()` when a reload or seek restarts the media clock.
  @discardableResult public mutating func ingest(
    _ comment: DanmakuComment, at mediaTime: Double, aggregate: Bool = true
  ) -> Bool {
    guard mediaTime.isFinite, mediaTime >= 0, mediaTime >= lastMediaTime else { return false }
    lastMediaTime = mediaTime
    expire(at: mediaTime)
    guard comment.mode == 1, aggregate, configuration.enabled, !comment.text.isEmpty else {
      appendDirect(comment, at: mediaTime)
      return true
    }
    let key = Key(text: comment.text, color: comment.color, mode: comment.mode)
    if var group = groups[key] {
      guard group.count < configuration.maximumCount else {
        // The ingest that reached the cap already sealed this group.
        appendDirect(comment, at: mediaTime)
        return true
      }
      group.count += 1
      groups[key] = group
      if group.count == configuration.maximumCount { seal(key) }
    } else if order.count < configuration.maximumGroups {
      let sequence = advanceSequence()
      groups[key] = Group(key: key, comment: comment, startedAt: mediaTime, sequence: sequence, count: 1)
      order.append(key)
    } else {
      // Keep the active group dictionary bounded without dropping the new overlay line.
      appendDirect(comment, at: mediaTime)
    }
    return true
  }

  /// Live chat conversion keeps rich messages and every non-scrolling mode out of vote groups.
  @discardableResult public mutating func ingest(_ message: LiveDanmaku, at mediaTime: Double) -> Bool {
    let comment = DanmakuComment(time: mediaTime, mode: Int(message.mode), color: message.color, text: message.text)
    return ingest(comment, at: mediaTime, aggregate: Self.isPlainScrollingText(message))
  }

  /// Emits all sealed and passthrough comments, then closes windows elapsed at this media time.
  /// Every returned timestamp is the current media time, so output is nondecreasing and a batch
  /// delayed by a busy main thread enters at the renderer's now rather than halfway across screen.
  public mutating func flush(at mediaTime: Double) -> [DanmakuComment] {
    guard mediaTime.isFinite, mediaTime >= 0, mediaTime >= lastMediaTime else { return [] }
    lastMediaTime = mediaTime
    expire(at: mediaTime)
    var output = ready
    output.append(contentsOf: direct)
    ready.removeAll(keepingCapacity: true)
    direct.removeAll(keepingCapacity: true)
    output.sort { $0.mediaTime != $1.mediaTime ? $0.mediaTime < $1.mediaTime : $0.sequence < $1.sequence }
    return output.map { DanmakuComment(time: mediaTime, mode: $0.comment.mode, color: $0.comment.color,
      text: $0.comment.text, weight: $0.comment.weight, userHash: $0.comment.userHash,
      displayText: $0.comment.displayText) }
  }

  /// Forgets pending groups and the media-clock checkpoint on reload/reconnect.
  public mutating func reset() {
    groups.removeAll(keepingCapacity: true)
    order.removeAll(keepingCapacity: true)
    ready.removeAll(keepingCapacity: true)
    direct.removeAll(keepingCapacity: true)
    lastMediaTime = -Double.infinity
    nextSequence = 0
  }

  private mutating func expire(at mediaTime: Double) {
    let expired = order.filter { groups[$0].map { mediaTime >= $0.startedAt + Self.window } ?? false }
    for key in expired { seal(key) }
  }

  private mutating func seal(_ key: Key) {
    guard let group = groups.removeValue(forKey: key) else { return }
    order.removeAll { $0 == key }
    let displayText = group.count > 1 ? group.comment.text + " ×\(group.count)" : nil
    ready.append(Output(comment: DanmakuComment(time: group.comment.time, mode: group.comment.mode,
      color: group.comment.color, text: group.comment.text, weight: group.comment.weight,
      userHash: group.comment.userHash, displayText: displayText), mediaTime: group.startedAt,
      sequence: group.sequence))
  }

  private mutating func appendDirect(_ comment: DanmakuComment, at mediaTime: Double) {
    direct.append(Output(comment: comment, mediaTime: mediaTime, sequence: advanceSequence()))
  }

  private mutating func advanceSequence() -> UInt64 {
    nextSequence &+= 1
    return nextSequence
  }

  private static func isPlainScrollingText(_ message: LiveDanmaku) -> Bool {
    message.mode == 1 && message.dmType == 0 && !message.text.isEmpty
      && isEmpty(message.emotes) && isEmpty(message.roomEmote) && isEmpty(message.reply)
      && (message.emoticonUnique?.isEmpty ?? true)
  }

  private static func isEmpty(_ value: LiveJSON) -> Bool {
    switch value {
    case .null: true
    case .object(let values): values.isEmpty
    case .array(let values): values.isEmpty
    default: false
    }
  }
}
public final class DanmakuParser: NSObject, XMLParserDelegate {
  private var result: [DanmakuComment] = []
  private var properties: [String]?
  private var text = ""
  private let limit: Int
  private var accepted = 0
  private var randomState: UInt64 = 0x6a09e667f3bcc909

  private init(limit: Int) { self.limit = limit }
  public static func parse(_ data: Data, limit: Int = Int.max) throws -> [DanmakuComment] {
    let delegate = DanmakuParser(limit: max(1, limit))
    let parser = XMLParser(data: data)
    parser.delegate = delegate
    parser.shouldResolveExternalEntities = false
    guard parser.parse() else { throw BiliError.invalidResponse("Invalid danmaku XML") }
    return delegate.result.sorted { $0.time < $1.time }
  }
  public func parser(
    _ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
    qualifiedName: String?, attributes: [String: String]
  ) {
    if name == "d" {
      properties = attributes["p"]?.components(separatedBy: ",")
      text = ""
    }
  }
  public func parser(_ parser: XMLParser, foundCharacters string: String) {
    if properties != nil { text += string }
  }
  public func parser(
    _ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?
  ) {
    guard name == "d", let p = properties else { return }
    defer { properties = nil }
    guard p.count >= 4, let time = Double(p[0]), time.isFinite, time >= 0, let mode = Int(p[1]),
      [1, 4, 5].contains(mode), let color = UInt32(p[3]), !text.isEmpty
    else { return }
    // list.so: time, mode, size, color, sent, pool, user hash, id, weight.
    let weight = p.count >= 9 ? Int(p[8]) : nil
    let hash = p.count >= 7 && !p[6].isEmpty ? p[6].lowercased() : nil
    let comment = DanmakuComment(time: time, mode: mode, color: color, text: String(text.prefix(160)), weight: weight, userHash: hash)
    accepted += 1
    if result.count < limit {
      result.append(comment)
    } else {
      randomState = randomState &* 6364136223846793005 &+ 1442695040888963407
      let index = Int(randomState % UInt64(accepted))
      if index < limit { result[index] = comment }
    }
  }
}
public struct PositionedComment: Sendable {
  public let comment: DanmakuComment
  public let lane: Int
  public let progress: Double
}
/// Deterministic media-clock scheduling: pause, speed changes and seeking don't depend on wall time.
///
/// Scrolling comments all take the same time to cross, so a long line moves faster than a short
/// one. A lane only takes a new line once the previous tail has left the right edge and the new
/// head cannot catch it before it leaves on the left; text widths are estimated in ems against a
/// deliberately narrow view, which keeps wider views (and smaller fonts) collision-free too.
/// Top comments take a lane no scrolling line is using; bottom comments have their own stack.
public struct DanmakuTimeline: Sendable {
  private struct Entry {
    let comment: DanmakuComment
    let lane: Int
  }
  private struct StoredComment {
    let comment: DanmakuComment
    // A checkpoint verifies that a cached viewport still shares this append-only prefix.
    let revision: UUID
  }
  private struct Lane {
    var start = -Double.infinity
    var length = 0.0
    var fixedUntil = -Double.infinity
  }
  /// View width in ems that placement assumes (about a 670pt player at 24pt).
  static let assumedWidth = 28.0
  /// Space kept between two lines in one lane, in ems.
  static let spacing = 1.0
  private var entries: [Entry] = []
  /// Every accepted comment, so a speed change can lay the lanes out again.
  private var comments: [StoredComment] = []
  private var firstCommentIndex = 0
  private var endCommentIndex: Int { firstCommentIndex + comments.count }
  private var revision = UUID()
  /// Appends preserve the layout; replacement, speed and shield changes do not.
  private(set) var layoutRevision = UUID()
  private var lanes: [Lane]
  private var bottomUntil: [Double]
  public let duration: Double
  /// Playback speed multiplier the lanes are laid out for (0.5–2).
  public private(set) var speed: Double = 1
  public private(set) var scrollingDurationScale: Double = 1
  /// Shield applied while laying out; hidden lines keep no lane.
  public private(set) var filter = DanmakuFilter()
  private var matcher = DanmakuFilter().compiled()
  public init(comments: [DanmakuComment], lanes: Int = 16, duration: Double = 8) {
    self.duration = max(1, duration)
    self.lanes = [Lane](repeating: Lane(), count: max(1, lanes))
    bottomUntil = [Double](repeating: -Double.infinity, count: max(1, lanes / 2))
    let revision = revision
    self.comments = comments.filter { $0.time.isFinite }.sorted(by: { $0.time < $1.time })
      .map { StoredComment(comment: $0, revision: revision) }
    for stored in self.comments { place(stored.comment) }
  }
  public var count: Int { entries.count }
  /// Comment density over the video, `bins` buckets scaled to 0…1 (peak = 1). Counts every
  /// loaded comment, shielded or not, so the curve shows where the audience reacted.
  public func density(duration: Double, bins: Int = 100) -> [Double] {
    guard duration.isFinite, duration > 0, bins > 0, comments.count >= 20 else { return [] }
    var counts = [Double](repeating: 0, count: bins)
    for stored in comments where stored.comment.time >= 0 && stored.comment.time <= duration {
      counts[min(bins - 1, Int(stored.comment.time / duration * Double(bins)))] += 1
    }
    // Light smoothing so single spikes read as moments rather than noise.
    let smoothed = counts.indices.map { index -> Double in
      let window = counts[max(0, index - 1)...min(bins - 1, index + 1)]
      return window.reduce(0, +) / Double(window.count)
    }
    guard let peak = smoothed.max(), peak > 0 else { return [] }
    return smoothed.map { $0 / peak }
  }
  /// Lays the lanes out again for a new speed: a slower crawl needs wider gaps.
  public mutating func setSpeed(_ value: Double) {
    let clamped = value.isFinite ? min(2, max(0.5, value)) : 1
    guard clamped != speed else { return }
    speed = clamped
    relayout()
  }
  /// Fixed comments keep their original dwell in a viewport-specific layout.
  public mutating func setScrollingDurationScale(_ value: Double) {
    let scale = Self.normalizedScrollingDurationScale(value)
    guard scale != scrollingDurationScale else { return }
    scrollingDurationScale = scale
    relayout()
  }
  /// Applies a new shield to the comments already loaded and to later live lines.
  public mutating func setFilter(_ value: DanmakuFilter) {
    guard value != filter else { return }
    filter = value
    matcher = value.compiled()
    relayout()
  }
  private static func normalizedScrollingDurationScale(_ value: Double) -> Double {
    value.isFinite ? max(1, value) : 1
  }
  private mutating func relayout() {
    revision = UUID(); layoutRevision = UUID()
    entries.removeAll(keepingCapacity: true)
    lanes = [Lane](repeating: Lane(), count: lanes.count)
    bottomUntil = [Double](repeating: -Double.infinity, count: bottomUntil.count)
    for stored in comments { place(stored.comment) }
  }
  /// Live chat: adds a comment at the current media clock. Comments must arrive in time order
  /// (a reload that restarts the clock should start a new timeline). Lines that scrolled off
  /// long ago are dropped so a long live session keeps a bounded timeline.
  @discardableResult public mutating func append(_ comment: DanmakuComment) -> Bool {
    if let last = comments.last, comment.time < last.comment.time { return false }
    guard comment.time.isFinite else { return false }
    revision = UUID()
    comments.append(StoredComment(comment: comment, revision: revision))
    let placed = place(comment)
    if comments.count > 1_500 {
      let cutoff = comment.time - duration * 4
      if let keep = comments.firstIndex(where: { $0.comment.time >= cutoff }), keep > 0 {
        comments.removeFirst(keep); firstCommentIndex += keep
      }
      if let keep = entries.firstIndex(where: { $0.comment.time >= cutoff }), keep > 0 { entries.removeFirst(keep) }
      // A paused stream keeps the media clock still while chat keeps arriving, so the time
      // window alone never shrinks: hold at most the newest 1,500 whatever their timestamps.
      if comments.count > 1_500 {
        let removed = comments.count - 1_500
        comments.removeFirst(removed); firstCommentIndex += removed
      }
      if entries.count > 1_500 { entries.removeFirst(entries.count - 1_500) }
    }
    return placed
  }
  /// A renderer-owned layout. Unchanged publications are O(1); live updates place only the
  /// appended suffix. Keep this on the rendering thread so a new viewport never lays out
  /// the whole source on the main thread.
  public struct ViewportCache: Sendable {
    public private(set) var timeline = DanmakuTimeline(comments: [])
    private var sourceLayoutRevision: UUID?
    private var sourceRevision: UUID?
    private var sourceEnd = 0
    private var lastCommentRevision: UUID?
    public init() {}

    public mutating func update(source: DanmakuTimeline, scrollingDurationScale value: Double) {
      let scale = DanmakuTimeline.normalizedScrollingDurationScale(value)
      guard sourceRevision != source.revision || timeline.scrollingDurationScale != scale else { return }
      if source.scrollingDurationScale == scale {
        // In particular, 120 Hz uses the original layout without any extra placement.
        timeline = source
      } else {
        let checkpoint = sourceEnd - source.firstCommentIndex - 1
        let sharesPrefix = sourceEnd == 0 && source.firstCommentIndex == 0
          || (source.comments.indices.contains(checkpoint) && source.comments[checkpoint].revision == lastCommentRevision)
        if sourceLayoutRevision == source.layoutRevision, timeline.scrollingDurationScale == scale,
          sourceEnd <= source.endCommentIndex, sharesPrefix {
          for stored in source.comments.suffix(source.endCommentIndex - sourceEnd) { timeline.append(stored.comment) }
        } else {
          timeline = source
          timeline.setScrollingDurationScale(scale)
        }
      }
      sourceLayoutRevision = source.layoutRevision; sourceRevision = source.revision
      sourceEnd = source.endCommentIndex; lastCommentRevision = source.comments.last?.revision
    }
  }

  /// Rough advance in ems: ASCII is about half as wide as CJK and emoji.
  static func estimatedLength(_ text: String) -> Double {
    text.unicodeScalars.reduce(0) { total, scalar in
      if scalar.properties.generalCategory == .nonspacingMark || scalar.value == 0xfe0f { return total }
      return total + (scalar.isASCII ? 0.56 : 1)
    }
  }
  @discardableResult private mutating func place(_ comment: DanmakuComment) -> Bool {
    guard matcher.allows(comment) else { return false }
    let time = comment.time
    let fixedDuration = duration / speed
    let crossing = fixedDuration * scrollingDurationScale
    let lane: Int?
    switch comment.mode {
    case 4:
      if let index = bottomUntil.firstIndex(where: { $0 <= time }) {
        bottomUntil[index] = time + fixedDuration
        entries.append(Entry(comment: comment, lane: index))
        return true
      }
      return false
    case 5:
      lane = lanes.firstIndex { $0.fixedUntil <= time && $0.start + crossing <= time }
      if let lane { lanes[lane].fixedUntil = time + fixedDuration }
    default:
      let length = Self.estimatedLength(comment.displayedText)
      let width = Self.assumedWidth
      lane = lanes.firstIndex { previous in
        guard previous.fixedUntil <= time else { return false }
        // The previous tail must clear the right edge, and the new head must not reach the
        // previous tail before that line leaves on the left.
        let clear = crossing * (previous.length + Self.spacing) / (width + previous.length)
        let catchUp = crossing * (length + Self.spacing) / (width + length)
        return time - previous.start >= max(clear, catchUp)
      }
      if let lane { lanes[lane].start = time; lanes[lane].length = length }
    }
    guard let lane else { return false }
    entries.append(Entry(comment: comment, lane: lane))
    return true
  }
  public func visible(at clock: Double, speed: Double = 1) -> [PositionedComment] {
    guard clock.isFinite, clock >= 0 else { return [] }
    let duration = self.duration / (speed.isFinite ? min(2, max(0.5, speed)) : 1)
    let scrolling = duration * scrollingDurationScale
    let lo = firstOnScreen(at: clock, duration: scrolling)
    var result: [PositionedComment] = []
    for entry in entries.dropFirst(lo) {
      if entry.comment.time > clock { break }
      let crossing = entry.comment.mode == 4 || entry.comment.mode == 5 ? duration : scrolling
      guard clock - entry.comment.time < crossing else { continue }
      result.append(
        PositionedComment(
          comment: entry.comment, lane: entry.lane,
          progress: (clock - entry.comment.time) / crossing))
    }
    return result
  }
  /// Whether `visible(at:speed:)` would return any line, without building the list (the
  /// renderer asks every display refresh).
  public func hasVisible(at clock: Double, speed: Double = 1) -> Bool {
    guard clock.isFinite, clock >= 0 else { return false }
    let duration = self.duration / (speed.isFinite ? min(2, max(0.5, speed)) : 1)
    let scrolling = duration * scrollingDurationScale
    let lo = firstOnScreen(at: clock, duration: scrolling)
    for entry in entries.dropFirst(lo) {
      if entry.comment.time > clock { break }
      let crossing = entry.comment.mode == 4 || entry.comment.mode == 5 ? duration : scrolling
      if clock - entry.comment.time < crossing { return true }
    }
    return false
  }
  /// Index of the first entry that has not yet left the screen at `clock` (entries are in time order).
  private func firstOnScreen(at clock: Double, duration: Double) -> Int {
    var lo = 0
    var hi = entries.count
    while lo < hi {
      let mid = (lo + hi) / 2
      if entries[mid].comment.time <= clock - duration { lo = mid + 1 } else { hi = mid }
    }
    return lo
  }
}
