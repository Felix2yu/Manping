import AppKit

struct PlaybackPageShortcutActions {
  let registrationID: UUID
  let mediaID: String
  var toggleInfo: (() -> Void)? = nil
  var toggleComments: (() -> Void)? = nil
  var like: (() -> Void)? = nil
  var coin: (() -> Void)? = nil
  var favorite: (() -> Void)? = nil
  var triple: (() -> Void)? = nil
  var composeDanmaku: (() -> Void)? = nil

  init(registrationID: UUID = UUID(), mediaID: String,
    toggleInfo: (() -> Void)? = nil, toggleComments: (() -> Void)? = nil,
    like: (() -> Void)? = nil, coin: (() -> Void)? = nil,
    favorite: (() -> Void)? = nil, triple: (() -> Void)? = nil,
    composeDanmaku: (() -> Void)? = nil) {
    self.registrationID = registrationID; self.mediaID = mediaID
    self.toggleInfo = toggleInfo; self.toggleComments = toggleComments
    self.like = like; self.coin = coin; self.favorite = favorite; self.triple = triple
    self.composeDanmaku = composeDanmaku
  }
}

enum PlaybackShortcut: Equatable, CaseIterable {
  case home, player, cycleWindows, zoom, compact, detached, info, comments, share, copyShareLink
  case speedUp, speedDown, volumeUp, volumeDown
  case previousAdjacent, nextAdjacent, previousHistory, nextHistory
  case like, coin, favorite, triple, playPause, seekBackward, seekForward
  case exitFullScreen, fullScreen, mute, composeDanmaku, toggleDanmaku
  case normalSpeed, doubleSpeed

  static func match(_ event: NSEvent) -> Self? {
    let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
      .subtracting([.capsLock, .function, .numericPad])
    let shifted = flags.contains(.shift)
    if flags.contains(.command) || flags.contains(.option) { return nil }
    if flags.contains(.control) {
      return event.keyCode == 48 && !shifted ? .cycleWindows : nil
    }
    guard flags.isEmpty || shifted, let key = event.charactersIgnoringModifiers?.lowercased(), !key.isEmpty else { return nil }
    if shifted {
      switch event.keyCode {
      case 18: return .normalSpeed
      case 19: return .doubleSpeed
      case 43: return .previousHistory
      case 45: return .nextHistory
      case 123: return .speedDown
      case 124: return .speedUp
      case 125: return .volumeUp
      case 126: return .volumeDown
      default: break
      }
      switch key {
      case "\u{f702}": return .speedUp
      case "\u{f703}": return .speedDown
      case "\u{f700}": return .volumeUp
      case "\u{f701}": return .volumeDown
      case "<": return .previousHistory
      case ">": return .nextHistory
      default: return nil
      }
    }
    switch event.keyCode {
    case 43: return .previousAdjacent
    case 45: return .nextAdjacent
    case 123: return .seekBackward
    case 124: return .seekForward
    case 125: return .volumeUp
    case 126: return .volumeDown
    default: break
    }
    switch key {
    case "a": return .home
    case "b": return .player
    case "g": return .zoom
    case "s": return .compact
    case "p": return .detached
    case "x": return .info
    case "c": return .comments
    case "v": return .share
    case "<": return .previousAdjacent
    case ">": return .nextAdjacent
    case "[": return .previousAdjacent
    case "]": return .nextAdjacent
    case "q": return .like
    case "w": return .coin
    case "e": return .favorite
    case "r": return .triple
    case " ": return .playPause
    case "\u{f700}": return .volumeUp
    case "\u{f701}": return .volumeDown
    case "\u{f702}": return .seekForward
    case "\u{f703}": return .seekBackward
    case "\u{1b}": return .exitFullScreen
    case "f": return .fullScreen
    case "\r", "\u{3}": return .composeDanmaku
    case "d": return .toggleDanmaku
    case "m": return .mute
    default: return nil
    }
  }
}

enum PlaybackKeyboardInput {
  @MainActor static func blocksShortcut(_ responder: NSResponder?) -> Bool {
    guard let editor = responder as? NSTextView else { return false }
    return editor.isEditable || editor.hasMarkedText()
  }
}

@MainActor final class PlaybackKeyboardRouter {
  private weak var delegate: AppDelegate?
  private var downMonitor: Any?
  private var upMonitor: Any?
  private var resignObserver: NotificationCenter.ObservationToken?
  private var holdTask: Task<Void, Never>?
  private var shareTask: Task<Void, Never>?
  private var heldAction: PlaybackShortcut?
  private var holdFired = false
  private var lastShare = Date.distantPast
  private let shareInterval: TimeInterval = 0.32

  init(delegate: AppDelegate) { self.delegate = delegate }

  func install() {
    guard downMonitor == nil else { return }
    downMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
      self?.keyDown(event) ?? event
    }
    upMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyUp) { [weak self] event in
      self?.keyUp(event)
      return event
    }
    resignObserver = NotificationCenter.default.addObserver(for: NSWindow.DidResignKeyMessage.self) {
      [weak self] _ in self?.cancelHold()
    }
  }

  func shutdown() {
    cancelHold()
    shareTask?.cancel(); shareTask = nil
    if let downMonitor { NSEvent.removeMonitor(downMonitor) }
    if let upMonitor { NSEvent.removeMonitor(upMonitor) }
    if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
    downMonitor = nil; upMonitor = nil; resignObserver = nil
  }

  private func keyDown(_ event: NSEvent) -> NSEvent? {
    guard let delegate, NSApp.keyWindow != nil else { return event }
    if PlaybackKeyboardInput.blocksShortcut(NSApp.keyWindow?.firstResponder) {
      guard event.keyCode == 53 else { return event }
      NSApp.keyWindow?.makeFirstResponder(nil)
      return nil
    }
    if heldAction != nil && !event.isARepeat { cancelHold() }
    guard let action = PlaybackShortcut.match(event) else { return event }
    // Recognized playback keys stay consumed when unavailable, so AppKit does not beep.
    guard delegate.canPerformShortcut(action, in: event.window ?? NSApp.keyWindow) else { return nil }
    switch action {
    case .like, .triple:
      if !event.isARepeat { beginHold(action, delay: 0.45) }
      return nil
    case .seekForward:
      if !event.isARepeat {
        delegate.performShortcut(.seekForward)
        beginHold(.seekForward, delay: 0.35)
      }
      return nil
    default:
      if action == .share {
        guard !event.isARepeat else { return nil }
        shareTask?.cancel()
        let now = Date()
        let doubleTap = now.timeIntervalSince(lastShare) < shareInterval
        lastShare = now
        if doubleTap {
          delegate.performShortcut(.copyShareLink)
        } else {
          shareTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(self?.shareInterval ?? 0.32))
            guard !Task.isCancelled else { return }
            self?.delegate?.performShortcut(.share)
            self?.shareTask = nil
          }
        }
        return nil
      }
      if !event.isARepeat { delegate.performShortcut(action) }
      return nil
    }
  }

  private func keyUp(_ event: NSEvent) {
    guard let action = heldAction, action.matchesKeyUp(event) else { return }
    let shouldLike = action == .like && !holdFired
    cancelHold()
    if shouldLike { delegate?.performShortcut(.like) }
  }

  private func beginHold(_ action: PlaybackShortcut, delay: TimeInterval) {
    holdTask?.cancel()
    heldAction = action; holdFired = false
    holdTask = Task { @MainActor [weak self] in
      do { try await Task.sleep(for: .seconds(delay)) } catch { return }
      guard let self, self.heldAction == action, !Task.isCancelled else { return }
      self.holdFired = true
      if action == .seekForward {
        self.delegate?.beginShortcutSeekHold()
      } else {
        self.delegate?.performShortcut(.triple)
      }
    }
  }

  private func cancelHold() {
    holdTask?.cancel(); holdTask = nil
    if heldAction == .seekForward { delegate?.endShortcutSeekHold() }
    heldAction = nil; holdFired = false
  }
}

extension PlaybackShortcut {
  func matchesKeyUp(_ event: NSEvent) -> Bool {
    if self == .seekForward { return event.keyCode == 124 }
    if self == .like { return event.charactersIgnoringModifiers?.lowercased() == "q" }
    if self == .triple { return event.charactersIgnoringModifiers?.lowercased() == "r" }
    return false
  }
}
