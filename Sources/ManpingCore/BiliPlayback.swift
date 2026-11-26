import Foundation

public struct MediaStream: Identifiable, Equatable, Sendable {
  public var id: String { "\(quality)-\(codec)" }
  public let quality: Int
  public let codec: String
  public let url: URL
  public let bandwidth: Int
  public let label: String
  public let width: Int
  public let height: Int
  public let backupURLs: [URL]
  public let codecID: Int
  public init(
    quality: Int, codec: String, url: URL, bandwidth: Int, label: String,
    width: Int = 0, height: Int = 0, backupURLs: [URL] = [], codecID: Int = 0
  ) {
    self.quality = quality
    self.codec = codec
    self.url = url
    self.bandwidth = bandwidth
    self.label = label
    self.width = width
    self.height = height
    self.backupURLs = backupURLs
    self.codecID = codecID
  }
}

public enum PlaybackAudioKind: String, Sendable {
  case aac, hires, flac, dolby, unknown

  public init(stream: MediaStream) {
    let codec = stream.codec.lowercased()
    if codec.hasPrefix("ec-3") || codec.hasPrefix("ec3") || codec.hasPrefix("ac-3") { self = .dolby }
    else if stream.quality == 30250 { self = .dolby }
    else if stream.quality == 30251 { self = .hires }
    else if codec.hasPrefix("flac") { self = .flac }
    else if codec.hasPrefix("mp4a") { self = .aac }
    else { self = .unknown }
  }

  public var title: String {
    switch self {
    case .aac: "AAC"
    case .hires: "Hi-Res"
    case .flac: "FLAC"
    case .dolby: "杜比"
    case .unknown: "其他"
    }
  }
}

public extension MediaStream {
  var audioKind: PlaybackAudioKind? {
    guard quality >= 30216 || codec.lowercased().contains("mp4a") else { return nil }
    return PlaybackAudioKind(stream: self)
  }
  var audioTitle: String {
    guard let kind = audioKind else { return label }
    if kind == .dolby, codec.lowercased().hasPrefix("ec-3") { return "Dolby Digital Plus" }
    if kind == .dolby, quality == 30250 { return "杜比全景声" }
    if kind == .unknown { return codec.isEmpty ? label : codec.uppercased() }
    return kind.title
  }
}

public struct PlaybackFormat: Sendable, Equatable {
  public let quality: Int
  public let format: String
  public let description: String
}

public struct PlaybackManifest: Sendable {
  public let video: [MediaStream]
  public let audio: [MediaStream]
  public let duration: Double
  public let formats: [PlaybackFormat]
  /// Opening / ending ranges an episode marks for skipping (PGC only).
  public let skips: [PlaybackSkip]
  public init(
    video: [MediaStream], audio: [MediaStream], duration: Double,
    formats: [PlaybackFormat] = [], skips: [PlaybackSkip] = []
  ) {
    self.video = video
    self.audio = audio
    self.duration = duration
    self.formats = formats
    self.skips = skips
  }
  public static func parse(_ object: [String: Any]) throws -> PlaybackManifest {
    guard let dash = object["dash"] as? [String: Any] else {
      throw BiliError.invalidResponse("This video did not return DASH streams")
    }
    let ids = object["accept_quality"] as? [Int] ?? []
    let names = object["accept_description"] as? [String] ?? []
    var labels: [Int: String] = [:]
    for (index, id) in ids.enumerated() where index < names.count { labels[id] = names[index] }
    let formats = (object["support_formats"] as? [[String: Any]] ?? []).compactMap {
      item -> PlaybackFormat? in
      guard let quality = item["quality"] as? Int else { return nil }
      let name =
        item["new_description"] as? String ?? item["description"] as? String ?? labels[quality]
        ?? "\(quality)"
      labels[quality] = name
      return PlaybackFormat(
        quality: quality, format: item["format"] as? String ?? "", description: name)
    }
    func streams(_ key: String) -> [MediaStream] {
      (dash[key] as? [[String: Any]] ?? []).compactMap { item in
        guard let url = JSONValue.url(item["baseUrl"] ?? item["base_url"]),
          let id = item["id"] as? Int
        else { return nil }
        return MediaStream(
          quality: id, codec: item["codecs"] as? String ?? "", url: url,
          bandwidth: JSONValue.int(item["bandwidth"]), label: labels[id] ?? "\(id)",
          width: JSONValue.int(item["width"]), height: JSONValue.int(item["height"]),
          backupURLs: ((item["backupUrl"] ?? item["backup_url"]) as? [String] ?? []).compactMap(
            JSONValue.url),
          codecID: JSONValue.int(item["codecid"]))
      }.sorted {
        $0.quality > $1.quality || ($0.quality == $1.quality && $0.bandwidth > $1.bandwidth)
      }
    }
    let video = streams("video")
    let audio = streams("audio")
    guard !video.isEmpty, !audio.isEmpty else {
      throw BiliError.invalidResponse("DASH video/audio unavailable")
    }
    return PlaybackManifest(
      video: video, audio: audio,
      duration: (dash["duration"] as? NSNumber)?.doubleValue ?? 0, formats: formats,
      skips: PlaybackSkip.parse(object["clip_info_list"]))
  }
}

/// A range the episode marks as opening or ending, in seconds.
public struct PlaybackSkip: Sendable, Equatable {
  public enum Kind: Sendable, Equatable { case opening, ending }
  public let kind: Kind
  public let start: Double
  public let end: Double
  public init(kind: Kind, start: Double, end: Double) { self.kind = kind; self.start = start; self.end = end }
  public var title: String { kind == .opening ? "跳过片头" : "跳过片尾" }

  static func parse(_ raw: Any?) -> [PlaybackSkip] {
    (raw as? [[String: Any]] ?? []).compactMap { item in
      let kind: Kind
      switch item["clipType"] as? String {
      case "CLIP_TYPE_OP": kind = .opening
      case "CLIP_TYPE_ED": kind = .ending
      default: return nil
      }
      guard let start = (item["start"] as? NSNumber)?.doubleValue, let end = (item["end"] as? NSNumber)?.doubleValue,
        start.isFinite, end.isFinite, start >= 0, end - start >= 5, end - start <= 600 else { return nil }
      return PlaybackSkip(kind: kind, start: start, end: end)
    }.sorted { $0.start < $1.start }
  }

  /// The range playing at `time`, offered until a few seconds before it ends.
  public static func active(_ skips: [PlaybackSkip], at time: Double) -> PlaybackSkip? {
    skips.first { time >= $0.start && time < $0.end - 3 }
  }
}

/// Automatic skipping for one episode. Each marked range is skipped at most once, whether
/// playback starts inside it, automatic skipping is turned on while it plays, or the picture
/// moves to another window; seeking back into a range that was already skipped (or skipped by
/// hand) leaves the viewer there.
public struct PlaybackSkipTracker: Sendable, Equatable {
  public private(set) var episode: Int64?
  private var handled: Set<Double> = []
  public init(episode: Int64? = nil) { self.episode = episode }
  /// A new episode (or none): every range may be skipped again.
  public mutating func reset(episode: Int64?) { self.episode = episode; handled = [] }
  /// Where to seek now, or nil. Returning a target marks its range handled.
  public mutating func target(_ skips: [PlaybackSkip], at time: Double, automatic: Bool) -> Double? {
    guard automatic, time.isFinite, let range = PlaybackSkip.active(skips, at: time),
      !handled.contains(range.start) else { return nil }
    handled.insert(range.start)
    return range.end
  }
  /// The viewer pressed 「跳过」 for this range.
  public mutating func markHandled(_ skip: PlaybackSkip) { handled.insert(skip.start) }
}

public enum PlaybackCodec: String, CaseIterable, Sendable {
  case h264, hevc, av1
  func matches(_ stream: MediaStream) -> Bool {
    let codec = stream.codec.lowercased()
    switch self {
    case .h264: return stream.codecID == 7 || codec.hasPrefix("avc")
    case .hevc: return stream.codecID == 12 || codec.hasPrefix("hev") || codec.hasPrefix("hvc")
    case .av1: return stream.codecID == 13 || codec.hasPrefix("av01")
    }
  }
}

public enum PlaybackAudioPreference: String, CaseIterable, Sendable {
  case auto, hires, flac, dolby, aac
  public var title: String {
    switch self {
    case .auto: "自动"
    case .hires: "Hi-Res 优先"
    case .flac: "FLAC 优先"
    case .dolby: "杜比优先"
    case .aac: "AAC"
    }
  }
}

public struct PlaybackPreferences: Sendable, Equatable {
  public var codec: PlaybackCodec
  public var quality: Int?
  public var lastQuality: Int?
  public var avoidP2P: Bool
  public var audio: PlaybackAudioPreference
  public var audioStreamID: String?
  public init(
    codec: PlaybackCodec = .h264, quality: Int? = nil,
    lastQuality: Int? = nil, avoidP2P: Bool = false,
    audio: PlaybackAudioPreference = .auto, audioStreamID: String? = nil
  ) {
    self.codec = codec
    self.quality = quality
    self.lastQuality = lastQuality
    self.avoidP2P = avoidP2P
    self.audio = audio
    self.audioStreamID = audioStreamID
  }
}

public struct PlaybackSelection: Sendable {
  public let video: MediaStream
  public let audio: MediaStream
  public let videoURL: URL
  public let audioURL: URL
}

public enum PlaybackSelector {
  public static let defaultQualityCeiling = 116
  public static func select(
    _ manifest: PlaybackManifest, preferences: PlaybackPreferences = .init(),
    supportsHardware: (PlaybackCodec) -> Bool = { $0 == .h264 }
  ) throws -> PlaybackSelection {
    // H.264 remains the compatibility baseline. Higher codecs require the caller's hardware verdict.
    let supported = manifest.video.filter { stream in
      PlaybackCodec.h264.matches(stream)
        || PlaybackCodec.allCases.contains {
          $0 != .h264 && $0.matches(stream) && supportsHardware($0)
        }
    }
    let eligible = supported.filter { stream in
      !preferences.avoidP2P || ([stream.url] + stream.backupURLs).contains(where: { !isP2P($0) })
    }
    let eligibleAudio = manifest.audio.filter { stream in
      !preferences.avoidP2P || ([stream.url] + stream.backupURLs).contains(where: { !isP2P($0) })
    }
    guard !eligible.isEmpty, !eligibleAudio.isEmpty else {
      throw BiliError.invalidResponse(
        preferences.avoidP2P ? "没有可用的非 P2P 播放节点，请关闭「不使用 P2P」或选择其他画质。" : "No compatible playback streams")
    }
    let highestAudio = eligibleAudio.max {
      $0.quality < $1.quality || ($0.quality == $1.quality && $0.bandwidth < $1.bandwidth)
    }
    let preferredKinds: [PlaybackAudioKind]
    switch preferences.audio {
    case .auto: preferredKinds = [.dolby, .hires, .flac, .aac]
    case .hires: preferredKinds = [.hires, .flac]
    case .flac: preferredKinds = [.flac, .hires]
    case .dolby: preferredKinds = [.dolby]
    case .aac: preferredKinds = [.aac]
    }
    let preferredAudio = preferences.audioStreamID.flatMap { id in eligibleAudio.first { $0.id == id } }
      ?? preferredKinds.lazy.compactMap { kind in
        eligibleAudio.filter({ $0.audioKind == kind }).max {
          $0.quality < $1.quality || ($0.quality == $1.quality && $0.bandwidth < $1.bandwidth)
        }
      }.first
    guard let audio = preferredAudio ?? highestAudio else {
      throw BiliError.invalidResponse("No compatible audio stream")
    }
    let qualities = Set(eligible.map(\.quality)).sorted(by: >)
    // With no preference yet, start at 1080P 60 (116) rather than 8K / Dolby Vision: the
    // highest tiers start slowly and stall on ordinary networks. A request below every
    // available tier falls back to the lowest tier, not the highest.
    let requested = preferences.quality ?? preferences.lastQuality ?? PlaybackSelector.defaultQualityCeiling
    let quality = qualities.first(where: { $0 <= requested }) ?? qualities[qualities.count - 1]
    let candidates = eligible.filter { $0.quality == quality }.sorted {
      $0.bandwidth > $1.bandwidth
    }
    let video =
      candidates.first(where: { preferences.codec.matches($0) })
      ?? candidates.first(where: { PlaybackCodec.h264.matches($0) }) ?? candidates[0]
    func selectedURL(_ stream: MediaStream) throws -> URL {
      guard preferences.avoidP2P else { return stream.url }
      guard let url = ([stream.url] + stream.backupURLs).first(where: { !isP2P($0) }) else {
        throw BiliError.invalidResponse("没有可用的非 P2P 播放节点。")
      }
      return url
    }
    return PlaybackSelection(
      video: video, audio: audio,
      videoURL: try selectedURL(video), audioURL: try selectedURL(audio))
  }
  public static func isP2P(_ url: URL) -> Bool {
    let host = url.host?.lowercased() ?? ""
    return ["mcdn.bilivideo.cn", "mcdn.bilivideo.com", "szbdyd.com"].contains {
      host == $0 || host.hasSuffix("." + $0)
    }
  }
}
