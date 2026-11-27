import AppKit

/// Hosts one playback page after the root removes its previous SwiftUI owner.
/// It never creates a PlayerModel or a second render surface.
@MainActor final class M7PlaybackWindowCoordinator: NSObject, NSWindowDelegate {
  static let defaultSize = NSSize(width: 1280, height: 720)
  static let minimumSize = NSSize(width: 640, height: 360)

  private let savesFrame: Bool
  private(set) var window: NSWindow?
  private weak var mainWindow: NSWindow?
  private var onClose: (@MainActor () -> Void)?
  /// The window's own full-screen button moved the picture; a pending open placement must yield.
  var onUserPlaced: (@MainActor () -> Void)?
  /// The window enters (true) or leaves (false) full screen; its page turns immersive.
  var onFullScreen: (@MainActor (Bool) -> Void)?
  private var closing = false
  /// This window only shows the player, so its full screen is always immersive.
  private lazy var fullScreen = PlayerFullScreenTransition(showsPlayer: { true },
    setFullScreen: { [weak self] in self?.onFullScreen?($0) })

  init(savesFrame: Bool = true) {
    self.savesFrame = savesFrame
    super.init()
  }

  /// Shows `content` in the window. `displayMode` (default, fullscreen or compact) is applied
  /// when the caller opens something there; nil keeps the window's current state.
  func present(content: NSView, mainWindow: NSWindow?, displayMode: String?,
    onClose: @escaping @MainActor () -> Void) {
    self.mainWindow = mainWindow
    self.onClose = onClose
    if window == nil {
      let window = PlayerHostWindow(contentRect: NSRect(origin: .zero, size: Self.defaultSize),
        styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
        backing: .buffered, defer: false)
      window.title = "满屏 · 播放"
      window.titlebarAppearsTransparent = true
      window.titleVisibility = .hidden
      window.backgroundColor = Theme.stageNSColor
      window.isReleasedWhenClosed = false
      window.isRestorable = false
      window.minSize = Self.minimumSize
      window.delegate = self
      window.center()
      // Reopens where the user last left it (center() is only the first-run default).
      if savesFrame, !DebugUIFixtures.usesLiveSceneMemory { window.setFrameAutosaveName("PlaybackWindow") }
      self.window = window
    }
    guard let window else { return }
    // The window instance is kept across closes so its frame (size and position) is remembered.
    window.delegate = self
    window.contentView = content
    #if DEBUG
    publishWindowID(window)
    #endif
    window.makeKeyAndOrderFront(nil)
    if let displayMode { applyDisplayMode(displayMode) }
  }
  func applyDisplayMode(_ displayMode: String) {
    guard let window else { return }
    let fullScreen = window.styleMask.contains(.fullScreen)
    if displayMode == "fullscreen" {
      if !fullScreen { window.toggleFullScreen(nil) }
    } else {
      if fullScreen { window.toggleFullScreen(nil) }
      window.level = displayMode == "compact" ? .floating : .normal
      window.collectionBehavior = displayMode == "compact" ? [.canJoinAllSpaces, .fullScreenAuxiliary] : []
      if displayMode == "compact" {
        window.setContentSize(NSSize(width: 800, height: 500))
      }
    }
  }
  func close(showMain: Bool = true, notify: Bool = true) {
    guard let window, window.isVisible, !closing else { return }
    closing = true
    let callback = notify ? onClose : nil
    onClose = nil
    window.delegate = nil
    window.contentView = nil
    window.close()
    // Keep the instance: its autosaved frame survives, so reopening restores the same size.
    #if DEBUG
    if let file = playbackWindowIDFile { try? FileManager.default.removeItem(at: file) }
    #endif
    fullScreen.reset()
    if showMain { mainWindow?.makeKeyAndOrderFront(nil) }
    closing = false
    callback?()
  }
  func windowWillClose(_ notification: Notification) { close(showMain: true) }
  func windowWillEnterFullScreen(_ notification: Notification) {
    onUserPlaced?()
    if let window { fullScreen.willEnter(window) }
  }
  func windowWillExitFullScreen(_ notification: Notification) {
    onUserPlaced?()
    fullScreen.willExit()
  }
  func customWindowsToEnterFullScreen(for window: NSWindow) -> [NSWindow]? { fullScreen.customWindowsToEnter(window) }
  func window(_ window: NSWindow, startCustomAnimationToEnterFullScreenWithDuration duration: TimeInterval) {
    fullScreen.startEntering(window, duration: duration)
  }
  func customWindowsToExitFullScreen(for window: NSWindow) -> [NSWindow]? { fullScreen.customWindowsToExit(window) }
  func window(_ window: NSWindow, startCustomAnimationToExitFullScreenWithDuration duration: TimeInterval) {
    fullScreen.startExiting(window, duration: duration)
  }
  func window(_ window: NSWindow, willUseFullScreenContentSize proposedSize: NSSize) -> NSSize {
    fullScreen.fullScreenContentSize(proposed: proposedSize)
  }
  func windowDidEnterFullScreen(_ notification: Notification) { fullScreen.didEnter() }
  func windowDidExitFullScreen(_ notification: Notification) { fullScreen.didExit() }
  func windowDidFailToEnterFullScreen(_ window: NSWindow) { fullScreen.didFailToEnter() }
  func windowDidFailToExitFullScreen(_ window: NSWindow) { fullScreen.didFailToExit() }

  #if DEBUG
  private var playbackWindowIDFile: URL? {
    guard Bundle.main.bundleURL.pathExtension == "app" else { return nil }
    return Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("playback-window-id")
  }

  private func publishWindowID(_ window: NSWindow) {
    guard let file = playbackWindowIDFile else { return }
    try? String(window.windowNumber).write(to: file, atomically: true, encoding: .utf8)
  }
  #endif
}
