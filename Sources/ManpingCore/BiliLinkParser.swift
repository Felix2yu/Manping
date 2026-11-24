import Foundation

/// A Bilibili destination recognised from a pasted, dropped or opened link.
public enum BiliLink: Equatable, Sendable {
  case video(bvid: String, part: Int? = nil, startAt: Double? = nil)
  case archive(aid: Int64)
  case episode(Int64)
  case season(Int64)
  case live(Int64)
  case article(Int64)
  case space(Int64)
  case search(String)
  case region(Int64)
  /// b23.tv short link: resolve its redirect, then parse the result.
  case short(URL)
}

/// Recognises web links (www/m/live/space.bilibili.com, b23.tv), this app's `manping://` scheme
/// and bare identifiers (BV…, av…, ep…, ss…, cv…). Anything else is not ours.
public enum BiliLinkParser {
  private static let webHosts: Set<String> = ["bilibili.com", "www.bilibili.com", "m.bilibili.com"]
  private static let shortHosts: Set<String> = ["b23.tv", "www.b23.tv", "bili2233.cn"]

  public static func parse(_ raw: String) -> BiliLink? {
    let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty, text.count <= 2048 else { return nil }
    if let link = identifier(text) { return link }
    // A share text often wraps the link in words: take the first URL in it.
    if let url = URL(string: text), url.scheme != nil, let link = parse(url) { return link }
    let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
    if let match = detector?.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)), let url = match.url {
      return parse(url)
    }
    return nil
  }

  public static func parse(_ url: URL) -> BiliLink? {
    guard url.user == nil, url.password == nil, let scheme = url.scheme?.lowercased() else { return nil }
    if scheme == "manping" || scheme == "bilibili" {
      // manping://video/BV…, bilibili://live/123, manping://search?keyword=…
      let parts = ([url.host ?? ""] + url.pathComponents.filter { $0 != "/" }).filter { !$0.isEmpty }
      guard !parts.isEmpty else { return nil }
      let (kind, value) = (parts[0].lowercased(), parts.count >= 2 ? parts[1] : "")
      switch kind {
      case "video": return identifier(value).flatMap { videoLink($0, url: url) }
      case "episode": return number(value).map(BiliLink.episode)
      case "season": return number(value).map(BiliLink.season)
      case "live": return number(value).map(BiliLink.live)
      case "article": return number(value.hasPrefix("cv") ? String(value.dropFirst(2)) : value).map(BiliLink.article)
      case "space": return number(value).map(BiliLink.space)
      case "region": return number(value).map(BiliLink.region)
      case "search": return searchQuery(url).map(BiliLink.search)
      default: return nil
      }
    }
    guard ["http", "https"].contains(scheme), let host = url.host?.lowercased() else { return nil }
    let parts = url.pathComponents.filter { $0 != "/" }
    if shortHosts.contains(host) { return parts.count == 1 ? .short(url) : nil }
    if host == "live.bilibili.com" {
      if parts.first == "h5", parts.count >= 2 { return number(parts[1]).map(BiliLink.live) }
      return parts.first.flatMap(number).map(BiliLink.live)
    }
    if host == "search.bilibili.com" { return searchQuery(url).map(BiliLink.search) }
    if host == "space.bilibili.com" { return parts.first.flatMap(number).map(BiliLink.space) }
    guard webHosts.contains(host), parts.count >= 2 else { return nil }
    switch parts[0] {
    case "video": return identifier(parts[1]).flatMap { videoLink($0, url: url) }
    case "v" where parts.count >= 3 && parts[1] == "channel":
      return number(parts[2]).map(BiliLink.region)
    case "bangumi" where parts.count >= 3 && parts[1] == "play":
      return identifier(parts[2]).flatMap { link in
        switch link { case .episode, .season: link; default: nil } }
    case "read":
      return identifier(parts[1]).flatMap { if case .article = $0 { $0 } else { nil } }
    default: return nil
    }
  }

  /// BV1xx411c7mD, av170001, ep123, ss456, cv789 (case-insensitive prefixes except BV's body).
  static func identifier(_ text: String) -> BiliLink? {
    if text.range(of: "^[Bb][Vv]1[0-9A-Za-z]{9}$", options: .regularExpression) != nil {
      return .video(bvid: "BV" + text.dropFirst(2))
    }
    let lower = text.lowercased()
    for (prefix, make) in [("av", BiliLink.archive), ("ep", BiliLink.episode), ("ss", BiliLink.season), ("cv", BiliLink.article)]
    where lower.hasPrefix(prefix) {
      return number(String(lower.dropFirst(2))).map(make)
    }
    return nil
  }

  private static func videoLink(_ link: BiliLink, url: URL) -> BiliLink? {
    switch link {
    case .archive: return link
    case .video(let bvid, _, _):
      let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
      let part = items.first(where: { $0.name == "p" })?.value.flatMap(Int.init).flatMap { $0 > 0 ? $0 : nil }
      let startAt = items.first(where: { $0.name == "t" })?.value.flatMap(Double.init).flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
      return .video(bvid: bvid, part: part, startAt: startAt)
    default: return nil
    }
  }

  private static func searchQuery(_ url: URL) -> String? {
    guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
      let raw = components.queryItems?.first(where: { $0.name == "keyword" })?.value else { return nil }
    let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !value.isEmpty, value.count <= 200 else { return nil }
    return value
  }

  private static func number(_ text: String) -> Int64? {
    guard text.range(of: "^[1-9][0-9]{0,17}$", options: .regularExpression) != nil else { return nil }
    return Int64(text)
  }

  /// Whether a redirect target of a short link may be followed.
  public static func isBilibili(_ url: URL) -> Bool {
    guard let host = url.host?.lowercased(), ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return false }
    return host == "bilibili.com" || host.hasSuffix(".bilibili.com")
  }
}
